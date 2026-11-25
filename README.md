# RECLAIM

RECLAIM is a Reactive Omni Buildathon prototype. Verified Base Sepolia and Reactive Lasna testnet executions recovered the recipient balances of a canceled Sablier stream (V1) and a matured Sablier stream (V2). Both used **rUSD, a demonstration token with no monetary value**. These individual executions do not establish production readiness or reliability.

## Architecture

1. The employee opts into a non-transferable Sablier stream by enrolling with `SablierRecoveryExecutor` on Base Sepolia and setting a maximum protocol withdrawal fee.
2. `SablierRecoveryReactive` mirrors enrollment state on Reactive Lasna. When Sablier emits `CancelLockupStream`, it derives an event ID from the Base chain ID, Sablier address, transaction hash, log index and policy version, then requests a callback.
3. The official Base Sepolia callback proxy calls the executor. The executor checks both the proxy and the reactive sender, verifies the policy and Sablier state, and calls Sablier to withdraw the employee's remaining balance **directly to the employee**. On depletion it completes the policy and credits the unused fee reserve for withdrawal.
4. A later Lasna reaction to `PolicyCompleted` deactivates the mirrored enrollment.

V2 uses separate `SablierRecoveryExecutorV2` and `SablierRecoveryReactiveV2` contracts. The employee can choose a maturity policy; the executor reads Sablier's end time, and the bounded coordinator schedules a callback from a native Cron100 tick after a 120-second buffer. The executor checks Base chain time and Sablier state before any direct withdrawal. A Base completion event closes the Lasna policy.

The original `RecoverySignal` → `ReclaimReactive` → `ReclaimReceiver` path remains a controlled signal demonstration; its receiver only records events. A separate bounded `OmniCronProbe` experiment verified live native Cron100 delivery and system unsubscription on Lasna. Deployment metadata is in [deployments/testnet.json](deployments/testnet.json). Read-only evidence is in [docs/first-live-sablier-recovery.md](docs/first-live-sablier-recovery.md), [docs/first-live-execution.md](docs/first-live-execution.md) and [docs/first-live-cron-delivery.md](docs/first-live-cron-delivery.md).

## Verified V2 autonomous maturity milestone

For stream **214**, the employee enrolled a non-transferable, 300 rUSD stream in V2 `Maturity` mode. The V2 Lasna coordinator processed that enrollment and, after the Sablier end time plus its 120-second buffer, a native Cron100 event triggered **one** callback request. The official Base Sepolia callback proxy reached the V2 executor, which withdrew **300 rUSD directly from Sablier to the employee**. The employee's balance rose from `34166666666666666666` to `334166666666666666666` token units. The callback emitted `RecoverySucceeded` and `PolicyCompleted`; two Lasna reactions acknowledged success and marked the coordinator policy `Completed`. Sablier is depleted, the executor holds zero rUSD, and the employee has `500000000000000` wei of refundable fee credit. No successful manual withdrawal, cancellation or retry was observed for stream 214 in bounded deployment-to-head event scans. [Full V2 receipt and state evidence](docs/first-live-maturity-recovery.md) links every step.

The V2 demonstration coordinator received 0.5 REACT of Lasna system funding. After recovery, continuous idle Cron100 reactions consumed its reserve and created **0.0038719 REACT** of debt. The owner [permanently shut it down](https://lasna-omni.reactscan.net/tx/0xb20f065c4a9f03163be9ae2fe7337461e08e037728666cb264909cd218a78cba), removing all eight subscriptions including Cron100, then [settled the debt](https://lasna-omni.reactscan.net/tx/0x99ba6821cc5f05b1ea0f27fa91c2271ba1924e95ec42067512a7395b20f1ae8b). Verified final Lasna state is `shutdown=true`, `debt=0`, `reserves=0`. This retired coordinator cannot perform new autonomous recoveries; they require a fresh coordinator and corresponding executor deployment. [Full V2 evidence and retirement record](docs/first-live-maturity-recovery.md#coordinator-retirement-and-debt-settlement) preserves the earlier reserve and debt snapshots.

## Verified Sablier milestone

For stream **213**, the employer deposited **300 rUSD**. Cancellation refunded **265.833333333333333334 rUSD** to the employer. A Reactive callback recovered the remaining **34.166666666666666666 rUSD** from Sablier directly to the employee. The token-unit amounts sum exactly to the original deposit. The successful cancellation, Lasna reaction, callback and completion reaction are linked by receipt references and decoded events in the evidence document. The Sablier withdrawal fee was **0 wei**; the employee's **0.0005 ETH** enrollment fee reserve became refundable credit. The cancellation and callback Base block timestamps differ by one second; this is **not** a measured end-to-end latency.

## Verified Cron100 probe milestone

On Reactive Lasna, [OmniCronProbe](https://lasna-omni.reactscan.net/address/0x2eCAB99a82A3aFF9682Fe4a5A3E333B2636Bc68D) recorded three distinct native Cron100 logs from blocks `9198700`, `9198900` and `9199000`. The third successful reaction emitted `ProbeStopped(3)` and a matching system unsubscribe log. Three subsequent Cron100 emissions at blocks `9199100`, `9199200` and `9199300` produced no further probe delivery through block `9199372`. The probe's final getters show count `3` and inactive state; system reserve was `44969100000000000` wei and debt `0`. The [evidence document](docs/first-live-cron-delivery.md) links each origin log and reaction, verifies funding and reserve arithmetic, and gives read-only reproduction commands. Cron block timestamp spacing was 106–109 seconds; it is not a delivery-latency measurement.

## Build and test

Requires Foundry and the checked-out `lib/reactive-lib-omni` and `lib/forge-std` dependencies. Initialize Git submodules if needed.

Future local builds, CI checks and deployments use the pinned Foundry configuration in `foundry.toml`: Solidity 0.8.35 with the optimizer enabled at 200 runs. Run `forge build --sizes` before deployment to enforce the EIP-170 runtime limit. The addresses and transaction evidence below belong to earlier deployments built under the previous, unpinned configuration; this change does not alter or reclassify those historical contracts.

```sh
forge build
forge build --sizes
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org forge test -vv
forge fmt --check
```

`test/SablierRecovery.t.sol` covers callback authorization, policy state, fee reserves and replay guards. `test/SablierRecoveryFork.t.sol` runs a local fork against deployed Sablier when `BASE_SEPOLIA_RPC_URL` is set. The repository also retains the controlled signal tests and Foundry starter files.

## Testnet deployment

| Network | Contract | Address |
| --- | --- | --- |
| [Base Sepolia](https://sepolia.basescan.org/) (84532) | [RecoverySignal](https://sepolia.basescan.org/address/0x0397891a1fEC35C0f7A2bB7B9a7Aa552f62B346E) | `0x0397891a1fEC35C0f7A2bB7B9a7Aa552f62B346E` |
| Base Sepolia | [ReclaimReceiver](https://sepolia.basescan.org/address/0x66d166f509f58bbC71Fd61443Ef7BB498cF8921E) | `0x66d166f509f58bbC71Fd61443Ef7BB498cF8921E` |
| [Reactive Lasna](https://lasna-omni.reactscan.net/) (5318007) | [ReclaimReactive](https://lasna-omni.reactscan.net/address/0xf5AcBACf7D8eE453Db4a5B714226E1526d773c3C) | `0xf5AcBACf7D8eE453Db4a5B714226E1526d773c3C` |
| Base Sepolia | [Sablier Lockup](https://sepolia.basescan.org/address/0xA65A1ecEf02C2B9BDc604951c6A6D02335D4532e) | `0xA65A1ecEf02C2B9BDc604951c6A6D02335D4532e` |
| Base Sepolia | [SablierRecoveryExecutor](https://sepolia.basescan.org/address/0x94A5898f1c411051313e0572e577FeA5F667C9B1) | `0x94A5898f1c411051313e0572e577FeA5F667C9B1` |
| Base Sepolia | [ReclaimDemoToken (rUSD)](https://sepolia.basescan.org/address/0x2f3A8806D9094dD7866e04635B400F65587e5Fb2) | `0x2f3A8806D9094dD7866e04635B400F65587e5Fb2` |
| Reactive Lasna | [SablierRecoveryReactive](https://lasna-omni.reactscan.net/address/0xc9af1EaA0a212A425aCC5efC5752807F5181C019) | `0xc9af1EaA0a212A425aCC5efC5752807F5181C019` |
| Reactive Lasna | [OmniCronProbe](https://lasna-omni.reactscan.net/address/0x2eCAB99a82A3aFF9682Fe4a5A3E333B2636Bc68D) | `0x2eCAB99a82A3aFF9682Fe4a5A3E333B2636Bc68D` |
| Base Sepolia | [SablierRecoveryExecutorV2](https://sepolia.basescan.org/address/0x1B5E99E9FE6d75AcCC6983ac28ffDCD97bc6553B) | `0x1B5E99E9FE6d75AcCC6983ac28ffDCD97bc6553B` |
| Reactive Lasna | [SablierRecoveryReactiveV2](https://lasna-omni.reactscan.net/address/0xA219Ef314436207E5c242f89ad02fe1Fc71B6568) | `0xA219Ef314436207E5c242f89ad02fe1Fc71B6568` |

See [README-START-HERE.md](README-START-HERE.md) for the detailed deployment procedure. Those instructions broadcast transactions; the evidence commands in the execution document are read-only.

## Current limits

The Sablier paths are verified for two non-transferable testnet streams and a valueless demonstration token. The earlier eligibility-signal path and bounded Cron100 probe remain separate. There is no production safety or reliability claim, and block timestamp differences do not measure end-to-end latency. Callback proxy and Lasna system reserves and debt are observable, but the available receipts do not itemize per-callback or per-reaction bills.
