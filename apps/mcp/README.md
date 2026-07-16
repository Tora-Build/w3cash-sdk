# @w3cash/mcp

**MCP server for the W3Cash Intent Compiler ASP.** It lets any MCP-capable AI
agent — Claude Code, Cursor, Claude Desktop, OKX.AI / OnchainOS, etc. — compile
natural-language goals into **non-custodial, ready-to-sign on-chain intents** on
Base Sepolia, in plain language.

This is the agent-consumption layer. It is a thin proxy over the live ASP HTTP
API (`https://asp.w3.cash`): each MCP tool fetches one ASP endpoint and returns
its JSON. The ASP compiles intents and never holds keys — **the agent signs and
submits.** (The MetaMask playground is only a human visualizer; this is how
agents actually consume the service.)

The model is **"do X only when Y"**: a compiled intent runs its **actions (X)**
only after every **condition gate (Y)** is satisfied.

---

## Install (hosted — recommended)

The server is reverse-proxied at `https://asp.w3.cash/mcp`. Nothing to run
locally.

### Claude Code (CLI)

```bash
claude mcp add --transport http w3cash https://asp.w3.cash/mcp
```

### `.mcp.json` (Claude Code project scope / Cursor)

```json
{
  "mcpServers": {
    "w3cash": {
      "type": "http",
      "url": "https://asp.w3.cash/mcp"
    }
  }
}
```

### Claude Desktop (`claude_desktop_config.json`)

Claude Desktop reaches a remote HTTP MCP server through the `mcp-remote` bridge:

```json
{
  "mcpServers": {
    "w3cash": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://asp.w3.cash/mcp"]
    }
  }
}
```

> Config file locations — macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`,
> Windows: `%APPDATA%\Claude\claude_desktop_config.json`. Restart the app after editing.

The MCP endpoint itself lives at `POST https://asp.w3.cash/mcp`. The app also
serves a plain `GET /health` → `{"ok":true,"service":"w3cash-mcp"}` on its own
origin, used as the reverse proxy's upstream reachability probe.

---

## Install (local — stdio)

Run the compiled server as a local subprocess. Useful for development or when
you want to point at a different ASP via `ASP_BASE_URL`.

```bash
cd apps/mcp
npm install
npm run build          # tsc -> dist/
node dist/stdio.js     # speaks MCP over stdin/stdout
```

Register it with Claude Code:

```bash
claude mcp add w3cash -- node /absolute/path/to/apps/mcp/dist/stdio.js
```

…or in `.mcp.json` / `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "w3cash": {
      "command": "node",
      "args": ["/absolute/path/to/apps/mcp/dist/stdio.js"],
      "env": { "ASP_BASE_URL": "https://asp.w3.cash" }
    }
  }
}
```

Once published, the same server runs via `npx @w3cash/mcp` (the package `bin`).

### Environment

| Var            | Default                 | Purpose                                   |
| -------------- | ----------------------- | ----------------------------------------- |
| `ASP_BASE_URL` | `https://asp.w3.cash`   | Base URL of the ASP the tools proxy.      |
| `PORT`         | `4100`                  | HTTP transport listen port (`dist/http.js`). |

---

## Tools

| Tool                    | Args                                                                          | ASP endpoint           | Use it to…                                                                                       |
| ----------------------- | ----------------------------------------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------ |
| `w3cash_capabilities`   | `chain?`                                                                      | `GET /capabilities`    | **Call first.** List supported actions/conditions + exact field names, adapters, operators (for the chosen chain). |
| `w3cash_compile_intent` | `chain?`, `nonce?`, `initiator?`, `conditions?[]`, `actions?[]`               | `POST /compile-intent` | Compile a "do X only when Y" goal into `steps`, `toSign`, and `instruction` bytes to sign & run. |
| `w3cash_bridge_quote`   | `inputToken`, `destinationChainId`, `inputAmount`, `outputToken?`, `recipient?` | `POST /quote/bridge`   | Get a live Across quote for a cross-chain `bridge` action (outputAmount / deadlines).            |
| `w3cash_recipes`        | `chain?`                                                                      | `GET /recipes`         | Fetch canned, ready-to-edit example bodies for the chosen chain (DCA, buy-the-dip, stop-loss, sweep, market-gated; X Layer: transfer + gates). |

`chain` is `84532` (Base Sepolia, default) or `1952` (X Layer testnet). Each tool
fetches with a ~15s timeout and returns the endpoint's JSON pretty-printed. On a
non-2xx status or an `{ok:false}` envelope it returns the error text as an MCP
tool error (`isError`) instead of throwing.

**Actions:** `transfer`, `approve`, `swap`, `aaveDeposit`, `aaveWithdraw`,
`aaveWithdrawAll`, `wrap`, `bridge`. _(On X Layer only `transfer` + `approve` are deployed.)_
**Conditions (gates):** `waitTime`, `waitBlock`, `waitPriceGte`, `waitPriceLte`,
`balance`, `price`, `query`, `timeRange`, `gasPrice`, `signature`,
`marketResolved`, `marketOutcome`.

## Resource

The server also exposes the full usage skill (`SKILL.md`) as a readable MCP
resource — so adding the server delivers the tools **and** their how-to guide.

| Resource         | URI              | Contents                                                              |
| ---------------- | ---------------- | -------------------------------------------------------------------- |
| `w3cash-skill`   | `w3cash://skill` | Multi-chain usage, decimal→base-unit conversion, the non-custodial sign→execute flow (incl. keyless OnchainOS Agentic Wallet), and replay/security guidance. |

---

## Example prompts

Once installed, ask your agent naturally:

- _"Use W3Cash to compile an intent that swaps 100 USDC to WETH only when ETH is below $3000."_
- _"With W3Cash, bridge 5 USDC to Ethereum when gas is cheap."_
- _"Use W3Cash to withdraw 1 USDC from Aave only if my prediction market `0x80334C47F3DcE19FcFE7dB1AEce7423D32C4ccB1` resolves YES."_

A well-behaved agent will call `w3cash_capabilities` first, then
`w3cash_compile_intent`. For example, the first prompt compiles a body like:

```json
{
  "initiator": "0xYourWallet",
  "conditions": [
    {
      "type": "waitPriceLte",
      "feed": "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1",
      "targetPrice": "300000000000"
    }
  ],
  "actions": [
    {
      "type": "swap",
      "tokenIn": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
      "tokenOut": "0x4200000000000000000000000000000000000006",
      "amountIn": "100000000",
      "minAmountOut": "0",
      "fee": 3000
    }
  ]
}
```

(`targetPrice` is a Chainlink 8-decimal answer: `$3000 = 3000 × 1e8`. `amountIn`
is 100 USDC at 6 decimals.)

---

## Non-custodial: how execution actually happens

This service **never holds keys and never signs.** `w3cash_compile_intent`
returns:

- `toSign` — the raw **32-byte EIP-191 personal-sign message** the `initiator`
  signs with its own wallet.
- `instruction` — the assembled instruction bytes.
- `steps` / `humanSummary` / `warnings` — for review before signing.

The agent then:

1. Signs `toSign` with the initiator's wallet (EIP-191 personal sign).
2. Submits `W3CashProcessor.execute(...)` on **Base Sepolia (chain 84532)**,
   processor `0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE`.
3. Anyone can call `execute()` once the gates pass — the on-chain adapters
   enforce every condition before any action runs.

**Replay caveat:** `execute()` verifies but does **not** consume the outer
nonce, so a captured signed payload stays re-executable until the initiator
calls `incrementNonce()` on the processor. Damage is bounded by the token
allowance each adapter holds — **never grant unlimited approvals** for compiled
intents. Bump `nonce` (and re-sign) to invalidate old signatures.

---

## Development

```bash
npm install
npm run build        # tsc -> dist/
npm run typecheck    # tsc --noEmit
npm run dev          # tsx watch src/http.ts  (HTTP transport, hot reload)
npm run dev:stdio    # tsx watch src/stdio.ts (stdio transport, hot reload)
npm start            # node dist/http.js
```

### Layout

```
apps/mcp/
├── src/
│   ├── asp.ts     # ASP HTTP client (15s timeout, {ok:false} -> tool error)
│   ├── tools.ts   # registerTools + registerResources (4 tools + skill resource)
│   ├── skill.ts   # loads SKILL.md, served as the w3cash://skill resource
│   ├── meta.ts    # server name/version
│   ├── stdio.ts   # stdio entry  (local install; package `bin`)
│   └── http.ts    # Express + Streamable-HTTP entry (POST /mcp, GET /health)
├── README.md
└── SKILL.md       # the agent skill — teaches the W3Cash model; also the w3cash://skill resource
```

Both transports register the **same** tools + resource via `registerTools` /
`registerResources`, so the surface is identical whether an agent connects over
stdio or HTTP.
