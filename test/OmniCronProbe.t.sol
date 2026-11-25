// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {OmniCronProbe} from "../src/demo/OmniCronProbe.sol";

contract MockOmniSubscriptionSystem {
    bytes public lastSubscription;
    bytes public lastUnsubscription;
    uint256 public subscribeCount;
    uint256 public unsubscribeCount;
    bool public failUnsubscribe;
    mapping(address => uint256) public debt;

    function subscribe(uint256 chainId, address emitter, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3)
        external
    {
        lastSubscription = abi.encode(chainId, emitter, topic0, topic1, topic2, topic3);
        subscribeCount += 1;
    }

    function unsubscribe(
        uint256 chainId,
        address emitter,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        require(!failUnsubscribe, "unsubscribe failed");
        lastUnsubscription = abi.encode(chainId, emitter, topic0, topic1, topic2, topic3);
        unsubscribeCount += 1;
    }

    function setFailUnsubscribe(bool fail) external {
        failUnsubscribe = fail;
    }

    function setDebt(address probe, uint256 amount) external {
        debt[probe] = amount;
    }

    receive() external payable {
        debt[msg.sender] -= msg.value;
    }
}

contract OmniCronProbeTest is Test {
    address private constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 private constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    OmniCronProbe private probe;
    MockOmniSubscriptionSystem private system;

    function setUp() public {
        MockOmniSubscriptionSystem implementation = new MockOmniSubscriptionSystem();
        vm.etch(SYSTEM, address(implementation).code);
        system = MockOmniSubscriptionSystem(payable(SYSTEM));
        probe = new OmniCronProbe();
    }

    function _log(uint256 cronBlock, uint256 txHash, uint256 logIndex)
        private
        view
        returns (IReactive.LogRecord memory record)
    {
        record.chainId = probe.LASNA_CHAIN_ID();
        record.contractAddress = probe.CRON_EMITTER();
        record.topic0 = probe.CRON100_TOPIC();
        record.topic1 = cronBlock;
        record.opCode = 2;
        record.blockNumber = cronBlock;
        record.txHash = txHash;
        record.logIndex = logIndex;
    }

    function _deliver(IReactive.LogRecord memory record) private {
        vm.prank(SYSTEM);
        probe.react(record);
    }

    function testSubscribesOnlyToCron100WithExactArguments() public view {
        assertEq(system.subscribeCount(), 1);
        assertEq(system.unsubscribeCount(), 0);
        assertTrue(probe.subscriptionActive());
        assertEq(
            system.lastSubscription(),
            abi.encode(probe.LASNA_CHAIN_ID(), probe.CRON_EMITTER(), probe.CRON100_TOPIC(), IGNORE, IGNORE, IGNORE)
        );
    }

    function testValidDeliveryRecordsIndexedBlockAndEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(probe));
        emit OmniCronProbe.CronObserved(9_197_000, 123, 2, 1);
        _deliver(_log(9_197_000, 123, 2));
        assertEq(probe.uniqueDeliveries(), 1);
        assertEq(probe.lastCronBlockNumber(), 9_197_000);
        assertEq(probe.lastCronTransactionHash(), 123);
        assertEq(probe.lastCronLogIndex(), 2);
    }

    function testUnauthorizedCallerCannotDeliver() public {
        IReactive.LogRecord memory record = _log(9_197_000, 123, 2);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(0xBAD), SYSTEM));
        probe.react(record);
        assertEq(probe.uniqueDeliveries(), 0);
    }

    function testWrongChainEmitterOrTopicIsIgnored() public {
        IReactive.LogRecord memory record = _log(9_197_000, 123, 2);
        record.chainId = 1;
        _deliver(record);
        record.chainId = probe.LASNA_CHAIN_ID();
        record.contractAddress = address(0xBAD);
        _deliver(record);
        record.contractAddress = probe.CRON_EMITTER();
        record.topic0 = uint256(keccak256("Cron10(uint256)"));
        _deliver(record);
        assertEq(probe.uniqueDeliveries(), 0);
    }

    function testMalformedTopicStructureAndPayloadAreIgnored() public {
        IReactive.LogRecord memory record = _log(9_197_000, 123, 2);
        record.opCode = 1;
        _deliver(record);
        record.opCode = 2;
        record.topic2 = 1;
        _deliver(record);
        record.topic2 = 0;
        record.topic3 = 1;
        _deliver(record);
        record.topic3 = 0;
        record.data = abi.encode(uint256(9_197_000));
        _deliver(record);
        record.data = "";
        record.topic1 = 9_197_001;
        _deliver(record);
        record.topic1 = 0;
        _deliver(record);
        record.topic1 = 9_197_000;
        record.txHash = 0;
        _deliver(record);
        assertEq(probe.uniqueDeliveries(), 0);
    }

    function testDuplicateLogDoesNotIncrement() public {
        IReactive.LogRecord memory record = _log(9_197_000, 123, 2);
        _deliver(record);
        _deliver(record);
        assertEq(probe.uniqueDeliveries(), 1);
        assertEq(system.unsubscribeCount(), 0);
    }

    function testThirdUniqueDeliveryAutomaticallyUnsubscribesAndStops() public {
        _deliver(_log(9_197_000, 123, 2));
        _deliver(_log(9_197_100, 456, 2));
        _deliver(_log(9_197_200, 789, 2));
        assertEq(probe.uniqueDeliveries(), 3);
        assertFalse(probe.subscriptionActive());
        assertEq(system.unsubscribeCount(), 1);
        assertEq(system.lastUnsubscription(), system.lastSubscription());
        _deliver(_log(9_197_300, 999, 2));
        assertEq(probe.uniqueDeliveries(), 3);
        assertEq(system.unsubscribeCount(), 1);
    }

    function testUnsubscribeRevertRollsBackThirdDelivery() public {
        _deliver(_log(9_197_000, 123, 2));
        _deliver(_log(9_197_100, 456, 2));
        system.setFailUnsubscribe(true);
        IReactive.LogRecord memory third = _log(9_197_200, 789, 2);
        vm.prank(SYSTEM);
        vm.expectRevert("unsubscribe failed");
        probe.react(third);
        assertEq(probe.uniqueDeliveries(), 2);
        assertTrue(probe.subscriptionActive());
        assertEq(system.unsubscribeCount(), 0);
    }

    function testOnlyOwnerCanPauseAndPauseIsIdempotent() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(OmniCronProbe.OnlyOwner.selector);
        probe.pause();
        assertTrue(probe.subscriptionActive());
        probe.pause();
        probe.pause();
        assertFalse(probe.subscriptionActive());
        assertEq(system.unsubscribeCount(), 1);
        assertEq(system.lastUnsubscription(), system.lastSubscription());
        _deliver(_log(9_197_000, 123, 2));
        assertEq(probe.uniqueDeliveries(), 0);
    }

    function testCoverDebtUsesInstalledLibraryAndProbeBalance() public {
        vm.deal(address(probe), 1 ether);
        system.setDebt(address(probe), 0.2 ether);
        probe.coverDebt();
        assertEq(system.debt(address(probe)), 0);
        assertEq(address(probe).balance, 0.8 ether);
    }
}
