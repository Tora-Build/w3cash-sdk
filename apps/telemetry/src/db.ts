/**
 * D1 SQL glue. Thin wrappers around the Cloudflare D1 API (env.DB). Not unit-tested (needs the
 * D1 runtime) — the transform logic they carry is in parse.ts, which is. `nowSec` is injected so
 * the worker stays deterministic where it matters.
 */
import type { EventRow, IntentStatus } from "./parse.js";

/** Subset of the D1Database API we use — declared locally so this compiles without CF types. */
export interface D1Like {
  prepare(sql: string): {
    bind(...args: unknown[]): {
      run(): Promise<unknown>;
      all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
      first<T = Record<string, unknown>>(): Promise<T | null>;
    };
  };
  batch(stmts: unknown[]): Promise<unknown>;
}

export async function getCursor(db: D1Like, chainId: number, fallback: number): Promise<number> {
  const row = await db.prepare("SELECT last_block FROM cursors WHERE chain_id = ?").bind(chainId).first<{ last_block: number }>();
  return row ? row.last_block : fallback;
}

export async function setCursor(db: D1Like, chainId: number, block: number): Promise<void> {
  await db.prepare("INSERT INTO cursors (chain_id, last_block) VALUES (?, ?) ON CONFLICT(chain_id) DO UPDATE SET last_block = excluded.last_block")
    .bind(chainId, block).run();
}

export async function upsertEvents(db: D1Like, rows: EventRow[], nowSec: number): Promise<void> {
  for (const r of rows) {
    await db.prepare(
      "INSERT OR IGNORE INTO events (chain_id, tx_hash, log_index, block, event, kind, payload_hash, indexed_at) VALUES (?,?,?,?,?,?,?,?)"
    ).bind(r.chainId, r.txHash, r.logIndex, r.block, r.event, r.kind, r.payloadHash, nowSec).run();
  }
}

/**
 * Events for a payloadHash. MUST be scoped by chainId wherever the caller has one: the deployed
 * Legacy processor hashes `keccak256(payload)` with no chainId in the preimage, and the same
 * processor address is indexed on X Layer testnet(1952) AND mainnet(196), so an identical intent
 * yields the same payloadHash on both chains. Without the chain predicate a testnet row would
 * contaminate the mainnet intent's reported status (round-4 audit). When chainId is omitted the
 * caller MUST group the rows per chain before deriving a status (see index.ts /intent/:hash).
 */
export async function eventsForHash(db: D1Like, payloadHash: string, chainId?: number): Promise<EventRow[]> {
  const cols =
    "SELECT chain_id AS chainId, tx_hash AS txHash, log_index AS logIndex, block, event, kind, payload_hash AS payloadHash FROM events WHERE payload_hash = ?";
  if (chainId === undefined) {
    const { results } = await db.prepare(`${cols} ORDER BY chain_id, block, log_index`)
      .bind(payloadHash.toLowerCase()).all<EventRow>();
    return results;
  }
  const { results } = await db.prepare(`${cols} AND chain_id = ? ORDER BY block, log_index`)
    .bind(payloadHash.toLowerCase(), chainId).all<EventRow>();
  return results;
}

export async function recordIntent(
  db: D1Like, payloadHash: string, chainId: number, initiator: string | null, summary: string | null, nowSec: number
): Promise<void> {
  await db.prepare(
    "INSERT OR REPLACE INTO intents (payload_hash, chain_id, initiator, summary, compiled_at) VALUES (?,?,?,?,?)"
  ).bind(payloadHash.toLowerCase(), chainId, initiator?.toLowerCase() ?? null, summary, nowSec).run();
}

export interface IntentRow { payloadHash: string; chainId: number; initiator: string | null; summary: string | null; compiledAt: number }

export async function intentsForInitiator(db: D1Like, initiator: string): Promise<IntentRow[]> {
  const { results } = await db.prepare(
    "SELECT payload_hash AS payloadHash, chain_id AS chainId, initiator, summary, compiled_at AS compiledAt FROM intents WHERE initiator = ? ORDER BY compiled_at DESC LIMIT 200"
  ).bind(initiator.toLowerCase()).all<IntentRow>();
  return results;
}

/** All recorded intents joined to their derived status — the neutral stats denominator. */
export async function allIntentStatuses(db: D1Like): Promise<{ chainId: number; status: IntentStatus }[]> {
  // executed if any 'executed' event; else cancelled if any 'cancelled'; else waiting if any event;
  // else unknown (recorded but never seen on-chain).
  const { results } = await db.prepare(
    `SELECT i.chain_id AS chainId,
       CASE
         WHEN SUM(CASE WHEN e.kind='executed' THEN 1 ELSE 0 END) > 0 THEN 'executed'
         WHEN SUM(CASE WHEN e.kind='cancelled' THEN 1 ELSE 0 END) > 0 THEN 'cancelled'
         WHEN COUNT(e.kind) > 0 THEN 'waiting'
         ELSE 'unknown'
       END AS status
     FROM intents i
     LEFT JOIN events e ON e.payload_hash = i.payload_hash AND e.chain_id = i.chain_id
     GROUP BY i.payload_hash, i.chain_id`
  ).bind().all<{ chainId: number; status: IntentStatus }>();
  return results;
}
