/**
 * Across Protocol suggested-fees quote — lets the ASP fill a bridge intent's
 * fee-dependent fields (outputAmount / quoteTimestamp / fillDeadline) server-side,
 * so a caller can bridge without computing Across fees themselves.
 *
 * Base Sepolia (84532) is a testnet, so the default base URL is the Across testnet
 * API. Override with ACROSS_API_URL for mainnet (https://app.across.to/api).
 */
const BASE = process.env.ACROSS_API_URL ?? "https://testnet.across.to/api";
const DEFAULT_ORIGIN = 84532; // Base Sepolia

export class AcrossQuoteError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AcrossQuoteError";
  }
}

export interface AcrossQuoteParams {
  inputToken: string;
  outputToken?: string;
  originChainId?: number;
  destinationChainId: number;
  amount: string; // input amount in minimal units
  recipient?: string;
}

export interface AcrossQuote {
  outputAmount: string;
  quoteTimestamp: number;
  fillDeadline: number;
  exclusivityDeadline: number;
  exclusiveRelayer: string;
  originSpokePool: string;
  totalRelayFee: string;
  limits: { minDeposit: string; maxDeposit: string };
}

/** Fetch a live Across quote. Throws AcrossQuoteError on any API/route/limit error. */
export async function fetchAcrossQuote(p: AcrossQuoteParams): Promise<AcrossQuote> {
  const q = new URLSearchParams({
    originChainId: String(p.originChainId ?? DEFAULT_ORIGIN),
    destinationChainId: String(p.destinationChainId),
    amount: p.amount,
  });
  // Same-token bridge → `token`; cross-token → inputToken + outputToken.
  if (p.outputToken && p.outputToken.toLowerCase() !== p.inputToken.toLowerCase()) {
    q.set("inputToken", p.inputToken);
    q.set("outputToken", p.outputToken);
  } else {
    q.set("token", p.inputToken);
  }
  if (p.recipient) q.set("recipient", p.recipient);

  let res: Response;
  try {
    res = await fetch(`${BASE}/suggested-fees?${q.toString()}`, {
      signal: AbortSignal.timeout(12_000),
    });
  } catch (e) {
    throw new AcrossQuoteError(
      `Across quote request failed: ${e instanceof Error ? e.message : String(e)}`
    );
  }

  const data = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  if (!res.ok || data.type === "AcrossApiError") {
    const msg = typeof data.message === "string" ? data.message : res.statusText;
    const code = data.code ?? res.status;
    throw new AcrossQuoteError(`Across: ${msg} (${code})`);
  }

  const limits = (data.limits ?? {}) as Record<string, unknown>;
  return {
    outputAmount: String(data.outputAmount),
    quoteTimestamp: Number(data.timestamp),
    fillDeadline: Number(data.fillDeadline),
    exclusivityDeadline: Number(data.exclusivityDeadline ?? 0),
    exclusiveRelayer: String(
      data.exclusiveRelayer ?? "0x0000000000000000000000000000000000000000"
    ),
    originSpokePool: String(data.spokePoolAddress ?? ""),
    totalRelayFee: String((data.totalRelayFee as Record<string, unknown>)?.total ?? "0"),
    limits: {
      minDeposit: String(limits.minDeposit ?? "0"),
      maxDeposit: String(limits.maxDeposit ?? "0"),
    },
  };
}
