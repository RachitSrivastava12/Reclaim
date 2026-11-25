// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {ReclaimReceiver} from "../src/ReclaimReceiver.sol";
import {RecoverySignal} from "../src/RecoverySignal.sol";

contract ReclaimReceiverTest is Test {
    address constant PROXY = address(0x476F44b11F5C942c58f4c8E3d0300E5710743585);
    address constant REACTIVE = address(0xBABE);
    address constant USER = address(0xBEEF);
    bytes32 constant ID = keccak256("event-1");

    ReclaimReceiver receiver;
    RecoverySignal signal;

    function setUp() public {
        receiver = new ReclaimReceiver(IPayable(payable(PROXY)), REACTIVE);
        signal = new RecoverySignal();
    }

    function testAuthenticatedCallbackProcessesOnce() public {
        vm.prank(PROXY);
        receiver.record(REACTIVE, ID, bytes32(uint256(42)), USER, bytes32(uint256(1)));
        assertTrue(receiver.processed(ID));
        assertEq(receiver.processedCount(), 1);

        vm.prank(PROXY);
        receiver.record(REACTIVE, ID, bytes32(uint256(42)), USER, bytes32(uint256(1)));
        assertEq(receiver.processedCount(), 1);
    }

    function testRejectsDirectCallerEvenWithCorrectReactiveSender() public {
        vm.expectRevert();
        receiver.record(REACTIVE, ID, bytes32(uint256(42)), USER, bytes32(uint256(1)));
    }

    function testRejectsWrongReactiveSenderEvenFromProxy() public {
        vm.prank(PROXY);
        vm.expectRevert();
        receiver.record(address(0xDEAD), ID, bytes32(uint256(42)), USER, bytes32(uint256(1)));
    }

    function testOriginSignalRestrictedToOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(RecoverySignal.OnlyOwner.selector);
        signal.signalEligible(bytes32(uint256(1)), USER);
    }

    function testOriginRejectsZeroBeneficiary() public {
        vm.expectRevert(RecoverySignal.InvalidBeneficiary.selector);
        signal.signalEligible(bytes32(uint256(1)), address(0));
    }
}
