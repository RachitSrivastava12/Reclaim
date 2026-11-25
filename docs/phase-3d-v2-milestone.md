# Phase 3D V2 executor milestone

## Architecture and threat model

The existing cancellation-only executor and coordinator remain unchanged. `SablierRecoveryExecutorV2` is a separate Base Sepolia deployment target. Its recipient opts in to `Cancellation`, `Maturity`, or `Either` mode and funds a Sablier protocol-fee reserve. Enrollment reads Sablier's `getEndTime(streamId)` and emits that value for a future coordinator; callers cannot supply a deadline. A successful recovery calls Sablier `withdraw(streamId, currentRecipient, amount)` directly, so the executor never receives the recovered token.

Only the configured Base callback proxy can invoke `recover`, and the proxy-injected Reactive sender must equal the configured coordinator address. The callback also checks policy version, current recipient, non-transferability, depletion, mode, current Sablier end time, positive withdrawable amount, fee cap, and user reserve. A depleted stream is completed and its unused fee reserve becomes owner credit. A failed withdrawal leaves the event ID retryable. An operator-only callback reserve is accounted separately from user fee reserves. The existing reentrancy guard covers recovery and native transfers.

Enrollment rejects streams that are already depleted before recording a policy or accepting a fee reserve. External Sablier view failures during `recover`, including the post-withdrawal depletion read, revert the whole callback. The withdrawal and any emitted logs roll back atomically, so the same event ID can be retried. There is no bounded on-chain protocol-read failure event: the future coordinator must recognize a missing Base acknowledgement, wait for its timeout, then retry within its budget. A reverted callback may still incur proxy/Reactive delivery cost.

The key untrusted inputs are enrollment transactions, delivered origin logs, cron records, and callback payloads. The executor treats all scheduling hints as hints: Sablier state on Base decides whether a withdrawal can happen. A delayed callback for an earlier policy version cannot recover a new enrollment. A recipient change invalidates the policy and credits the original owner. The `recoveredEvents` key marks only successful withdrawals, never callback requests or skipped attempts.

## Coordinator design still required

This milestone does **not** deploy or implement a V2 Reactive coordinator; it does not autonomously schedule maturity recovery. The verified native Cron100 event is a Lasna `LOG2` from `0x0000000000000000000000000000000000ffffff`, with `Cron100(uint256)` in topic 0, a block number divisible by 100 in topic 1, and empty data. It supplies no trustworthy Base timestamp. A future coordinator may use Lasna time only to decide when to *try* a callback; the executor must keep checking the actual Base time and Sablier end time.

That coordinator needs a fixed-capacity indexed heap or queue and a fixed per-tick operation cap. It should subscribe to Cron100 continuously, avoiding subscribe/unsubscribe races; operating cost is one Lasna reaction per delivered Cron100 tick, plus bounded queue work and attempted callbacks, even when no streams are due. Enrollment events need version and log-order tombstones. Completion must follow verified Base `PolicyCompleted` or `PolicyRevoked` events, never `requestCallbackV_1_0` success. Failed delivery must remain retryable with a cooldown and per-item retry cap or budget; missed ticks must be caught up by later ticks. The queue must not scan historical enrollments or permit public callers to trigger callback requests. Bounds, retry policy, gas limits, reserve funding, and starvation behavior need tests before deployment.

Repeated public enrollments and owner retries can still cause operator-funded callbacks to exhaust the callback reserve. The executor's separate accounting protects user reserves and credits, but cannot bound this cost. The coordinator must enforce bounded admission, per-policy callback rate limits, cooldowns, and retry budgets before production use.

## Executor event ABI and scheduler correlation

The following signatures are the exact `topic0` inputs. `indexed` parameters occupy topics in declaration order after `topic0`; the `data` column lists static ABI words in order (32 bytes each). All events are emitted by the V2 executor address, which the coordinator must verify with Base chain ID and log ordering.

| Event signature | Indexed topics | Data words |
| --- | --- | --- |
| `PolicyEnrolled(uint256,address,uint64,uint256,uint40,uint8)` | `streamId`, `owner` | `version`, `maxFeeWei`, `endTime`, `mode` |
| `PolicyRevoked(uint256,address,uint64)` | `streamId`, `owner` | `version` |
| `PolicyCompleted(uint256,address,uint64)` | `streamId`, `owner` | `version` |
| `RecoveryRetryRequested(uint256,address,uint64,uint64)` | `streamId`, `owner` | `version`, `retryNonce` |
| `FeeReserveAdded(uint256,address,uint256)` | `streamId`, `owner` | `amount` |
| `FeeCreditWithdrawn(address,uint256)` | `owner` | `amount` |
| `CallbackReserveAdded(uint256)` | none | `amount` |
| `CallbackReserveWithdrawn(uint256)` | none | `amount` |
| `RecoverySucceeded(bytes32,uint256,address,address,uint128,uint256)` | `eventId`, `streamId`, `recipient` | `token`, `amount`, `feeWei` |
| `RecoverySkipped(bytes32,uint256,uint64,uint8)` | `eventId`, `streamId` | `version`, `reason` |

`mode` and `reason` are ABI-encoded enum values (`uint8`): modes 0 Cancellation, 1 Maturity, 2 Either; skip reasons 0 Duplicate, 1 NoPolicy, 2 StalePolicy, 3 OwnerChanged, 4 NotCanceled, 5 NotMatured, 6 Depleted, 7 NothingWithdrawable, 8 FeeTooHigh, 9 InsufficientReserve, 10 WithdrawFailed. `RecoverySucceeded` carries no version; match its `eventId` to a pending callback record containing `streamId` and version, and verify the current enrollment history. A success followed by `PolicyCompleted` in the same transaction closes that version. `PolicyCompleted` can also accompany a `RecoverySkipped(Depleted)` when a user withdrew manually; correlate by transaction, stream ID, and version. `PolicyRevoked` can be explicit or can accompany `RecoverySkipped(OwnerChanged)` in the same transaction. Neither terminal policy event contains a callback ID, so an explicit owner revocation is correlated by version and ordered Base logs, not by pending callback ID. Skips leave the policy active except OwnerChanged and Depleted; they do not consume `eventId`. A reverted callback emits none of these events.

## Compiler and lint review

Solc compiles the V2 contract without compiler diagnostics. Forge lint reports `reentrancy-eth` on four native transfers, `reentrancy-events` on five events following external calls, `non-reentrant-not-first` on three guarded functions, and `block-timestamp` on two maturity comparisons. The native transfer paths debit their dedicated balance before calling out and execute under `nonReentrant`; authenticated nested recovery is tested. Events after calls describe committed results and cannot be forged by reentry into guarded functions. The modifier-order notices flag style and gas ordering, while authorization is checked before entering the guard. Base block time is deliberately compared with Sablier's current end time, and Sablier itself enforces withdrawal eligibility. These warnings warrant review but do not reveal an unguarded V2 withdrawal or user-reserve drain. No lint suppression was added. Existing V1 and Reactive warnings are outside this milestone.

## Verification scope

The local V2 tests also cover depleted enrollment, an authenticated nested callback, all three modes across four cancellation/maturity states, nonzero fee restoration on failed withdrawal, payment and debt isolation, and failed protocol reads. The Base Sepolia fork tests use real non-transferable streams for cancellation and maturity and check `getEndTime` after cancellation. They do not prove Reactive delivery, cron scheduling, subscription billing, or live callback reliability.
