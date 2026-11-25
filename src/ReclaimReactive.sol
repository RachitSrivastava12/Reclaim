// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {ReclaimReceiver} from "./ReclaimReceiver.sol";

/// @notice Omni coordinator; observes a controlled origin and authenticates its logs.
contract ReclaimReactive is AbstractReactive {
    error OnlyOwner();
    error DestinationAlreadySet();
    error InvalidDestination();

    address public immutable owner;
    uint256 public immutable originChainId;
    address public immutable originContract;
    address public destination;

    uint256 public constant POSITION_ELIGIBLE_TOPIC = uint256(keccak256("PositionEligible(bytes32,address)"));

    event DestinationConfigured(address indexed destination);
    event RecoveryRequested(bytes32 indexed eventId, bytes32 indexed positionId, bytes32 indexed originTxHash);

    constructor(uint256 originChainId_, address originContract_) payable {
        if (originChainId_ == 0 || originContract_ == address(0)) revert InvalidDestination();
        owner = msg.sender;
        originChainId = originChainId_;
        originContract = originContract_;

        SYSTEM.subscribe(
            originChainId_, originContract_, POSITION_ELIGIBLE_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function setDestination(address destination_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (destination != address(0)) revert DestinationAlreadySet();
        if (destination_ == address(0)) revert InvalidDestination();
        destination = destination_;
        emit DestinationConfigured(destination_);
    }

    function react(LogRecord calldata log_) external onlySystem {
        // Reject unrelated, malformed and non-LOG3 records without reverting.
        if (
            log_.chainId != originChainId || log_.contractAddress != originContract
                || log_.topic0 != POSITION_ELIGIBLE_TOPIC || log_.opCode != 3 || log_.topic2 >> 160 != 0
                || log_.topic3 != 0 || log_.data.length != 0 || destination == address(0)
        ) return;

        bytes32 positionId = bytes32(log_.topic1);
        address beneficiary = address(uint160(log_.topic2));
        if (beneficiary == address(0)) return;

        // txHash alone is NOT unique across multiple logs in the same transaction.
        bytes32 eventId = keccak256(abi.encode(log_.chainId, log_.contractAddress, log_.txHash, log_.logIndex));
        bytes32 originTxHash = bytes32(log_.txHash);

        bytes memory payload =
            abi.encodeCall(ReclaimReceiver.record, (address(0), eventId, positionId, beneficiary, originTxHash));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId, recipient: destination, gasLimit: 500_000, payload: payload
            })
        );
        emit RecoveryRequested(eventId, positionId, originTxHash);
    }

    function coverDebt() external {
        _coverDebt();
    }
}
