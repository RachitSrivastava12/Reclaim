import { NextResponse } from 'next/server';
import { readStream, jsonSafe } from '@/lib/read';
export const revalidate=20;
export async function GET(_:Request,{params}:{params:Promise<{id:string}>}){const {id}=await params;if(!/^\d{1,30}$/.test(id)||BigInt(id)===0n)return NextResponse.json({error:'Enter a valid positive stream ID.'},{status:400});try{const data=await readStream(BigInt(id));if(!data.recipient)return NextResponse.json({error:'Stream not found or Sablier RPC unavailable.'},{status:404});return new NextResponse(jsonSafe(data),{headers:{'Content-Type':'application/json','Cache-Control':'public, s-maxage=15, stale-while-revalidate=30'}})}catch{return NextResponse.json({error:'RPC reads failed. Try again shortly.'},{status:503})}}
