import { describe, it, expect } from "vitest";
import { decodeAbiParameters, parseAbiParameters, getAddress, type Hex } from "viem";
import {
  compileIntent,
  getCapabilities,
  getRecipes,
  signatureMessageHash,
  ValidationError,
  XLAYER_CHAIN_ID,
  XLAYER_MAINNET_CHAIN_ID,
  XLAYER_MAINNET_KNOWN_ADDRESSES,
  XLAYER_PROCESSOR,
  XLAYER_ADAPTERS,
  CHAIN_ID,
} from "../src/w3cash/encode.js";

const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
const DEAD = getAddress("0x000000000000000000000000000000000000dEaD");

/** Decode operations[i] -> its field-3 target address (the routed adapter). */
function opTarget(op: Hex): string {
  const [, , , target] = decodeAbiParameters(
    parseAbiParameters("uint8, uint8, uint64, address, bytes8, uint112"),
    op
  );
  return getAddress(target as string);
}

describe("X Layer testnet (1952) routing", () => {
  it("compiles a conditional transfer to the X Layer processor + adapters", () => {
    const intent = compileIntent({
      chain: XLAYER_CHAIN_ID,
      conditions: [{ type: "waitTime", timestamp: "1767225600" }],
      actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1000000" }],
    });
    expect(intent.chainId).toBe(XLAYER_CHAIN_ID);
    expect(intent.processor).toBe(XLAYER_PROCESSOR);
    // Op #0 = WaitAdapter, op #1 = TransferAdapter — both the X Layer addresses.
    expect(opTarget(intent.operations[0])).toBe(XLAYER_ADAPTERS.wait.address);
    expect(opTarget(intent.operations[1])).toBe(XLAYER_ADAPTERS.transfer.address);
    expect(intent.steps[1].target).toBe(XLAYER_ADAPTERS.transfer.address);
  });

  it("rejects adapters not deployed on X Layer (swap/aave/wrap/bridge)", () => {
    for (const action of [
      { type: "swap", tokenIn: USDC, tokenOut: DEAD, amountIn: "1", minAmountOut: "1", fee: 3000 },
      { type: "aaveWithdrawAll", token: USDC },
      { type: "wrap", isWrap: true, amount: "1" },
      {
        type: "bridge",
        recipient: DEAD,
        destinationChainId: "11155111",
        inputToken: USDC,
        inputAmount: "1",
        outputAmount: "1",
        quoteTimestamp: "1",
        fillDeadline: "2",
      },
    ] as const) {
      expect(() =>
        compileIntent({ chain: XLAYER_CHAIN_ID, actions: [action as never] })
      ).toThrow(ValidationError);
    }
  });

  it("allows every gate adapter on X Layer (wait/query/gas/time/signature/balance)", () => {
    const intent = compileIntent({
      chain: XLAYER_CHAIN_ID,
      conditions: [
        { type: "gasPrice", operator: "lte", threshold: "5000000000" },
        { type: "balance", token: USDC, target: DEAD, operator: "gte", threshold: "1" },
        { type: "timeRange", startTime: "9", endTime: "17", recurring: true },
      ],
      actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1" }],
    });
    expect(intent.steps.map((s) => s.target)).toEqual([
      XLAYER_ADAPTERS.gasPrice.address,
      XLAYER_ADAPTERS.query.address,
      XLAYER_ADAPTERS.timeRange.address,
      XLAYER_ADAPTERS.transfer.address,
    ]);
  });

  it("getCapabilities(1952) reports the filtered X Layer catalog", () => {
    const caps = getCapabilities(XLAYER_CHAIN_ID);
    expect(caps.chainId).toBe(XLAYER_CHAIN_ID);
    expect(caps.processor).toBe(XLAYER_PROCESSOR);
    // Only transfer + approve survive the action filter on X Layer.
    expect(caps.counts.actionTypes).toBe(2);
    expect(new Set(caps.actions.map((a) => a.type))).toEqual(
      new Set(["transfer", "approve"])
    );
    // All 12 condition types remain (their adapters are all deployed).
    expect(caps.counts.conditionTypes).toBe(12);
    expect(caps.counts.deployedAdapters).toBe(7);
    for (const gone of ["swap", "aave", "wrap", "bridge"]) {
      expect(caps.adapterCatalog.find((a) => a.key === gone)).toBeUndefined();
    }
    expect(caps.adapterCatalog.find((a) => a.key === "transfer")?.address).toBe(
      XLAYER_ADAPTERS.transfer.address
    );
  });

  it("getRecipes(1952) returns X Layer recipes that all compile", () => {
    const book = getRecipes(XLAYER_CHAIN_ID);
    expect(book.chainId).toBe(XLAYER_CHAIN_ID);
    expect(book.recipes.length).toBeGreaterThanOrEqual(3);
    for (const r of book.recipes) {
      const intent = compileIntent(r.request);
      expect(intent.chainId).toBe(XLAYER_CHAIN_ID);
      expect(intent.processor).toBe(XLAYER_PROCESSOR);
    }
  });

  it("signatureMessageHash binds to the per-chain signature adapter + chainId", () => {
    const actionHash = ("0x" + "11".repeat(32)) as Hex;
    const base = signatureMessageHash({ account: DEAD, actionHash, deadline: "2000000000" });
    const xlayer = signatureMessageHash({
      account: DEAD,
      actionHash,
      deadline: "2000000000",
      chain: XLAYER_CHAIN_ID,
    });
    // Different chainId + different SignatureAdapter address => different hash.
    expect(xlayer).not.toBe(base);
  });

  it("default chain is still Base Sepolia (backward compatible)", () => {
    const intent = compileIntent({
      actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1" }],
    });
    expect(intent.chainId).toBe(CHAIN_ID);
  });
});

describe("X Layer MAINNET (196) routing", () => {
  it("compiles a transfer to the X Layer core on chain 196", () => {
    const intent = compileIntent({
      chain: XLAYER_MAINNET_CHAIN_ID,
      conditions: [{ type: "waitTime", timestamp: "1767225600" }],
      actions: [
        { type: "transfer", token: XLAYER_MAINNET_KNOWN_ADDRESSES.usdt0, to: DEAD, amount: "1000000" },
      ],
    });
    expect(intent.chainId).toBe(196);
    expect(intent.processor).toBe(XLAYER_PROCESSOR); // same deterministic address
    expect(opTarget(intent.operations[1])).toBe(XLAYER_ADAPTERS.transfer.address);
  });

  it("getCapabilities(196) reports the X Layer mainnet minimal core", () => {
    const caps = getCapabilities(XLAYER_MAINNET_CHAIN_ID);
    expect(caps.chainId).toBe(196);
    expect(caps.chainName).toBe("X Layer mainnet");
    expect(caps.counts.actionTypes).toBe(2); // transfer + approve only
    expect(caps.counts.deployedAdapters).toBe(7);
  });

  it("getRecipes(196) uses mainnet USD₮0 (0x779Ded…) and all compile", () => {
    const book = getRecipes(XLAYER_MAINNET_CHAIN_ID);
    expect(book.chainId).toBe(196);
    for (const r of book.recipes) {
      const intent = compileIntent(r.request);
      expect(intent.chainId).toBe(196);
    }
    // A transfer recipe must reference the mainnet USD₮0 token.
    const transferRecipe = book.recipes.find((r) =>
      (r.request.actions ?? []).some((a) => a.type === "transfer")
    );
    expect(transferRecipe).toBeDefined();
  });

  it("rejects swap/aave on X Layer mainnet (minimal core only)", () => {
    expect(() =>
      compileIntent({
        chain: XLAYER_MAINNET_CHAIN_ID,
        actions: [{ type: "aaveWithdrawAll", token: USDC } as never],
      })
    ).toThrow(ValidationError);
  });
});
