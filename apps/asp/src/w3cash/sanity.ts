/**
 * Compile-time sanity lints (Phase-1 item 18) — best-effort, NEVER-blocks advisories folded
 * into a compiled intent's `warnings`. These catch the high-signal "did you mean…?" mistakes an
 * agent commonly makes before it signs, WITHOUT any chain read (pure, deterministic, testable).
 *
 * Design rule: only lint what has a LOW false-positive rate. A warning must be almost-certainly a
 * real mistake (e.g. a gas threshold in gwei-not-wei, a wait time already in the past), never a
 * judgment call on a legitimate value. It advises; it never changes the compiled bytes or blocks.
 */
import type { CompileRequest } from "./encode.js";

/** Parse a Numeric-ish value to bigint, or null if not a clean integer. */
function toBig(v: unknown): bigint | null {
  try {
    if (typeof v === "number") return Number.isInteger(v) ? BigInt(v) : null;
    if (typeof v === "string" && /^-?(0x[0-9a-fA-F]+|[0-9]+)$/.test(v.trim())) return BigInt(v.trim());
  } catch {
    /* fall through */
  }
  return null;
}

const ONE_GWEI = 1_000_000_000n;
// Below this, a gas threshold is almost certainly gwei mistaken for wei (real L2 gas prices are
// ~1e6–1e9 wei; a threshold under 1000 wei can never be a deliberate ceiling).
const GAS_IMPLAUSIBLE_WEI = 1000n;
// Amounts above this are almost certainly a decimals mistake (1e30 = a trillion 18-dec tokens).
const AMOUNT_IMPLAUSIBLE = 10n ** 30n;
// Year-2100 threshold reused from the infinite-deadline convention: a "timestamp" above this is
// not a real unix time and is handled elsewhere (infinite sentinel) — don't lint it as past/future.
const YEAR_2100 = 4_102_444_800n;

/** Return best-effort sanity warnings for a compile request. Never throws. */
export function sanityWarnings(request: CompileRequest): string[] {
  const out: string[] = [];
  const now = request?.now !== undefined ? toBig(request.now) : null;

  const conditions = Array.isArray(request?.conditions) ? request.conditions : [];
  const actions = Array.isArray(request?.actions) ? request.actions : [];

  for (const c of conditions) {
    if (!c || typeof c !== "object") continue;
    const cond = c as Record<string, unknown>;
    const type = cond.type;

    // Gas threshold in gwei instead of wei — the single most common gas-gate mistake.
    if (type === "gasPrice") {
      const t = toBig(cond.threshold);
      if (t !== null && t > 0n && t < GAS_IMPLAUSIBLE_WEI) {
        out.push(
          `SANITY: gasPrice threshold ${t.toString()} wei is implausibly low — gas thresholds are in WEI (5 gwei = ${(
            5n * ONE_GWEI
          ).toString()}). Did you mean gwei?`
        );
      }
    }

    // Absolute wait time already in the past → the gate is immediately satisfiable.
    if (type === "waitTime" && now !== null) {
      const ts = toBig(cond.timestamp);
      if (ts !== null && ts > 0n && ts < YEAR_2100 && ts < now) {
        out.push(
          `SANITY: waitTime ${ts.toString()} is in the past (now ${now.toString()}); this gate is already satisfiable and will not defer execution.`
        );
      }
    }

    // A one-time (non-recurring) timeRange fully in the past can never be met.
    if (type === "timeRange" && cond.recurring === false && now !== null) {
      const end = toBig(cond.endTime);
      if (end !== null && end > 0n && end < YEAR_2100 && end < now) {
        out.push(
          `SANITY: timeRange endTime ${end.toString()} is already in the past (now ${now.toString()}); a one-time window that has closed can NEVER be met.`
        );
      }
    }

    // A zero/absent price target is trivially satisfiable for a >= gate.
    if ((type === "price" || type === "waitPriceGte" || type === "waitPriceLte")) {
      const p = toBig(cond.targetPrice);
      if (p !== null && p === 0n) {
        out.push(`SANITY: ${String(type)} targetPrice is 0 — the gate may be trivially satisfiable; double-check the value + feed decimals.`);
      }
    }
  }

  // Implausibly large token amounts (likely a decimals slip).
  const amountFields: Array<[string, string]> = [
    ["transfer", "amount"], ["approve", "amount"], ["swap", "amountIn"],
    ["aaveDeposit", "amount"], ["aaveWithdraw", "amount"], ["bridge", "inputAmount"],
  ];
  for (const a of actions) {
    if (!a || typeof a !== "object") continue;
    const act = a as Record<string, unknown>;
    for (const [t, field] of amountFields) {
      if (act.type === t) {
        const amt = toBig(act[field]);
        if (amt !== null && amt > AMOUNT_IMPLAUSIBLE) {
          out.push(
            `SANITY: ${t}.${field} = ${amt.toString()} is extremely large (>1e30) — verify the token decimals (amounts are in the smallest unit).`
          );
        }
      }
    }
  }

  return out;
}
