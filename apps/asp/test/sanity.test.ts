import { describe, it, expect } from "vitest";
import { sanityWarnings } from "../src/w3cash/sanity.js";
import { getAddress } from "viem";

const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
const DEAD = getAddress("0x000000000000000000000000000000000000dEaD");

describe("sanityWarnings (item 18)", () => {
  it("flags a gasPrice threshold in gwei-not-wei", () => {
    const w = sanityWarnings({ conditions: [{ type: "gasPrice", operator: "lte", threshold: "5" } as never] });
    expect(w.some((x) => x.includes("gasPrice") && x.includes("WEI"))).toBe(true);
  });

  it("does NOT flag a plausible wei gas threshold", () => {
    const w = sanityWarnings({ conditions: [{ type: "gasPrice", operator: "lte", threshold: "5000000000" } as never] });
    expect(w.some((x) => x.includes("gasPrice"))).toBe(false);
  });

  it("flags a waitTime already in the past (given now)", () => {
    const w = sanityWarnings({ now: 2_000_000_000, conditions: [{ type: "waitTime", timestamp: 1 } as never] });
    expect(w.some((x) => x.includes("waitTime") && x.includes("past"))).toBe(true);
  });

  it("does NOT flag a future waitTime", () => {
    const w = sanityWarnings({ now: 1_000, conditions: [{ type: "waitTime", timestamp: 2_000_000_000 } as never] });
    expect(w.some((x) => x.includes("waitTime"))).toBe(false);
  });

  it("flags a closed one-time timeRange window", () => {
    const w = sanityWarnings({
      now: 2_000_000_000,
      conditions: [{ type: "timeRange", startTime: 1, endTime: 100, recurring: false } as never],
    });
    expect(w.some((x) => x.includes("timeRange") && x.includes("NEVER"))).toBe(true);
  });

  it("flags an implausibly large amount (decimals slip)", () => {
    const w = sanityWarnings({
      actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1" + "0".repeat(31) } as never],
    });
    expect(w.some((x) => x.includes("extremely large"))).toBe(true);
  });

  it("returns nothing for a clean intent", () => {
    const w = sanityWarnings({
      now: 1_000,
      conditions: [{ type: "gasPrice", operator: "lte", threshold: "20000000000" } as never],
      actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1000000" } as never],
    });
    expect(w).toEqual([]);
  });

  it("never throws on malformed input", () => {
    expect(() => sanityWarnings({ conditions: [null as never, { type: "gasPrice" } as never] })).not.toThrow();
  });
});
