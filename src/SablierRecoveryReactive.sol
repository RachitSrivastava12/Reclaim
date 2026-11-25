// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {SablierRecoveryExecutor} from "./SablierRecoveryExecutor.sol";
import {ISablierLockup} from "./ISablierLockup.sol";

/// @notice Mirrors Base enrollment logs and requests recovery for cancellation logs.
contract SablierRecoveryReactive is AbstractReactive {
    error OnlyOwner();
    error InvalidSource();
    error DestinationAlreadySet();

    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant CANCEL_TOPIC =
        uint256(keccak256("CancelLockupStream(uint256,address,address,address,uint128,uint128)"));
    uint256 public constant ENROLLED_TOPIC = uint256(keccak256("PolicyEnrolled(uint256,address,uint64,uint256)"));
    uint256 public constant REVOKED_TOPIC = uint256(keccak256("PolicyRevoked(uint256,address,uint64)"));
    uint256 public constant COMPLETED_TOPIC = uint256(keccak256("PolicyCompleted(uint256,address,uint64)"));
    uint256 public constant RETRY_TOPIC = uint256(keccak256("RecoveryRetryRequested(uint256,address,uint64,uint64)"));

    struct Mirror {
        address owner;
        uint64 version;
        uint256 blockNumber;
        uint256 logIndex;
        bool active;
    }

    address public immutable owner;
    address public immutable sablier;
    address public executor;
    mapping(uint256 => Mirror) public mirrors;
    mapping(bytes32 => bool) public requestedEvents;

    event DestinationConfigured(address indexed destination);
    event RecoveryRequested(bytes32 indexed eventId, uint256 indexed streamId, uint64 version);

    constructor(address sablier_) payable {
        if (sablier_ == address(0)) revert InvalidSource();
        owner = msg.sender;
        sablier = sablier_;
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, sablier_, CANCEL_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice One-time configuration after the Base executor is created with this coordinator's address.
    function setDestination(address executor_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (executor != address(0)) revert DestinationAlreadySet();
        if (executor_ == address(0)) revert InvalidSource();
        executor = executor_;
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, executor_, ENROLLED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, executor_, REVOKED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, executor_, COMPLETED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            BASE_SEPOLIA_CHAIN_ID, executor_, RETRY_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit DestinationConfigured(executor_);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.chainId != BASE_SEPOLIA_CHAIN_ID) return;
        if (log_.contractAddress == executor) {
            if (log_.topic0 == ENROLLED_TOPIC) _onEnrollment(log_);
            else if (log_.topic0 == REVOKED_TOPIC || log_.topic0 == COMPLETED_TOPIC) _onRevocation(log_);
            else if (log_.topic0 == RETRY_TOPIC) _onRetry(log_);
        } else if (log_.contractAddress == sablier && log_.topic0 == CANCEL_TOPIC) {
            _onCancellation(log_);
        }
    }

    function _onEnrollment(LogRecord calldata log_) private {
        if (log_.opCode != 3 || log_.data.length != 64 || log_.topic2 == 0 || log_.topic2 >> 160 != 0) return;
        (uint256 rawVersion,) = abi.decode(log_.data, (uint256, uint256));
        if (rawVersion == 0 || rawVersion > type(uint64).max) return;
        uint256 streamId = log_.topic1;
        Mirror storage mirror = mirrors[streamId];
        if (!_isLater(log_, mirror)) return;
        mirror.owner = address(uint160(log_.topic2));
        // Checked against type(uint64).max above.
        // forge-lint: disable-next-line(unsafe-typecast)
        mirror.version = uint64(rawVersion);
        mirror.blockNumber = log_.blockNumber;
        mirror.logIndex = log_.logIndex;
        mirror.active = true;
        // An enrollment callback also closes the race where a cancellation log is delivered first.
        _request(log_, streamId, mirror.version);
    }

    function _onRevocation(LogRecord calldata log_) private {
        if (log_.opCode != 3 || log_.data.length != 32 || log_.topic2 == 0 || log_.topic2 >> 160 != 0) return;
        uint256 rawVersion = abi.decode(log_.data, (uint256));
        if (rawVersion == 0 || rawVersion > type(uint64).max) return;
        uint256 streamId = log_.topic1;
        Mirror storage mirror = mirrors[streamId];
        if (!_isLater(log_, mirror)) return;
        mirror.owner = address(uint160(log_.topic2));
        // Checked against type(uint64).max above.
        // forge-lint: disable-next-line(unsafe-typecast)
        mirror.version = uint64(rawVersion);
        mirror.blockNumber = log_.blockNumber;
        mirror.logIndex = log_.logIndex;
        mirror.active = false;
    }

    function _onCancellation(LogRecord calldata log_) private {
        if (log_.opCode != 4 || log_.data.length != 96 || log_.topic1 == 0 || log_.topic2 == 0 || log_.topic3 == 0) {
            return;
        }
        if ((log_.topic1 >> 160) != 0 || (log_.topic2 >> 160) != 0 || (log_.topic3 >> 160) != 0) return;
        (uint256 streamId, uint256 senderAmount, uint256 recipientAmount) =
            abi.decode(log_.data, (uint256, uint256, uint256));
        if (senderAmount > type(uint128).max || recipientAmount > type(uint128).max) return;
        if (recipientAmount == 0) return;
        Mirror storage mirror = mirrors[streamId];
        if (!mirror.active || mirror.owner != address(uint160(log_.topic2))) return;
        if (!_isLater(log_, mirror)) return;
        _request(log_, streamId, mirror.version);
    }

    function _onRetry(LogRecord calldata log_) private {
        if (log_.opCode != 3 || log_.data.length != 64 || log_.topic2 == 0 || log_.topic2 >> 160 != 0) return;
        (uint256 rawVersion, uint256 rawNonce) = abi.decode(log_.data, (uint256, uint256));
        if (rawVersion == 0 || rawVersion > type(uint64).max || rawNonce == 0 || rawNonce > type(uint64).max) {
            return;
        }
        uint256 streamId = log_.topic1;
        Mirror storage mirror = mirrors[streamId];
        if (!mirror.active || mirror.owner != address(uint160(log_.topic2)) || mirror.version != rawVersion) return;
        if (!_isLater(log_, mirror)) return;
        _request(log_, streamId, mirror.version);
    }

    function _isLater(LogRecord calldata log_, Mirror storage mirror) private view returns (bool) {
        return log_.blockNumber > mirror.blockNumber
            || (log_.blockNumber == mirror.blockNumber && log_.logIndex > mirror.logIndex);
    }

    function _request(LogRecord calldata log_, uint256 streamId, uint64 version) private {
        if (executor == address(0)) return;
        bytes32 eventId = keccak256(abi.encode(log_.chainId, log_.contractAddress, log_.txHash, log_.logIndex, version));
        if (requestedEvents[eventId]) return;
        bytes memory payload = abi.encodeCall(SablierRecoveryExecutor.recover, (address(0), eventId, streamId, version));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: BASE_SEPOLIA_CHAIN_ID, recipient: executor, gasLimit: 600_000, payload: payload
            })
        );
        requestedEvents[eventId] = true;
        emit RecoveryRequested(eventId, streamId, version);
    }

    function coverDebt() external {
        _coverDebt();
    }
}
