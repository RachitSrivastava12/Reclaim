'use client';

import { useEffect, useRef, useState } from 'react';
import { ArrowRight, Check, RotateCcw, Play } from 'lucide-react';

const stages = [
  { name: 'Enroll', detail: 'The recipient chooses when recovery should happen and caps the withdrawal fee.' },
  { name: 'Detect', detail: 'Reactive Network sees a cancellation or the stream reaching its end time.' },
  { name: 'Validate', detail: 'The Base executor checks the callback, policy, fee limit and current Sablier balance.' },
  { name: 'Recover', detail: 'Sablier transfers the earned funds directly to the recipient.' },
];

export function Reveal({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    if (!('IntersectionObserver' in window) || window.matchMedia('(prefers-reduced-motion: reduce)').matches) { node.dataset.visible = 'true'; return; }
    const observer = new IntersectionObserver(([entry]) => { if (entry.isIntersecting) { node.dataset.visible = 'true'; observer.disconnect(); } }, { threshold: .12 });
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  return <div ref={ref} className={`reveal ${className}`}>{children}</div>;
}

export function CountUp({ value, decimals = 0 }: { value: number; decimals?: number }) {
  const ref = useRef<HTMLElement>(null);
  const [display, setDisplay] = useState(value.toFixed(decimals));
  useEffect(() => {
    const node = ref.current;
    if (!node || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    let frame = 0;
    const observer = new IntersectionObserver(([entry]) => {
      if (!entry.isIntersecting) return;
      observer.disconnect();
      const started = performance.now();
      const tick = (now: number) => {
        const progress = Math.min(1, (now - started) / 850);
        setDisplay((value * (1 - Math.pow(1 - progress, 3))).toFixed(decimals));
        if (progress < 1) frame = requestAnimationFrame(tick);
      };
      frame = requestAnimationFrame(tick);
    }, { threshold: .7 });
    observer.observe(node);
    return () => { observer.disconnect(); cancelAnimationFrame(frame); };
  }, [value, decimals]);
  return <span ref={ref}>{display}</span>;
}

export function RecoveryMap({ active = -1 }: { active?: number }) {
  return <div className="recovery-map" aria-label="Reactive Network sends a signal to the executor; funds move directly from Sablier to the recipient">
    <div className="map-caption"><span className="signal-dot"/> RECOVERY ROUTE <span>ILLUSTRATIVE · NOT LIVE TRAFFIC</span></div>
    <div className="map-signal"><div className={`map-node ${active === 0 ? 'lit' : ''}`}><span>01 / SOURCE</span><strong>Sablier stream</strong><small>Earned funds stay here</small></div><i/><div className={`map-node ${active === 1 ? 'lit' : ''}`}><span>02 / SIGNAL</span><strong>Reactive Network</strong><small>Detects the trigger</small></div><i/><div className={`map-node ${active === 2 ? 'lit' : ''}`}><span>03 / CHECK</span><strong>Base executor</strong><small>Validates recovery</small></div></div>
    <div className="map-funds"><span>FUNDS MOVE DIRECTLY</span><div className="funds-path"><strong>Sablier</strong><i/><strong className={active === 3 ? 'lit' : ''}>Recipient</strong></div><small>Reactive Network and the executor never receive the funds.</small></div>
  </div>;
}

export function HowItWorks() {
  const [active, setActive] = useState(0);
  return <div className="how-grid"><div className="how-list" role="group" aria-label="Recovery steps">{stages.map((stage, index) => <button key={stage.name} className={`how-step ${active === index ? 'selected' : ''}`} onClick={() => setActive(index)} aria-pressed={active === index}><span className="mono">0{index + 1}</span><strong>{stage.name}</strong><ArrowRight size={16} aria-hidden="true"/></button>)}</div><div className="how-detail" aria-live="polite"><span className="eyebrow">STEP 0{active + 1} / 04</span><h3>{stages[active].name}</h3><p>{stages[active].detail}</p><RecoveryMap active={active}/></div></div>;
}

export function Simulation() {
  const [scenario, setScenario] = useState<'cancellation' | 'maturity'>('cancellation');
  const [stage, setStage] = useState(-1);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const clear = () => { timers.current.forEach(clearTimeout); timers.current = []; };
  useEffect(() => clear, []);
  const reset = () => { clear(); setStage(-1); };
  const run = () => {
    reset();
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) { setStage(3); return; }
    [0, 1, 2, 3].forEach((value, index) => timers.current.push(setTimeout(() => setStage(value), 260 + index * 850)));
  };
  const change = (value: 'cancellation' | 'maturity') => { reset(); setScenario(value); };
  const balance = scenario === 'cancellation' ? '34.17' : '300.00';
  return <div className="sim-shell"><div className="sim-toolbar"><div><span className="eyebrow red">INTERACTIVE SIMULATION</span><h3>Try a recovery</h3><p>Local walkthrough using the amounts from the verified testnet examples. No transaction is sent.</p></div><div className="sim-switch" role="group" aria-label="Scenario"><button className={scenario === 'cancellation' ? 'selected' : ''} onClick={() => change('cancellation')} aria-pressed={scenario === 'cancellation'}>Salary cancelled</button><button className={scenario === 'maturity' ? 'selected' : ''} onClick={() => change('maturity')} aria-pressed={scenario === 'maturity'}>Salary matured</button></div></div><div className="sim-body"><div className="sim-stages">{['Stream ends', 'Trigger detected', 'Recovery validated', 'Recipient paid'].map((label, index) => <div key={label} className={`sim-stage ${stage >= index ? 'done' : ''} ${stage === index ? 'current' : ''}`}><span>{stage >= index ? <Check size={15}/> : `0${index + 1}`}</span><strong>{label}</strong></div>)}</div><div className="sim-result"><span className="eyebrow">RECIPIENT BALANCE · SIMULATED</span><strong className="mono">{stage === 3 ? balance : '0.00'} <small>rUSD</small></strong><p>{stage === 3 ? 'Sablier → recipient. The executor never takes custody.' : 'Run the simulation to see the direct payment path.'}</p></div></div><div className="sim-footer"><button className="button primary" onClick={run}><Play size={15}/>{stage === 3 ? 'Replay simulation' : 'Run simulation'}</button><button className="button ghost" onClick={reset} disabled={stage === -1}><RotateCcw size={15}/> Reset</button><span>SIMULATION ONLY · NO WALLET · NO BLOCKCHAIN WRITE</span></div></div>;
}
