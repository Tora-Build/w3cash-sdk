# W3Cash Design C — Internal Security Audit

> **Resolution (2026-07-21, same day):** the two MEDIUMs are **FIXED** in-repo with regression
> tests (149 contract tests green): **M1** — the keeper tip now meters against the **shared**
> `spentByToken` cursor (the separate `tipSpent` mapping was removed), so total per-token outflow
> is bounded by one cap (no 2× drain); **M2** — the best-effort tip return is decoded as `uint256`
> and checked `== 1`, so a short/dirty token return can never revert the protective intent. The
> encoder-shape guards from `mustFixBeforePhase1` were also added on-chain: flash ops must carry
> `value == 0` (L3), and `PERMIT2`/`STANDING` funding rejects a native/zero `fundToken` (I2). The
> remaining LOWs + the NOTE(freeze) deploy-gate items stay open for the external audit. This
> internal audit does **not** replace a full external audit before any mainnet deploy.


**Scope:** `W3CashProcessor.sol` (Design C core, built this cycle, tests green, NOT deployed) + `PostConditionAdapter.sol`, with the surrounding adapter fleet and the deployed Legacy processor considered for context. Five review lenses (reentrancy/flash-frame, signature/replay/domain, four-invariants/native-frame, adapter-fleet/tip/post-condition, plus one degenerate "test" lens that returned a placeholder and was discarded).

**Result:** 0 new critical, 0 new high. The Design C core is fundamentally sound — reentrancy, EIP-712 replay/domain, session-auth chaining, reserve-then-run CEI, and the native-frame accounting invariant all hold. The material new issues are 2 MEDIUM (both signer/config-gated) and 5 LOW, plus a set of pre-acknowledged NOTE(freeze) items tracked separately.

## Findings

| # | Sev | Title | Location | Status |
|---|-----|-------|----------|--------|
| M1 | Medium | Keeper tip reuses the action token's cap via a separate cursor → up to 2× cap per-token per window | `W3CashProcessor.sol:189-190,653-680` vs `629-648`; `TokenCap` :137 | Confirmed (lenses 3,4,5) |
| M2 | Medium | `_payTipMetered` raw `abi.decode(ret,(bool))` reverts on short/dirty tipToken return → best-effort tip bricks the whole protective intent | `W3CashProcessor.sol:670-678` | Likely (lens 5) |
| L1 | Low | `onFlashLoan` credits the adapter-claimed `amount` instead of a measured balance delta — breaks the measure-don't-trust rule | `W3CashProcessor.sol:609` vs `_pullRoot:478-484`, `_feedAndRun:516-529` | Confirmed (lenses 1,4) |
| L2 | Low | ERC20 frame residue never swept back to root at intent end (only NATIVE is) → stranded output + supplies L1's idle balance | `W3CashProcessor.sol:296-299`, `_exitFrame:728-741` | Likely (lens 1) |
| L3 | Low | A `VERB_FLASH` op carrying `op.value` strands that native permanently (`_drawNative` debits, `_runFlashOp` forwards nothing) | `W3CashProcessor.sol:283-285`, `_checkPolicyAndShape:407-410` | Confirmed (lens 4) |
| L4 | Low | `_sweepNative` reverts on failed send → a non-payable contract root bricks every native-residual intent (immutable, no rescue) | `W3CashProcessor.sol:713-716,297-299,711` | Likely (lens 4) |
| L5 | Low | `PostConditionAdapter` re-imports the QueryAdapter first-word decode footgun → false protection on multi-field views | `PostConditionAdapter.sol:44-49` | Likely (lens 5) |
| I1 | Info | Exactly ONE flash sub-group admissible per whole intent (fail-closed, undocumented functional limit) | `W3CashProcessor.sol:570-571,602,737` | Confirmed |
| I2 | Info | Native `TokenCap` (token==0) is dead/inconsistent config — native is never metered, yet STANDING/PERMIT2 with fundToken==0 reserves it then reverts on `IERC20(0)` pull | `W3CashProcessor.sol:137,425,477` | Confirmed |
| I3 | Info | Same-chainId fork replay of grant/intent sigs (inherent EIP-712 limit; cross-chain replay closed by construction) | `W3CashProcessor.sol:215,344-359` | Confirmed |

**Dropped:** the "test" lens returned a single stub finding (`title:"t"`, `repro:"r"`, `fix:"f"`, severity high) with no location or substance — it is a harness placeholder, not a real high, and is excluded from `highCount`.

---

## M1 — Tip sub-budget doubles per-token exposure (Medium, confirmed)

**Where:** `_reserveCap` meters actions against `spentByToken[gDigest][token]` (`:629-648`); `_payTipMetered` meters tips against the *distinct* `tipSpent[gDigest][token]` cursor (`:653-680`) — but both are ceiling-checked against the **same** `TokenCap.cap`. `TokenCap` (`:137`) has a single `cap` field and no separate tip ceiling.

**Repro:** Root grants a session intending "≤ 1000 USDC leaves per window" via `caps[USDC].cap = 1000`. A compromised/hostile session key signs one intent that (a) pulls 1000 USDC to the attacker through a capped action (fills `spentByToken` to 1000) **and** (b) sets `tipToken=USDC`, `tipAmount=1000`, `keeperOfRecord=attacker` (fills `tipSpent` to 1000). Total pulled from root in one window = **2000**, double the authorized cap. This weakens by 2× the exact bound the session-cap system exists to enforce against hot-key compromise. Bounded: only bites when root granted a *standing* allowance for the shared token (PERMIT2-only roots degrade the tip to untipped), and only when tipToken == an action fundToken (the common USDC/USDC case). Untested — `test_Tip_PaysKeeper` / `_policyWithTip` always use a *different* token for the tip, so the doubling is never exercised.

**Fix:** Meter tips against the **same** `spentByToken[gDigest][token]` cursor as actions (unified per-token rolling budget), OR add an explicit `uint128 tipCap` to `TokenCap` so root sizes the tip envelope independently, OR reject an `it.tipToken` that collides with any action `fundToken`. Document the semantics on `TokenCap`. **Note (shape impact):** the `tipCap` variant changes the signed Policy struct — see `mustFixBeforePhase1`.

## M2 — Best-effort tip bricks the intent on a dirty/short token return (Medium, likely)

**Where:** `_payTipMetered` (`:670-678`): `(bool ok, bytes memory ret) = it.tipToken.call{gas:TIP_GAS_CAP}(...); bool paid = ok && (ret.length == 0 || abi.decode(ret, (bool)));`

**Repro:** The low-level call correctly tolerates revert/OOG (`ok=false` → refund → continue) and empty returns. But when the token returns non-empty data that is *not* a clean 32-byte bool, `abi.decode(ret,(bool))` itself **reverts** and is *not* inside any try/catch — unwinding the entire `execute()`. (a) 1–31 byte return → ABI decoder Panic; (b) 32-byte dirty bool (e.g. `transferFrom` returns `2`, which some non-standard ERC20s do) → invalid-bool Panic. This is exactly the class `SafeERC20` exists to absorb. Result: a non-standard/hostile `tipToken` bricks the protective action (a stop-loss / liquidation-protection intent never runs), contradicting the item-10 guarantee that a failed tip "NEVER bricks the protective action." `tipToken` is signer-chosen and digest-bound (not third-party theft), but a naïve/compromised ASP compiler or a legitimately non-standard token silently converts a degrade into a hard brick. `test_Tip_DryAllowance_DegradesNotBricks` covers only the revert path, not the dirty/short-return path.

**Fix:** Do not raw-`abi.decode` the return. Mirror SafeERC20's tolerant check inside the best-effort frame: `paid = ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret,(bool))))`; any other shape → `paid=false`, refund the reserve, emit `TipSkipped`. That keeps the decode from ever reverting the outer call.

## L1 — onFlashLoan trusts the claimed principal instead of measuring it (Low, confirmed)

**Where:** `onFlashLoan` does `_frameCredit(asset, amount)` (`:609`), trusting the callback `amount`; every other funding path measures a balance delta (`_pullRoot:478-484`, `_feedAndRun:516-529`).

**Repro:** If the flash `asset` is fee-on-transfer, or the pinned flash adapter forwards net-of-fee/less than `amount`, the frame ledger over-credits. Combined with an idle/donated `asset` balance in the processor (anyone can ERC20-transfer in; L2's un-swept residue also lands here), the THREADED sub-ops' real `safeTransfer` draws the shortfall from the idle balance, leaking pre-existing funds. With an honest, non-FoT, codehash-pinned adapter the credit equals arrival and nothing leaks — so exploitability is niche, but it is a genuine break from the invariant enforced on every other path.

**Fix:** Snapshot `balanceOf(this)` at dispatch/callback entry and credit the measured delta; additionally assert `receivedDelta >= amount` so a short-forwarding adapter cannot open a phantom credit.

## L2 — ERC20 frame residue never swept to root (Low, likely)

**Where:** Step 9 (`:296-299`) sweeps only `frameNative` to root; `_exitFrame` (`:728-741`) zeroes the ERC20 ledger without moving tokens.

**Repro:** An intent that credits an ERC20 output to the frame but omits a downstream op that fully drains it leaves those tokens sitting in the processor as idle balance — the ledger is zeroed but no transfer occurs. Primarily a stuck-funds / compiler-obligation issue, but it directly manufactures the idle-balance precondition that makes L1 reachable across intents (a later honest intent's per-frame ledger starts at 0 and cannot THREADED-draw the residue).

**Fix:** Either (a) at step 9 iterate the touched-token list and `safeTransfer` any nonzero ERC20 residue back to root before zeroing (symmetric with the NATIVE sweep), or (b) enforce in the compiler that every intent terminates with a payout op that drains each frame token, plus a processor-side assert that the ERC20 frame ledger is empty at exit (fail-closed on a mis-compiled intent).

## L3 — Flash op carrying op.value strands native (Low, confirmed)

**Where:** `execute()` runs `_drawNative(op.value)` for every action incl. flash (`:283`) then `_runFlashOp` (`:284-285`), which calls `initiateFlash` with **no** `{value:}`. `_checkPolicyAndShape` (`:407-410`) does not force `op.value==0` for `VERB_FLASH` (contrast `_checkSubGroup:583`, which does reject value on sub-ops).

**Repro:** A signed `VERB_FLASH` op with `value=V>0` debits caller/frame native by V but never forwards it; end-of-execute sweeps return only the reduced amounts, so V ETH is stranded permanently in the immutable contract. Practically self-grief (with `msg.value=0` and empty frame, `_drawNative` reverts and execute fails safe), but a latent trap: any keeper who funds such an op loses that ETH.

**Fix:** In `_checkPolicyAndShape`, in the `VERB_FLASH` branch require `op.value == 0` (revert `PolicyDenied`), mirroring the sub-op guard at `:583`. **Note (shape impact):** the off-chain encoder must then never emit `value` on flash ops.

## L4 — _sweepNative revert-on-failure bricks a non-payable contract root (Low, likely)

**Where:** `_sweepNative` reverts `NativeRefundFailed` on a failed send (`:713-716`), called for the root frame-native sweep (`:299`), caller sweep (`:297`), and pause refund (`:711`).

**Repro:** An ERC-1271 smart-account root without a payable receiver that runs any intent producing frame-native residual (unwrap WETH → send-ETH, dust from rounding) hits `:299`, whose `.call{value:}` fails and reverts the whole `execute`. On an immutable, admin-less processor such a root can never run native-residual intents and any ETH bound for it is unrescuable. The caller-sweep path lets a keeper that can't receive ETH brick its own submission (minor self-grief).

**Fix:** For the root native sweep, prefer a non-reverting push with a pull fallback: on failed `.call`, record `owedNative[root] += frameNative` and expose a permissionless `claimNative(root)`, rather than reverting. At minimum, document that a contract root MUST have a payable receiver.

## L5 — PostConditionAdapter first-word decode footgun (Low, likely)

**Where:** `PostConditionAdapter.run` (`:44-49`): `(bool ok, bytes memory ret) = target.staticcall(callData); uint256 actual = abi.decode(ret,(uint256));` — the same first-32-byte assumption the OracleReadAdapter was purpose-built to fix for the gate path.

**Repro:** The PostConditionAdapter is the on-chain slippage/MEV safety net (revert-on-unmet). If an author points `target/callData` at a multi-return view (`latestRoundData`, `getUserAccountData`, a struct getter), `actual` is word 0 (e.g. `roundId`, a large monotonically-increasing number), so an assert like `roundId >= minOut` passes trivially and the swap/action is silently **not** protected. Staticcall-only and opsHash-bound, so no theft or keeper bypass — a false-negative-protection footgun, not a fund path, but the same defect class already remediated on the gate path.

**Fix:** Route post-conditions through typed single-`uint256` readers (OracleReadAdapter-style) and/or add a word-offset parameter; document that the assert target MUST return a single `uint256`. Add a test that a multi-field return is rejected or read at the correct offset. **Note (shape impact):** a word-offset param would extend the encoded post-condition op.

## I1 / I2 / I3 — Informational

- **I1:** Two `VERB_FLASH` ops in one intent fail-close (`FlashSlotConsumed`): `_T_FLASH` is set in `onFlashLoan` and cleared only in `_exitFrame`, while `_runFlashOp` clears only the adapter/ctx pins. Matches the "single sub-group per frame" comment but is an undocumented one-flash-per-intent limit. No security change needed; if multi-flash is desired, reset `_T_FLASH` at the end of `_runFlashOp`; otherwise document the constraint in the compiler.
- **I2:** `TokenCap` documents native caps (token==0) but native `op.value` is exempt from metering, so a native cap constrains nothing — yet a STANDING/PERMIT2 action with `fundToken==0` passes the shape check, reserves against the dead cap, then reverts inside `IERC20(0).safeTransferFrom`. Confusing dead config, no exploit. Fix: reject caps with token==0 in `_assertCaps` (or actually meter native), and reject STANDING/PERMIT2 with `fundToken==0` at shape-check time. **Note (shape impact):** tightens what the encoder may emit.
- **I3:** Grant/intent digests carry `chainId + verifyingContract` (OZ EIP712 lazy recompute), so cross-chain replay is closed by construction (invariant C2); only a same-chainId fork leaves both digests valid — inherent to any EIP-712 scheme. Keep OZ's lazy `_domainSeparatorV4`; optionally document the fork caveat.

---

## Known pre-freeze work (pre-acknowledged; NOT counted as new criticals)

These are in-code `NOTE(freeze)` placeholders / known hackathon-era design, flagged once here and excluded from the new-finding counts:

1. **Permit2 `WITNESS_TYPESTRING` golden vector** (`:126-127`, `_permit2Pull:490-505`). As written the typestring appears EIP-712-correct and a mismatch **fails closed** (the pull reverts — liveness, not forgery). Land a per-chain golden vector proving `signTypedData_v4` over the intent-witness matches the on-chain typehash before deploy.
2. **ERC-7739 nested-712 for the ERC-1271 root branch** (`_verifyRoot:364-378`). Raw EIP-712 digest validated without 7739 wrapping. Real cross-context replay risk is LOW (full domain + typehash binding makes a collision infeasible for any honest counterparty; residual risk is confined to pathological raw-hash wallets). Wrap the digest in 7739 nesting and ship the raw-hash-mock-rejects / 7739-Safe-accepts vector before the immutable deploy.
3. **The three flash-frame formal proofs** (single-sub-group / zeroed-on-every-exit / no unreserved-root-pull-via-reentry). Traced and found to hold in code this cycle; formal write-up still outstanding.
4. **Still-shipped Legacy `IAdapter` fleet + deployed Legacy processor.** The ~50 `transferFrom(initiator)` adapters are correctly **rejected** by the new processor (missing `verb()`/`adapterKind()` → `PolicyDenied` + codehash gate), but that leaves the new processor with **no production fund-moving adapter yet** — a deploy gate: ship ≥1 audited SOLE-MOVER (push-fed, balanceOf-delta) action adapter + a conformance test. Separately, on the **live** `W3CashProcessorLegacy` (X Layer 196 / 1952 / Base Sepolia), `_execute` never consumes the nonce, so signed intents are **replayable** against a standing allowance until `incrementNonce` — the known hackathon design; consume/increment the nonce in `_execute` or migrate users off it.

---

## Verdict

**The Design C on-chain core is sound enough to proceed** to the off-chain Phase-1 build, given it still faces a real external audit before any deploy. All four target invariants (PAUSE-writes-nothing, recurring re-runs, permissionless `execute`, execution-chain EIP-712 domain) hold; the reentrancy / flash-frame model, the signature/replay/domain/session-auth chain (epoch folded into both typehashes, preimage-bound policyHash/opsHash, intent→grant→root chaining, fail-closed `_verifyRoot`), and the native-frame accounting invariant were each traced and found correct. No critical or high in the new core. The two MEDIUMs are signer/config-gated (tip-cap doubling; best-effort-tip brick) and should be fixed before audit freeze; the five LOWs are containment-level, self-grief, or false-negative-protection. The remaining risk sits in the pre-acknowledged freeze items above, which are deploy gates, not Phase-1 blockers.

_Lead auditor consolidation of 5 lenses; 1 degenerate lens discarded. Counts below exclude NOTE(freeze) placeholders._