# RECLAIM

RECLAIM is a Reactive Omni Buildathon prototype. A verified Base Sepolia and Reactive Lasna testnet execution recovered the remaining recipient balance of a canceled Sablier Lockup stream. It used **rUSD, a demonstration token with no monetary value**. One execution does not establish production readiness or reliability.

## Architecture

1. The employee opts into a non-transferable Sablier stream by enrolling with `SablierRecoveryExecutor` on Base Sepolia and setting a maximum protocol withdrawal fee.
2. `SablierRecoveryReactive` mirrors enrollment state on Reactive Lasna. When Sablier emits `CancelLockupStream`, it derives an event ID from the Base chain ID, Sablier address, transaction hash, log index and policy version, then requests a callback.
3. The official Base Sepolia callback proxy calls the executor. The executor checks both the proxy and the reactive sender, verifies the policy and Sablier state, and calls Sablier to withdraw the employee's remaining balance **directly to the employee**. On depletion it completes the policy and credits the unused fee reserve for withdrawal.
4. A later Lasna reaction to `PolicyCompleted` deactivates the mirrored enrollment.

The original `RecoverySignal` → `ReclaimReactive` → `ReclaimReceiver` path remains a controlled signal demonstration; its receiver only records events. Deployment metadata is in [deployments/testnet.json](deployments/testnet.json). Read-only evidence is in [docs/first-live-sablier-recovery.md](docs/first-live-sablier-recovery.md) and [docs/first-live-execution.md](docs/first-live-execution.md).

## Verified Sablier milestone

For stream **213**, the employer deposited **300 rUSD**. Cancellation refunded **265.833333333333333334 rUSD** to the employer. A Reactive callback recovered the remaining **34.166666666666666666 rUSD** from Sablier directly to the employee. The token-unit amounts sum exactly to the original deposit. The successful cancellation, Lasna reaction, callback and completion reaction are linked by receipt references and decoded events in the evidence document. The Sablier withdrawal fee was **0 wei**; the employee's **0.0005 ETH** enrollment fee reserve became refundable credit. The cancellation and callback Base block timestamps differ by one second; this is **not** a measured end-to-end latency.

## Build and test

Requires Foundry and the checked-out `lib/reactive-lib-omni` and `lib/forge-std` dependencies. Initialize Git submodules if needed.

```sh
forge build
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

See [README-START-HERE.md](README-START-HERE.md) for the detailed deployment procedure. Those instructions broadcast transactions; the evidence commands in the execution document are read-only.

## Current limits

The Sablier path is verified for one non-transferable testnet stream and a valueless demonstration token. The earlier eligibility-signal path remains separate. There is no production safety or reliability claim, and block timestamp differences do not measure end-to-end latency. Callback proxy reserves and debt are observable, but the available receipt does not itemize a per-callback bill.
