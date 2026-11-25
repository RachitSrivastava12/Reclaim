# RECLAIM / First genuine Reactive callback

This is a **protocol connectivity milestone**. It records an authenticated eligibility event on Base Sepolia via Lasna. It does **not** claim, refund, or transfer real assets.

## 0. Add files to an initialized Foundry repo
Unzip the starter into the root of your `~/reclaim` Foundry project. It adds three `src/*.sol` files and one `test/*.t.sol` file; it does not overwrite existing `foundry.toml` or `.gitignore`.

## 1. Install the current Reactive Omni library, NOT the legacy library

```bash
cd ~/reclaim
forge install Reactive-Network/reactive-lib-omni
printf '@reactive/=lib/reactive-lib-omni/\n' >> remappings.txt
forge build
forge test -vv
```

If `forge build` fails, stop and inspect the compiler error rather than deploying.

## 2. Network settings

- Base Sepolia (chain 84532): origin and callback recipient
- Lasna (chain 5318007): reactive coordinator, RPC `https://lasna-rpc.rnk.dev/`
- Base Sepolia callback proxy: `0x476F44b11F5C942c58f4c8E3d0300E5710743585`
- Lasna system: `0x8888888888888888888888888888888888888888`

```bash
export BASE_RPC_URL='https://sepolia.base.org'
export LASNA_RPC_URL='https://lasna-rpc.rnk.dev/'
export PROXY='0x476F44b11F5C942c58f4c8E3d0300E5710743585'
cast chain-id --rpc-url "$BASE_RPC_URL"      # 84532
cast chain-id --rpc-url "$LASNA_RPC_URL"     # 5318007
cast code "$PROXY" --rpc-url "$BASE_RPC_URL" # nonempty
```

Use a fresh throwaway testnet-only wallet; don't paste secrets in the chat or store a private key in a shell command or repository. Create/import an encrypted Foundry account with `cast wallet import reclaim-test --interactive` and use `--account reclaim-test` when broadcasting. **Fund the SAME address on Base Sepolia (test ETH) and Lasna (test REACT)**. To obtain lREACT, use the official testnet faucet procedure (read https://dev.reactive.network/debugging and verify official faucet address there before sending).

## 3. Deploy in this exact order

### A. Origin on Base Sepolia
```bash
forge create src/RecoverySignal.sol:RecoverySignal --broadcast \
 --rpc-url "$BASE_RPC_URL" --account reclaim-test
```
Copy printed `Deployed to:` address:
```bash
export ORIGIN=0xPASTE_ORIGIN_ADDRESS
```

### B. Coordinator on Lasna
```bash
forge create src/ReclaimReactive.sol:ReclaimReactive --broadcast \
 --rpc-url "$LASNA_RPC_URL" --account reclaim-test \
 --constructor-args 84532 "$ORIGIN"
```
Copy address:
```bash
export REACTIVE=0xPASTE_REACTIVE_ADDRESS
```

### C. Authenticated callback target on Base Sepolia
```bash
forge create src/ReclaimReceiver.sol:ReclaimReceiver --broadcast \
 --rpc-url "$BASE_RPC_URL" --account reclaim-test \
 --constructor-args "$PROXY" "$REACTIVE"
```
Copy address:
```bash
export RECEIVER=0xPASTE_RECEIVER_ADDRESS
```

### D. Wire destination on Lasna
```bash
cast send "$REACTIVE" 'setDestination(address)' "$RECEIVER" \
 --rpc-url "$LASNA_RPC_URL" --account reclaim-test
```

### E. Fund both execution paths (small testnet-only amounts)
Use the proxy's `depositTo` API so debt is cleared and reserves credited. Example values below are testnet *starting examples*, not guaranteed sufficient amounts. The callback proxy uses ETH on Base and Lasna system uses REACT on Lasna.
```bash
cast send 0x8888888888888888888888888888888888888888 \
 'depositTo(address)' "$REACTIVE" --value 0.1ether \
 --rpc-url "$LASNA_RPC_URL" --account reclaim-test

cast send "$PROXY" 'depositTo(address)' "$RECEIVER" --value 0.002ether \
 --rpc-url "$BASE_RPC_URL" --account reclaim-test
```

### F. Trigger one real event (Base Sepolia)
```bash
export BENEFICIARY=$(cast wallet address --account reclaim-test)
export POSITION_ID=$(cast keccak 'first-reclaim-test')

cast send "$ORIGIN" 'signalEligible(bytes32,address)' "$POSITION_ID" "$BENEFICIARY" \
 --rpc-url "$BASE_RPC_URL" --account reclaim-test
```
Save the returned origin transaction hash. Locate the Lasna `RecoveryRequested` transaction and resulting Base `RecoveryObserved` event in chain explorers. **Do not call the callback manually** and label that as a network callback.

Verify receiver state:
```bash
cast call "$RECEIVER" 'processedCount()(uint256)' --rpc-url "$BASE_RPC_URL"
```
Expected: 1 after successful callback, not immediately after posting the signal.

## 4. Evidence and failure debugging

- Origin `PositionEligible` must be on Base Sepolia.
- Lasna `RecoveryRequested` must exist for the same origin tx and event ID.
- Destination `RecoveryObserved` must be in a **different transaction initiated via the official callback proxy**.
- Never infer success solely from a CallbackRequest: delivery can fail.
- Check reserves/debt, proxy address, callback authentication, and callback gas if the last step fails.
- Public documentation: https://dev.reactive.network/debugging

## Scope
`ReclaimReceiver` records one event only; it does not validate positions in a financial protocol or recover money. That needs an audited adapter and real integration after this genuine three-chain transaction path works.
