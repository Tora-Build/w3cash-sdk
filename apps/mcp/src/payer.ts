/**
 * x402 payer — pays the paid ASP endpoint BEHIND A POLICY GATE that validates the ACTUAL challenge
 * the SDK will settle (not a separate probe), via the SDK's `paymentRequirementsSelector`.
 *
 * A funded payer key must NOT auto-sign an arbitrary challenge — a malicious/compromised/redirected
 * server could demand a huge amount to an attacker address and drain the key. The selector runs
 * INSIDE the settle flow on the real `accepts[]` and returns the ONE requirement to pay, only if it
 * passes policy; otherwise it throws and nothing is signed. This closes the earlier round-2 gate's
 * two flaws (round-3 audit): the probe-then-settle TOCTOU (there is no separate probe now) and the
 * "any option is safe" vs "SDK pays a specific option" mismatch (the selector IS the choice).
 *
 * Policy (env):
 *   - HOST      — only the trusted ASP origin (ASP_BASE_URL host) is ever paid.
 *   - VALUE cap — reject any `amount` above X402_MAX_AMOUNT (asset base units; our assets are 6-dp stables).
 *   - NETWORK   — reject a chain not in X402_ALLOWED_NETWORKS (CAIP-2).
 *   - PAYTO     — reject any recipient not in X402_ALLOWED_PAYTO (defaults to the known ASP receiver).
 */
import { wrapFetchWithPayment, x402Client } from "@okxweb3/x402-fetch";
import { registerExactEvmScheme } from "@okxweb3/x402-evm/exact/client";
import { privateKeyToAccount } from "viem/accounts";
import { ASP_BASE_URL } from "./asp.js";

interface Requirement { scheme?: string; network?: string; asset?: string; amount?: string; payTo?: string }

function policy() {
  const host = (() => { try { return new URL(ASP_BASE_URL).host; } catch { return ""; } })();
  const maxAmount = BigInt(process.env.X402_MAX_AMOUNT ?? "1000000"); // 1.0 (6-dp) per call
  const networks = (process.env.X402_ALLOWED_NETWORKS ?? "eip155:196,eip155:1952")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  // Default the payTo allowlist to the known ASP receiver (round-3 audit: an empty list accepted any
  // recipient up to the cap). Operators override with X402_ALLOWED_PAYTO.
  const payTo = (process.env.X402_ALLOWED_PAYTO ?? "0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3")
    .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  return { host, maxAmount, networks, payTo };
}

function acceptable(r: Requirement, p: ReturnType<typeof policy>): boolean {
  if (!p.networks.includes((r.network ?? "").toLowerCase())) return false;
  let amt: bigint;
  try { amt = BigInt(r.amount ?? "0"); } catch { return false; }
  if (amt > p.maxAmount) return false;
  if (p.payTo.length > 0 && !p.payTo.includes((r.payTo ?? "").toLowerCase())) return false;
  return true;
}

/** SDK selector: choose the ONE requirement to pay, ONLY if it passes policy; else refuse. */
function makeSelector(p: ReturnType<typeof policy>) {
  return (_v: number, reqs: Requirement[]): Requirement => {
    const pick = reqs.find((r) => acceptable(r, p));
    if (!pick) {
      throw new Error(
        "[w3cash-mcp] x402 payment REFUSED by policy — no advertised option is within the value cap / network / payTo allowlist. Not signing."
      );
    }
    return pick;
  };
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
    const p = policy();
    // The selector runs on the ACTUAL 402 challenge inside wrapFetchWithPayment and returns the
    // specific requirement to pay — no separate probe (no TOCTOU), and it IS the choice (no accepts[0] gap).
    const client = new x402Client(makeSelector(p) as never);
    registerExactEvmScheme(client, { signer: account });
    const settle = wrapFetchWithPayment(fetch, client) as unknown as typeof fetch;
    console.error(
      `[w3cash-mcp] x402 payer enabled (${account.address}) — pays ONLY ${p.host}, <= ${p.maxAmount} on [${p.networks.join(", ")}] to [${p.payTo.join(", ")}]`
    );

    // Host gate: only ever attempt payment against the trusted ASP host; else plain fetch.
    const gated: typeof fetch = (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
      let host = "";
      try { host = new URL(url).host; } catch { /* non-URL */ }
      if (p.host === "" || host !== p.host) return fetch(input as RequestInfo, init);
      return settle(input as RequestInfo, init); // selector validates the real challenge or throws
    };
    return gated;
  } catch (e) {
    console.error("[w3cash-mcp] x402 payer disabled (init failed):", e instanceof Error ? e.message : e);
    return fetch;
  }
}

/** A policy-gated payment-enabled fetch (or plain fetch when no payer key is set). */
export const payingFetch: typeof fetch = build();

// Exposed for testing the policy logic.
export const __test = { policy, acceptable, makeSelector };
