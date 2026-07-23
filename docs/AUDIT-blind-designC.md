## W3CashProcessor — Final Adversarial Audit Report

**Scope:** `W3CashProcessor.sol`, `adapters/PostConditionAdapter.sol`, `adapters/OracleReadAdapter.sol`
**Model:** immutable, permissionless, non-custodial. No patch path, no admin rescue.
**Attacker:** any relayer (msg.sender of `execute`), own-root intent author, deployer of malicious tokens/adapters/pools, holder of a leaked session key.

### Summary

| # | Severity | Title | Status | New / Known |
|---|----------|-------|--------|-------------|
| 1 | High | Flash callback credits attacker-supplied `amount` to the frame ledger without measuring receipt → drains processor-resident ERC20 | Confirmed | New |
| 2 | Low | ERC20 frame residue is never swept at end-of-execute (only native is) → permanent stranding | Confirmed | New |
| 3 | Low | Adapter-returned native sourced from caller `op.value` is credited to frame and swept to root, not refunded to keeper | Confirmed | New |
| 4 | Low | Native returned/retained by an op with `outToken != NATIVE` is untracked → stranded ETH | Confirmed | New |
| 5 | Low | THREADED action with `fundToken==NATIVE` zeroes the native ledger without forwarding → stranded ETH | Confirmed | New |
| 6 | Low | PERMIT2 funding mode is permanently unconstructible (witness = `iDigest` depends on `opsHash` which includes the Permit2 sig — circular fixed point) | Confirmed | New |
| 7 | Low (uncertain) | `verb()` re-read at dispatch is independent of the check-time read → `flashCodehashes` allowlist not constancy-pinned | Uncertain-but-fix | New |
| 8 | Informational | Leaked session key can permanently cancel its grant's intents (dual-auth cancel + one-way latch) | Confirmed | New |
| 9 | Informational | Native `TokenCap` (`token==address(0)`) is dead configuration — enforces nothing | Confirmed | New |
| 10 | Informational | OracleReadAdapter Pyth readers discard the price exponent; `pythPrice` has no staleness check | Confirmed | New |
| 11 | Informational | `chainlinkPriceScaled` silently truncates to zero on down-scaling (violates the adapter's stated fail-closed philosophy) | Confirmed | New |

None of the confirmed findings appear on the KNOWN accepted/deferred list; all are New. The two prior MEDIUMs (M1 shared-cursor tip, M2 tolerant tip decode) remain correctly Fixed and were re-challenged and upheld (see Refuted list).

---

### Finding 1 (High) — Flash callback credits unmeasured principal

**Mechanism.** `onFlashLoan` does `_frameCredit(asset, amount)` trusting the caller-supplied `amount` with **no `balanceOf`-delta check** — uniquely among funds-in paths (`_pullRoot` measures the delta; `_feedAndRun` measures `outAfter-outBefore`). Flash ops bypass `_reserveAndFund`/`_reserveCap` entirely, so `amount` is unbounded and uncapped. `_checkPolicyAndShape`'s flash branch only requires `verbMask&VERB_FLASH`, `op.target` codehash in the attacker's own `flashCodehashes`, `funding==NONE`, `value==0` — all attacker-satisfiable when the attacker is their own root. A malicious flash adapter (whose codehash the attacker pinned in their own policy) forwards **zero** tokens and calls back `onFlashLoan(asset, amount, 0, cb)` with attacker-consistent `cb`/`cbAsset`/`cbAmount`; every guard passes; the phantom `amount` is credited. With empty sub-ops and `premium=0`, `repay==amount==avail`, so the shortfall check passes and the processor `safeTransfer`s `amount` of its **physically-held** balance to the attacker as "repayment" for a loan never funded.

**Impact.** Permissionless theft of any ERC20 the processor physically holds. That set is real and continuously replenished: the end-of-execute sweep is NATIVE-only (Finding 2), so measured swap/unwrap output not fully drawn by THREADED ops is stranded in the processor on every such intent, plus FoT/donations/airdrops. Bounded to processor-resident balances (cannot directly drain live user wallets, which still require the user's own permit/signature) — hence high, not critical.

**Repro.** Processor holds `S>0` of token `T`. Attacker (own EOA = root): deploy `MaliciousFlashAdapter` (`verb()==VERB_FLASH`; `initiateFlash` forwards nothing and immediately calls `processor.onFlashLoan(T, S, 0, cb)`). Policy pins its codehash in `flashCodehashes`, `verbMask=VERB_FLASH`. One ACTION op, `funding=NONE`, `value=0`, data encodes `(T, S, "", abi.encode(new Op   )`. `execute()` → `_runFlashOp` pins adapter → `initiateFlash` → `onFlashLoan(T,S,0)` sends nothing → guards pass → `_frameCredit(T,S)` phantom → `repay=S=avail` → `safeTransfer(adapter, S)`. Repeat to sweep every ERC20.

**Fix.** Measure the actually-received principal. The adapter forwards principal to the processor **before** calling `onFlashLoan`, so snapshot at dispatch and credit the delta: in `_runFlashOp` before `initiateFlash`, `_tstore(_T_FLASH_PREBAL, IERC20(asset).balanceOf(address(this)))`; in `onFlashLoan` replace `_frameCredit(asset, amount)` with `received = balanceOf(this) - _tload(_T_FLASH_PREBAL); _frameCredit(asset, received);` and zero `_T_FLASH_PREBAL` in `_exitFrame`. A phantom callback then credits 0 → `repay > avail` → `RepayShortfall` reverts, and the pre-existing resting balance is never drawn. Independently fix the ERC20 no-sweep (Finding 2) to remove the replenishing supply of drainable balances.

---

### Finding 2 (Low) — ERC20 frame residue never swept

**Mechanism.** `execute()`'s cleanup sweeps two NATIVE buckets only (unused caller ETH → msg.sender; leftover frame native → root). There is no ERC20 counterpart; `_exitFrame` only tstore-zeroes each touched frame slot, moving zero physical tokens. Any ERC20 credited to the frame ledger (measured `outToken` delta, or flash-arb profit) that a downstream THREADED op does not fully draw stays physically in the processor while its ledger entry is wiped. It is unreachable by later intents (frame slots start at 0 → `InsufficientFrameBalance`; `_pullRoot`/`outToken` use deltas so residue is invisible) and there is no rescue function → permanently lost.

**Repro.** Intent: op A swaps USDC→WETH (credits ~0.401 WETH); op B is a THREADED transfer of a **fixed** 0.40 WETH (not the draw-all sentinel). 0.001 WETH remains in the ledger; cleanup ignores it; `_exitFrame` zeroes the slot. The 0.001 WETH is stranded forever. Same for undrawn flash-arb profit.

**Fix.** Before `_exitFrame` zeroes the ledger, iterate the `_T_TOUCH` list; for each `tok != NATIVE` with `b=_frameGet(tok)>0`, `_frameSet(tok,0)` and `IERC20(tok).safeTransfer(root, b)` — mirroring the native frame→root sweep. (Cheaper alternative: require every touched ERC20 frame balance == 0 and revert otherwise; but sweeping to root is strictly safer for an immutable contract.)

---

### Finding 3 (Low) — Caller-origin native mis-attributed to root

**Mechanism.** `callerNative` starts at `msg.value`; `_drawNative` deducts `op.value` from `callerNative` first, so `op.value` can be fully caller-origin. When `op.outToken==NATIVE`, `_feedAndRun` reconstructs `balAfter = balance + op.value` and credits the whole positive delta to the NATIVE frame ledger, which is unconditionally swept to `root`; only the *undrawn* caller remainder returns to msg.sender. Adapter-returned native is thus merged with root's the instant an adapter returns native with `outToken==NATIVE`. Root controls the codehash-pinned policy, so the sink adapter is root-constructible. Loss is the relayer's own fronted ETH.

**Why low.** Requires a keeper to voluntarily front `msg.value >= op.value` (else `InsufficientNative` reverts); the loss is self-inflicted and revealed by the pre-submission simulation every rational keeper runs; unprofitable for a rational root against a rational keeper (any tip large enough to lure execution offsets the stolen native). Realistic victim: a naive/non-simulating auto-keeper.

**Fix.** Thread caller-origin native accounting through `_feedAndRun`: in the `outToken==NATIVE` branch, apply the measured native delta FIRST to replenish the caller's drawn amount (refunded to msg.sender), crediting only the EXCESS to root's frame. Simpler for an immutable contract: forbid the conflation — source `op.value` native only from frame (remove the caller-first draw in `_drawNative`), or reject `outToken==NATIVE` on any op whose `op.value` was caller-funded.

---

### Finding 4 (Low) — Native retained/returned by non-native-output op is stranded

**Mechanism.** A non-flash ACTION may carry `op.value != 0` with any `outToken` (`op.value` is only restricted for flash ops). `_feedAndRun` snapshots/credits native **only** on the `outToken==NATIVE` branch. When `outToken` is an ERC20 (or `address(0)`), any native the adapter refunds — or a payable adapter retains — is never credited, never swept, and unrecoverable (later `outBefore` already includes it; no withdraw). The `PostConditionAdapter` sub-case is real: its `run()` is payable but never spends/forwards/refunds value, so a `VERB_ASSERT` op with `value!=0` black-holes it.

**Repro (honest loss).** Native→USDC exact-output swap: `op1 value=5e18`, `outToken=USDC`. Adapter consumes 3 ETH, returns USDC + 2 ETH refund. `_feedAndRun` credits only the USDC delta; the 2 ETH refund is on no native branch → uncredited → stranded.

**Fix.** ALWAYS snapshot native around `run()` independent of `outToken`: `nativeBefore = balance` before; `nativeAfter = balance + op.value` after; credit any positive delta to the NATIVE frame ledger, then handle the ERC20 output register separately. Belt-and-suspenders: reject `op.value != 0` on `VERB_ASSERT` ops (an assert never needs forwarded native, and the adapter cannot return it).

---

### Finding 5 (Low) — THREADED `fundToken==NATIVE` decrements ledger without forwarding

**Mechanism.** `_checkPolicyAndShape` constrains `fundToken` only for PERMIT2/STANDING and NONE-with-fundToken; `THREADED` matches neither, so `funding==THREADED, fundToken==NATIVE` passes shape validation uncapped. `_reserveAndFund`'s THREADED branch reads `avail=_frameGet(NATIVE)`, computes `draw`, and `_frameSet(NATIVE, avail-draw)` — decrementing the ledger. `_feedAndRun`'s transfer guard (`fundToken != 0 && != NATIVE`) is false for NATIVE, so nothing is transferred and `run{value: op.value=0}` forwards nothing. Net: `draw` is subtracted from the ledger but no ETH leaves; the end-sweep reads the reduced ledger and shorts root by `draw`, which sits untracked and unrecoverable.

**Why low.** Gated behind a leaked session key + a permissive policy that first produces frame-native from a cap-metered WETH pull then unwraps; per-intent loss bounded by that token cap. Malice-only (a legitimate integrator forwards native via `op.value`, never `fundToken==NATIVE` THREADED), but it erodes the cap model's damage bound for a leaked key.

**Fix.** In the non-flash ACTION branch add `else if (op.funding == FundingMode.THREADED) { if (op.fundToken == NATIVE || op.fundToken == address(0)) revert PolicyDenied(); }`. Defense-in-depth: also revert in the `_reserveAndFund` THREADED branch when `fundToken == NATIVE`, so the decrement-without-transfer state is unreachable.

---

### Finding 6 (Low) — PERMIT2 mode permanently unconstructible

**Mechanism.** In `_permit2Pull` the SignatureTransfer witness is `iDigest`, and the sig is decoded only from `op.fundingParams`. `iDigest = _intentDigest(it)` hashes `it.opsHash`, and `execute` enforces `it.opsHash == keccak256(abi.encode(ops))`. Since `op.fundingParams` is a struct field of the hashed `ops`, and it contains the Permit2 sig, we have `sig = Sign(root, H(iDigest(sig)))` — a keccak/ECDSA preimage fixed point that is computationally infeasible. Placing the real sig in the ops makes its signed message unknowable until after the sig is fixed (circular); hashing with empty `fundingParams` then filling the sig reverts `OpsMismatch` (or empty `abi.decode` reverts). No alternate sig channel exists (`rootSig`/`sessionSig` verify grant/intent digests, not Permit2). The mode is dead forever on an immutable contract.

**Why low / worth fixing.** Not a fund-theft vector — no attacker moves funds through it; the STANDING fallback remains cap-bounded. But it is a permanent liveness/dead-feature defect that forces standing allowances for one-shot protective intents, and is unfixable post-deploy. Not the KNOWN deferred item (that is about witness *typestring* correctness — a different concern).

**Fix.** Decouple the Permit2 signature from `opsHash`: pass `bytes[] fundingSigs` as a separate `execute()` calldata argument (indexed to funded ops), keep only `(nonce, deadline)` in `op.fundingParams`, and read the sig from `fundingSigs` in `_permit2Pull`. `fundingSigs` is excluded from `keccak256(abi.encode(ops))`, breaking the cycle while the witness still binds the pull to this intent. Alternative: compute `opsHash` over a canonical form with the funding-signature bytes masked. Gate release on a construct-and-execute fork test against a real deployed Permit2.

---

### Finding 7 (Low, Uncertain-but-fix) — `flashCodehashes` allowlist not constancy-pinned

**Mechanism.** `_checkPolicyAndShape` reads `_adapterVerb(op.target)` at check time and, when `VERB_FLASH` is clear, validates the op only against `allowedCodehashes`+KIND_ACTION — never touching the `flashCodehashes` gate. `execute()` then re-reads `_adapterVerb(op.target)` fresh to route into `_runFlashOp`, which itself never re-checks `flashCodehashes`. An adapter that reads `VERB_TRANSFER` at check and `VERB_FLASH` at dispatch reaches the flash-initiator path having passed only the ACTION allowlist, with the `funding==NONE`/`value==0` flash restrictions never applied — a genuine bypass of a documented security boundary.

**Why uncertain / low.** `verb()` is `view` (every read is a staticcall; no self-mutation). The value can only differ if an earlier approved op's `run()` flips op_X's state intra-transaction, which requires op_X's code to be in the **root-signed** `allowedCodehashes` (attacker cannot add codehashes), op_X to be a real `IFlashAdapter` with a non-constant `verb()`, plus a second approved adapter that flips it. That chimera means the root already whitelisted a pathological adapter — a trust-boundary violation on its own. Real fund loss additionally rides on Finding 1. Hence a valid constancy/defense-in-depth gap, not an attacker-triggerable theft against a careful root.

**Fix.** Pin the routing decision to a single authoritative read: compute the verb once in the shape pass and thread a per-op `flashRouted[]` bit into `execute()` instead of re-reading `_adapterVerb`. Additionally re-assert at the top of `_runFlashOp`: `if (!_codehashIn(policy.flashCodehashes, op.target)) revert PolicyDenied();` and re-check `op.funding==NONE && op.value==0`. Given immutability, apply both.

---

### Finding 8 (Informational) — Leaked session key can permanently cancel intents

`cancelIntent` authorizes `msg.sender == g.root || g.sessionKey`; `IntentState.cancelled` is a one-way latch (written true only in `cancelIntent`, checked in `execute`, no un-cancel path). A leaked session key can permanently disable any intent under its own grant. Strictly inside the already-accepted leaked-key boundary and strictly dominated by the key's spend capability (cancellation moves no money); intentional, documented design. The only novel angle is **stealth**: a cancel-only compromise produces no balance-change signal, so a protective intent (e.g. stop-loss) can be silently disarmed. Optional hardening: restrict cancel to `msg.sender == g.root` (root already holds `revokeSession`/`incrementEpoch`), removing the stealthy griefing vector while preserving keeper ergonomics via epoch rotation. Not a mustFix.

### Finding 9 (Informational) — Native `TokenCap` is dead config

The `TokenCap` comment advertises `token==address(0)` as a native cap, but no path meters native against it (`_reserveCap` is guarded off for `address(0)`/NATIVE; THREADED/NONE return early; native tips short-circuit; `op.value` native is explicitly unmetered). No fund risk (root native is unpullable by construction), but a policy author could believe native is bounded when it is not. Fix: in `_assertCaps`, `if (p.caps[i].token == address(0) || == NATIVE) revert PolicyDenied();` and delete the misleading comment line. Not a mustFix.

### Finding 10 (Informational) — Pyth reader discards expo / no staleness

`pythPrice`/`pythFreshPrice` return the raw mantissa `uint64(p.price)`, never reading `int32 expo`; `pythPrice` also omits `_requireValidTime`, making it strictly weaker than `chainlinkPrice`. A view-only gate helper (moves no funds); consistent with the adapter's native-scale contract and documented unsafe/fresh split. Impact is an author-mis-encoded or mis-timed protective gate against a feed the author chose. Fix: prefer an expo-aware, freshness-bounded reader (`pythPriceScaled(pyth, id, targetDecimals, maxAge)`); at minimum have `pythPrice` call `_requireValidTime(p.publishTime)`; ideally the SDK never emits the raw-mantissa reader. Not a mustFix.

### Finding 11 (Informational) — `chainlinkPriceScaled` truncates to zero

On down-scaling (`targetDecimals < feedDecimals`) the function guards only the exponent magnitude (`down > 77`) and returns `price / 10**down` with no zero/underflow check. For sub-1.0-unit feed values with coarse `targetDecimals`, the result floors to 0 with no revert — contradicting the adapter's own documented fail-closed philosophy ("no numeric sentinel is safe under both `<=` and `>=`"). Author-triggered (attacker cannot force `targetDecimals`), view-only, wrong-gate impact. Fix: after the quotient, `if (r == 0 && price != 0) revert ScaleUnderflow();`, surfacing as `QueryFailed()` (gate treated as not-met) rather than a silent 0. Not a mustFix.

---

### Refuted / Non-issues

- **Keeper-tip tolerant success check mis-accounts shared cap** — Refuted. Cursor is per-root-grant (`spentByToken[gDigest]`, `gDigest` binds `g.root`); tip/token both root-signed per intent; empty-return "success by convention" and return-false→refund are correct ERC20 handling. This is the accepted M2 fix. No cross-user harm.
- **SOLE-MOVER interface gate lets legacy pull-adapters drain caps** — Refuted. Shipped legacy adapters (Transfer/Approve/Wrap/Unwrap) implement only the legacy ABI; `_adapterVerb` reverts→catch→0→`PolicyDenied`; `_adapterKind != KIND_ACTION` also reverts. Gate fails closed; no conforming shipped adapter pulls root funds. Draining would require root to both pin a hostile codehash (root-signed policy) and self-approve it — self-sabotage outside the attacker model.
- **Flash-initiator skips `_adapterKind()==KIND_ACTION`** — Refuted. Asymmetry is real but non-exploitable: `flashCodehashes` is inside the root-signed `policyHash`; `_adapterKind` is self-declared (worthless vs malice); flash op moves no root funds (`funding==NONE`/`value==0` enforced); every fund-touching sub-op is re-checked `KIND_ACTION` in `_checkSubGroup`. Optional symmetry nit only.
- **Codehash pin binds bytecode not storage (stateful clone)** — Refuted. Both shipped adapters are stateless. SOLE-MOVER containment: root funds move only via the processor (`_pullRoot`/`_permit2Pull` with `to: this`, processor as sole spender); an adapter has no allowance; a clone's max reach is the cap-metered `fed` it is legitimately pushed. Forward-looking adapter-authoring rule, not a code defect.
- **Fee-on-transfer fundToken cap mis-charge** — Refuted. `_pullRoot` measures `received = balAfter-balBefore` (FoT-safe); standard FoT debits root exactly `fundAmount` (cap charge == real outflow). The only overshoot is exotic "fee-on-top" tokens the root itself capped and selected; no attacker-controlled steering; the excess is the token's own fee, not theft.

---

### Verdict

The core architecture — codehash-pinned root-signed policy, dual-signature session model, push-then-measure SOLE-MOVER cap accounting, transient flash frame with reentrancy/depth guards — is **fundamentally sound**. The metered funds-in paths (`_pullRoot`, `_feedAndRun` output measurement, `_reserveCap`-before-pull CEI) are correct, and the two prior MEDIUMs remain properly fixed.

**One High must be fixed before deploy:** the flash callback trusts an unmeasured caller-supplied `amount` (Finding 1), turning any processor-resident ERC20 into permissionless loot. It is the single break in the otherwise-consistent "measure, never trust" discipline, and it is amplified by the missing ERC20 end-sweep (Finding 2) that keeps the drainable pool replenished. Fixing 1 (measure received principal) + 2 (symmetric ERC20 sweep) closes the theft primitive and its fuel supply.

The remaining Lows are genuine correctness gaps that are unfixable post-deploy and should be closed now: native accounting conflation/stranding (3, 4, 5) and the dead PERMIT2 mode (6, a liveness defect that silently forces standing allowances). Finding 7 (verb constancy) is cheap defense-in-depth that also hardens the Finding-1 blast radius. The Informationals (8–11) are documentation/config fail-closed improvements. **Nothing requires an architectural rethink** — the money model holds modulo the enumerated fixes, all local and mechanical.

### Simple summary

This contract runs signed lists of "operations" that move a user's tokens under spending caps — and it is permanent once deployed, so bugs can't be patched. The good news: the overall design is solid. The processor almost always *measures* how much money actually moved instead of trusting a number, and the permission/signature model holds up under adversarial poking. I re-checked the two previously-fixed medium bugs and they're still fixed. I threw out five candidate "bugs" that don't actually work against this code. **The one serious problem:** the flash-loan callback believes a caller-supplied "amount" without checking what tokens were really received. An attacker who is their own user can pin a fake flash adapter, call back with a made-up amount and send nothing, and walk away with any tokens the contract happens to be holding — and the contract does leave tokens lying around because it only sweeps leftover ETH, never leftover tokens. That pair must be fixed before launch. Beyond that, several smaller issues strand ETH permanently or make the Permit2 funding mode literally impossible to use; all are cheap, local fixes worth doing now precisely because the contract can never be changed later.
---

## Resolution (2026-07-23) — all confirmed findings FIXED in-repo

Every confirmed finding was fixed with a regression test; the suite is **166 tests, 0 failures**.

| # | Sev | Fix | Test |
|---|-----|-----|------|
| F1 | High | `onFlashLoan` credits the **measured** balance-delta principal (snapshot at dispatch), not the caller-claimed `amount` — a phantom callback credits 0 → `RepayShortfall`; resident ERC20 is safe | `test_AuditF1_PhantomFlash_CannotDrainResident` |
| F2 | Low | Symmetric **ERC20 frame sweep to root** at end-of-execute (mirrors the native sweep) — nothing strands, no resident pool to harvest | `test_AuditF2_Erc20FrameResidue_SweptToRoot` |
| F3 | Low | Subsumed by F4's always-measure native; residual caller-vs-root refund asymmetry documented as accepted (keepers front exactly the wrap amount) | — |
| F4 | Low | **Always** measure native around `run()` (not only when `outToken==NATIVE`) so a refund can't strand; reject `op.value` on assert ops | covered by native tests |
| F5 | Low | Reject `THREADED` funding with a native/zero `fundToken` at the shape check | `test_AuditF5_ThreadedNativeFundToken_Rejected` |
| F6 | Low | **Decouple the Permit2 signature from `opsHash`** — sigs are a separate `execute()` arg (`fundingSigs`); `fundingParams` holds only `(nonce,deadline)`. The mode was previously unconstructible (circular witness). | `test_Permit2Funding_PullsViaPermit2` |
| F7 | Low | Re-assert `flashCodehashes` membership + `funding==NONE`/`value==0` at dispatch in `_runFlashOp` (mutable-verb defense) | — |
| F8 | Info | `cancelIntent` is **root-only** (a leaked session key can't permanently latch-cancel a protective intent) | `test_AuditF8_SessionKeyCannotCancel` |
| F9 | Info | Reject a native-keyed `TokenCap` (it enforced nothing) | — |
| F10 | Info | `OracleReadAdapter.pythPrice` enforces a valid publish time; new expo-aware `pythPriceScaled` for real price gates | `test_AuditF10_*` |
| F11 | Info | `chainlinkPriceScaled` reverts (`ScaleUnderflow`) instead of feeding a truncated `0` into a gate | `test_AuditF11_*` |

**Not fixed (external, per scope):** a real-deployed-**Permit2 fork test** (audit-only — no chain deploy) and the deferred root-sourced flash **premium/shortfall top-up**. The design verdict stands: **core architecture sound, no rethink needed.**
