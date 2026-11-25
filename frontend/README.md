# RECLAIM frontend

Next.js App Router presentation for the verified Base Sepolia and Reactive Lasna testnet demonstrations. The `frontend/` directory is a complete Vercel project root. Its bundled `lib/deployments.json` is a copy of the verified metadata from repository commit `e22226a`; update that copy when a future deployment replaces the retired V2 coordinator.

## Local setup

```sh
cd frontend
npm ci
npm run dev
```

Open `http://localhost:3000`. Public evidence, the execution explorer, and the landing page work without a wallet. Live stream and status panels use the public Base Sepolia and Reactive Lasna RPC endpoints declared in `lib/chain.ts`; no secret or environment variable is required. A public RPC outage shows unavailable live values while the historical receipt trail remains available.

Optional `NEXT_PUBLIC_SITE_URL` sets the canonical origin used by social metadata. Set it to the final HTTPS site URL for a hosted build. There are no private keys in client code.

## Vercel

Import the repository and set **Root Directory** to `frontend`. Use the Next.js framework preset and the default `npm ci` / `npm run build` steps. Set `NEXT_PUBLIC_SITE_URL` to the production HTTPS origin, then deploy. The frontend does not read root Foundry artifacts or parent files at build or runtime. `public/brand/` contains the favicon and social preview assets.

## Evidence and contract behavior

The two historical recoveries are stream 213 (V1 cancellation, 34.166666666666666666 rUSD) and stream 214 (V2 maturity, 300 rUSD). Exact token-unit values and all explorer links come from bundled verified deployment metadata. rUSD has no monetary value. The dashboard's 334.17 rUSD presentation is a rounded display of the exact 334.166666666666666666 rUSD sum, not a live balance or an adoption metric.

`/api/stream/[id]` reads Sablier and the correct V1 or V2 policy contracts. `/api/status` reads V2 coordinator, system billing, callback proxy and chain heads. Server reads are cached briefly; visible panels refresh every 60 seconds. Public RPC failures never become fabricated healthy values.

The deployed V2 coordinator is permanently retired. Enrollment, fee reserve top-ups and retry controls are disabled for this deployment. Active V2 policy revocation and eligible fee-credit withdrawal remain independent Base executor operations; wallet actions simulate before signature. The operator admission requirement is shown explicitly. A new autonomous recovery requires a fresh coordinator and corresponding executor deployment.

## Validation

```sh
npm run lint
npm run typecheck
npm run build
npm audit
npm test
```

Run `npm test` while the local app is serving on port 3000; it performs read-only Base Sepolia and Reactive Lasna integration checks. Browser captures and interaction checks are in `scripts/capture.mjs`; it writes screenshots to `/private/tmp/reclaim-final-screenshots` by default. Existing `public/screenshots/` captures are ignored by Git, and generated screenshots should stay outside the eventual commit. The full root contract suite was previously run with 112 passing tests, including fork tests.
