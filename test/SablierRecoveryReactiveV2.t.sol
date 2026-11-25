// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {SablierRecoveryReactiveV2} from "../src/SablierRecoveryReactiveV2.sol";
import {SablierRecoveryExecutorV2} from "../src/SablierRecoveryExecutorV2.sol";
import {MockSablierLockup, RecoveryTestToken} from "./SablierRecovery.t.sol";

contract MockSchedulerSystem {
    uint256 public subscriptions;
    uint256 public requests;
    uint256 public chainId;
    address public recipient;
    uint64 public gasLimit;
    bytes public payload;
    bool public failRequest;
    uint256 public failStreamId;
    uint256 public unsubscriptions;
    bytes32 public lastUnsubscribe;
    bytes32 public subscriptionDigest;
    bytes32 public unsubscriptionDigest;
    mapping(address => uint256) public debt;

    function subscribe(uint256 chain, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subscriptions++;
        subscriptionDigest = keccak256(abi.encode(subscriptionDigest, chain, emitter, t0, t1, t2, t3));
    }

    function unsubscribe(uint256 chain, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        unsubscriptions++;
        lastUnsubscribe = keccak256(abi.encode(chain, emitter, t0, t1, t2, t3));
        unsubscriptionDigest = keccak256(abi.encode(unsubscriptionDigest, chain, emitter, t0, t1, t2, t3));
    }

    function requestCallbackV_1_0(CallbackConfiguration calldata c) external {
        (,, uint256 id,) = abi.decode(c.payload[4:], (address, bytes32, uint256, uint64));
        require(!failRequest && id != failStreamId, "callback request failed");
        requests++;
        chainId = c.chainId;
        recipient = c.recipient;
        gasLimit = c.gasLimit;
        payload = c.payload;
    }

    struct CallbackConfiguration {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    function setFailRequest(bool value) external {
        failRequest = value;
    }

    function setFailStreamId(uint256 id) external {
        failStreamId = id;
    }

    receive() external payable {
        debt[msg.sender] -= msg.value;
    }
}

contract SchedulerProxy is IPayable {
    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function forward(SablierRecoveryExecutorV2 executor, address sender, bytes32 eventId, uint256 id, uint64 version)
        external
    {
        executor.recover(sender, eventId, id, version);
    }
}

contract SablierRecoveryReactiveV2Test is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant SABLIER = address(0x1111);
    address constant EXECUTOR = address(0x2222);
    address constant ALICE = address(0x3333);
    SablierRecoveryReactiveV2 coordinator;
    MockSchedulerSystem system;
    uint256 nonce;

    function setUp() public {
        MockSchedulerSystem implementation = new MockSchedulerSystem();
        vm.etch(SYSTEM, address(implementation).code);
        system = MockSchedulerSystem(payable(SYSTEM));
        coordinator = new SablierRecoveryReactiveV2(SABLIER);
        coordinator.setDestination(EXECUTOR);
        coordinator.setCallbackBudget(256);
        vm.warp(1_000_000);
    }

    function _base(
        address emitter,
        uint256 topic0,
        uint256 t1,
        uint256 t2,
        uint256 t3,
        bytes memory data,
        uint256 opcode
    ) internal pure returns (IReactive.LogRecord memory r) {
        r.chainId = 84532;
        r.contractAddress = emitter;
        r.topic0 = topic0;
        r.topic1 = t1;
        r.topic2 = t2;
        r.topic3 = t3;
        r.data = data;
        r.opCode = opcode;
        r.blockNumber = 123;
        r.txHash = 555;
        r.logIndex = 1;
    }

    function _deliver(IReactive.LogRecord memory r) internal {
        vm.prank(SYSTEM);
        coordinator.react(r);
    }

    function _enroll(uint256 id, uint64 version, uint40 endTime, uint8 mode) internal {
        coordinator.setStreamAllowed(id, true);
        _deliver(
            _base(
                EXECUTOR,
                coordinator.ENROLLED_TOPIC(),
                id,
                uint256(uint160(ALICE)),
                0,
                abi.encode(version, uint256(0), endTime, mode),
                3
            )
        );
    }

    function _cancel(uint256 id) internal {
        _deliver(
            _base(
                SABLIER,
                coordinator.CANCEL_TOPIC(),
                uint256(uint160(address(0x4444))),
                uint256(uint160(ALICE)),
                uint256(uint160(address(0x5555))),
                abi.encode(id, uint128(0), uint128(10)),
                4
            )
        );
    }

    function _cron() internal {
        nonce++;
        IReactive.LogRecord memory r;
        r.chainId = coordinator.LASNA();
        r.contractAddress = coordinator.CRON_EMITTER();
        r.topic0 = coordinator.CRON_TOPIC();
        r.topic1 = (9_000_000 + nonce * 100);
        r.blockNumber = r.topic1;
        r.opCode = 2;
        r.txHash = nonce;
        r.logIndex = 2;
        _deliver(r);
    }

    function _state(uint256 id)
        internal
        view
        returns (SablierRecoveryReactiveV2.State s, bytes32 pending, uint8 attempts)
    {
        (,,,,,, attempts, s, pending,) = coordinator.policies(id);
    }

    function testSubscriptionsAndDirectCallForbidden() public {
        assertEq(system.subscriptions(), 8);
        IReactive.LogRecord memory r = _base(
            EXECUTOR,
            coordinator.ENROLLED_TOPIC(),
            1,
            uint256(uint160(ALICE)),
            0,
            abi.encode(uint64(1), uint256(0), uint40(1_000_100), uint8(1)),
            3
        );
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        coordinator.react(r);
        assertEq(coordinator.activeCount(), 0);
    }

    function testMalformedAndInvalidSourceIgnored() public {
        IReactive.LogRecord memory r = _base(
            EXECUTOR,
            coordinator.ENROLLED_TOPIC(),
            1,
            uint256(uint160(ALICE)),
            0,
            abi.encode(uint256(1), uint256(0), uint256(1_000_100), uint256(1)),
            3
        );
        r.chainId = 1;
        _deliver(r);
        r.chainId = 84532;
        r.contractAddress = SABLIER;
        _deliver(r);
        r.contractAddress = EXECUTOR;
        r.opCode = 4;
        _deliver(r);
        r.opCode = 3;
        r.topic3 = 1;
        _deliver(r);
        r.topic3 = 0;
        r.data = hex"00";
        _deliver(r);
        r.data = abi.encode(uint256(type(uint64).max) + 1, uint256(0), uint256(1_000_100), uint256(1));
        _deliver(r);
        r.data = abi.encode(uint256(1), uint256(0), uint256(1_000_100), uint256(3));
        _deliver(r);
        assertEq(coordinator.activeCount(), 0);
        _enroll(1, 1, 1_000_100, 1);
        assertEq(coordinator.activeCount(), 1);
    }

    function testEnrollmentParsesFeeCapDeadlineAndMode() public {
        coordinator.setStreamAllowed(1, true);
        _deliver(
            _base(
                EXECUTOR,
                coordinator.ENROLLED_TOPIC(),
                1,
                uint256(uint160(ALICE)),
                0,
                abi.encode(uint64(1), uint256(123456), uint40(1_500_000), uint8(2)),
                3
            )
        );
        assertEq(coordinator.maxFeeWei(1), 123456);
        (,,, uint40 endTime,, uint8 mode,,,,) = coordinator.policies(1);
        assertEq(endTime, 1_500_000);
        assertEq(mode, 2);
        assertEq(coordinator.heapHead(), 1);
    }

    function testMalformedCronAndCancellationIgnored() public {
        IReactive.LogRecord memory tick;
        tick.chainId = coordinator.LASNA();
        tick.contractAddress = coordinator.CRON_EMITTER();
        tick.topic0 = coordinator.CRON_TOPIC();
        tick.topic1 = 9_200_000;
        tick.blockNumber = tick.topic1;
        tick.opCode = 2;
        tick.txHash = 888;
        tick.logIndex = 2;
        tick.data = abi.encode(uint256(1));
        _deliver(tick);
        tick.data = "";
        tick.topic2 = 1;
        _deliver(tick);
        tick.topic2 = 0;
        tick.blockNumber++;
        _deliver(tick);
        tick.blockNumber--;
        tick.opCode = 3;
        _deliver(tick);
        assertEq(coordinator.lastCronBlock(), 0);

        IReactive.LogRecord memory cancelLog = _base(
            SABLIER,
            coordinator.CANCEL_TOPIC(),
            uint256(uint160(address(0x4444))),
            uint256(uint160(ALICE)),
            uint256(uint160(address(0x5555))),
            abi.encode(uint256(1), uint128(0), uint128(10)),
            4
        );
        cancelLog.opCode = 3;
        _deliver(cancelLog);
        cancelLog.opCode = 4;
        cancelLog.data = abi.encode(uint256(1), uint128(0), uint128(0));
        _deliver(cancelLog);
        cancelLog.data = abi.encode(uint256(1), uint128(0), uint128(10));
        cancelLog.chainId = 1;
        _deliver(cancelLog);
        (address recipient,,) = coordinator.cancellations(1);
        assertEq(recipient, address(0));
    }

    function testMaturityBufferDuplicateCronAndMissingAcknowledgement() public {
        _enroll(1, 1, 1_000_100, 1);
        vm.warp(1_000_219);
        _cron();
        assertEq(system.requests(), 0);
        vm.warp(1_000_220);
        _cron();
        assertEq(system.requests(), 1);
        assertEq(system.chainId(), 84532);
        assertEq(system.recipient(), EXECUTOR);
        assertEq(system.gasLimit(), 600_000);
        (, bytes32 id,) = _state(1);
        assertEq(system.payload(), abi.encodeCall(SablierRecoveryExecutorV2.recover, (address(0), id, 1, 1)));
        _cron();
        assertEq(system.requests(), 1);
        vm.warp(1_000_819);
        _cron();
        assertEq(system.requests(), 1);
        vm.warp(1_000_820);
        _cron();
        assertEq(system.requests(), 2);
        (, bytes32 fresh,) = _state(1);
        assertTrue(fresh != id);
    }

    function testCancellationBeforeEnrollmentAndModeIsolation() public {
        _cancel(1);
        _enroll(1, 1, 1_500_000, 0);
        _enroll(2, 1, 1_500_000, 0);
        _enroll(3, 1, 1_500_000, 1);
        assertEq(coordinator.heapSize(), 2);
        _cron();
        assertEq(system.requests(), 1);
        assertEq(uint8(_stateOnly(2)), uint8(SablierRecoveryReactiveV2.State.Dormant));
        _cancel(2);
        _cron();
        assertEq(system.requests(), 2);
        assertEq(coordinator.heapSize(), 3); // maturity plus two pending timeouts
    }

    function _stateOnly(uint256 id) internal view returns (SablierRecoveryReactiveV2.State s) {
        (s,,) = _state(id);
    }

    function testCapacityBacklogFairnessAndNoUnboundedTick() public {
        for (uint256 i = 1; i <= 64; i++) _enroll(i, 1, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 64);
        assertEq(coordinator.heapSize(), 64);
        _enroll(65, 1, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 64);
        vm.warp(1_000_121);
        _cron();
        assertEq(system.requests(), 3);
        _cron();
        assertEq(system.requests(), 6);
        _cron();
        assertEq(system.requests(), 9);
        _cron();
        assertEq(system.requests(), 12);
        assertEq(coordinator.heapSize(), 64);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Pending));
        assertEq(uint8(_stateOnly(12)), uint8(SablierRecoveryReactiveV2.State.Pending));
        assertEq(uint8(_stateOnly(13)), uint8(SablierRecoveryReactiveV2.State.Scheduled));
    }

    function testSkipCooldownRetryNonceAndTerminalEvents() public {
        _enroll(1, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        _cron();
        (, bytes32 id,) = _state(1);
        _deliver(_base(EXECUTOR, coordinator.SKIPPED_TOPIC(), uint256(id), 1, 0, abi.encode(uint64(1), uint8(8)), 3));
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Retryable));
        _cron();
        assertEq(system.requests(), 1);
        vm.warp(1_000_421);
        _cron();
        assertEq(system.requests(), 2);
        _deliver(_base(EXECUTOR, coordinator.REVOKED_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1)), 3));
        assertEq(coordinator.activeCount(), 0);
        assertEq(coordinator.heapSize(), 0);
        _enroll(1, 1, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 0);
        _enroll(1, 2, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 1);
    }

    function testSuccessCompletionOrderingAndStaleOutcome() public {
        _enroll(1, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        _cron();
        (, bytes32 id,) = _state(1);
        _deliver(
            _base(
                EXECUTOR,
                coordinator.SUCCEEDED_TOPIC(),
                uint256(id),
                1,
                uint256(uint160(ALICE)),
                abi.encode(uint256(uint160(address(0x5555))), uint128(10), uint256(0)),
                4
            )
        );
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Acknowledged));
        _deliver(
            _base(EXECUTOR, coordinator.COMPLETED_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1)), 3)
        );
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Completed));
        assertEq(coordinator.activeCount(), 0);
        _deliver(
            _base(
                EXECUTOR,
                coordinator.SUCCEEDED_TOPIC(),
                uint256(id),
                1,
                uint256(uint160(ALICE)),
                abi.encode(uint256(uint160(address(0x5555))), uint128(10), uint256(0)),
                4
            )
        );
        assertEq(coordinator.heapSize(), 0);
    }

    function testTerminalBeforeEnrollmentAndMaxAttempts() public {
        _deliver(
            _base(EXECUTOR, coordinator.COMPLETED_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1)), 3)
        );
        _enroll(1, 1, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 0);
        _enroll(2, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        for (uint256 i; i < 5; i++) {
            _cron();
            vm.warp(block.timestamp + 600);
        }
        _cron();
        assertEq(system.requests(), 5);
        assertEq(uint8(_stateOnly(2)), uint8(SablierRecoveryReactiveV2.State.Exhausted));
        assertEq(coordinator.heapSize(), 0);
    }

    function testPauseKeepsSubscriptionAndCatchesUp() public {
        _enroll(1, 1, 1_000_001, 1);
        coordinator.setPaused(true);
        vm.warp(1_001_000);
        _cron();
        assertEq(system.requests(), 0);
        assertEq(system.subscriptions(), 8);
        coordinator.setPaused(false);
        _cron();
        assertEq(system.requests(), 1);
    }

    function testTransientSkipReasonsRetryAndTerminalReasonStops() public {
        uint8[5] memory reasons = [uint8(5), 7, 8, 9, 10];
        for (uint256 i; i < reasons.length; i++) {
            uint256 streamId = i + 1;
            _enroll(streamId, 1, 1_000_001, 1);
        }
        vm.warp(1_000_121);
        _cron();
        _cron();
        for (uint256 i; i < reasons.length; i++) {
            uint256 streamId = i + 1;
            (, bytes32 id,) = _state(streamId);
            _deliver(
                _base(
                    EXECUTOR,
                    coordinator.SKIPPED_TOPIC(),
                    uint256(id),
                    streamId,
                    0,
                    abi.encode(uint64(1), reasons[i]),
                    3
                )
            );
            assertEq(uint8(_stateOnly(streamId)), uint8(SablierRecoveryReactiveV2.State.Retryable));
        }
        vm.warp(block.timestamp + 300);
        _cron();
        assertEq(system.requests(), 8);
        (, bytes32 pending,) = _state(1);
        _deliver(
            _base(EXECUTOR, coordinator.SKIPPED_TOPIC(), uint256(pending), 1, 0, abi.encode(uint64(1), uint8(3)), 3)
        );
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.TerminalPending));
        _deliver(
            _base(
                EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1), uint64(1)), 3
            )
        );
        assertGt(coordinator.heapIndex(1), 0);
    }

    function testWrongOutcomeIdVersionAndShapeDoNotAcknowledge() public {
        _enroll(1, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        _cron();
        (, bytes32 id,) = _state(1);
        IReactive.LogRecord memory r =
            _base(EXECUTOR, coordinator.SKIPPED_TOPIC(), uint256(id), 1, 0, abi.encode(uint64(1), uint8(8)), 3);
        r.topic1 = uint256(keccak256("stale"));
        _deliver(r);
        r.topic1 = uint256(id);
        r.data = abi.encode(uint64(2), uint8(8));
        _deliver(r);
        r.data = abi.encode(uint64(1), uint256(11));
        _deliver(r);
        r.data = hex"11";
        _deliver(r);
        r.data = abi.encode(uint64(1), uint8(8));
        r.opCode = 4;
        _deliver(r);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Pending));
        assertEq(coordinator.heapSize(), 1);
    }

    function testOwnerRetryRespectsCooldownAndPending() public {
        _enroll(1, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        _cron();
        _deliver(
            _base(
                EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1), uint64(1)), 3
            )
        );
        _cron();
        assertEq(system.requests(), 1);
        (, bytes32 id,) = _state(1);
        _deliver(_base(EXECUTOR, coordinator.SKIPPED_TOPIC(), uint256(id), 1, 0, abi.encode(uint64(1), uint8(9)), 3));
        _deliver(
            _base(
                EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1), uint64(2)), 3
            )
        );
        _cron();
        assertEq(system.requests(), 1);
        vm.warp(block.timestamp + 300);
        _cron();
        assertEq(system.requests(), 2);
    }

    function testCallbackRequestRevertLeavesTickRetryable() public {
        _enroll(1, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        system.setFailRequest(true);
        IReactive.LogRecord memory tick;
        tick.chainId = coordinator.LASNA();
        tick.contractAddress = coordinator.CRON_EMITTER();
        tick.topic0 = coordinator.CRON_TOPIC();
        tick.topic1 = 9_200_000;
        tick.blockNumber = tick.topic1;
        tick.opCode = 2;
        tick.txHash = 888;
        tick.logIndex = 2;
        vm.prank(SYSTEM);
        coordinator.react(tick);
        assertEq(coordinator.heapSize(), 1);
        assertEq(coordinator.lifetimeAttempts(1), 0);
        assertTrue(coordinator.observedCron(keccak256(abi.encode(uint256(888), uint256(2)))));
        system.setFailRequest(false);
        vm.warp(block.timestamp + 300);
        _cron();
        assertEq(system.requests(), 1);
    }

    function testReenrollmentCannotResetLifetimeBudget() public {
        vm.warp(1_000_121);
        for (uint64 version = 1; version <= 2; version++) {
            _enroll(1, version, 1_000_001, 1);
            for (uint256 i; i < 5; i++) {
                _cron();
                vm.warp(block.timestamp + 600);
            }
            _cron(); // retire the fifth pending attempt
        }
        assertEq(system.requests(), 10);
        assertEq(coordinator.lifetimeAttempts(1), 10);
        _enroll(1, 3, 1_000_001, 1);
        _cron();
        assertEq(system.requests(), 10);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Exhausted));
    }

    function testIntegratedExecutorEventFlow() public {
        RecoveryTestToken token = new RecoveryTestToken();
        MockSablierLockup sablier = new MockSablierLockup(token);
        SchedulerProxy proxy = new SchedulerProxy();
        SablierRecoveryReactiveV2 liveCoordinator = new SablierRecoveryReactiveV2(address(sablier));
        SablierRecoveryExecutorV2 executor = new SablierRecoveryExecutorV2(proxy, address(liveCoordinator), sablier);
        liveCoordinator.setDestination(address(executor));
        liveCoordinator.setStreamAllowed(7, true);
        liveCoordinator.setCallbackBudget(1);
        sablier.seed(7, address(0x4444), ALICE, 100, false);
        sablier.setEndTime(uint40(block.timestamp + 100));
        vm.recordLogs();
        vm.prank(ALICE);
        executor.enroll(7, 0, SablierRecoveryExecutorV2.Mode.Maturity);
        _relay(vm.getRecordedLogs(), liveCoordinator, address(executor), 200);
        vm.warp(block.timestamp + 220);
        IReactive.LogRecord memory tick;
        tick.chainId = liveCoordinator.LASNA();
        tick.contractAddress = liveCoordinator.CRON_EMITTER();
        tick.topic0 = liveCoordinator.CRON_TOPIC();
        tick.topic1 = 9_100_000;
        tick.blockNumber = tick.topic1;
        tick.opCode = 2;
        tick.txHash = 999;
        tick.logIndex = 2;
        vm.prank(SYSTEM);
        liveCoordinator.react(tick);
        (,,,,,,,, bytes32 eventId,) = liveCoordinator.policies(7);
        assertEq(system.payload(), abi.encodeCall(SablierRecoveryExecutorV2.recover, (address(0), eventId, 7, 1)));
        vm.recordLogs();
        proxy.forward(executor, address(liveCoordinator), eventId, 7, 1);
        _relay(vm.getRecordedLogs(), liveCoordinator, address(executor), 201);
        assertEq(token.balanceOf(ALICE), 100);
        (,,,,,,, SablierRecoveryReactiveV2.State state,,) = liveCoordinator.policies(7);
        assertEq(uint8(state), uint8(SablierRecoveryReactiveV2.State.Completed));
    }

    function testSelectiveCallbackFailureDoesNotBlockOtherPolicies() public {
        _enroll(1, 1, 1_000_001, 1);
        _enroll(2, 1, 1_000_001, 1);
        _enroll(3, 1, 1_000_001, 1);
        system.setFailStreamId(1);
        vm.warp(1_000_121);
        _cron();
        assertEq(system.requests(), 2);
        assertEq(coordinator.callbacksSubmitted(), 2);
        assertEq(coordinator.lifetimeAttempts(1), 0);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Retryable));
        assertEq(uint8(_stateOnly(2)), uint8(SablierRecoveryReactiveV2.State.Pending));
        assertEq(coordinator.heapSize(), 3);
        system.setFailStreamId(0);
        vm.warp(block.timestamp + 300);
        _cron();
        assertEq(system.requests(), 3);
    }

    function testRequestFailureBudgetBoundsOneTick() public {
        for (uint256 i = 1; i <= 4; i++) _enroll(i, 1, 1_000_001, 1);
        system.setFailRequest(true);
        vm.warp(1_000_121);
        _cron();
        assertEq(system.requests(), 0);
        assertEq(coordinator.callbacksSubmitted(), 0);
        assertEq(coordinator.heapSize(), 4);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Retryable));
        assertEq(uint8(_stateOnly(2)), uint8(SablierRecoveryReactiveV2.State.Retryable));
        assertEq(uint8(_stateOnly(3)), uint8(SablierRecoveryReactiveV2.State.Scheduled));
        assertEq(coordinator.lifetimeAttempts(1), 0);
        system.setFailRequest(false);
        _cron();
        assertEq(system.requests(), 2);
    }

    function testPersistentSubmissionFailuresExhaustAndReleaseCapacityOnce() public {
        _enroll(1, 1, 1_000_001, 1);
        _enroll(2, 1, 1_000_001, 1);
        system.setFailStreamId(1);
        vm.warp(1_000_121);
        for (uint256 i = 1; i <= coordinator.MAX_LIFETIME_SUBMISSION_FAILURES(); i++) {
            _cron();
            assertEq(coordinator.submissionFailures(1), i);
            assertEq(coordinator.callbacksSubmitted(), system.requests());
            assertEq(coordinator.lifetimeAttempts(1), 0);
            (,, uint8 attempts) = _state(1);
            assertEq(attempts, 0);
            if (i < coordinator.MAX_LIFETIME_SUBMISSION_FAILURES()) vm.warp(block.timestamp + 300);
        }
        assertGt(system.requests(), 0); // The unrelated eligible stream progressed.
        assertEq(coordinator.activeCount(), 1);
        assertEq(coordinator.heapIndex(1), 0);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Exhausted));
        uint256 accepted = coordinator.callbacksSubmitted();
        _cron();
        _deliver(
            _base(
                EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1), uint64(1)), 3
            )
        );
        assertEq(coordinator.activeCount(), 1);
        assertEq(coordinator.submissionFailures(1), coordinator.MAX_LIFETIME_SUBMISSION_FAILURES());
        assertEq(coordinator.callbacksSubmitted(), accepted);
        _enroll(3, 1, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 2); // The released slot can be reused.
    }

    function testReenrollmentCannotResetSubmissionFailureBudget() public {
        system.setFailStreamId(1);
        vm.warp(1_000_121);
        for (uint64 version = 1; version <= 3; version++) {
            _enroll(1, version, 1_000_001, 1);
            uint256 failuresThisVersion = version == 3 ? 1 : 2;
            for (uint256 i; i < failuresThisVersion; i++) {
                _cron();
                if (coordinator.submissionFailures(1) < coordinator.MAX_LIFETIME_SUBMISSION_FAILURES()) {
                    vm.warp(block.timestamp + 300);
                }
            }
            assertEq(coordinator.submissionFailures(1), version == 1 ? 2 : version == 2 ? 4 : 5);
        }
        assertEq(coordinator.activeCount(), 0);
        _enroll(1, 4, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 0);
        assertEq(coordinator.heapSize(), 0);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Exhausted));
        system.setFailStreamId(0);
        _cron();
        assertEq(system.requests(), 0);
        assertEq(coordinator.callbacksSubmitted(), 0);
        assertEq(coordinator.lifetimeAttempts(1), 0);
    }

    function testDisallowPreventsFutureAdmissionButKeepsAdmittedPolicy() public {
        _enroll(1, 1, 1_000_001, 1);
        coordinator.setStreamAllowed(1, false);
        assertEq(coordinator.activeCount(), 1);
        vm.warp(1_000_121);
        _cron();
        assertEq(system.requests(), 1);
        _deliver(
            _base(
                EXECUTOR,
                coordinator.ENROLLED_TOPIC(),
                1,
                uint256(uint160(ALICE)),
                0,
                abi.encode(uint64(2), uint256(0), uint40(1_000_001), uint8(1)),
                3
            )
        );
        assertEq(coordinator.activeCount(), 0);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Untracked));
    }

    function testRetryBeforeEnrollmentAndDelayedCron() public {
        _deliver(
            _base(
                EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1), uint64(1)), 3
            )
        );
        _enroll(1, 1, 1_000_001, 1);
        (,, uint64 retryNonce,,,,,,,) = coordinator.policies(1);
        assertEq(retryNonce, 0);
        vm.warp(1_000_500);
        _cron();
        assertEq(system.requests(), 1);
    }

    function testGlobalBudgetAndControlledAdmission() public {
        coordinator.setCallbackBudget(1);
        _deliver(
            _base(
                EXECUTOR,
                coordinator.ENROLLED_TOPIC(),
                99,
                uint256(uint160(ALICE)),
                0,
                abi.encode(uint64(1), uint256(0), uint40(1_000_001), uint8(1)),
                3
            )
        );
        assertEq(coordinator.activeCount(), 0);
        _enroll(1, 1, 1_000_001, 1);
        _enroll(2, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        _cron();
        assertEq(system.requests(), 1);
        _enroll(3, 1, 1_000_001, 1);
        _cron();
        assertEq(system.requests(), 1);
        vm.prank(ALICE);
        vm.expectRevert(SablierRecoveryReactiveV2.OnlyOwner.selector);
        coordinator.setCallbackBudget(256);
        vm.expectRevert(SablierRecoveryReactiveV2.InvalidBudget.selector);
        coordinator.setCallbackBudget(513);
    }

    function testExhaustedPoliciesReleaseAllSlots() public {
        coordinator.setCallbackBudget(512);
        for (uint256 i = 1; i <= 64; i++) _enroll(i, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        for (uint256 attempt; attempt < 5; attempt++) {
            for (uint256 tick; tick < 22; tick++) _cron();
            vm.warp(block.timestamp + 600);
        }
        for (uint256 tick; tick < 7; tick++) _cron();
        assertEq(coordinator.activeCount(), 0);
        assertEq(coordinator.heapSize(), 0);
        _enroll(65, 1, 1_000_001, 1);
        assertEq(coordinator.activeCount(), 1);
        _deliver(_base(EXECUTOR, coordinator.REVOKED_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1)), 3));
        assertEq(coordinator.activeCount(), 1);
        assertEq(coordinator.lifetimeAttempts(1), 5);
    }

    function testTerminalTimeoutReleasesSlotAndAcceptsLateTerminal() public {
        _enroll(1, 1, 1_000_001, 1);
        vm.warp(1_000_121);
        _cron();
        (, bytes32 id,) = _state(1);
        _deliver(_base(EXECUTOR, coordinator.SKIPPED_TOPIC(), uint256(id), 1, 0, abi.encode(uint64(1), uint8(3)), 3));
        _cancel(1);
        _deliver(
            _base(
                EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1), uint64(1)), 3
            )
        );
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.TerminalPending));
        vm.warp(block.timestamp + 1 days);
        coordinator.releaseTimedOutTerminal(1);
        assertEq(coordinator.activeCount(), 0);
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.TerminalPending));
        _deliver(
            _base(EXECUTOR, coordinator.COMPLETED_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1)), 3)
        );
        assertEq(uint8(_stateOnly(1)), uint8(SablierRecoveryReactiveV2.State.Completed));
        assertEq(coordinator.activeCount(), 0);
    }

    function testRetrySpamCannotMoveDueLaterOrRunBeforeMaturity() public {
        _enroll(1, 1, 1_010_000, 1);
        for (uint64 n = 1; n <= 8; n++) {
            vm.warp(1_000_000 + n * 100);
            _deliver(
                _base(EXECUTOR, coordinator.RETRY_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1), n), 3)
            );
            (,,,, uint40 dueAt,,,,,) = coordinator.policies(1);
            assertEq(dueAt, 1_010_120);
            _cron();
        }
        assertEq(system.requests(), 0);
        vm.warp(1_010_120);
        _cron();
        assertEq(system.requests(), 1);
    }

    function testPermanentShutdownUsesExactSubscriptionsAndStopsDelayedCron() public {
        _enroll(1, 1, 1_000_001, 1);
        vm.prank(ALICE);
        vm.expectRevert(SablierRecoveryReactiveV2.OnlyOwner.selector);
        coordinator.shutdownPermanently();
        coordinator.shutdownPermanently();
        assertEq(system.unsubscriptions(), 8);
        assertEq(system.unsubscriptionDigest(), system.subscriptionDigest());
        uint256 ignoreTopic = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
        assertEq(
            system.lastUnsubscribe(),
            keccak256(
                abi.encode(
                    coordinator.BASE(), EXECUTOR, coordinator.SKIPPED_TOPIC(), ignoreTopic, ignoreTopic, ignoreTopic
                )
            )
        );
        vm.warp(1_000_121);
        _cron();
        assertEq(system.requests(), 0);
        vm.expectRevert(SablierRecoveryReactiveV2.ShutdownPermanent.selector);
        coordinator.setPaused(false);
        _deliver(_base(EXECUTOR, coordinator.REVOKED_TOPIC(), 1, uint256(uint160(ALICE)), 0, abi.encode(uint64(1)), 3));
        assertEq(coordinator.activeCount(), 0);
    }

    function testFuzzHeapInvariants(uint256 seed) public {
        for (uint256 i = 1; i <= 16; i++) _enroll(i, 1, 1_000_001 + uint40(i), 2);
        for (uint256 step; step < 32; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 id = seed % 16 + 1;
            if (seed % 4 == 0) {
                _cancel(id);
            } else if (seed % 4 == 1) {
                _deliver(
                    _base(
                        EXECUTOR,
                        coordinator.RETRY_TOPIC(),
                        id,
                        uint256(uint160(ALICE)),
                        0,
                        abi.encode(uint64(1), uint64(step + 1)),
                        3
                    )
                );
            } else if (seed % 4 == 2) {
                _deliver(
                    _base(
                        EXECUTOR, coordinator.REVOKED_TOPIC(), id, uint256(uint160(ALICE)), 0, abi.encode(uint64(1)), 3
                    )
                );
            } else {
                vm.warp(block.timestamp + 300);
                _cron();
            }
            uint256 size = coordinator.heapSize();
            assertLe(size, coordinator.activeCount());
            assertLe(coordinator.activeCount(), coordinator.MAX_ACTIVE());
            for (uint256 i = 1; i <= size; i++) {
                uint256 item = coordinator.heapAt(i);
                assertEq(coordinator.heapIndex(item), i);
                if (i > 1) {
                    uint256 parent = coordinator.heapAt(i / 2);
                    uint40 parentDue = _dueAt(parent);
                    uint40 itemDue = _dueAt(item);
                    assertTrue(parentDue < itemDue || (parentDue == itemDue && parent < item));
                }
                for (uint256 j = i + 1; j <= size; j++) assertTrue(item != coordinator.heapAt(j));
            }
        }
    }

    function _dueAt(uint256 id) internal view returns (uint40 dueAt) {
        (,,,, dueAt,,,,,) = coordinator.policies(id);
    }

    function testGasEstimates() public {
        uint256 beforeGas = gasleft();
        _enroll(1, 1, 1_000_100, 1);
        uint256 enrollmentGas = beforeGas - gasleft();
        beforeGas = gasleft();
        _cron();
        uint256 idleGas = beforeGas - gasleft();
        vm.warp(1_000_220);
        beforeGas = gasleft();
        _cron();
        uint256 dueGas = beforeGas - gasleft();
        for (uint256 i = 2; i <= 11; i++) _enroll(i, 1, 1_000_100, 1);
        beforeGas = gasleft();
        _cron();
        uint256 backlogGas = beforeGas - gasleft();
        emit log_named_uint("enrollment gas with mock system", enrollmentGas);
        emit log_named_uint("idle cron gas", idleGas);
        emit log_named_uint("one due cron gas", dueGas);
        emit log_named_uint("callback submission marginal estimate", dueGas - idleGas);
        emit log_named_uint("10-policy backlog cron gas", backlogGas);
    }

    function _relay(Vm.Log[] memory logs, SablierRecoveryReactiveV2 target, address emitter, uint256 blockNumber)
        internal
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != emitter) continue;
            IReactive.LogRecord memory r;
            r.chainId = 84532;
            r.contractAddress = emitter;
            r.topic0 = uint256(logs[i].topics[0]);
            r.opCode = logs[i].topics.length;
            if (logs[i].topics.length > 1) r.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) r.topic2 = uint256(logs[i].topics[2]);
            if (logs[i].topics.length > 3) r.topic3 = uint256(logs[i].topics[3]);
            r.data = logs[i].data;
            r.blockNumber = blockNumber;
            r.txHash = blockNumber;
            r.logIndex = i + 1;
            vm.prank(SYSTEM);
            target.react(r);
        }
    }
}
