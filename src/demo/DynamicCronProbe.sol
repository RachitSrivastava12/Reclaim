// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @notice Exercises on-demand Cron100 subscribe/unsubscribe on Reactive Omni.
contract DynamicCronProbe is AbstractReactive {
    error OnlyOwner();
    error PermanentlyShutdown();
    error ActivationLimitReached();

    uint256 public constant LASNA_CHAIN_ID = 5_318_007;
    uint256 public constant BASE_CHAIN_ID = 84_532;
    address public constant CRON_EMITTER = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant CRON100_TOPIC = uint256(keccak256("Cron100(uint256)"));
    uint256 public constant DELIVERIES_PER_CYCLE = 3;
    uint256 public constant MAX_CYCLES = 2;
    uint256 public constant ACTIVATION_TOPIC = uint256(keccak256("ActivationRequested(uint256,uint256)"));

    address public immutable owner;
    address public immutable controlOrigin;
    bool public subscriptionActive;
    bool public shutdown;
    uint256 public cycle;
    uint256 public uniqueDeliveries;
    uint256 public lastCronBlockNumber;
    uint256 public lastCronTransactionHash;
    uint256 public lastCronLogIndex;
    mapping(bytes32 => bool) public observedLogs;

    event SubscriptionEnabled(uint256 indexed cycle);
    event ActivationRequested(uint256 indexed nonce, uint256 indexed sourceBlock);
    event CronObserved(
        uint256 indexed cycle, uint256 indexed cronBlockNumber, uint256 transactionHash, uint256 logIndex, uint256 count
    );
    event SubscriptionDisabled(uint256 indexed cycle, uint256 count);
    event EmergencyShutdown(uint256 indexed cycle, uint256 count);

    constructor(address controlOrigin_) payable {
        require(controlOrigin_ != address(0), "zero origin");
        owner = msg.sender;
        controlOrigin = controlOrigin_;
        SYSTEM.subscribe(
            BASE_CHAIN_ID, controlOrigin_, ACTIVATION_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function enable() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (shutdown) revert PermanentlyShutdown();
        if (subscriptionActive) return;
        if (cycle == MAX_CYCLES) revert ActivationLimitReached();
        _enable();
    }

    function emergencyShutdown() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (shutdown) revert PermanentlyShutdown();
        shutdown = true;
        if (subscriptionActive) _unsubscribe();
        SYSTEM.unsubscribe(
            BASE_CHAIN_ID, controlOrigin, ACTIVATION_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit EmergencyShutdown(cycle, uniqueDeliveries);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (shutdown) return;
        if (log_.chainId == BASE_CHAIN_ID && log_.contractAddress == controlOrigin && log_.topic0 == ACTIVATION_TOPIC) {
            if (
                log_.opCode != 1 || log_.topic1 != 0 || log_.topic2 != 0 || log_.topic3 != 0 || log_.data.length != 64
                    || log_.txHash == 0
            ) return;
            (uint256 nonce, uint256 sourceBlock) = abi.decode(log_.data, (uint256, uint256));
            if (nonce == 0 || nonce <= lastActivationNonce || sourceBlock != log_.blockNumber) return;
            if (subscriptionActive || cycle == MAX_CYCLES) return;
            lastActivationNonce = nonce;
            emit ActivationRequested(nonce, sourceBlock);
            _enable();
            return;
        }
        if (!subscriptionActive || log_.chainId != LASNA_CHAIN_ID) return;
        if (log_.contractAddress != CRON_EMITTER || log_.topic0 != CRON100_TOPIC) return;
        // Verified Lasna Omni Cron100 shape: LOG2, indexed block, empty data.
        if (
            log_.opCode != 2 || log_.topic1 == 0 || log_.topic1 % 100 != 0 || log_.topic1 != log_.blockNumber
                || log_.topic2 != 0 || log_.topic3 != 0 || log_.data.length != 0 || log_.txHash == 0
        ) return;

        bytes32 logId = keccak256(abi.encode(log_.txHash, log_.logIndex));
        if (observedLogs[logId]) return;
        observedLogs[logId] = true;
        uniqueDeliveries++;
        lastCronBlockNumber = log_.topic1;
        lastCronTransactionHash = log_.txHash;
        lastCronLogIndex = log_.logIndex;
        emit CronObserved(cycle, log_.topic1, log_.txHash, log_.logIndex, uniqueDeliveries);
        if (uniqueDeliveries == DELIVERIES_PER_CYCLE) _unsubscribe();
    }

    uint256 public lastActivationNonce;

    function _enable() private {
        cycle++;
        uniqueDeliveries = 0;
        subscriptionActive = true;
        SYSTEM.subscribe(LASNA_CHAIN_ID, CRON_EMITTER, CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit SubscriptionEnabled(cycle);
    }

    function coverDebt() external {
        _coverDebt();
    }

    function _unsubscribe() private {
        subscriptionActive = false;
        SYSTEM.unsubscribe(
            LASNA_CHAIN_ID, CRON_EMITTER, CRON100_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit SubscriptionDisabled(cycle, uniqueDeliveries);
    }
}
