/**
 * AgentCard (Phase-1 item 19) — the machine-readable discovery descriptor an agent framework
 * (or an ERC-8004 registry resolver) reads to find, understand, and price the W3Cash service.
 *
 * Served at `GET /agent-card` and `GET /.well-known/agent-card.json`. Built from the live encoder
 * config so it can never drift from what the service actually supports. Pure + deterministic.
 */
import { CHAINS } from "./w3cash/encode.js";
import { getPaymentOptions, type PaymentOptions } from "./x402.js";

export interface AgentCard {
  readonly protocol: "a2mcp";
  readonly name: string;
  readonly description: string;
  readonly version: string;
  readonly model: "do X only when Y";
  readonly custody: "non-custodial";
  readonly skill: string;
  readonly endpoints: Readonly<Record<string, string>>;
  readonly mcpTools: readonly string[];
  readonly chains: readonly { chainId: number; name: string; processor: string }[];
  readonly capabilities: {
    readonly actions: readonly string[];
    readonly conditions: readonly string[];
    readonly note: string;
  };
  readonly payment: PaymentOptions;
  readonly safety: readonly string[];
}

const MCP_TOOLS = [
  "w3cash_capabilities",
  "w3cash_simulate_intent",
  "w3cash_compile_intent",
  "w3cash_bridge_quote",
  "w3cash_recipes",
  "w3cash_cancel_all",
  "w3cash_payment_options",
] as const;

/** Build the AgentCard from the live config. `baseUrl` is the public origin (e.g. https://asp.w3.cash). */
export function getAgentCard(
  baseUrl: string,
  paymentConfig: Parameters<typeof getPaymentOptions>[0],
  version = "0.0.1"
): AgentCard {
  const b = baseUrl.replace(/\/$/, "");
  const chains = Object.values(CHAINS).map((c) => ({
    chainId: c.chainId,
    name: c.chainName,
    processor: c.processor,
  }));
  return {
    protocol: "a2mcp",
    name: "W3Cash Intent Compiler",
    description:
      "Non-custodial intent compiler for AI agents: turns a structured goal into a ready-to-sign, " +
      "on-chain 'do X only when Y' intent — actions gated by time/price/balance/gas/co-signer/" +
      "prediction-market conditions. Local, single-user: the caller signs the exact target; there " +
      "is no solver or counterparty. The compiler never holds keys or funds.",
    version,
    model: "do X only when Y",
    custody: "non-custodial",
    skill: "w3cash://skill",
    endpoints: {
      mcp: `${b}/mcp`,
      simulate: `${b}/simulate-intent`,
      compile: `${b}/compile-intent`,
      capabilities: `${b}/capabilities`,
      recipes: `${b}/recipes`,
      cancel: `${b}/cancel`,
      paymentOptions: `${b}/payment-options`,
    },
    mcpTools: [...MCP_TOOLS],
    chains,
    capabilities: {
      actions: ["transfer", "approve", "swap", "aaveDeposit", "aaveWithdraw", "wrap", "bridge"],
      conditions: [
        "waitTime", "waitBlock", "waitPriceGte", "waitPriceLte", "balance", "price", "query",
        "timeRange", "gasPrice", "signature", "marketResolved", "marketOutcome",
      ],
      note:
        "The full DeFi action set is on Base Sepolia; the X Layer chains are a minimal core " +
        "(transfer/approve + all gates). Every condition is available on every chain. Call " +
        "GET /capabilities?chain=<id> for the exact, chain-filtered set.",
    },
    payment: getPaymentOptions(paymentConfig),
    safety: [
      "Safe-by-default compile: auto-expiry bound + exact-sized exposure + one-tap cancel.",
      "FREE pre-sign simulate (POST /simulate-intent): would-fire / blocked / needs-setup — no payload leak.",
      "Non-custodial: the caller signs the exact target; the service never holds keys or funds.",
    ],
  };
}
