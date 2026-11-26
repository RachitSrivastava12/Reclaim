// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Authenticated Base Sepolia origin for DynamicCronProbe activation events.
contract DynamicCronControl {
    error OnlyOwner();
    error ActivationLimitReached();

    event ActivationRequested(uint256 nonce, uint256 sourceBlock);
    address public immutable owner;
    uint256 public nonce;

    constructor() {
        owner = msg.sender;
    }

    function activate() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (nonce == 2) revert ActivationLimitReached();
        emit ActivationRequested(++nonce, block.number);
    }
}
