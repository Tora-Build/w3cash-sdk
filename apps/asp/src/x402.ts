/**
 * x402 pay-per-call gate (phase-2) for POST /compile-intent, via the OKX Payment
 * SDK. Non-invasive: returns an Express middleware only when explicitly enabled
 * and fully configured; otherwise the endpoint stays FREE (returns null).
 *
 * Enable with:  X402_ENABLED=true  + NETWORK (CAIP-2) + PAY_TO_ADDRESS + OKX_* creds.
 * Settlement is USD₮0 on X Layer (testnet eip155:1952, mainnet eip155:196).
 *
 * The OKX packages are imported dynamically so free-mode boot never loads them.
 */
import type { RequestHandler } from "express";

export interface PaymentConfig {
  network?: string;
  payTo?: string;
  okxApiKey?: string;
  okxSecretKey?: string;
  okxPassphrase?: string;
}

/** Build the x402 middleware, or null when payments are disabled/misconfigured. */
export async function buildX402Middleware(
  cfg: PaymentConfig,
  price: string = process.env.X402_PRICE ?? "$0.01"
): Promise<RequestHandler | null> {
  if (process.env.X402_ENABLED !== "true") return null;

  const { network, payTo, okxApiKey, okxSecretKey, okxPassphrase } = cfg;
  if (!network || !payTo || !okxApiKey || !okxSecretKey || !okxPassphrase) {
    console.warn(
      "[x402] X402_ENABLED=true but NETWORK / PAY_TO_ADDRESS / OKX_* are incomplete — staying FREE."
    );
    return null;
  }
  // The SDK types network as CAIP-2 (`namespace:reference`, e.g. "eip155:1952").
  // HARDENING: sanitize + validate before touching the SDK. A stray inline
  // comment or whitespace in the env value (e.g. "eip155:1952 # note") reaches
  // the facilitator as a malformed network and throws RouteConfigurationError —
  // which previously escaped as an unhandled rejection and CRASHED the boot.
  // Cut at the first whitespace/# and require the CAIP-2 shape; otherwise stay FREE.
  const net = network.split(/[\s#]/)[0].trim() as `${string}:${string}`;
  if (!/^[a-z0-9]+:[a-zA-Z0-9]+$/.test(net)) {
    console.warn(
      `[x402] NETWORK "${network}" is not a valid CAIP-2 id (parsed "${net}") — staying FREE.`
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
    resourceServer.register(net, new ExactEvmScheme());

    // Eagerly initialize (calls the OKX facilitator's getSupported) INSIDE this
    // try, so bad creds / an unreachable facilitator fail-open to FREE here
    // rather than crashing later as an unhandled rejection inside the middleware.
    const initable = resourceServer as unknown as { initialize?: () => Promise<unknown> };
    if (typeof initable.initialize === "function") {
      await initable.initialize();
    }

    console.log(`[x402] payments ENABLED — POST /compile-intent, ${price} on ${network} → ${payTo}`);

    // Gate both POST (the real call) and GET (so OKX's `curl -i` self-check on the
    // registered endpoint returns the 402 challenge regardless of method).
    const paidRoute = {
      accepts: [{ scheme: "exact", network: net, payTo, price }],
      description: "W3Cash Intent Compiler — compile a signable on-chain intent",
      mimeType: "application/json",
    };
    return paymentMiddleware(
      {
        "POST /compile-intent": paidRoute,
        "GET /compile-intent": paidRoute,
      },
      resourceServer
    );
  } catch (e) {
    // Never let a payment misconfig take down the endpoint — fall back to FREE.
    console.error(
      "[x402] failed to initialize payments — staying FREE:",
      e instanceof Error ? e.message : e
    );
    return null;
  }
}
