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
  ValidationError,
  PROCESSOR,
  CHAIN_ID,
  type CompileRequest,
} from "./w3cash/encode.js";

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
} as const;
void paymentConfig; // referenced by the (not-yet-wired) x402 middleware

// Health / self-check endpoint (used by OKX A2MCP endpoint verification).
app.get("/health", (_req: Request, res: Response) => {
  res.status(200).json({ ok: true, service: "w3cash-intent-compiler" });
});

// Capability discovery — supported actions/conditions + adapter catalog.
app.get("/capabilities", (_req: Request, res: Response) => {
  res.status(200).json({ ok: true, capabilities: getCapabilities() });
});

/**
 * A2MCP tool endpoint. Non-custodial: compiles a signable W3Cash intent from a
 * structured body {chain?, nonce?, seq?, initiator?, conditions[], actions[]}.
 * Returns the operation/input arrays, the assembled instruction, the payload
 * hash, and the raw 32-byte message the initiator must EIP-191 personal-sign.
 * This ASP NEVER signs or holds keys.
 */
const compileHandler: RequestHandler = (req: Request, res: Response) => {
  try {
    const body = req.body as CompileRequest;
    const intent = compileIntent(body);
    res.status(200).json({ ok: true, intent });
  } catch (err) {
    if (err instanceof ValidationError) {
      res.status(400).json({ ok: false, error: err.message, code: "VALIDATION" });
      return;
    }
    // Never echo internal error messages to an external caller.
    res.status(500).json({ ok: false, error: "internal error", code: "INTERNAL" });
  }
};

// Phase-1: no payment gate. To add x402, unshift the 402-gate middleware here.
const paidMiddlewares: RequestHandler[] = [];
app.post("/compile-intent", ...paidMiddlewares, compileHandler);

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
