/**
 * W3Cash telemetry worker (Phase-1 item 17). Two jobs:
 *   scheduled() — a cron tick that indexes the deployed processor's events on each chain into D1
 *                 (paged, resumable, idempotent). This is the "watcher" — it READS public chain
 *                 events; it never signs or holds funds, and it doesn't depend on who relayed a tx.
 *   fetch()     — read-only status/telemetry endpoints an agent (or a dashboard) queries.
 *
 * Read-only sidecar: the compiler (/compile-intent) stays stateless. The only write from outside is
 * the optional, auth'd POST /record the ASP fires at compile time to store an intent's metadata.
 */
import { resolveChains } from "./config.js";
import { blockNumber, getLogs } from "./rpc.js";
import { parseLog, deriveStatus, computeStats, type EventRow } from "./parse.js";
import {
  getCursor, setCursor, upsertEvents, eventsForHash, recordIntent, intentsForInitiator, allIntentStatuses,
  type D1Like,
} from "./db.js";

export interface Env {
  DB: D1Like;
  RECORD_SECRET?: string; // shared secret the ASP presents to POST /record
  [key: string]: unknown;
}

/** Index one chain from its cursor to head, in <= logChunk-block pages (idempotent upserts). */
async function indexChain(env: Env, cfg: ReturnType<typeof resolveChains>[number], nowSec: number): Promise<number> {
  const head = await blockNumber(cfg.rpc);
  // Index only up to a finality-buffered head: the cursor is monotonic and events are append-only,
  // so a log emitted on a block that a shallow reorg later orphans would otherwise persist forever
  // and corrupt status/fireRate. Staying `confirmations` blocks behind the tip avoids that for
  // shallow reorgs. (Deep-reorg reconcile — DELETE + re-scan with block-hash divergence — is a
  // deferred follow-up.) (round-5 audit)
  const safeHead = head - cfg.confirmations;
  let from = (await getCursor(env.DB, cfg.chainId, cfg.startBlock)) + 1;
  if (from > safeHead) return 0;
  let indexed = 0;
  // Bound work per tick so one cron invocation can't run unbounded.
  const MAX_PAGES = 20;
  for (let page = 0; page < MAX_PAGES && from <= safeHead; page++) {
    const to = Math.min(from + cfg.logChunk - 1, safeHead);
    const logs = await getLogs(cfg.rpc, cfg.processor, from, to);
    const rows = logs.map((l) => parseLog(l, cfg.chainId)).filter((r): r is NonNullable<typeof r> => r !== null);
    if (rows.length) { await upsertEvents(env.DB, rows, nowSec); indexed += rows.length; }
    await setCursor(env.DB, cfg.chainId, to);
    from = to + 1;
  }
  return indexed;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });
}

/** Length-independent, short-circuit-free string comparison (round-3 audit). */
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < ab.length; i++) diff |= ab[i]! ^ (bb[i] ?? 0);
  return diff === 0;
}

export default {
  async scheduled(_event: unknown, env: Env): Promise<void> {
    const nowSec = Math.floor(Date.now() / 1000);
    for (const cfg of resolveChains(env as Record<string, string | undefined>)) {
      try { await indexChain(env, cfg, nowSec); }
      catch (e) { console.error(`[telemetry] index ${cfg.chainId} failed:`, e instanceof Error ? e.message : e); }
    }
  },

  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const p = url.pathname;

    if (p === "/health") return json({ ok: true, service: "w3cash-telemetry" });

    // GET /intent/:hash[?chainId=] — status of one intent, derived from its chain events. The
    // Legacy payloadHash has no chainId in its preimage and the same processor is indexed on
    // multiple chains, so a bare hash can match rows on more than one chain. With ?chainId= we
    // scope to that chain; without it we report PER CHAIN so identical hashes never conflate
    // (round-4 audit — eventsForHash previously ran unscoped).
    const m = p.match(/^\/intent\/(0x[0-9a-fA-F]{64})$/);
    if (m && req.method === "GET") {
      const hash = m[1]!;
      const chainParam = url.searchParams.get("chainId");
      if (chainParam !== null) {
        const cid = Number(chainParam);
        if (!Number.isInteger(cid) || cid <= 0) return json({ ok: false, error: "chainId must be a positive integer" }, 400);
        const rows = await eventsForHash(env.DB, hash, cid);
        return json({ ok: true, payloadHash: hash.toLowerCase(), chainId: cid, report: deriveStatus(rows) });
      }
      const rows = await eventsForHash(env.DB, hash);
      const byChain: Record<number, EventRow[]> = {};
      for (const r of rows) (byChain[r.chainId] ??= []).push(r);
      const reports = Object.entries(byChain).map(([cid, rs]) => ({ chainId: Number(cid), report: deriveStatus(rs) }));
      return json({ ok: true, payloadHash: hash.toLowerCase(), reports });
    }

    // GET /intents?initiator=0x... — the caller's recorded intents (needs a prior /record).
    if (p === "/intents" && req.method === "GET") {
      const initiator = url.searchParams.get("initiator");
      if (!initiator || !/^0x[0-9a-fA-F]{40}$/.test(initiator)) return json({ ok: false, error: "initiator query param required" }, 400);
      const list = await intentsForInitiator(env.DB, initiator);
      const withStatus = [];
      for (const it of list) {
        // Scope status to the intent's OWN chain (round-4 audit: an unscoped lookup let a
        // same-hash event on another chain flip the reported status).
        const rows = await eventsForHash(env.DB, it.payloadHash, it.chainId);
        const status = deriveStatus(rows).status;
        // Only disclose intents that already have on-chain events to this UNAUTHENTICATED endpoint.
        // A never-broadcast intent (status 'unknown') exists only as ASP-recorded compile metadata,
        // which is not otherwise public — hiding it prevents enumeration of a target's pending plans.
        // The ASP-authored free-text `summary` is likewise never returned here (round-4/5 audit).
        if (status === "unknown") continue;
        // compiledAt (off-chain compile timestamp) is omitted from this UNAUTHENTICATED endpoint —
        // it leaks compile-to-execute latency for a known address; on-chain block times remain public
        // via the per-event report (round-6 audit).
        withStatus.push({
          payloadHash: it.payloadHash, chainId: it.chainId, initiator: it.initiator, status,
        });
      }
      return json({ ok: true, initiator: initiator.toLowerCase(), intents: withStatus });
    }

    // GET /stats — neutral reliability stats over all recorded intents (recomputable by anyone).
    if (p === "/stats" && req.method === "GET") {
      const statuses = await allIntentStatuses(env.DB);
      return json({ ok: true, stats: computeStats(statuses) });
    }

    // POST /record — the ASP registers a compiled intent's metadata (auth via shared secret).
    if (p === "/record" && req.method === "POST") {
      // Constant-time compare (round-3 audit): a `!==` string compare short-circuits and leaks the
      // secret length/prefix via timing.
      if (!env.RECORD_SECRET || !timingSafeEqual(req.headers.get("x-record-secret") ?? "", env.RECORD_SECRET))
        return json({ ok: false, error: "unauthorized" }, 401);
      const b = (await req.json().catch(() => null)) as { payloadHash?: string; chainId?: number; initiator?: string; summary?: string } | null;
      const hash = b?.payloadHash ?? "";
      if (!/^0x[0-9a-fA-F]{64}$/.test(hash) || typeof b?.chainId !== "number") return json({ ok: false, error: "payloadHash + chainId required" }, 400);
      await recordIntent(env.DB, hash, b.chainId, b.initiator ?? null, b.summary ?? null, Math.floor(Date.now() / 1000));
      return json({ ok: true });
    }

    return json({ ok: false, error: "not found" }, 404);
  },
};
