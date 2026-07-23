# W3Cash SDK — Blind Audit Convergence Report (Rounds 1–6)

**Status: CONVERGED — GREEN × 2 consecutive (rounds 5 & 6).**
Scope: whole codebase (Design C contracts + adapters, ASP encoder/server, MCP x402 payer,
telemetry sidecar). Method: blind multi-agent audit (finders see only raw source — no docs, no
tests, no prior findings), then triage → adversarial per-finding verification (refute against
code) → scored synthesis.

## Scoring & convergence rule

- `weight = { critical: 100, high: 40, medium: 10, low: 3, informational: 1 }`
- `residualRiskScore = Σ weight` over **NEW + actionable** confirmed findings only
  (known-fixed and known-accepted score **0**).
- **GREEN** = 0 new critical AND 0 new high AND 0 new medium (the security-material bar).
  YELLOW = only new low/info. RED = any new crit/high.
- **Stop when GREEN for K = 2 consecutive rounds.**

## Trajectory

| Round | Verdict | Score | Notable |
|------:|:-------:|------:|---------|
| 1 | fixed | — | Design C hardening (1 HIGH + 10) |
| 2 | fixed | — | payer HIGH + Legacy CRITICAL **accepted** (immutable) |
| 3 | 🔴 RED | ~116 | **CRITICAL in the round-2 payer fix** (probe-then-settle TOCTOU + accepts[0] mismatch) → payer redesigned around the SDK `paymentRequirementsSelector` |
| 4 | 🟡 YELLOW | 22 | payer redesign **verified sound** (both round-3 criticals closed); 1 new MED + 3 LOW + 3 INFO → all fixed |
| 5 | 🟢 GREEN #1 | 8 | 0 new crit/high/med; 6/7 round-4 fixes CLOSED, 1 incomplete (u256 clamp missed the Date path) + 3 more low/info → all fixed |
| 6 | 🟢 GREEN #2 | 8 | 0 new crit/high/med; all 4 round-5 fixes CLOSED, no regression → **converged** |

The round-3 → round-4 → round-5 sequence is the key lesson of the loop: **a fix must be
re-audited**, because a fix can itself be the next critical (round 3) or merely incomplete
(round 5's u256 clamp that stopped the ABI-encode overflow but not the downstream `Date` throw).

## Fixes applied (rounds 4–6, off-chain only — no contract changes)

### Round 4 (7)
- **[MED] telemetry `eventsForHash`** now takes an optional `chainId` and scopes `AND chain_id = ?`.
  `/intent/:hash` reports **per chain** (or scoped with `?chainId=`); `/intents` scopes to the
  intent's own chain. Closes cross-chain status spoofing (identical Legacy `payloadHash` on X Layer
  testnet 1952 / mainnet 196, same processor address).
- **[INFO] telemetry `/intents`** no longer returns the ASP-authored free-text `summary`.
- **[LOW] payer `payTo`** fails **closed**: an explicitly-empty `X402_ALLOWED_PAYTO` normalizes to the
  default receiver, and the `payTo.length > 0 &&` short-circuit was dropped so an empty list rejects
  every recipient (matching the network gate).
- **[LOW] payer** opt-in `X402_ALLOWED_ASSETS` allowlist (the value cap was asset-agnostic).
- **[LOW] ASP `X-Payment-Network`** disclosure scoped to `req.path === '/compile-intent'` **and**
  validated against `resolvePaymentNetworks(cfg)` — no longer echoes arbitrary caller input on free
  routes.
- **[INFO] encoder** honors an explicit numeric `expiry` **above** the non-recurring-`timeRange`
  short-circuit (both gates apply on-chain; tighter wins).
- **[INFO] encoder** clamps every summed `endTime` to `UINT_MAX.u256` (`clampU256`).

### Round 5 (completions of round-4 residuals + new)
- **[LOW] encoder `isoOrUnbounded`** guards **both** `new Date(...).toISOString()` sites
  (`DATE_MAX_SECONDS = 8.64e12 s`) — an absurd `expiry`/`waitTime.timestamp`/`now` now returns a clean
  200 with a sentinel string instead of throwing `RangeError` → HTTP 500. (The round-4 u256 clamp
  alone did not cover this: the JS `Date` ceiling is ~28 orders of magnitude below the u256 cap.)
- **[INFO] encoder** near-max approval warning threshold changed from exact `UINT_MAX.u256` to
  `amt >= 1n << 128n`, so effectively-infinite approvals are flagged `UNLIMITED`.
- **[LOW] telemetry finality buffer** — `indexChain` indexes only to `head - cfg.confirmations`
  (default 12, env `CONFIRM_<id>`) so a **shallow** reorg can't persist orphaned events.
- **[INFO] telemetry `/intents`** skips `status === 'unknown'` (never-broadcast) intents, so a target's
  pending compile metadata isn't enumerable unauthenticated. `schema.sql` comment corrected.

### Round 6 (last polish)
- **[LOW] ASP bridge quote** requires **string** `inputToken`/`outputToken`/`inputAmount` at both call
  sites, so a non-string field returns 400 VALIDATION instead of a `TypeError` → 500.
- **[INFO] telemetry `/intents`** no longer returns off-chain `compiledAt` (compile-to-execute latency
  leak for a known address).
- **[INFO] telemetry config** — `START_<id>` / `CONFIRM_<id>` env overrides parsed with a
  `Number.isFinite` guard so a malformed value falls back to the default instead of `NaN` (which would
  silently halt indexing).

## Accepted / deferred residuals (weight 0 — documented, not fund-material)

- **Legacy processor** (`W3CashProcessorLegacy`, deployed on 84532 / 1952 / 196): unsigned instruction
  header (arbitrary `seq` skips gates), non-consumed nonce (replay), no EIP-712 domain (cross-chain
  replay). **Immutable + demo-only**; structurally fixed by Design C. See
  [`SECURITY-NOTICE-legacy.md`](./SECURITY-NOTICE-legacy.md). Do not route real value or grant standing
  allowances through it.
- **Telemetry deep-reorg reconcile** (DELETE + re-scan with block-hash divergence for reorgs deeper than
  the finality buffer) — real feature, deferred until the sidecar is provisioned/live. Shallow-reorg
  buffer is in.
- **Telemetry `payloadHash` omits `initiator`** — two users' identical intents collide in the
  read-only stats sidecar (misattribution/griefing, no fund loss). Fix = add `initiator` to the
  `intents` primary key; deferred with the reconcile work (no live D1 data to migrate).
- **`/simulate` + `/quote` per-IP rate limiting**, and **x402 fail-closed on facilitator-init error** —
  off-chain infra hardening follow-ups.
- **Undeployed adapters**: FlashLoanAdapter / ClaimAdapter arbitrary-call + sibling permissionless
  setters (not registered in the main deploy); WrapAdapter resident-ETH sweep is Legacy-only;
  Batch/Delegate adapters inert.
- **Refuted (not bugs)**: Design C `_feedAndRun` mid-loop native sweep (guarded by the frame-depth
  latch + flash-adapter pin + root-gated latches); mutable-verb PERMIT2→flash `fundingSig` desync
  (hard-reverts at the funding check before any index skip). Both re-confirmed unreachable in round 6.

## Test status (all green)

- Contracts (Design C + adapters): **168 passed**
- ASP: **126 passed** · Telemetry: **11 passed** · MCP: typecheck + standalone payer-policy checks

## Recommended before mainnet / real value

1. **External professional audit** of Design C (`W3CashProcessor.sol`) — this loop is blind-multi-agent,
   not a substitute.
2. **Real-deployed-Permit2 fork test** (audited-only here; no chain deploy).
3. **Point the ASP's Base Sepolia processor + envelope format at Design C** so the compiler stops
   emitting exploitable Legacy envelopes.
4. **Provision telemetry D1** and land the deep-reorg reconcile + rate limiting before the sidecar goes
   live.

_Blind multi-agent audit loop, rounds 1–6. All fixes off-chain; contracts unchanged since the Design C
core landed._
