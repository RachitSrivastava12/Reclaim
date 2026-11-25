# First live OmniCronProbe delivery on Reactive Lasna

This is a read-only reconstruction of the bounded `OmniCronProbe` experiment on Lasna chain `5318007`. The verified observation window ends at block **9199372** (2026-11-25 UTC). The probe is [0x2eCA…c68D](https://lasna-omni.reactscan.net/address/0x2eCAB99a82A3aFF9682Fe4a5A3E333B2636Bc68D). The contract source is [`src/demo/OmniCronProbe.sol`](../src/demo/OmniCronProbe.sol). It subscribes to `Cron100(uint256)` from `0x0000000000000000000000000000000000ffffff` and calls the system contract at `0x8888888888888888888888888888888888888888` to unsubscribe after three unique deliveries.

## Receipts and delivered logs

The [deployment receipt](https://lasna-omni.reactscan.net/tx/0xf5b6ef39ddd1fc3140a71c2f5dee723c72a1e74240aa14d9cfc37ff335011690) has `status=1`, `contractAddress` equal to the probe, and block `9198601`. Its system log `1` records the probe, source chain `5318007`, Cron emitter, `Cron100` topic `0xb49937fb…503c70`, and wildcard values for topics 1–3. A read-only `eth_getCode` call returned 4,324 bytes of code at the probe address. The [funding receipt](https://lasna-omni.reactscan.net/tx/0x82137f6b7ad2e721e97471f017a66cd87112616ef4240a0b40c0e2f6efdb0ca2) has `status=1`, block `9198897`, and a system log for the probe. `eth_getTransactionByHash` independently shows `to` as the system contract, value `100000000000000000` wei (0.1 REACT), and `depositTo(address)` input naming the probe.

The three probe logs have topic `keccak256("CronObserved(uint256,uint256,uint256,uint256)")` = `0x82a2d59b…3dbfd`. Each indexed topic 1 is the origin Cron block, indexed topic 2 is its transaction hash, and the data decodes to origin log index `2` and the delivery count. The origin `Cron100` logs are `LOG2` at the native emitter, have the same block in indexed topic 1, and have empty data. Each successful reaction receipt also has `refChainId=5318007`, `refTx` equal to that origin transaction and `refEventIndex=2`.

| Count | Origin `Cron100` block / transaction / log | Reaction transaction / block |
| --- | --- | --- |
| 1 | `9198700` / [0x89c2…2526](https://lasna-omni.reactscan.net/tx/0x89c2947e0209b861ae0812fdf801c3fed430d5adbf30c9b85e183bd5282d2526) / `2` | [0x4ead…45fd](https://lasna-omni.reactscan.net/tx/0x4eada80a869328410042d2fe18e6fd03ac2940c7226eeff45c9dd7dc325745fd) / `9198701` |
| 2 | `9198900` / [0x2103…a180](https://lasna-omni.reactscan.net/tx/0x2103ae574db1f622408bf950c55c9765e1b64240c84c71d6d5431756b9b0a180) / `2` | [0x57bc…c54a](https://lasna-omni.reactscan.net/tx/0x57bc20d807fb75d5cd6b02b66708190e5c0ebdafb1466def49f76b42809bc54a) / `9198901` |
| 3 | `9199000` / [0x01e3…7684](https://lasna-omni.reactscan.net/tx/0x01e376db9cec758c8aee3020d8be1c6bfa9fe61cfc1cdf2574bb6a70c8587684) / `2` | [0x562b…50e3](https://lasna-omni.reactscan.net/tx/0x562badf997524210327fe8054f1b7046baf5ea9aa8fc23e6295ddb0b704b50e3) / `9199001` |

The source also emitted [Cron100 at block 9198800](https://lasna-omni.reactscan.net/tx/0xa78726d15b7a8e37e9f67f863423df3c742976e91f1c53291cf6a37ffbbaece6), log `2`. The bounded probe-log query has no delivery for that origin and `observedLogs` for its `(txHash, 2)` key is false. The query does not establish why that origin was not delivered; the historical debt snapshot is consistent with a funding pause.

## Shutdown and later emissions

The third [reaction receipt](https://lasna-omni.reactscan.net/tx/0x562badf997524210327fe8054f1b7046baf5ea9aa8fc23e6295ddb0b704b50e3) contains probe log `2`, `ProbeStopped(3)`, followed by **system contract log `3`** with topic `0x15fca4b8…4a944`. Its indexed fields identify the probe, chain `5318007` and Cron emitter; its data repeats the Cron100 topic and the three wildcard topic values from the deployment subscription. The receipt succeeded. This matching system log is evidence of an executed system-level unsubscribe, separate from the probe's own `subscriptionActive=false` state. A direct system subscription-list getter was not used.

The native emitter continued to produce Cron100 at blocks [9199100](https://lasna-omni.reactscan.net/tx/0x17830b68b723bcf3898d480e12d9681be45dce0d4f178e8a2fba3d9c73694ea3), [9199200](https://lasna-omni.reactscan.net/tx/0x6d3c352550183c14ddf7ef14a0791641ecf9342e263bdc1c57b01c283fb320e2), and [9199300](https://lasna-omni.reactscan.net/tx/0x3304874a089d51acd490b4e19af5420f10fa73cadd7b8f6f04c627e12baaaa2a), each at log `2`. A probe `CronObserved` log query from block `9199002` through `9199372` returned **zero** events. This is a bounded observation, not a claim about future blocks.

## State and accounting

At block `9198896`, immediately before funding, read-only getters returned `uniqueDeliveries=1`, `subscriptionActive=true`, system `reserves(probe)=0`, and `debt(probe)=22728800000000000` wei. At funding block `9198897`, the system reserve was `77271200000000000` wei and debt was zero. The identity `100000000000000000 - 22728800000000000 = 77271200000000000` reconciles the funded amount, prior debt and immediately credited reserve.

At the second reaction block `9198901`, reserve was `61662400000000000` wei. At the third reaction block `9199001`, reserve was `44969100000000000` wei, with debt still zero. The reserve decreased by `15608800000000000` wei and `16693300000000000` wei between these block snapshots, totaling `32302100000000000` wei. These are **net reserve changes across blocks**, not itemized execution costs; the receipts do not supply a per-delivery bill. The originally reported “after funding” reserve of `44969100000000000` wei is the later post-shutdown snapshot, not the immediate funding-block reserve.

At the observation cutoff, getters returned `uniqueDeliveries=3`, `subscriptionActive=false`, `lastCronBlockNumber=9199000`, `lastCronTransactionHash=0x01e376db9cec758c8aee3020d8be1c6bfa9fe61cfc1cdf2574bb6a70c8587684`, `lastCronLogIndex=2`, system reserve `44969100000000000` wei and debt `0`. `observedLogs(keccak256(abi.encode(originTxHash, uint256(2))))` is true for each of the three tabled origins and false for the 9198800 origin. This mapping verifies what the probe recorded, while the system receipt establishes the separate unsubscribe action.

## Cron timing

The origin block timestamps for 9198700, 9198800, 9198900, 9199000, 9199100, 9199200 and 9199300 are respectively `06:56:25`, `06:58:12`, `07:00:01`, `07:01:48`, `07:03:36`, `07:05:22` and `07:07:09` UTC on 2026-11-25. The adjacent **block timestamp differences** are `107`, `109`, `107`, `108`, `106` and `107` seconds, with a 100-block gap each time. These describe observed cron emission spacing. They do not measure end-to-end event delivery or reaction latency.

## Reproduce with read-only RPC

These commands use only receipt, transaction, log, block and contract-call methods. `jq` is used to trim the JSON output. Replace `RPC` only if verifying against another Lasna RPC endpoint.

```sh
RPC=https://lasna-rpc.rnk.dev/
PROBE=0x2eCAB99a82A3aFF9682Fe4a5A3E333B2636Bc68D
SYSTEM=0x8888888888888888888888888888888888888888

cast chain-id --rpc-url "$RPC"
cast receipt 0xf5b6ef39ddd1fc3140a71c2f5dee723c72a1e74240aa14d9cfc37ff335011690 --json --rpc-url "$RPC"
cast receipt 0x82137f6b7ad2e721e97471f017a66cd87112616ef4240a0b40c0e2f6efdb0ca2 --json --rpc-url "$RPC"
cast tx 0x82137f6b7ad2e721e97471f017a66cd87112616ef4240a0b40c0e2f6efdb0ca2 --json --rpc-url "$RPC"

# Query both source and probe logs over the fixed observation window.
curl -s "$RPC" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{"fromBlock":"0x8c5c09","toBlock":"0x8c5f0c","address":"0x0000000000000000000000000000000000ffffff","topics":["0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70"]}]}' | jq '.result[] | {blockNumber,transactionHash,logIndex,topics}'
curl -s "$RPC" -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_getLogs","params":[{"fromBlock":"0x8c5c09","toBlock":"0x8c5f0c","address":"0x2eCAB99a82A3aFF9682Fe4a5A3E333B2636Bc68D"}]}' | jq '.result[] | {blockNumber,transactionHash,logIndex,topics,data}'

# Receipt refTx/refEventIndex and the system unsubscribe log are in these raw receipts.
for TX in 0x4eada80a869328410042d2fe18e6fd03ac2940c7226eeff45c9dd7dc325745fd 0x57bc20d807fb75d5cd6b02b66708190e5c0ebdafb1466def49f76b42809bc54a 0x562badf997524210327fe8054f1b7046baf5ea9aa8fc23e6295ddb0b704b50e3; do
  curl -s "$RPC" -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$TX\"]}" | jq '.result | {status,blockNumber,refChainId,refTx,refEventIndex,logs}'
done

cast call "$PROBE" 'uniqueDeliveries()(uint256)' --block 9198896 --rpc-url "$RPC"
cast call "$PROBE" 'subscriptionActive()(bool)' --block 9198896 --rpc-url "$RPC"
cast call "$PROBE" 'uniqueDeliveries()(uint256)' --block 9199372 --rpc-url "$RPC"
cast call "$PROBE" 'subscriptionActive()(bool)' --block 9199372 --rpc-url "$RPC"
cast call "$PROBE" 'lastCronBlockNumber()(uint256)' --block 9199372 --rpc-url "$RPC"
cast call "$PROBE" 'lastCronTransactionHash()(uint256)' --block 9199372 --rpc-url "$RPC"
cast call "$PROBE" 'lastCronLogIndex()(uint256)' --block 9199372 --rpc-url "$RPC"
for BLOCK in 9198896 9198897 9198901 9199001 9199372; do
  cast call "$SYSTEM" 'reserves(address)(uint256)' "$PROBE" --block "$BLOCK" --rpc-url "$RPC"
  cast call "$SYSTEM" 'debt(address)(uint256)' "$PROBE" --block "$BLOCK" --rpc-url "$RPC"
done

# Keys are keccak256(abi.encode(originTxHash, uint256(2))).
for KEY in 0x66fb39ff97b1525f9a718a2d77c83320dbb14a629d559ae957b4bbba60629234 0xc09f85b45ab819361b88bf998c6ee23a9c74a6bdf816f4820f4ed7e03ce7df10 0x95cd2b68de12630d710a3094218bffa509e6c1b29e4dad3751b2cbcb1f1cf93a 0x74d8b4a8b1fad1eea7ecd3cc743b4dcfc8e6f8d06a1f8aeb8c92d5bafa714574; do
  cast call "$PROBE" 'observedLogs(bytes32)(bool)' "$KEY" --block 9199372 --rpc-url "$RPC"
done
for BLOCK in 9198700 9198800 9198900 9199000 9199100 9199200 9199300; do
  cast block "$BLOCK" --json --rpc-url "$RPC" | jq '{number,timestamp}'
done
```

The first three mapping keys in the command follow the delivered rows in order; the last is the undelivered 9198800 log. The pre-funding values were also supplied as historical terminal observations, and were independently reproduced above with historical RPC calls. No broadcast transaction, wallet or private key is needed to reproduce this evidence.
