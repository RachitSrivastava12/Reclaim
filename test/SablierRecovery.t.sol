// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISablierLockup} from "../src/ISablierLockup.sol";
import {SablierRecoveryExecutor} from "../src/SablierRecoveryExecutor.sol";
import {SablierRecoveryReactive} from "../src/SablierRecoveryReactive.sol";

contract RecoveryTestToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockSablierLockup is ISablierLockup {
    struct Stream {
        address recipient;
        address sender;
        uint128 withdrawable;
        bool canceled;
        bool depleted;
        bool transferable;
    }
    mapping(uint256 => Stream) public streams;
    RecoveryTestToken public token;
    uint256 public fee;
    uint40 public endTime;
    bool public failWithdraw;
    bool public failDepletedReadAfterWithdrawal;
    address public reentryTarget;
    bytes public reentryPayload;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    constructor(RecoveryTestToken token_) {
        token = token_;
    }

    function seed(uint256 id, address sender, address recipient, uint128 amount, bool transferable_) external {
        streams[id] = Stream(recipient, sender, amount, false, false, transferable_);
        token.mint(address(this), amount);
    }

    function setFee(uint256 value) external {
        fee = value;
    }

    function setFailWithdraw(bool value) external {
        failWithdraw = value;
    }

    function setFailDepletedReadAfterWithdrawal(bool value) external {
        failDepletedReadAfterWithdrawal = value;
    }

    function setRecipient(uint256 id, address recipient) external {
        streams[id].recipient = recipient;
    }

    function setWithdrawable(uint256 id, uint128 amount) external {
        streams[id].withdrawable = amount;
    }

    function setReentry(address target, bytes calldata payload) external {
        reentryTarget = target;
        reentryPayload = payload;
    }

    function cancel(uint256 id) external {
        require(msg.sender == streams[id].sender, "sender");
        streams[id].canceled = true;
        emit CancelLockupStream(id, msg.sender, streams[id].recipient, address(token), 0, streams[id].withdrawable);
    }

    function manualWithdraw(uint256 id) external {
        require(msg.sender == streams[id].recipient, "recipient");
        uint128 amount = streams[id].withdrawable;
        streams[id].withdrawable = 0;
        streams[id].depleted = true;
        require(token.transfer(msg.sender, amount));
    }

    function withdraw(uint256 id, address to, uint128 amount) external payable {
        Stream storage stream = streams[id];
        require(!failWithdraw, "protocol revert");
        require((stream.canceled || (endTime != 0 && block.timestamp >= endTime)) && !stream.depleted, "state");
        require(to == stream.recipient, "wrong payout");
        require(msg.value >= fee, "fee");
        require(amount > 0 && amount <= stream.withdrawable, "amount");
        if (reentryTarget != address(0)) {
            reentryAttempted = true;
            (reentrySucceeded, reentryReturnData) = reentryTarget.call(reentryPayload);
        }
        stream.withdrawable -= amount;
        if (stream.withdrawable == 0) stream.depleted = true;
        require(token.transfer(to, amount));
    }

    function withdrawableAmountOf(uint256 id) external view returns (uint128) {
        return streams[id].withdrawable;
    }

    function getRecipient(uint256 id) external view returns (address) {
        return streams[id].recipient;
    }

    function getEndTime(uint256) external view returns (uint40) {
        return endTime;
    }

    function setEndTime(uint40 value) external {
        endTime = value;
    }

    function getUnderlyingToken(uint256) external view returns (address) {
        return address(token);
    }

    function wasCanceled(uint256 id) external view returns (bool) {
        return streams[id].canceled;
    }

    function isDepleted(uint256 id) external view returns (bool) {
        require(!(failDepletedReadAfterWithdrawal && streams[id].depleted), "depletion read failed");
        return streams[id].depleted;
    }

    function isTransferable(uint256 id) external view returns (bool) {
        return streams[id].transferable;
    }

    function calculateMinFeeWei(uint256) external view returns (uint256) {
        return fee;
    }
}

contract SablierRecoveryTest is Test {
    address constant PROXY = address(0x1001);
    address constant REACTIVE = address(0x1002);
    address constant OWNER = address(0x1003);
    address constant SENDER = address(0x1004);
    address constant OTHER = address(0x1005);
    bytes32 constant EVENT_ID = keccak256("cancel");

    RecoveryTestToken token;
    MockSablierLockup sablier;
    SablierRecoveryExecutor executor;

    function setUp() public {
        token = new RecoveryTestToken();
        sablier = new MockSablierLockup(token);
        executor = new SablierRecoveryExecutor(IPayable(payable(PROXY)), REACTIVE, sablier);
        sablier.seed(1, SENDER, OWNER, 100, false);
        vm.deal(OWNER, 1 ether);
        vm.deal(address(this), 1 ether);
    }

    function _enroll(uint256 feeCap, uint256 reserve) internal {
        vm.prank(OWNER);
        executor.enroll{value: reserve}(1, feeCap);
    }

    function _cancel() internal {
        vm.prank(SENDER);
        sablier.cancel(1);
    }

    function _recover(bytes32 id, uint64 version) internal {
        vm.prank(PROXY);
        executor.recover(REACTIVE, id, 1, version);
    }

    function testSuccessfulRecoveryPaysOwnerExactlyAndNeverExecutor() public {
        _enroll(0, 0);
        _cancel();
        _recover(EVENT_ID, 1);
        assertEq(token.balanceOf(OWNER), 100);
        assertEq(token.balanceOf(address(executor)), 0);
        assertEq(token.balanceOf(address(sablier)), 0);
        assertTrue(executor.recoveredEvents(EVENT_ID));
    }

    function testUnauthorizedEnrollmentAndTransferableStream() public {
        vm.prank(OTHER);
        vm.expectRevert(SablierRecoveryExecutor.UnauthorizedOwner.selector);
        executor.enroll(1, 0);
        sablier.seed(2, SENDER, OWNER, 10, true);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutor.TransferableStream.selector);
        executor.enroll(2, 0);
    }

    function testUnauthorizedRevocation() public {
        _enroll(0, 0);
        vm.prank(OTHER);
        vm.expectRevert(SablierRecoveryExecutor.UnauthorizedOwner.selector);
        executor.revoke(1);
    }

    function testRejectsWrongProxyAndReactiveSender() public {
        _enroll(0, 0);
        _cancel();
        vm.prank(OTHER);
        vm.expectRevert();
        executor.recover(REACTIVE, EVENT_ID, 1, 1);
        vm.prank(PROXY);
        vm.expectRevert();
        executor.recover(OTHER, EVENT_ID, 1, 1);
    }

    function testUnregisteredNonCanceledAndZeroBalance() public {
        _cancel();
        _recover(EVENT_ID, 0);
        assertFalse(executor.recoveredEvents(EVENT_ID));
        _enroll(0, 0);
        sablier.seed(1, SENDER, OWNER, 100, false);
        _recover(EVENT_ID, 1);
        assertFalse(executor.recoveredEvents(EVENT_ID));
        _cancel();
        vm.prank(OWNER);
        sablier.manualWithdraw(1);
        _recover(EVENT_ID, 1);
        assertFalse(executor.recoveredEvents(EVENT_ID));
        assertEq(token.balanceOf(address(executor)), 0);
    }

    function testDuplicateCallback() public {
        _enroll(0, 0);
        _cancel();
        _recover(EVENT_ID, 1);
        _recover(EVENT_ID, 1);
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testManualWithdrawalBeforeCallback() public {
        _enroll(0, 0);
        _cancel();
        vm.prank(OWNER);
        sablier.manualWithdraw(1);
        _recover(EVENT_ID, 1);
        assertFalse(executor.recoveredEvents(EVENT_ID));
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testZeroWithdrawableWithoutDepletionIsSkipped() public {
        _enroll(0, 0);
        _cancel();
        sablier.setWithdrawable(1, 0);
        _recover(EVENT_ID, 1);
        assertFalse(executor.recoveredEvents(EVENT_ID));
        assertEq(token.balanceOf(OWNER), 0);
    }

    function testOwnerChangeInvalidatesPolicyAndRefundsReserveToCredit() public {
        _enroll(1 ether, 0.1 ether);
        _cancel();
        sablier.setRecipient(1, OTHER);
        _recover(EVENT_ID, 1);
        (,,,,, bool active) = executor.policies(1);
        assertFalse(active);
        assertEq(executor.feeCredits(OWNER), 0.1 ether);
        sablier.setRecipient(1, OWNER);
        _recover(EVENT_ID, 1);
        assertEq(token.balanceOf(OWNER), 0);
    }

    function testRevocationBeforeCallbackAndReEnrollmentRejectsDelayedVersion() public {
        _enroll(1, 0);
        _cancel();
        vm.prank(OWNER);
        executor.revoke(1);
        _recover(EVENT_ID, 1);
        vm.prank(OWNER);
        executor.enroll(1, 0);
        _recover(EVENT_ID, 1);
        assertEq(token.balanceOf(OWNER), 0);
        _recover(keccak256("new policy"), 2);
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testExcessiveFeeAndInsufficientReserve() public {
        _enroll(2, 0);
        _cancel();
        sablier.setFee(3);
        _recover(EVENT_ID, 1);
        assertEq(token.balanceOf(OWNER), 0);
        sablier.setFee(2);
        _recover(EVENT_ID, 1);
        assertEq(token.balanceOf(OWNER), 0);
        vm.prank(OWNER);
        executor.addFeeReserve{value: 2}(1);
        _recover(EVENT_ID, 1);
        assertEq(token.balanceOf(OWNER), 100);
        assertEq(address(executor).balance, 0);
    }

    function testProtocolWithdrawalRevertDoesNotMarkSuccessOrSpendReserve() public {
        _enroll(2, 2);
        _cancel();
        sablier.setFee(2);
        sablier.setFailWithdraw(true);
        _recover(EVENT_ID, 1);
        assertFalse(executor.recoveredEvents(EVENT_ID));
        (,, uint256 reserve,,,) = executor.policies(1);
        assertEq(reserve, 2);
        sablier.setFailWithdraw(false);
        _recover(EVENT_ID, 1);
        assertTrue(executor.recoveredEvents(EVENT_ID));
    }

    function testOwnerRetryAndTopUpEmitFreshEventsButRevokedPolicyCannotRetry() public {
        _enroll(2, 0);
        vm.prank(OTHER);
        vm.expectRevert(SablierRecoveryExecutor.UnauthorizedOwner.selector);
        executor.requestRetry(1);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutor.EmptyRetry.selector);
        executor.addFeeReserve(1);
        vm.prank(OWNER);
        executor.addFeeReserve{value: 2}(1);
        vm.prank(OWNER);
        executor.requestRetry(1);
        (,,,, uint64 nonce, bool active) = executor.policies(1);
        assertEq(nonce, 2);
        assertTrue(active);
        vm.prank(OWNER);
        executor.revoke(1);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutor.UnauthorizedOwner.selector);
        executor.requestRetry(1);
    }

    function testChangedProtocolRecipientCannotRequestRetryOrTopUp() public {
        _enroll(2, 0);
        sablier.setRecipient(1, OTHER);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutor.UnauthorizedOwner.selector);
        executor.requestRetry(1);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutor.UnauthorizedOwner.selector);
        executor.addFeeReserve{value: 2}(1);
    }

    function testSuccessfulRecoveryCompletesPolicyAndCreditsUnusedFee() public {
        _enroll(10, 10);
        _cancel();
        sablier.setFee(2);
        _recover(EVENT_ID, 1);
        (,, uint256 reserve,,, bool active) = executor.policies(1);
        assertFalse(active);
        assertEq(reserve, 0);
        assertEq(executor.feeCredits(OWNER), 8);
        assertEq(address(executor).balance, 8);
        vm.prank(OWNER);
        vm.expectRevert(SablierRecoveryExecutor.UnauthorizedOwner.selector);
        executor.requestRetry(1);
        uint256 beforeBalance = OWNER.balance;
        vm.prank(OWNER);
        executor.withdrawFeeCredit();
        assertEq(OWNER.balance, beforeBalance + 8);
    }

    function testWithdrawalFailureCannotCompletePolicy() public {
        _enroll(10, 10);
        _cancel();
        sablier.setFee(2);
        sablier.setFailWithdraw(true);
        _recover(EVENT_ID, 1);
        (,, uint256 reserve,,, bool active) = executor.policies(1);
        assertTrue(active);
        assertEq(reserve, 10);
        assertEq(executor.feeCredits(OWNER), 0);
        assertFalse(executor.recoveredEvents(EVENT_ID));
    }

    function testReentrancyAttemptCannotRecoverTwice() public {
        _enroll(0, 0);
        _cancel();
        sablier.setReentry(address(executor), abi.encodeCall(executor.recover, (REACTIVE, EVENT_ID, 1, 1)));
        _recover(EVENT_ID, 1);
        assertTrue(sablier.reentryAttempted());
        assertFalse(sablier.reentrySucceeded());
        assertEq(token.balanceOf(OWNER), 100);
    }

    function testFeeCreditCanOnlyBeClaimedByOwner() public {
        _enroll(10, 10);
        vm.prank(OWNER);
        executor.revoke(1);
        vm.prank(OTHER);
        vm.expectRevert(SablierRecoveryExecutor.NoCredit.selector);
        executor.withdrawFeeCredit();
        uint256 beforeBalance = OWNER.balance;
        vm.prank(OWNER);
        executor.withdrawFeeCredit();
        assertEq(OWNER.balance, beforeBalance + 10);
    }

    function testCallbackProxyCannotSpendUserFeeReserve() public {
        _enroll(100, 100);
        vm.prank(PROXY);
        vm.expectRevert(SablierRecoveryExecutor.InsufficientCallbackReserve.selector);
        executor.pay(1);
        executor.fundCallbackReserve{value: 3}();
        vm.prank(PROXY);
        executor.pay(2);
        (,, uint256 feeReserve,,,) = executor.policies(1);
        assertEq(feeReserve, 100);
        assertEq(executor.callbackReserveWei(), 1);
    }

    function testCallbackDebtSettlementUsesOnlyOperatorReserve() public {
        _enroll(100, 100);
        vm.mockCall(PROXY, abi.encodeWithSelector(IPayable.debt.selector, address(executor)), abi.encode(2));
        vm.expectRevert(SablierRecoveryExecutor.InsufficientCallbackReserve.selector);
        executor.coverCallbackDebt();
        executor.fundCallbackReserve{value: 3}();
        executor.coverCallbackDebt();
        assertEq(executor.callbackReserveWei(), 1);
        (,, uint256 reserve,,,) = executor.policies(1);
        assertEq(reserve, 100);
    }
}

contract SablierRecoveryReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant SABLIER = address(0x3001);
    address constant EXECUTOR = address(0x3002);
    address constant OWNER = address(0x3003);
    SablierRecoveryReactive coordinator;

    function setUp() public {
        vm.etch(SYSTEM, hex"00");
        coordinator = new SablierRecoveryReactive(SABLIER);
        coordinator.setDestination(EXECUTOR);
    }

    function _log(address source, uint256 topic, uint256 topic1, uint256 topic2, uint256 topic3, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory record)
    {
        record.chainId = 84532;
        record.contractAddress = source;
        record.topic0 = topic;
        record.topic1 = topic1;
        record.topic2 = topic2;
        record.topic3 = topic3;
        record.data = data;
        record.blockNumber = 100;
        record.opCode = topic3 == 0 ? 3 : 4;
        record.txHash = 123;
        record.logIndex = 1;
    }

    function _react(IReactive.LogRecord memory record) internal {
        vm.prank(SYSTEM);
        coordinator.react(record);
    }

    function testEnrollmentAndCancellationRequest() public {
        vm.recordLogs();
        _react(
            _log(
                EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
            )
        );
        Vm.Log[] memory enrollmentLogs = vm.getRecordedLogs();
        assertEq(enrollmentLogs.length, 1);
        assertEq(enrollmentLogs[0].topics[0], keccak256("RecoveryRequested(bytes32,uint256,uint64)"));
        (address owner, uint64 version,,, bool active) = coordinator.mirrors(1);
        assertEq(owner, OWNER);
        assertEq(version, 1);
        assertTrue(active);
        IReactive.LogRecord memory canceled = _log(
            SABLIER,
            coordinator.CANCEL_TOPIC(),
            uint256(uint160(address(0xA))),
            uint256(uint160(OWNER)),
            uint256(uint160(address(0xB))),
            abi.encode(uint256(1), uint128(50), uint128(50))
        );
        canceled.logIndex = 2;
        vm.recordLogs();
        _react(canceled);
        Vm.Log[] memory cancellationLogs = vm.getRecordedLogs();
        assertEq(cancellationLogs.length, 1);
        assertEq(cancellationLogs[0].topics[0], keccak256("RecoveryRequested(bytes32,uint256,uint64)"));
        vm.recordLogs();
        _react(canceled);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testRetryRequiresCurrentActiveMirrorAndHasDistinctEventId() public {
        _react(
            _log(
                EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
            )
        );
        IReactive.LogRecord memory retry =
            _log(EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint64(1)));
        retry.logIndex = 2;
        vm.recordLogs();
        _react(retry);
        Vm.Log[] memory first = vm.getRecordedLogs();
        assertEq(first.length, 1);
        bytes32 firstId = first[0].topics[1];
        vm.recordLogs();
        _react(retry);
        assertEq(vm.getRecordedLogs().length, 0);
        retry.logIndex = 3;
        retry.data = abi.encode(uint64(1), uint64(2));
        vm.recordLogs();
        _react(retry);
        Vm.Log[] memory second = vm.getRecordedLogs();
        assertEq(second.length, 1);
        assertTrue(second[0].topics[1] != firstId);
        retry.logIndex = 4;
        retry.data = abi.encode(uint64(0), uint64(3));
        vm.recordLogs();
        _react(retry);
        assertEq(vm.getRecordedLogs().length, 0);
        retry.data = abi.encode(uint64(2), uint64(3));
        vm.recordLogs();
        _react(retry);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testCallbackRequestFailureCanBeDeliveredAgain() public {
        IReactive.LogRecord memory enrolled = _log(
            EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
        );
        vm.mockCallRevert(
            SYSTEM, abi.encodeWithSignature("requestCallbackV_1_0((uint256,address,uint64,bytes))"), hex"dead"
        );
        vm.prank(SYSTEM);
        vm.expectRevert();
        coordinator.react(enrolled);
        vm.clearMockedCalls();
        vm.recordLogs();
        _react(enrolled);
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function testCompletionAndStaleCancellationLeaveMirrorInactive() public {
        _react(
            _log(
                EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
            )
        );
        IReactive.LogRecord memory completion =
            _log(EXECUTOR, coordinator.COMPLETED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1)));
        completion.logIndex = 3;
        _react(completion);
        (,,,, bool active) = coordinator.mirrors(1);
        assertFalse(active);
        IReactive.LogRecord memory canceled = _log(
            SABLIER,
            coordinator.CANCEL_TOPIC(),
            uint256(uint160(address(0xA))),
            uint256(uint160(OWNER)),
            uint256(uint160(address(0xB))),
            abi.encode(uint256(1), uint128(50), uint128(50))
        );
        canceled.logIndex = 2;
        vm.recordLogs();
        _react(canceled);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testCancellationArrivingBeforeEnrollmentIsCoveredByEnrollmentCallback() public {
        IReactive.LogRecord memory canceled = _log(
            SABLIER,
            coordinator.CANCEL_TOPIC(),
            uint256(uint160(address(0xA))),
            uint256(uint160(OWNER)),
            uint256(uint160(address(0xB))),
            abi.encode(uint256(1), uint128(50), uint128(50))
        );
        canceled.blockNumber = 101;
        vm.recordLogs();
        _react(canceled);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.recordLogs();
        _react(
            _log(
                EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
            )
        );
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function testOutOfOrderRevocationLeavesTombstone() public {
        IReactive.LogRecord memory revoked =
            _log(EXECUTOR, coordinator.REVOKED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1)));
        revoked.blockNumber = 101;
        vm.recordLogs();
        _react(revoked);
        assertEq(vm.getRecordedLogs().length, 0);
        _react(
            _log(
                EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
            )
        );
        (,, uint256 lastBlock,, bool active) = coordinator.mirrors(1);
        assertEq(lastBlock, 101);
        assertFalse(active);
    }

    function testMalformedDataWrongSourceAndRevocation() public {
        IReactive.LogRecord memory bad =
            _log(SABLIER, coordinator.CANCEL_TOPIC(), 1, uint256(uint160(OWNER)), 2, hex"1234");
        _react(bad);
        bad.data = abi.encode(uint256(1), uint256(0), uint256(10));
        bad.contractAddress = address(0xBAD);
        _react(bad);
        (,,,, bool active) = coordinator.mirrors(1);
        assertFalse(active);
        _react(
            _log(
                EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
            )
        );
        IReactive.LogRecord memory revoked =
            _log(EXECUTOR, coordinator.REVOKED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1)));
        revoked.logIndex = 2;
        _react(revoked);
        (,,,, active) = coordinator.mirrors(1);
        assertFalse(active);
        IReactive.LogRecord memory oldEnroll = _log(
            EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
        );
        _react(oldEnroll);
        (,,,, active) = coordinator.mirrors(1);
        assertFalse(active);
    }

    function testWrongChainAndMalformedCancellationDoNotRequest() public {
        _react(
            _log(
                EXECUTOR, coordinator.ENROLLED_TOPIC(), 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0))
            )
        );
        IReactive.LogRecord memory canceled = _log(
            SABLIER,
            coordinator.CANCEL_TOPIC(),
            uint256(uint160(address(0xA))),
            uint256(uint160(OWNER)),
            uint256(uint160(address(0xB))),
            hex"1234"
        );
        vm.recordLogs();
        _react(canceled);
        assertEq(vm.getRecordedLogs().length, 0);
        canceled.data = abi.encode(uint256(1), uint256(0), uint256(10));
        canceled.chainId = 1;
        vm.recordLogs();
        _react(canceled);
        assertEq(vm.getRecordedLogs().length, 0);
        canceled.chainId = 84532;
        canceled.contractAddress = address(0xBAD);
        vm.recordLogs();
        _react(canceled);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testRejectsDirectReactCall() public {
        uint256 topic = coordinator.ENROLLED_TOPIC();
        IReactive.LogRecord memory record =
            _log(EXECUTOR, topic, 1, uint256(uint160(OWNER)), 0, abi.encode(uint64(1), uint256(0)));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        coordinator.react(record);
    }

    function testDestinationCanOnlyBeConfiguredOnceByOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(SablierRecoveryReactive.OnlyOwner.selector);
        coordinator.setDestination(address(0xBAD));
        vm.expectRevert(SablierRecoveryReactive.DestinationAlreadySet.selector);
        coordinator.setDestination(address(0xBAD));
    }
}
