// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ReclaimReactive} from "../src/ReclaimReactive.sol";
import {RecoverySignal} from "../src/RecoverySignal.sol";
import {ReclaimReceiver} from "../src/ReclaimReceiver.sol";

contract MockSignalSystem {
    struct CallbackConfiguration {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    uint256 public requests;
    uint256 public chainId;
    address public recipient;
    uint64 public gasLimit;
    bytes public payload;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(CallbackConfiguration calldata config) external {
        requests++;
        chainId = config.chainId;
        recipient = config.recipient;
        gasLimit = config.gasLimit;
        payload = config.payload;
    }
}

contract ReclaimReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant DESTINATION = address(0xCAFE);
    address constant BENEFICIARY = address(0xBEEF);
    bytes32 constant POSITION = bytes32(uint256(42));

    MockSignalSystem system;
    RecoverySignal signal;
    ReclaimReactive reactive;

    function setUp() public {
        MockSignalSystem implementation = new MockSignalSystem();
        vm.etch(SYSTEM, address(implementation).code);
        system = MockSignalSystem(SYSTEM);
        signal = new RecoverySignal();
        reactive = new ReclaimReactive(84532, address(signal));
        reactive.setDestination(DESTINATION);
    }

    function _validRecord() private returns (IReactive.LogRecord memory record) {
        vm.recordLogs();
        signal.signalEligible(POSITION, BENEFICIARY);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        record.chainId = 84532;
        record.contractAddress = logs[0].emitter;
        record.topic0 = uint256(logs[0].topics[0]);
        record.topic1 = uint256(logs[0].topics[1]);
        record.topic2 = uint256(logs[0].topics[2]);
        record.data = logs[0].data;
        record.opCode = logs[0].topics.length;
        record.txHash = uint256(keccak256("origin-tx"));
        record.logIndex = 2;
    }

    function _deliver(IReactive.LogRecord memory record) private {
        vm.prank(SYSTEM);
        reactive.react(record);
    }

    function testCanonicalSignalRequestsExpectedCallback() public {
        IReactive.LogRecord memory record = _validRecord();
        _deliver(record);

        assertEq(system.requests(), 1);
        assertEq(system.chainId(), 84532);
        assertEq(system.recipient(), DESTINATION);
        assertEq(system.gasLimit(), 500_000);
        bytes memory payload = system.payload();
        assertEq(bytes4(payload), ReclaimReceiver.record.selector);
        bytes memory arguments = new bytes(payload.length - 4);
        for (uint256 i; i < arguments.length; i++) arguments[i] = payload[i + 4];
        (address sender, bytes32 eventId, bytes32 position, address beneficiary, bytes32 originTxHash) =
            abi.decode(arguments, (address, bytes32, bytes32, address, bytes32));
        assertEq(sender, address(0));
        assertEq(eventId, keccak256(abi.encode(record.chainId, record.contractAddress, record.txHash, record.logIndex)));
        assertEq(position, POSITION);
        assertEq(beneficiary, BENEFICIARY);
        assertEq(originTxHash, bytes32(record.txHash));
    }

    function testRejectsNoncanonicalAddressTopic() public {
        IReactive.LogRecord memory record = _validRecord();
        record.topic2 |= uint256(1) << 160;
        _deliver(record);
        assertEq(system.requests(), 0);
    }

    function testRejectsUnexpectedTopic3() public {
        IReactive.LogRecord memory record = _validRecord();
        record.topic3 = 1;
        _deliver(record);
        assertEq(system.requests(), 0);
    }

    function testRejectsNonemptyData() public {
        IReactive.LogRecord memory record = _validRecord();
        record.data = hex"01";
        _deliver(record);
        assertEq(system.requests(), 0);
    }

    function testRejectsWrongOpcode() public {
        IReactive.LogRecord memory record = _validRecord();
        record.opCode = 4;
        _deliver(record);
        assertEq(system.requests(), 0);
    }
}
