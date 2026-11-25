// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {SablierRecoveryExecutorV2} from "./SablierRecoveryExecutorV2.sol";

/// @notice Bounded, event-acknowledged V2 recovery coordinator for Reactive Lasna.
contract SablierRecoveryReactiveV2 is AbstractReactive {
    error OnlyOwner();
    error InvalidSource();
    error DestinationAlreadySet();
    error ShutdownPermanent();
    error InvalidBudget();

    uint256 public constant BASE = 84_532;
    uint256 public constant LASNA = 5_318_007;
    address public constant CRON_EMITTER = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant CRON_TOPIC = uint256(keccak256("Cron100(uint256)"));
    uint256 public constant CANCEL_TOPIC =
        uint256(keccak256("CancelLockupStream(uint256,address,address,address,uint128,uint128)"));
    uint256 public constant ENROLLED_TOPIC =
        uint256(keccak256("PolicyEnrolled(uint256,address,uint64,uint256,uint40,uint8)"));
    uint256 public constant REVOKED_TOPIC = uint256(keccak256("PolicyRevoked(uint256,address,uint64)"));
    uint256 public constant COMPLETED_TOPIC = uint256(keccak256("PolicyCompleted(uint256,address,uint64)"));
    uint256 public constant RETRY_TOPIC = uint256(keccak256("RecoveryRetryRequested(uint256,address,uint64,uint64)"));
    uint256 public constant SUCCEEDED_TOPIC =
        uint256(keccak256("RecoverySucceeded(bytes32,uint256,address,address,uint128,uint256)"));
    uint256 public constant SKIPPED_TOPIC = uint256(keccak256("RecoverySkipped(bytes32,uint256,uint64,uint8)"));

    uint256 public constant MAX_ACTIVE = 64;
    uint256 public constant MAX_OPS_PER_TICK = 10;
    uint256 public constant MAX_CALLBACKS_PER_TICK = 3;
    uint256 public constant MAX_FAILED_REQUESTS_PER_TICK = 2;
    uint256 public constant MAX_GLOBAL_CALLBACKS = 512;
    uint8 public constant MAX_ATTEMPTS = 5;
    uint8 public constant MAX_LIFETIME_ATTEMPTS = 10;
    uint8 public constant MAX_LIFETIME_SUBMISSION_FAILURES = 5;
    uint40 public constant MATURITY_BUFFER = 120;
    uint40 public constant ACK_TIMEOUT = 600;
    uint40 public constant COOLDOWN = 300;
    uint40 public constant TERMINAL_TIMEOUT = 1 days;
    uint64 public constant CALLBACK_GAS_LIMIT = 600_000;

    enum State {
        Untracked,
        Dormant,
        Scheduled,
        Pending,
        Acknowledged,
        Retryable,
        TerminalPending,
        Completed,
        Revoked,
        Exhausted
    }

    struct Policy {
        address owner;
        uint64 version;
        uint64 retryNonce;
        uint40 endTime;
        uint40 dueAt;
        uint8 mode;
        uint8 attempts;
        State state;
        bytes32 pendingId;
        bool admitted;
    }

    struct Cancellation {
        address recipient;
        uint256 blockNumber;
        uint256 logIndex;
    }

    address public immutable owner;
    address public immutable sablier;
    address public executor;
    bool public paused;
    bool public shutdown;
    uint256 public callbackBudget;
    uint256 public callbacksSubmitted;
    mapping(uint256 => bool) public streamAllowed;
    uint256 public activeCount;
    uint256 public heapSize;
    uint256[65] private heap;
    mapping(uint256 => uint256) public heapIndex;
    mapping(uint256 => Policy) public policies;
    mapping(uint256 => uint256) public maxFeeWei;
    mapping(uint256 => uint8) public lifetimeAttempts;
    mapping(uint256 => uint8) public submissionFailures;
    mapping(uint256 => uint40) public lastAttemptAt;
    mapping(uint256 => Cancellation) public cancellations;
    mapping(bytes32 => bool) public observedCron;
    uint256 public lastCronBlock;

    event DestinationConfigured(address indexed destination);
    event AdmissionRejected(uint256 indexed streamId, uint64 version);
    event CallbackRequested(bytes32 indexed eventId, uint256 indexed streamId, uint64 version, uint8 attempt);
    event CallbackAcknowledged(bytes32 indexed eventId, uint256 indexed streamId, uint8 reason);
    event PolicyStateChanged(uint256 indexed streamId, uint64 version, State state);
    event Paused(bool value);
    event Shutdown();
    event CallbackRequestFailed(uint256 indexed streamId, uint64 version);
    event CallbackBudgetSet(uint256 value);
    event StreamAllowed(uint256 indexed streamId, bool value);

    constructor(address sablier_) payable {
        if (sablier_ == address(0)) revert InvalidSource();
        owner = msg.sender;
        sablier = sablier_;
        SYSTEM.subscribe(BASE, sablier_, CANCEL_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(LASNA, CRON_EMITTER, CRON_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setDestination(address executor_) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (shutdown) revert ShutdownPermanent();
        if (executor != address(0)) revert DestinationAlreadySet();
        if (executor_ == address(0)) revert InvalidSource();
        executor = executor_;
        SYSTEM.subscribe(BASE, executor_, ENROLLED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(BASE, executor_, REVOKED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(BASE, executor_, COMPLETED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(BASE, executor_, RETRY_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(BASE, executor_, SUCCEEDED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(BASE, executor_, SKIPPED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit DestinationConfigured(executor_);
    }

    function setPaused(bool value) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (shutdown) revert ShutdownPermanent();
        paused = value;
        emit Paused(value);
    }

    function setStreamAllowed(uint256 id, bool value) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (shutdown) revert ShutdownPermanent();
        streamAllowed[id] = value;
        emit StreamAllowed(id, value);
    }

    function setCallbackBudget(uint256 value) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (shutdown) revert ShutdownPermanent();
        if (value < callbacksSubmitted || value > MAX_GLOBAL_CALLBACKS) revert InvalidBudget();
        callbackBudget = value;
        emit CallbackBudgetSet(value);
    }

    function shutdownPermanently() external {
        if (msg.sender != owner) revert OnlyOwner();
        if (shutdown) revert ShutdownPermanent();
        shutdown = true;
        SYSTEM.unsubscribe(BASE, sablier, CANCEL_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.unsubscribe(LASNA, CRON_EMITTER, CRON_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        if (executor != address(0)) {
            SYSTEM.unsubscribe(BASE, executor, ENROLLED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.unsubscribe(BASE, executor, REVOKED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.unsubscribe(BASE, executor, COMPLETED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.unsubscribe(BASE, executor, RETRY_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.unsubscribe(BASE, executor, SUCCEEDED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.unsubscribe(BASE, executor, SKIPPED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        emit Shutdown();
    }

    function coverDebt() external {
        _coverDebt();
    }

    function heapHead() external view returns (uint256) {
        return heapSize == 0 ? 0 : heap[1];
    }

    function heapAt(uint256 index) external view returns (uint256) {
        return index > 0 && index <= heapSize ? heap[index] : 0;
    }

    function releaseTimedOutTerminal(uint256 id) external {
        Policy storage p = policies[id];
        if (p.state != State.TerminalPending || !p.admitted || block.timestamp < p.dueAt) return;
        _retire(id);
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (shutdown) {
            if (
                log_.chainId == BASE && log_.contractAddress == executor && executor != address(0)
                    && (log_.topic0 == REVOKED_TOPIC || log_.topic0 == COMPLETED_TOPIC)
            ) _terminal(log_, log_.topic0 == REVOKED_TOPIC ? State.Revoked : State.Completed);
            return;
        }
        if (log_.chainId == LASNA && log_.contractAddress == CRON_EMITTER && log_.topic0 == CRON_TOPIC) {
            _cron(log_);
        } else if (log_.chainId == BASE && log_.contractAddress == sablier && log_.topic0 == CANCEL_TOPIC) {
            _cancel(log_);
        } else if (log_.chainId == BASE && log_.contractAddress == executor && executor != address(0)) {
            if (log_.topic0 == ENROLLED_TOPIC) _enroll(log_);
            else if (log_.topic0 == REVOKED_TOPIC) _terminal(log_, State.Revoked);
            else if (log_.topic0 == COMPLETED_TOPIC) _terminal(log_, State.Completed);
            else if (log_.topic0 == RETRY_TOPIC) _retry(log_);
            else if (log_.topic0 == SUCCEEDED_TOPIC) _success(log_);
            else if (log_.topic0 == SKIPPED_TOPIC) _skip(log_);
        }
    }

    function _validOwner(uint256 word) private pure returns (bool) {
        return word != 0 && word >> 160 == 0;
    }

    function _enroll(LogRecord calldata log_) private {
        if (log_.opCode != 3 || log_.topic3 != 0 || !_validOwner(log_.topic2) || log_.data.length != 128) return;
        (uint256 v, uint256 feeCap, uint256 end, uint256 mode) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint256));
        if (v == 0 || v > type(uint64).max || end == 0 || end > type(uint40).max || mode > 2) return;
        uint256 id = log_.topic1;
        Policy storage p = policies[id];
        if (v <= p.version) return;
        _remove(id);
        if (p.admitted) {
            p.admitted = false;
            activeCount--;
        }
        p.owner = address(uint160(log_.topic2));
        maxFeeWei[id] = feeCap;
        p.version = uint64(v);
        p.retryNonce = 0;
        p.endTime = uint40(end);
        p.mode = uint8(mode);
        p.attempts = 0;
        p.pendingId = 0;
        if (submissionFailures[id] == MAX_LIFETIME_SUBMISSION_FAILURES) {
            p.state = State.Exhausted;
            emit PolicyStateChanged(id, p.version, p.state);
            return;
        }
        if (activeCount == MAX_ACTIVE || !streamAllowed[id] || shutdown) {
            p.state = State.Untracked;
            emit AdmissionRejected(id, p.version);
            return;
        }
        p.admitted = true;
        activeCount++;
        Cancellation storage c = cancellations[id];
        if (mode != 1 && c.recipient == p.owner) {
            p.state = State.Scheduled;
            _schedule(id, _now());
        } else if (mode != 0) {
            p.state = State.Scheduled;
            _schedule(
                id, p.endTime > type(uint40).max - MATURITY_BUFFER ? type(uint40).max : p.endTime + MATURITY_BUFFER
            );
        } else {
            p.state = State.Dormant;
        }
        emit PolicyStateChanged(id, p.version, p.state);
    }

    function _terminal(LogRecord calldata log_, State state) private {
        if (log_.opCode != 3 || log_.topic3 != 0 || !_validOwner(log_.topic2) || log_.data.length != 32) return;
        uint256 v = abi.decode(log_.data, (uint256));
        if (v == 0 || v > type(uint64).max) return;
        uint256 id = log_.topic1;
        Policy storage p = policies[id];
        if (v < p.version || (v == p.version && p.owner != address(uint160(log_.topic2)))) return;
        _remove(id);
        if (p.admitted) {
            p.admitted = false;
            activeCount--;
        }
        p.owner = address(uint160(log_.topic2));
        p.version = uint64(v);
        p.pendingId = 0;
        p.state = state;
        emit PolicyStateChanged(id, p.version, state);
    }

    function _retry(LogRecord calldata log_) private {
        if (log_.opCode != 3 || log_.topic3 != 0 || !_validOwner(log_.topic2) || log_.data.length != 64) return;
        (uint256 v, uint256 nonce) = abi.decode(log_.data, (uint256, uint256));
        if (v == 0 || v > type(uint64).max || nonce == 0 || nonce > type(uint64).max) return;
        uint256 id = log_.topic1;
        Policy storage p = policies[id];
        if (!p.admitted || p.version != v || p.owner != address(uint160(log_.topic2)) || nonce <= p.retryNonce) return;
        p.retryNonce = uint64(nonce);
        if (p.state == State.Pending || p.state == State.Exhausted || p.state == State.TerminalPending) return;
        uint40 next = _later(_timePlus(COOLDOWN), _maturityDue(id, p));
        if (p.state != State.Dormant && p.dueAt < next) next = p.dueAt;
        p.state = State.Retryable;
        _schedule(id, next);
    }

    function _cancel(LogRecord calldata log_) private {
        if (
            log_.opCode != 4 || log_.topic0 != CANCEL_TOPIC || !_validOwner(log_.topic1) || !_validOwner(log_.topic2)
                || !_validOwner(log_.topic3) || log_.data.length != 96
        ) return;
        (uint256 id, uint256 senderAmount, uint256 recipientAmount) = abi.decode(log_.data, (uint256, uint256, uint256));
        if (senderAmount > type(uint128).max || recipientAmount == 0 || recipientAmount > type(uint128).max) return;
        Cancellation storage c = cancellations[id];
        if (log_.blockNumber < c.blockNumber || (log_.blockNumber == c.blockNumber && log_.logIndex <= c.logIndex)) {
            return;
        }
        c.recipient = address(uint160(log_.topic2));
        c.blockNumber = log_.blockNumber;
        c.logIndex = log_.logIndex;
        Policy storage p = policies[id];
        if (
            p.admitted && p.mode != 1 && p.owner == c.recipient && p.state != State.Pending
                && p.state != State.Exhausted && p.state != State.TerminalPending
        ) {
            p.state = State.Scheduled;
            _schedule(id, _now());
        }
    }

    function _success(LogRecord calldata log_) private {
        if (log_.opCode != 4 || log_.topic1 == 0 || !_validOwner(log_.topic3) || log_.data.length != 96) return;
        (uint256 token, uint256 amount,) = abi.decode(log_.data, (uint256, uint256, uint256));
        if (token >> 160 != 0 || amount == 0 || amount > type(uint128).max) return;
        uint256 id = log_.topic2;
        Policy storage p = policies[id];
        if (
            !p.admitted || p.state != State.Pending || p.pendingId != bytes32(log_.topic1)
                || p.owner != address(uint160(log_.topic3))
        ) return;
        p.pendingId = 0;
        p.state = State.Acknowledged;
        // A successful withdrawal can be partial. Wait for PolicyCompleted; later retry is bounded.
        _schedule(id, _timePlus(ACK_TIMEOUT));
        emit CallbackAcknowledged(bytes32(log_.topic1), id, type(uint8).max);
    }

    function _skip(LogRecord calldata log_) private {
        if (log_.opCode != 3 || log_.topic1 == 0 || log_.topic3 != 0 || log_.data.length != 64) return;
        (uint256 v, uint256 reason) = abi.decode(log_.data, (uint256, uint256));
        if (v == 0 || v > type(uint64).max || reason > 10) return;
        uint256 id = log_.topic2;
        Policy storage p = policies[id];
        if (!p.admitted || p.version != v || p.state != State.Pending || p.pendingId != bytes32(log_.topic1)) return;
        p.pendingId = 0;
        emit CallbackAcknowledged(bytes32(log_.topic1), id, uint8(reason));
        if (reason == 1 || reason == 2 || reason == 3 || reason == 6) {
            // Terminal executor events accompany owner-change and depletion skips.
            p.state = State.TerminalPending;
            _schedule(id, _timePlus(TERMINAL_TIMEOUT));
        } else {
            _schedule(id, _timePlus(COOLDOWN));
            p.state = State.Retryable;
        }
    }

    function _cron(LogRecord calldata log_) private {
        if (
            log_.opCode != 2 || log_.topic1 == 0 || log_.topic1 % 100 != 0 || log_.topic1 != log_.blockNumber
                || log_.topic2 != 0 || log_.topic3 != 0 || log_.data.length != 0 || log_.txHash == 0
        ) return;
        bytes32 key = keccak256(abi.encode(log_.txHash, log_.logIndex));
        if (observedCron[key]) return;
        observedCron[key] = true;
        lastCronBlock = log_.topic1;
        if (paused || shutdown || executor == address(0)) return;
        uint256 sent;
        uint256 failed;
        for (uint256 i; i < MAX_OPS_PER_TICK && heapSize != 0; ++i) {
            uint256 id = heap[1];
            Policy storage p = policies[id];
            if (uint256(p.dueAt) > block.timestamp) break;
            if (p.state == State.TerminalPending) {
                _retire(id);
                continue;
            }
            if (p.state == State.Pending && uint256(p.dueAt) <= block.timestamp) {
                p.pendingId = 0; // No Base acknowledgement arrived within the timeout.
                p.state = State.Retryable;
            }
            if (p.attempts == MAX_ATTEMPTS || lifetimeAttempts[id] == MAX_LIFETIME_ATTEMPTS) {
                _retire(id);
                p.state = State.Exhausted;
                emit PolicyStateChanged(id, p.version, p.state);
                continue;
            }
            if (
                sent == MAX_CALLBACKS_PER_TICK || failed == MAX_FAILED_REQUESTS_PER_TICK
                    || callbacksSubmitted == callbackBudget
            ) break;
            _remove(id);
            bytes32 eventId = keccak256(abi.encode(address(this), id, p.version, p.attempts + 1));
            bytes memory payload =
                abi.encodeCall(SablierRecoveryExecutorV2.recover, (address(0), eventId, id, p.version));
            try SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: BASE, recipient: executor, gasLimit: CALLBACK_GAS_LIMIT, payload: payload
                })
            ) {}
            catch {
                failed++;
                submissionFailures[id]++;
                emit CallbackRequestFailed(id, p.version);
                if (submissionFailures[id] == MAX_LIFETIME_SUBMISSION_FAILURES) {
                    _retire(id);
                    p.state = State.Exhausted;
                    emit PolicyStateChanged(id, p.version, p.state);
                } else {
                    p.state = State.Retryable;
                    _schedule(id, _timePlus(COOLDOWN));
                }
                continue;
            }
            callbacksSubmitted++;
            p.attempts++;
            lifetimeAttempts[id]++;
            lastAttemptAt[id] = _now();
            p.pendingId = eventId;
            p.state = State.Pending;
            _schedule(id, _timePlus(ACK_TIMEOUT));
            emit CallbackRequested(eventId, id, p.version, p.attempts);
            sent++;
        }
    }

    function _retire(uint256 id) private {
        _remove(id);
        Policy storage p = policies[id];
        if (p.admitted) {
            p.admitted = false;
            activeCount--;
        }
    }

    function _timePlus(uint40 delta) private view returns (uint40) {
        return block.timestamp >= type(uint40).max - delta ? type(uint40).max : uint40(block.timestamp) + delta;
    }

    function _now() private view returns (uint40) {
        return block.timestamp >= type(uint40).max ? type(uint40).max : uint40(block.timestamp);
    }

    function _later(uint40 a, uint40 b) private pure returns (uint40) {
        return a > b ? a : b;
    }

    function _maturityDue(uint256 id, Policy storage p) private view returns (uint40) {
        if (p.mode == 0 || (p.mode == 2 && cancellations[id].recipient == p.owner)) return 0;
        return p.endTime > type(uint40).max - MATURITY_BUFFER ? type(uint40).max : p.endTime + MATURITY_BUFFER;
    }

    function _schedule(uint256 id, uint40 dueAt) private {
        Policy storage p = policies[id];
        if (!p.admitted) return;
        uint40 last = lastAttemptAt[id];
        uint40 cooldownEnds = last > type(uint40).max - COOLDOWN ? type(uint40).max : last + COOLDOWN;
        if (dueAt < cooldownEnds) dueAt = cooldownEnds;
        p.dueAt = dueAt;
        uint256 i = heapIndex[id];
        if (i == 0) {
            heapSize++;
            i = heapSize;
            heap[i] = id;
            heapIndex[id] = i;
        }
        _up(i);
        _down(heapIndex[id]);
    }

    function _remove(uint256 id) private {
        uint256 i = heapIndex[id];
        if (i == 0) return;
        uint256 last = heap[heapSize];
        heap[heapSize] = 0;
        heapSize--;
        heapIndex[id] = 0;
        if (i <= heapSize) {
            heap[i] = last;
            heapIndex[last] = i;
            _up(i);
            _down(heapIndex[last]);
        }
    }

    function _less(uint256 a, uint256 b) private view returns (bool) {
        uint40 x = policies[heap[a]].dueAt;
        uint40 y = policies[heap[b]].dueAt;
        return x < y || (x == y && heap[a] < heap[b]);
    }

    function _swap(uint256 a, uint256 b) private {
        uint256 x = heap[a];
        uint256 y = heap[b];
        heap[a] = y;
        heap[b] = x;
        heapIndex[x] = b;
        heapIndex[y] = a;
    }

    function _up(uint256 i) private {
        while (i > 1 && _less(i, i / 2)) {
            _swap(i, i / 2);
            i /= 2;
        }
    }

    function _down(uint256 i) private {
        while (i * 2 <= heapSize) {
            uint256 child = i * 2;
            if (child + 1 <= heapSize && _less(child + 1, child)) child++;
            if (!_less(child, i)) break;
            _swap(i, child);
            i = child;
        }
    }
}
