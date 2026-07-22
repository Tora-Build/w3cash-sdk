/**
 * Telemetry core (Phase-1 item 17) — PURE, testable transforms. No CF/D1/RPC here.
 *
 * The source of truth is the CHAIN: the deployed processor emits an event per execution/pause,
 * each carrying the intent's `payloadHash`. This module turns a raw eth_getLogs log into a row,
 * derives an intent's status from its rows, and computes neutral reliability stats — all pure so
 * they can be unit-tested without the Cloudflare runtime or a live chain. The worker (index.ts)
 * wires these to D1 + RPC.
 */
import { toEventSelector, type Hex } from "viem";

export type EventKind = "executed" | "paused" | "cancelled";

/** Where an event carries the intent's payloadHash: an indexed topic, or a data word. */
type HashFrom = { kind: "topic"; index: number } | { kind: "data"; word: number };

interface EventDef {
  readonly sig: string;
  readonly kind: EventKind;
  readonly hashFrom: HashFrom;
}

/**
 * Event catalogue for BOTH the deployed Legacy processor (nonce-based) and the future Design C
 * processor — keyed by topic0 so whichever is deployed on a chain is indexed. Same-named events
 * with different signatures have distinct topic0s, so they coexist safely.
 */
const EVENT_DEFS: readonly EventDef[] = [
  // Legacy (deployed): payloadHash is the 2nd non-indexed data word.
  { sig: "LocalCommandProcessed(uint256,bytes32)", kind: "executed", hashFrom: { kind: "data", word: 1 } },
  { sig: "WorkflowPaused(uint256,bytes32)", kind: "paused", hashFrom: { kind: "data", word: 1 } },
  { sig: "NonceCancelled(address,uint256,uint256)", kind: "cancelled", hashFrom: { kind: "topic", index: 1 } },
  // Design C (future): intentDigest is indexed topic1.
  { sig: "WorkflowExecuted(bytes32,address,uint32)", kind: "executed", hashFrom: { kind: "topic", index: 1 } },
  { sig: "WorkflowPaused(bytes32,uint256)", kind: "paused", hashFrom: { kind: "topic", index: 1 } },
];

/** topic0 -> EventDef, computed once. */
export const EVENTS_BY_TOPIC0: Map<string, EventDef> = new Map(
  EVENT_DEFS.map((d) => [toEventSelector(d.sig).toLowerCase(), d])
);

/** The topic0 filter list for eth_getLogs (any of these events). */
export const EVENT_TOPIC0S: Hex[] = EVENT_DEFS.map((d) => toEventSelector(d.sig));

export interface RawLog {
  readonly topics: readonly string[];
  readonly data: string;
  readonly blockNumber: string; // hex
  readonly transactionHash: string;
  readonly logIndex: string; // hex
}

export interface EventRow {
  readonly chainId: number;
  readonly block: number;
  readonly txHash: string;
  readonly logIndex: number;
  readonly event: string;
  readonly kind: EventKind;
  readonly payloadHash: string;
}

/** Extract a 32-byte word (0x-prefixed) from data at word index `w`. */
function dataWord(data: string, w: number): string {
  const start = 2 + w * 64;
  return "0x" + data.slice(start, start + 64);
}

/** Parse a raw log into an EventRow, or null if its topic0 isn't one of ours. */
export function parseLog(log: RawLog, chainId: number): EventRow | null {
  const topic0 = (log.topics[0] ?? "").toLowerCase();
  const def = EVENTS_BY_TOPIC0.get(topic0);
  if (!def) return null;
  const payloadHash =
    def.hashFrom.kind === "topic"
      ? (log.topics[def.hashFrom.index] ?? "").toLowerCase()
      : dataWord(log.data, def.hashFrom.word).toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(payloadHash)) return null;
  return {
    chainId,
    block: Number.parseInt(log.blockNumber, 16),
    txHash: log.transactionHash,
    logIndex: Number.parseInt(log.logIndex, 16),
    event: def.sig,
    kind: def.kind,
    payloadHash,
  };
}

export type IntentStatus = "waiting" | "executed" | "cancelled" | "unknown";

export interface IntentReport {
  readonly status: IntentStatus;
  readonly executedEvents: number;
  readonly pausedEvents: number;
  readonly firstBlock: number | null;
  readonly lastBlock: number | null;
  readonly txHashes: readonly string[];
}

/**
 * Derive an intent's status from its (unordered) event rows. Latest event wins:
 * cancelled > (last kind). No rows => "unknown" (never seen on-chain yet).
 */
export function deriveStatus(rows: readonly EventRow[]): IntentReport {
  if (rows.length === 0) {
    return { status: "unknown", executedEvents: 0, pausedEvents: 0, firstBlock: null, lastBlock: null, txHashes: [] };
  }
  const sorted = [...rows].sort((a, b) => (a.block - b.block) || (a.logIndex - b.logIndex));
  const executedEvents = sorted.filter((r) => r.kind === "executed").length;
  const pausedEvents = sorted.filter((r) => r.kind === "paused").length;
  const anyCancelled = sorted.some((r) => r.kind === "cancelled");
  const first = sorted[0]!;              // sorted is non-empty (rows.length checked above)
  const last = sorted[sorted.length - 1]!;
  const status: IntentStatus = anyCancelled
    ? "cancelled"
    : last.kind === "executed"
      ? "executed"
      : last.kind === "paused"
        ? "waiting"
        : "unknown";
  return {
    status,
    executedEvents,
    pausedEvents,
    firstBlock: first.block,
    lastBlock: last.block,
    txHashes: [...new Set(sorted.map((r) => r.txHash))],
  };
}

export interface Stats {
  readonly total: number;
  readonly fired: number;
  readonly waiting: number;
  readonly cancelled: number;
  readonly fireRate: number; // fired / total, 0 if total 0
  readonly byChain: Readonly<Record<number, { total: number; fired: number }>>;
  readonly methodology: string;
}

/**
 * Neutral reliability stats over a set of KNOWN intents (each a {chainId, status}). The denominator
 * is every recorded intent — including never-fired — so the fire rate can't be inflated. Any third
 * party can recompute it from the same public chain events + the published intent set.
 */
export function computeStats(intents: readonly { chainId: number; status: IntentStatus }[]): Stats {
  const byChain: Record<number, { total: number; fired: number }> = {};
  let fired = 0, waiting = 0, cancelled = 0;
  for (const it of intents) {
    const c = (byChain[it.chainId] ??= { total: 0, fired: 0 });
    c.total += 1;
    if (it.status === "executed") { fired += 1; c.fired += 1; }
    else if (it.status === "waiting") waiting += 1;
    else if (it.status === "cancelled") cancelled += 1;
  }
  const total = intents.length;
  return {
    total, fired, waiting, cancelled,
    fireRate: total === 0 ? 0 : fired / total,
    byChain,
    methodology:
      "Denominator = every intent recorded at compile time (incl. never-fired). Numerator = intents with >=1 on-chain execution event. Recomputable by anyone from public chain events + the recorded intent set.",
  };
}
