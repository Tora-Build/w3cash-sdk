## W3Cash SDK — Security Audit: Lead Auditor Final Report

Blind source audit of `/Users/mohammadzakerirad/Sooth/w3cash-sdk`. Findings below are the CONFIRMED (and clearly-argued UNCERTAIN-worth-fixing) results after adversarial verification; refuted candidates are listed at the end. Highest stakes are the **DEPLOYED** contracts: the Legacy nonce-based processor + 7 core adapters (Transfer, Approve, Wait, Query, GasPrice, TimeRange, Signature) on Base Sepolia 84532 / X Layer 1952 / X Layer 196 — these hold real funds.

### Summary Table

| # | Sev | Title | Area | Status |
|---|-----|-------|------|--------|
| 1 | Critical | Unsigned execution-cursor header lets any observer skip all gate/condition ops on a victim's signed intent | On-chain DEPLOYED (Legacy) | Confirmed / NEW |
| 2 | High | Nonce verified but never consumed — one signature replays fund-moving adapters until manually cancelled | On-chain DEPLOYED (Legacy) | Confirmed / NEW |
| 3 | Medium | Signature has no EIP-712 domain (no chainId/verifyingContract/deadline) → cross-chain & cross-deployment replay | On-chain DEPLOYED (Legacy) | Confirmed / NEW |
| 4 | Low | ApproveAdapter ignores initiator; sets the adapter's own allowance to an attacker-chosen spender | On-chain DEPLOYED (Approve adapter) | Confirmed / NEW |
| 5 | High | FlashLoanAdapter/ClaimAdapter arbitrary `target.call` under shared adapter identity drains standing allowances | Adapter fleet (UNDEPLOYED) | Confirmed / NEW |
| 6 | Medium | AaveAdapter.registerAToken & ClaimAdapter.setAaveRewardsController unauthenticated → permissionless global-state DoS | Adapter fleet (UNDEPLOYED) | Confirmed / NEW |
| 7 | Low | WrapAdapter sweeps its own residual/donated ETH to a caller-chosen recipient when forwarded value is 0 | Adapter fleet (UNDEPLOYED) | Confirmed / NEW |
| 8 | High | MCP x402 payer auto-signs any 402 with no value cap / payTo allowlist / consent | Off-chain (MCP app) | Confirmed / NEW |
| 9 | Low | x402 payment gate fails open to FREE and only initializes once at boot | Off-chain (ASP) | Confirmed / NEW |
| 10 | Low | Telemetry indexer has no reorg/finality handling → corrupted status + reliability stat | Off-chain (telemetry) | Confirmed / NEW |
| 11 | Low | Telemetry never attributes NonceCancelled → cancelled intents shown "waiting", stats.cancelled always 0 | Off-chain (telemetry) | Confirmed / NEW |
| 12 | Low | Unauthenticated/unrated /simulate-intent drives attacker-controlled RPC view-call fan-out (amplification/DoS) | Off-chain (ASP) | Confirmed / NEW |
| 13 | Low | Design C: always-measure-native credits caller-fronted refunds to root instead of the keeper | On-chain Design C (NOT deployed) | Confirmed / NEW |
| 14 | Low | Design C: VERB_ASSERT ops not forced to NONE funding → root funds pushed to PostConditionAdapter stranded | On-chain Design C (NOT deployed) | Confirmed / NEW |
| 15 | Info | Unauthenticated /intents enumerates any address's recorded intent metadata (summary + timing) | Off-chain (telemetry) | Confirmed / NEW |
| 16 | Info | Unauthenticated/unrated /quote/bridge + compile autoQuote fan out to Across with no per-IP limit | Off-chain (ASP) | Uncertain-worth-fixing / NEW |
| 17 | Info | agent-card reflects unvalidated Host/X-Forwarded-Proto into advertised endpoint URLs | Off-chain (ASP) | Uncertain-worth-fixing / NEW |

---

## A. On-chain — DEPLOYED contracts (real funds, highest stakes)

### 1. [CRITICAL] Unsigned execution-cursor header lets any observer skip all gate/condition ops
`packages/.../W3CashProcessorLegacy.sol:128-153` (verify path), signing at `:130`; encoder `encode.ts:840-853, 1688-1691`.

**Mechanism.** `execute()` is permissionless. The signature is `keccak256(abi.encodePacked(keccak256(payload), nonce))` — it commits only to `payload` and `nonce`. The instruction header `(seq, length, payloadHash)` returned by `_splitHeaderAndPayload` is *discarded* before hashing (first tuple element dropped at L128) and never enters the digest. `_execute` then reads `seq`/`length`/`payloadHash` straight from that attacker-controllable header. The sole header check, `require(keccak256(payload) == payloadHash)` at L149, is self-referential and reproducible for free. The loop `for (; seq < length;)` begins at the attacker-supplied `seq`, so an attacker can start execution at any op index and truncate the end. The encoder deliberately places the auto-expiry gate first and conditions before actions, so skipping to an action index bypasses TimeRange expiry, GasPrice, Wait, Query, and the SignatureAdapter co-signer requirement.

**Repro.** Victim signs `[op0 TimeRange expiry, op1 GasPrice(<20 gwei), op2 Transfer 100 USDC]`. Intent pauses on-chain (SignedPayload becomes public). Attacker keeps `payload/initiator/nonce/signature`, sets `forgedHeader = abi.encode(2, 3, keccak256(payload))`, wraps `forgedInstruction = abi.encode(forgedHeader, payload)`, and calls `execute(...)`. Signature re-verifies (payload+nonce unchanged); loop starts at seq=2 → transfer fires while expired and gas is 200 gwei. Same technique bypasses a SignatureAdapter co-signer.

**Impact.** The entire "execute only when condition holds" guarantee is void — forced execution + authorization bypass on user funds. Attacker cannot redirect the recipient (it is inside the signed payload), which is the only thing short of direct theft.

**Fix.** Authenticate the header: hash over `keccak256(abi.encodePacked(keccak256(payload), length, nonce))` so op-count and payload binding cannot be swapped; force the public `execute()` entry to `seq == 0` (reject caller-supplied positive cursors). Legitimate resume-after-PAUSE re-runs from 0 idempotently. `seq > 0` is legitimate only on the cross-chain resume path, which must arrive through an `authorizedEndpoints`-gated receive that sets `seq` via `_updateHeader` itself — never via public `execute()`.

### 2. [HIGH] Nonce verified but never consumed — signature replay
`W3CashProcessorLegacy.sol:71-192`; nonce read `:126`; only writer `incrementNonce():116-118`; `TransferAdapter.sol:37-50`.

**Mechanism.** The only nonce logic is the equality check `sp.nonce == nonces[initiator]` (a read). `nonces` is written solely by the user-initiated `incrementNonce()`. Neither `execute()` nor `_execute()` advances the nonce or records a per-payload executed flag; no `executed`/`completed`/`deadline` state exists on the struct or contract. Since the signature binds to `(keccak256(payload), nonce)`, the identical signed bytes re-verify forever. Fund-moving adapters pull against a standing allowance every call (the adapter's own docstring prescribes pre-approval for gasless flows), so re-invoking drains up to allowance/balance. The PAUSE/resume keeper model actively invites repeated `execute()` calls.

**Repro.** Victim approves TransferAdapter 1,000 USDC and signs one payload for a single 100-USDC transfer (nonce 0). Attacker deploys a helper that loops `execute(sp)` 10× in one transaction → 1,000 USDC gone, nonce still 0. `incrementNonce()` cannot be inserted mid-batch, so the victim cannot defend against an atomic drain.

**Fix.** Add per-payload replay protection compatible with paused resumption: `mapping(bytes32 => bool) completed` keyed by `keccak256(abi.encode(initiator, nonce, payloadHash))`; require `!completed[key]` and set it only when the loop reaches `seq == length` (never on the PAUSE early-return). Lighter alternative: `nonces[initiator]++` on full completion only.

### 3. [MEDIUM] No EIP-712 domain → cross-chain / cross-deployment replay
`W3CashProcessorLegacy.sol:130`; SDK `W3cash.ts:181-191`; default chain index `IntentBuilder.ts:37`; deploy `DeployW3Cash.s.sol:75`.

**Mechanism.** The digest is `toEthSignedMessageHash(keccak256(abi.encodePacked(keccak256(payload), nonce)))` — EIP-191 personal_sign with no chainId, no verifyingContract, no deadline. The per-op `chain` field does not save it: the SDK defaults chainIndex 0, and deployments map index 0 to the local chain, so `getChain(0) == block.chainid` on every deployment (this must hold for local execution to work). With the processor and adapters deployed at identical addresses across chains and a victim holding mirrored approvals and matching nonce (0), a payload signed on chain A verifies and executes on chain B.

**Repro.** Alice signs a transfer intent on Base Sepolia (nonce 0, deterministic deployments, mirrored approvals). Attacker re-submits the same SignedPayload on X Layer; `getChain(0) == 1952 == block.chainid` → local branch → `safeTransferFrom(Alice, Bob, 100e6)` executes. Alice pays twice for one authorization.

**Fix.** Move to EIP-712 typed data with a domain binding `block.chainid` + `address(this)` (cached DOMAIN_SEPARATOR with chainId-change re-derivation), add a `deadline` field and revert past it, and mirror it exactly in `W3cash.ts` (`signTypedData`). Combine with the nonce-consumption fix (#2) to also stop same-chain replay.

### 4. [LOW] ApproveAdapter ignores initiator, approves its own balance to an attacker-chosen spender
`ApproveAdapter.sol:25-31`; dispatch `W3CashProcessorLegacy.sol:178`.

**Mechanism.** `execute()` discards `initiator` and calls `IERC20(token).forceApprove(spender, amount)` with token/spender/amount from attacker `input`. The processor uses a plain external call (not delegatecall), so this sets the *ApproveAdapter contract's* own allowance. `execute()` is permissionless via self-signed intent. An attacker grants themselves `max` allowance over any token held by ApproveAdapter and sweeps it.

**Impact bounded to stray/donated/dust tokens.** In the stateless legacy design no user principal ever rests at ApproveAdapter (Transfer moves initiator→recipient directly; Swap empties its own transient balance in-call; Batch dispatches in the pulling adapter's context). So the practical effect is (a) a stray-token sweep primitive and (b) an adapter that cannot fulfill its documented purpose (a contract cannot approve from a user's EOA).

**Fix.** Deprecate/remove ApproveAdapter from the registry (approvals belong inside the custodying adapter, as SwapAdapter already does). If retained: restrict `spender` to an allowlisted router set, refuse arbitrary max approvals, and reset allowance to 0 at end of call.

---

## B. On-chain — Design C processor (built, NOT deployed)

The Design C processor was previously blind-audited and 11 findings fixed. Re-verification confirms those fixes are broadly intact (flash callback measures received principal via balance delta; ERC20 residue swept to root; Permit2 sig decoupled into a separate `execute()` arg; `cancelIntent` root-only; native always measured; codehash-pinned adapters; fail-closed shape checks). Two low-severity residual gaps surfaced, both consequences of the hardening rather than regressions of it.

### 13. [LOW] Always-measure-native credits caller-fronted refunds to root, not the keeper
`W3CashProcessor.sol:286-309, 555-563, 576`.

**Mechanism.** `callerNative` is seeded from `msg.value` and decremented by the full `op.value` in `_drawNative` (bookkeeping only). In `_feedAndRun`, `nativeBefore = address(this).balance` already includes the whole `msg.value`; an adapter's native refund surfaces as `nativeAfter - nativeBefore` and is credited unconditionally to the frame NATIVE ledger with no caller-vs-frame attribution. At sweep, `callerNative` (already reduced by the full op.value) goes to `msg.sender` while frame NATIVE (the refund) goes to root. A keeper forced to front `msg.value` (because `_drawNative` reverts `InsufficientNative` when no frame native exists) loses its own change to root.

**Impact.** Keeper→root economic mis-attribution/griefing only; root funds never at risk, direction is strictly keeper→root, and a keeper that simulates before submitting sees the reduced net return and declines. Not theft or a solvency bug.

**Fix.** Thread the caller-vs-frame split of `op.value` into `_feedAndRun`; on a positive native delta `r`, refund `min(r, drawnFromCaller)` to `callerNative` first and only `_frameCredit` the remainder. Note the ambiguity when one `run()` both consumes `op.value` and emits native output (unwrap adapters); document if the always-to-root conservative choice is kept.

### 14. [LOW] VERB_ASSERT ops not forced to NONE funding → root funds stranded at PostConditionAdapter
`W3CashProcessor.sol:434-463` (esp. the assert guard at :462), `549-551`; `PostConditionAdapter.sol:41-51`.

**Mechanism.** An ACTION op targeting PostConditionAdapter (VERB_ASSERT) with `funding = STANDING/PERMIT2/THREADED` passes every shape check — the only assert-specific guard (`:462`) rejects `op.value != 0`, never the funding mode. `_reserveAndFund`/`_pullRoot` then pull `fundAmount` of root's token into the processor and `_feedAndRun` transfers it to PostConditionAdapter, which staticcalls a view and returns `""` without ever touching, forwarding, or returning the tokens. No output measurement reclaims them (snapshot taken after the outbound transfer; nothing returned) and the immutable adapter has no withdrawal path → permanent strand up to the token cap.

**Impact.** Low — requires the root+session-signed intent to explicitly set `funding != NONE` on an assert op (a correct SDK sets NONE). A malicious/compromised session key can only strand up to the cap it could already spend, so this is strictly weaker than the theft it could already do; root can revoke. It is a fail-closed asymmetry: the contract guards the native-strand and NONE+fundToken footgun but omits the root-pull strand for non-consuming adapters.

**Fix.** In the non-flash ACTION branch, force `funding == NONE` (and `fundToken == 0`) for any adapter with no consuming verb bit set; extend the L460-462 assert guard to reject funded assert ops, mirroring the existing L456/L457 guards.

---

## C. Adapter fleet (built, NOT deployed — becomes critical the moment deployed + approved)

### 5. [HIGH] FlashLoanAdapter / ClaimAdapter arbitrary `target.call` under shared adapter identity
`FlashLoanAdapter.sol:109-131, 149-180` (call at `:167-168`, repay pull `:174`); `ClaimAdapter.sol:123-129`; local dispatch with no allowlist `W3CashProcessorLegacy.sol:176`.

**Mechanism.** Legacy `_execute` calls `IAdapter(targetAddress).execute{value}(initiator, inputs[seq])` with **no registry/whitelist gate on the local target** (registry is consulted only for the cross-chain AMB id). An attacker self-signs an intent pointing an op at FlashLoanAdapter with arbitrary `operations`. `executeOperation` decodes `(target, callData)` and does `target.call(callData)` with `msg.sender == the adapter` — unconstrained in target and selector. Because repayment is pulled via `safeTransferFrom(user, ...)`, every legitimate user must grant a standing (often unlimited) allowance to this shared singleton, so `callData = token.transferFrom(victim, attacker, allowance)` spends any victim's allowance while the adapter repays principal+premium from the attacker's own borrowed funds — pure cross-user theft driven by the attacker's own intent. ClaimAdapter's `_claimGeneric` has the identical unconstrained call with no flash dependency.

**Repro.** Victim V approves FlashLoanAdapter F for USDC. Attacker A signs an intent: `target = F`, `input = abi.encode(USDC, borrowAmount, abi.encode(USDC, transferFrom(V, A, V_allowance)))`, calls `execute`. F borrows, `executeOperation` runs `USDC.transferFrom(V, A, allowance)` as F, repays from A's borrowed funds → A drains V.

**Fix.** Remove the unconstrained arbitrary-call primitive: forward the flash callback `operations` back through the processor to execute the initiator's *own* signed sub-ops (borrowed funds used under initiator authority, repayment via processor custody, not a per-user singleton allowance). If a direct call must remain, blocklist `transferFrom/approve/permit` selectors, forbid targets the adapter can spend, and allowlist targets. For ClaimAdapter, drop the generic path or apply the same restrictions. Additionally gate the Legacy local `targetAddress` through an on-chain adapter allowlist, and add access control to `ClaimAdapter.setAaveRewardsController`.

### 6. [MEDIUM] Unauthenticated global-state setters → permissionless DoS
`AaveAdapter.registerAToken:96-99`; `ClaimAdapter.setAaveRewardsController:137-140` (same pattern in `SparkAdapter:116`, `EigenLayerAdapter:161`, `OptimismBridgeAdapter:136`, `MoonwellAdapter:88`).

**Mechanism.** Both setters are `external` with no caller check and write global shared state (source comments admit "should be access controlled"). `aTokens[underlying]` is consumed in `_executeWithdraw`/`_executeWithdrawAll` to pick which token is `safeTransferFrom`'d. Any address can overwrite the mapping for everyone: point it at a nonzero wrong token → every USDC withdrawal reverts at the pull (permanent, cheap, re-appliable). `setAaveRewardsController` lets anyone repoint reward claims to an arbitrary contract, bricking or hijacking the external call.

**Impact.** Permissionless permanent DoS + fund-destruction griefing (a victim with a standing approval on the substituted token can have it pulled and stranded, no rescue function). Clean theft is refuted — Aave burns the adapter's aToken so substituted-token pulls revert atomically or strand.

**Fix.** Make both setters `onlyOwner` (Ownable / immutable admin). Cross-check registered aTokens against `pool.getReserveData(underlying).aTokenAddress`. Add an `onlyOwner` rescue for mis-pulled tokens. Apply to all sibling adapters carrying the same comment.

### 7. [LOW] WrapAdapter sweeps its own residual/donated ETH to a caller-chosen recipient
`WrapAdapter.sol:40-46`; forwarded value at `W3CashProcessorLegacy.sol:176`.

**Mechanism.** The processor forwards the op's `value` field (not tx `msg.value`). With `op.value = 0` and `input = abi.encode(true, adapterBalance)`, the adapter's `msg.value == 0 ? amount : msg.value` fallback wraps the adapter's own residual ETH and transfers the WETH to `initiator` (the attacker). Any ETH ever sitting in the adapter (open `receive()`, donations, misroutes) is drainable.

**Impact.** Low — no legitimate flow parks ETH in the adapter, so no user principal is exposed; limited to stranded/donated ETH; adapter undeployed.

**Fix.** Remove the fallback: `require(msg.value == amount); deposit{value: msg.value}(); transfer(initiator, msg.value)`. Never source wrap ETH from the adapter's balance.

---

## D. Off-chain services (ASP, MCP, telemetry)

### 8. [HIGH] MCP x402 payer auto-signs any 402 with no cap / allowlist / consent
`apps/mcp/src/payer.ts:21, 28-30`; `asp.ts:17-19, 62`; SDK client defaults (x402-core `client/index.mjs:24,29`), scheme wildcard (`registerExactEvmScheme` no `networks`), EIP-3009 payload (`x402-evm chunk-2HIS7LN3.mjs:17-24`).

**Mechanism.** `payer.ts` builds `new x402Client()` + `registerExactEvmScheme(client, { signer })` + `wrapFetchWithPayment(fetch, client)` and wires **none** of the SDK's guards: no `registerPolicy` value cap, no `onBeforePaymentCreation` abort/consent hook, no `networks` allowlist (so `eip155:*` wildcard is payable). The EIP-3009 authorization is `{ to: payTo, value: amount }` taken verbatim from the server response with no local max/allowlist. `wrapFetchWithPayment` signs and retries on ANY 402, and every ASP call (including read-only `/capabilities`, `/recipes`, `/simulate-intent`) routes through this fetch. Key fallback silently uses `RELAYER_PRIVATE_KEY`. `ASP_BASE_URL` is env-overridable with no https/host validation.

**Repro.** A malicious/compromised/redirected server (or a hostile `ASP_BASE_URL`) answers any request with one 402 requirement: `payTo=attacker`, `asset=<stablecoin the payer holds>`, `network=eip155:<any>`, `amount=<full balance>`, matching `extra.name/version`. The MCP signs a `TransferWithAuthorization` (EIP-3009 needs no prior approval) for the full balance and returns it; the attacker broadcasts and drains the wallet — zero human interaction.

**Impact HIGH not critical.** Gated on crossing the ASP trust boundary — against an honest server over intact TLS no drain occurs. But it turns any server compromise into an arbitrary drain up to each operator's payer balance, widened by the relayer-key fallback and read-only-endpoint coverage.

**Fix.** Wire the SDK's controls in `payer.ts`: value-cap policy from env; `payTo`+network+asset allowlist policy (primary defense); `onBeforePaymentCreation` consent/abort above a threshold; use `payingFetch` only for the actually-paid endpoint (`POST /compile-intent`) and plain fetch for GETs; enforce https + host allowlist on `ASP_BASE_URL`; require an explicit separately-funded `X402_PAYER_KEY` (no relayer fallback).

### 9. [LOW] x402 payment gate fails open to FREE and initializes only once at boot
`apps/asp/src/server.ts:92-93`; `x402.ts:158-227` (catch `return null` at `:219-226`).

**Mechanism.** The gate is built once via top-level `await buildX402Middleware(...)` and mounted only `if (x402Middleware)`. All init (OKX import, facilitator construction, `initialize()` which calls getSupported) is in one try/catch that `return null` on ANY throw → gate never mounts → `/compile-intent` served free for the whole process lifetime until manual restart. No interval/lazy re-init/per-request re-check.

**Impact.** Low — intentional documented fail-open; ASP is non-custodial, output is a deterministic client-reproducible compile (a free sample is even served on GET). Loss is ~$0.01/call micro-revenue. Realistic trigger is a transient facilitator outage at boot, not an attacker primitive.

**Fix.** If paid-gating is an invariant, fail closed: on init throw while enabled+configured, either `process.exit(1)` or mount a 503 stub, not `return null`. Add retry-with-backoff / periodic re-init to self-heal, plus a real alert. Distinguish deliberate-disabled (null correct) from configured-but-failed.

### 10. [LOW] Telemetry indexer has no reorg/finality handling
`apps/telemetry/src/index.ts:27` (head via `blockNumber()`, no confirmation buffer, monotonic `setCursor`); `db.ts:30-36` (INSERT OR IGNORE, no DELETE).

**Mechanism.** Indexes to the raw head and advances the cursor monotonically, never rewinding; event rows are never deleted. (b) An execution re-mined at height ≤ the advanced cursor is never re-scanned → intent stuck "waiting" forever. (a) An indexed execution whose tx is dropped/replaced on the canonical fork keeps its row → intent reads "executed" permanently and `fireRate` is inflated. No self-healing (the worker only reads its own rows).

**Impact.** Low — off-chain read-only telemetry, no fund/auth impact; skewed public reliability metric + wrong per-intent status, triggered by natural reorgs.

**Fix.** Add a confirmation buffer (`safeHead = head - CONFIRMATIONS`) and a per-tick rewind window (`from = cursor - REORG_DEPTH + 1`) with `DELETE FROM events WHERE chain_id=? AND block>=from` before re-upserting the canonical range (PK excludes block, so delete-then-reinsert prunes orphans).

### 11. [LOW] Telemetry never attributes NonceCancelled
`W3CashProcessorLegacy.sol:50` (event has no payloadHash); `parse.ts:32` (hashFrom topic index 1 = padded user address); status derivation `db.ts:63,73`, `parse.ts:118`.

**Mechanism.** `NonceCancelled(address indexed user, uint256 oldNonce, uint256 newNonce)` carries no payloadHash. The catalogue maps `hashFrom = topic index 1`, so it stores `payload_hash = padded user address`. Real intent hashes are keccak digests; a join requires 12 leading zero bytes (~2^-96) → never matches. So the "cancelled" branch of status derivation is dead: cancelled intents read "waiting" and `/stats.cancelled` is always 0. Deeper: NonceCancelled invalidates all of a user's pending intents at a nonce, and telemetry stores no per-intent nonce, so there is no correct key anyway.

**Impact.** Low — off-chain reporting inaccuracy; fireRate numerator stays accurate (cancelled-never-executed intents fall to unknown/waiting, not fired).

**Fix.** Remove the NonceCancelled catalogue entry (stops garbage rows); implement by nonce — store intent nonce+initiator at `/record`, index NonceCancelled into a `cancellations` table keyed by `(chainId, user, newNonce)`, mark an intent cancelled when it has no executed event and its nonce < max cancelled newNonce. Minimum: drop the handling and document legacy cancellations as untracked.

### 12. [LOW] Unauthenticated/unrated /simulate-intent drives attacker-controlled RPC view-call fan-out
`apps/asp/src/server.ts:69,393-404`; `x402.ts:202-208` (gate covers only `/compile-intent`); query gate compile `encode.ts:1360-1365`; `simulate.ts:147-158`.

**Mechanism.** `/simulate-intent` is never payment-gated and has no rate limiting. The `query` condition embeds a fully attacker-chosen `(target, calldata)` with no allowlist; `evalGate` issues one `eth_call` per gate through the deployed QueryAdapter, which staticcalls the attacker target at the current block. Up to ~MAX_STEPS (32 combined) gate calls (or ~64 ERC20 reads via actions) per small POST, sequential with 8s timeouts. Reads only — no fund movement, and gate results are reduced to pass/blocked/unknown (not echoed).

**Impact.** Low — RPC/amplification + event-loop/socket DoS against the configured node; conditional operator RPC-quota drain if `SIM_RPC_*` points at a metered/private node (defaults are public). "SSRF" and "96×" from the candidate are refuted: the RPC host is fixed (arbitrary on-chain view-call, not arbitrary URL), and the cap is 32 combined steps.

**Fix.** Per-IP rate limiting on `/simulate-intent` (and `/quote/bridge`); bound actual outbound fan-out independent of step count (cap gate calls, mark rest "unknown", bounded concurrency + total-time cap); constrain the free-preview `query` gate (require initiator, restrict target/calldata); never point `SIM_RPC_*` at a privileged node.

### 15. [INFO] Unauthenticated /intents enumerates any address's recorded intent metadata
`apps/telemetry/src/index.ts:57,72-82`; `db.ts:55-60`.

**Mechanism.** Reached from the top-level fetch handler with no auth (only the 40-hex address regex), returning up to 200 rows for any `initiator` with no ownership predicate. The `summary` is off-chain ASP-supplied metadata not derivable from chain events, so wallet→payloadHash→summary→timing linkage is genuinely additional information.

**Impact.** Informational — privacy/enumeration of ASP-recorded automation summaries and timing; no funds/credentials; only ASP-recorded intents appear.

**Fix.** Require ownership proof (EIP-191/712 signature recovering to `initiator`) or reuse the `x-record-secret`, or drop initiator enumeration and keep only per-payloadHash lookup. At minimum strip the `summary` field from the unauthenticated response.

### 16. [INFO, Uncertain] Unauthenticated/unrated /quote/bridge + compile autoQuote fan out to Across
`apps/asp/src/server.ts:170-211, 238-276`; `across.ts:58`; free-by-default `x402.ts:146,200-204`.

**Mechanism.** `/quote/bridge` is never in the paid-route map (free in every config); compile autoQuote fires up to MAX_AUTOQUOTE=4 outbound Across fetches per request. No per-IP rate limiting anywhere. Real angle: outbound-volume amplification (up to ~4× inbound) from the ASP's IP → Across-side rate-limit/ban degrading bridge quoting for legit users.

**Impact.** Informational/low — an off-chain hardening gap. The candidate's "48s held slot" is refuted (Node is non-blocking; invalid Across routes error quickly). Developers already bounded per-request fan-out (MAX_AUTOQUOTE, MAX_STEPS, 64kb cap, 12s timeout); what's missing is per-IP / global-concurrency limiting, conventionally an infra-layer concern.

**Fix.** App-layer per-IP rate limiting on `/quote/bridge` + `/compile-intent`; a global `p-limit` outbound budget for Across; short-TTL cache of identical quotes; optionally add `/quote/bridge` to the paid map.

### 17. [INFO, Uncertain] agent-card reflects unvalidated Host/X-Forwarded-Proto
`apps/asp/src/server.ts:104-106`; `agentcard.ts:47-73`.

**Mechanism.** `baseUrl` is built from client-controlled `x-forwarded-proto` + `host` with no allow-list and embedded verbatim into every advertised endpoint URL. Output is JSON (no XSS).

**Impact.** Informational — the cache-poisoning exploit requires a shared cache that caches this dynamic JSON, keys by path only, and still forwards the spoofed Host upstream; none exists in the documented nginx (`proxy_set_header Host $host`, no `proxy_cache`) / cloudflared deployment. A direct caller only reflects its own Host to itself.

**Fix.** Use a configured origin: `baseUrl = process.env.PUBLIC_BASE_URL ?? "https://asp.w3.cash"`, ignore request headers. If host derivation stays, validate against an allow-list and fall back to canonical; optionally send `Vary: Host`.

---

## Refuted / non-issues (dropped)

- **Fleet adapters pull from initiator with input-controlled token/amount** — token/amount/recipient live inside the signed payload (re-bound by payloadHash check + signature); adapters gate `msg.sender == processor`. Standard approve/transferFrom model; only an amplifier of the separately-reported bugs (#1/#2), not independently exploitable.
- **BatchAdapter authority fan-out** — every adapter gates on the *direct caller*; sub-calls run with `msg.sender == BatchAdapter ≠ processor`, so all fund-moving sub-calls revert. Batch data is signature-covered. Non-functional against the gated fleet, not a drain. (Latent missing-PAUSE-propagation code smell only.)
- **QueryAdapter reverts on codeless/void target** — target is signature-bound (not attacker-injectable); nonces aren't consumed so a revert burns nothing and is retryable; functionally identical to PAUSE; selfdestruct-to-codeless dead post-EIP-6780. DX nit.
- **Design C encoder missing `now` skips auto-expiry** — not silent (case-specific + always-on warnings, `replayable:true`, `expiry.applied:false`); live path always injects `now` server-side; only self-inflicted against explicit warnings. No attacker lever.
- **X-Payment-Network disclosure derived from request header** — disclosure runs only inside the gate's success callback, reading the *same* network field the gate already verified against a real payment; cannot report an unpaid network. Redundant-source code smell only.
- **Telemetry /record non-constant-time compare + unvalidated initiator** — network-facing timing on a high-entropy secret is unrecoverable; writes require the secret; `computeStats` ignores initiator and `/intents` validates its query param, so junk rows are inert. Hygiene note.
- **Encoder hard-codes X Layer mainnet == testnet addresses / local chain index 0** — index 0 is the correct encoding for the documented `setChain(0,196)`; exploit is contingent on an unproven deployment misconfig, and the worst case is a safe atomic revert (no AMB adapter), not misrouting or loss.
- **Design C flash repay premium adapter-controlled** — bounded by root's own frame ledger (not resident/other-user balances); the flash adapter must be in root's own `flashCodehashes` allowlist, which already grants sole-mover authority. Intended trust boundary, no third-party path. (A premium ceiling is optional hardening — this is the deferred/accepted top-up item.)

---

## Verdicts by area

- **On-chain DEPLOYED (Legacy processor + core adapters) — UNSOUND, immediate action required.** Findings #1 (critical) and #2 (high) together mean any public observer can force-execute and infinitely-replay a victim's signed intent against standing allowances; #3 extends that across chains/deployments. The signing/verification scheme is the root cause and must be redesigned (authenticate header+length, EIP-712 domain+deadline, consume the payload). These affect real funds today.
- **On-chain Design C (not deployed) — sound with two low-severity fail-closed gaps** (#13, #14) worth fixing before deployment; the 11 prior fixes verify intact.
- **Adapter fleet (not deployed) — one high-severity design defect (#5) plus a medium DoS class (#6)** that become critical/serious the moment these adapters are deployed and approved; the arbitrary-call-under-shared-identity pattern must be removed before any fleet deployment.
- **Off-chain — one high-severity client defect (#8, MCP payer)** and a set of low/informational hardening gaps. The MCP payer must gain value caps + payTo allowlist before it is used with a funded key.

## Overall

The off-chain and Design C code is broadly careful, but the **DEPLOYED Legacy processor's signing scheme is fundamentally broken**: the execution cursor is unauthenticated and signatures are never consumed. **Single most important fix: authenticate the instruction header and pin the public entrypoint to `seq = 0` (finding #1), together with per-payload replay consumption (#2)** — these are on live, real-funds contracts and enable forced execution + unbounded replay by any observer.
---

## Resolution (2026-07-23)

| # | Sev | Area | Action |
|---|-----|------|--------|
| 1 | Critical | Legacy (deployed) | **Cannot patch (immutable).** Design C already fixes it (bind full header + `seq==0`, C1). See `SECURITY-NOTICE-legacy.md`. |
| 2 | High | Legacy (deployed) | Cannot patch. Design C's per-intent cursor consumes each intent. |
| 3 | Medium | Legacy (deployed) | Cannot patch. Design C uses an EIP-712 execution-chain domain + deadline. |
| 8 | High | MCP payer | **FIXED** — `payer.ts` policy gate: host allowlist + per-call value cap + network/payTo allowlist. |
| 13 | Low | Design C | **FIXED** — caller-fronted native refunds go to the keeper (`test_AuditN13_*`). |
| 14 | Low | Design C | **FIXED** — funded/valued `VERB_ASSERT` ops rejected (`test_AuditN14_*`). |
| 6 | Medium | fleet (undeployed) | **FIXED (named 2)** — `AaveAdapter.registerAToken` + `ClaimAdapter.setAaveRewardsController` owner-gated. Siblings (Spark/EigenLayer/OptimismBridge/Moonwell) need the same before fleet deploy. |
| 4 | Low | ApproveAdapter (deployed) | Documented — deprecate; approvals belong in the custodying adapter. |
| 5 | High | FlashLoan/Claim (undeployed) | Known — Addendum B already excludes FlashLoanAdapter pending a SOLE-MOVER rewrite; ClaimAdapter same class. Not wired into Design C. |
| 7 | Low | WrapAdapter (undeployed) | Documented — remove the `msg.value==0` balance fallback in the fleet rewrite. |
| info | ASP | agent-card | **FIXED** — uses `PUBLIC_BASE_URL`, not the Host header. |
| 9,10,11,12,info | ASP/telemetry | Documented hardening — x402 fail-closed option, telemetry reorg buffer + cancellation-by-nonce, `/simulate` + `/quote` rate limiting, `/intents` privacy. Cheap follow-ups before real traffic. |

**Contract suite: 168 tests, 0 failures.** The single highest-priority item is operational, not code:
**do not trust the deployed Legacy processor with real value** — it is replaced by Design C after the
external audit.
