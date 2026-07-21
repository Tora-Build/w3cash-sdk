/**
 * W3Cash MCP tools — the agent-consumption layer for the W3Cash Intent Compiler.
 *
 * Four tools, each a thin proxy over one live ASP endpoint. The descriptions are
 * deliberately verbose: an agent reads them to decide WHEN and HOW to call each
 * tool, so they teach the "do X only when Y" model, the non-custodial sign→
 * execute flow, and the exact field shapes. `registerTools` is shared by both
 * transports (stdio + Streamable HTTP) so the tool surface is identical either
 * way; `createMcpServer` bundles registration with server metadata + instructions.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { aspGet, aspPost, ASP_BASE_URL } from "./asp.js";
import { SERVER_NAME, SERVER_VERSION } from "./meta.js";
import { SKILL_MD, SKILL_URI } from "./skill.js";

/** MCP text-content tool result. `isError` marks a surfaced ASP failure. */
type ToolResult = {
  readonly content: { readonly type: "text"; readonly text: string }[];
  readonly isError?: boolean;
};

/** Turn an AspResult into an MCP tool result: pretty JSON on success, error text + isError on failure. */
function present(result: Awaited<ReturnType<typeof aspGet>>): ToolResult {
  if (!result.ok) {
    return { content: [{ type: "text", text: result.error }], isError: true };
  }
  return { content: [{ type: "text", text: JSON.stringify(result.data, null, 2) }] };
}

const SERVER_INSTRUCTIONS = [
  "W3Cash compiles a structured goal into a non-custodial, ready-to-sign on-chain",
  "intent. Three chains are supported: Base Sepolia (84532, default), X Layer",
  "testnet (1952), and X Layer MAINNET (196 — real funds). The mental model is",
  "\"do X only when Y\": ACTIONS (X) run only after every CONDITION gate (Y) is",
  "satisfied, in order.",
  "",
  "Chain note: Base Sepolia has the full action set (transfer/approve/swap/aave/",
  "wrap/bridge). Both X Layer chains (testnet 1952 + mainnet 196) are a minimal",
  "core — transfer/approve plus every gate (time/block/gas/balance/price/query/",
  "co-signer/market); swap/aave/wrap/bridge are NOT available there. X Layer USD₮0",
  "is 0x9e29… on testnet and 0x779Ded… on mainnet. Pass the target chain id (default 84532).",
  "",
  "Workflow: (1) call w3cash_capabilities FIRST (optionally with a chain) to learn",
  "the exact action/condition field names for that chain; (2) call",
  "w3cash_compile_intent with the chain + conditions[] + actions[]; it returns",
  "`toSign` (the 32-byte EIP-191 message the initiator personal-signs) and",
  "`instruction` bytes; (3) the CALLER signs `toSign` with its own wallet and submits",
  "W3CashProcessor.execute() on that chain. This service NEVER holds keys or signs.",
  "",
  "Caveat: execute() verifies but does NOT consume the nonce — a captured signature",
  "stays replayable until the initiator calls incrementNonce(). Never grant unlimited",
  "token approvals for compiled intents.",
  "",
  "A full usage guide ships with this server as the `" + SKILL_URI + "` resource",
  "(multi-chain, decimal conversion, keyless sign->execute, security). Read it for",
  "the exact field shapes and the recommended flow.",
].join("\n");

export function registerTools(server: McpServer): void {
  // -------------------------------------------------------------------------
  // 1. Capabilities — the discovery call. Agents should hit this first.
  // -------------------------------------------------------------------------
  server.registerTool(
    "w3cash_capabilities",
    {
      title: "W3Cash: list capabilities",
      description:
        "Discover what the W3Cash Intent Compiler can do ON A GIVEN CHAIN. CALL THIS " +
        "FIRST, before w3cash_compile_intent, to learn the exact field names for every " +
        "action and condition available on the target chain. Pass `chain` (84532 Base " +
        "Sepolia default, 1952 X Layer testnet, or 196 X Layer mainnet); the returned " +
        "action/condition set is " +
        "filtered to what that chain actually deploys — e.g. X Layer omits swap/aave/" +
        "wrap/bridge. Returns the supported ACTIONS " +
        "(transfer, approve, [swap, aaveDeposit, aaveWithdraw, aaveWithdrawAll, wrap, " +
        "bridge on Base Sepolia]) and CONDITION gates " +
        "(waitTime, waitBlock, waitPriceGte, waitPriceLte, balance, price, query, " +
        "timeRange, gasPrice, signature, marketResolved, marketOutcome), each with its " +
        "adapter, required fields, and whether it needs a prior token approval. Also " +
        "returns that chain's deployed processor/adapter addresses, the operator enums, " +
        "the adapter catalog, and the replay caveat.",
      inputSchema: {
        chain: z
          .number()
          .int()
          .optional()
          .default(84532)
          .describe("EVM chain id: 84532 (Base Sepolia, default), 1952 (X Layer testnet), or 196 (X Layer mainnet)."),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) =>
      present(await aspGet(`/capabilities?chain=${args.chain ?? 84532}`)),
  );

  // -------------------------------------------------------------------------
  // 2. Compile intent — the core tool. Structured goal -> signable intent.
  // -------------------------------------------------------------------------
  server.registerTool(
    "w3cash_compile_intent",
    {
      title: "W3Cash: compile an on-chain intent",
      description:
        "Compile a structured goal into a ready-to-sign, non-custodial W3Cash on-chain " +
        "intent — the \"do X only when Y\" primitive. ACTIONS run only after EVERY " +
        "condition (gate) is met, in array order. Returns `steps`, `humanSummary`, " +
        "`warnings`, the `operations`/`inputs` arrays, the assembled `instruction` " +
        "bytes, `payloadHash`, and `toSign` — the 32-byte EIP-191 personal-sign message " +
        "the `initiator` must sign. NON-CUSTODIAL: the caller signs `toSign` with its " +
        "own wallet and submits W3CashProcessor.execute(); this service never holds keys.\n\n" +
        "Call w3cash_capabilities first for exact field names. Field values may be " +
        "decimal strings or numbers; token amounts are in base units (wei / smallest " +
        "token unit). Examples of the (conditions, actions) arrays:\n" +
        "• Wait then transfer: conditions=[{\"type\":\"waitTime\",\"timestamp\":1893456000}], " +
        "actions=[{\"type\":\"transfer\",\"token\":\"0x<usdc>\",\"to\":\"0x<dest>\",\"amount\":\"1000000\"}]\n" +
        "• Withdraw when a prediction market resolves YES: " +
        "conditions=[{\"type\":\"marketOutcome\",\"market\":\"0x<truthMarket>\",\"outcome\":\"YES\"}], " +
        "actions=[{\"type\":\"aaveWithdraw\",\"token\":\"0x<usdc>\",\"amount\":\"1000000\"}]\n" +
        "• Bridge when gas is cheap (server auto-fetches the Across quote): " +
        "conditions=[{\"type\":\"gasPrice\",\"operator\":\"lte\",\"threshold\":\"20000000000\"}], " +
        "actions=[{\"type\":\"bridge\",\"autoQuote\":true,\"recipient\":\"0x<dest>\"," +
        "\"destinationChainId\":11155111,\"inputToken\":\"0x<weth>\",\"inputAmount\":\"5000000\"}]\n\n" +
        "SAFE BY DEFAULT: unless you pass expiry:\"none\", the compiler auto-adds an " +
        "absolute time bound so the signature can't be replayed forever (short for " +
        "one-shot, ~30d for triggered, until-target+grace for scheduled, unbounded for " +
        "market-gated). The result includes `expiry` (the applied bound) and `exposure` " +
        "(worst-case per-execution token outflow); to cancel outstanding intents use " +
        "w3cash_cancel_all.",
      inputSchema: {
        chain: z
          .number()
          .int()
          .optional()
          .default(84532)
          .describe("EVM chain id: 84532 (Base Sepolia, default), 1952 (X Layer testnet), or 196 (X Layer mainnet). X Layer supports transfer/approve + all gates but NOT swap/aave/wrap/bridge."),
        expiry: z
          .union([z.literal("auto"), z.literal("none"), z.number().int().nonnegative()])
          .optional()
          .describe("Safe-default expiry policy. Omit/\"auto\" = classify and add a sensible time bound (recommended). \"none\" = opt out (NO time bound — stays replayable until incrementNonce()). A number = explicit window in seconds from now."),
        nonce: z
          .number()
          .int()
          .optional()
          .describe("The initiator's current on-chain W3CashProcessor nonce (default 0). `toSign` is bound to this nonce."),
        initiator: z
          .string()
          .optional()
          .describe("Address that will sign and whose funds/approvals the actions use. Echoed into the summary."),
        conditions: z
          .array(z.record(z.string(), z.unknown()))
          .optional()
          .describe("Gate objects (the Y in 'do X only when Y'), each { type, ...fields }. All must pass before actions run. See w3cash_capabilities."),
        actions: z
          .array(z.record(z.string(), z.unknown()))
          .optional()
          .describe("Action objects (the X), each { type, ...fields }, executed in order once all conditions pass. See w3cash_capabilities."),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => {
      const body: Record<string, unknown> = { chain: args.chain };
      if (args.nonce !== undefined) body.nonce = args.nonce;
      if (args.initiator !== undefined) body.initiator = args.initiator;
      if (args.conditions !== undefined) body.conditions = args.conditions;
      if (args.actions !== undefined) body.actions = args.actions;
      if (args.expiry !== undefined) body.expiry = args.expiry;
      return present(await aspPost("/compile-intent", body));
    },
  );

  // -------------------------------------------------------------------------
  // 5. Cancel all — the one-tx incrementNonce() calldata that invalidates
  //    every outstanding replayable signature the initiator holds on a chain.
  // -------------------------------------------------------------------------
  server.registerTool(
    "w3cash_cancel_all",
    {
      title: "W3Cash: cancel all outstanding intents",
      description:
        "Get the one-transaction \"cancel everything\" calldata for a chain. A compiled " +
        "W3Cash signature stays REPLAYABLE until the initiator's on-chain nonce advances " +
        "(execute() verifies but never consumes it), so this is how an initiator " +
        "invalidates ALL of its outstanding intents at once — including any leaked " +
        "signature — before their expiry. Returns { to, data, value } for a no-arg " +
        "W3CashProcessor.incrementNonce() call on the given `chain`; the initiator " +
        "signs and submits it from its OWN wallet (this service is non-custodial and " +
        "never sends it). Use after a key exposure, or to retire intents you no longer " +
        "want executable.",
      inputSchema: {
        chain: z
          .number()
          .int()
          .optional()
          .default(84532)
          .describe("EVM chain id: 84532 (Base Sepolia, default), 1952 (X Layer testnet), or 196 (X Layer mainnet)."),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => present(await aspGet(`/cancel?chain=${args.chain ?? 84532}`)),
  );

  // -------------------------------------------------------------------------
  // 5b. Simulate — FREE pre-sign dry-run. Call BEFORE compiling to check readiness.
  // -------------------------------------------------------------------------
  server.registerTool(
    "w3cash_simulate_intent",
    {
      title: "W3Cash: simulate an intent (free dry-run)",
      description:
        "FREE pre-sign dry-run: answers \"would this fire right now / which gate is blocking / what " +
        "setup do I still need\" BEFORE anyone signs or pays for a compile. Takes the SAME " +
        "{chain, conditions, actions} as w3cash_compile_intent, plus `initiator` (the address whose " +
        "funds/approvals the actions use — required for balance/allowance checks). Returns a `verdict` " +
        "(would-fire | blocked | needs-setup | unknown), per-gate status (pass/blocked/unknown, with " +
        "how far off), and `setup` fix-its (e.g. \"approve USDC for the TransferAdapter\", \"top up " +
        "0.5 more WETH\"). It NEVER returns the signable payload — that is the paid w3cash_compile_intent. " +
        "Gates are evaluated at the CURRENT block, not the future fire time (a co-signer gate can't be " +
        "simulated without the co-signature). Use this first to avoid paying to compile an intent that " +
        "can't fire yet.",
      inputSchema: {
        chain: z.number().int().optional().default(84532)
          .describe("EVM chain id: 84532 (Base Sepolia, default), 1952 (X Layer testnet), or 196 (X Layer mainnet)."),
        initiator: z.string().optional()
          .describe("Address whose funds/approvals the actions use. Required for balance/allowance readiness; gates still evaluate without it."),
        conditions: z.array(z.record(z.string(), z.unknown())).optional()
          .describe("Gate objects (the Y), each { type, ...fields }. Same shape as w3cash_compile_intent."),
        actions: z.array(z.record(z.string(), z.unknown())).optional()
          .describe("Action objects (the X), each { type, ...fields }. Same shape as w3cash_compile_intent."),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => {
      const body: Record<string, unknown> = { chain: args.chain };
      if (args.initiator !== undefined) body.initiator = args.initiator;
      if (args.conditions !== undefined) body.conditions = args.conditions;
      if (args.actions !== undefined) body.actions = args.actions;
      return present(await aspPost("/simulate-intent", body));
    },
  );

  // -------------------------------------------------------------------------
  // 6. Payment options — which chains the compile fee can be paid on.
  // -------------------------------------------------------------------------
  server.registerTool(
    "w3cash_payment_options",
    {
      title: "W3Cash: list payment (x402) options",
      description:
        "List the settlement chains the paid compile fee can be paid on, and which is the DEFAULT. " +
        "The x402 402-challenge advertises ALL of these; your payer picks one, or omits a preference " +
        "to pay the default — and the paid response echoes which chain settled (X-Payment-Network). " +
        "Use this to show the user their payment choices before compiling, or to confirm where a " +
        "compile fee will settle. Each option is a { network (CAIP-2), asset, payTo, price, isDefault }. " +
        "Note: this is about the FEE to USE the compiler (a stablecoin like USD₮0 on X Layer mainnet), " +
        "NOT the chain the compiled intent executes on (that is the `chain` arg on the other tools).",
      inputSchema: {},
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async () => present(await aspGet(`/payment-options`)),
  );

  // -------------------------------------------------------------------------
  // 3. Bridge quote — live Across quote for a cross-chain `bridge` action.
  // -------------------------------------------------------------------------
  server.registerTool(
    "w3cash_bridge_quote",
    {
      title: "W3Cash: quote a cross-chain bridge",
      description:
        "Fetch a live Across bridge quote for a cross-chain `bridge` action, so you can " +
        "fill outputAmount/quoteTimestamp/fillDeadline before compiling (or just to " +
        "preview the fee = inputAmount − outputAmount). Bridges an ERC20 FROM Base " +
        "Sepolia to a real destination EVM chain (native ETH is not bridgeable — bridge " +
        "WETH). Note: w3cash_compile_intent can auto-fetch this same quote inline when a " +
        "bridge action sets \"autoQuote\": true, so this tool is mainly for previewing.",
      inputSchema: {
        inputToken: z
          .string()
          .describe("ERC20 token address on Base Sepolia to bridge (e.g. WETH). Native ETH is not supported."),
        destinationChainId: z
          .number()
          .int()
          .describe("Destination EVM chain id (e.g. 11155111 for Ethereum Sepolia)."),
        inputAmount: z
          .string()
          .describe("Amount of inputToken to bridge, in base units (decimal string)."),
        outputToken: z
          .string()
          .optional()
          .describe("Token to receive on the destination chain. Omit / zero-address => auto (wrapped-native)."),
        recipient: z
          .string()
          .optional()
          .describe("Recipient address on the destination chain (defaults to the initiator)."),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => {
      const body: Record<string, unknown> = {
        inputToken: args.inputToken,
        destinationChainId: args.destinationChainId,
        inputAmount: args.inputAmount,
      };
      if (args.outputToken !== undefined) body.outputToken = args.outputToken;
      if (args.recipient !== undefined) body.recipient = args.recipient;
      return present(await aspPost("/quote/bridge", body));
    },
  );

  // -------------------------------------------------------------------------
  // 4. Recipes — canned, ready-to-POST example bodies.
  // -------------------------------------------------------------------------
  server.registerTool(
    "w3cash_recipes",
    {
      title: "W3Cash: list example recipes",
      description:
        "Return canned, ready-to-use example request bodies for common automations, for " +
        "the given `chain`. Base Sepolia (84532, default): DCA, buy-the-dip, Aave " +
        "stop-loss, cross-chain sweep, prediction-gated withdraw. X Layer testnet (1952) " +
        "and X Layer mainnet (196): scheduled-transfer, gas-gated-transfer, " +
        "balance-gated-transfer (transfer + gates only, over USD₮0). Use these as " +
        "templates: copy a recipe's body, swap in real addresses/" +
        "amounts, and pass it to w3cash_compile_intent. Also returns the replay caveat.",
      inputSchema: {
        chain: z
          .number()
          .int()
          .optional()
          .default(84532)
          .describe("EVM chain id: 84532 (Base Sepolia, default), 1952 (X Layer testnet), or 196 (X Layer mainnet)."),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => present(await aspGet(`/recipes?chain=${args.chain ?? 84532}`)),
  );
}

/**
 * Register the usage skill (SKILL.md) as a readable MCP resource, so adding the
 * server also delivers its how-to guide. Clients that support resources can read
 * `w3cash://skill`; the tools themselves remain fully self-describing without it.
 */
export function registerResources(server: McpServer): void {
  server.registerResource(
    "w3cash-skill",
    SKILL_URI,
    {
      title: "W3Cash Intent Compiler — usage skill",
      description:
        "Full how-to for the w3cash_* tools: chains (84532/1952), decimal→base-unit " +
        "conversion, the non-custodial sign→execute flow (incl. keyless OnchainOS " +
        "Agentic Wallet), interactive clarification, and replay/security guidance.",
      mimeType: "text/markdown",
    },
    async (uri) => ({
      contents: [{ uri: uri.href, mimeType: "text/markdown", text: SKILL_MD }],
    }),
  );
}

/** Build a fully-configured MCP server (metadata + instructions + tools + skill resource). */
export function createMcpServer(): McpServer {
  const server = new McpServer(
    { name: SERVER_NAME, version: SERVER_VERSION },
    { instructions: SERVER_INSTRUCTIONS },
  );
  registerTools(server);
  registerResources(server);
  return server;
}

export { ASP_BASE_URL };
