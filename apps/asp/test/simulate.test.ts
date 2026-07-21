import { describe, it, expect } from "vitest";
import { keccak256, toBytes, encodeAbiParameters, parseAbiParameters, getAddress, type Hex, type Address } from "viem";
import { simulateIntent, type SimReader } from "../src/simulate.js";
import { XLAYER_MAINNET_CHAIN_ID, XLAYER_ADAPTERS } from "../src/w3cash/encode.js";

const USDT0 = getAddress("0x779Ded0c9e1022225f8E0630b35a9b54bE713736");
const HOLDER = getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3");
const PAUSE_WORD = keccak256(toBytes("PAUSE_EXECUTION"));

/** A mock reader with tunable gate result + balance/allowance. */
function mockReader(opts: {
  gatePass?: boolean;          // what eth_call'd gates return
  balance?: bigint;
  allowance?: bigint;
  gasPrice?: bigint;
  fail?: boolean;              // reject everything (=> unknown)
}): SimReader {
  const gateRet: Hex = opts.gatePass
    ? ("0x" + "20".padStart(64, "0") + "00".repeat(32)) as Hex // abi.encode(bytes "") — empty inner
    : (encodeAbiParameters(parseAbiParameters("bytes"), [PAUSE_WORD]) as Hex);
  return {
    ethCall: async () => { if (opts.fail) throw new Error("rpc"); return gateRet; },
    balanceOf: async () => { if (opts.fail || opts.balance === undefined) throw new Error("rpc"); return opts.balance; },
    allowance: async () => { if (opts.fail || opts.allowance === undefined) throw new Error("rpc"); return opts.allowance; },
    gasPrice: async () => { if (opts.fail || opts.gasPrice === undefined) throw new Error("rpc"); return opts.gasPrice; },
  };
}

const transfer = { type: "transfer" as const, token: USDT0, to: HOLDER, amount: "1000000" };
const balanceGate = { type: "balance" as const, token: USDT0, target: HOLDER, operator: "gte" as const, threshold: "1000000" };

describe("simulateIntent verdicts", () => {
  it("would-fire: gate passes + balance & allowance sufficient", async () => {
    const r = await simulateIntent(
      { chain: XLAYER_MAINNET_CHAIN_ID, initiator: HOLDER, expiry: "none", conditions: [balanceGate], actions: [transfer] },
      mockReader({ gatePass: true, balance: 5_000_000n, allowance: 5_000_000n })
    );
    expect(r.verdict).toBe("would-fire");
    expect(r.gates[0].status).toBe("pass");
    expect(r.setup[0].ok).toBe(true);
    // never leaks the payload
    expect(r).not.toHaveProperty("toSign");
    expect(r).not.toHaveProperty("operations");
  });

  it("blocked: gate not met", async () => {
    const r = await simulateIntent(
      { chain: XLAYER_MAINNET_CHAIN_ID, initiator: HOLDER, expiry: "none", conditions: [balanceGate], actions: [transfer] },
      mockReader({ gatePass: false, balance: 5_000_000n, allowance: 5_000_000n })
    );
    expect(r.verdict).toBe("blocked");
    expect(r.gates[0].status).toBe("blocked");
  });

  it("needs-setup: allowance too low → fix-it names the adapter", async () => {
    const r = await simulateIntent(
      { chain: XLAYER_MAINNET_CHAIN_ID, initiator: HOLDER, expiry: "none", conditions: [balanceGate], actions: [transfer] },
      mockReader({ gatePass: true, balance: 5_000_000n, allowance: 0n })
    );
    expect(r.verdict).toBe("needs-setup");
    expect(r.setup[0].ok).toBe(false);
    expect(r.setup[0].spender).toBe(XLAYER_ADAPTERS.transfer.address);
    expect(r.setup[0].fix).toContain("approve");
  });

  it("needs-setup takes priority over a blocked gate", async () => {
    const r = await simulateIntent(
      { chain: XLAYER_MAINNET_CHAIN_ID, initiator: HOLDER, expiry: "none", conditions: [balanceGate], actions: [transfer] },
      mockReader({ gatePass: false, balance: 0n, allowance: 0n })
    );
    expect(r.verdict).toBe("needs-setup");
  });

  it("unknown: rpc failure degrades gracefully, never throws", async () => {
    const r = await simulateIntent(
      { chain: XLAYER_MAINNET_CHAIN_ID, initiator: HOLDER, expiry: "none", conditions: [balanceGate], actions: [transfer] },
      mockReader({ fail: true })
    );
    expect(r.verdict).toBe("unknown");
    expect(r.gates[0].status).toBe("unknown");
  });

  it("gasPrice gate: compares current gas to the threshold", async () => {
    const gasGate = { type: "gasPrice" as const, operator: "lte" as const, threshold: "5000000000" };
    const r = await simulateIntent(
      { chain: XLAYER_MAINNET_CHAIN_ID, initiator: HOLDER, expiry: "none", conditions: [gasGate], actions: [transfer] },
      mockReader({ gatePass: true, balance: 5_000_000n, allowance: 5_000_000n, gasPrice: 1_000_000_000n })
    );
    expect(r.gates[0].type).toBe("gasPrice");
    expect(r.gates[0].status).toBe("pass"); // 1 gwei <= 5 gwei
  });

  it("no initiator: skips setup checks, notes it", async () => {
    const r = await simulateIntent(
      { chain: XLAYER_MAINNET_CHAIN_ID, expiry: "none", conditions: [balanceGate], actions: [transfer] },
      mockReader({ gatePass: true })
    );
    expect(r.setup).toHaveLength(0);
    expect(r.notes.some((n) => n.includes("initiator"))).toBe(true);
  });
});
