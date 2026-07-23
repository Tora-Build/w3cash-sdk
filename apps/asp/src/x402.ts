/**
 * x402 pay-per-call gate (phase-2) for /compile-intent, via the OKX Payment SDK.
 * Non-invasive: returns an Express middleware only when explicitly enabled and
 * fully configured; otherwise the endpoint stays FREE (returns null).
 *
 * DYNAMIC PAYMENT (Phase-1 item 16): the 402 challenge advertises EVERY configured
 * settlement chain in `accepts[]`, so the caller's x402 client picks one (interactive).
 * A caller with no preference pays the DEFAULT (the first / primary network); the
 * chosen network is disclosed back on the paid response via `X-Payment-Network`, and
 * the full option list is served at `GET /payment-options`. Settlement is a stablecoin
 * per chain (e.g. USD₮0 on X Layer mainnet eip155:196, USDC on Base) resolved by the
 * OKX facilitator from the price.
 *
 * Enable with:  X402_ENABLED=true + NETWORK (primary CAIP-2) + PAY_TO_ADDRESS + OKX_* creds.
 * Add more chains with PAYMENT_NETWORKS (comma-separated CAIP-2; same payTo + price).
 *
 * The OKX packages are imported dynamically so free-mode boot never loads them.
 */
import type { RequestHandler, Request, Response, NextFunction } from "express";

export interface PaymentConfig {
  network?: string;
  payTo?: string;
  okxApiKey?: string;
  okxSecretKey?: string;
  okxPassphrase?: string;
  /** Extra settlement chains beyond `network` (comma-separated CAIP-2). */
  extraNetworks?: string;
}

type Caip2 = `${string}:${string}`;

/** Display-only asset labels per chain (the facilitator resolves the real asset from price). */
const KNOWN_ASSET: Record<string, string> = {
  "eip155:196": "USD₮0",
  "eip155:1952": "USD₮0",
  "eip155:8453": "USDC",
  "eip155:84532": "USDC",
};

/**
 * Sanitize + validate a CAIP-2 network id. A stray inline comment or whitespace in an
 * env value (e.g. "eip155:196 # note") reaches the facilitator as a malformed network
 * and throws — which previously escaped as an unhandled rejection and CRASHED the boot.
 * Cut at the first whitespace/# and require the CAIP-2 shape; return null if invalid.
 */
function sanitizeNetwork(raw: string | undefined): Caip2 | null {
  if (!raw) return null;
  const net = raw.trim().split(/[\s#]/)[0].trim(); // trim FIRST so a leading space isn't cut to ""
  if (!/^[a-z0-9]+:[a-zA-Z0-9]+$/.test(net)) return null;
  return net as Caip2;
}

/**
 * Resolve the ordered, de-duplicated list of settlement networks (default = first).
 * The primary `network` leads; `PAYMENT_NETWORKS` (or cfg.extraNetworks) appends more.
 */
export function resolvePaymentNetworks(cfg: PaymentConfig): Caip2[] {
  const out: Caip2[] = [];
  const push = (raw: string | undefined) => {
    const net = sanitizeNetwork(raw);
    if (net && !out.includes(net)) out.push(net);
  };
  push(cfg.network);
  const extra = cfg.extraNetworks ?? process.env.PAYMENT_NETWORKS;
  if (extra) for (const part of extra.split(",")) push(part);
  return out;
}

export interface PaymentOption {
  readonly network: Caip2;
  readonly asset: string; // display label; facilitator resolves the concrete token
  readonly payTo: string;
  readonly price: string;
  readonly isDefault: boolean;
}

export interface PaymentTier {
  readonly tier: string;
  readonly endpoint: string;
  readonly price: string;
  readonly returns: string;
}

export interface PaymentOptions {
  readonly enabled: boolean;
  readonly default: Caip2 | null;
  readonly options: readonly PaymentOption[];
  /** The pricing ladder (item 15): free preview → metered compile → (future) subscription. */
  readonly tiers: readonly PaymentTier[];
  readonly note: string;
}

/** The payment options for `GET /payment-options` (disclosure of chains + default). */
export function getPaymentOptions(
  cfg: PaymentConfig,
  price: string = process.env.X402_PRICE ?? "$0.01"
): PaymentOptions {
  const enabled = process.env.X402_ENABLED === "true";
  const nets = resolvePaymentNetworks(cfg);
  const payTo = cfg.payTo ?? "";
  const options = nets.map((network, i) => ({
    network,
    asset: KNOWN_ASSET[network] ?? "stablecoin",
    payTo,
    price,
    isDefault: i === 0,
  }));
  return {
    enabled: enabled && options.length > 0 && payTo !== "",
    default: nets[0] ?? null,
    options,
    tiers: [
      { tier: "preview", endpoint: "POST /simulate-intent", price: "free", returns: "verdict + gate status + setup fix-its (NO signable payload)" },
      { tier: "compile", endpoint: "POST /compile-intent", price, returns: "the full signable intent (operations, instruction, toSign)" },
      { tier: "subscription", endpoint: "(future)", price: "TBD", returns: "keeper/telemetry value-add — not yet enabled" },
    ],
    note:
      "Pricing ladder: FREE simulate → metered compile → (future) subscription. The 402 challenge advertises every payment chain above; your x402 client picks one, or omits a preference to pay the default. The chosen chain is echoed on the paid response as X-Payment-Network.",
  };
}

/** Decode the caller's X-PAYMENT request header (base64 JSON) to the network they paid on. */
function paidNetworkFromRequest(req: Request): string | null {
  try {
    const h = req.headers["x-payment"];
    const raw = Array.isArray(h) ? h[0] : h;
    if (!raw) return null;
    const decoded = JSON.parse(Buffer.from(raw, "base64").toString("utf8")) as {
      network?: string;
    };
    return typeof decoded.network === "string" ? decoded.network : null;
  } catch {
    return null;
  }
}

/**
 * Best-effort disclosure: echo the settled network on the response. Never throws.
 *
 * Scoped to the PAID route only, and only echoes a network that (a) is one we actually settle on
 * and (b) the payment gate already verified for this request. Previously this fired on EVERY route
 * (it was mounted globally) and echoed the raw, unvalidated caller-supplied `x-payment` network —
 * so any client could stamp `X-Payment-Network: <anything>` on a free response like /health,
 * falsely certifying a settlement that never happened (round-4 audit).
 */
function makeDisclosureMiddleware(cfg: PaymentConfig): RequestHandler {
  const allowed = new Set(resolvePaymentNetworks(cfg).map((n) => n.toLowerCase()));
  return (req: Request, res: Response, next: NextFunction) => {
    // req.path is "/compile-intent" only after the payment gate let this request through (it 402s
    // unpaid). On any other (free) route we never attach the header.
    if (req.path === "/compile-intent") {
      const net = paidNetworkFromRequest(req);
      if (net && allowed.has(net.toLowerCase())) res.setHeader("X-Payment-Network", net);
    }
    next();
  };
}

/** Build the x402 middleware, or null when payments are disabled/misconfigured. */
export async function buildX402Middleware(
  cfg: PaymentConfig,
  price: string = process.env.X402_PRICE ?? "$0.01"
): Promise<RequestHandler | null> {
  if (process.env.X402_ENABLED !== "true") return null;

  const { payTo, okxApiKey, okxSecretKey, okxPassphrase } = cfg;
  const networks = resolvePaymentNetworks(cfg);
  if (networks.length === 0 || !payTo || !okxApiKey || !okxSecretKey || !okxPassphrase) {
    console.warn(
      "[x402] X402_ENABLED=true but NETWORK / PAY_TO_ADDRESS / OKX_* are incomplete or no valid CAIP-2 network — staying FREE."
    );
    return null;
  }

  try {
    const { paymentMiddleware, x402ResourceServer } = await import("@okxweb3/x402-express");
    const { ExactEvmScheme } = await import("@okxweb3/x402-evm/exact/server");
    const { OKXFacilitatorClient } = await import("@okxweb3/x402-core");

    const facilitatorClient = new OKXFacilitatorClient({
      apiKey: okxApiKey,
      secretKey: okxSecretKey,
      passphrase: okxPassphrase,
    });
    const resourceServer = new x402ResourceServer(facilitatorClient);
    // Register the exact scheme for EACH advertised network.
    for (const net of networks) resourceServer.register(net, new ExactEvmScheme());

    // Eagerly initialize (calls the OKX facilitator's getSupported) INSIDE this try so
    // bad creds / an unreachable facilitator fail-open to FREE here rather than crashing
    // later as an unhandled rejection inside the middleware.
    const initable = resourceServer as unknown as { initialize?: () => Promise<unknown> };
    if (typeof initable.initialize === "function") {
      await initable.initialize();
    }

    console.log(
      `[x402] payments ENABLED — /compile-intent, ${price} → ${payTo} on [${networks.join(
        ", "
      )}] (default ${networks[0]})`
    );

    // Multi-chain accepts[]: one entry per configured network. The x402 client chooses
    // one (or the default). Gate both POST (the real call) and GET (OKX's curl self-check).
    const accepts = networks.map((network) => ({
      scheme: "exact",
      network,
      payTo,
      price,
    }));
    const paidRoute = {
      accepts,
      description: "W3Cash Intent Compiler — compile a signable on-chain intent",
      mimeType: "application/json",
    };
    const paymentGate = paymentMiddleware(
      {
        "POST /compile-intent": paidRoute,
        "GET /compile-intent": paidRoute,
      },
      resourceServer
    );

    // Chain the disclosure wrapper AFTER the payment gate so a settled /compile-intent request
    // echoes X-Payment-Network. Both are no-ops on non-/compile-intent routes.
    const disclosure = makeDisclosureMiddleware(cfg);
    const composed: RequestHandler = (req, res, next) => {
      paymentGate(req, res, (err?: unknown) => {
        if (err) return next(err as Error);
        disclosure(req, res, next);
      });
    };
    return composed;
  } catch (e) {
    // Never let a payment misconfig take down the endpoint — fall back to FREE.
    console.error(
      "[x402] failed to initialize payments — staying FREE:",
      e instanceof Error ? e.message : e
    );
    return null;
  }
}
