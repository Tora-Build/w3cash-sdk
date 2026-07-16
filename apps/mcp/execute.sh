#!/usr/bin/env bash
# execute.sh — sign an ALREADY-COMPILED W3Cash intent with the OnchainOS Agentic
# Wallet (keyless) and relay execute() in one shot. Collapses the sign +
# abi-encode + send steps so an agent makes ONE call instead of several.
#
# Usage: execute.sh <chain> <initiator> <nonce> <toSign> <instruction>
#   <chain>       1952 (X Layer testnet) or 84532 (Base Sepolia)
#   <initiator>   the signer = the OnchainOS Agentic Wallet address
#   <nonce>       the intent's nonce (from the compiled intent)
#   <toSign>      the 32-byte hash to personal-sign (from the compiled intent)
#   <instruction> the instruction bytes (from the compiled intent)
#
# Gas payer: RELAYER_PRIVATE_KEY from the env, else ./.env in the current dir.
set -euo pipefail

CHAIN=${1:?chain}; INIT=${2:?initiator}; NONCE=${3:?nonce}; TOSIGN=${4:?toSign}; INSTR=${5:?instruction}

case "$CHAIN" in
  1952)  RPC=https://testrpc.xlayer.tech;               PROC=0x3C06E44bD4d09328a4c374174b8e325c0C674b6E ;;
  84532) RPC=https://base-sepolia-rpc.publicnode.com;   PROC=0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE ;;
  *) echo "execute.sh: unknown chain '$CHAIN' (use 1952 or 84532)" >&2; exit 1 ;;
esac

PK=${RELAYER_PRIVATE_KEY:-}
if [ -z "$PK" ] && [ -f ./.env ]; then
  PK=$(grep -E '^RELAYER_PRIVATE_KEY=' ./.env | cut -d= -f2- | tr -d ' "' || true)
fi
[ -z "$PK" ] && { echo "execute.sh: no RELAYER_PRIVATE_KEY (env or ./.env)" >&2; exit 1; }

# 1) keyless personal-sign via the OnchainOS Agentic Wallet (no private key exported)
SIG=$(onchainos wallet sign-message --message "$TOSIGN" --chain "$CHAIN" --from "$INIT" --type personal --force \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['signature'])")

# 2) assemble the SignedPayload and 3) relay execute()
SP=$(cast abi-encode "f((bytes,address,uint256,bytes))" "($INSTR,$INIT,$NONCE,$SIG)")
cast send "$PROC" "execute(bytes)" "$SP" --private-key "$PK" --rpc-url "$RPC" --json \
  | python3 -c "import sys,json;r=json.load(sys.stdin);print('execute tx:',r['transactionHash'],'| status:',r['status'],'| block:',int(r['blockNumber'],16))"
