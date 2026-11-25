// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ReclaimDemoToken} from "../src/demo/ReclaimDemoToken.sol";

contract ReclaimDemoTokenTest is Test {
    ReclaimDemoToken token;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;

    function setUp() public {
        token = new ReclaimDemoToken();
    }

    function testInitialSupplyAndMetadata() public view {
        assertEq(token.name(), "Reclaim Demo USD");
        assertEq(token.symbol(), "rUSD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit ReclaimDemoToken.Transfer(address(this), ALICE, 100 ether);
        assertTrue(token.transfer(ALICE, 100 ether));
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testApproveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit ReclaimDemoToken.Approval(address(this), ALICE, 100 ether);
        assertTrue(token.approve(ALICE, 100 ether));
        assertEq(token.allowance(address(this), ALICE), 100 ether);

        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 40 ether));
        assertEq(token.allowance(address(this), ALICE), 60 ether);
        assertEq(token.balanceOf(BOB), 40 ether);
        assertEq(token.balanceOf(address(this)), INITIAL_SUPPLY - 40 ether);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
    }

    function testUnlimitedAllowanceIsNotReduced() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function testTransferRevertsForInsufficientBalance() public {
        vm.prank(ALICE);
        vm.expectRevert("ERC20: insufficient balance");
        token.transfer(BOB, 1);
    }

    function testTransferRevertsForZeroRecipient() public {
        vm.expectRevert("ERC20: transfer to zero address");
        token.transfer(address(0), 1);
    }

    function testTransferFromRevertsForInsufficientAllowance() public {
        token.approve(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert("ERC20: insufficient allowance");
        token.transferFrom(address(this), BOB, 2);
        assertEq(token.allowance(address(this), ALICE), 1);
    }

    function testTransferFromRevertsForInsufficientBalance() public {
        vm.prank(ALICE);
        token.approve(BOB, 1);
        vm.prank(BOB);
        vm.expectRevert("ERC20: insufficient balance");
        token.transferFrom(ALICE, address(this), 1);
        assertEq(token.allowance(ALICE, BOB), 1);
    }

    function testTransferFromRevertsForZeroRecipient() public {
        token.approve(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert("ERC20: transfer to zero address");
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), ALICE), 1);
    }

    function testTransferFromRevertsForZeroSenderEvenForZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert("ERC20: transfer from zero address");
        token.transferFrom(address(0), BOB, 0);
    }
}
