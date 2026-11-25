import { NextResponse } from 'next/server';import { readStatus,jsonSafe } from '@/lib/read';
export const dynamic="force-dynamic";
export async function GET(){try{return new NextResponse(jsonSafe(await readStatus()),{headers:{'Content-Type':'application/json','Cache-Control':'public, s-maxage=15, stale-while-revalidate=30'}})}catch{return NextResponse.json({error:'Network status unavailable.'},{status:503})}}
