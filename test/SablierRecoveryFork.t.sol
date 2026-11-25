// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {ISablierLockup} from "../src/ISablierLockup.sol";
import {SablierRecoveryExecutor} from "../src/SablierRecoveryExecutor.sol";

contract ForkTestToken {
    string public constant name = "RECLAIM Fork Test Token";
    string public constant symbol = "RFT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        require(approved >= amount, "allowance");
        allowance[from][msg.sender] = approved - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface IRealSablierLinear {
    struct CreateWithDurations {
        address sender;
        address recipient;
        uint128 depositAmount;
        address token;
        bool cancelable;
        bool transferable;
        string shape;
    }

    struct UnlockAmounts {
        uint128 start;
        uint128 cliff;
    }

    struct Durations {
        uint40 cliff;
        uint40 total;
    }
    function createWithDurationsLL(
        CreateWithDurations calldata params,
        UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        Durations calldata durations
    ) external payable returns (uint256 streamId);
    function cancel(uint256 streamId) external payable returns (uint128 refundedAmount);
}

contract SablierRecoveryForkTest is Test {
    address constant SABLIER = 0xA65A1ecEf02C2B9BDc604951c6A6D02335D4532e;
    address constant PROXY = address(0x4001);
    address constant REACTIVE = address(0x4002);
    address constant SENDER = address(0x4003);
    address constant RECIPIENT = address(0x4004);

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "set BASE_SEPOLIA_RPC_URL to run the real Sablier fork test");
            return;
        }
        vm.createSelectFork(rpc);
    }

    function testActualSablierCancellationRecoveryOnLocalFork() public {
        ForkTestToken token = new ForkTestToken();
        SablierRecoveryExecutor executor =
            new SablierRecoveryExecutor(IPayable(payable(PROXY)), REACTIVE, ISablierLockup(SABLIER));
        token.mint(SENDER, 300 ether);
        vm.deal(SENDER, 1 ether);
        vm.deal(RECIPIENT, 1 ether);

        vm.startPrank(SENDER);
        token.approve(SABLIER, 300 ether);
        uint256 streamId = IRealSablierLinear(SABLIER)
            .createWithDurationsLL(
                IRealSablierLinear.CreateWithDurations({
                sender: SENDER,
                recipient: RECIPIENT,
                depositAmount: 300 ether,
                token: address(token),
                cancelable: true,
                transferable: false,
                shape: ""
            }),
                IRealSablierLinear.UnlockAmounts({start: 0, cliff: 0}),
                1,
                IRealSablierLinear.Durations({cliff: 0, total: 300})
            );
        vm.stopPrank();

        vm.prank(RECIPIENT);
        executor.enroll{value: 0.01 ether}(streamId, 0.01 ether);
        vm.warp(block.timestamp + 120);
        vm.prank(SENDER);
        IRealSablierLinear(SABLIER).cancel(streamId);

        uint128 amount = ISablierLockup(SABLIER).withdrawableAmountOf(streamId);
        assertGt(amount, 0);
        assertTrue(ISablierLockup(SABLIER).wasCanceled(streamId));
        uint256 beforeBalance = token.balanceOf(RECIPIENT);
        vm.prank(PROXY);
        executor.recover(REACTIVE, keccak256("fork cancellation"), streamId, 1);
        assertEq(token.balanceOf(RECIPIENT), beforeBalance + amount);
        assertEq(token.balanceOf(address(executor)), 0);
        assertEq(ISablierLockup(SABLIER).withdrawableAmountOf(streamId), 0);
        (,, uint256 reserve,,, bool active) = executor.policies(streamId);
        assertFalse(active);
        assertEq(reserve, 0);
        assertEq(executor.feeCredits(RECIPIENT), address(executor).balance);
    }
}
