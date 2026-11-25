import deployment from './deployments.json';
import { baseTx, lasnaTx } from './chain';

const cancellation = deployment.firstLiveSablierRecovery;
const maturity = deployment.firstLiveMaturityRecoveryV2;
export const recoveryUnits = {
  cancellation: BigInt(cancellation.recoveredTokenUnits),
  maturity: BigInt(maturity.recoveredTokenUnits),
};
export const combinedRecoveryUnits = recoveryUnits.cancellation + recoveryUnits.maturity;
export const exactTokenAmount = (units: bigint) => `${units / 10n ** 18n}.${(units % 10n ** 18n).toString().padStart(18, '0')}`;
export type EvidenceStep = { title: string; description: string; network: 'Base Sepolia' | 'Reactive Lasna'; actor: 'Sablier' | 'Reactive' | 'Executor' | 'Recipient'; hash: string; block: number; detail?: string };
export const trails: Record<'cancellation' | 'maturity', { stream: number; title: string; amount: bigint; eventId: string; steps: EvidenceStep[] }> = {
  cancellation: {
    stream: 213, title: 'Cancellation recovery', amount: recoveryUnits.cancellation, eventId: cancellation.recoveryEventId,
    steps: [
      { title: 'Sablier cancellation', description: 'The employer cancels stream 213. 34.166666666666666666 rUSD remains for the recipient.', network: 'Base Sepolia', actor: 'Sablier', hash: cancellation.cancellationTx, block: cancellation.cancellationBlock, detail: 'CancelLockupStream · log 1 · recipient amount 34166666666666666666 token units' },
      { title: 'Reactive event processing', description: 'Lasna consumes the Base cancellation log and requests an authenticated callback.', network: 'Reactive Lasna', actor: 'Reactive', hash: cancellation.cancellationReactiveTx, block: cancellation.cancellationReactiveBlock, detail: 'refChainId 84532 · refEventIndex 1 · callback request log 1' },
      { title: 'Base callback execution', description: 'The official callback proxy reaches the V1 executor, which checks the policy and live Sablier state.', network: 'Base Sepolia', actor: 'Executor', hash: cancellation.recoveryCallbackTx, block: cancellation.recoveryCallbackBlock, detail: 'RecoverySucceeded · log 5 · PolicyCompleted · log 6' },
      { title: 'Direct recipient transfer', description: 'Sablier sends 34.166666666666666666 rUSD straight to the recipient. The executor never holds it.', network: 'Base Sepolia', actor: 'Recipient', hash: cancellation.recoveryCallbackTx, block: cancellation.recoveryCallbackBlock, detail: 'Token Transfer · log 2 · Sablier withdrawal · log 3' },
      { title: 'Completion acknowledged', description: 'Reactive Lasna observes PolicyCompleted and deactivates the V1 mirror.', network: 'Reactive Lasna', actor: 'Reactive', hash: cancellation.completionReactiveTx, block: cancellation.completionReactiveBlock, detail: 'refEventIndex 6 · mirror active=false' },
    ],
  },
  maturity: {
    stream: 214, title: 'Maturity recovery', amount: recoveryUnits.maturity, eventId: maturity.eventId,
    steps: [
      { title: 'Maturity policy enrolled', description: 'The recipient enrolls stream 214 in Maturity mode; the executor records Sablier’s end time.', network: 'Base Sepolia', actor: 'Executor', hash: maturity.policyEnrollmentTx, block: 63491437, detail: 'PolicyEnrolled · log 15 · mode 1' },
      { title: 'Scheduled on Reactive', description: 'Lasna admits the policy. Its due time includes a 120 second safety buffer after maturity.', network: 'Reactive Lasna', actor: 'Reactive', hash: maturity.enrollmentReactiveTx, block: maturity.enrollmentReactiveBlock, detail: 'PolicyStateChanged(214, 1, Scheduled) · log 1' },
      { title: 'Native Cron100 event', description: 'A native Reactive Network tick arrives after the due time.', network: 'Reactive Lasna', actor: 'Reactive', hash: maturity.cronOriginTx, block: maturity.cronOriginBlock, detail: 'Cron100 · native emitter 0x000…ffffff · log 2' },
      { title: 'Callback requested', description: 'The V2 coordinator submits its single Base Sepolia callback request.', network: 'Reactive Lasna', actor: 'Reactive', hash: maturity.callbackRequestedTx, block: maturity.callbackRequestedBlock, detail: 'CallbackRequested · log 2 · attempt 1 · gas limit 600000' },
      { title: 'Base callback execution', description: 'The official proxy calls the V2 executor. Base time and Sablier state are checked again.', network: 'Base Sepolia', actor: 'Executor', hash: maturity.callbackTx, block: maturity.callbackBlock, detail: 'RecoverySucceeded · log 88 · PolicyCompleted · log 89' },
      { title: 'Direct 300 rUSD transfer', description: 'Sablier transfers 300 rUSD directly to the recipient; the executor never takes custody.', network: 'Base Sepolia', actor: 'Recipient', hash: maturity.callbackTx, block: maturity.callbackBlock, detail: 'Token Transfer · log 85 · Sablier withdrawal · log 86' },
      { title: 'Completion acknowledged', description: 'Lasna acknowledges success and marks the scheduled policy Completed.', network: 'Reactive Lasna', actor: 'Reactive', hash: maturity.completionAcknowledgementTx, block: 9227202, detail: `Success acknowledgement ${maturity.recoveryAcknowledgementTx} · Completed log 2` },
    ],
  },
};
export const txUrl = (step: EvidenceStep) => step.network === 'Base Sepolia' ? baseTx(step.hash) : lasnaTx(step.hash);
export const retirement = { permanent: maturity.finalCoordinatorShutdown, shutdownTx: maturity.shutdownTx, settlementTx: maturity.debtSettlementTx, shutdownBlock: maturity.shutdownBlock, settlementBlock: maturity.debtSettlementBlock, settlementWei: maturity.debtSettlementWei };
