/**
 * x402 payer — makes the MCP transparently pay for the paid ASP endpoint.
 *
 * The ASP's `/compile-intent` is an x402 pay-per-call endpoint: an unpaid request
 * gets `402 Payment Required` with a challenge. When a payer key is configured,
 * this wraps `fetch` with the OKX x402 client so a 402 is settled automatically
 * (sign a Permit2 authorization for the challenge amount, retry) — the tool then
 * receives the intent exactly as before. Free endpoints (capabilities/recipes)
 * never 402, so they pass straight through.
 *
 * Configure with `X402_PAYER_KEY` (falls back to `RELAYER_PRIVATE_KEY`). The payer
 * must hold the challenge asset (USD₮0 on X Layer) and have approved Permit2 for
 * it. With no key, this returns the plain global `fetch` (unpaid → the tool
 * surfaces the 402 as an error), so nothing breaks without a payer.
 */
import { wrapFetchWithPayment, x402Client } from "@okxweb3/x402-fetch";
import { registerExactEvmScheme } from "@okxweb3/x402-evm/exact/client";
import { privateKeyToAccount } from "viem/accounts";

function build(): typeof fetch {
  const raw = process.env.X402_PAYER_KEY ?? process.env.RELAYER_PRIVATE_KEY;
  if (!raw) return fetch;
  try {
    const pk = (raw.startsWith("0x") ? raw : `0x${raw}`) as `0x${string}`;
    const account = privateKeyToAccount(pk);
    const client = new x402Client();
    registerExactEvmScheme(client, { signer: account });
    // stderr so it never pollutes stdio-transport JSON-RPC on stdout.
    console.error(
      `[w3cash-mcp] x402 payer enabled (${account.address}) — paid calls auto-settle`
    );
    return wrapFetchWithPayment(fetch, client) as unknown as typeof fetch;
  } catch (e) {
    console.error(
      "[w3cash-mcp] x402 payer disabled (init failed):",
      e instanceof Error ? e.message : e
    );
    return fetch;
  }
}

/** A payment-enabled fetch (or plain fetch when no payer key is set). */
export const payingFetch: typeof fetch = build();
