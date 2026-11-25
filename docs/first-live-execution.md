# First live Reactive execution

This is one testnet connectivity proof. `RecoverySignal` emitted a controlled eligibility event, `ReclaimReactive` observed it on Lasna and requested a callback, and `ReclaimReceiver` recorded the callback on Base Sepolia. No financial protocol position was checked and no assets were recovered or transferred.

## On-chain trail

| Step | Transaction | Read-only observation |
| --- | --- | --- |
| Base Sepolia origin | [0x2779…c114](https://sepolia.basescan.org/tx/0x2779b675904b4f2f7f7d2a22cb2df34ed5f3112a799d5248732642ebef20c114) | Successful receipt, block 63299610; `PositionEligible` emitted by `RecoverySignal`, origin log index 0. |
| Reactive Lasna execution | [0x5f54…5933](https://lasna-omni.reactscan.net/tx/0x5f547f49be9154bfa6be974608144a1e23bd3e27920f4b2be3759398e0dd5933) | Successful receipt, block 9191333; system callback request and `RecoveryRequested` logs. Receipt `refTx` equals the origin hash and `refEventIndex` is 0. |
| Base Sepolia callback | [0x8c4a…5a52](https://sepolia.basescan.org/tx/0x8c4aa27789f0e43a2e9fda09b458d8be9ee118db06b9e879734ccd3525c35a52) | Successful receipt, block 63299614; transaction from `0xF9F61C1D3325e2d4aBb55dd9e0Db84F7A0D914B0` to callback proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`. Receiver emitted `RecoveryObserved`; gas used: 111079. |

- Position ID: `0x7ef5def7caef1fb1644264761a76b0359ecf9219434ae0225dd64a270510301a`
- Beneficiary: `0xB5BD5F9927ac96213C416662Cc9CFc192c12bA24`
- Event ID: `0x5e11337b7573b221fe7c17a65ece67de34024d30c1d627705be96971b8a7d5ab`

The origin `PositionEligible` topics encode the position ID and beneficiary. The Lasna `RecoveryRequested` topics encode the same event ID and position ID plus the origin transaction hash. The destination `RecoveryObserved` topics encode the same event ID, position ID and beneficiary; its data contains the origin hash. The event ID independently recomputes as `keccak256(abi.encode(uint256(84532), originContract, originTxHash, uint256(0)))`.

The receiver's current `processed(eventId)` is `true` and `processedCount()` is `1`. Its `_SERVICE_PROVIDER()` matches the callback proxy and `_CALLBACK_SENDER()` matches the deployed Lasna coordinator. The successful destination receipt establishes this callback's delivery; a callback request alone would not.

## Deployment and configuration

Read-only receipts show successful deployments of [RecoverySignal](https://sepolia.basescan.org/tx/0xdd0540bb2dc2c5b8578d7068d061ae12817cde0a09c9fbba17faa51624a522a1), [ReclaimReactive](https://lasna-omni.reactscan.net/tx/0xf89d3927c89215e5f2618e816166c857e3f269d92da49c7b13ee0eadea77f1f4) and [ReclaimReceiver](https://sepolia.basescan.org/tx/0xaac9e0c557497a5a5461355302a76fc68fbef45e20aa172033bbbcbae72fadd4) at the addresses in [deployments/testnet.json](../deployments/testnet.json). The Lasna deployment receipt includes a system subscription log for the Base origin and `PositionEligible` topic. The [configuration receipt](https://lasna-omni.reactscan.net/tx/0x614ed941f55f2d3f61d51890eb0f1a902a3e017e78879a085001dfdd83a74547) contains `DestinationConfigured` for the receiver; current `destination()` matches. Successful [Lasna funding](https://lasna-omni.reactscan.net/tx/0x794ca3616bd6cc44f5fa3cb4854b5415f1c5f4cda0f8ac431256c9b07c385143) and [Base funding](https://sepolia.basescan.org/tx/0xe29394a278d1ef53465453d5383e7f2d6f7450baa751120ee0535247beb7f6ff) transactions called `depositTo` with 0.1 REACT and 0.002 ETH respectively. These are transaction values, not current reserve balances.

## Reproduce with read-only Foundry commands

```sh
BASE_RPC=https://sepolia.base.org
LASNA_RPC=https://lasna-rpc.rnk.dev/
ORIGIN=0x0397891a1fEC35C0f7A2bB7B9a7Aa552f62B346E
REACTIVE=0xf5AcBACf7D8eE453Db4a5B714226E1526d773c3C
RECEIVER=0x66d166f509f58bbC71Fd61443Ef7BB498cF8921E
EVENT_ID=0x5e11337b7573b221fe7c17a65ece67de34024d30c1d627705be96971b8a7d5ab

cast chain-id --rpc-url "$BASE_RPC"    # 84532
cast chain-id --rpc-url "$LASNA_RPC"   # 5318007
cast receipt 0x2779b675904b4f2f7f7d2a22cb2df34ed5f3112a799d5248732642ebef20c114 --json --rpc-url "$BASE_RPC"
cast logs 'RecoveryRequested(bytes32 indexed eventId,bytes32 indexed positionId,bytes32 indexed originTxHash)' "$EVENT_ID" --address "$REACTIVE" --from-block 9190914 --to-block 9191333 --json --rpc-url "$LASNA_RPC"
cast receipt 0x5f547f49be9154bfa6be974608144a1e23bd3e27920f4b2be3759398e0dd5933 --json --rpc-url "$LASNA_RPC"
cast receipt 0x8c4aa27789f0e43a2e9fda09b458d8be9ee118db06b9e879734ccd3525c35a52 --json --rpc-url "$BASE_RPC"
cast tx 0x8c4aa27789f0e43a2e9fda09b458d8be9ee118db06b9e879734ccd3525c35a52 --json --rpc-url "$BASE_RPC"
cast call "$REACTIVE" 'originChainId()(uint256)' --rpc-url "$LASNA_RPC"
cast call "$REACTIVE" 'originContract()(address)' --rpc-url "$LASNA_RPC"
cast call "$REACTIVE" 'destination()(address)' --rpc-url "$LASNA_RPC"
cast call "$RECEIVER" '_SERVICE_PROVIDER()(address)' --rpc-url "$BASE_RPC"
cast call "$RECEIVER" '_CALLBACK_SENDER()(address)' --rpc-url "$BASE_RPC"
cast call "$RECEIVER" 'processed(bytes32)(bool)' "$EVENT_ID" --rpc-url "$BASE_RPC"
cast call "$RECEIVER" 'processedCount()(uint256)' --rpc-url "$BASE_RPC"
```

For deployment and funding checks, run `cast receipt <transaction-hash> --json --rpc-url <matching-network-RPC>` using the hashes in the metadata file. Use `cast tx` on the funding hashes to inspect `depositTo` arguments and values. The event ID can be reproduced with `cast abi-encode 'f(uint256,address,uint256,uint256)' 84532 "$ORIGIN" 0x2779b675904b4f2f7f7d2a22cb2df34ed5f3112a799d5248732642ebef20c114 0`, followed by `cast keccak` on the returned bytes.

## Timing and limits

Base receipt block timestamps are `0x6b06675e` (origin) and `0x6b06675f` (callback), a **one second difference in block timestamps** across four Base blocks. This is not a measured end-to-end latency: block timestamps do not identify precise log, Lasna execution or callback delivery times. The Lasna receipt reports `blockTimestamp: 0x0`, so it provides no usable intermediate timestamp here. One successful execution cannot establish a latency guarantee or reliability rate.

This path validates connectivity and callback authentication for a controlled signal only. A financial protocol integration, independent position eligibility checks and actual recovery actions remain unimplemented.
