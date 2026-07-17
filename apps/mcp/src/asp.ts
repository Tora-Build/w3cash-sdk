/**
 * Thin HTTP client for the live W3Cash Intent Compiler ASP.
 *
 * Every MCP tool is a one-to-one proxy over an ASP endpoint: fetch the JSON,
 * hand it back verbatim. This module owns the two concerns common to all of
 * them — a bounded request timeout and mapping any failure (network error,
 * non-2xx status, or an `{ ok: false }` envelope) into a single typed result
 * the tools turn into an MCP tool error instead of throwing.
 *
 * The ASP is public, non-custodial, and holds no keys, so no auth header is
 * sent. Base URL is configurable via ASP_BASE_URL for local/staging targets.
 */

import { payingFetch } from "./payer.js";

/** Base URL of the ASP, trailing slashes trimmed. Overridable via env. */
export const ASP_BASE_URL: string = (
  process.env.ASP_BASE_URL ?? "https://asp.w3.cash"
).replace(/\/+$/, "");

/** Per-request timeout. The ASP compiles/quotes synchronously; 15s is ample. */
const TIMEOUT_MS = 15_000;

/**
 * Outcome of an ASP call. `ok:true` carries the parsed JSON body; `ok:false`
 * carries a human-readable, already-contextualized error string that a tool can
 * surface directly as `isError` content.
 */
export type AspResult =
  | { readonly ok: true; readonly data: unknown }
  | { readonly ok: false; readonly error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Pull the most descriptive message out of an ASP `{ ok:false, error, code }` body. */
function extractError(body: unknown): string | undefined {
  if (!isRecord(body)) return undefined;
  const parts: string[] = [];
  if (typeof body.error === "string" && body.error.length > 0) parts.push(body.error);
  if (typeof body.code === "string" && body.code.length > 0) parts.push(`[${body.code}]`);
  return parts.length > 0 ? parts.join(" ") : undefined;
}

function describeError(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}

async function request(
  method: "GET" | "POST",
  path: string,
  body?: unknown,
): Promise<AspResult> {
  const url = `${ASP_BASE_URL}${path}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let res: Response;
  try {
    res = await payingFetch(url, {
      method,
      headers:
        body === undefined
          ? { accept: "application/json" }
          : { "content-type": "application/json", accept: "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (err) {
    const reason = controller.signal.aborted
      ? `timed out after ${TIMEOUT_MS}ms`
      : describeError(err);
    return { ok: false, error: `W3Cash ASP ${method} ${path} failed: ${reason}` };
  } finally {
    clearTimeout(timer);
  }

  const text = await res.text().catch(() => "");
  let parsed: unknown;
  if (text.length > 0) {
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = undefined;
    }
  }

  if (!res.ok) {
    const detail = extractError(parsed) ?? (text.length > 0 ? text : res.statusText);
    return {
      ok: false,
      error: `W3Cash ASP ${method} ${path} returned HTTP ${res.status}: ${detail}`,
    };
  }

  if (parsed === undefined) {
    return {
      ok: false,
      error: `W3Cash ASP ${method} ${path} returned a non-JSON body: ${text.slice(0, 500)}`,
    };
  }

  // The ASP wraps every response in an `{ ok, ... }` envelope. A 2xx with
  // `ok:false` is still a logical failure (validation, bridge-quote upstream).
  if (isRecord(parsed) && parsed.ok === false) {
    return {
      ok: false,
      error: `W3Cash ASP ${method} ${path} reported an error: ${
        extractError(parsed) ?? "unknown error"
      }`,
    };
  }

  return { ok: true, data: parsed };
}

/** GET an ASP endpoint (no body). */
export function aspGet(path: string): Promise<AspResult> {
  return request("GET", path);
}

/** POST a JSON body to an ASP endpoint. */
export function aspPost(path: string, body: unknown): Promise<AspResult> {
  return request("POST", path, body);
}
