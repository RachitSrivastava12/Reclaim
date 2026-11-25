'use client';
import { useEffect, useState } from 'react';
import { ArrowRight, X } from 'lucide-react';

const steps = [
  { title: 'Start with the proof', body: 'Two real testnet recoveries are preserved here. Select either stream in the execution explorer to inspect every receipt.', view: 'executions' },
  { title: 'Follow the money', body: 'The red route is the callback signal. The green route is the token transfer from Sablier directly to the recipient.', view: 'executions' },
  { title: 'Check current state', body: 'Stream and protocol pages use public RPC reads. They may change or be unavailable without affecting the historical receipts.', view: 'streams' },
  { title: 'Understand the lifecycle', body: 'The V2 coordinator was permanently retired after testing. New autonomous recoveries are unavailable on this deployment.', view: 'status' },
];
export function JudgeWalkthrough({ onNavigate }: { onNavigate: (view: 'executions' | 'streams' | 'status') => void }) {
  const [open, setOpen] = useState(false);
  const [index, setIndex] = useState(0);
  useEffect(() => { if (new URLSearchParams(window.location.search).get('walkthrough') === '1') setOpen(true); }, []);
  useEffect(() => { const handler = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false); }; window.addEventListener('keydown', handler); return () => window.removeEventListener('keydown', handler); }, []);
  const step = steps[index];
  return <><button className="button ghost walkthrough-trigger" onClick={() => { setIndex(0); setOpen(true); }}>Guided tour <ArrowRight size={15}/></button>{open && <div className="tour-backdrop" role="presentation" onMouseDown={event => { if (event.target === event.currentTarget) setOpen(false); }}><section className="tour-dialog" role="dialog" aria-modal="true" aria-label="RECLAIM guided tour"><div className="tour-top"><span className="eyebrow red">NO WALLET REQUIRED · {index + 1} / {steps.length}</span><button className="tour-close" onClick={() => setOpen(false)} aria-label="Close tour"><X size={18}/></button></div><div className="tour-progress">{steps.map((_, number) => <span key={number} className={number <= index ? 'active' : ''}/>)}</div><h2>{step.title}</h2><p>{step.body}</p><div className="tour-actions"><button className="button ghost" onClick={() => setOpen(false)}>Close</button><button className="button primary" onClick={() => { onNavigate(step.view as 'executions' | 'streams' | 'status'); if (index === steps.length - 1) setOpen(false); else setIndex(index + 1); }}>{index === steps.length - 1 ? 'Finish tour' : 'Show me'} <ArrowRight size={15}/></button></div></section></div>}</>;
}
