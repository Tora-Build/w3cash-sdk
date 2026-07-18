# Architecture Decisions (ADRs)

Records of significant, hard-to-reverse architecture decisions for W3Cash.

---

## ADR-0001 — Replay protection: per-intent EIP-712 cursor with reserve-then-run (deferred, post-audit redeploy)

- **Status:** Accepted (design) — **deferred** to a post-hackathon, audited redeploy. Not shipped.
- **Date:** 2026-07-16
- **Scope:** `W3CashProcessor.sol` and its off-chain encoder (`apps/asp/src/w3cash/encode.ts`), the MCP/skill, `packages/registry`, golden-vector tests, and both deployments (Base Sepolia 84532, X Layer testnet 1952).

### Context

`W3CashProcessor` is **immutable** (no admin, no `Ownable`). Today it uses **one nonce per user** (`mapping(address => uint256) nonces`). `execute()` verifies a signature against `nonces[initiator]` but **does not consume it**; `incrementNonce()` bumps the counter, invalidating **all** of that user's intents at once. The signed digest is `keccak256(abi.encodePacked(keccak256(payload), nonce))` under an **EIP-191 personal_sign** — with **no chainId / verifyingContract domain separation**.

Consequences of the current design:

1. **Replayable one-shots.** A signed payload stays valid until the shared nonce advances, so a one-time transfer can be re-executed (bounded only by the token allowance). The signed payload is also public in the tx calldata after the first submit.
2. **Coarse cancellation only.** There is no per-intent cancel — `incrementNonce()` cancels every intent at the current nonce.
3. **No cross-chain domain separation.** A signature valid on X Layer (1952) is not cryptographically prevented from replaying on Base Sepolia (84532); today only the chain-specific adapter addresses in the payload provide incidental protection.

**Non-negotiable constraints** (any fix must preserve these — verified against the code):

- **PAUSE → resume:** when a condition is not met, `execute()` emits `WorkflowPaused` and returns *before any state write*; the **same** signed payload is re-submitted later when the gate flips true. There is no on-chain seq cursor for local flows.
- **Recurring / scheduled intents:** a single signed intent that re-runs each time a time/price gate passes again (DCA, etc.).

The naive fix — "consume the nonce on execute" — **breaks both** of these. This ADR records the design that does not.

### Decision

Adopt **Design A (Hardened): a per-intent EIP-712 digest keying a single packed state slot, with reserve-then-run ordering.**

**Storage / signing:**

```solidity
struct IntentState { uint32 executions; uint40 lastExecuted; bool cancelled; } // one packed slot
mapping(bytes32 => IntentState) public intentState;   // key = EIP-712 digest
mapping(address => uint256)     public epoch;         // was `nonces`; folded into the digest -> cancel-ALL
uint256 private _reentry = 1;                          // nonReentrant

bytes32 private constant INTENT_TYPEHASH = keccak256(
  "Intent(address initiator,bytes32 payloadHash,uint256 epoch,uint64 deadline,uint32 maxRuns,uint40 cooldown,bytes32 salt)");
```

The signed header gains **`deadline` (uint64), `maxRuns` (uint32), `cooldown` (uint40), `salt` (bytes32)**, and the digest is a fork-safe EIP-712 hash bound to `{name, version, chainId, verifyingContract}`.

**execute() — checks → effects (reserve) → interactions:**

```solidity
function execute(Intent calldata it, bytes calldata sig) external nonReentrant {
  require(block.timestamp <= it.deadline, Expired());
  require(it.maxRuns == 1 || it.cooldown > 0, CooldownRequired());        // recurring must be paced
  bytes32 digest = _eip712(it, epoch[it.initiator]);
  require(ECDSA.recover(digest, sig) == it.initiator, BadSig());
  IntentState storage s = intentState[digest];
  require(!s.cancelled, Cancelled());
  require(it.maxRuns == 0 || s.executions < it.maxRuns, Exhausted());
  require(block.timestamp >= uint256(s.lastExecuted) + it.cooldown, Cooldown());
  if (!_gatesPass(it)) { emit WorkflowPaused(digest); return; }           // pause writes NOTHING -> resume intact
  unchecked { s.executions += 1; }                                        // RESERVE before actions
  s.lastExecuted = uint40(block.timestamp);
  _runActions(it);
}

function cancelIntent(Intent calldata it) external {                       // per-intent selective cancel
  require(msg.sender == it.initiator, NotOwner());
  intentState[_digest(it)].cancelled = true;                              // one SSTORE; other intents untouched
}
function incrementEpoch() external { epoch[msg.sender] += 1; }             // renamed incrementNonce; cancel-ALL
```

**The load-bearing fix (found by the adversarial review):** the reserve of `executions`/`lastExecuted` happens **before** `_runActions`, and a `nonReentrant` guard is added. Every candidate design, as first drafted, wrote the replay counter *after* the external actions — letting a reentrant action callee (token hook, swap router, bridge, Aave) re-enter `execute()` and drain a "one-shot" N times in a single transaction. Reserve-then-run + `nonReentrant` closes this; `maxRuns == 1 || cooldown > 0` closes the `maxRuns == 0` same-block loop.

**This delivers all four goals:** per-intent replay protection (`maxRuns=1` ⇒ true single-use), per-intent selective cancel (`cancelIntent`), per-intent expiry (`deadline`), and cross-chain domain separation (EIP-712 `chainId`/`verifyingContract`). Cancel-ALL is retained by folding `epoch` into the digest (Seaport `incrementCounter` pattern) — one SSTORE rotates every digest.

### Why resume + recurring still work

- **Resume:** the pause branch returns *before any SSTORE*, so a paused intent's record stays `{0, 0, false}`. `epoch/deadline/maxRuns/cooldown/salt/payload` are all fixed in the signed header, so re-submitting identical calldata reproduces the identical digest, re-enters the same non-terminal record, and only reserves `executions=1` on the completing (post-gate) run. Reserve-then-run never touches the pause path.
- **Recurring:** reusable intents sign `maxRuns=0` (unlimited) or `N` and never terminalize (the digest is stable across runs because the counters live in the record, not the digest). The on-chain condition inside `_gatesPass` is the primary re-execution guard; `cooldown > 0` closes the same-block window the condition alone leaves open.
- **ASP policy (encode off-chain, not on-chain):** open-ended condition-gated intents sign `deadline = type(uint64).max` (the existing year-2199 infinite sentinel) so a finite default cannot expire a slow-to-flip resume; schedules are expressed as pause-able gates in `_gatesPass`, not via `cooldown` (which reverts, not pauses).

### Alternatives considered

- **Design B — Permit2/Seaport order-hash + unordered nonce bitmap.** Gives granular *and* batch (256-at-a-time) cancel. **Rejected for now:** batch-cancel-of-hundreds is not a current requirement, and the off-chain nonce/bit allocator adds a stateful failure mode (a colliding bit silently bricks a fresh intent and can break resume). Promote only if high-volume parallel issuance / mass-cancel becomes real.
- **Design C — Session keys + spend caps + policy modules (ERC-7579-style).** Root key grants a bounded, expiring, individually-revocable session to a hot signer; three revocation tiers; spend-cap budget. **This is the full-redesign end-state** — worth baking in *now* (the contract can't be upgraded) *only if* delegated agent-signing / spend-caps become a first-class product goal. Highest contract/encoder/ASP/test surface; its `spent += cost` accounting has the same reserve-before-interactions requirement, plus an immutable `_policyAllows` decoder that voids the guarantee if buggy.
- **Naive "consume the nonce on execute".** **Rejected:** breaks PAUSE→resume (a paused first run would consume the nonce) and recurring (each run would consume it).

### Consequences

- **Backward-incompatible, immutable ⇒ fresh redeploy + client migration.** Signature format changes `personal_sign → signTypedData_v4`; old intents cannot be auto-re-signed. There is no in-place patch path, so even the "minimal viable" change is a redeploy.
- **Migration sequence:** (1) freeze hardened source; Foundry tests including a malicious-reentrant callee proving `maxRuns=1` reverts `Exhausted` on reentry and recurring reverts `Cooldown` same-block; deploy immutably on **both** chains, record addresses. (2) Encoder/MCP emit the EIP-712 struct + new fields and sign via `signTypedData_v4` with domain `{name:"W3Cash", version:"1", chainId, verifyingContract}`; expose per-intent + cancel-ALL. (3) ASP populates `maxRuns` (1 one-shot / 0|N recurring), `cooldown` (>0 for recurring), `deadline` (`uint64.max` for open-ended), and an **all-time-unique `salt`** per intent (uniqueness is an ASP invariant — a duplicate salt self-collides two identical intents onto one record). (4) `packages/registry/nodes.json`: add the two new processor addresses, bump `version`, redeploy `registry-api`. (5) Regenerate **all** golden vectors (per-chain: 84532 and 1952 produce distinct digests — that *is* the cross-chain-separation property under test) + negative vectors (expired / cancelled / exhausted / cooldown / wrong-chain). (6) Parallel-run new + old processors; ASP stops issuing to the old address; in-flight old intents drain or expire. No on-chain state migration is possible.
- **Minimal viable build (still a redeploy):** one struct, one mapping, one EIP-712 domain, four `require`s, one `nonReentrant` modifier, two small functions — **no change to the conditions/actions engine.**

### Residual risks

- **Paused-path griefing (low, funds-safe):** `execute()` is permissionless and the payload is public, so anyone can spam `execute()` on a not-yet-triggered intent to emit `WorkflowPaused` and burn oracle-read gas. Mitigate at the indexer/keeper, or add a `lastSeen` SSTORE on the pause path if judged worth the gas.
- **Salt-collision self-DoS (reliability):** a duplicate/buggy ASP salt maps a second identical intent onto the first's terminal record → `Exhausted`. Mitigate with an ASP uniqueness guarantee + client pre-check.
- **`incrementEpoch()` also cancels paused/scheduled intents** (intended but sharp) — surface in UI as "cancel-ALL also cancels pending/scheduled."
- **Fork replay** if the `_domainSeparator()` lazy-recompute is dropped — it is mandatory, not an optimization.
- **Immutability tax:** any shipped bug (e.g. off-by-one in the cooldown compare) has no patch path but a full redeploy + client re-migration on both chains. Golden vectors are release gates.

### Open questions

- Is mass-cancel / high-volume parallel issuance a near-term need? (If yes → Design B's bitmap.)
- Are agent-spend-caps / delegated hot-key signing on the roadmap within this immutable deploy's life? (If yes → jump to the Design C end-state now.)
- On-chain minimum `cooldown` floor for recurring intents, or leave entirely to the ASP?
- Close paused-path event spam on-chain (`lastSeen` SSTORE) or accept + handle at the indexer?

_Source: multi-agent research + adversarial-review workflow, 2026-07-16 (AA/ERC-4337 nonces, ERC-7579 session keys, Seaport/0x/Permit2 order-hash + bitmap nonces, Gnosis Safe + EIP-712 domain separation, recurring-execution systems)._

---

## ADR-0001 — Addendum A: redeploy riders & batch scope

- **Status:** Accepted (design) — locks the feature set that rides the ADR-0001 redeploy. Must be folded into the contract spec **before** audit freeze.
- **Date:** 2026-07-17

### Why an addendum

The processor is immutable: the audited hardening redeploy is the **only**
window to add processor-level features without a second migration cycle. This
addendum enumerates exactly what rides that redeploy (the "riders"), what is
deliberately excluded, the hidden costs now booked, and resolutions to the open
questions from the base ADR. Anything processor-level not on this list waits an
entire redeploy cycle — err on the side of speccing now, cutting at audit.

### Base-ADR corrections (2026-07-18, from the CoW/MEV mechanism-design workflow)

Two **critical** findings sit *upstream* of every tip/MEV mechanism and amend the
base ADR-0001 Decision itself — they are the load-bearing anti-MEV fixes:

- **C1 — bind the full header; assert `seq == 0` always (forced-firing fix).**
  Today's digest `keccak256(abi.encodePacked(keccak256(payload), nonce))` binds
  only the payload + nonce, **not** the instruction header's `seq`/`length`. An
  attacker who alters the unsigned header can make `_execute()` skip ahead and
  run actions with **condition gates bypassed** — a master key over any intent.
  The EIP-712 digest MUST bind the full header (`seq`, `length`, `payloadHash`),
  and `_execute()` MUST assert `seq == 0` for **every** execution. **There is no
  resume path and no processor-stored progress state** — PAUSE is an atomic
  whole-intent no-op re-run from the start. *(This corrects the base ADR's
  "resume from processor-stored progress state" language, which described storage
  the processor does not have and contradicted the zero-new-storage claim.)*
- **C2 — domain = the execution chain; cross-chain = multi-leg envelopes.** The
  EIP-712 domain is `{chainId, verifyingContract}` of the processor that will run
  the actions. A cross-chain flow is a multi-leg envelope: the destination leg is
  a **separate sub-intent signed for the destination processor's domain**,
  carried opaquely by `_sendCrossChainMessage`; the source processor never
  verifies destination legs, and a source-domain signature is invalid on any
  other chain by construction. Naive domain separation *without* this envelope
  format would silently convert a low-severity replay into a dead bridge feature
  — so the envelope format must be frozen in the same struct freeze.

### Riders (in the frozen spec)

**RIDER 1 — Keeper tip with signed-payee routing** *(revised after the CoW/MEV
mechanism-design workflow, 2026-07-18 — the earlier "exclusive-then-open window"
idea below is superseded and rejected).*

Three fields in the signed EIP-712 header: `{ tipToken: address, tipAmount:
uint128, keeperOfRecord: address }`. On the **non-pause path only**, the
processor routes a best-effort tip: `tipRecipient = keeperOfRecord != 0 ?
keeperOfRecord : msg.sender`. **No window fields, no time terms, no
execution-state reads in the payout path.**

- **R1.0 preconditions (non-negotiable):** ships only in the same redeploy as
  the base-ADR execution-state + nonce-consumption + CEI (a tip on a replayable
  signature is a drain); the digest must bind the **full instruction header
  (seq/length/payloadHash)** and `_execute()` must assert `seq == 0` always
  (see the base-ADR correction below); domain = the **execution** chain, with
  cross-chain flows as multi-leg envelopes (destination leg signed for the
  destination processor, forwarded opaquely — a source-domain signature is
  invalid elsewhere by construction).
- **R1.2 best-effort payout:** after all state updates, still inside
  `nonReentrant`, attempt `tipToken.transferFrom(initiator, tipRecipient,
  tipAmount)` as a **gas-capped (~150k) low-level call**; on failure emit
  `TipFailed` and continue. A dry allowance degrades the intent to *untipped*
  (recoverable by topping up — no re-sign), never bricks it. *(The atomic
  "reverting tip reverts execution" rule is rejected: a cents-level allowance
  grief on the shared (user, token) approval could DoS a protective action worth
  a 5–10% liquidation penalty.)*
- **R1.3 censorship resistance:** `execute()` stays permissionless for everyone
  at every instant — routing touches *payment* only, never gates/delays/
  prioritizes execution. A user censored by their keeper is executable by anyone
  (untipped if `keeperOfRecord` set, tipped if `address(0)`).
- **R1.4 honest scope (normative):** DOES prevent tip-theft-by-calldata-copy (a
  sniper who copies the tx pays the tip to `keeperOfRecord`; the copier donates
  gas — no priority-gas auction forms over the tip). DOES NOT fund/verify
  monitoring (the tip pays for *landing a tx*; monitoring is priced + policed by
  the off-chain SLA), force promptness, stop swap sandwiches (a searcher can
  self-trigger the public bearer payload — the `OracleSwapAdapter` floor is the
  defense), or provide an in-protocol dead-keeper backstop when `keeperOfRecord
  != 0` (recovery = untipped permissionless execution / cancel-and-resign).
- **R1.5 class defaults (compiler policy):** stop-loss/liquidation-protection →
  `keeperOfRecord = 0` (open bounty; any-fast-someone maximizes liveness) +
  buffer-over-speed trigger; recurring DCA → Keep v1's baked-recipient transfer
  stays primary; the compiler MUST surface `keeperOfRecord` as an explicit
  choice against a published keeper directory (self / Keep service / third party
  / none), NEVER a silent house default, and MUST NOT price-discriminate on it
  (anti-incumbency).
- **R1.7 non-goals:** no exclusivity windows, no commit-reveal (the payload is a
  public bearer instrument from run 1 — nothing is secret), no on-chain tip
  auction, no escalation/ramp fields, no bonding in the processor, no tip on the
  pause path.
- **Audit surface:** three struct fields, one ternary, one gas-capped external
  call after all state updates inside `nonReentrant`, **zero** new storage
  mappings, zero execution-state reads in the payout path.

*Why the window died:* the "exclusive-then-open" variant protected
cooldown-paced runs (which a cron can fire — they need no monitoring) and
abandoned gate-flip-timed runs (the only ones that do), invited
`openAfter`-squatting + straddle-pacing by the keeper, and had a CEI-ordering
footgun. Unconditional signed-payee routing keeps the one property that held
(snipe-dominance, at every instant) and deletes every exploit hanging off the
windows. Monitoring quality is a lemons market that only a provable-fault SLA
(gate provably true at block B via Chainlink round data, no execution within N
blocks, no third-party execution to excuse it) can police — not a tip.

**RIDER 2 — ERC-1271 smart-account initiators.** If `initiator` has code,
verify via `IERC1271.isValidSignature(hash, sig)` instead of `ecrecover` — one
fallback branch in the verification code the base ADR already rewrites for
EIP-712, plus compiler emission of the 712 struct a Safe UI can sign. Admits
Safe / Kernel / Nexus / DAO treasuries, which are entirely locked out today.
Explicitly **not** the rejected Design C (session keys / policy modules) —
policies stay in the user's own account.

**RIDER 3 — Intent-dependency getters.** Public single-word views
`executionsOf(bytes32 digest) → uint256` (and `lastExecutedOf`) unpacking the
packed `IntentState`, so `afterIntent` conditions compile to the
already-deployed QueryAdapter targeting the processor itself — "intent B only
after intent A ran n times" (sequencing, ordered workflows). Document that
"A executed" means the whole payload ran (execute is all-or-nothing).

**RIDER 4 — CREATE2 uniform-address deployment kit.** Deterministic-factory
deploys of the post-audit processor, registry, and portable adapters with fixed
salts, so every chain shares one canonical address set and chain N+1 becomes a
config one-liner. **Hard prerequisite: the base ADR's EIP-712 domain
separation** — uniform addresses under today's EIP-191 scheme would be a
cross-chain replay *amplifier*. DeFi adapters with chain-specific constructor
args stay per-chain.

**RIDER 5 — Processor-native Permit2 funding.** Per-intent funding via
witness-bound Permit2 `SignatureTransfer` in the CEI block: one canonical
Permit2 approval forever, zero standing per-adapter allowances (eliminating the
standing-approval drain class entirely), and the RIDER-1 tip pull rides the
same path. Moderate audit surface — the strongest security-posture upgrade per
contract line. The NEXT-tier Permit2 *adapter* (see ROADMAP v2) proves the flow
pre-audit and graduates into this.

### Booked costs (not riders — consequences)

**Adapter-fleet migration.** Every adapter pins the processor address as an
immutable constructor arg, so the redeploy forces redeploying **all** adapters
on **all** chains and re-collecting user approvals. Sequencing rule: NEXT-tier
adapter deploys land as close to the redeploy as possible to avoid double
deployment; the constrained BatchAdapter's second-authorized-caller change
rides this same fleet redeploy (the only time it is cheap).

**Public golden-vector conformance kit.** Publish the encode/digest test
vectors (per chain — 84532 and 1952+ produce distinct digests; that *is* the
domain-separation property under test) so third-party keepers and integrators
can independently verify payloads. Required for the RIDER-1 marketplace to
have participants; a trust artifact for a trust-is-the-product service.

### Open questions from the base ADR — resolved

- **On-chain minimum cooldown floor:** yes — a small constant floor for any
  reusable intent (`maxRuns != 1`), keeping high-frequency DCA possible while
  preventing same-block loops; the ASP may impose stricter per-recipe floors.
- **Paused-path event-spam:** handle at the indexer, **no** `lastSeen` SSTORE
  on the pause path — funds are safe, the attacker pays gas, and the pause path
  must stay write-free to preserve the resume property.

### Explicitly NOT riding the redeploy

- OR/any-of gate composition — ships earlier as `CompositeGateAdapter`, no
  processor change (bracket/OCO *marketing* still gates on the redeploy, since
  pre-ADR a fired leg can re-fire).
- WordLens, Pyth gate, ERC-4626 vault, dynamic verbs, Borrow/Repay — all
  processor-free by design (see ROADMAP v2, NEXT tier).
- The scoped Base-mainnet beachhead — deliberately pre-ADR with capped verbs,
  bounded allowances, mandatory expiry, and distinct (non-CREATE2) addresses.
- Session keys / policy modules (Design C), k-of-N runtime quorum, generic
  call-anything adapter — rejected in the base ADR / roadmap; unchanged.

_Sources: multi-agent opportunity-research + adversarial-critique workflow,
2026-07-17 (6 opportunity spaces × novelty/feasibility/value critique panel);
RIDER 1 + corrections C1/C2 revised by the CoW/MEV mechanism-design workflow,
2026-07-18 (threat model → CoW/MEV/keeper-game-theory research → design →
game-theory/implementability/complexity critique panel). Verdict on "CoW for
everything": PARTIAL — reject batch auctions / coincidence-of-wants / uniform
clearing (single-user intents have no counterparty flow; firing is
same-direction gate-correlated). Keep only the signed-payee routing principle
(RIDER 1) and execution-time oracle pricing (OracleSwapAdapter, ROADMAP NEXT)._

---

## ADR-0001 — Addendum B: contract-architecture scope for the redeploy

- **Status:** Accepted (design) — extends the ADR-0001 redeploy freeze list beyond
  the 5 riders. Fold into the audit scope before freeze.
- **Date:** 2026-07-18
- **Verdict:** **Keep the shape, do surgical (not sweeping) core surgery.** The
  processor + per-adapter + user-signs-the-EXACT-target envelope is the right
  foundation (Seaport-zone posture). The immutable redeploy is a once-ever chance,
  so it must carry every processor-level change — but only the ones that are
  *unfixable if omitted*. Everything else ships later as a redeployable adapter.

### KEEP (the current minimalism is right)

- **Immutability + non-custodial + permissionless `execute()`** — the "no admin
  can change the rules" pitch *is* the product; every change here is admin-free.
- **User signs the EXACT target** on the local path — a deliberate divergence from
  outcome-declarative intent standards, not legacy drift. Re-encoding to a
  7683/7521 solver-fill envelope is a **category error**: a solver structurally
  cannot fill a local W3Cash intent (no counterparty), and it would import the
  counterparty risk our value prop removes.
- **Per-adapter contracts as the evolvability story** — a new capability = deploy
  a new immutable adapter, usable the instant the SDK knows its address. Zero
  processor change. Formalize this as official.
- **PAUSE-sentinel gates + whole-intent atomicity-on-revert** — a hard revert
  already unwinds the whole intent, so **no all-or-nothing wrapper is needed**.
- **The `OnlyProcessor` caller-pin — KEPT (reversal of an earlier draft).** It is
  a free, universal, one-line boundary guard on an unpatchable contract. Dropping
  it to "avoid the fleet-migration tax" is a false economy (that tax is paid once
  this redeploy regardless) and would trade enforceable defense-in-depth for an
  unenforceable "every future adapter must stay perfectly stateless" discipline.

### ADD to the redeploy (unfixable-if-omitted core primitives)

1. **Multi-mode funding descriptor** (frozen into the interpreter, one per op):
   (a) **Permit2 SignatureTransfer** witness-bound pull — one-shot, exact amount;
   (b) **standing authorization** (AllowanceTransfer or approve-to-processor),
   per-run cap gated by the ADR-0001 cursor — because single-use nonces *cannot*
   fund keyless `maxRuns>1` recurring intents; (c) **contract-held-balance
   ("balance-threading")** — an op funds from the processor's transiently-held
   balance of a token, which is how chained dynamic-amount flows, cross-chain
   inbound legs, *and* flash-loan sub-groups all get funded. The processor is the
   **sole** Permit2 caller. *(Rejected: Permit2 as the SOLE path — it can't fund
   recurring or dynamic ops and buys no free upgrades, since `spender=processor`
   is baked into every signature.)* Frozen into every signature → get it wrong and
   you need a **second** core redeploy.
2. **Controlled-callback reentrancy frame** (the top previously-missed primitive).
   Instead of a blanket `nonReentrant`, a **known-entrypoint** guard that admits
   exactly ONE bounded flash-loan callback sub-group (funded by balance-threading)
   and blocks uncontrolled re-entry everywhere else. Omitting it forecloses the
   entire **leverage / collateral-migration / debt-refinance** surface *forever*
   (the guard + loop shape are frozen). Highest audit-risk item in the freeze —
   its "admits only the designated sub-group" property must be proven on every
   exit path.

### SUBTRACT from the redeploy (all critiques agree — dead surface off an immutable contract)

- Delete the **dormant cross-chain AMB branch** (`_sendCrossChainMessage`,
  inline-asm `_updateHeader`, the `getChain` routing test, `getAdapter(amb).send`)
  → processor becomes a **pure local interpreter**. 2026 cross-chain is
  solver-settlement (see below), not the lock-and-message branch.
- Delete `AdapterRegistry`'s local-path role + the dead `authorizedEndpoints` /
  `setAuthorizedEndpoint` admin state. The processor takes **no** per-chain
  constructor immutables (preserves RIDER-4 uniform addresses); any chain table
  is a pure external `ChainRegistry`, never folded into processor immutables.
- **Compact op encoding**: replace the 6-field tuple (`chain,amb,fee,target,
  selector,value` — `amb/fee/chain` dead locally, `selector` decoded-then-
  discarded) with `(target, value, fundingMode, fundingParams, flags)` and a
  **generously-provisioned variable-length** funding/flags field — NOT crammed
  into the dead `bytes8`.
- **Split `IAdapter`** into `IActionAdapter` / `IGateAdapter` / `IBridgeAdapter`
  (or ERC-165 probing); only `IBridgeAdapter` carries `send/estimateFee`.
  `IActionAdapter` declares its funding mode + the first-word-return convention
  balance-threading relies on.
- **`msg.value` conservation**: assert `sum(op.value)+fees == msg.value` and
  sweep residual/dust to the initiator on exit — no permanently locked ETH.

### DEFER (ships later as redeployable adapters — do NOT burn freeze bandwidth)

- The general **Weiroll-style register VM** — highest permanent audit cost; the
  dominant "swap then deposit the ACTUAL output" case is covered by
  balance-threading + purpose-built dynamic adapters.
- **OPTIONAL / try-catch control flow** — best-effort multi-venue is a
  redeployable `MultiRouteSwapAdapter`; swallowing reverts around fund movement
  is a loss/griefing bug class.
- **x402 escrow/receipt schema** — redeployable periphery, unproven schema,
  reintroduces custody. Ship as a `ReceiptAdapter`/`EscrowAdapter` later.

### New standalone contracts (ship ANYTIME — the processor need not know them)

| Contract | Purpose | Value |
|---|---|---|
| **`PostConditionAdapter`** | A delta-assertion gate placed AFTER action ops whose unmet behavior is **REVERT** (not pause) — snapshot before, check after; the on-chain slippage/MEV safety net. | 9 |
| **`OracleReadAdapter`** (typed) | **Fixes a real current bug:** `QueryAdapter` does `abi.decode(result,(uint256))`, which reads `latestRoundData()`'s first word = `roundId`, **not** the price. A typed reader for Chainlink/Pyth/RedStone/API3/ERC-4626. Supersedes the roadmap's "WordLens." | 8 |
| **`ERC7683BridgeAdapter`** | Canonical cross-chain outbound leg: opens an ERC-7683 `CrossChainOrder` to Across/solvers, funded via balance-threading. | 8 |
| **`W3CashResolver`** | Stateless `resolve(signedPayload) → (tokensSpent[], gates[], recipient, deadline)` — simulation/preview, 7683-field-shaped. | 8 |
| **`W3CashReceiver`** (per-chain) | Cross-chain ACTIONS inbound: `handleV3AcrossMessage`/`ccipReceive`, holds bridged funds transiently, forwards the C2-signed destination envelope. | 7 |
| **`FlashLoanAdapter`** shells | Pool-specific (Aave/Balancer/Morpho) shells that drive the in-core controlled-callback frame. | 7 |
| **`KeeperCoordinator`** | Stake/rotate/reputation/slash for the keeper economy — kept OUTSIDE the core; users sign `keeperOfRecord = coordinator` (RIDER-1 seam). | 5 |

### Open questions for the audit / freeze

- Recurring funding: standing AllowanceTransfer vs direct approve-to-processor
  vs per-run fresh SignatureTransfer.
- The controlled-callback guard must be **proven** to admit only the designated
  flash sub-group on every path (revert/pause/normal).
- Balance-threading isolation: no cross-intent balance-confusion (one intent's
  residual funding another's op).
- Op-encoding **headroom**: reserve enough in the funding/flags field that a
  future funding mode (e.g. ERC-4626 share-based) fits without a second redeploy.
- If **EIP-1153 transient storage** backs balance accounting, **zero every slot
  on every exit path** (SIR.trading lost $355k to an unzeroed `TSTORE`).
- Migration honesty (product-side): outstanding recurring intents run out their
  life on v1 (spender + verifyingContract binding); new intents sign against v2.

_Source: multi-agent contract-architecture workflow, 2026-07-18 (5 topics:
intent standards / execution model / missing primitives / upgradeability /
cross-chain → synthesis → over-engineering-trust / migration-immutability /
feasibility-completeness critique panel; the final revision reversed two of its
own draft's core moves — dropping the caller-pin and Permit2-as-sole-path)._
