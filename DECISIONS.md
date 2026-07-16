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
