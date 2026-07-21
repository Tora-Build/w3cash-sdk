---
name: w3cash-intent-compiler
description: >-
  Compile natural-language on-chain goals into non-custodial, ready-to-sign
  W3Cash intents via the W3Cash MCP server, then sign and execute them. Works on
  Base Sepolia (chain 84532, full DeFi action set), X Layer testnet (chain 1952,
  minimal core), and X Layer MAINNET (chain 196, minimal core, REAL funds). Use
  whenever the user wants an on-chain action that runs
  "only when" a condition holds — e.g. "swap 100 USDC to WETH when ETH drops
  below $3000", "send 0.1 USDT0 to 0x… when my wallet holds at least 1", "bridge
  when gas is cheap", DCA / buy-the-dip / stop-loss, or any time-, price-,
  balance-, gas-, co-signer-, or market-gated transfer / swap / approve / wrap /
  bridge / Aave action. Handles decimal→base-unit conversion, and can sign
  keylessly with an OnchainOS Agentic Wallet. Requires the `w3cash` MCP server
  (tools `w3cash_*`); signing/executing also uses `onchainos` and/or `cast`.
---

# W3Cash Intent Compiler

W3Cash turns a structured goal into a **non-custodial, signable on-chain intent**.
You (the agent) describe *what* to do and *when*; W3Cash returns the exact bytes
to sign and submit. It **never holds keys and never signs** — you sign and execute.

## The model: "do X only when Y"

An intent is **conditions** + **actions**:

- **Conditions (Y)** are gates. ALL must be satisfied, in order, before anything runs.
- **Actions (X)** run in array order, but only once every gate passes.

On-chain adapters enforce the gates; no keeper can run the actions early, and the
gate is re-checked on-chain at `execute()` time — nothing is "watched" off-chain.

## Chains & deployments

Pass the target `chain` to every tool (default `84532`). Always call
`w3cash_capabilities` **for that chain** first — the catalog is filtered to what
the chain actually deploys, and returns that chain's processor + adapter addresses.

| Chain | id | Processor | Action set |
| --- | --- | --- | --- |
| Base Sepolia | `84532` | `0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE` | full: transfer, approve, swap, aave*, wrap, bridge |
| X Layer testnet | `1952` | `0x3C06E44bD4d09328a4c374174b8e325c0C674b6E` | minimal core: transfer, approve (+ all gates). NO swap/aave/wrap/bridge |
| **X Layer mainnet** | `196` | `0x3C06E44bD4d09328a4c374174b8e325c0C674b6E` | minimal core (same as testnet) — **REAL funds**. USD₮0 = `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` |

Every condition (time / block / price / balance / query / gas / co-signer /
market) is available on **all three** chains. X Layer USD₮0 is `0x9e29…` on
testnet and `0x779Ded…` on mainnet (both 6 decimals). The X Layer core lives at
the **same addresses** on 1952 and 196 (deterministic deploy).

## Tools

| Tool                    | When to use                                                                 |
| ----------------------- | --------------------------------------------------------------------------- |
| `w3cash_capabilities`   | **ALWAYS FIRST**, with the target `chain`. Learn the exact types + fields.  |
| `w3cash_simulate_intent`| **FREE dry-run BEFORE compiling** — "would it fire / which gate blocks / what setup you need". |
| `w3cash_compile_intent` | Compile `{chain, initiator, nonce, conditions[], actions[]}` → signable intent. |
| `w3cash_bridge_quote`   | Preview a live Across quote before a cross-chain `bridge` (Base Sepolia).    |
| `w3cash_recipes`        | Ready-to-edit templates for the given `chain`.                              |
| `w3cash_cancel_all`     | Get the one-tx `incrementNonce()` calldata to invalidate ALL outstanding intents. |

## Amounts & decimals (convert yourself — never ask the user for base units)

Token `amount` and balance `threshold` fields are **base units** (smallest unit).
The user speaks in whole/decimal tokens; you convert using the token's decimals:

| Token | Decimals | Example |
| --- | --- | --- |
| USD₮0 (X Layer `0x9e29b3aada05bf2d2c827af80bd28dc0b9b4fb0c`) | 6 | `0.1 → 100000`, `1 → 1000000` |
| USDC | 6 | `100 → 100000000` |
| WETH | 18 | `0.5 → 500000000000000000` |
| any other ERC20 | read it | `cast call <token> "decimals()(uint8)" --rpc-url <rpc>` |

Chainlink `targetPrice` values are **8-decimal** integers (`$3000 → "300000000000"`).

## Be interactive — ask, don't guess

If the user's goal is missing or ambiguous on any **critical** field — amount,
token, recipient, chain, or the condition — ask ONE short clarifying question
before compiling. Never guess amounts or addresses.

- **Chain** not stated → ask (`84532` Base Sepolia or `1952` X Layer), or infer
  from the token if unambiguous (e.g. USD₮0 ⇒ X Layer).
- **Recipient** looks truncated / like an ENS-less placeholder → confirm the full address.
- **Amount / token** missing → ask; do not assume.
- **Action not available on the chosen chain** (e.g. `swap` on X Layer) → say so
  and offer the nearest supported alternative or the other chain.

Keep questions brief. Once you have what you need, proceed without extra chatter.

## Workflow (fast by default — aim for the fewest steps)

For a clear, complete execution request (amount, recipient, chain, condition all
given) do EXACTLY this — no extra tool calls:

1. **Compile.** Call **`w3cash_compile_intent`** with `{ chain, initiator, conditions, actions }`,
   converting human amounts to base units per the table above. **OMIT `nonce`** — it
   defaults to 0, which is correct unless the initiator has called `incrementNonce()`.
   Take `nonce`, `toSign`, and `instruction` straight from the result.
2. **Execute** via the Fast path below (one call). Done.

Skip these unless actually needed:
- **`w3cash_capabilities`** — only call it if you're unsure of a field name; the
  catalog above already lists every type + field. Don't call it for a routine intent.
- **Reading the nonce with `cast`** — don't; use the compiled `nonce` (0 by default).
  Only read it (and recompile) if an execute reverts `InvalidNonce`.
- **A separate balance re-check** — don't; the execute receipt + explorer link is the proof.

## Action & condition catalog

- **Actions:** `transfer`, `approve`, `swap` (Uniswap V3), `aaveDeposit`,
  `aaveWithdraw`, `aaveWithdrawAll`, `wrap` (ETH↔WETH), `bridge` (Across, ERC20).
  *(On X Layer only `transfer` + `approve` are deployed.)*
- **Conditions:** `waitTime`, `waitBlock`, `waitPriceGte`, `waitPriceLte`,
  `balance`, `price`, `query`, `timeRange`, `gasPrice`, `signature`,
  `marketResolved`, `marketOutcome`.

Many actions need a **prior token approval** to the adapter (transfer, swap,
aaveDeposit, aaveWithdraw*, bridge). `w3cash_capabilities` marks
`requiresPriorApprove` per action — surface it and, if missing, do the approve
first (approve exactly the amount the action needs — see Security).

## Sign → execute (two commands — this IS the fast path)

`w3cash_compile_intent` returns `toSign` (the **32-byte EIP-191 personal-sign
message** the `initiator` signs) and `instruction` (the assembled bytes). Just two
standard commands — no bespoke scripts:

**1. Sign** `toSign` as **raw bytes** (EIP-191 personal sign):

- *OnchainOS Agentic Wallet (keyless — no private key):*
  `onchainos wallet sign-message --message <toSign> --chain <chainId> --from <initiator> --type personal --force`
  → take `data.signature`. This signs the raw 32 bytes under the EIP-191 prefix,
  exactly what the processor verifies (confirmed on X Layer 1952). No key exported.
- *Any other wallet:* personal-sign `toSign` as raw bytes with your own signer
  (viem: `signMessage({ message: { raw: toSign } })`).

**2. Execute** — assemble the payload and submit in **one** command:

```
cast send <processor> "execute(bytes)" \
  $(cast abi-encode "f((bytes,address,uint256,bytes))" "(<instruction>,<initiator>,<nonce>,<signature>)") \
  --private-key <gasPayerKey> --rpc-url <rpc>
```

**GAS — never ask who pays.** The submitter pays gas; use a funded **relayer key by
default** — in this environment `RELAYER_PRIVATE_KEY` from the env or `./.env`
(`--private-key $(grep RELAYER_PRIVATE_KEY .env | cut -d= -f2-)`), so run from a
directory that has that `.env` (e.g. `~/Sooth/w3cash-sdk/apps/asp`). Do NOT prompt
for a wallet, a private key, or which account pays gas.

**Anyone may submit** `execute()` — the adapters enforce every gate first. Don't
re-verify balance; the tx hash + explorer link (`https://www.oklink.com/xlayer-test/tx/<hash>`
for 1952) is the proof. If the gate isn't met, `execute()` succeeds but does
nothing (a no-op) — re-submit later when it flips true.

## Security: replay & how to bound it

`execute()` **verifies but does not consume** the outer nonce, and the signed
payload is **public in the tx calldata** once submitted. So a compiled signature
stays **replayable** — anyone can re-run it until the initiator advances the nonce
(bounded by the token allowance you granted).

The *proper* fix is **contract-level** (consume the nonce per execute, mark the
intent hash used, or embed a signed deadline) — a hardening item; a stateless
compiler cannot enforce it. What the **caller** must do:

1. **Bounded approvals only** — never unlimited. Approve exactly the action's
   amount; damage is capped at the allowance. The compiled result now returns an
   `exposure` array (worst-case per-execution outflow per token) and flags any
   unlimited approval in `warnings` — relay it.
2. **Cancel is coarse** — `nonces` is ONE counter per user, shared by all their
   intents. `incrementNonce()` invalidates **every** intent at the current nonce
   at once; there is no per-intent cancel. Use **`w3cash_cancel_all`** to fetch
   the ready-to-send `incrementNonce()` calldata (`{ to, data, value }`) for the
   chain; the initiator signs+submits it from its own wallet. (A signed payload
   is also public in the tx calldata after the first submit.)
3. **Expiry — safe by default, non-blocking.** The ASP now **auto-adds** an
   absolute expiry to every compiled intent (short for one-shot, ~30d for a
   triggered gate, until-target+grace for scheduled, effectively unbounded for
   market-gated). You do NOT need to add a `timeRange` yourself and must NOT pause
   to ask about it. The result carries `expiry` (`{ applied, endTime, className }`)
   — surface it in your final summary. To widen/narrow it, pass
   `expiry: <seconds>`; to disable it entirely (rarely — it removes the time
   bound), pass `expiry: "none"`.

Relay `warnings` + `expiry` + `exposure` in the final summary — as information,
not a blocking question.

## Worked examples

**Base Sepolia — "Swap 100 USDC to WETH only when ETH is below $3000":**

```json
{
  "chain": 84532,
  "initiator": "0xUserWallet",
  "conditions": [
    { "type": "waitPriceLte", "feed": "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1", "targetPrice": "300000000000" }
  ],
  "actions": [
    { "type": "swap", "tokenIn": "0x036CbD53842c5426634e7929541eC2318f3dCF7e", "tokenOut": "0x4200000000000000000000000000000000000006", "amountIn": "100000000", "minAmountOut": "0", "fee": 3000 }
  ]
}
```

**X Layer testnet — "Send 0.1 USDT0 to 0xEfdB… only when my wallet holds ≥ 1 USDT0"**
(USD₮0 has 6 decimals → `0.1 = 100000`, `1 = 1000000`):

```json
{
  "chain": 1952,
  "initiator": "0xe403…4ab3",
  "conditions": [
    { "type": "balance", "token": "0x9e29b3aada05bf2d2c827af80bd28dc0b9b4fb0c", "target": "0xe403…4ab3", "operator": "gte", "threshold": "1000000" }
  ],
  "actions": [
    { "type": "transfer", "token": "0x9e29b3aada05bf2d2c827af80bd28dc0b9b4fb0c", "to": "0xEfdB…aA74F", "amount": "100000" }
  ]
}
```

Then sign `toSign` (keyless via the OnchainOS Agentic Wallet) and submit
`execute()`. The initiator must have approved the TransferAdapter for the amount.
