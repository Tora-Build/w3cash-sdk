# W3Cash — Roadmap v2

**Live today:** the intent compiler runs as a paid A2MCP service on OKX.AI (Agent
#5934) at `asp.w3.cash` — x402 pay-per-call ($0.01, USD₮0 on X Layer), MCP
endpoint (`/mcp`, 4 tools + the usage skill served as the `w3cash://skill`
resource, client-side x402 payer built in), multi-chain compiler (Base Sepolia
84532 full action set; X Layer testnet 1952 minimal core), keyless signing via
the OnchainOS Agentic Wallet proven end-to-end on-chain. `DECISIONS.md`
ADR-0001 fixes the replay/nonce architecture in one audited, immutable redeploy.

**The arc:** W3Cash becomes the safe-by-default **lifecycle owner** of a
non-custodial intent — compile → free-simulate → watch → notify → execute →
verify — funded by two streams: (a) per-call compile fees via x402, and (b) a
keep-and-execute keeper service billed per execution. The pre-audit period is
spent on the two things that actually gate demand: **safety** (pre-ADR
signatures are replayable; one drained agent ends the product) and **real
money** (a deliberately capped mainnet beachhead).

Everything below is sequenced by what it needs: nothing → new adapters → the one
ADR-0001 contract redeploy (which, because the processor is immutable, must
carry *every* processor-level feature at once).

---

## NOW — encoder / MCP / skill / off-chain only (no chain work)

### 1. Safe-by-default compilation + one-call cancel
Every compile auto-inserts a default `timeRange` expiry window (opt-out, not
opt-in), sizes token allowances to the exact per-intent need, and prints
max-total-exposure (including any keeper fee, N-execution cap) in
`humanSummary`. New `w3cash_cancel_all` MCP tool compiles and submits the
`incrementNonce()` tx — the one-transaction kill switch. Honest docs: pre-ADR,
`incrementNonce()` is the only cancel and nukes *all* intents; per-intent
cancellation is cancel-by-expiry until the redeploy. This is the churn-killer
and the pre-ADR sales answer ("we default to safe").

### 2. Keep Service v1 — watch loop + bounded per-execution fee
`keep: true` on compile + `POST /keep`: a watcher simulates `execute()` per
tick and broadcasts when the gates pass. Fee = a compiler-appended
user→keeper transfer as the last op, with the fee-token allowance
**compiler-capped to N executions' worth** (execute is permissionless pre-ADR,
so replay exposure is bounded and disclosed up front). The keeper pre-flight
simulates the *full* payload including the fee leg (TransferAdapter reverts on
insufficient allowance — it does not pause), and every `keep:true` compile
carries a mandatory expiry. Migrates transparently to the RIDER-1 header tip
after the ADR-0001 redeploy.

### 3. `w3cash_simulate_intent` — FREE pre-sign dry-run
Fifth MCP tool: would `execute()` run or PAUSE right now, which gate blocks and
by how much, gas estimate, and a revert-risk preflight of every required
allowance/balance with the exact fix-it approve call. Simulated with tx-context
overrides (real gas price — default `eth_call` gasprice=0 would make gasPrice
gates always "pass" — plus timestamp), with per-gate caveats for
state-dependent gates. Free by design: the funnel is free simulate → paid
compile → paid keep.

### 4. Intent status + portfolio + reliability telemetry
`GET /intent/:payloadHash` lifecycle (status, execution count, per-gate
current-vs-target distance, txHashes) plus list-by-initiator ("all my
active/paused intents, with humanSummary and how to cancel") — agents lose
payloadHashes across sessions; the portfolio view creates daily use. The same
read-only indexer publishes machine-readable reliability telemetry (per-recipe
compile→execute success rate, median time-to-fire, keeper uptime) — how 2026
agent frameworks select subcontractors. `POST /watch` adds gate-flip webhooks
and MCP resource notifications. Strictly a sidecar; `/compile-intent` stays
stateless.

### 5. Compile-time sanity layer
Threshold-plausibility warnings (a price gate implausibly far from spot),
decimal-conversion outlier lint, and current-values annotation in
`humanSummary`; swap autoQuote (QuoterV2-filled `minAmountOut` from
`slippageBps`, the same pattern as the existing bridge autoQuote). Pluggable
quote context, best-effort with a short timeout, never blocks compilation.

### 6. Distribution: sub-ASP positioning + vertical skills
Register in the ERC-8004 Identity Registry, accept OKX A2A marketplace compile
jobs (`toSign` as the deliverable), publish an AgentCard carrying the telemetry
field. Split the skill into per-vertical resources (dca, treasury-guard,
prediction-hedge) generated from `/capabilities` as the source of truth; charge
x402 only on the final successful compile, not clarification round-trips.

*(Committed from v1 and unchanged: the x402 pricing ladder via MPP —
`accepts[]` tiers, session channels, a2a-pay links.)*

---

## NEXT — new adapters / deploys (no processor change)

### 1. Scoped Base-mainnet execution beachhead *(the demand unlock)*
A deliberately capped mainnet deploy on Base (eip155:8453): processor +
transfer/approve actions + wait/query/timeRange/balance gates **only** — no
DeFi verbs — with mandatory default expiry and exact-sized allowances.
Allowance-bounding *is* the pre-ADR risk posture, so a capped deploy is
defensible now; distinct (non-CREATE2) addresses so missing domain separation
cannot cross-replay. Real $10–100 moves conditionally today; compile and keeper
fees are paid on the chain where the intent executes. Full DeFi-verb promotion
still gates on ADR-0001 + audit.

### 2. Permit2 SignatureTransfer pull adapter
Per-intent funding via Permit2 `SignatureTransfer`: one canonical Permit2
approval replaces N per-adapter standing approvals; each intent carries a
signed amount/deadline-scoped permit. The stack already runs Permit2 (the MCP
x402 payer). This is the bridge to RIDER 5, which bakes the same mechanism into
the processor at the redeploy.

### 3. WordLens — universal multi-return view unlock *(~40 lines, outsized win)*
A tiny stateless view contract (`extractWord`, `chainlinkAgeSeconds`,
`chainlinkAnswerFresh`, `healthFactor`, …) staticcalled by the **existing**
query condition — not an IAdapter, no registry entry. Restores the dropped
Chainlink staleness check and unlocks every multi-return getter (Aave health
factor, EAS attestations, `Governor.state`, ERC-4626 share price) as compile-fee
recipes. Codifies the "gates pause, never revert" standard: the lens returns
sentinel words instead of propagating inner reverts.

### 4. ERC-4626 VaultAdapter *(consolidates v1's per-protocol adapter list)*
`vaultDeposit` / `vaultWithdraw` / `vaultRedeemAll` with `receiver=initiator`
covers Morpho/MetaMorpho, Yearn V3, sDAI, sUSDe and every 4626 venue by
address with one adapter. Compiler-added minOut + curated vault allowlist.

### 5. Dynamic action verbs
Per-verb `dynamicTransfer` / `dynamicAaveDeposit` adapters that compute
`all | bps-of-balanceOf(initiator)` **internally at execute time** with min/max
clamps (ops are independent calls with inputs frozen at signing — there is no
channel to pass computed amounts between adapters, so per-verb is the only
correct shape). The fix that makes recurring re-execution — the keeper's
billable event — correct over time. Pairs with Permit2-scoped funding.

### 6. MEV-safe swap + stop-loss *(from the CoW/MEV workflow, 2026-07-18)*
The CoW verdict was **partial** — reject batch auctions/netting (single-user
intents have no counterparty flow), keep only *execution-time pricing* and
*signed-payee tip routing* (RIDER 1). Two concrete pieces:
- **`OracleSwapAdapter`** — the fix for swap sandwiches. A UniswapV3 swap's
  `minAmountOut` is frozen at signing (possibly weeks before execution), so the
  trigger is public Chainlink state and the extractable band is unbounded. This
  adapter recomputes the minOut **floor at the fire block** from a fresh
  Chainlink read (`floor = amountIn × oraclePrice × (1 − maxSlippageBps)`, with
  a **mandatory** staleness check floored at the feed heartbeat) + a signed
  `executeBy` expiry. Collapses max extraction to oracle-deviation + slippage
  and un-bricks upward-moved intents. **Pre-ADR: one-shot + exact allowance
  only** — recurring swaps must wait for the redeploy (replay would collapse the
  schedule). Rejected: a Dutch-decay adapter (its price anchor is set by the
  first permissionless gate-passing call → poisonable).
- **Buffer-over-speed stop-loss** (compiler policy, no contract): protective
  triggers default to a safety margin *above* the liquidation threshold (fire at
  HF 1.10, not 1.01) so the protective action and the liquidation are never valid
  in the same block — the timing race is *designed out* rather than fought (you
  cannot win a latency war vs Timeboost/priority-lane searchers). `keeperOfRecord
  = address(0)` (open bounty) for this class + best-effort tip.

### 7. Backlog + cranks
- **Aave Borrow/Repay**: deploy the already-written adapters (review pass
  first); with the WordLens healthFactor gate → "repay 500 USDC when HF < 1.15".
- **CompositeGateAdapter (OR / any-of)**: up to 8 QueryAdapter-shaped
  sub-checks, `logic=any`, PAUSE-preserving. (True k-of-N quorum is infeasible
  pre-redeploy — co-signatures are frozen inside the signed payload. Bracket/OCO
  productization explicitly gates on ADR-0001: pre-ADR, a fired stop-loss could
  re-fire on a price re-cross.)
- **SoothSettleAdapter / settlement-crank recipe**: permissionless
  `settle(market)` after the veto window — W3Cash as the settlement crank for
  our own protocol, a first-party recurring keeper event.
- **PaymentAdapter**: transfer + `bytes32 paymentId` memo + `PaymentSettled`
  event — machine-reconcilable conditional payments, correlatable to a2a-pay /
  x402 invoices.
- **Pyth pull-oracle gate**: staleness-safe price gate for chains where
  Chainlink is thin; keeper prepends the permissionless `updatePriceFeeds`.
- **Arbitrum Sepolia deploy**: the prerequisite chain for v1's committed
  GMX/perps adapters; sequence late in NEXT (everything deployed pre-ADR is
  caller-pinned and redeploys again with the fleet).

*(Committed from v1 and unchanged: conditional embedded cross-chain via Across
`depositV3` + MulticallHandler — encoding helper + recipe, no new contracts;
off-chain-data conditions via a zkTLS/kpi-resolver-style relayer.)*

---

## WITH THE ADR-0001 REDEPLOY — contract-batched

The processor is immutable, so the audited hardening redeploy is the **one
shot** to add processor-level features. The full rider list, sequencing rules,
fleet-migration plan and conformance kit are specified in `DECISIONS.md`
ADR-0001 **Addendum A** — summary:

1. **RIDER 1 — keeper tip** `{tipToken, tipAmount}` paid to `msg.sender` →
   open execution-bounty marketplace (retires the appended-transfer fee).
2. **RIDER 2 — ERC-1271** smart-account initiators → Safe / Kernel / Nexus /
   DAO treasuries become addressable customers.
3. **RIDER 3 — `executionsOf()` getters** → `afterIntent` dependency gates via
   the existing QueryAdapter ("B only after A ran n times").
4. **RIDER 4 — CREATE2 uniform addresses** (safe only *after* domain
   separation) → chain N+1 becomes a config one-liner.
5. **RIDER 5 — processor-native Permit2 funding** → one canonical approval
   ever; eliminates the standing-approval drain class.
6. **Fleet migration + public golden-vector conformance kit** — every adapter
   pins the processor address, so the redeploy re-deploys the fleet on all
   chains; the published vectors are what let third-party keepers verify
   payloads and make the RIDER-1 marketplace real.

---

## LATER / BETS

- **AMB remote dispatch** (the dormant cross-chain envelope branch): one signed
  intent carrying ops for another chain — "when ETH < $3k on Base, unwind Aave
  on Arbitrum". Gated hard on ADR-0001; largest security surface here.
- **Sooth trading actions** (`soothBuy/Sell/Mint/Redeem`): waits for
  `onBehalfOf` support in sooth-core rather than any custody-adjacent shortcut.
- **OKX DEX aggregator swap**: needs an executor-supplied-route design (frozen
  calldata goes stale; the balance-delta invariant validates fresh routes) —
  an ADR-adjacent design question, not an adapter to ship now.
- **Constrained BatchAdapter**: atomic multi-step for EOAs; only economical
  when the ADR-0001 fleet redeploy happens anyway (adapters must authorize a
  second caller).
- **HyperEVM minimal core**: landing zone for the Hyperliquid adapter;
  sequence after Arbitrum and ideally after the redeploy.
- **Proof-of-keep receipts + SLA tier**: signed per-tick attestations +
  merkle anchoring behind premium keep pricing, once Keep v1 has customers.

---

## Explicitly rejected (so we don't relitigate)

- **Generic "call anything" action adapter** — arbitrary calldata + standing
  approvals + pre-ADR replayable signatures = a drain primitive.
- **Native-ETH transfer action** — the envelope's `value` spends the
  *submitter's* msg.value, not user funds; not expressible non-custodially.
- **k-of-N runtime quorum** — all co-signatures are frozen in the signed
  payload; a real quorum needs an on-chain approval redesign (deferred).
- **Paid simulation SKU** — eth_call dry-runs are free everywhere; simulation
  is the conversion feature, not a product.
- **Keeper-network export (Gelato/Chainlink templates)** — hands the execution
  relationship to third parties weeks before our own keeper ships.
- **Storage-proof cross-chain gates** — audit surface and gas dwarf the value;
  revisit when the proof stacks commoditize.
