/**
 * x402 payer — makes the MCP transparently pay for the paid ASP endpoint, BEHIND A POLICY GATE.
 *
 * The ASP's `/compile-intent` is an x402 pay-per-call endpoint: an unpaid request gets `402 Payment
 * Required` with a challenge. A funded payer key must NOT auto-sign an arbitrary challenge — a
 * malicious/compromised/redirected server could otherwise demand a huge amount to an attacker
 * address and drain the key (audit #8). So before settling, this validates every 402 challenge:
 *   - HOST allowlist    — only pay requests to the trusted ASP origin (ASP_BASE_URL host).
 *   - VALUE cap         — reject any `amount` above X402_MAX_AMOUNT (asset base units).
 *   - NETWORK allowlist — reject a chain not in X402_ALLOWED_NETWORKS (CAIP-2).
 *   - PAYTO allowlist   — if X402_ALLOWED_PAYTO is set, reject any other recipient.
 * Only an option that passes ALL checks is settled (via the OKX SDK). Free endpoints never 402 and
 * pass straight through unpaid.
 *
 * Configure with `X402_PAYER_KEY` (falls back to `RELAYER_PRIVATE_KEY`, with a warning — prefer a
 * dedicated, low-balance payer key). With no key, this returns plain `fetch`.
 */
import { wrapFetchWithPayment, x402Client } from "@okxweb3/x402-fetch";
import { registerExactEvmScheme } from "@okxweb3/x402-evm/exact/client";
import { privateKeyToAccount } from "viem/accounts";
import { ASP_BASE_URL } from "./asp.js";

interface Accept {
  scheme?: string;
  network?: string;
  amount?: string;
  asset?: string;
  payTo?: string;
}

/** Payment policy resolved from env (safe defaults). */
function policy() {
  const host = (() => {
    try { return new URL(ASP_BASE_URL).host; } catch { return ""; }
  })();
  const maxAmount = BigInt(process.env.X402_MAX_AMOUNT ?? "1000000"); // default 1.0 USD₮0 (6dp) per call
  const networks = (process.env.X402_ALLOWED_NETWORKS ?? "eip155:196,eip155:1952")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  const payTo = (process.env.X402_ALLOWED_PAYTO ?? "")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  return { host, maxAmount, networks, payTo };
}

/** Decode the base64 PAYMENT-REQUIRED header to its accepts[]. Returns [] on any failure. */
function decodeAccepts(headerVal: string | null): Accept[] {
  if (!headerVal) return [];
  try {
    const j = JSON.parse(Buffer.from(headerVal, "base64").toString("utf8")) as { accepts?: Accept[] };
    return Array.isArray(j.accepts) ? j.accepts : [];
  } catch {
    return [];
  }
}

/** True if at least one advertised option satisfies the whole policy. */
function anyAcceptable(accepts: Accept[], p: ReturnType<typeof policy>): boolean {
  return accepts.some((a) => {
    const net = (a.network ?? "").toLowerCase();
    if (!p.networks.includes(net)) return false;
    let amt: bigint;
    try { amt = BigInt(a.amount ?? "0"); } catch { return false; }
    if (amt > p.maxAmount) return false;
    if (p.payTo.length > 0 && !p.payTo.includes((a.payTo ?? "").toLowerCase())) return false;
    return true;
  });
}

function build(): typeof fetch {
  const raw = process.env.X402_PAYER_KEY ?? process.env.RELAYER_PRIVATE_KEY;
  if (!raw) return fetch;
  if (!process.env.X402_PAYER_KEY && process.env.RELAYER_PRIVATE_KEY) {
    console.error("[w3cash-mcp] WARNING: x402 payer is using RELAYER_PRIVATE_KEY — prefer a dedicated low-balance X402_PAYER_KEY.");
  }
  try {
    const pk = (raw.startsWith("0x") ? raw : `0x${raw}`) as `0x${string}`;
    const account = privateKeyToAccount(pk);
    const client = new x402Client();
    registerExactEvmScheme(client, { signer: account });
    const settle = wrapFetchWithPayment(fetch, client) as unknown as typeof fetch;
    const p = policy();
    console.error(
      `[w3cash-mcp] x402 payer enabled (${account.address}) — pays ONLY ${p.host}, <= ${p.maxAmount} on [${p.networks.join(", ")}]`
    );

    // Policy-gated fetch: probe first, validate the 402 challenge, only THEN settle.
    const gated: typeof fetch = async (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      let host = "";
      try { host = new URL(url).host; } catch { /* non-URL */ }
      // Only ever attempt payment against the trusted ASP host; everything else is plain fetch.
      if (host !== p.host || p.host === "") return fetch(input as RequestInfo, init);

      const probe = await fetch(input as RequestInfo, init);
      if (probe.status !== 402) return probe;

      const accepts = decodeAccepts(probe.headers.get("payment-required"));
      if (!anyAcceptable(accepts, p)) {
        throw new Error(
          `[w3cash-mcp] x402 payment REFUSED by policy — challenge from ${host} exceeds the value cap / network / payTo allowlist. Not signing.`
        );
      }
      return settle(input as RequestInfo, init); // SDK re-requests + settles the vetted challenge
    };
    return gated;
  } catch (e) {
    console.error("[w3cash-mcp] x402 payer disabled (init failed):", e instanceof Error ? e.message : e);
    return fetch;
  }
}

/** A policy-gated payment-enabled fetch (or plain fetch when no payer key is set). */
export const payingFetch: typeof fetch = build();

// Exposed for unit testing the policy logic.
export const __test = { policy, decodeAccepts, anyAcceptable };
