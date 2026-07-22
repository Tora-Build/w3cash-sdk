import { describe, it, expect } from "vitest";
import { toEventSelector, encodeAbiParameters, parseAbiParameters, pad, type Hex } from "viem";
import { parseLog, deriveStatus, computeStats, type EventRow, type RawLog } from "../src/parse.js";

const HASH = ("0x" + "ab".repeat(32)) as Hex;
const HASH2 = ("0x" + "cd".repeat(32)) as Hex;

/** A Legacy LocalCommandProcessed / WorkflowPaused log: data = abi.encode(seq, payloadHash). */
function legacyLog(sig: string, payloadHash: Hex, block: number, logIndex: number): RawLog {
  return {
    topics: [toEventSelector(sig)],
    data: encodeAbiParameters(parseAbiParameters("uint256, bytes32"), [1n, payloadHash]),
    blockNumber: "0x" + block.toString(16),
    transactionHash: "0x" + "11".repeat(32),
    logIndex: "0x" + logIndex.toString(16),
  };
}

/** A Design C WorkflowExecuted log: intentDigest indexed topic1, root topic2, executions in data. */
function designCExecuted(payloadHash: Hex, block: number): RawLog {
  return {
    topics: [toEventSelector("WorkflowExecuted(bytes32,address,uint32)"), payloadHash, pad("0xdead")],
    data: "0x" + "01".padStart(64, "0"),
    blockNumber: "0x" + block.toString(16),
    transactionHash: "0x" + "22".repeat(32),
    logIndex: "0x0",
  };
}

describe("parseLog", () => {
  it("parses a Legacy LocalCommandProcessed (executed) from data word 1", () => {
    const row = parseLog(legacyLog("LocalCommandProcessed(uint256,bytes32)", HASH, 100, 0), 84532);
    expect(row).not.toBeNull();
    expect(row!.kind).toBe("executed");
    expect(row!.payloadHash).toBe(HASH.toLowerCase());
    expect(row!.block).toBe(100);
    expect(row!.chainId).toBe(84532);
  });

  it("parses a Legacy WorkflowPaused (paused)", () => {
    const row = parseLog(legacyLog("WorkflowPaused(uint256,bytes32)", HASH, 100, 1), 1952);
    expect(row!.kind).toBe("paused");
    expect(row!.payloadHash).toBe(HASH.toLowerCase());
  });

  it("parses a Design C WorkflowExecuted from indexed topic1", () => {
    const row = parseLog(designCExecuted(HASH, 200), 196);
    expect(row!.kind).toBe("executed");
    expect(row!.payloadHash).toBe(HASH.toLowerCase());
  });

  it("returns null for an unrelated event topic0", () => {
    const row = parseLog({ topics: [toEventSelector("Transfer(address,address,uint256)")], data: "0x", blockNumber: "0x1", transactionHash: "0x0", logIndex: "0x0" }, 84532);
    expect(row).toBeNull();
  });
});

describe("deriveStatus", () => {
  const row = (kind: EventRow["kind"], block: number, logIndex = 0): EventRow => ({
    chainId: 84532, block, txHash: "0x" + block.toString(16).padStart(2, "0"), logIndex, event: "e", kind, payloadHash: HASH.toLowerCase(),
  });

  it("unknown when no events", () => {
    expect(deriveStatus([]).status).toBe("unknown");
  });
  it("executed when the last event is an execution", () => {
    expect(deriveStatus([row("paused", 10), row("executed", 20)]).status).toBe("executed");
  });
  it("waiting when the last event is a pause", () => {
    expect(deriveStatus([row("executed", 10), row("paused", 20)]).status).toBe("waiting");
  });
  it("cancelled dominates regardless of order", () => {
    expect(deriveStatus([row("executed", 30), row("cancelled", 5)]).status).toBe("cancelled");
  });
  it("counts executed/paused events + dedups tx hashes", () => {
    const r = deriveStatus([row("executed", 10), row("executed", 11), row("paused", 5)]);
    expect(r.executedEvents).toBe(2);
    expect(r.pausedEvents).toBe(1);
    expect(r.firstBlock).toBe(5);
    expect(r.lastBlock).toBe(11);
  });
});

describe("computeStats", () => {
  it("fire rate = fired / total over ALL recorded intents (incl. never-fired)", () => {
    const s = computeStats([
      { chainId: 84532, status: "executed" },
      { chainId: 84532, status: "waiting" },
      { chainId: 196, status: "executed" },
      { chainId: 196, status: "unknown" },
    ]);
    expect(s.total).toBe(4);
    expect(s.fired).toBe(2);
    expect(s.fireRate).toBe(0.5);
    expect(s.byChain[84532]).toEqual({ total: 2, fired: 1 });
    expect(s.byChain[196]).toEqual({ total: 2, fired: 1 });
  });
  it("fireRate is 0 (not NaN) for an empty set", () => {
    expect(computeStats([]).fireRate).toBe(0);
  });
});
