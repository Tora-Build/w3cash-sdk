import "dotenv/config";
import { pathToFileURL } from "node:url";
import express, {
  type Request,
  type Response,
  type NextFunction,
  type RequestHandler,
} from "express";
import {
  compileIntent,
  getCapabilities,
  getRecipes,
  cancelInstruction,
  ValidationError,
  PROCESSOR,
  CHAIN_ID,
  MAX_STEPS,
  type CompileRequest,
} from "./w3cash/encode.js";
import { buildX402Middleware, getPaymentOptions } from "./x402.js";
import { simulate } from "./simulate.js";
import { getAgentCard } from "./agentcard.js";
import { fetchAcrossQuote, AcrossQuoteError } from "./across.js";
import { LANDING_HTML } from "./landing.js";

// Backstop: a stray unhandled promise rejection (e.g. a deferred x402/facilitator
// error) must NOT take the whole service down. Log it and keep serving — the
// endpoint being reachable matters more than a background init hiccup. Node's
// default behavior (crash on unhandledRejection) is what took the boot down once.
process.on("unhandledRejection", (reason) => {
  console.error(
    "[w3cash-asp] unhandledRejection (kept alive):",
    reason instanceof Error ? reason.message : reason
  );
});

const app = express();

// Default to production behavior so any error path that somehow reaches
// Express's built-in finalhandler cannot leak a stack trace. Opt into
// development explicitly via NODE_ENV=development. (The terminal error handler
// below is the load-bearing control; this is defense in depth.)
if (process.env.NODE_ENV !== "development") {
  app.set("env", "production");
}
app.disable("x-powered-by");

// Permissive CORS for cross-origin marketplace agents (OKX OnchainOS et al.).
// This endpoint is a public, non-custodial, read/compile service — it holds no
// cookies or credentials — so a wildcard origin is safe. Preflights are handled
// so browser-based agents can POST application/json cross-origin.
app.use((req: Request, res: Response, next: NextFunction) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.header("Access-Control-Allow-Headers", "Content-Type");
  res.header("Access-Control-Max-Age", "86400");
  if (req.method === "OPTIONS") {
    res.sendStatus(204);
    return;
  }
  next();
});

// Parse JSON with an explicit small body cap (not the implicit body-parser
// default) so a single request cannot smuggle a huge array of steps, and parse
// regardless of Content-Type since marketplace agents/relayers frequently omit
// or mis-set the header. Malformed bodies surface via the terminal error
// handler below in the same JSON envelope as every other error.
app.use(express.json({ limit: "64kb", type: () => true }));

const PORT = Number(process.env.PORT ?? 4000);

/**
 * Payment configuration seam (x402 — phase-2). Loaded once at boot into a typed,
 * OPTIONAL object. It is intentionally undefined-tolerant: the endpoint is FREE
 * in phase-1, so these vars are expected to be empty and MUST NOT be validated
 * or required here. A future x402 middleware reads this object.
 */
const paymentConfig = {
  network: process.env.NETWORK,
  payTo: process.env.PAY_TO_ADDRESS,
  okxApiKey: process.env.OKX_API_KEY,
  okxSecretKey: process.env.OKX_SECRET_KEY,
  okxPassphrase: process.env.OKX_PASSPHRASE,
  extraNetworks: process.env.PAYMENT_NETWORKS,
} as const;

// x402 pay-per-call gate (phase-2). Returns null in free mode (default), or an
// Express middleware when X402_ENABLED=true and fully configured. Registered
// before the routes so it can 402-gate POST /compile-intent; other routes pass
// through free. Top-level await is fine here (ESM); free mode resolves instantly.
const x402Middleware = await buildX402Middleware(paymentConfig);
if (x402Middleware) app.use(x402Middleware);

// Payment disclosure: the settlement chains advertised in the 402 challenge + the
// default, so a caller can see where it will pay before paying (dynamic payment).
app.get("/payment-options", (_req: Request, res: Response) => {
  res.status(200).json({ ok: true, payment: getPaymentOptions(paymentConfig) });
});

// AgentCard — the machine-readable discovery descriptor (item 19). Served at both the
// friendly path and the well-known convention agent frameworks probe.
const agentCardHandler: RequestHandler = (_req: Request, res: Response) => {
  // Use a CONFIGURED origin, never the attacker-controllable Host/X-Forwarded-Proto headers
  // (audit info-finding) — otherwise the advertised endpoint URLs could be spoofed.
  const base = process.env.PUBLIC_BASE_URL ?? "https://asp.w3.cash";
  res.status(200).json(getAgentCard(base, paymentConfig));
};
app.get("/agent-card", agentCardHandler);
app.get("/.well-known/agent-card.json", agentCardHandler);

// Landing page at the root — a read-only, self-contained visual of the live
// service (renders /capabilities prettily). Static HTML; no wallet/execution.
app.get("/", (_req: Request, res: Response) => {
  res.status(200).type("html").send(LANDING_HTML);
});

// Health / self-check endpoint (used by OKX A2MCP endpoint verification).
app.get("/health", (_req: Request, res: Response) => {
  res.status(200).json({ ok: true, service: "w3cash-intent-compiler" });
});

// Capability discovery — supported actions/conditions + adapter catalog.
// Optional ?chain=<84532|1952> selects the chain (default Base Sepolia).
app.get("/capabilities", (req: Request, res: Response) => {
  try {
    const chain = typeof req.query.chain === "string" ? req.query.chain : undefined;
    res.status(200).json({ ok: true, capabilities: getCapabilities(chain) });
  } catch (err) {
    if (err instanceof ValidationError) {
      res.status(400).json({ ok: false, error: err.message, code: "VALIDATION" });
      return;
    }
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
});

// Canned recipes — ready-to-POST request bodies for common automations.
// Optional ?chain=<84532|1952> selects the chain (default Base Sepolia).
app.get("/recipes", (req: Request, res: Response) => {
  try {
    const chain = typeof req.query.chain === "string" ? req.query.chain : undefined;
    res.status(200).json({ ok: true, recipes: getRecipes(chain) });
  } catch (err) {
    if (err instanceof ValidationError) {
      res.status(400).json({ ok: false, error: err.message, code: "VALIDATION" });
      return;
    }
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
});

// Cancel-all instruction — the one-tx incrementNonce() calldata that invalidates
// every outstanding replayable signature the initiator holds on ?chain=.
app.get("/cancel", (req: Request, res: Response) => {
  try {
    const chain = typeof req.query.chain === "string" ? req.query.chain : undefined;
    res.status(200).json({ ok: true, cancel: cancelInstruction(chain) });
  } catch (err) {
    if (err instanceof ValidationError) {
      res.status(400).json({ ok: false, error: err.message, code: "VALIDATION" });
      return;
    }
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
});

// Live Across bridge quote — returns outputAmount/quoteTimestamp/fillDeadline for a
// cross-chain transfer, so a `bridge` action can be filled without the caller
// computing Across fees. (Also available inline via a bridge action's autoQuote:true.)
app.post("/quote/bridge", async (req: Request, res: Response) => {
  try {
    const b = req.body as {
      inputToken?: string;
      outputToken?: string;
      destinationChainId?: number | string;
      inputAmount?: string;
      recipient?: string;
    } | null;
    // Guard shape before dereferencing so a null/non-object body returns the
    // documented 400 VALIDATION envelope rather than throwing a TypeError that
    // the catch below would map to 500.
    if (
      !b ||
      typeof b !== "object" ||
      !b.inputToken ||
      b.destinationChainId === undefined ||
      !b.inputAmount
    ) {
      res.status(400).json({
        ok: false,
        error: "inputToken, destinationChainId and inputAmount are required",
        code: "VALIDATION",
      });
      return;
    }
    const quote = await fetchAcrossQuote({
      inputToken: b.inputToken,
      outputToken: b.outputToken,
      destinationChainId: Number(b.destinationChainId),
      amount: b.inputAmount,
      recipient: b.recipient,
    });
    res.status(200).json({ ok: true, quote });
  } catch (err) {
    if (err instanceof AcrossQuoteError) {
      res.status(502).json({ ok: false, error: err.message, code: "BRIDGE_QUOTE" });
      return;
    }
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
});

/**
 * Cap on bridge actions that may set autoQuote:true in a single request. Each one
 * fires an outbound Across fetch, so this bounds the per-request outbound fan-out.
 * The encoder's MAX_STEPS guard runs AFTER auto-quoting and would not cover it.
 */
const MAX_AUTOQUOTE = 4;

/**
 * Bridge auto-quote: when a `bridge` action sets `autoQuote: true`, fetch a live
 * Across quote server-side and fill outputAmount/quoteTimestamp/fillDeadline/
 * exclusivityDeadline so the caller doesn't have to. No-op for every other action.
 */
interface BridgeActionLike {
  type?: string;
  autoQuote?: boolean;
  inputToken?: string;
  outputToken?: string;
  destinationChainId?: number | string;
  inputAmount?: string;
  recipient?: string;
  outputAmount?: string;
  quoteTimestamp?: number;
  fillDeadline?: number;
  exclusivityDeadline?: number;
}
async function applyBridgeAutoQuote(body: CompileRequest): Promise<void> {
  // Leave the 400 to compileIntent for a non-object body or a non-array `actions`.
  // Dereferencing them here would throw a raw TypeError the handler maps to 500,
  // breaking the documented {code:"VALIDATION"} 400 contract.
  if (!body || typeof body !== "object" || !Array.isArray(body.actions)) return;
  const actions = body.actions as BridgeActionLike[];
  // Bound the outbound fan-out BEFORE any fetch. Without this, one small body
  // could trigger hundreds of sequential Across calls (request-duration DoS +
  // Across-side rate-limit/ban). Oversized step counts are rejected by
  // compileIntent's MAX_STEPS guard, so just bail here and let it produce the 400.
  if (actions.length > MAX_STEPS) return;
  const autoQuoteActions = actions.filter(
    (a) => a?.type === "bridge" && a.autoQuote === true
  );
  if (autoQuoteActions.length > MAX_AUTOQUOTE) {
    throw new ValidationError(
      `at most ${MAX_AUTOQUOTE} bridge actions may set autoQuote:true (got ${autoQuoteActions.length})`
    );
  }
  for (const a of autoQuoteActions) {
    if (!a.inputToken || a.destinationChainId === undefined || !a.inputAmount) {
      throw new ValidationError(
        "bridge autoQuote requires inputToken, destinationChainId and inputAmount"
      );
    }
    const quote = await fetchAcrossQuote({
      inputToken: a.inputToken,
      outputToken: a.outputToken,
      destinationChainId: Number(a.destinationChainId),
      amount: a.inputAmount,
      recipient: a.recipient,
    });
    a.outputAmount = quote.outputAmount;
    a.quoteTimestamp = quote.quoteTimestamp;
    a.fillDeadline = quote.fillDeadline;
    a.exclusivityDeadline = quote.exclusivityDeadline;
    delete a.autoQuote;
  }
}

/**
 * A2MCP tool endpoint. Non-custodial: compiles a signable W3Cash intent from a
 * structured body {chain?, nonce?, seq?, initiator?, conditions[], actions[]}.
 * Returns the operation/input arrays, the assembled instruction, the payload
 * hash, and the raw 32-byte message the initiator must EIP-191 personal-sign.
 * This ASP NEVER signs or holds keys.
 */
/**
 * Best-effort telemetry registration (item 17): if TELEMETRY_URL is configured, POST the compiled
 * intent's metadata to the telemetry worker so its status/dashboard can link the on-chain events
 * (by payloadHash) back to this intent. Fire-and-forget — it never blocks the compile response and
 * never throws; only public data (the hash + chain + initiator + a short summary) is sent.
 */
function recordToTelemetry(
  intent: { payloadHash: string; chainId: number; humanSummary?: readonly string[] },
  body: CompileRequest
): void {
  const url = process.env.TELEMETRY_URL;
  if (!url) return;
  const summary = (intent.humanSummary ?? []).slice(1, 3).join(" | ").slice(0, 200);
  void fetch(`${url.replace(/\/$/, "")}/record`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-record-secret": process.env.TELEMETRY_SECRET ?? "" },
    body: JSON.stringify({ payloadHash: intent.payloadHash, chainId: intent.chainId, initiator: body?.initiator, summary }),
  }).catch(() => {
    /* telemetry is a non-critical sidecar; a failed record must never affect compile */
  });
}

const compileHandler: RequestHandler = async (req: Request, res: Response) => {
  try {
    const body = req.body as CompileRequest;
    await applyBridgeAutoQuote(body);
    // Safe-by-default (decision #6): inject the server clock so the auto-expiry
    // gate is applied unless the caller explicitly opted out (expiry:"none") or
    // supplied their own `now`. Keeps the live API safe by default.
    if (body && typeof body === "object" && body.now === undefined) {
      body.now = Math.floor(Date.now() / 1000);
    }
    const intent = compileIntent(body);
    res.status(200).json({ ok: true, intent });
    recordToTelemetry(intent, body); // fire-and-forget; never blocks or throws
  } catch (err) {
    if (err instanceof AcrossQuoteError) {
      res.status(502).json({ ok: false, error: err.message, code: "BRIDGE_QUOTE" });
      return;
    }
    if (err instanceof ValidationError) {
      res.status(400).json({ ok: false, error: err.message, code: "VALIDATION" });
      return;
    }
    // Never echo internal error messages to an external caller.
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
};

// GET handler for /compile-intent. x402 clients probe/replay a paid resource with
// GET (only reached AFTER payment — the x402 middleware 402s unpaid GETs), and the
// OKX marketplace validator drives exactly that flow. Without a GET handler a paid
// probe hits the 404 fallback and the agent looks unresponsive. So return a valid
// result: if a `goal`/`chain` is passed as a query param it compiles that; else a
// runnable X Layer sample. Real integrations POST {chain, conditions, actions}.
const SAMPLE_REQUEST: CompileRequest = {
  chain: 1952,
  initiator: "0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3",
  conditions: [
    {
      type: "balance",
      token: "0x9e29b3aada05bf2d2c827af80bd28dc0b9b4fb0c",
      target: "0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3",
      operator: "gte",
      threshold: "1000000",
    },
  ],
  actions: [
    {
      type: "transfer",
      token: "0x9e29b3aada05bf2d2c827af80bd28dc0b9b4fb0c",
      to: "0xEfdB15EE6e7C7C7906cb230AfF1EDb75CcBaA74F",
      amount: "100000",
    },
  ],
};
const getCompileHandler: RequestHandler = (req: Request, res: Response) => {
  try {
    const chain =
      typeof req.query.chain === "string" ? req.query.chain : undefined;
    // Fresh object each call (never mutate SAMPLE_REQUEST); inject the server
    // clock so the sample shows the safe-by-default expiry gate too.
    const request: CompileRequest = {
      ...(chain ? { ...SAMPLE_REQUEST, chain } : SAMPLE_REQUEST),
      now: Math.floor(Date.now() / 1000),
    };
    const intent = compileIntent(request);
    res.status(200).json({
      ok: true,
      note: "Sample compiled intent. POST {chain, conditions, actions} to /compile-intent for a custom one; see GET /capabilities and /recipes.",
      intent,
    });
  } catch (err) {
    if (err instanceof ValidationError) {
      res.status(400).json({ ok: false, error: err.message, code: "VALIDATION" });
      return;
    }
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
};

// Payment gating (when enabled) is applied globally above via buildX402Middleware.
app.get("/compile-intent", getCompileHandler);
app.post("/compile-intent", compileHandler);

// FREE pre-sign dry-run (Phase-1 item 14). Same body as /compile-intent (+ `initiator` for
// balance/allowance checks). Returns a verdict + fix-its, NEVER the signable payload — the
// free hook that leads to the paid compile. Not x402-gated (only /compile-intent is).
app.post("/simulate-intent", async (req: Request, res: Response) => {
  try {
    const result = await simulate(req.body as CompileRequest);
    res.status(200).json({ ok: true, simulation: result });
  } catch (err) {
    if (err instanceof ValidationError) {
      res.status(400).json({ ok: false, error: err.message, code: "VALIDATION" });
      return;
    }
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
});

// 404 JSON fallback so unknown routes return the {ok:false,...} envelope rather
// than Express's default HTML page.
app.use((_req: Request, res: Response) => {
  res.status(404).json({ ok: false, error: "not found", code: "NOT_FOUND" });
});

// Terminal JSON error handler (4-arg signature required by Express). Catches
// body-parser failures that throw BEFORE the route handler runs — otherwise
// Express's default finalhandler would return an HTML stack-trace page, breaking
// the JSON error contract and leaking framework/filesystem internals.
app.use((err: unknown, _req: Request, res: Response, next: NextFunction) => {
  if (res.headersSent) {
    next(err);
    return;
  }
  const e = err as {
    type?: string;
    status?: number;
    statusCode?: number;
  };
  const rawStatus = Number(e.status ?? e.statusCode);
  const isBadJson = e.type === "entity.parse.failed";
  // body-parser tags all client-side body errors (too.large=413, unsupported
  // charset/encoding=415, aborted=400, ...) with a 4xx status; anything else is
  // an unexpected server fault.
  const isClient = isBadJson || (rawStatus >= 400 && rawStatus < 500);
  if (isClient) {
    const status = rawStatus >= 400 && rawStatus < 500 ? rawStatus : 400;
    res.status(status).json({
      ok: false,
      error: isBadJson ? "request body is not valid JSON" : "invalid request body",
      code: isBadJson ? "BAD_JSON" : "BAD_REQUEST",
    });
    return;
  }
  res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
});

/**
 * Start the HTTP listener. Exported (not auto-run on import) so the endpoint test
 * suite can import `app` and bind its own ephemeral port without this module
 * grabbing PORT. Returns the http.Server for lifecycle control.
 */
export function start(port: number = PORT): import("node:http").Server {
  return app.listen(port, () => {
    console.log(`[w3cash-asp] listening on http://localhost:${port}`);
    console.log(
      `[w3cash-asp] chain=${CHAIN_ID} processor=${PROCESSOR} — non-custodial intent compiler`
    );
  });
}

// Only listen when run as the process entrypoint (`tsx src/server.ts` /
// `node dist/server.js`). When imported by the test suite, argv[1] is the test
// runner, so this stays inert and the tests drive `app` / `start` themselves.
const isEntrypoint =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;
if (isEntrypoint) {
  start();
}

export { app };
