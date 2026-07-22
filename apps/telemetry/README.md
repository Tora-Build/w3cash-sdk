# W3Cash Telemetry (item 17)

A read-only **Cloudflare Worker + D1** that gives W3Cash a memory: it indexes the deployed
processor's on-chain events across all chains and serves intent **status** + neutral **reliability
stats**. It never signs, never holds funds, and doesn't depend on who relayed a tx — it just
**reads public chain events**.

## What it is (and isn't)

- **The source of truth is the CHAIN.** Every execution/pause emits a public event carrying the
  intent's `payloadHash`. This worker mirrors those into D1 for fast querying — it does not
  *create* history, and any third party can index the same events.
- **`intents` metadata is the only thing we add**, via the ASP's optional `POST /record` at compile
  time (`payloadHash → {chain, initiator, summary}`) — everything it stores is already public in the
  calldata. Without it, `/intent/:hash` status still works from chain events alone; only the
  per-initiator list + the stats denominator need it.

## Endpoints (read-only)

| Route | Returns |
|---|---|
| `GET /health` | liveness |
| `GET /intent/:payloadHash` | `{ status: waiting\|executed\|cancelled\|unknown, executedEvents, pausedEvents, txHashes, … }` |
| `GET /intents?initiator=0x…` | that address's recorded intents + each one's status |
| `GET /stats` | neutral reliability: `fired/total` over ALL recorded intents (incl. never-fired), per chain, with a published, recomputable methodology |
| `POST /record` | (auth: `x-record-secret`) the ASP registers a compiled intent's metadata |

## Deploy

```bash
cd apps/telemetry
npm install
wrangler d1 create w3cash-telemetry          # paste the id into wrangler.toml
npm run db:init                                # apply schema.sql
# set the REAL processor deploy blocks so the indexer doesn't scan from 0:
#   wrangler.toml [vars] START_84532 / START_1952 / START_196
wrangler secret put RECORD_SECRET              # shared with the ASP for /record
npm run deploy
```

The `[triggers] crons` tick (every 2 min) runs the indexer: from each chain's cursor to head, in
`logChunk`-block pages (X Layer caps `eth_getLogs` at 100 blocks), idempotent upserts, resumable.

## Status

Pure core (`parse.ts`: log→row, status derivation, stats) is unit-tested (11 tests). The D1/RPC glue
+ cron are written against the CF runtime and **reviewed, not yet deployed** — provision D1 + the
deploy blocks to go live. Indexes the **deployed Legacy** events today; the Design C event
signatures are already in the catalogue for when that processor deploys.
