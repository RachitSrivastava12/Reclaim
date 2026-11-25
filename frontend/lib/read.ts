import { address, baseClient, lasnaClient, executorAbi, coordinatorAbi, sablierAbi } from './chain';
import { parseAbi, type Address } from 'viem';

const billingAbi = parseAbi(['function reserves(address) view returns (uint256)', 'function debt(address) view returns (uint256)']);
const extraAbi = parseAbi(['function getSender(uint256) view returns (address)', 'function getDepositedAmount(uint256) view returns (uint128)', 'function getStartTime(uint256) view returns (uint40)', 'function isCancelable(uint256) view returns (bool)', 'function symbol() view returns (string)', 'function decimals() view returns (uint8)']);
const v1Abi = parseAbi(['function policies(uint256) view returns (address,uint256,uint256,uint64,uint64,bool)', 'function feeCredits(address) view returns (uint256)']);
const mirrorAbi = parseAbi(['function mirrors(uint256) view returns (address,uint64,uint256,uint256,bool)']);
const cache = new Map<string, { at: number; value: unknown }>();
const pending = new Map<string, Promise<unknown>>();
async function cached<T>(key: string, read: () => Promise<T>): Promise<T> {
  const saved = cache.get(key);
  if (saved && Date.now() - saved.at < 30_000) return saved.value as T;
  if (pending.has(key)) return pending.get(key) as Promise<T>;
  const task = read().then(value => { cache.set(key, { at: Date.now(), value }); return value; }).finally(() => pending.delete(key));
  pending.set(key, task);
  return task;
}
async function safe<T>(fn: () => Promise<T>): Promise<T | null> { try { return await fn(); } catch { return null; } }

export async function readStream(id: bigint) { return cached(`stream:${id}`, async () => {
  const v1 = id === 213n;
  const sablier = (functionName: string) => baseClient.readContract({ address: address.sablier as Address, abi: sablierAbi, functionName, args: [id] });
  const extra = (functionName: 'getSender' | 'getDepositedAmount' | 'getStartTime' | 'isCancelable' | 'symbol' | 'decimals', token: Address = address.sablier as Address) => baseClient.readContract({ address: token, abi: extraAbi, functionName, args: ['symbol', 'decimals'].includes(functionName) ? [] : [id] });
  const [sender, recipient, token, deposited, withdrawable, start, end, canceled, depleted, transferable, cancelable, basePolicy, coordinatorPolicy, allowed] = await Promise.all([
    safe(() => extra('getSender')), safe(() => sablier('getRecipient')), safe(() => sablier('getUnderlyingToken')),
    safe(() => extra('getDepositedAmount')), safe(() => sablier('withdrawableAmountOf')), safe(() => extra('getStartTime')),
    safe(() => sablier('getEndTime')), safe(() => sablier('wasCanceled')), safe(() => sablier('isDepleted')),
    safe(() => sablier('isTransferable')), safe(() => extra('isCancelable')),
    v1 ? safe(() => baseClient.readContract({ address: address.v1Executor as Address, abi: v1Abi, functionName: 'policies', args: [id] })) : safe(() => baseClient.readContract({ address: address.executor as Address, abi: executorAbi, functionName: 'policies', args: [id] })),
    v1 ? safe(() => lasnaClient.readContract({ address: address.v1Coordinator as Address, abi: mirrorAbi, functionName: 'mirrors', args: [id] })) : safe(() => lasnaClient.readContract({ address: address.coordinator as Address, abi: coordinatorAbi, functionName: 'policies', args: [id] })),
    v1 ? Promise.resolve(null) : safe(() => lasnaClient.readContract({ address: address.coordinator as Address, abi: coordinatorAbi, functionName: 'streamAllowed', args: [id] }))
  ]);
  const tokenAddress = typeof token === 'string' ? token as Address : null;
  const [symbol, decimals, feeCredit] = await Promise.all([
    tokenAddress ? safe(() => extra('symbol', tokenAddress)) : null,
    tokenAddress ? safe(() => extra('decimals', tokenAddress)) : null,
    typeof recipient === 'string' ? v1
      ? safe(() => baseClient.readContract({ address: address.v1Executor as Address, abi: v1Abi, functionName: 'feeCredits', args: [recipient as Address] }))
      : safe(() => baseClient.readContract({ address: address.executor as Address, abi: executorAbi, functionName: 'feeCredits', args: [recipient as Address] })) : null
  ]);
  return { id: id.toString(), version: v1 ? 'V1' : 'V2', sender, recipient, token, deposited, withdrawable, start, end, canceled, depleted, transferable, cancelable, symbol, decimals, basePolicy, coordinatorPolicy, allowed, feeCredit, readAt: new Date().toISOString() };
}); }

export async function readStatus() { return cached('status', async () => {
  const c = (functionName: string) => lasnaClient.readContract({ address: address.coordinator as Address, abi: coordinatorAbi, functionName });
  const e = (functionName: string) => baseClient.readContract({ address: address.executor as Address, abi: executorAbi, functionName });
  const [paused, shutdown, budget, submitted, active, lastCron, callbackReserve, baseBlock, lasnaBlock, systemReserve, systemDebt, proxyReserve, proxyDebt] = await Promise.all([
    safe(() => c('paused')), safe(() => c('shutdown')), safe(() => c('callbackBudget')), safe(() => c('callbacksSubmitted')),
    safe(() => c('activeCount')), safe(() => c('lastCronBlock')), safe(() => e('callbackReserveWei')),
    safe(() => baseClient.getBlockNumber()), safe(() => lasnaClient.getBlockNumber()),
    safe(() => lasnaClient.readContract({ address: address.system as Address, abi: billingAbi, functionName: 'reserves', args: [address.coordinator as Address] })),
    safe(() => lasnaClient.readContract({ address: address.system as Address, abi: billingAbi, functionName: 'debt', args: [address.coordinator as Address] })),
    safe(() => baseClient.readContract({ address: address.proxy as Address, abi: billingAbi, functionName: 'reserves', args: [address.executor as Address] })),
    safe(() => baseClient.readContract({ address: address.proxy as Address, abi: billingAbi, functionName: 'debt', args: [address.executor as Address] }))
  ]);
  return { paused, shutdown, budget, submitted, active, lastCron, callbackReserve, baseBlock, lasnaBlock, systemReserve, systemDebt, proxyReserve, proxyDebt, readAt: new Date().toISOString() };
}); }

export const jsonSafe = (value: unknown) => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v);
