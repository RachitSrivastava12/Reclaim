// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {Vm} from "forge-std/Vm.sol";
import {SablierRecoveryExecutorV2} from "../src/SablierRecoveryExecutorV2.sol";
import {MockSablierLockup, RecoveryTestToken} from "./SablierRecovery.t.sol";

contract V2CallbackProxy is IPayable {
    uint256 public debtAmount;
    receive() external payable {}

    function debt(address) external view returns (uint256) {
        return debtAmount;
    }

    function setDebt(uint256 amount) external {
        debtAmount = amount;
    }

    function forward(SablierRecoveryExecutorV2 executor, address sender, bytes32 id, uint256 streamId, uint64 version)
        external
    {
        executor.recover(sender, id, streamId, version);
    }

    function requestPay(SablierRecoveryExecutorV2 executor, uint256 amount) external {
        executor.pay(amount);
    }
}

contract SablierRecoveryV2Test is Test {
    address constant PROXY = address(0x1001);
    address constant REACTIVE = address(0x1002);
    address constant OWNER = address(0x1003);
    address constant SENDER = address(0x1004);
    address constant OTHER = address(0x1005);

    RecoveryTestToken token;
    MockSablierLockup sablier;
    SablierRecoveryExecutorV2 executor;
    uint40 endTime;

    function setUp() public {
        token = new RecoveryTestToken();
        sablier = new MockSablierLockup(token);
        executor = new SablierRecoveryExecutorV2(IPayable(payable(PROXY)), REACTIVE, sablier);
        sablier.seed(1, SENDER, OWNER, 100, false);
        endTime = uint40(block.timestamp + 100);
        sablier.setEndTime(endTime);
        vm.deal(OWNER, 1 ether);
    }

    function _enroll(SablierRecoveryExecutorV2.Mode mode, uint256 cap, uint256 reserve) internal {
        vm.prank(OWNER);
        executor.enroll{value: reserve}(1, cap, mode);
    }

    function _recover(bytes32 id, uint64 version) internal {
        vm.prank(PROXY);
        executor.recover(REACTIVE, id, 1, version);
    }

    function testMaturityRequiresActualEndTimeAndPaysRecipientDirectly() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 1 ether, 0.1 ether);
        (,,,,, uint40 recordedEnd, SablierRecoveryExecutorV2.Mode mode,) = executor.policies(1);
        assertEq(recordedEnd, endTime);
        assertEq(uint8(mode), uint8(SablierRecoveryExecutorV2.Mode.Maturity));
        _recover(keccak256("early"), 1);
        assertEq(token.balanceOf(OWNER), 0);
        vm.warp(endTime);
        _recover(keccak256("mature"), 1);
        assertEq(token.balanceOf(OWNER), 100);
        assertEq(token.balanceOf(address(executor)), 0);
        assertEq(executor.feeCredits(OWNER), 0.1 ether);
        assertTrue(executor.recoveredEvents(keccak256("mature")));
        vm.prank(OWNER);
        executor.withdrawFeeCredit();
        assertEq(address(executor).balance, 0);
    }

    function testCancellationFirstInEitherModeAndDuplicateCallback() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Either, 0, 0);
        vm.prank(SENDER);
        sablier.cancel(1);
        _recover(keccak256("cancel"), 1);
        _recover(keccak256("cancel"), 1);
        assertEq(token.balanceOf(OWNER), 100);
        assertTrue(executor.recoveredEvents(keccak256("cancel")));
    }

    function testManualWithdrawalBeforeCallbackCompletesPolicy() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.1 ether);
        vm.warp(endTime);
        vm.prank(OWNER);
        sablier.manualWithdraw(1);
        _recover(keccak256("manual"), 1);
        (,,,,,,, bool active) = executor.policies(1);
        assertFalse(active);
        assertEq(executor.feeCredits(OWNER), 0.1 ether);
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testReenrollmentVersionRevocationAndStaleCallback() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.1 ether);
        vm.prank(OWNER);
        executor.revoke(1);
        vm.warp(endTime);
        _recover(keccak256("revoked"), 1);
        assertEq(token.balanceOf(OWNER), 0);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0);
        _recover(keccak256("old"), 1);
        assertEq(token.balanceOf(OWNER), 0);
        _recover(keccak256("new"), 2);
        assertEq(token.balanceOf(OWNER), 100);
        assertEq(executor.feeCredits(OWNER), 0.1 ether);
    }

    function testFeeCapReserveFailureAndRetry() public {
        sablier.setFee(0.02 ether);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0.01 ether, 0.01 ether);
        vm.warp(endTime);
        _recover(keccak256("fee high"), 1);
        assertEq(token.balanceOf(OWNER), 0);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0.03 ether, 0.01 ether);
        _recover(keccak256("reserve low"), 2);
        assertEq(token.balanceOf(OWNER), 0);
        vm.prank(OWNER);
        executor.addFeeReserve{value: 0.01 ether}(1);
        _recover(keccak256("retry"), 2);
        assertEq(token.balanceOf(OWNER), 100);
        assertEq(executor.feeCredits(OWNER), 0.01 ether);
        assertEq(address(executor).balance, 0.01 ether);
    }

    function testWithdrawalFailureCanRetryAndDoesNotConsumeReplayId() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0);
        vm.warp(endTime);
        sablier.setFailWithdraw(true);
        bytes32 id = keccak256("failure");
        _recover(id, 1);
        assertFalse(executor.recoveredEvents(id));
        sablier.setFailWithdraw(false);
        _recover(id, 1);
        assertTrue(executor.recoveredEvents(id));
    }

    function testAuthenticationEnrollmentAndOwnerChange() public {
        vm.prank(OTHER);
        vm.expectRevert(SablierRecoveryExecutorV2.UnauthorizedOwner.selector);
        executor.enroll(1, 0, SablierRecoveryExecutorV2.Mode.Maturity);
        sablier.seed(2, SENDER, OWNER, 10, true);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutorV2.TransferableStream.selector);
        executor.enroll(2, 0, SablierRecoveryExecutorV2.Mode.Maturity);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.1 ether);
        vm.warp(endTime);
        vm.prank(OTHER);
        vm.expectRevert();
        executor.recover(REACTIVE, keccak256("bad proxy"), 1, 1);
        vm.prank(PROXY);
        vm.expectRevert();
        executor.recover(OTHER, keccak256("bad sender"), 1, 1);
        sablier.setRecipient(1, OTHER);
        _recover(keccak256("changed"), 1);
        assertEq(token.balanceOf(OTHER), 0);
        assertEq(executor.feeCredits(OWNER), 0.1 ether);
    }

    function testCallbackReserveSeparateFromFeeReserve() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.1 ether);
        vm.expectRevert(SablierRecoveryExecutorV2.InsufficientCallbackReserve.selector);
        vm.prank(PROXY);
        executor.pay(1);
        executor.fundCallbackReserve{value: 0.01 ether}();
        assertEq(executor.callbackReserveWei(), 0.01 ether);
        assertEq(address(executor).balance, 0.11 ether);
    }

    function testCallbackReadsCurrentSablierEndTime() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0);
        sablier.setEndTime(endTime + 50);
        vm.warp(endTime);
        _recover(keccak256("old end"), 1);
        assertEq(token.balanceOf(OWNER), 0);
        vm.warp(endTime + 50);
        _recover(keccak256("new end"), 1);
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testMaturityAtUint40Boundary() public {
        vm.warp(type(uint40).max - 1);
        sablier.setEndTime(type(uint40).max);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0);
        _recover(keccak256("boundary early"), 1);
        assertEq(token.balanceOf(OWNER), 0);
        vm.warp(type(uint40).max);
        _recover(keccak256("boundary due"), 1);
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testNestedDirectCallbackCannotWithdrawTwice() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0);
        vm.warp(endTime);
        sablier.setReentry(
            address(executor), abi.encodeCall(executor.recover, (REACTIVE, keccak256("nested"), uint256(1), uint64(1)))
        );
        vm.prank(PROXY);
        executor.recover(REACTIVE, keccak256("outer"), 1, 1);
        assertTrue(sablier.reentryAttempted());
        assertFalse(sablier.reentrySucceeded());
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testDepletedEnrollmentRejectsValueWithoutPolicyOrReserve() public {
        vm.prank(OWNER);
        sablier.manualWithdraw(1);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutorV2.DepletedStream.selector);
        executor.enroll{value: 0.1 ether}(1, 0, SablierRecoveryExecutorV2.Mode.Either);
        (,, uint256 reserve, uint64 version,,,, bool active) = executor.policies(1);
        assertFalse(active);
        assertEq(version, 0);
        assertEq(reserve, 0);
        assertEq(executor.feeCredits(OWNER), 0);
        assertEq(address(executor).balance, 0);
    }

    function testAuthenticatedNestedCallbackHitsReentrancyGuard() public {
        V2CallbackProxy proxy = new V2CallbackProxy();
        executor = new SablierRecoveryExecutorV2(proxy, REACTIVE, sablier);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0);
        vm.warp(endTime);
        bytes32 nestedId = keccak256("authenticated nested");
        bytes32 outerId = keccak256("authenticated outer");
        sablier.setReentry(
            address(proxy), abi.encodeCall(proxy.forward, (executor, REACTIVE, nestedId, uint256(1), uint64(1)))
        );
        proxy.forward(executor, REACTIVE, outerId, 1, 1);
        assertTrue(sablier.reentryAttempted());
        assertFalse(sablier.reentrySucceeded());
        assertEq(bytes4(sablier.reentryReturnData()), SablierRecoveryExecutorV2.ReentrantCall.selector);
        assertTrue(executor.recoveredEvents(outerId));
        assertFalse(executor.recoveredEvents(nestedId));
        assertEq(token.balanceOf(OWNER), 100);
        assertTrue(sablier.isDepleted(1));
    }

    function testModeMatrixAcrossCancellationAndMaturityStates() public {
        // Every row uses a fresh stream so completion cannot affect another case.
        for (uint8 mode = 0; mode < 3; mode++) {
            for (uint8 state = 0; state < 4; state++) {
                uint256 id = 10 + uint256(mode) * 4 + state;
                sablier.seed(id, SENDER, OWNER, 100, false);
                vm.prank(OWNER);
                executor.enroll(id, 0, SablierRecoveryExecutorV2.Mode(mode));
                if (state == 1) {
                    vm.prank(SENDER);
                    sablier.cancel(id);
                }
                if (state >= 2) vm.warp(endTime);
                if (state == 3) {
                    vm.prank(SENDER);
                    sablier.cancel(id);
                }
                bytes32 eventId = keccak256(abi.encode(mode, state));
                uint256 beforeBalance = token.balanceOf(OWNER);
                vm.prank(PROXY);
                executor.recover(REACTIVE, eventId, id, 1);
                bool expected =
                    (mode == 0 && (state == 1 || state == 3)) || (mode == 1 && state >= 2) || (mode == 2 && state != 0);
                assertEq(executor.recoveredEvents(eventId), expected, "mode/state result");
                assertEq(token.balanceOf(OWNER) - beforeBalance, expected ? 100 : 0, "mode/state payout");
                // Restore the clock for the next active row.
                vm.warp(endTime - 100);
            }
        }
    }

    function testNonzeroFeeWithdrawalRevertRestoresReserveAndEmitsOnlySkip() public {
        sablier.setFee(0.02 ether);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0.02 ether, 0.03 ether);
        vm.warp(endTime);
        sablier.setFailWithdraw(true);
        bytes32 id = keccak256("fee revert");
        vm.recordLogs();
        _recover(id, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("RecoverySkipped(bytes32,uint256,uint64,uint8)"));
        assertEq(logs[0].topics[1], id);
        (uint64 version, SablierRecoveryExecutorV2.SkipReason reason) =
            abi.decode(logs[0].data, (uint64, SablierRecoveryExecutorV2.SkipReason));
        assertEq(version, 1);
        assertEq(uint8(reason), uint8(SablierRecoveryExecutorV2.SkipReason.WithdrawFailed));
        (,, uint256 reserve,,,,, bool active) = executor.policies(1);
        assertEq(reserve, 0.03 ether);
        assertTrue(active);
        assertEq(executor.feeCredits(OWNER), 0);
        assertFalse(executor.recoveredEvents(id));
        sablier.setFailWithdraw(false);
        _recover(id, 1);
        assertTrue(executor.recoveredEvents(id));
    }

    function testCallbackPaymentAndDebtCannotSpendUserReserveOrCredit() public {
        V2CallbackProxy proxy = new V2CallbackProxy();
        executor = new SablierRecoveryExecutorV2(proxy, REACTIVE, sablier);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.03 ether);
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.02 ether);
        assertEq(executor.feeCredits(OWNER), 0.03 ether);
        proxy.setDebt(1);
        vm.expectRevert(SablierRecoveryExecutorV2.InsufficientCallbackReserve.selector);
        proxy.requestPay(executor, 1);
        vm.expectRevert(SablierRecoveryExecutorV2.InsufficientCallbackReserve.selector);
        executor.coverCallbackDebt();
        executor.fundCallbackReserve{value: 0.01 ether}();
        proxy.requestPay(executor, 0.004 ether);
        proxy.setDebt(0.006 ether);
        executor.coverCallbackDebt();
        assertEq(executor.callbackReserveWei(), 0);
        assertEq(executor.feeCredits(OWNER), 0.03 ether);
        (,, uint256 reserve,,,,,) = executor.policies(1);
        assertEq(reserve, 0.02 ether);
        assertEq(address(executor).balance, 0.05 ether);
        proxy.setDebt(1);
        vm.expectRevert(SablierRecoveryExecutorV2.InsufficientCallbackReserve.selector);
        executor.coverCallbackDebt();
    }

    function testProtocolReadFailureRevertsCallbackAndRetainsEventId() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.01 ether);
        vm.warp(endTime);
        bytes32 id = keccak256("read failure");
        vm.mockCallRevert(address(sablier), abi.encodeCall(sablier.getEndTime, (uint256(1))), bytes("read failed"));
        vm.recordLogs();
        vm.expectRevert(bytes("read failed"));
        _recover(id, 1);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.clearMockedCalls();
        assertFalse(executor.recoveredEvents(id));
        assertEq(token.balanceOf(OWNER), 0);
        (,, uint256 reserve,,,,, bool active) = executor.policies(1);
        assertEq(reserve, 0.01 ether);
        assertTrue(active);
        _recover(id, 1);
        assertTrue(executor.recoveredEvents(id));
    }

    function testPostWithdrawalReadFailureRollsBackWithdrawalAndSuccess() public {
        _enroll(SablierRecoveryExecutorV2.Mode.Maturity, 0, 0.01 ether);
        vm.warp(endTime);
        sablier.setFailDepletedReadAfterWithdrawal(true);
        bytes32 id = keccak256("post withdrawal read failure");
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "depletion read failed"));
        _recover(id, 1);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token.balanceOf(OWNER), 0);
        assertFalse(sablier.isDepleted(1));
        assertFalse(executor.recoveredEvents(id));
        (,, uint256 reserve,,,,, bool active) = executor.policies(1);
        assertEq(reserve, 0.01 ether);
        assertTrue(active);
        sablier.setFailDepletedReadAfterWithdrawal(false);
        _recover(id, 1);
        assertEq(token.balanceOf(OWNER), 100);
        assertTrue(executor.recoveredEvents(id));
    }
}
