// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Controlled testnet event source. No tokens are held or moved here.
contract RecoverySignal {
    error OnlyOwner();
    error InvalidBeneficiary();

    address public immutable owner;

    // LOG3: signature + two indexed arguments, exactly what our RC expects.
    event PositionEligible(bytes32 indexed positionId, address indexed beneficiary);

    constructor() {
        owner = msg.sender;
    }

    function signalEligible(bytes32 positionId, address beneficiary) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        emit PositionEligible(positionId, beneficiary);
    }
}
