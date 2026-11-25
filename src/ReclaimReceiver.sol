// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";

/// @notice First live callback target. Records genuine receipt, NEVER moves funds.
contract ReclaimReceiver is AbstractCallback {
    mapping(bytes32 => bool) public processed;
    uint256 public processedCount;

    event RecoveryObserved(
        bytes32 indexed eventId,
        bytes32 indexed positionId,
        address indexed beneficiary,
        bytes32 originTxHash
    );

    constructor(IPayable callbackProxy, address reactiveSender)
        payable
        AbstractCallback(callbackProxy, reactiveSender)
    {}

    function record(
        address reactiveSender,
        bytes32 eventId,
        bytes32 positionId,
        address beneficiary,
        bytes32 originTxHash
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) {
        if (processed[eventId]) return; // duplicate delivery must not change state twice
        processed[eventId] = true;
        unchecked { ++processedCount; }
        emit RecoveryObserved(eventId, positionId, beneficiary, originTxHash);
    }

    function coverDebt() external { _coverDebt(); }
}
