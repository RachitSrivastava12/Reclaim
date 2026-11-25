# First live Sablier cancellation recovery on testnet

Verified with read-only Base Sepolia (`84532`) and Reactive Lasna (`5318007`) RPC calls on 2026-11-25. This is one successful testnet execution, not a reliability or production-readiness claim. The token is **rUSD, a demonstration token with no monetary value**.

## Contracts and transaction trail

| Role | Network | Address |
| --- | --- | --- |
| Sablier Lockup | Base Sepolia | [`0xA65A…532e`](https://sepolia.basescan.org/address/0xA65A1ecEf02C2B9BDc604951c6A6D02335D4532e) |
| Recovery executor | Base Sepolia | [`0x94A5…C9B1`](https://sepolia.basescan.org/address/0x94A5898f1c411051313e0572e577FeA5F667C9B1) |
| Reactive coordinator | Reactive Lasna | [`0xc9af…C019`](https://lasna-omni.reactscan.net/address/0xc9af1EaA0a212A425aCC5efC5752807F5181C019) |
| Demo token | Base Sepolia | [`0x2f3A…e5Fb2`](https://sepolia.basescan.org/address/0x2f3A8806D9094dD7866e04635B400F65587e5Fb2) |
| Callback proxy | Base Sepolia | [`0x476F…3585`](https://sepolia.basescan.org/address/0x476F44b11F5C942c58f4c8E3d0300E5710743585) |

The proxy address matches the [Reactive Network Base Sepolia deployment table](https://dev.reactive.network/origins-and-destinations). The employer is `0xB5BD5F9927ac96213C416662Cc9CFc192c12bA24`; the employee and stream recipient is `0xD88f3b7479C3555b3c6d24D9EABBcCE18ec0dDd3`.

| Step | Transaction | Receipt and evidence |
| --- | --- | --- |
| Create stream 213 | [Base `0x7500…4114`](https://sepolia.basescan.org/tx/0x75006514a3de2fc42397b6e12db5fac5d4443191af1daa3a1e51a06c4bca4114) | Success, block `63325897`, 2026-11-25 06:10:48 UTC. `CreateLockupLinearStream` at log `10` records the 300 rUSD deposit, employer sender, employee recipient, token, cancelable `true`, transferable `false`. Token `Transfer` at log `9` moves `300000000000000000000` units from employer to Sablier. |
| Enroll | [Base `0x4dcc…12e4`](https://sepolia.basescan.org/tx/0x4dccf559924a51deca775c659d7a7f9d07c1c2d71ce358db431d53f7c95112e4) | Success, block `63326397`, 06:12:28 UTC. Employee calls `enroll(213, 500000000000000)` with `500000000000000` wei. `PolicyEnrolled` log `6`: stream 213, employee, version 1, maximum Sablier fee `500000000000000` wei. `FeeReserveAdded` log `7`: same stream, employee and amount. |
| Cancel | [Base `0x9469…0746`](https://sepolia.basescan.org/tx/0x94690db4dfd48c5c589143b10394bff0705fb4b08b47782f0ed3c4b192950746) | Success, block `63326922`, 06:14:13 UTC. `CancelLockupStream` log **1**: employer, employee, token, stream 213, sender refund `265833333333333333334`, recipient amount `34166666666666666666` token units. Token `Transfer` log `0` moves the refund from Sablier to employer. |
| React to cancellation | [Lasna `0xe711…81cf`](https://lasna-omni.reactscan.net/tx/0xe711993a621cb42bd041e3429de86329a0ef10b752eeed216b09b89a55ac81cf) | Success, block `9196354`. Receipt has `refChainId=84532`, `refTx` equal to the cancellation hash, and `refEventIndex=1`. System callback-request log `1` targets Base Sepolia, the executor and 600,000 gas. Coordinator `RecoveryRequested` log `2` has the event ID below, stream 213 and version 1. |
| Recover | [Base `0x49e7…3d65`](https://sepolia.basescan.org/tx/0x49e72e70bb6a691c9dd4bcb2072bb83b08698dfce36d4053a526738ee4ff3d65) | Success, block `63326926`, 06:14:14 UTC. Transaction `to` is the official callback proxy; its calldata targets the executor and contains the authenticated coordinator address, event ID, stream 213 and version 1. Token `Transfer` log `2`, Sablier `WithdrawFromLockupStream` log `3`, executor `RecoverySucceeded` log `5` and `PolicyCompleted` log `6` agree on the recovered amount and recipient. |
| React to completion | [Lasna `0xe6f3…f0e0`](https://lasna-omni.reactscan.net/tx/0xe6f37134ad32661167d9a55fa405a8eb64fdbee4a9f4aa0b904477df9ae1f0e0) | Success, block `9196355`. Receipt has `refTx` equal to the recovery callback hash and `refEventIndex=6`, the `PolicyCompleted` log. Transaction input carries the executor source, completion topic, stream and employee; the mirror is inactive at this block. No coordinator output event is expected for this branch. |

The creation receipt also shows Sablier minting the stream NFT (ERC-721 `Transfer`, log `7`) to the employee. The cancellation Lasna transaction input contains the cancellation topic, Sablier address, Base block `63326922`, cancellation transaction hash, log index `1`, stream 213 and the two cancellation amounts. This connects the `refTx` receipt metadata to the actual delivered log. The executor's immutable `CALLBACK_PROXY()` reads as `0x476F44b11F5C942c58f4c8E3d0300E5710743585`, `REACTIVE_SENDER()` reads as the coordinator, and `SABLIER()` reads as the stated Lockup contract. Together with the successful executor logs inside a transaction addressed to the official proxy, these verify the route and authentication configuration.

## Event ID and amounts

The coordinator computes `keccak256(abi.encode(uint256(84532), Sablier, cancellationTxHash, uint256(1), uint64(1)))`. Independent ABI encoding and hashing gives:

```text
0x288dc2c215b4fd087d2bdebda5ce62b3738d88273233484f02c3faae169c3d0c
```

This equals the Lasna `RecoveryRequested` topic, Base `RecoverySucceeded` topic, callback payload and `requestedEvents` / `recoveredEvents` mapping key. The index is the receipt's global log index `1`, not the position of the Sablier log among only Sablier logs.

The token reports `symbol() = rUSD` and `decimals() = 18`. All amounts below are **integer token units**; display values are exact decimal conversions, not floating-point estimates.

| Flow | Token units | rUSD |
| --- | ---: | ---: |
| Deposited by employer into Sablier | `300000000000000000000` | `300` |
| Refunded directly from Sablier to employer on cancellation | `265833333333333333334` | `265.833333333333333334` |
| Recovered directly from Sablier to employee on callback | `34166666666666666666` | `34.166666666666666666` |

`265833333333333333334 + 34166666666666666666 = 300000000000000000000` exactly. The callback receipt's ERC-20 `Transfer` has **from Sablier, to employee**, never the executor. The employee's token balance changes from `0` in Base block `63326925` to `34166666666666666666` in block `63326926`; the executor's token balance is `0` on the observed latest state. The Sablier withdrawal event and executor success event encode the same recovered amount. `RecoverySucceeded` records `feeWei=0` for this withdrawal.

## Final state and callback billing

At Base block `63326926`, `policies(213)` is `(employee, maxFeeWei=500000000000000, reserveWei=0, version=1, retryNonce=0, active=false)`. `feeCredits(employee)=500000000000000` wei: the unspent enrollment reserve is **refundable credit**, not evidence it was withdrawn. `recoveredEvents(eventId)=true`. Sablier reports `wasCanceled=true`, `isDepleted=true`, `withdrawableAmountOf(213)=0`, the employee as recipient, and `isTransferable=false`. The executor's native balance was `1500000000000000` wei when checked, equal to its `1000000000000000` wei callback reserve plus the `500000000000000` wei fee credit. Its `callbackReserveWei` remained `1000000000000000` wei across the recovery block.

At Lasna block `9196354`, `requestedEvents(eventId)=true`. At block `9196355`, `mirrors(213)` is `(employee, version=1, blockNumber=63326926, logIndex=6, active=false)`, matching the completion log. This verifies the recorded replay guards and mirror deactivation; it does not test how future deliveries or network failures behave.

The callback proxy's `debt(executor)` was `0` both before and after the recovery block. Its `reserves(executor)` decreased from `1999132350800000` wei at Base block `63326925` to `1997254413200000` wei at block `63326926`, a **net decrease of `1877937600000` wei**. The latter is also the observed remaining proxy reserve. The executor's separate callback reserve remained `1000000000000000` wei; Lasna system `debt(coordinator)=0` and `reserves(coordinator)=46807300000000000` wei when checked. These are separate accounting pools. The receipt exposes no itemized proxy billing record, so the proxy-reserve change is a block-level net change, not an independently proven per-callback fee. A read-only `getCallbacks(uint256)` query using the cancellation Reactive transaction hash returned an empty array despite the successful destination receipt; its reason is unverified.

Base block timestamps are `0x6b067cb5` for cancellation and `0x6b067cb6` for callback, **one second apart**. Lasna reports `0x6b067cb4` for the cancellation reaction and `0x6b067cb5` for completion. These are independently set block timestamps, including a Lasna timestamp one second earlier than the referenced Base cancellation block. They do **not** measure end-to-end latency or establish transaction observation, finality or user-perceived completion time.

## Reproduce with read-only commands

Run from a shell with Foundry `cast` and `jq`. No command below signs or broadcasts a transaction.

```sh
BASE_RPC=https://sepolia.base.org
LASNA_RPC=https://lasna-rpc.rnk.dev/
SABLIER=0xA65A1ecEf02C2B9BDc604951c6A6D02335D4532e
EXECUTOR=0x94A5898f1c411051313e0572e577FeA5F667C9B1
REACTIVE=0xc9af1EaA0a212A425aCC5efC5752807F5181C019
PROXY=0x476F44b11F5C942c58f4c8E3d0300E5710743585
TOKEN=0x2f3A8806D9094dD7866e04635B400F65587e5Fb2
EMPLOYEE=0xD88f3b7479C3555b3c6d24D9EABBcCE18ec0dDd3
CANCEL=0x94690db4dfd48c5c589143b10394bff0705fb4b08b47782f0ed3c4b192950746
EVENT_ID=0x288dc2c215b4fd087d2bdebda5ce62b3738d88273233484f02c3faae169c3d0c

cast chain-id --rpc-url "$BASE_RPC"
cast chain-id --rpc-url "$LASNA_RPC"
cast receipt 0x75006514a3de2fc42397b6e12db5fac5d4443191af1daa3a1e51a06c4bca4114 --rpc-url "$BASE_RPC" --json
cast receipt 0x4dccf559924a51deca775c659d7a7f9d07c1c2d71ce358db431d53f7c95112e4 --rpc-url "$BASE_RPC" --json
cast receipt "$CANCEL" --rpc-url "$BASE_RPC" --json
cast receipt 0x49e72e70bb6a691c9dd4bcb2072bb83b08698dfce36d4053a526738ee4ff3d65 --rpc-url "$BASE_RPC" --json
cast rpc --rpc-url "$LASNA_RPC" eth_getTransactionReceipt 0xe711993a621cb42bd041e3429de86329a0ef10b752eeed216b09b89a55ac81cf
cast rpc --rpc-url "$LASNA_RPC" eth_getTransactionReceipt 0xe6f37134ad32661167d9a55fa405a8eb64fdbee4a9f4aa0b904477df9ae1f0e0
cast rpc --rpc-url "$LASNA_RPC" eth_getTransactionByHash 0xe711993a621cb42bd041e3429de86329a0ef10b752eeed216b09b89a55ac81cf
cast rpc --rpc-url "$BASE_RPC" eth_getTransactionByHash 0x49e72e70bb6a691c9dd4bcb2072bb83b08698dfce36d4053a526738ee4ff3d65

ENCODED=$(cast abi-encode 'f(uint256,address,bytes32,uint256,uint64)' 84532 "$SABLIER" "$CANCEL" 1 1)
cast keccak "$ENCODED"
cast call "$EXECUTOR" 'CALLBACK_PROXY()(address)' --rpc-url "$BASE_RPC"
cast call "$EXECUTOR" 'REACTIVE_SENDER()(address)' --rpc-url "$BASE_RPC"
cast call "$EXECUTOR" 'policies(uint256)(address,uint256,uint256,uint64,uint64,bool)' 213 --block 63326926 --rpc-url "$BASE_RPC"
cast call "$EXECUTOR" 'feeCredits(address)(uint256)' "$EMPLOYEE" --block 63326926 --rpc-url "$BASE_RPC"
cast call "$EXECUTOR" 'recoveredEvents(bytes32)(bool)' "$EVENT_ID" --block 63326926 --rpc-url "$BASE_RPC"
cast call "$EXECUTOR" 'callbackReserveWei()(uint256)' --block 63326926 --rpc-url "$BASE_RPC"
cast balance "$EXECUTOR" --rpc-url "$BASE_RPC"
cast call "$SABLIER" 'wasCanceled(uint256)(bool)' 213 --rpc-url "$BASE_RPC"
cast call "$SABLIER" 'isDepleted(uint256)(bool)' 213 --block 63326926 --rpc-url "$BASE_RPC"
cast call "$SABLIER" 'withdrawableAmountOf(uint256)(uint128)' 213 --rpc-url "$BASE_RPC"
cast call "$SABLIER" 'getRecipient(uint256)(address)' 213 --rpc-url "$BASE_RPC"
cast call "$SABLIER" 'isTransferable(uint256)(bool)' 213 --rpc-url "$BASE_RPC"
cast call "$REACTIVE" 'requestedEvents(bytes32)(bool)' "$EVENT_ID" --block 9196354 --rpc-url "$LASNA_RPC"
cast call "$REACTIVE" 'mirrors(uint256)(address,uint64,uint256,uint256,bool)' 213 --block 9196355 --rpc-url "$LASNA_RPC"
cast call "$TOKEN" 'balanceOf(address)(uint256)' "$EMPLOYEE" --block 63326925 --rpc-url "$BASE_RPC"
cast call "$TOKEN" 'balanceOf(address)(uint256)' "$EMPLOYEE" --block 63326926 --rpc-url "$BASE_RPC"
cast call "$TOKEN" 'balanceOf(address)(uint256)' "$EXECUTOR" --rpc-url "$BASE_RPC"
cast call "$PROXY" 'reserves(address)(uint256)' "$EXECUTOR" --block 63326925 --rpc-url "$BASE_RPC"
cast call "$PROXY" 'reserves(address)(uint256)' "$EXECUTOR" --block 63326926 --rpc-url "$BASE_RPC"
cast call "$PROXY" 'debt(address)(uint256)' "$EXECUTOR" --rpc-url "$BASE_RPC"
cast call 0x8888888888888888888888888888888888888888 'reserves(address)(uint256)' "$REACTIVE" --rpc-url "$LASNA_RPC"
cast call 0x8888888888888888888888888888888888888888 'debt(address)(uint256)' "$REACTIVE" --rpc-url "$LASNA_RPC"
cast call 0x8888888888888888888888888888888888888888 'getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])' 0xe711993a621cb42bd041e3429de86329a0ef10b752eeed216b09b89a55ac81cf --rpc-url "$LASNA_RPC"

TOPIC=$(cast keccak 'RecoveryRequested(bytes32,uint256,uint64)')
cast rpc --rpc-url "$LASNA_RPC" eth_getLogs "{\"fromBlock\":\"0x8c51e0\",\"toBlock\":\"0x8c53d3\",\"address\":\"$REACTIVE\",\"topics\":[\"$TOPIC\",\"$EVENT_ID\"]}"
```

The bounded Lasna event query returns the cancellation Reactive execution above; compare its receipt `refTx` and `refEventIndex` before associating it with the Base cancellation.

The receipts and state prove this one testnet path. They do not prove production safety, repeatability, exact end-to-end latency, deployment transaction hashes for the new contracts, or a fully itemized callback bill.
