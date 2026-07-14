#!/usr/bin/env bash
# W3Cash Intent Compiler — one-shot demo runner (hits the LIVE endpoint).
# Usage: bash scripts/demo.sh [ENDPOINT_URL]
set -euo pipefail
URL="${1:-https://146-103-42-69.sslip.io}"
pp() { if command -v jq >/dev/null 2>&1; then jq "$1"; else cat; fi; }

echo "━━━ W3Cash Intent Compiler — live at $URL ━━━"; echo

echo "▶ 1. Capabilities — one API, actions × conditions"
curl -s "$URL/capabilities" | pp '.capabilities | {chainId, actions: [.actions[].type], conditions: [.conditions[].type]}'
echo

echo "▶ 2. Compile a CONDITIONAL intent — wait, then transfer 1 USDC (non-custodial)"
curl -s -X POST "$URL/compile-intent" -H 'content-type: application/json' -d '{
  "chain": 84532,
  "conditions": [{"type":"waitTime","timestamp":1}],
  "actions": [{"type":"transfer","token":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","to":"0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3","amount":"1000000"}]
}' | pp '{ok, steps: [.intent.steps[].summary], toSign: .intent.toSign}'
echo

echo "▶ 3. The agent signs toSign with its Agentic Wallet and calls execute() — REAL on-chain:"
echo "     transfer     https://sepolia.basescan.org/tx/0xdc570c21b7973d14725061966e1bbb7e98329d380001b3cc267810f9e056f8e6"
echo "     wait-gated   https://sepolia.basescan.org/tx/0x57ceeef67259e71bdca35d2f02db2259c00a7351c33eece8ef9f2f1c7a3d80b2"
echo

echo "▶ 4. Monetized per call via x402 (0.01 USD₮0 on X Layer) — see DEMO.md."
echo "━━━ non-custodial · conditional · on OKX.AI ━━━"
