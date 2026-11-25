// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @notice Bounded probe for native Cron100 delivery on Reactive Lasna Omni.
contract OmniCronProbe is AbstractReactive {
    error OnlyOwner();

    uint256 public constant LASNA_CHAIN_ID = 5_318_007;
    address public constant CRON_EMITTER = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant CRON100_TOPIC = uint256(keccak256("Cron100(uint256)"));
    uint256 public constant MAX_DELIVERIES = 3;

    address public immutable owner;
    bool public subscriptionActive;
    uint256 public uniqueDeliveries;
    uint256 public lastCronBlockNumber;
    uint256 public lastCronTransactionHash;
    uint256 public lastCronLogIndex;
    mapping(bytes32 => bool) public observedLogs;

    event CronObserved(
        uint256 indexed cronBlockNumber, uint256 indexed transactionHash, uint256 logIndex, uint256 count
    );
    event ProbeStopped(uint256 count);

    constructor() payable {
        owner = msg.sender;
        _subscribe();
        subscriptionActive = true;
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (!subscriptionActive) return;
        if (log_.chainId != LASNA_CHAIN_ID || log_.contractAddress != CRON_EMITTER || log_.topic0 != CRON100_TOPIC) {
            return;
        }
        // The live Cron100 event is LOG2: its block number is indexed in topic1.
        if (
            log_.opCode != 2 || log_.topic1 == 0 || log_.topic1 % 100 != 0 || log_.topic2 != 0 || log_.topic3 != 0
                || log_.data.length != 0 || log_.txHash == 0
        ) return;

        bytes32 logId = keccak256(abi.encode(log_.txHash, log_.logIndex));
        if (observedLogs[logId]) return;
        observedLogs[logId] = true;

        uniqueDeliveries += 1;
        lastCronBlockNumber = log_.topic1;
        lastCronTransactionHash = log_.txHash;
        lastCronLogIndex = log_.logIndex;
        emit CronObserved(log_.topic1, log_.txHash, log_.logIndex, uniqueDeliveries);

        if (uniqueDeliveries == MAX_DELIVERIES) _stop();
    }

    function pause() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (subscriptionActive) _stop();
    }

    /// @notice Settle system debt from this probe's native-token balance.
    function coverDebt() external {
        _coverDebt();
    }

    function _subscribe() private {
        SYSTEM.subscribe(LASNA_CHAIN_ID, CRON_EMITTER, CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _stop() private {
        subscriptionActive = false;
        emit ProbeStopped(uniqueDeliveries);
        SYSTEM.unsubscribe(
            LASNA_CHAIN_ID, CRON_EMITTER, CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }
}
