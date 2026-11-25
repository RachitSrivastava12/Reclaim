import type { Metadata, Viewport } from 'next';
import { GeistSans } from 'geist/font/sans';
import { GeistMono } from 'geist/font/mono';
import './globals.css';

const siteOrigin = process.env.NEXT_PUBLIC_SITE_URL || (process.env.VERCEL_URL ? `https://${process.env.VERCEL_URL}` : 'http://localhost:3000');
export const viewport: Viewport = { width: 'device-width', initialScale: 1 };
export const metadata: Metadata = {
  metadataBase: new URL(siteOrigin),
  title: { default: 'RECLAIM — What’s yours, returned automatically.', template: '%s | RECLAIM' },
  description: 'Inspect two verified, non-custodial testnet recoveries powered by Reactive Network. Follow actual Base Sepolia and Reactive Lasna receipts without a wallet.',
  alternates: { canonical: '/' },
  openGraph: { type: 'website', title: 'RECLAIM — What’s yours, returned automatically.', description: 'Two verified autonomous testnet recoveries. Direct recipient transfers. Explore every receipt.', images: [{ url: '/brand/social.png', width: 1200, height: 630, alt: 'RECLAIM autonomous recovery on Reactive Network' }] },
  twitter: { card: 'summary_large_image', images: ['/brand/social.png'] },
};
export default function RootLayout({ children }: { children: React.ReactNode }) { return <html lang="en"><body className={`${GeistSans.variable} ${GeistMono.variable}`}>{children}</body></html>; }
