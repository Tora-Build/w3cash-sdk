# W3Cash — What Changed & Why (Hackathon → Now)

## 1. What W3Cash Is

W3Cash is a **non-custodial "intent compiler for AI agents."** You hand it a plain goal — *"swap 100 USDC to WETH, but only when ETH drops below $3,000"* — and it turns that into the exact, ready-to-sign transaction bytes. It never holds your keys and never signs for you.

The core idea is **"do X only when Y":**

- **X = ACTIONS** — moves or transforms funds (transfer, approve, swap, wrap, bridge, Aave deposit/withdraw).
- **Y = CONDITIONS (gates)** — must *all* be true first (time, block, price, balance, gas, a co-signer, or a prediction-market result).

Two things make it distinctive:

| Property | What it means in plain terms |
|---|---|
| **Local, single-user** | *You* sign the exact target and amounts. There is no solver, no counterparty, nobody who "fills" your order — so **no counterparty risk**. |
| **Conditions enforced on-chain** | Gates are re-checked at execution by small purpose-built contracts ("adapters"). Nothing is merely "watched" off-chain; **no keeper can run your action early**. |

It has two halves: an **off-chain compiler** (the ASP — Agent Service Provider — live at `asp.w3.cash`, callable by agents with pay-per-call billing) and an **on-chain processor** (an immutable, permissionless contract that verifies your signature, checks the gates, then routes each action to its adapter).

> **The single most important status fact:** the *deployed* on-chain contract is still the **hackathon "Legacy" version**. The hardened next-gen design ("Design C") is **built with green tests but NOT deployed and NOT audited.** Every on-chain improvement below is marked accordingly.

---

## 2. On-Chain Diff: Legacy (LIVE) → Design C (BUILT, not deployed)

**Legacy = `W3CashProcessorLegacy.sol`** — live on Base Sepolia (84532), X Layer testnet (1952), and **X Layer mainnet (196)**.
**Design C = `W3CashProcessor.sol`** — built this cycle, tests green, **not deployed, not audited.**

| Area | Legacy (LIVE) | Design C (BUILT, not deployed) | Why it changed |
|---|---|---|---|
| **Authorization** | One signature by the initiator authorizes everything. Signer = funds owner = only authority. | **Two signatures:** the *root* signs one **SessionGrant** delegating a spend-capped hot **session key**; the session key then signs each individual intent. | Lets an AI agent sign many intents keylessly with a hot key **without ever exposing the root funds owner's key.** |
| **Signature scheme** | EIP-191 `personal_sign`, **no domain** — not bound to any chain or contract. | **EIP-712 typed data**, domain = the execution chain. | Stops cross-chain / cross-contract signature replay; wallets can show structured data. |
| **Replay protection** | Nonce is **checked but never consumed** → a captured signature is **replayable by anyone** until you call `incrementNonce()`. | Per-intent counter with **maxRuns + cooldown + deadline**; counters reserved before actions. | Closes the replay footgun; also enables safe **recurring** intents (DCA) with a rate limit. |
| **Cancellation** | One nonce → `incrementNonce()` cancels **everything** at once. | **Three tiers:** passive grant expiry → `revokeSession` (one key) → `incrementEpoch` (nuclear cancel-all), plus per-intent `cancelIntent`. | Granular kill switches instead of all-or-nothing. |
| **Spend limits** | **None.** Adapters pull whatever your allowance permits. | Typed **Policy**: codehash-pinned adapter allowlist + verb mask + **per-token rolling-window caps**; deny-all by default. | Bounds worst-case loss per token/window and pins exactly which code and actions a session may invoke. |
| **Fund custody** | Each adapter calls `transferFrom(initiator)` **directly** on your wallet. | **SOLE-MOVER:** the processor pulls root funds into *itself* (via Permit2 or standing allowance), then *pushes* the exact amount to the adapter. Adapters never touch root funds. | A compromised adapter can no longer reach your funds; every outflow is metered at the processor. |
| **Balance threading** | None — each step pulls independently. | A transient per-execution ledger routes one step's real output into the next (e.g. swap → deposit). | Enables multi-leg strategies without extra pulls or extra caps. |
| **Flash loans** | Not supported. | A tightly scoped **flash frame**: one sub-group, no nesting, repaid from the frame, all transient state zeroed on exit. | Adds atomic leverage/refinance while keeping the callback unable to escape the signed plan. |
| **Root account type** | EOA only (`ecrecover`). | EOA **or ERC-1271 smart account** (Safe, Kernel, etc.). | Lets multisig/smart-account users be the funds owner. |
| **Keeper incentive** | Anyone can execute, but earns nothing. | Optional **gas-capped keeper tip** from a dedicated sub-budget; a failed tip never bricks the action. | Pays relayers to land time-sensitive protective intents. |
| **Op ordering** | Any order. | Strict **all GATES before all ACTIONS**; gates move no funds. | Guarantees conditions are fully checked before any money moves. |
| **Post-action safety** | Only a non-reverting "pause" pattern. | Pause for pre-action gates **plus** a `PostConditionAdapter` that **hard-reverts** on an unmet post-check (slippage/MEV guard). | Because gates must precede actions, slippage checks need a revert-on-fail action after the swap. |
| **Cross-chain** | Forwarded ops to other chains inside the processor via bridge endpoints. | **Removed from the core.** Bridging is now a normal ACTION (Across); multi-chain = deploy the same core per chain. | Simplifies the trust surface; moves bridging to an auditable adapter. |

---

## 3. Off-Chain Diff: the ASP Compiler (all LIVE)

Unlike the on-chain changes, these off-chain improvements **are deployed** at `asp.w3.cash`.

| Change | Before | After (live) | Why |
|---|---|---|---|
| **Chains** | Base Sepolia only, testnet. | Three chains: Base Sepolia (full action set), X Layer testnet, and **X Layer mainnet 196** (minimal core: transfer/approve + all gates). | X Layer is the OKX target; mainnet makes it a real, live execution surface. |
| **Payment** | Free endpoint. | **x402 pay-per-call** (~$0.01) on `/compile-intent`, settled in USD₮0. **Fails open to free** if misconfigured. | Monetizes the service as an agent-native API without risking uptime. |
| **MCP auto-pay** | No payment ability. | The MCP tool auto-pays 402-gated calls mid-tool-call. | An agent transparently pays the ASP without manual settlement. |
| **Safe-by-default compile** | No time bound, no exposure figure. | Auto-injects an **expiry** as the first gate, reports **per-token worst-case exposure**, flags unlimited approvals, and gives cancel guidance. | Bounds how long a (replayable, Legacy) signature stays live and shows the agent exactly what it's authorizing. |
| **Bigger action/gate set** | Smaller set; some stale adapters. | Added bridge, timeRange, gasPrice, co-signer, and Sooth prediction-market gates; balance/price re-routed to the deployed on-chain reader. | More expressible "do X only when Y" intents, using only on-chain-verified adapters. |
| **Server-side bridge quotes** | Caller supplied quote data. | ASP auto-fetches Across quotes and fills them in. | Removes a manual, revert-prone step. |
| **Boot hardening** | Bad payment config could crash boot. | All payment failure paths fall back to FREE; config is validated. | A misconfig must never take down the public compile endpoint. |

> **Important gap:** the *live compiler still targets the Legacy processor.* It emits nonce-based envelopes and honestly stamps every result **`replayable: true`**. There is **no encoder yet** for the Design C session-key processor — that's the main bridge left to build between the new contract and the live service.

---

## 4. Roles Table (new & changed)

| Role | Era | What it does | Status |
|---|---|---|---|
| **Initiator** | Hackathon | The single signer. Their EOA funds are pulled directly by adapters; their one nonce both gates and (via `incrementNonce`) cancels **all** flows. Authority + funds owner + rate-limiter in one. | baseline |
| **Root** | Design C | The funds owner and grantor (EOA or ERC-1271). Signs the **SessionGrant**. The **only** account whose funds move. Holds all kill switches (`revokeSession`, `incrementEpoch`, `cancelIntent`). | **changed** — splits "initiator" into root vs session key |
| **Session key** | Design C | A hot signer the root delegates to. Signs each intent, but confined by the Policy (codehash allowlist, verb mask, per-token caps). Cannot exceed caps or call un-pinned adapters. | **new** |
| **Keeper** | Design C | Whoever lands a time-sensitive intent; paid a gas-capped, best-effort tip from a dedicated sub-budget. A failed tip degrades to untipped. | **new** |
| **Relayer / executor** | Both | Anyone — `execute()` is permissionless in both eras. Legacy: earns nothing. Design C: is `msg.sender`, can collect the keeper tip and leftover native ETH. | **changed** — now incentivizable |
| **Co-signer / adjudicator gate** | Design C ASP | External truth providers surfaced as GATES: a 2nd-approver ECDSA co-signer, and Sooth prediction-market reads. Non-custodial — the ASP cannot produce these signatures. | **new** |

---

## 5. How Each Action Works + Lifecycle

### The actions (X)

| Action | In one sentence | Note |
|---|---|---|
| **transfer** | Send a fixed ERC-20 amount to a fixed address once gates pass. | Native ETH must be wrapped first. |
| **approve** | Grant a token allowance to a spender, gated. | Unlimited approvals are flagged as a top warning. |
| **swap** | Uniswap V3 swap with a slippage floor and fee tier. | Base Sepolia only. |
| **aave** | Deposit for yield, or withdraw / withdrawAll. | Base Sepolia only. |
| **wrap** | ETH ↔ WETH. | Base Sepolia only. |
| **bridge** | Move a token to another chain via Across. | Base Sepolia only; can auto-quote. |

### The gates (Y)

| Gate | Passes when… |
|---|---|
| **time** | `waitTime` = after a timestamp; `timeRange` = inside a daily or absolute window. |
| **block** | The chain reaches a target block number. |
| **price** | A Chainlink feed crosses your target (buy-the-dip / stop-loss / take-profit). *No staleness check.* |
| **balance** | A holder's token balance meets your threshold. |
| **gas** | The submitting tx's gas price meets your threshold (submitter-set, not an oracle). |
| **co-signer** | A required second approver has signed off (two-person control). |
| **prediction-market** | A Sooth market has resolved, or resolved to a specific outcome. |

### Lifecycle: COMPILE → SIGN → EXECUTE

1. **COMPILE (off-chain).** You send a goal `{chain, initiator, conditions[], actions[]}`. The compiler validates fields, converts human amounts to base units, picks the right deployed adapters, orders all gates before all actions, injects a safe-default expiry, computes worst-case exposure, and returns the bytes to sign plus a plain-language summary. Nothing is on-chain yet.

2. **SIGN (off-chain).**
   - *Legacy (live):* the initiator `personal_sign`s one 32-byte message — reusable until the nonce advances.
   - *Design C (built):* **two** EIP-712 signatures — root signs one SessionGrant (delegating a capped, revocable session key + a Policy hash); the session key signs each intent.

3. **EXECUTE (on-chain, permissionless).** Anyone submits it; the submitter pays gas.
   - *Legacy:* processor verifies the signature against your nonce, runs each gate read-only, and if all pass routes actions to adapters that pull your funds. A failed gate is a harmless no-op — retry later. The nonce isn't consumed, so the signature stays replayable.
   - *Design C:* processor verifies the grant, checks the Policy matches, verifies the session-key signature, enforces gate-before-action ordering, runs gates read-only (a failing gate **pauses with zero state writes** — resume later), then **reserves the spend against the cap**, acts as sole mover (pull → measure → push to the codehash-pinned adapter), threads outputs into the next step, pays the keeper tip best-effort, and sweeps leftover ETH.

---

## 6. Competitive Advantage (with honest trade-offs)

W3Cash's edge is its **trust/authorization model** — an immutable, non-custodial processor with spend-capped, revocable, codehash-pinned session keys and exact-target (no-solver) intents — **not** breadth of protocol coverage or battle-testing. Two caveats apply to *every* competitive claim: **(1)** the strongest security properties describe Design C, which is **unaudited and undeployed** — the live contract is still the replayable-nonce Legacy one; **(2)** liveness depends on whoever calls `execute()` — there are tips but **no keeper network yet.**

### vs. Automation / keeper networks (Gelato, Chainlink Automation, DeFi Saver, Instadapp, Enso)

| | W3Cash edge | Honest trade-off |
|---|---|---|
| **Gelato / Chainlink** | No custom contract to deploy, no gas tank / LINK to fund. Agent-native keyless signing; on-chain gates mean **no keeper can run your action early.** | They are live, decentralized, SLA-backed executor networks with far broader triggers. W3Cash has **no execution network** — liveness rests on whoever pays gas. |
| **DeFi Saver / Instadapp** | General-purpose (any action × any condition), not one vendor bot or one strategy; typed caps bound what a delegated key can ever do. | They're battle-tested with polished UX and deep coverage. W3Cash's **live real-funds deployment (X Layer mainnet) is transfer/approve only.** |
| **Enso** | The deliberate opposite of a router: **no solver, no fill, no route-quality/MEV risk** — you sign the exact target. | Enso unlocks thousands of protocols with best-path routing; W3Cash does no routing and its live action set is a small fraction. |

**Right framing:** W3Cash is the conditional-authorization *layer* that could sit **on top of** a keeper network for liveness — not a replacement for executor infrastructure.

### vs. Smart-account / AA session keys (Rhinestone Smart Sessions, ZeroDev, Biconomy, Safe+Zodiac, Argent)

W3Cash re-implements the AA world's best primitives — session keys, typed policies, per-token caps, revocation tiers, ERC-1271 — as a **standalone immutable processor any signer can delegate to.**

| | W3Cash edge | Honest trade-off |
|---|---|---|
| **Rhinestone / ZeroDev / Biconomy** | Works with a bare EOA today — **no account deploy, no module install, no asset migration, no bundler/paymaster dependency.** Immutable + codehash-pinned means policy semantics can't be silently upgraded. | You get **none of the AA payload** — no gas sponsorship, no arbitrary-call batching, no social recovery, no unified balance. Policy is a frozen target+verb+cap decoder, extendable only by redeploy. |
| **Safe + Zodiac Roles / Argent** | No Safe deploy or module-enable tx; a Safe can still be the ERC-1271 root grantor to delegate to a hot agent key. Condition-gated and recurring execution is first-class. | Zodiac offers richer per-parameter scoping; both are audited and live at scale. W3Cash containment is **amount-only, not destination-based** — a leaked session key can still send *capped* funds to an attacker. |

**The honest bottom line:** W3Cash is a **delegation-and-guardrails layer** that rides on whatever custody you already have — the right tool for spend-capped, revocable, condition-gated *autonomous* execution **without becoming a smart-account user**, and the wrong tool if you actually want a full programmable account. Its differentiation is architectural (immutability + any-signer + built-in conditions/recurring), **not yet proven in production.**
