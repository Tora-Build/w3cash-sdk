# W3Cash Intent Compiler — 90-second demo kit

**One-liner:** an OKX.AI **A2MCP ASP** that turns any agent's plain request into a
**ready-to-sign, conditional on-chain automation** — non-custodial. The agent's
Agentic Wallet signs and executes. "Every on-chain action, as an agent skill."

- **Live endpoint:** `https://146-103-42-69.sslip.io`
- **Proven on-chain (Base Sepolia):**
  - transfer — [`0xdc570c21…e056f8e6`](https://sepolia.basescan.org/tx/0xdc570c21b7973d14725061966e1bbb7e98329d380001b3cc267810f9e056f8e6)
  - **wait-gated conditional** — [`0x57ceeef6…c7a3d80b2`](https://sepolia.basescan.org/tx/0x57ceeef67259e71bdca35d2f02db2259c00a7351c33eece8ef9f2f1c7a3d80b2)

---

## 90-second storyboard

| Time | Scene | Show |
|---|---|---|
| 0:00–0:12 | **Hook** | "AI agents can chat, but they can't *do* complex on-chain automations. W3Cash makes 'every on-chain action' a skill any agent can call." |
| 0:12–0:35 | **Discover** | `curl .../capabilities` — 7 actions × conditions, live adapter catalog. "One API, deposit/swap/transfer/… gated by price/time/balance." |
| 0:35–1:05 | **Compile** | `curl .../compile-intent` with "swap-when-price / wait-then-transfer" → returns the encoded intent + the exact `toSign`. "Non-custodial — we never hold keys; the agent's OKX Agentic Wallet signs this." |
| 1:05–1:25 | **Execute (real)** | Open the Basescan tx — the *same* kind of intent, signed + `execute()`'d, **1 USDC moved on-chain**, condition gate and all. |
| 1:25–1:30 | **Close** | "Listed on OKX.AI, paid per call via x402. An agent skill that actually moves money." |

---

## On-camera commands (copy/paste, all hit the LIVE endpoint)

```bash
URL=https://146-103-42-69.sslip.io

# 1) Capabilities
curl -s $URL/capabilities | jq '.capabilities | {chainId, actions: [.actions[].type], conditions: [.conditions[].type]}'

# 2) Compile a conditional intent: wait, then transfer 1 USDC (non-custodial)
curl -s -X POST $URL/compile-intent -H 'content-type: application/json' -d '{
  "chain": 84532,
  "conditions": [{"type":"waitTime","timestamp":1}],
  "actions": [{"type":"transfer","token":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","to":"0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3","amount":"1000000"}]
}' | jq '{ok, steps: [.intent.steps[].summary], toSign: .intent.toSign}'
```

Then cut to the Basescan tx to show a real execution of exactly this shape.

*(Optional live execution on camera — needs the relayer key locally:*
`WAIT_UNTIL=1 npx tsx scripts/execute-demo.ts` *→ prints the `✅ REAL EXECUTION PROVEN` line and a fresh tx hash.)*

---

## X post (≤ the 90s clip), tag **#OKXAI**

> Meet the W3Cash Intent Compiler — an #OKXAI ASP that turns any agent request into a
> ready-to-sign, *conditional* on-chain automation. Non-custodial: the agent's Agentic
> Wallet signs & executes. Live, and already moving real USDC on-chain. 🧵👇
>
> • 18 actions × conditions (price/time/balance/health-factor)
> • A2MCP, pay-per-call via x402
> • Proven end-to-end on Base Sepolia
> [demo video] [basescan tx] [endpoint]

---

## Notes
- Endpoint is the interim `sslip.io` HTTPS host; swaps to `asp.w3.cash` once DNS is set (one endpoint update on OKX).
- `jq` optional — drop it if not installed; the raw JSON is readable.
