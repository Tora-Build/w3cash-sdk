# W3Cash Intent Compiler — 90-second demo kit

**One-liner:** the **conditional-execution layer** for AI agents — an OKX.AI **A2MCP
ASP** that turns *"do X **only when** Y"* into a **ready-to-sign, self-executing
on-chain automation**, non-custodial. `Y` can be time, price, gas, a co-signer — or,
uniquely, **a prediction market resolving**. The agent's Agentic Wallet signs; a keeper
executes the moment the condition hits.

> **What it is / isn't.** Not another bridge, DEX, or lending app — those exist, and
> specialists (Across, Uniswap, Aave) execute them best, *right now*. We're the layer
> that makes any of them fire **only when your rule is met**, signed once. The gates are
> the product; the actions are commodity legs we compose. The one gate nobody else has:
> a market's outcome — because we own both the intent compiler **and** the truth layer.

- **Live endpoint:** `https://146-103-42-69.sslip.io`
- **Proven on-chain (Base Sepolia):**
  - transfer — [`0xdc570c21…e056f8e6`](https://sepolia.basescan.org/tx/0xdc570c21b7973d14725061966e1bbb7e98329d380001b3cc267810f9e056f8e6)
  - **wait-gated conditional** — [`0x57ceeef6…c7a3d80b2`](https://sepolia.basescan.org/tx/0x57ceeef67259e71bdca35d2f02db2259c00a7351c33eece8ef9f2f1c7a3d80b2)

---

## Commands to record (no narration — the output is the story)

```bash
URL=https://146-103-42-69.sslip.io

# 1) Capabilities — accurate counts + adapter catalog
curl -s $URL/capabilities | jq '.capabilities | {chainId, summary, counts, actions: [.actions[].type], conditions: [.conditions[].type]}'

# 2) Compile a conditional intent: wait, then transfer 1 USDC (non-custodial)
curl -s -X POST $URL/compile-intent -H 'content-type: application/json' -d '{
  "chain": 84532,
  "conditions": [{"type":"waitTime","timestamp":1}],
  "actions": [{"type":"transfer","token":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","to":"0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3","amount":"1000000"}]
}' | jq '{ok, steps: [.intent.steps[].summary], toSign: .intent.toSign}'

# 3) Prediction-gated withdraw: only transfer once a Sooth market resolves YES
curl -s -X POST $URL/compile-intent -H 'content-type: application/json' -d '{
  "chain": 84532,
  "conditions": [{"type":"marketOutcome","market":"0x80334C47F3DcE19FcFE7dB1AEce7423D32C4ccB1","outcome":"YES"}],
  "actions": [{"type":"transfer","token":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","to":"0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3","amount":"1000000"}]
}' | jq '{ok, steps: [.intent.steps[].summary]}'

# 4) Canned recipes (DCA, buy-the-dip, Aave stop-loss, cross-chain sweep, prediction-gated withdraw)
curl -s $URL/recipes | jq '.recipes | {replay: .replay.replayable, cancel: .replay.cancel, recipes: [.recipes[].id]}'
```

Then cut to the Basescan tx to show a real execution of exactly this shape.

*(Optional live execution on camera — needs the relayer key locally:*
`WAIT_UNTIL=1 npx tsx scripts/execute-demo.ts` *→ prints the `✅ REAL EXECUTION PROVEN` line and a fresh tx hash.)*

---

## Monetization — x402 (Revenue Rocket)

Free by default, but a **pay-per-call A2MCP** in one flag flip (`X402_ENABLED=true`).
With payments on, `POST /compile-intent` returns a standard **HTTP 402 +
`PAYMENT-REQUIRED`** — $0.01 in **USD₮0 on X Layer** — which the caller's Agentic
Wallet pays automatically, then the request replays. Verified live:

```json
{
  "x402Version": 2,
  "accepts": [{
    "scheme": "exact",
    "network": "eip155:1952",                               // X Layer testnet (mainnet: eip155:196)
    "amount": "10000",                                       // 0.01 USD₮0 (6 decimals)
    "asset": "0x9e29b3aada05bf2d2c827af80bd28dc0b9b4fb0c",   // USD₮0
    "payTo": "0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3"    // Agentic Wallet
  }]
}
```

Nice symmetry for the pitch: the ASP **gets paid via x402** while the intents it
compiles **move value on-chain** (transfer / swap / bridge) — a natural fit for the
agent payment economy. Built on OKX's `@okxweb3/x402-express` SDK.

---

## X post (≤ the 90s clip), tag **#OKXAI**

> Meet the W3Cash Intent Compiler — the #OKXAI **conditional-execution layer** for agents.
> Not another bridge/DEX — the thing that makes ANY of them fire *only when your rule hits*,
> signed once, non-custodial. Live, moving real USDC on Base Sepolia. 🧵👇
>
> • *"Do X only when Y"* — Y = time / price / gas / balance / co-signer / **a prediction market**
> • The flagship nobody else has: gate an intent on a Sooth market resolving YES
> • 12 condition types × 8 actions (incl. a *gated* Across bridge), A2MCP, pay-per-call via x402
> [demo video] [basescan tx] [endpoint]

---

## OKX.AI listing blurb (for the marketplace / Google form)

> **W3Cash Intent Compiler** — the conditional-execution layer for agents. Give it a goal
> as `{conditions, actions}` and it returns a ready-to-sign, self-executing on-chain intent:
> *"do X only when Y."* `Y` can be time, price, gas, balance, a co-signer — or, uniquely, a
> **Sooth prediction market resolving**. Non-custodial (never touches keys), pay-per-call via
> **x402** (0.01 USD₮0 on X Layer). It doesn't reimplement swaps or bridges — it **composes**
> best-in-class legs (Uniswap, Aave, **Across**) and makes them *conditional*. Live on Base
> Sepolia; 8 actions × 12 conditions over 11 on-chain-verified adapters.

## Where Across fits (and why we don't compete with it)

Across already serves agents directly (its `skills` + Swap API bridge across 24+ chains).
We don't try to be a better bridge — we **wrap** it: the `bridge` action is an Across
`depositV3` leg, auto-quoted live via Across's suggested-fees API, that fires **only when
your condition is met**. An agent uses Across to bridge *now*; it uses **us** to bridge
*when gas is cheap* or *after a market resolves*. **Across = execution; W3Cash = conditions.**

## Notes
- Endpoint is the interim `sslip.io` HTTPS host; swaps to `asp.w3.cash` once DNS is set (one endpoint update on OKX).
- `jq` optional — drop it if not installed; the raw JSON is readable.
