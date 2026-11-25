// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IPayer} from "@reactive/src/interfaces/IPayer.sol";
import {ISablierLockup} from "./ISablierLockup.sol";

/// @notice Opt-in recovery of canceled, non-transferable Sablier Lockup streams.
contract SablierRecoveryExecutor is IPayer {
    error InvalidSablier();
    error InvalidCallbackConfiguration();
    error UnauthorizedOwner();
    error TransferableStream();
    error ReentrantCall();
    error NoCredit();
    error CreditTransferFailed();
    error OnlyOperator();
    error CallbackNotAuthorized(address sender, address expectedSender);
    error ProxyNotAuthorized(address sender, address expectedProxy);
    error InsufficientCallbackReserve();
    error EmptyRetry();

    enum SkipReason {
        Duplicate,
        NoPolicy,
        StalePolicy,
        OwnerChanged,
        NotCanceled,
        Depleted,
        NothingWithdrawable,
        FeeTooHigh,
        InsufficientReserve,
        WithdrawFailed
    }

    struct Policy {
        address owner;
        uint256 maxFeeWei;
        uint256 reserveWei;
        uint64 version;
        uint64 retryNonce;
        bool active;
    }

    ISablierLockup public immutable SABLIER;
    IPayable public immutable CALLBACK_PROXY;
    address public immutable REACTIVE_SENDER;
    address public immutable operator;
    uint256 public callbackReserveWei;
    mapping(uint256 => Policy) public policies;
    mapping(address => uint256) public feeCredits;
    mapping(bytes32 => bool) public recoveredEvents;
    bool private entered;

    event PolicyEnrolled(uint256 indexed streamId, address indexed owner, uint64 version, uint256 maxFeeWei);
    event PolicyRevoked(uint256 indexed streamId, address indexed owner, uint64 version);
    event PolicyCompleted(uint256 indexed streamId, address indexed owner, uint64 version);
    event RecoveryRetryRequested(uint256 indexed streamId, address indexed owner, uint64 version, uint64 retryNonce);
    event FeeReserveAdded(uint256 indexed streamId, address indexed owner, uint256 amount);
    event FeeCreditWithdrawn(address indexed owner, uint256 amount);
    event CallbackReserveAdded(uint256 amount);
    event CallbackReserveWithdrawn(uint256 amount);
    event RecoverySucceeded(
        bytes32 indexed eventId,
        uint256 indexed streamId,
        address indexed recipient,
        address token,
        uint128 amount,
        uint256 feeWei
    );
    event RecoverySkipped(bytes32 indexed eventId, uint256 indexed streamId, uint64 version, SkipReason reason);

    constructor(IPayable callbackProxy, address reactiveSender, ISablierLockup sablier) {
        if (address(sablier) == address(0) || address(sablier).code.length == 0) revert InvalidSablier();
        if (address(callbackProxy) == address(0) || reactiveSender == address(0)) {
            revert InvalidCallbackConfiguration();
        }
        SABLIER = sablier;
        CALLBACK_PROXY = callbackProxy;
        REACTIVE_SENDER = reactiveSender;
        operator = msg.sender;
    }

    modifier onlyServiceProvider() {
        if (msg.sender != address(CALLBACK_PROXY)) revert ProxyNotAuthorized(msg.sender, address(CALLBACK_PROXY));
        _;
    }

    modifier onlyCallbackSender(address sender) {
        if (sender != REACTIVE_SENDER) revert CallbackNotAuthorized(sender, REACTIVE_SENDER);
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    /// @dev Native funds sent by the operator are separate from enrolled owners' protocol-fee reserves.
    receive() external payable onlyOperator {
        callbackReserveWei += msg.value;
        emit CallbackReserveAdded(msg.value);
    }

    function fundCallbackReserve() external payable onlyOperator {
        callbackReserveWei += msg.value;
        emit CallbackReserveAdded(msg.value);
    }

    function withdrawCallbackReserve(uint256 amount) external onlyOperator nonReentrant {
        if (amount > callbackReserveWei) revert InsufficientCallbackReserve();
        callbackReserveWei -= amount;
        (bool ok,) = payable(operator).call{value: amount}("");
        if (!ok) revert CreditTransferFailed();
        emit CallbackReserveWithdrawn(amount);
    }

    /// @inheritdoc IPayer
    function pay(uint256 amount) external onlyServiceProvider nonReentrant {
        if (amount > callbackReserveWei) revert InsufficientCallbackReserve();
        callbackReserveWei -= amount;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert CreditTransferFailed();
    }

    /// @notice Settle proxy debt using only the operator's callback reserve.
    function coverCallbackDebt() external nonReentrant {
        uint256 amount = CALLBACK_PROXY.debt(address(this));
        if (amount > callbackReserveWei) revert InsufficientCallbackReserve();
        callbackReserveWei -= amount;
        (bool ok,) = payable(address(CALLBACK_PROXY)).call{value: amount}("");
        if (!ok) revert CreditTransferFailed();
    }

    /// @dev Transferrable NFTs are excluded: owner checks alone cannot detect a transfer away and back.
    function enroll(uint256 streamId, uint256 maxFeeWei) external payable nonReentrant {
        if (SABLIER.getRecipient(streamId) != msg.sender) revert UnauthorizedOwner();
        if (SABLIER.isTransferable(streamId)) revert TransferableStream();
        Policy storage policy = policies[streamId];
        if (policy.active || policy.reserveWei != 0) {
            if (policy.owner != msg.sender) revert UnauthorizedOwner();
            feeCredits[msg.sender] += policy.reserveWei;
        }
        policy.owner = msg.sender;
        policy.maxFeeWei = maxFeeWei;
        policy.reserveWei = msg.value;
        policy.version += 1;
        policy.retryNonce = 0;
        policy.active = true;
        emit PolicyEnrolled(streamId, msg.sender, policy.version, maxFeeWei);
        if (msg.value != 0) emit FeeReserveAdded(streamId, msg.sender, msg.value);
    }

    function addFeeReserve(uint256 streamId) external payable nonReentrant {
        Policy storage policy = policies[streamId];
        _checkRetryOwner(streamId, policy);
        if (msg.value == 0) revert EmptyRetry();
        policy.reserveWei += msg.value;
        emit FeeReserveAdded(streamId, msg.sender, msg.value);
        _requestRetry(streamId, policy);
    }

    /// @notice Request one fresh callback after a transient failure or changed fee conditions.
    function requestRetry(uint256 streamId) external nonReentrant {
        Policy storage policy = policies[streamId];
        _checkRetryOwner(streamId, policy);
        _requestRetry(streamId, policy);
    }

    function _checkRetryOwner(uint256 streamId, Policy storage policy) private view {
        if (!policy.active || policy.owner != msg.sender) revert UnauthorizedOwner();
        if (SABLIER.getRecipient(streamId) != msg.sender) revert UnauthorizedOwner();
        if (SABLIER.isTransferable(streamId)) revert TransferableStream();
    }

    function _requestRetry(uint256 streamId, Policy storage policy) private {
        policy.retryNonce += 1;
        emit RecoveryRetryRequested(streamId, policy.owner, policy.version, policy.retryNonce);
    }

    function revoke(uint256 streamId) external nonReentrant {
        Policy storage policy = policies[streamId];
        if (!policy.active || policy.owner != msg.sender) revert UnauthorizedOwner();
        policy.active = false;
        feeCredits[msg.sender] += policy.reserveWei;
        policy.reserveWei = 0;
        emit PolicyRevoked(streamId, msg.sender, policy.version);
    }

    function withdrawFeeCredit() external nonReentrant {
        uint256 amount = feeCredits[msg.sender];
        if (amount == 0) revert NoCredit();
        feeCredits[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert CreditTransferFailed();
        emit FeeCreditWithdrawn(msg.sender, amount);
    }

    /// @dev The proxy injects the authenticated reactive sender as the first payload argument.
    function recover(address reactiveSender, bytes32 eventId, uint256 streamId, uint64 version)
        external
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
        nonReentrant
    {
        if (recoveredEvents[eventId]) return _skip(eventId, streamId, version, SkipReason.Duplicate);
        Policy storage policy = policies[streamId];
        if (!policy.active) return _skip(eventId, streamId, version, SkipReason.NoPolicy);
        if (policy.version != version) return _skip(eventId, streamId, version, SkipReason.StalePolicy);
        address recipient = SABLIER.getRecipient(streamId);
        if (recipient != policy.owner || SABLIER.isTransferable(streamId)) {
            // Permanently invalidate this enrollment; a later owner change cannot revive it.
            policy.active = false;
            feeCredits[policy.owner] += policy.reserveWei;
            policy.reserveWei = 0;
            emit PolicyRevoked(streamId, policy.owner, policy.version);
            return _skip(eventId, streamId, version, SkipReason.OwnerChanged);
        }
        if (!SABLIER.wasCanceled(streamId)) return _skip(eventId, streamId, version, SkipReason.NotCanceled);
        if (SABLIER.isDepleted(streamId)) return _skip(eventId, streamId, version, SkipReason.Depleted);
        uint128 amount = SABLIER.withdrawableAmountOf(streamId);
        if (amount == 0) return _skip(eventId, streamId, version, SkipReason.NothingWithdrawable);
        uint256 feeWei = SABLIER.calculateMinFeeWei(streamId);
        if (feeWei > policy.maxFeeWei) return _skip(eventId, streamId, version, SkipReason.FeeTooHigh);
        if (feeWei > policy.reserveWei) return _skip(eventId, streamId, version, SkipReason.InsufficientReserve);

        // Effects precede the external call. A reverted withdrawal restores the reserved fee.
        policy.reserveWei -= feeWei;
        address token = SABLIER.getUnderlyingToken(streamId);
        try SABLIER.withdraw{value: feeWei}(streamId, recipient, amount) {
            recoveredEvents[eventId] = true;
            emit RecoverySucceeded(eventId, streamId, recipient, token, amount, feeWei);
            // Failure to query completion must not undo a successful withdrawal.
            try SABLIER.isDepleted(streamId) returns (bool depleted) {
                if (depleted) {
                    policy.active = false;
                    feeCredits[policy.owner] += policy.reserveWei;
                    policy.reserveWei = 0;
                    emit PolicyCompleted(streamId, policy.owner, policy.version);
                }
            } catch {}
        } catch {
            policy.reserveWei += feeWei;
            _skip(eventId, streamId, version, SkipReason.WithdrawFailed);
        }
    }

    function _skip(bytes32 eventId, uint256 streamId, uint64 version, SkipReason reason) private {
        emit RecoverySkipped(eventId, streamId, version, reason);
    }
}
