import Link from 'next/link';
import Image from 'next/image';
export function Brand({compact=false}:{compact?:boolean}){return <Link href="/" aria-label="RECLAIM home" style={{display:'inline-flex',alignItems:'center',gap:10}}><Image src="/brand/logo.svg" alt="" width={34} height={34}/><span style={{fontSize:compact?16:18,fontWeight:700,letterSpacing:'.12em'}}>RECLAIM</span></Link>}
