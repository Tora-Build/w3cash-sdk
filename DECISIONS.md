# Architecture Decisions (ADRs)

Records of significant, hard-to-reverse architecture decisions for W3Cash.

---

## ADR-0001 — Authorization & replay protection: session keys + spend caps over a per-intent EIP-712 cursor (deferred, post-audit redeploy)

- **Status:** Accepted (design) — **deferred** to a post-hackathon, audited redeploy. Not shipped.
- **Date:** 2026-07-16 (base) · **Decision changed 2026-07-18: Design A → Design C (session keys + spend caps + policy modules).**
- **Scope:** `W3CashProcessor.sol` and its off-chain encoder (`apps/asp/src/w3cash/encode.ts`), the MCP/skill, `packages/registry`, golden-vector tests, and both deployments (Base Sepolia 84532, X Layer testnet 1952).

> **⚠ Decision changed (2026-07-18).** This ADR originally adopted **Design A**
> (per-intent EIP-712 cursor). The open question *"are agent-spend-caps /
> delegated hot-key signing on the roadmap within this immutable deploy's life?"*
> is now answered **YES** — delegated agent signing with bounded, revocable,
> spend-capped session keys is a **first-class product goal** of an agent-facing
> intent compiler (the keyless OnchainOS Agentic Wallet grants a scoped session to
> a hot execution key; the agent signs many intents cheaply within the budget). We
> therefore adopt **Design C** as the end-state, built **on top of** Design A's
> load-bearing mechanics (reserve-then-run CEI, `nonReentrant`, PAUSE-atomic
> whole-intent no-op, EIP-712 execution-chain domain). Design A is retained below
> as the substrate + the runner-up. **This spec was adversarially hardened on
> 2026-07-18 (5-angle research → hardened design → 5-lens critique panel, 12
> agents) — see Addendum C for the frozen pre-audit fix list (11 amendments).**
> Verdict: **proceed to audit after the amendments, not a rethink** — the
> authorization core survived all five lenses. The two flagged sharp edges (the
> immutable `_policyAllows` decoder; the per-token spend reserve under reentrancy /
> flash) are resolved there, along with a critical hole the panel found that the
> first draft missed: a uniform "every op is a fundable ACTION" policy check would
> have bricked every gated intent (the condition is a read-only GATE op in the same
> ops array). **Addendum C amendments 1–11 are normative for the freeze.**

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

Adopt **Design C: root-granted session keys with per-token spend caps and a typed
policy module**, layered on **Design A's hardened per-intent cursor** (the
substrate below). The root account grants a bounded, expiring, revocable session
to a hot signer; the session key signs individual intents; the processor enforces
policy + spend-cap + per-intent replay protection on every `execute()`.

#### Substrate — Design A mechanics (retained, unchanged)

Design C does not replace the per-intent cursor; it wraps it in a session-authority
layer. Everything here still holds — the intent digest, packed `IntentState`,
reserve-then-run CEI, `nonReentrant`, and the cancel-ALL epoch all carry over.

**Storage / signing:**

```solidity
struct IntentState { uint32 executions; uint40 lastExecuted; bool cancelled; } // one packed slot
mapping(bytes32 => IntentState) public intentState;   // key = EIP-712 intent digest
mapping(address => uint256)     public epoch;         // was `nonces`; folded into digests -> cancel-ALL
uint256 private _reentry = 1;                          // nonReentrant

bytes32 private constant INTENT_TYPEHASH = keccak256(
  "Intent(bytes32 session,bytes32 payloadHash,uint64 deadline,uint32 maxRuns,uint40 cooldown,bytes32 salt)");
```

*(The intent no longer carries `initiator`/`epoch` directly — it binds to a
`session` digest, which itself binds the root + epoch. See the Design C layer.)*

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

**This delivers all four substrate goals:** per-intent replay protection (`maxRuns=1` ⇒ true single-use), per-intent selective cancel (`cancelIntent`), per-intent expiry (`deadline`), and cross-chain domain separation (EIP-712 `chainId`/`verifyingContract`). Cancel-ALL is retained by folding `epoch` into the digest (Seaport `incrementCounter` pattern) — one SSTORE rotates every digest. *(In Design C the single-sig `execute(Intent, sig)` above is superseded by the two-signature session form below; the intent-cursor mechanics are identical.)*

#### Design C layer — session keys, spend caps, typed policy

**The delegation model.** The **root** account (the user / agent owner; an EOA
**or** an ERC-1271 smart account — this absorbs RIDER 2) signs **one**
`SessionGrant` that delegates a bounded authority to a **session key** (a hot
signer, e.g. the keyless OnchainOS Agentic Wallet's session key). The session key
then signs **many** intents cheaply, within the grant's policy + budget. This is
the product thesis: root grants once, the agent operates autonomously inside a
provable, revocable envelope.

**Storage / signing (adds to the substrate):**

```solidity
// resetPeriod == 0 => absolute lifetime cap (default). > 0 => rolling window
// {cap per resetPeriod}. address(0) = native-ETH cap. (Addendum C Resolution 2.)
struct TokenCap { address token; uint128 cap; uint40 resetPeriod; }

struct SessionGrant {                                     // signed by ROOT (EIP-712)
  address root;            // grantor; EOA or ERC-1271
  address sessionKey;      // hot signer authorized to sign intents
  uint40  expiry;          // Tier-1 passive revocation (no tx)
  bytes32 policyHash;      // keccak256(abi.encode(Policy)) — bound INSIDE _policyAllows
  bytes32 salt;            // >=128-bit CSPRNG; ASP-unique across live AND revoked grants
}

struct Policy {                                           // the immutable typed decoder's input (executor-supplied preimage, hash-checked)
  address[] allowedTargets;   // codehash-pinned target allowlist; EMPTY = DENY ALL (fail-closed)
  uint32    allowedVerbMask;  // permitted action kinds; 0 = deny all; verb read from the pinned adapter, not op bytes
  TokenCap[] caps;            // per-token budgets (len<=16, no dup tokens); a token absent = DENIED
}

struct Session { uint40 revokedAt; }                      // 0 = live; Tier-2 selective revoke
struct CapCursor { uint128 spent; uint40 lastReset; }     // persistent per (session, token)
mapping(bytes32 => Session) public sessions;              // key = grant digest (binds root + epoch)
mapping(bytes32 => mapping(address => CapCursor)) public spentByToken; // reset-before-reserve for rolling windows
// intentState / epoch / _reentry as in the substrate; epoch is folded into BOTH digests.
// Cap exemption is SOURCE-keyed: root-sourced pulls (Permit2 / standing allowance) count;
// balance-threaded pulls draw ONLY from a transient per-execute frameReceived[token] ledger and
// never count. spentByToken stays PERSISTENT; never mirrored in transient. (Addendum C Resolution 1.)
```

**Three revocation tiers** (matched to the operational reality of a leaked hot key):

1. **Tier 1 — passive expiry.** `block.timestamp <= grant.expiry`. No transaction; the session simply dies. The ASP sizes this from the off-chain safe-default expiry (short for one-shot sessions, longer for scheduled/DCA).
2. **Tier 2 — revoke one session** (`revokeSession(grant)` by root): sets `sessions[gDigest].revokedAt` — that hot key is dead, the root's other sessions live. The routine "rotate a suspect agent key" path.
3. **Tier 3 — cancel ALL** (`incrementEpoch()` by root): rotates `epoch`, invalidating every session **and** intent bound to the old epoch in one SSTORE (Seaport pattern). The nuclear option (root-key compromise).

Per-**intent** `cancelIntent` from the substrate still gives sub-session granularity.

**execute() — the session form (checks → policy → gates → reserve → interactions):**

```solidity
function execute(
  SessionGrant calldata g, bytes calldata rootSig,   // signed ONCE by root, reused
  Intent calldata it,      bytes calldata sessionSig // signed per-intent by the hot key
) external nonReentrant {
  // 1. GRANT authority (root)
  require(block.timestamp <= g.expiry, SessionExpired());
  bytes32 gDigest = _grantDigest(g, epoch[g.root]);            // EIP-712, execution-chain domain (C2)
  _verifyRoot(g.root, gDigest, rootSig);                       // ecrecover OR IERC1271 (RIDER 2)
  require(sessions[gDigest].revokedAt == 0, SessionRevoked());
  // 2. INTENT authority (session key)
  require(it.session == gDigest, WrongSession());
  require(block.timestamp <= it.deadline, Expired());
  require(it.maxRuns == 1 || it.cooldown > 0, CooldownRequired());
  bytes32 iDigest = _intentDigest(it);                         // binds full header, seq==0 (C1)
  require(ECDSA.recover(iDigest, sessionSig) == g.sessionKey, BadSessionSig());
  IntentState storage s = intentState[iDigest];
  require(!s.cancelled, Cancelled());
  require(it.maxRuns == 0 || s.executions < it.maxRuns, Exhausted());
  require(block.timestamp >= uint256(s.lastExecuted) + it.cooldown, Cooldown());
  // 3. POLICY gate (immutable typed decoder — MINIMAL by design; see Residual risks)
  require(_policyAllows(g.policyHash, it), PolicyDenied());    // targets + verbs + per-token cap presence
  // 4. GATES (pause writes NOTHING — resume + recurring intact)
  if (!_gatesPass(it)) { emit WorkflowPaused(iDigest); return; }
  // 5. RESERVE spend + counters BEFORE actions (CEI — the load-bearing fix, per token)
  _reserveSpend(gDigest, it);   // for each funded op: spentByToken[gDigest][tok]+=cost; require <= cap
  unchecked { s.executions += 1; }
  s.lastExecuted = uint40(block.timestamp);
  // 6. INTERACTIONS (controlled-callback frame, Addendum B) + RIDER-1 tip + msg.value conservation
  _runActions(it);
}

function revokeSession(SessionGrant calldata g) external {     // Tier 2
  require(msg.sender == g.root, NotOwner());
  sessions[_grantDigest(g, epoch[g.root])].revokedAt = uint40(block.timestamp);
}
```

**Why the spend cap must reserve before interactions (the second load-bearing
fix, flagged at Design-C selection):** `spentByToken += cost` is exactly the
`executions += 1` reserve, per token. If it ran *after* `_runActions`, a reentrant
action callee could re-enter `execute()` under the same session and blow past the
budget before the first run's spend is booked — a spend-cap that doesn't cap. It
reserves in the CEI block, inside `nonReentrant`, alongside the intent counters.

**Interaction with the multi-mode funding descriptor (Addendum B):** `cost` per op
is the exact pull amount from that op's funding descriptor, so spend accounting
reuses the funding path — no separate price oracle in the core. **Open for the
adversarial pass:** whether a controlled-callback flash sub-group's *internal*
pulls count against the session cap (they should net to zero, but the isolation
must be proven), and whether the RIDER-1 tip counts against the cap (proposal: it
does — the tip is a real outflow the session authorized).

**This delivers the Design C goals on top of the substrate:** delegated hot-key
signing (agents sign, not the root), per-token spend caps (a leaked session key
drains at most its remaining budget), three-tier revocation, and a provable policy
envelope — while keeping every substrate guarantee (per-intent replay protection,
resume, recurring, domain separation, cancel-ALL).

### Why resume + recurring still work

- **Resume:** the pause branch returns *before any SSTORE*, so a paused intent's record stays `{0, 0, false}`. `epoch/deadline/maxRuns/cooldown/salt/payload` are all fixed in the signed header, so re-submitting identical calldata reproduces the identical digest, re-enters the same non-terminal record, and only reserves `executions=1` on the completing (post-gate) run. Reserve-then-run never touches the pause path.
- **Recurring:** reusable intents sign `maxRuns=0` (unlimited) or `N` and never terminalize (the digest is stable across runs because the counters live in the record, not the digest). The on-chain condition inside `_gatesPass` is the primary re-execution guard; `cooldown > 0` closes the same-block window the condition alone leaves open.
- **ASP policy (encode off-chain, not on-chain):** open-ended condition-gated intents sign `deadline = type(uint64).max` (the existing year-2199 infinite sentinel) so a finite default cannot expire a slow-to-flip resume; schedules are expressed as pause-able gates in `_gatesPass`, not via `cooldown` (which reverts, not pauses).

### Alternatives considered

- **Design A — per-intent EIP-712 cursor, single signature (root signs each intent).** The substrate above, *without* the session layer. **Now the runner-up (was the original choice):** simpler and smaller audit surface, but it makes the root key sign every intent and offers no spend-cap envelope — so delegated agent operation means either handing the agent the root key (unbounded) or re-signing constantly (not autonomous). Chosen only if delegated agent-signing / spend-caps were *not* first-class; as of 2026-07-18 they are, so Design C is adopted and Design A survives as C's substrate. If the session layer proves too heavy at audit, falling back to Design A is a clean subtract (drop the grant + policy + spend-cap; keep the cursor).
- **Design B — Permit2/Seaport order-hash + unordered nonce bitmap.** Gives granular *and* batch (256-at-a-time) cancel. **Rejected for now:** batch-cancel-of-hundreds is not a current requirement, and the off-chain nonce/bit allocator adds a stateful failure mode (a colliding bit silently bricks a fresh intent and can break resume). Promote only if high-volume parallel issuance / mass-cancel becomes real. (Orthogonal to C — a bitmap could back C's per-intent cursor if mass-cancel ever matters.)
- **Naive "consume the nonce on execute".** **Rejected:** breaks PAUSE→resume (a paused first run would consume the nonce) and recurring (each run would consume it).

### Consequences

- **Backward-incompatible, immutable ⇒ fresh redeploy + client migration.** Signature format changes `personal_sign → signTypedData_v4`; old intents cannot be auto-re-signed. There is no in-place patch path, so even the "minimal viable" change is a redeploy.
- **Migration sequence:** (1) freeze hardened source; Foundry tests including a malicious-reentrant callee proving `maxRuns=1` reverts `Exhausted` on reentry and recurring reverts `Cooldown` same-block; deploy immutably on **both** chains, record addresses. (2) Encoder/MCP emit the EIP-712 struct + new fields and sign via `signTypedData_v4` with domain `{name:"W3Cash", version:"1", chainId, verifyingContract}`; expose per-intent + cancel-ALL. (3) ASP populates `maxRuns` (1 one-shot / 0|N recurring), `cooldown` (>0 for recurring), `deadline` (`uint64.max` for open-ended), and an **all-time-unique `salt`** per intent (uniqueness is an ASP invariant — a duplicate salt self-collides two identical intents onto one record). (4) `packages/registry/nodes.json`: add the two new processor addresses, bump `version`, redeploy `registry-api`. (5) Regenerate **all** golden vectors (per-chain: 84532 and 1952 produce distinct digests — that *is* the cross-chain-separation property under test) + negative vectors (expired / cancelled / exhausted / cooldown / wrong-chain). (6) Parallel-run new + old processors; ASP stops issuing to the old address; in-flight old intents drain or expire. No on-chain state migration is possible.
- **Minimal viable build (Design A substrate, still a redeploy):** one struct, one mapping, one EIP-712 domain, four `require`s, one `nonReentrant` modifier, two small functions — no change to the conditions/actions engine.
- **Design C delta (the session layer, on top):** two more structs (`SessionGrant`, `Policy`), two mappings (`sessions`, `spentByToken`), a two-signature `execute()` (root grant + session intent) with an ERC-1271 branch, the typed `_policyAllows` decoder, the per-token `_reserveSpend`, and `revokeSession`. Roughly doubles the core audit surface vs. A — the price of first-class delegated signing. Encoder/ASP gain session lifecycle (grant issuance, budget tracking, revocation), and golden vectors gain grant digests + policy/spend negative vectors.

### Residual risks

- **Immutable `_policyAllows` decoder (Design C, HIGH — hardened in Addendum C):** a bug voids the whole envelope on an unpatchable contract. Resolved via a minimal typed policy (fixed struct, no expression VM), a **total** pure decoder with capped array lengths, **op-kind branching** (GATE vs ACTION — Addendum C #1), an in-decoder `keccak256(policyBytes)==policyHash` bind, fail-closed empties, and adapter-declared verbs. See Addendum C amendments 1, 3, 10, 11 + the fail-closed hardenings.
- **Per-token spend reserve under reentrancy + balance-threading (Design C, HIGH — hardened in Addendum C):** `spentByToken += cost` reserves in the CEI block inside `nonReentrant`, **before every pull** (not once up-front), with `THREADED` funding validated against per-frame `frameReceived` and a mandated flash-frame isolation proof. Metering uses the **actual** root outflow delta (FoT-safe). See Addendum C amendments 4, 6 + the flash-frame proof.
- **Two-signature surface (Design C):** the grant is a bearer authority for the session key until expiry/revocation — a leaked *session* key is bounded by policy+cap+expiry (the point), but a leaked *root* key is total; the root grant should itself be short-lived / re-issued, and Tier-3 `incrementEpoch()` is the root-compromise backstop.
- **Paused-path griefing (low, funds-safe):** `execute()` is permissionless and the payload is public, so anyone can spam `execute()` on a not-yet-triggered intent to emit `WorkflowPaused` and burn oracle-read gas. Mitigate at the indexer/keeper, or add a `lastSeen` SSTORE on the pause path if judged worth the gas.
- **Salt-collision self-DoS (reliability):** a duplicate/buggy ASP salt maps a second identical intent (or grant) onto the first's terminal record → `Exhausted`. Mitigate with an ASP uniqueness guarantee + client pre-check.
- **`incrementEpoch()` also cancels paused/scheduled intents AND every live session** (intended but sharp) — surface in UI as "cancel-ALL also revokes all sessions + cancels pending/scheduled."
- **Fork replay** if the `_domainSeparator()` lazy-recompute is dropped — it is mandatory, not an optimization.
- **Immutability tax:** any shipped bug has no patch path but a full redeploy + client re-migration on both chains. Golden vectors are release gates.

### Open questions

- Is mass-cancel / high-volume parallel issuance a near-term need? (If yes → Design B's bitmap can back C's cursor.)
- ~~Are agent-spend-caps / delegated hot-key signing on the roadmap within this immutable deploy's life?~~ **RESOLVED 2026-07-18: yes → Design C adopted.**
- ~~Does a controlled-callback flash sub-group's internal funding count against the session spend cap? Does the RIDER-1 tip count against the cap?~~ **RESOLVED in Addendum C: balance-threaded flash pulls do NOT count (they draw only `frameReceived`, proven-isolated); the tip counts against a DEDICATED per-session sub-budget distinct from action caps (amendments 4, 8).**
- ~~Absolute-lifetime vs rolling-window spend cap~~ **RESOLVED (Addendum C Resolution 2): unified rolling-window `TokenCap` with `resetPeriod==0` = absolute lifetime cap (default), `resetPeriod>0` = rolling window for DCA/recurring.**
- Session-grant lifetime policy: how short should root grants be, and does the ASP auto-re-issue on expiry?
- On-chain minimum `cooldown` floor for recurring intents, or leave entirely to the ASP?
- Close paused-path event spam on-chain (`lastSeen` SSTORE) or accept + handle at the indexer?

_Source: multi-agent research + adversarial-review workflow, 2026-07-16 (AA/ERC-4337 nonces, ERC-7579 session keys, Seaport/0x/Permit2 order-hash + bitmap nonces, Gnosis Safe + EIP-712 domain separation, recurring-execution systems). Design A→C decision change 2026-07-18 (user: delegated agent-signing + spend-caps are first-class); the Design C spec above is a first-draft pending adversarial hardening before audit freeze._

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

**RIDER 2 — ERC-1271 smart-account roots.** If the **root** grantor has code,
verify the SessionGrant via `IERC1271.isValidSignature(hash, sig)` instead of
`ecrecover` — one fallback branch in `_verifyRoot`, plus compiler emission of the
712 struct a Safe UI can sign. Admits Safe / Kernel / Nexus / DAO treasuries as
session grantors, which are entirely locked out today. *(Updated 2026-07-18: under
Design C this is the natural on-ramp — a smart-account root grants a scoped,
spend-capped session to a hot agent key. The session key itself is a plain EOA
verified by `ecrecover`; only the root grant takes the 1271 branch.)*

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
- k-of-N runtime quorum, generic call-anything adapter — still rejected.
- ~~Session keys / policy modules (Design C)~~ **now RIDE the redeploy as the base
  Decision (changed 2026-07-18) — the session-key + spend-cap + typed-policy layer
  is the authorization core, unfixable if omitted.**

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

> **0. Session-key authorization core (base ADR-0001, Design C — added 2026-07-18).**
> The `SessionGrant` + typed `Policy` + per-token spend-cap + three-tier revocation
> layer is now part of the base Decision, not this addendum — but it is the largest
> unfixable-if-omitted core primitive, so it is called out here for audit scoping.
> It **composes with** the funding descriptor below: each op's spend `cost` is its
> funding-descriptor pull amount, so `spentByToken` accounting reuses the funding
> path (no separate price oracle in core). The controlled-callback flash frame (#2)
> must be proven to keep a sub-group's internal pulls net-zero against the session
> cap. See ADR-0001 base for the full spec + the two flagged sharp edges.

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

---

## ADR-0001 — Addendum C: Design C adversarial hardening (pre-audit fix list)

- **Status:** Accepted (design) — the frozen fix list the Design C spec must carry **into** the audit. Supersedes the "first-draft" caveat on the base Design C decision.
- **Date:** 2026-07-18
- **Verdict:** **PROCEED TO AUDIT after amendments 1–11 — not a rethink.** The authorization core (per-intent EIP-712 cursor, session-grant delegation, three-tier revocation, execution-chain domain binding, reserve-then-run CEI, persistent-only `spentByToken`) **survived all five adversarial lenses** — the signature/replay/domain lens found no working forgery. The defects are localized and fixable within the current architecture. Two are genuine `breaksDesign` that MUST land before freeze (op-kind classification; native pause-path refund); one is a critical **adapter** hole (FlashLoanAdapter). The two mandated pre-freeze items are now **decided** (see Resolutions below): flash-frame isolation = source-keyed exemption + transient nesting-counter frame (carries a formal-proof audit deliverable), and the cap = a unified rolling-window with `resetPeriod==0` = absolute. With amendments 1–11 applied and the flash-frame proof closed at audit, Design C is audit-ready.

### The load-bearing correction the panel found (would have bricked the product)

The base Design C `_policyAllows` implicitly treated **every** op as a fundable
ACTION. But the flagship "do X only when Y" intent carries its condition as a
**QueryAdapter GATE op in the same signed ops array** as the actions, and
QueryAdapter is a read-only condition adapter — **not** an action. A uniform
`require(_isActionKind(op.target))` would revert **every gated intent** (both the
pause and the run case), making PAUSE→resume + recurring structurally unreachable
— an **unpatchable brick of the core product** on an immutable deploy. Amendment 1
fixes it; it is the single most important change.

### Amendments (normative — fold into the Design C spec before freeze)

**CRITICAL**

1. **Op-kind classification.** Add an `Op.kind` discriminator (`GATE | ACTION`).
   `_policyAllows` branches: GATE ops must be in a gate-allowlist, must assert
   `!_movesFunds(op)`, and take **no** TokenCap; ACTION ops require action-kind +
   capped funding. On-chain shape check: every GATE index is strictly below every
   fund-moving index (single monotonic boundary); `_gatesPass` iterates
   `[0,boundary)`, `_runActions` iterates `[boundary,len)`. Golden vectors: a
   `[gate,action]` intent passes policy, PAUSES with zero writes when false, RUNS
   when true; a fund-moving op before a gate op reverts at the shape check.
2. **FlashLoanAdapter is excluded until rewritten.** The **shipped**
   FlashLoanAdapter contains a live `target.call(callData)` (runs attacker calldata
   as the adapter) and repays the **full principal** via `transferFrom(root,…)`
   (falsely exhausts the cap AND drains root when sub-ops leave no proceeds). It
   MUST NOT declare `KIND_ACTION` and MUST be excluded from every session allowlist
   until rewritten to run policy-checked processor ops inside the controlled-callback
   frame and repay via balance-threading (never a root pull).

**HIGH**

3. **SOLE-MOVER by codehash, not self-declaration.** The whole cap system rests on
   "the processor is the only puller of root funds." A self-declared `adapterKind()`
   cannot reject a dishonest adapter that returns `KIND_ACTION` while keeping a root
   pull. Pin allowlist membership by **`EXTCODEHASH(op.target)`** against a
   root-signed set of vetted-bytecode hashes (RIDER-4 CREATE2 addresses still
   verify); keep the `adapterKind()` staticcall as fail-closed belt-and-suspenders
   against *misconfiguration* only. **REWRITE the fleet** (TransferAdapter et al.
   currently pull `transferFrom(initiator,…)` — the v1 root-approves-adapters model)
   to be processor-fed via balance-threading; re-collect approvals to the processor
   only, on redeploy.
4. **Flash frame = explicit transient nesting counter, reserve-before-every-pull.**
   Specify the "admits exactly ONE sub-group" property as a transient
   `depth`+`flashSlotConsumed` state machine, not a boolean; every external entry
   reverts unless it matches the exact expected transition. **Reserve each
   root-sourced pull against its cap immediately before that pull** (not once
   up-front), even inside a sub-op. A `THREADED` op is valid only inside an open
   frame with `frameReceived[token] >= pull` (decrement atomically); no frame →
   hard revert. Balance-threading draws only from `frameReceived`, never
   `token.balanceOf(processor)`. Mandate a fuzz/formal proof: no admitted path
   reaches an unreserved root pull; `frameReceived`/`flashSlotConsumed` zero on all
   three exit paths (normal/pause/revert).
5. **Native-ETH model (fixes permanently-stuck ETH).** `msg.value` is
   executor-supplied (execute is permissionless): treat it as pass-through, do NOT
   meter it against root's `caps[address(0)]`, refund excess/residual to
   `msg.sender` (not root), and **refund `msg.value` to `msg.sender` on the PAUSE
   branch** before returning. Preferred: forbid native `msg.value` at entry and
   source native only via a threaded WETH-unwrap op inside the frame, so the pause
   path never holds caller ETH.

**MEDIUM**

6. **Actual-delta metering for FoT/rebasing.** Reserve a conservative upper bound
   pre-pull, then meter the **real** root outflow (`balanceBefore−balanceAfter`) and
   reconcile `spentByToken` post-pull inside `nonReentrant`; on over-delivery revert
   or reserve the actual delta — never let surplus enter `frameReceived` uncounted.
   Deny/clamp rebasing tokens from caps.
7. **Recurring cap exhaustion is observable + window decision.** Emit
   `CapExhausted(iDigest, token)` (or degrade to `WorkflowPaused`) so keepers stop
   polling a dead intent instead of seeing an indistinguishable revert. **DECIDED
   (Resolution 2 below):** a unified rolling-window `TokenCap{cap, resetPeriod}` +
   persistent `{spent, lastReset}` cursor — `resetPeriod==0` = absolute lifetime cap
   (emits `CapExhausted`), `resetPeriod>0` = rolling window for DCA/recurring (pauses
   until reset). ASP short-grant re-issue stays as defense-in-depth.
8. **Keeper tip = dedicated sub-budget.** Give the tip its own per-session budget
   distinct from action caps (action spend must not starve a protective intent's
   tip); require `tipToken != actionToken` for the protective default; clamp-and-
   meter (emit `TipSkipped(NO_ROOM)`, never revert); fix the `_payTipMetered` scope
   bug (needs `g.root`); document open-bounty tips as **stealable bearer MEV** (a
   front-runner can copy the public payload) — size accordingly.
9. **Bind `epoch` into the intent digest.** Add `uint256 epoch` to
   `INTENT_TYPEHASH` and require `== epoch[g.root]` at execute, so an epoch bump
   kills the intent digest directly (not only transitively via `it.session`).
   Freeze an invariant test that `gDigest` is NEVER read from storage. Mandate a
   ≥128-bit CSPRNG `salt` + ASP uniqueness across live **and** revoked grants
   (a recomputed `gDigest` shares its `spentByToken` cursor / inherits revocation).

**LOW**

10. **Decide ERC-7739 for the ERC-1271 root branch now.** Either adopt ERC-7739
    nested-712 (root always signs nested under W3Cash's domain — defeats cross-
    context replay of a naive-1271 account) or normatively require 7739-compliant
    roots and ship a release-gate vector showing a raw-hash 1271 mock is
    (intentionally) accepted. `staticcall` the 1271 branch; exact `0x1626ba7e`
    match. Document that an EIP-7702 delegation flip invalidates outstanding grants.
11. **Native cap check in `_policyAllows`** as a first-class early check
    (`if (op.value != 0) require(_capIndex(p, address(0)) != NONE)`), matching the
    fail-closed ERC20 path — a tidy-up so all checks live in the decoder.

Also fold in the smaller fail-closed hardenings the research surfaced: **empty
`allowedTargets` = DENY ALL** (require an explicit wildcard sentinel for "any
adapter"); **`verbMask == 0` = deny all**; **derive the verb from the pinned
adapter's declared type, not from op bytes**; **cap array lengths** (`allowedTargets
≤ 16`, `caps ≤ 16`) and reject duplicate-token cap entries; **hash-check the full
Policy bytes inside `_policyAllows`** (`require(keccak256(policyBytes)==g.policyHash)`
as the first line — the Policy is executor-supplied and must never be trusted
unbound).

### Residual risks (accepted, recorded)

- **Containment is amount-only, not destination-based.** The cap bounds *how much*
  of a token leaves, not *where*; a leaked session key can send capped funds to an
  attacker up to `caps[token]`. Accepted — mitigated by tight caps + short grants.
  Revisit a per-adapter typed recipient-allowlist (e.g. TransferAdapter) if needed.
- **Caps are per-session-key, not per-root.** N grants × cap C = N·C aggregate; the
  true global backstop is the single root→processor standing allowance / Permit2
  authorization + Tier-3 `incrementEpoch`, not the sum of caps. A `spentByRoot`
  ceiling is deliberately NOT added (cross-session coupling + shared-counter
  griefing on an immutable contract) unless mass-delegation becomes a product.
- **EIP-7702 root delegation flips** invalidate outstanding grants (self-inflicted
  liveness edge, not an external forge) — SDK warns at issuance; re-issue required.
- **Paused-path spam** stays accepted (indexer-handled, pause path write-free);
  indexers must treat `WorkflowPaused` as unauthenticated.
- **Immutability tax:** no patch path — frozen golden + negative vectors per chain
  are the release gates.

### Resolutions to the two mandated pre-freeze items (decided 2026-07-18, best practice)

Both were the two highest-audit-risk items. Both are now **decided**; the flash-frame
one additionally carries a formal-proof obligation as an audit deliverable (a spec
decision cannot substitute for the proof, but it freezes exactly what the proof targets).

**Resolution 1 — Flash-frame isolation: SOURCE-keyed exemption + transient
nesting-counter frame.** The exemption keys on **funding source, never frame
position** (a frame-keyed rule lets a `transferFrom(root,attacker)` op smuggled
into the flash sub-group escape the cap — the panel's critical finding):

- **Root-sourced pulls always count** against the cap (Permit2 mode-a + standing
  allowance mode-b), in or out of the flash frame. **Balance-threaded pulls
  (mode-c) never count** — but ONLY because they draw exclusively from a per-execute
  **transient (EIP-1153) `frameReceived[token]` ledger**, credited only as funds
  actually arrive THIS frame (flash principal from the pool; swap/unwrap outputs),
  written through a single funnel. Every threaded pull asserts
  `frameReceived[token] >= pull` and decrements atomically; a THREADED op with no
  open frame or insufficient `frameReceived` **hard-reverts**. Threading NEVER reads
  raw `balanceOf` — this closes cross-intent balance confusion (a prior intent's
  residual or an attacker donation is never threadable).
- **Frame = transient nesting counter, not a boolean:** `depth` (0→1 on execute;
  1→2 for the single admitted flash sub-group) + single-use `flashSlotConsumed`.
  Every external re-entry (execute, flash continuation, op-dispatch) reverts unless
  it matches the exact expected `(depth, slot)` transition.
- **Reserve-before-every-pull:** each root-sourced pull reserves against its cap
  immediately before that pull, even inside a sub-op — a re-entrant sub-op that
  reaches a root pull still hits `spent += cost; require(<= cap)`.
- **`spentByToken` stays PERSISTENT, never mirrored in transient.** `_exitFrame()`
  zeroes every `frameReceived` slot on normal AND pause exit; a full-tx revert
  clears transient at tx-end (SIR.trading $355k lesson — zero on all three paths).
- **Net-zero property** (the isolation the cap relies on): borrowed principal enters
  `frameReceived` from the pool (uncounted, not root) → disbursed + repaid via
  threading (uncounted) → only the **premium + any genuine principal shortfall** is
  root-sourced and counted. A flash of X under cap C<X **succeeds**, debiting only
  the premium.
- **Proof obligation (release gate, audit deliverable):** fuzz/formal proof that
  (i) threading never reads `balanceOf`; (ii) `frameReceived`+`flashSlotConsumed`
  zero on all three exits; (iii) no admitted path reaches an unreserved root pull.
  Golden vectors: two `execute()` in one tx assert no phantom carry-over; flash X
  under cap C<X debits only the premium; a malicious in-frame router re-entry cannot
  exceed the reserved total.

**Resolution 2 — Cap shape: ADOPT the unified rolling-window;
`resetPeriod == 0` = absolute.** `TokenCap` gains `uint40 resetPeriod`; the
persistent per-(session,token) cursor is `{uint128 spent, uint40 lastReset}`. In the
CEI reserve block, BEFORE booking: `if (resetPeriod != 0 && block.timestamp >=
lastReset + resetPeriod) { spent = 0; lastReset = block.timestamp; }` then
`spent += cost; require(spent <= cap)`.

- `resetPeriod == 0` ⇒ **absolute lifetime cap** — the conservative default for
  one-shot + protective intents (keep the `CapExhausted(iDigest, token)` event of
  amendment 7 so keepers stop polling a dead intent).
- `resetPeriod > 0` ⇒ **rolling window** ("X per period forever") — the natural,
  and only expressible, budget for DCA/recurring; on exhaustion the intent **pauses
  until the next reset** (observable via the window) rather than dying.
- **Why adopt, not defer to short-lived grants:** (1) it is the only way to express
  recurring-with-a-bounded-budget, a core product; (2) for a *long-lived autonomous
  agent session* it is a **security improvement, not just UX** — it bounds a leaked
  session key's **per-period** blast radius, whereas a large absolute cap lets a
  leaked key drain the whole remaining lifetime budget in one burst (parallel intents
  defeat cooldown pacing); (3) it is a small (one field + a persistent cursor +
  ~4 lines), audited pattern (Gnosis Safe AllowanceModule); (4) it is **unaddable to
  an immutable contract later** — deferring forecloses the class forever.
- **Accepted inherent property (documented):** a rolling window admits up to `2×cap`
  across a single reset boundary (spend `cap` just before, `cap` just after) — true
  of every rolling window (Safe included), bounded and acceptable; the absolute case
  (`resetPeriod == 0`) has no boundary. **Floor `resetPeriod`** to the recurring-
  cooldown floor so it can't be set to per-block (which would defeat the cap).
- The "prefer many short-lived grants, ASP auto-re-issue" guidance stays as
  **defense-in-depth**, not the sole rate-limiter.

_(These resolve Addendum C amendments 4 and 7 respectively; folded into the base
Design C storage. Source: the same 2026-07-18 hardening workflow — the source-keyed
rule and the Safe-AllowanceModule rolling-window shape were the panel's converged
best-practice recommendations.)_

### Implementation status (skeleton for review)

A compiling **skeleton** implementing this Decision + all Addendum C amendments is
in the repo for review + audit scoping (NOT deployable):
`packages/contracts/src/w3cash/W3CashProcessorV2.sol` (+ `test/W3CashProcessorV2.t.sol`,
9 passing smoke tests). It encodes every frozen decision with correct ordering —
two-signature delegation, hash-bound typed `Policy`, GATE/ACTION op-kind boundary,
rolling-window SOURCE-keyed spend reserve (reserve-before-every-pull, CEI), transient
flash frame with zero-on-every-exit, three revocation tiers, ERC-1271 root, native
pause-refund, clamp-and-meter tip. Points depending on not-yet-frozen integration
(Permit2 exact call, adapter funding mechanics, flash-pool wiring, delta reconciliation)
are marked `NOTE(freeze):`. The mandated flash-frame formal proof + the fleet rewrite
(SOLE-MOVER / codehash-pin / FlashLoanAdapter) remain before audit.

_Source: multi-agent adversarial-hardening workflow, 2026-07-18 (5-angle prior-art
+ attack-surface research [ERC-7579/4337/6900, Smart Sessions, Kernel, Nexus,
Safe modules; spend-limit exploits; two-sig delegation; immutable-decoder totality;
composition] → hardened-design synthesis → 5-lens adversarial critique panel
[reentrancy/CEI, signature/replay/domain, policy-decoder, economic/griefing,
invariant-preservation] → synthesis. 12 agents, 0 errors. Ground-truth read against
`W3CashProcessor.sol`, `QueryAdapter.sol`, the shipped adapter fleet.)_
