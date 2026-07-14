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
  const net = network as `${string}:${string}`;

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

    return paymentMiddleware(
      {
        "POST /compile-intent": {
          accepts: [{ scheme: "exact", network: net, payTo, price }],
          description: "W3Cash Intent Compiler — compile a signable on-chain intent",
          mimeType: "application/json",
        },
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
