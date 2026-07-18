# W3Cash — Build Plan (post-hackathon maturation)

Decision-anchored execution plan derived from `ROADMAP.md` v2 + `DECISIONS.md`
ADR-0001 (+ Addendum A). Decisions locked 2026-07-18.

## Locked decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Mainnet risk | **Base Sepolia first → lightweight mini-review of the minimal core → Base mainnet (8453)** |
| 2 | ADR-0001 audit | **Soon** — run as a *parallel track* against the already-frozen spec |
| 3 | Hosted x402 payer | **Bring-your-own-payer on mainnet** (hosted relayer stays testnet-demo only) |
| 4 | Keeper/indexer infra | **CF Workers + Durable Objects / D1** (cron-tick gate polling, not long-poll) |
| 5 | Pricing | **Full x402 ladder now** — free simulate · metered compile · keep subscription |
| 6 | Default expiry | **Per-recipe smart default** (short for one-shot/stop-loss, long for DCA, opt-out available) |
| 7 | Sequencing | **Strict tiers** (NOW → NEXT → redeploy) — with audit as the parallel track |
| 8 | Sooth crank target | **Base Sepolia Sooth markets** first |

**Note (audit-soon implication):** because the redeploy lands relatively early,
minimize investment in short-lived pre-ADR band-aids — the appended-transfer
keeper fee and the one-shot-only `OracleSwapAdapter` are stepping stones, not
destinations. Build them thin.

## Track A — Audit (parallel, starts now)

The spec is frozen in ADR-0001 + Addendum A (5 riders, corrections C1/C2). Steps:
1. Select auditor; scope = the ADR-0001 processor + the riders + the C1/C2
   fixes + the fleet-migration surface.
2. Freeze the open items Addendum A flags before the engagement: keeper-tip
   gas-cap value (~150k) validated against non-standard/FoT tokens; the
   cross-chain envelope encoding (C2); the on-chain cooldown floor constant.
3. Audit runs while Phases 1–2 build. **Redeploy is gated on: audit clean AND
   Phase 2 shipped.**

## Phase 1 — NOW (no contract changes; Base Sepolia + off-chain)

Strict-tier first block; ships on the current deployment.

1. **Safe-by-default compilation + `w3cash_cancel_all`** — per-recipe default
   expiry (decision #6), exact-sized allowances, exposure in `humanSummary`; the
   one-tx `incrementNonce()` cancel tool. *(encoder + MCP)*
2. **`w3cash_simulate_intent` (FREE)** — dry-run with gas-price/timestamp
   overrides + per-gate caveats + fix-it approve. The free rung of the ladder.
3. **x402 ladder** (decision #5) — `accepts[]` tiers: free simulate, metered
   compile, keep subscription; MPP/session pricing. On mainnet, callers supply
   their own payer key (decision #3) — document the hosted payer as testnet-only.
4. **Intent status + portfolio + telemetry** on **CF Workers + DO/D1**
   (decision #4): cron-tick indexer over the processor events (2 chains),
   `GET /intent/:hash`, list-by-initiator, published reliability telemetry,
   `POST /watch` webhooks/MCP notifications. Read-only sidecar.
5. **Compile-time sanity layer** — threshold-plausibility, decimal lint,
   current-values annotation, swap autoQuote (QuoterV2).
6. **Distribution** — ERC-8004 self-registration + AgentCard w/ telemetry;
   split the skill into per-vertical resources generated from `/capabilities`.

## Phase 2 — NEXT (new adapters/deploys; Base Sepolia, then mini-review → mainnet)

1. **WordLens** (~40-line view) — unlocks multi-return gates (Chainlink
   staleness, Aave HF, EAS, Governor.state, 4626 share price) for the existing
   query condition. Highest leverage-per-line.
2. **Permit2 SignatureTransfer pull adapter** — one canonical approval; the
   bridge to RIDER 5.
3. **`OracleSwapAdapter`** — execution-time oracle-anchored minOut floor +
   `executeBy`. **Pre-ADR: one-shot + exact allowance only** (thin — recurring
   swaps wait for the redeploy).
4. **Buffer-over-speed stop-loss** (compiler policy) — fire at a margin above
   the liquidation threshold; `keeperOfRecord = 0` open bounty for the class.
5. **Keep Service v1** — CF-Workers cron watcher; baked-recipient appended fee
   (thin, graduates to RIDER-1 tip); mandatory expiry; pre-flight simulate.
6. **ERC-4626 VaultAdapter**, **dynamic verbs**, **Borrow/Repay deploy**,
   **CompositeGate (OR)**, **PaymentAdapter**, **Pyth gate**, **Arbitrum
   Sepolia** (late — caller-pinned, redeploys with the fleet).
7. **SoothSettleAdapter / crank recipe** → **Base Sepolia Sooth markets**
   (decision #8): first-party recurring keeper volume + a live watch→fire demo.
8. **Mini-review** of the Base-mainnet minimal core (transfer/approve + time/
   balance/query gates, bounded allowances, mandatory expiry) → **deploy Base
   mainnet (8453)** with distinct (non-CREATE2) addresses. Real fees begin.

## Phase 3 — Redeploy (after Track A audit clean + Phase 2 shipped)

The one immutable redeploy carrying every processor-level change:
- **Base-ADR core** + **corrections C1** (bind full header, `seq==0` always, no
  resume storage) **+ C2** (execution-chain domain + cross-chain envelopes).
- **RIDER 1** signed-payee tip · **RIDER 2** ERC-1271 · **RIDER 3**
  `executionsOf()` · **RIDER 4** CREATE2 · **RIDER 5** native Permit2 funding.
- **Fleet migration** (all adapters re-deploy, caller-pinned) + **public
  golden-vector conformance kit**.
- Post-redeploy: promote full DeFi verbs to mainnet; graduate recurring
  `OracleSwapAdapter`, the RIDER-1 tip, and the keeper marketplace.

## Later / bets
AMB remote dispatch · Sooth trading actions (needs `onBehalfOf`) · OKX DEX
aggregator swap (executor-supplied route) · constrained BatchAdapter (rides the
fleet redeploy) · HyperEVM core · proof-of-keep SLA receipts.

_Sequencing rule: anything deployed pre-redeploy is caller-pinned and redeploys
with the fleet — land Phase-2 adapter deploys as close to the redeploy as the
strict-tier order allows to avoid double work._

---

## The changes in plain terms — OFF-CHAIN vs ON-CHAIN

Two kinds of work. **Off-chain** = the compiler/API/keeper — safe, reversible,
ships continuously, never touches the deployed contracts. **On-chain** = smart
contracts — either *new standalone contracts* (deploy to new addresses anytime,
old ones untouched, submission unaffected) or *the one immutable processor
redeploy* (the big, audited, once-ever event).

### Off-chain changes (the compiler, API, and keeper — no contracts)

- **Make every intent safe by default.** When an agent compiles a goal, we
  automatically add a sensible **expiry** (short for one-shot, long for
  scheduled), size the token approval to the **exact** amount needed, and print
  the worst-case exposure — so a leaked signature can't be replayed forever.
  Plus a one-tap "cancel everything" button. *(Phase 1)*
- **Free "will this work?" preview.** A new tool that dry-runs the intent and
  says "yes it would fire / no, this gate is blocking, by this much / you need
  this approval first" — before anyone signs or pays. It's free; it's the hook
  that leads to the paid compile. *(Phase 1)*
- **Memory + dashboards.** Today an agent forgets its intents between sessions.
  We add "show me all my active/pending intents and how to cancel them," plus
  public reliability stats (how often our recipes actually fire) — which is how
  other agents will decide to trust us. Runs on Cloudflare Workers. *(Phase 1)*
- **Pricing tiers.** Free preview → pay-per-compile → keeper subscription. *(P1)*
- **The keeper service.** A watcher that checks each waiting intent every few
  seconds and submits it the moment its condition becomes true — so users don't
  have to babysit. It bills a small per-execution fee. *(Phase 2)*
- **Smarter compiling.** Warn on implausible thresholds, auto-fill swap slippage,
  split our "how to use it" guide into per-use-case skills. *(Phase 1)*

### On-chain — NEW standalone contracts (deploy anytime, submission unaffected)

Each is a small independent contract at a **new address**; the compiler just
learns the address. Nothing about the current deployment or the OKX listing
changes.

- **`OracleReadAdapter`** — *fixes a real bug*: our current price-condition can't
  actually read a Chainlink feed correctly (it reads the wrong field). This typed
  reader does, and unlocks price-staleness, Aave health-factor, and vault-price
  conditions. **Highest priority — it's a correctness fix.** *(Phase 2)*
- **`PostConditionAdapter`** — an on-chain "did I actually get what I expected?"
  check placed after an action that **reverts** if not (slippage/MEV safety net).
- **`OracleSwapAdapter`** — re-prices a swap's minimum-out at execution time from
  a live oracle, so a swap signed weeks ago can't be sandwiched. *(Phase 2)*
- **New action adapters** — ERC-4626 vaults (one contract = every vault),
  dynamic amounts ("send 50% of my balance"), Aave borrow/repay (already written,
  just deploy), payment-with-receipt, and a Sooth market settlement crank.
- **`W3CashResolver`** — a read-only "simulate this intent" contract other tools
  can call.
- Later: cross-chain bridge/receiver adapters, a `KeeperCoordinator` (staking/
  reputation for keepers), flash-loan shells.

### On-chain — the ONE immutable processor redeploy (audited, once-ever)

This is the only heavy, irreversible on-chain event. It happens **once**, after
an audit, to a new address, and old intents keep running on the old contract.
Because the processor can never be changed after, it must carry **everything**
that needs to be in the core — batched:

- **Fix the security holes** (from ADR-0001 + the CoW/MEV research): stop
  signatures being replayable (per-intent counter), stop a manipulated header
  from skipping the conditions, and bind each signature to its exact chain.
- **Keeper tips** — pay whoever executes an intent a small tip that routes to the
  right keeper even if someone copies the transaction.
- **Support smart-account wallets** (Safe, AA wallets) as signers, not just plain
  keys.
- **Get funding right, permanently** — because how the contract pulls the user's
  money is frozen into every signature, we bake in all three ways up front:
  one-shot pulls (Permit2), recurring pulls (for scheduled intents), and
  "use the money the previous step produced" (which also enables **flash loans /
  leverage** — a whole product category that's impossible to add later).
- **Trim the fat** — delete unused/dead code paths, tidy the data format, so the
  permanent contract is as small and auditable as possible.

**Simple mental model:** off-chain and new adapters are *lego bricks* we add
freely; the processor redeploy is *pouring the foundation* — we only get to pour
it once, so we pour everything structural in at the same time, after inspection.

### What is NOT affected, ever

The submitted OKX demo, the live `asp.w3.cash` service, and the current
contracts stay exactly as they are until *we* choose to point the compiler at new
addresses — which is a deliberate, separate step, not a side effect of any of the
above.
