// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {DynamicCronControl} from "../src/demo/DynamicCronControl.sol";
import {DynamicCronProbe} from "../src/demo/DynamicCronProbe.sol";

contract DynamicCronSystem {
    error DuplicateSubscription();
    error MissingSubscription();
    error ForcedFailure();
    uint256 public subscriptions;
    uint256 public unsubscriptions;
    bytes public lastSubscription;
    bytes public lastUnsubscription;
    bool public failSubscribe;
    bool public failUnsubscribe;
    mapping(bytes32 => bool) public active;
    mapping(address => uint256) public debt;

    function key(uint256 a, address b, uint256 c, uint256 d, uint256 e, uint256 f) public pure returns (bytes32) {
        return keccak256(abi.encode(a, b, c, d, e, f));
    }

    function setFailures(bool subscribe_, bool unsubscribe_) external {
        failSubscribe = subscribe_;
        failUnsubscribe = unsubscribe_;
    }

    function subscribe(uint256 a, address b, uint256 c, uint256 d, uint256 e, uint256 f) external {
        if (failSubscribe) revert ForcedFailure();
        bytes32 filter = key(a, b, c, d, e, f);
        if (active[filter]) revert DuplicateSubscription();
        active[filter] = true;
        subscriptions++;
        lastSubscription = abi.encode(a, b, c, d, e, f);
    }

    function unsubscribe(uint256 a, address b, uint256 c, uint256 d, uint256 e, uint256 f) external {
        if (failUnsubscribe) revert ForcedFailure();
        bytes32 filter = key(a, b, c, d, e, f);
        if (!active[filter]) revert MissingSubscription();
        active[filter] = false;
        unsubscriptions++;
        lastUnsubscription = abi.encode(a, b, c, d, e, f);
    }

    receive() external payable {
        debt[msg.sender] -= msg.value;
    }
}

contract DynamicCronProbeTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    DynamicCronProbe probe;
    DynamicCronSystem sys;
    DynamicCronControl control;

    function setUp() public {
        DynamicCronSystem impl = new DynamicCronSystem();
        vm.etch(SYSTEM, address(impl).code);
        sys = DynamicCronSystem(payable(SYSTEM));
        control = new DynamicCronControl();
        probe = new DynamicCronProbe(address(control));
    }

    function originActive() internal view returns (bool) {
        return
            sys.active(
                sys.key(probe.BASE_CHAIN_ID(), address(control), probe.ACTIVATION_TOPIC(), IGNORE, IGNORE, IGNORE)
            );
    }

    function cronActive() internal view returns (bool) {
        return sys.active(
            sys.key(probe.LASNA_CHAIN_ID(), probe.CRON_EMITTER(), probe.CRON100_TOPIC(), IGNORE, IGNORE, IGNORE)
        );
    }

    function activationLog(uint256 nonce, uint256 sourceBlock, uint256 txh)
        internal
        view
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = probe.BASE_CHAIN_ID();
        r.contractAddress = address(control);
        r.topic0 = probe.ACTIVATION_TOPIC();
        r.data = abi.encode(nonce, sourceBlock);
        r.blockNumber = sourceBlock;
        r.opCode = 1;
        r.txHash = txh;
    }

    function recordedActivation(uint256 txh) internal returns (IReactive.LogRecord memory r) {
        vm.recordLogs();
        control.activate();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(control));
        assertEq(logs[0].topics.length, 1);
        assertEq(logs[0].topics[0], bytes32(probe.ACTIVATION_TOPIC()));
        assertEq(logs[0].data, abi.encode(control.nonce(), block.number));
        r = activationLog(control.nonce(), block.number, txh);
        r.contractAddress = logs[0].emitter;
        r.topic0 = uint256(logs[0].topics[0]);
        r.data = logs[0].data;
        r.opCode = logs[0].topics.length;
    }

    function log_(uint256 b, uint256 txh) internal view returns (IReactive.LogRecord memory r) {
        r.chainId = probe.LASNA_CHAIN_ID();
        r.contractAddress = probe.CRON_EMITTER();
        r.topic0 = probe.CRON100_TOPIC();
        r.topic1 = b;
        r.opCode = 2;
        r.blockNumber = b;
        r.txHash = txh;
        r.logIndex = 2;
    }

    function deliver(IReactive.LogRecord memory r) internal {
        vm.prank(SYSTEM);
        probe.react(r);
    }

    function testStartsInactiveAndAuthenticatedEnableSubscribesOnce() public {
        assertFalse(probe.subscriptionActive());
        assertEq(sys.subscriptions(), 1);
        assertTrue(originActive());
        assertFalse(cronActive());
        probe.enable();
        assertEq(sys.subscriptions(), 2);
        assertTrue(cronActive());
        assertTrue(probe.subscriptionActive());
        assertEq(
            sys.lastSubscription(),
            abi.encode(probe.LASNA_CHAIN_ID(), probe.CRON_EMITTER(), probe.CRON100_TOPIC(), IGNORE, IGNORE, IGNORE)
        );
    }

    function testUnauthorizedControlAndReactiveCallRejected() public {
        vm.expectRevert(DynamicCronProbe.OnlyOwner.selector);
        vm.prank(address(0xBAD));
        probe.enable();
        vm.expectRevert(DynamicCronProbe.OnlyOwner.selector);
        vm.prank(address(0xBAD));
        probe.emergencyShutdown();
        IReactive.LogRecord memory r = log_(9_200_000, 1);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(0xBAD), SYSTEM));
        vm.prank(address(0xBAD));
        probe.react(r);
    }

    function testMalformedCronIgnored() public {
        probe.enable();
        IReactive.LogRecord memory r = log_(9_200_000, 1);
        r.opCode = 1;
        deliver(r);
        r = log_(9_200_001, 2);
        deliver(r);
        r = log_(9_200_100, 3);
        r.topic2 = 1;
        deliver(r);
        r = log_(9_200_200, 4);
        r.data = abi.encode(uint256(1));
        deliver(r);
        r = log_(9_200_300, 0);
        deliver(r);
        assertEq(probe.uniqueDeliveries(), 0);
    }

    function testThreeUniqueDeliveriesUnsubscribeAndDuplicateDoesNotCount() public {
        probe.enable();
        IReactive.LogRecord memory a = log_(9_200_000, 1);
        deliver(a);
        deliver(a);
        deliver(log_(9_200_100, 2));
        deliver(log_(9_200_200, 3));
        assertEq(probe.uniqueDeliveries(), 3);
        assertFalse(probe.subscriptionActive());
        assertEq(sys.unsubscriptions(), 1);
        assertFalse(cronActive());
        assertTrue(originActive());
    }

    function testResubscribeDeliversAndUnsubscribesAgain() public {
        probe.enable();
        deliver(log_(9_200_000, 1));
        deliver(log_(9_200_100, 2));
        deliver(log_(9_200_200, 3));
        probe.enable();
        assertEq(probe.cycle(), 2);
        deliver(log_(9_200_300, 4));
        deliver(log_(9_200_400, 5));
        deliver(log_(9_200_500, 6));
        assertEq(probe.uniqueDeliveries(), 3);
        assertEq(sys.subscriptions(), 3);
        assertEq(sys.unsubscriptions(), 2);
        assertFalse(probe.subscriptionActive());
        assertFalse(cronActive());
        assertTrue(originActive());
    }

    function testPermanentShutdownUnsubscribesAndCannotReactivate() public {
        probe.enable();
        probe.emergencyShutdown();
        assertTrue(probe.shutdown());
        assertFalse(probe.subscriptionActive());
        assertEq(sys.unsubscriptions(), 2);
        assertFalse(originActive());
        assertFalse(cronActive());
        vm.expectRevert(DynamicCronProbe.PermanentlyShutdown.selector);
        probe.enable();
    }

    function testUnauthorizedOriginAndRecordedEvent() public {
        vm.expectRevert(DynamicCronControl.OnlyOwner.selector);
        vm.prank(address(0xBAD));
        control.activate();
        assertEq(control.nonce(), 0);
        IReactive.LogRecord memory r = recordedActivation(1);
        assertEq(r.opCode, 1);
        assertEq(r.data.length, 64);
        deliver(r);
        assertTrue(cronActive());
        assertEq(probe.lastActivationNonce(), 1);
    }

    function testTwoCyclesViaRecordedOriginEventsAndLimit() public {
        deliver(recordedActivation(11));
        assertEq(sys.subscriptions(), 2);
        deliver(log_(9_200_000, 101));
        deliver(log_(9_200_100, 102));
        deliver(log_(9_200_200, 103));
        assertFalse(cronActive());
        deliver(recordedActivation(12));
        assertTrue(cronActive());
        deliver(log_(9_200_300, 104));
        deliver(log_(9_200_400, 105));
        deliver(log_(9_200_500, 106));
        assertEq(probe.cycle(), 2);
        assertEq(sys.subscriptions(), 3);
        assertEq(sys.unsubscriptions(), 2);
        assertTrue(originActive());
        assertFalse(cronActive());
        vm.expectRevert(DynamicCronControl.ActivationLimitReached.selector);
        control.activate();
        vm.expectRevert(DynamicCronProbe.ActivationLimitReached.selector);
        probe.enable();
        deliver(activationLog(3, block.number, 13));
        assertEq(probe.lastActivationNonce(), 2);
        assertEq(probe.cycle(), 2);
    }

    function testDuplicateAndStaleActivationIgnored() public {
        IReactive.LogRecord memory first = recordedActivation(1);
        deliver(first);
        deliver(first);
        assertEq(probe.cycle(), 1);
        deliver(log_(9_200_000, 101));
        deliver(log_(9_200_100, 102));
        deliver(log_(9_200_200, 103));
        deliver(first);
        deliver(activationLog(0, block.number, 2));
        assertEq(probe.cycle(), 1);
        assertEq(probe.lastActivationNonce(), 1);
        assertFalse(cronActive());
    }

    function testInvalidActivationFieldsIgnored() public {
        IReactive.LogRecord memory r = activationLog(1, 123, 1);
        r.contractAddress = address(0xBAD);
        deliver(r);
        r = activationLog(1, 123, 1);
        r.chainId++;
        deliver(r);
        r = activationLog(1, 123, 1);
        r.opCode = 3;
        deliver(r);
        r = activationLog(1, 123, 1);
        r.topic0++;
        deliver(r);
        r = activationLog(1, 123, 1);
        r.topic1 = 1;
        deliver(r);
        r = activationLog(1, 123, 1);
        r.topic2 = 1;
        deliver(r);
        r = activationLog(1, 123, 1);
        r.topic3 = 1;
        deliver(r);
        r = activationLog(1, 123, 1);
        r.data = abi.encode(uint256(1));
        deliver(r);
        r = activationLog(1, 123, 1);
        r.blockNumber++;
        deliver(r);
        r = activationLog(1, 123, 1);
        r.txHash = 0;
        deliver(r);
        assertEq(probe.cycle(), 0);
        assertEq(probe.lastActivationNonce(), 0);
        assertEq(sys.subscriptions(), 1);
        assertTrue(originActive());
        assertFalse(cronActive());

        deliver(activationLog(1, 123, 1));
        assertEq(probe.cycle(), 1);
        assertEq(probe.lastActivationNonce(), 1);
        assertEq(sys.subscriptions(), 2);
        assertTrue(cronActive());
    }

    function testSubscribeFailureRollsBack() public {
        IReactive.LogRecord memory r = recordedActivation(1);
        sys.setFailures(true, false);
        vm.expectRevert(DynamicCronSystem.ForcedFailure.selector);
        deliver(r);
        assertEq(probe.cycle(), 0);
        assertEq(probe.lastActivationNonce(), 0);
        assertEq(sys.subscriptions(), 1);
        assertTrue(originActive());
        assertFalse(cronActive());
        sys.setFailures(false, false);
        deliver(r);
        assertEq(probe.cycle(), 1);
        assertTrue(cronActive());
    }

    function testUnsubscribeFailureRollsBack() public {
        deliver(recordedActivation(1));
        deliver(log_(9_200_000, 101));
        deliver(log_(9_200_100, 102));
        IReactive.LogRecord memory third = log_(9_200_200, 103);
        sys.setFailures(false, true);
        vm.expectRevert(DynamicCronSystem.ForcedFailure.selector);
        deliver(third);
        assertEq(probe.uniqueDeliveries(), 2);
        assertFalse(probe.observedLogs(keccak256(abi.encode(third.txHash, third.logIndex))));
        assertTrue(cronActive());
        assertEq(sys.unsubscriptions(), 0);
        sys.setFailures(false, false);
        deliver(third);
        assertEq(probe.uniqueDeliveries(), 3);
        assertFalse(cronActive());
    }

    function testShutdownInactiveAndDelayedActivation() public {
        IReactive.LogRecord memory delayed = recordedActivation(1);
        probe.emergencyShutdown();
        assertEq(sys.unsubscriptions(), 1);
        assertFalse(originActive());
        assertFalse(cronActive());
        deliver(delayed);
        assertEq(probe.cycle(), 0);
        assertEq(probe.lastActivationNonce(), 0);
    }

    function testShutdownActiveAndDelayedActivation() public {
        deliver(recordedActivation(1));
        IReactive.LogRecord memory delayed = recordedActivation(2);
        probe.emergencyShutdown();
        assertEq(sys.unsubscriptions(), 2);
        assertFalse(originActive());
        assertFalse(cronActive());
        deliver(delayed);
        deliver(log_(9_200_000, 101));
        assertEq(probe.cycle(), 1);
        assertEq(probe.lastActivationNonce(), 1);
        assertEq(probe.uniqueDeliveries(), 0);
    }

    function testShutdownUnsubscribeFailureRollsBack() public {
        deliver(recordedActivation(1));
        sys.setFailures(false, true);
        vm.expectRevert(DynamicCronSystem.ForcedFailure.selector);
        probe.emergencyShutdown();
        assertFalse(probe.shutdown());
        assertTrue(originActive());
        assertTrue(cronActive());
        assertEq(sys.unsubscriptions(), 0);
    }

    function testManualActivationCountsTowardLimit() public {
        probe.enable();
        deliver(log_(9_200_000, 101));
        deliver(log_(9_200_100, 102));
        deliver(log_(9_200_200, 103));
        deliver(recordedActivation(1));
        deliver(log_(9_200_300, 104));
        deliver(log_(9_200_400, 105));
        deliver(log_(9_200_500, 106));
        vm.expectRevert(DynamicCronProbe.ActivationLimitReached.selector);
        probe.enable();
        assertEq(probe.cycle(), 2);
        assertEq(sys.subscriptions(), 3);
        assertFalse(cronActive());
    }
}
