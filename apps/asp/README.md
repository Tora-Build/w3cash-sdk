# W3Cash Intent Compiler (ASP)

A non-custodial **A2MCP** endpoint for OKX.AI OnchainOS. It compiles a structured
request into a **signable W3Cash intent** for the `W3CashProcessor` on **Base
Sepolia (chainId 84532)**. It returns the exact 32-byte message the initiator must
sign — **it never signs, never holds keys, and never broadcasts.**

- **Free by default; x402-ready.** The endpoint is free and unauthenticated out of the
  box. A pay-per-call **x402** tier (0.01 USD₮0 on X Layer) is fully wired and one flag
  away: set `X402_ENABLED=true` with the OKX/`NETWORK`/`PAY_TO_ADDRESS` vars from
  `.env.example` and `POST /compile-intent` returns an `HTTP 402 PAYMENT-REQUIRED`
  challenge (see `src/x402.ts`).

## What this is (the A2MCP model)

**A2MCP** = *Agent-to-Agent Model Context Protocol*: a marketplace agent (e.g. OKX
OnchainOS) calls this service as a *tool* over plain HTTP+JSON to obtain onchain
capabilities it doesn't implement itself. This ASP (Agent Service Provider) exposes
one core capability — **compile a W3Cash intent** (8 action types × 12 condition types
over 11 on-chain-verified adapters) — plus discovery (`/capabilities`, `/recipes`) and
health probes:

```
  ┌────────────────────┐     POST /compile-intent      ┌──────────────────────┐
  │  Calling agent      │  {conditions[], actions[]}    │  W3Cash Intent        │
  │  (OKX OnchainOS,    │ ────────────────────────────► │  Compiler ASP         │
  │   a relayer, a bot) │                               │  (this service)       │
  │                     │ ◄──────────────────────────── │  • non-custodial      │
  └─────────┬──────────┘   { toSign, instruction, … }   │  • pure encoder       │
            │                                            └──────────────────────┘
            │  1. sign `toSign` (EIP-191 personal_sign) with the initiator key
            │  2. assemble SignedPayload = (instruction, initiator, nonce, sig)
            ▼
  ┌────────────────────┐   execute(SignedPayload)       ┌──────────────────────┐
  │  Relayer / EOA      │ ────────────────────────────► │  W3CashProcessor      │
  └────────────────────┘                                │  (Base Sepolia)       │
                                                         └──────────────────────┘
```

The ASP does the one thing an agent can't safely guess: the **exact byte layout** of
the operation tuple, the payload/header/instruction envelope, and the EIP-191
`toSign` preimage — ported 1:1 from `W3CashProcessor.sol` and the deployed adapters.
Signing and broadcasting stay entirely on the caller's side.

## Quickstart

```bash
pnpm i           # or: npm install
cp .env.example .env
pnpm dev         # tsx watch src/server.ts  (default PORT=4000)
```

Build / test / typecheck:

```bash
pnpm build       # tsc -> dist/
pnpm test        # vitest run  (golden-vector + round-trip + endpoint suite)
pnpm typecheck   # tsc --noEmit
```

## Endpoints

All responses are JSON with the shape `{ ok: boolean, ... }`. Errors are
`{ ok: false, error, code }` (`code` ∈ `VALIDATION | BAD_JSON | BAD_REQUEST |
NOT_FOUND | INTERNAL`). CORS is wildcard-open for GET/POST so marketplace agents
can call cross-origin.

### `GET /health`

```bash
curl localhost:4000/health
# {"ok":true,"service":"w3cash-intent-compiler"}
```

### `GET /capabilities`

Lists supported actions/conditions, the operator enum, and the deployed adapter
catalog (with `deployed` flags).

```bash
curl localhost:4000/capabilities
```

### `GET /recipes`

Ready-to-POST request bodies for common automations (DCA, buy-the-dip, Aave
stop-loss, cross-chain sweep, prediction-gated withdraw), plus the replay/cancel
caveat as a first-class field.

```bash
curl localhost:4000/recipes
```

### `POST /quote/bridge`

Returns a **live Across quote** (`outputAmount`, `quoteTimestamp`, `fillDeadline`,
deposit limits) for a cross-chain transfer, so a `bridge` action can be filled
without computing fees. Body: `{ inputToken, destinationChainId, inputAmount, outputToken?, recipient? }`.
(The same fetch runs inline when a `bridge` action sets `autoQuote: true`.)

```bash
curl -X POST localhost:4000/quote/bridge -H 'Content-Type: application/json' \
  -d '{"inputToken":"0x036CbD53842c5426634e7929541eC2318f3dCF7e","destinationChainId":11155111,"inputAmount":"5000000"}'
```

### `POST /compile-intent`

Compiles the intent. Body:

```jsonc
{
  "chain": 84532,        // optional; must resolve to Base Sepolia (84532) or local index 0
  "nonce": 0,            // signer's CURRENT on-chain Processor.nonces(initiator)
  "seq": 0,              // optional resumption cursor; must be 0 <= seq < op count
  "initiator": "0x…",    // optional; echoed into humanSummary only
  "conditions": [ … ],   // gate steps, run FIRST
  "actions": [ … ]       // executed after conditions pass
}
```

Example (conditional transfer — wait until a timestamp, then transfer 1 USDC):

```bash
curl -X POST localhost:4000/compile-intent \
  -H 'Content-Type: application/json' \
  -d '{
    "chain": 84532,
    "nonce": 0,
    "conditions": [{ "type": "waitTime", "timestamp": 1 }],
    "actions": [{
      "type": "transfer",
      "token": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
      "to": "0x000000000000000000000000000000000000dEaD",
      "amount": "1000000"
    }]
  }'
```

Response (abridged — `{ ok: true, intent }`):

```jsonc
{
  "ok": true,
  "intent": {
    "chainId": 84532,
    "processor": "0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE",
    "nonce": "0",
    "seq": "0",
    "operations": ["0x…", "0x…"],       // one abi.encoded Command tuple per step
    "inputs": ["0x…", "0x…"],           // per-adapter calldata per step
    "header": "0x…",
    "payload": "0x…",
    "payloadHash": "0x…",
    "instruction": "0x…",
    "toSign": "0xce3786746701f4a1ce694c49980a5831faf9d304ddc3a3f137337ed27b853016",
    "signing": {
      "scheme": "eip191-personal-sign",
      "messageHash": "0xce37…3016",
      "nonce": "0",
      "replayable": true,
      "signedPayloadFormat": "execute(abi.encode((bytes instruction, address initiator, uint256 nonce, bytes signature)))",
      "note": "Sign `toSign` as an EIP-191 personal message …"
    },
    "steps": [ { "index": 0, "kind": "condition", "type": "waitTime", … } ],
    "humanSummary": [ "Chain: Base Sepolia (84532); …" ],
    "warnings": [ "REPLAYABLE SIGNATURE: …" ]
  }
}
```

Field meanings:

| Field | Meaning |
|-------|---------|
| `operations[]` | `abi.encode(uint8 chain, uint8 amb, uint64 fee, address target, bytes8 selector, uint112 value)` per step. Local routing is by `target` **address**. |
| `inputs[]` | Per-adapter `abi.encode(...)` calldata for step `i`. |
| `header` | `abi.encode(uint256 seq, uint256 length, bytes32 payloadHash)`. |
| `payload` | `abi.encode(bytes[] operations, bytes[] inputs)`. |
| `payloadHash` | `keccak256(payload)`. |
| `instruction` | `abi.encode(bytes header, bytes payload)` — the `SignedPayload.instruction`. |
| `toSign` | **The raw 32-byte message to sign** = `keccak256(abi.encodePacked(payloadHash, nonce))`. Depends on the nonce. |
| `signing` | `{ scheme, messageHash, nonce, replayable, signedPayloadFormat, note }`. |
| `steps[]` | Human-readable per-step `{ index, kind, type, adapter, target, value, operation, input, summary }`. |
| `warnings[]` | Includes the **replay caveat** (always), not-deployed-adapter flags, native-value totals, and seq-skip notes. |

Example validation error:

```bash
curl -X POST localhost:4000/compile-intent -H 'Content-Type: application/json' -d '{}'
# 400 {"ok":false,"error":"intent must contain at least one action or condition","code":"VALIDATION"}
```

## Supported actions

Conditions run **first** (they gate the actions); actions run after every condition
is met. `value?` is optional native ETH (wei) forwarded to the op. "Prior approve"
means the initiator must `approve(adapter, …)` the relevant token **to the adapter**
(not the Processor) before `execute()`.

| `type` | Adapter | Fields | Prior approve? |
|--------|---------|--------|----------------|
| `transfer` | TransferAdapter | `token, to, amount, value?` | yes — of `token` |
| `approve` | ApproveAdapter | `token, spender, amount, value?` | no (sets allowance from the adapter's context) |
| `swap` | SwapAdapter | `tokenIn, tokenOut, amountIn, minAmountOut, fee, value?` | yes — of `tokenIn` (Uniswap V3 `exactInputSingle`) |
| `aaveDeposit` | AaveAdapter | `token, amount, value?` | yes — of the underlying (selector `0x47e7ef24`) |
| `aaveWithdraw` | AaveAdapter | `token, amount, value?` | yes — of the aToken (selector `0xf3fef3a3`) |
| `aaveWithdrawAll` | AaveAdapter | `token, value?` | yes — of the aToken (selector `0xfa09e630`) |
| `wrap` | WrapAdapter | `isWrap, amount, value?` | `isWrap=false` (WETH→ETH) needs prior WETH approve; `isWrap=true` forwards ETH via `value` (defaults to `amount`) |
| `bridge` | BridgeAdapter | `recipient, destinationChainId, inputToken, inputAmount` + either `outputAmount, quoteTimestamp, fillDeadline` **or `autoQuote: true`** | yes — of `inputToken`. Across `depositV3`, ERC20-only. Set **`autoQuote: true`** and the ASP fetches the live Across quote (outputAmount/quoteTimestamp/fillDeadline) for you; or supply them yourself (standalone quote at `POST /quote/bridge`) |

## Supported conditions

| `type` | Adapter | Fields | Notes |
|--------|---------|--------|-------|
| `waitTime` | WaitAdapter | `timestamp` | met when `block.timestamp >= timestamp` |
| `waitBlock` | WaitAdapter | `blockNumber` | met when `block.number >= blockNumber` |
| `waitPriceGte` | WaitAdapter | `feed, targetPrice` | Chainlink price `>= targetPrice` (no staleness check) |
| `waitPriceLte` | WaitAdapter | `feed, targetPrice` | Chainlink price `<= targetPrice` (no staleness check) |
| `balance` | QueryAdapter | `token, target, operator, threshold` | `balanceOf(target)` compare. Native ETH (no `token`) is rejected — use a WETH balance instead |
| `price` | QueryAdapter | `feed, operator, targetPrice, checkStaleness?` | Chainlink `latestAnswer()` compare (unsigned; negative prices rejected) |
| `query` | QueryAdapter | `target, calldata, operator, expected` | `staticcall(target, calldata)` decoded as a single `uint256`, compared unsigned |
| `timeRange` | TimeRangeAdapter | `startTime, endTime, recurring` | one-time absolute window, or (`recurring`) a daily UTC hour window with overnight wrap |
| `gasPrice` | GasPriceAdapter | `operator, threshold` | gate on `tx.gasprice` vs a wei threshold |
| `signature` | SignatureAdapter | `requiredSigner, actionHash, deadline, signature` | **2nd-approver gate** — a co-signer's ECDSA approval with replay protection + deadline; makes an intent single-use (mitigates the replay caveat). Use the exported `signatureMessageHash` helper for what to sign |
| `marketResolved` | QueryAdapter | `market` | met once a **Sooth `TruthMarket`** `isSettled()` — gate an intent on a prediction market resolving |
| `marketOutcome` | QueryAdapter | `market, outcome` | met when the market's `winningOutcome()` equals `outcome` (`YES`/`NO`/`INVALID` or 0/1/2) |

`operator` accepts a name or its numeric code: `lt`=0, `gt`=1, `lte`=2, `gte`=3,
`eq`=4, `neq`=5.

## Non-custodial signing flow

The ASP returns **no signature**. To execute a compiled intent:

```ts
// 1. Sign toSign as an EIP-191 personal message (raw 32 bytes).
const signature = await account.signMessage({ message: { raw: intent.toSign } });
// signature is 65 bytes r||s||v.

// 2. Assemble execute()'s argument.
const signedPayload = encodeSignedPayload({
  instruction: intent.instruction,
  initiator,          // the signer
  nonce: BigInt(intent.nonce),
  signature,
});

// 3. Call the Processor.
await wallet.writeContract({
  address: PROCESSOR,
  abi: parseAbi(["function execute(bytes) payable"]),
  functionName: "execute",
  args: [signedPayload],
  value: /* total native ETH forwarded across ops, see warnings */ 0n,
});
```

### Caveats

- **Replayable until `incrementNonce()`.** `execute()` verifies but does **not**
  consume the nonce, so a captured signature can be re-executed by anyone until the
  initiator calls `incrementNonce()`. Damage is bounded by the token allowance
  granted to each adapter — **do not sign or grant open-ended/unlimited approvals.**
  This caveat is surfaced in every response's `warnings[]` and `signing`.
- **Approvals are per-adapter.** `transfer`/`swap`/`aaveDeposit`/`aaveWithdraw` pull
  tokens *from the initiator via the adapter*, so the initiator must approve the
  **adapter** (not the Processor) for the relevant token first.

## Deployed contracts (Base Sepolia, chainId 84532)

Processor: `0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE`

All 11 adapters are deployed on Base Sepolia; each address + `adapterId` was verified
on-chain (the upstream W3Cash SKILL.md/README address tables are unreliable — they
contain dead and double-claimed entries):

| Adapter | Address |
|---------|---------|
| Transfer | `0x6cA85B548d3512E355B63Fb390dBD197CF72d5eA` |
| Approve | `0x1ff4459D35E956BA999ECf80C20Ad559904398A0` |
| Swap (Uniswap V3) | `0x9952735758c18d00D3cf2D1D0985A93b265a2126` |
| Aave | `0xC330e841A259E8211D1Ea84c60efD8657DB1D546` |
| Wrap (ETH↔WETH) | `0xD9142Ae0fCf4Fe81b39cD196BC37C9675DC86516` |
| Bridge (Across) | `0x3502362cAB171ffF2bF094fC70FD5977c9AD7090` |
| Wait | `0x8448b5f4abD40830C3B980390AbcfD2822719061` |
| Query (backs `balance`/`price`/`marketResolved`/`marketOutcome`) | `0x4bC2F784CC76989dA6760Bc6bFCDc3F75c49ee9F` |
| TimeRange | `0xCC18E7E2283D3067B30D0e9a3Ba189FE25dB62EB` |
| GasPrice | `0x07DcD715DdAB18D449b10BB6140916e8a0F7f657` |
| Signature | `0xEEe61780cC5fC62B7017E46BB7f6b27fD8BAfBEe` |

`balance`, `price`, `marketResolved`, and `marketOutcome` all compile to the deployed
**QueryAdapter** (a generic `staticcall` view-gate), so no separate Balance/Price
adapter is needed.

## Deploy notes (VPS + HTTPS)

The service is a stateless Node process; any small VPS works. Put it behind a
reverse proxy that terminates TLS — A2MCP callers require an `https://` origin.

```bash
# On the VPS
git clone <repo> && cd apps/asp
npm ci
npm run build
cp .env.example .env       # set PORT (default 4000); leave x402 vars blank in phase-1

# Run under a process manager so it restarts on crash/reboot
pm2 start dist/server.js --name w3cash-asp          # or a systemd unit / Docker
```

Terminate HTTPS with nginx (or Caddy/Traefik) in front of `PORT`:

```nginx
server {
  listen 443 ssl;
  server_name asp.example.com;            # + certbot/Let's Encrypt for the cert
  location / {
    proxy_pass http://127.0.0.1:4000;
    proxy_set_header Host $host;
  }
}
```

Self-check once it's live (this is what OKX A2MCP endpoint verification probes):

```bash
curl -s https://asp.example.com/health
# {"ok":true,"service":"w3cash-intent-compiler"}

curl -s https://asp.example.com/capabilities | head -c 200

curl -s -X POST https://asp.example.com/compile-intent \
  -H 'Content-Type: application/json' \
  -d '{"actions":[{"type":"aaveWithdrawAll","token":"0x036CbD53842c5426634e7929541eC2318f3dCF7e"}]}'
# {"ok":true,"intent":{ … "toSign":"0x…" … }}
```

Operational notes: the endpoint is public and unauthenticated in phase-1 — add a
per-IP rate limit at the reverse proxy (covering `/health` + `/capabilities` too)
before public exposure; the in-process `64kb` body cap and `MAX_STEPS=32` bound
worst-case CPU per request but are not a substitute for gateway rate limiting.

## Live smoke test

`scripts/verify-transfer.mjs` `eth_call`s the deployed Processor with a compiled
conditional-transfer intent to prove the envelope decodes, the signature verifies,
and routing reaches both adapters. It is a network-dependent smoke test — the
deterministic regression guard is `pnpm test`.

```bash
npx tsx scripts/verify-transfer.mjs
```
