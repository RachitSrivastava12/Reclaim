# RECLAIM

RECLAIM is a Reactive Omni Buildathon prototype. Its testnet deployment proves a cross-chain event and callback path. It does **not** recover assets from a financial protocol.

## Architecture

1. `RecoverySignal` emits `PositionEligible(positionId, beneficiary)` on Base Sepolia. This is a controlled test signal, not a protocol position check.
2. `ReclaimReactive` subscribes to that log on Reactive Lasna, checks its source and topics, derives an event ID from the origin chain, contract, transaction hash and log index, then requests a Base Sepolia callback.
3. The Base Sepolia callback proxy calls `ReclaimReceiver.record`. The receiver checks the proxy and reactive sender, deduplicates the event ID and emits `RecoveryObserved`. It never transfers funds.

Deployment metadata is in [deployments/testnet.json](deployments/testnet.json). The independently checked execution and read-only commands are in [docs/first-live-execution.md](docs/first-live-execution.md).

## Build and test

Requires Foundry and the checked-out `lib/reactive-lib-omni` and `lib/forge-std` dependencies. Initialize Git submodules if needed.

```sh
forge build
forge test -vv
forge fmt --check
```

`test/ReclaimReceiver.t.sol` covers callback authorization, deduplication and controlled signal validation. The repository also retains the Foundry starter `Counter` contract, script and tests.

## Testnet deployment

| Network | Contract | Address |
| --- | --- | --- |
| [Base Sepolia](https://sepolia.basescan.org/) (84532) | [RecoverySignal](https://sepolia.basescan.org/address/0x0397891a1fEC35C0f7A2bB7B9a7Aa552f62B346E) | `0x0397891a1fEC35C0f7A2bB7B9a7Aa552f62B346E` |
| Base Sepolia | [ReclaimReceiver](https://sepolia.basescan.org/address/0x66d166f509f58bbC71Fd61443Ef7BB498cF8921E) | `0x66d166f509f58bbC71Fd61443Ef7BB498cF8921E` |
| [Reactive Lasna](https://lasna-omni.reactscan.net/) (5318007) | [ReclaimReactive](https://lasna-omni.reactscan.net/address/0xf5AcBACf7D8eE453Db4a5B714226E1526d773c3C) | `0xf5AcBACf7D8eE453Db4a5B714226E1526d773c3C` |

See [README-START-HERE.md](README-START-HERE.md) for the detailed deployment procedure. Those instructions broadcast transactions; the evidence commands in the execution document are read-only.

## Current limits

One live eligibility signal produced a Lasna execution and an authenticated, successful Base callback. The receiver only records that signal. No financial protocol adapter, position validation, claim, refund or asset transfer exists. One execution does not establish reliability or end-to-end latency.
