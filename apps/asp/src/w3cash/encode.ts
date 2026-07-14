/**
 * W3Cash intent encoder — ground-truth port of the on-chain operation +
 * envelope encoding used by W3CashProcessor on Base Sepolia (chainId 84532).
 *
 * Source of truth (contracts, do NOT trust the SDK's action layer):
 *   - W3CashProcessor.sol        operation tuple + routing + signature scheme
 *   - utils/DataTypes.sol        Command / SignedPayload / PAUSE_EXECUTION
 *   - AdapterRegistry.sol        numeric-id -> address (local exec ignores it)
 *   - adapters/*Adapter.sol      per-adapter `input` (== inputs[i]) encodings
 *   - test/W3CashProcessor.t.sol, test/ActionAdapters.t.sol   confirmed shapes
 *
 * Routing recap (W3CashProcessor.sol:166-190): for a LOCAL (same-chain) op the
 * processor calls `IAdapter(target).execute{value}(initiator, inputs[i])`
 * DIRECTLY by the operation's field-3 `target` ADDRESS. It never consults the
 * registry and never reads field-1 `amb` on the local path. So the correct
 * "adapter id" for a single-chain Base-Sepolia intent is the deployed adapter
 * ADDRESS placed in `target`; `amb` stays 0 (it only selects a BRIDGE adapter
 * on the cross-chain branch). This module always builds LOCAL ops.
 */

import {
  encodeAbiParameters,
  encodePacked,
  parseAbiParameters,
  keccak256,
  concat,
  getAddress,
  isAddress,
  isHex,
  type Hex,
  type Address,
} from "viem";

// ---------------------------------------------------------------------------
// Deployment constants (Base Sepolia, chainId 84532)
// ---------------------------------------------------------------------------

export const CHAIN_ID = 84532 as const;

/** Local chain INDEX in the deployed AdapterRegistry (getChain(0) == 84532). */
export const LOCAL_CHAIN_INDEX = 0 as const;

export const PROCESSOR: Address = getAddress(
  "0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE"
);

export const ADAPTER_REGISTRY: Address = getAddress(
  "0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82"
);

/**
 * Deployed action/condition adapters. `registryId` is the numeric uint8 index
 * in AdapterRegistry (informational only for local exec — routing is by
 * `address`). `deployed` flags adapters whose given address has NO bytecode
 * on Base Sepolia (Balance / Price are stale per on-chain verification).
 */
export interface AdapterInfo {
  readonly name: string;
  readonly address: Address;
  readonly adapterId: Hex; // bytes4 self-tag (NEVER used for routing)
  readonly registryId: number | null;
  readonly deployed: boolean;
}

export const ADAPTERS = {
  wait: {
    name: "WaitAdapter",
    address: getAddress("0x8448b5f4abD40830C3B980390AbcfD2822719061"),
    adapterId: "0x05bdc82b",
    registryId: 0,
    deployed: true,
  },
  query: {
    name: "QueryAdapter",
    address: getAddress("0x4bC2F784CC76989dA6760Bc6bFCDc3F75c49ee9F"),
    adapterId: "0x7485829c",
    registryId: 1,
    deployed: true,
  },
  aave: {
    name: "AaveAdapter",
    address: getAddress("0xC330e841A259E8211D1Ea84c60efD8657DB1D546"),
    adapterId: "0x41415645", // ASCII "AAVE" — NOT keccak256("AaveAdapter")
    registryId: 2,
    deployed: true,
  },
  transfer: {
    name: "TransferAdapter",
    address: getAddress("0x6cA85B548d3512E355B63Fb390dBD197CF72d5eA"),
    adapterId: "0xecbe83c0",
    registryId: 3,
    deployed: true,
  },
  approve: {
    name: "ApproveAdapter",
    address: getAddress("0x1ff4459D35E956BA999ECf80C20Ad559904398A0"),
    adapterId: "0x61da13e4",
    registryId: 4,
    deployed: true,
  },
  swap: {
    name: "SwapAdapter",
    address: getAddress("0x9952735758c18d00D3cf2D1D0985A93b265a2126"),
    adapterId: "0xb38cc878",
    registryId: 5,
    deployed: true,
  },
  wrap: {
    name: "WrapAdapter",
    address: getAddress("0xD9142Ae0fCf4Fe81b39cD196BC37C9675DC86516"),
    adapterId: "0xb0cb501b",
    registryId: 6,
    deployed: true,
  },
  // Given addresses are NOT deployed on Base Sepolia (cast code -> 0x) and are
  // not registered at any scanned id. Kept for encoding completeness; callers
  // are warned in the compiled output that these targets are unusable today.
  balance: {
    name: "BalanceAdapter",
    address: getAddress("0x78f84ea305d41D97C540B55651A5A0CA01bF61De"),
    adapterId: "0xeeb11cfc",
    registryId: null,
    deployed: false,
  },
  price: {
    name: "PriceAdapter",
    address: getAddress("0xa28C0E516d624D82aBd75D6B84eC08A3be5c31d1"),
    adapterId: "0xe7b48d6c",
    registryId: null,
    deployed: false,
  },
} as const satisfies Record<string, AdapterInfo>;

/** bytes8 field-4 selector — DEAD per W3CashProcessor.sol:159, always zero. */
const DEAD_SELECTOR: Hex = "0x0000000000000000";

/** field-1 amb — bridge index, unused on the local path, always zero. */
const LOCAL_AMB = 0;

/** field-2 fee (uint64) — cross-chain only, zero for local. */
const LOCAL_FEE = 0n;

const ZERO_ADDRESS: Address = "0x0000000000000000000000000000000000000000";

// Aave selector-dispatch prefixes (AaveAdapter.sol:50-52).
const AAVE_OP = {
  deposit: "0x47e7ef24", // deposit(address,uint256)
  withdraw: "0xf3fef3a3", // withdraw(address,uint256)
  withdrawAll: "0xfa09e630", // withdrawAll(address)
} as const;

// ---------------------------------------------------------------------------
// Shared comparison-operator enum (Query / Balance / Price adapters)
// ---------------------------------------------------------------------------

export const OPERATORS = {
  lt: 0,
  gt: 1,
  lte: 2,
  gte: 3,
  eq: 4,
  neq: 5,
} as const;

export type OperatorName = keyof typeof OPERATORS;

/** WaitAdapter's own condition enum (WaitAdapter.sol:20-25). */
export const WAIT_TYPE = {
  timestamp: 0,
  block: 1,
  priceGte: 2,
  priceLte: 3,
} as const;

// ---------------------------------------------------------------------------
// Request types (discriminated unions)
// ---------------------------------------------------------------------------

/** Numeric-ish scalar accepted from JSON: decimal string, hex string, or number. */
export type Numeric = string | number;

export type ActionRequest =
  | { type: "transfer"; token: string; to: string; amount: Numeric; value?: Numeric }
  | { type: "approve"; token: string; spender: string; amount: Numeric; value?: Numeric }
  | {
      type: "swap";
      tokenIn: string;
      tokenOut: string;
      amountIn: Numeric;
      minAmountOut: Numeric;
      fee: Numeric; // Uniswap V3 pool fee tier, e.g. 3000
      value?: Numeric;
    }
  | { type: "aaveDeposit"; token: string; amount: Numeric; value?: Numeric }
  | { type: "aaveWithdraw"; token: string; amount: Numeric; value?: Numeric }
  | { type: "aaveWithdrawAll"; token: string; value?: Numeric }
  | {
      // ETH<->WETH. isWrap=true (ETH->WETH) forwards ETH as the op `value`
      // (defaults to `amount`); isWrap=false (WETH->ETH) needs prior WETH approve.
      type: "wrap";
      isWrap: boolean;
      amount: Numeric;
      value?: Numeric;
    };

export type ConditionRequest =
  | { type: "waitTime"; timestamp: Numeric }
  | { type: "waitBlock"; blockNumber: Numeric }
  | { type: "waitPriceGte"; feed: string; targetPrice: Numeric }
  | { type: "waitPriceLte"; feed: string; targetPrice: Numeric }
  | {
      type: "balance";
      token?: string; // omit / zero-address => native ETH balance
      target: string;
      operator: OperatorName | number;
      threshold: Numeric;
    }
  | {
      type: "price";
      feed: string;
      operator: OperatorName | number;
      targetPrice: Numeric;
      checkStaleness?: boolean;
    }
  | {
      type: "query";
      target: string;
      calldata: string; // hex, selector + args
      operator: OperatorName | number;
      expected: Numeric;
    };

export interface CompileRequest {
  chain?: Numeric; // must resolve to 84532 or local index 0 (default: local)
  nonce?: Numeric; // signer's current on-chain nonce (default 0)
  seq?: Numeric; // starting seq in header (default 0)
  initiator?: string; // optional; echoed into summary, not required
  conditions?: ConditionRequest[];
  actions?: ActionRequest[];
}

// ---------------------------------------------------------------------------
// Compiled output
// ---------------------------------------------------------------------------

export interface CompiledStep {
  readonly index: number;
  readonly kind: "condition" | "action";
  readonly type: string;
  readonly adapter: string;
  readonly target: Address;
  readonly value: string; // native ETH forwarded (wei), decimal string
  readonly operation: Hex;
  readonly input: Hex;
  readonly summary: string;
}

export interface CompiledIntent {
  readonly chainId: number;
  readonly processor: Address;
  readonly nonce: string;
  readonly seq: string;
  readonly operations: readonly Hex[];
  readonly inputs: readonly Hex[];
  readonly header: Hex;
  readonly payload: Hex;
  readonly payloadHash: Hex;
  readonly instruction: Hex;
  /**
   * The RAW 32-byte message the initiator must sign as an EIP-191 personal
   * message (the processor applies the "\x19Ethereum Signed Message" prefix).
   * = keccak256(abi.encodePacked(keccak256(payload), nonce)). Depends on nonce.
   */
  readonly toSign: Hex;
  readonly signing: {
    readonly scheme: "eip191-personal-sign";
    readonly messageHash: Hex;
    readonly nonce: string;
    /**
     * TRUE for every intent this ASP produces: W3CashProcessor.execute() verifies
     * but does NOT consume the nonce, so a captured signature is re-executable
     * until the initiator calls incrementNonce(). Programmatic clients should gate
     * on this flag. See `warnings` and `note`.
     */
    readonly replayable: boolean;
    /** How to build execute()'s arg once the signature is obtained. */
    readonly signedPayloadFormat: string;
    readonly note: string;
  };
  readonly steps: readonly CompiledStep[];
  readonly humanSummary: readonly string[];
  readonly warnings: readonly string[];
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

export class ValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ValidationError";
  }
}

const UINT_MAX = {
  u8: (1n << 8n) - 1n,
  u24: (1n << 24n) - 1n,
  u64: (1n << 64n) - 1n,
  u112: (1n << 112n) - 1n,
  u256: (1n << 256n) - 1n,
} as const;

/**
 * Hard cap on the number of operations in a single intent. Each step runs a
 * synchronous keccak256 + ABI-encode on the event loop, and the whole payload is
 * hashed again in encodeEnvelope, so an unbounded array is an asymmetric CPU-DoS
 * vector on a free, unauthenticated endpoint. 32 comfortably covers legitimate
 * complex intents while bounding worst-case work independent of body size.
 */
export const MAX_STEPS = 32 as const;

function toBigInt(value: Numeric, field: string): bigint {
  if (typeof value === "bigint") return value;
  if (typeof value === "number") {
    if (!Number.isInteger(value)) {
      throw new ValidationError(`${field} must be an integer, got ${value}`);
    }
    if (!Number.isSafeInteger(value)) {
      throw new ValidationError(
        `${field} exceeds safe integer range; pass it as a string`
      );
    }
    return BigInt(value);
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (trimmed === "") throw new ValidationError(`${field} is empty`);
    // Restrict to the documented contract: optional sign + decimal OR 0x-hex.
    // Bare BigInt() also accepts 0b/0o prefixes (e.g. "0b101" -> 5) and would
    // silently produce a different amount than the caller intended.
    if (!/^-?(0x[0-9a-fA-F]+|[0-9]+)$/.test(trimmed)) {
      throw new ValidationError(`${field} is not a valid integer: "${value}"`);
    }
    try {
      // BigInt() handles both decimal and 0x-hex strings.
      return BigInt(trimmed);
    } catch {
      throw new ValidationError(`${field} is not a valid integer: "${value}"`);
    }
  }
  throw new ValidationError(`${field} must be a string or number`);
}

function toUint(value: Numeric, field: string, max: bigint): bigint {
  const v = toBigInt(value, field);
  if (v < 0n) throw new ValidationError(`${field} must be non-negative`);
  if (v > max) throw new ValidationError(`${field} exceeds its uint bound`);
  return v;
}

function toInt256(value: Numeric, field: string): bigint {
  const v = toBigInt(value, field);
  const lim = 1n << 255n;
  if (v < -lim || v >= lim) {
    throw new ValidationError(`${field} out of int256 range`);
  }
  return v;
}

function addr(value: unknown, field: string): Address {
  if (typeof value !== "string" || !isAddress(value)) {
    throw new ValidationError(`${field} must be a valid address, got ${String(value)}`);
  }
  return getAddress(value);
}

function optAddr(value: unknown, field: string, fallback: Address): Address {
  if (value === undefined || value === null || value === "") return fallback;
  return addr(value, field);
}

function hexBytes(value: unknown, field: string): Hex {
  if (typeof value !== "string" || !isHex(value)) {
    throw new ValidationError(`${field} must be a 0x-hex string`);
  }
  // `value` is a "0x"-prefixed hex string here, so (length - 2) is the number of
  // hex digits. Reject odd counts, which do not form whole bytes. (viem's size()
  // never returns undefined, so the previous size()-based guard was dead.)
  if ((value.length - 2) % 2 !== 0) {
    throw new ValidationError(`${field} must have an even number of hex digits`);
  }
  return value;
}

function resolveOperator(value: OperatorName | number, field: string): number {
  if (typeof value === "number") {
    if (!Number.isInteger(value) || value < 0 || value > 5) {
      throw new ValidationError(`${field} numeric operator must be 0..5`);
    }
    return value;
  }
  // Own-property guard: a plain-object index would walk the prototype chain, so
  // strings like "toString"/"constructor"/"valueOf"/"__proto__" would resolve to
  // inherited Object.prototype members and bypass the whitelist. Check ownership
  // BEFORE reading the value.
  if (
    typeof value !== "string" ||
    !Object.prototype.hasOwnProperty.call(OPERATORS, value)
  ) {
    throw new ValidationError(
      `${field} must be one of ${Object.keys(OPERATORS).join(", ")} or 0..5`
    );
  }
  return OPERATORS[value as OperatorName];
}

// ---------------------------------------------------------------------------
// Low-level encoders
// ---------------------------------------------------------------------------

/**
 * operations[i] = abi.encode(uint8 chain, uint8 amb, uint64 fee,
 *                            address target, bytes8 selector, uint112 value)
 * (W3CashProcessor.sol:154-164 / DataTypes.Command).
 * For local execution: chain = LOCAL_CHAIN_INDEX(0), amb = 0, fee = 0,
 * selector = 0, target = deployed adapter address, value = native ETH.
 */
export function encodeOperation(target: Address, value: bigint): Hex {
  return encodeAbiParameters(
    parseAbiParameters("uint8, uint8, uint64, address, bytes8, uint112"),
    [LOCAL_CHAIN_INDEX, LOCAL_AMB, LOCAL_FEE, target, DEAD_SELECTOR, value]
  );
}

/** Assemble payload/header/instruction + payloadHash + toSign (envelope spec). */
export function encodeEnvelope(
  operations: readonly Hex[],
  inputs: readonly Hex[],
  nonce: bigint,
  seq: bigint
): {
  payload: Hex;
  payloadHash: Hex;
  header: Hex;
  instruction: Hex;
  toSign: Hex;
} {
  const payload = encodeAbiParameters(parseAbiParameters("bytes[], bytes[]"), [
    operations as Hex[],
    inputs as Hex[],
  ]);
  const payloadHash = keccak256(payload);
  const header = encodeAbiParameters(
    parseAbiParameters("uint256, uint256, bytes32"),
    [seq, BigInt(operations.length), payloadHash]
  );
  const instruction = encodeAbiParameters(parseAbiParameters("bytes, bytes"), [
    header,
    payload,
  ]);
  // messageHash = keccak256(abi.encodePacked(keccak256(payload), nonce))
  const toSign = keccak256(
    encodePacked(["bytes32", "uint256"], [payloadHash, nonce])
  );
  return { payload, payloadHash, header, instruction, toSign };
}

/**
 * abi.encode(SignedPayload) — the exact bytes passed to execute(). The ASP is
 * non-custodial and never calls this (it has no signature); exported so a
 * signing client / test can assemble the final calldata argument.
 */
export function encodeSignedPayload(params: {
  instruction: Hex;
  initiator: Address;
  nonce: bigint;
  signature: Hex;
}): Hex {
  return encodeAbiParameters(
    parseAbiParameters("(bytes, address, uint256, bytes)"),
    [[params.instruction, params.initiator, params.nonce, params.signature]]
  );
}

// ---------------------------------------------------------------------------
// Per-op encoders
// ---------------------------------------------------------------------------

interface EncodedStep {
  input: Hex;
  adapter: AdapterInfo;
  value: bigint;
  summary: string;
}

function encodeAction(action: ActionRequest): EncodedStep {
  switch (action.type) {
    case "transfer": {
      const token = addr(action.token, "transfer.token");
      const to = addr(action.to, "transfer.to");
      const amount = toUint(action.amount, "transfer.amount", UINT_MAX.u256);
      const input = encodeAbiParameters(
        parseAbiParameters("address, address, uint256"),
        [token, to, amount]
      );
      return {
        input,
        adapter: ADAPTERS.transfer,
        value: toUint(action.value ?? 0, "transfer.value", UINT_MAX.u112),
        summary: `Transfer ${amount.toString()} of ${token} to ${to} (initiator must approve TransferAdapter first)`,
      };
    }
    case "approve": {
      const token = addr(action.token, "approve.token");
      const spender = addr(action.spender, "approve.spender");
      const amount = toUint(action.amount, "approve.amount", UINT_MAX.u256);
      const input = encodeAbiParameters(
        parseAbiParameters("address, address, uint256"),
        [token, spender, amount]
      );
      return {
        input,
        adapter: ADAPTERS.approve,
        value: toUint(action.value ?? 0, "approve.value", UINT_MAX.u112),
        summary: `Approve ${spender} for ${amount.toString()} of ${token} (allowance is granted FROM the adapter, not the user's EOA)`,
      };
    }
    case "swap": {
      const tokenIn = addr(action.tokenIn, "swap.tokenIn");
      const tokenOut = addr(action.tokenOut, "swap.tokenOut");
      const amountIn = toUint(action.amountIn, "swap.amountIn", UINT_MAX.u256);
      const minOut = toUint(action.minAmountOut, "swap.minAmountOut", UINT_MAX.u256);
      const feeTier = toUint(action.fee, "swap.fee", UINT_MAX.u24);
      const input = encodeAbiParameters(
        parseAbiParameters("address, address, uint256, uint256, uint24"),
        [tokenIn, tokenOut, amountIn, minOut, Number(feeTier)]
      );
      return {
        input,
        adapter: ADAPTERS.swap,
        value: toUint(action.value ?? 0, "swap.value", UINT_MAX.u112),
        summary: `Swap ${amountIn.toString()} ${tokenIn} -> ${tokenOut} (minOut ${minOut.toString()}, feeTier ${feeTier.toString()}); initiator must approve SwapAdapter first`,
      };
    }
    case "aaveDeposit": {
      const token = addr(action.token, "aaveDeposit.token");
      const amount = toUint(action.amount, "aaveDeposit.amount", UINT_MAX.u256);
      if (amount === 0n) {
        throw new ValidationError("aaveDeposit.amount must be > 0");
      }
      const params = encodeAbiParameters(
        parseAbiParameters("address, uint256"),
        [token, amount]
      );
      const input = concat([AAVE_OP.deposit, params]);
      return {
        input,
        adapter: ADAPTERS.aave,
        value: toUint(action.value ?? 0, "aaveDeposit.value", UINT_MAX.u112),
        summary: `Aave supply ${amount.toString()} of ${token} on behalf of initiator (approve AaveAdapter for the underlying first)`,
      };
    }
    case "aaveWithdraw": {
      const token = addr(action.token, "aaveWithdraw.token");
      const amount = toUint(action.amount, "aaveWithdraw.amount", UINT_MAX.u256);
      if (amount === 0n) {
        throw new ValidationError("aaveWithdraw.amount must be > 0");
      }
      const params = encodeAbiParameters(
        parseAbiParameters("address, uint256"),
        [token, amount]
      );
      const input = concat([AAVE_OP.withdraw, params]);
      return {
        input,
        adapter: ADAPTERS.aave,
        value: toUint(action.value ?? 0, "aaveWithdraw.value", UINT_MAX.u112),
        summary: `Aave withdraw ${amount.toString()} of ${token} (approve AaveAdapter for the aToken first; aToken must be registered)`,
      };
    }
    case "aaveWithdrawAll": {
      const token = addr(action.token, "aaveWithdrawAll.token");
      const params = encodeAbiParameters(parseAbiParameters("address"), [token]);
      const input = concat([AAVE_OP.withdrawAll, params]);
      return {
        input,
        adapter: ADAPTERS.aave,
        value: toUint(action.value ?? 0, "aaveWithdrawAll.value", UINT_MAX.u112),
        summary: `Aave withdraw ALL of ${token} (approve AaveAdapter for the aToken first)`,
      };
    }
    case "wrap": {
      if (typeof action.isWrap !== "boolean") {
        throw new ValidationError("wrap.isWrap must be a boolean");
      }
      const amount = toUint(action.amount, "wrap.amount", UINT_MAX.u256);
      const input = encodeAbiParameters(parseAbiParameters("bool, uint256"), [
        action.isWrap,
        amount,
      ]);
      // ETH->WETH: forward ETH into the adapter via the op `value`; default to
      // amount so the adapter is funded (WrapAdapter.sol:42-43). WETH->ETH: 0.
      const value = action.isWrap
        ? toUint(action.value ?? action.amount, "wrap.value", UINT_MAX.u112)
        : toUint(action.value ?? 0, "wrap.value", UINT_MAX.u112);
      return {
        input,
        adapter: ADAPTERS.wrap,
        value,
        summary: action.isWrap
          ? `Wrap ${amount.toString()} wei ETH -> WETH (op forwards ${value.toString()} wei as msg.value to fund the adapter)`
          : `Unwrap ${amount.toString()} WETH -> ETH (initiator must approve WrapAdapter for WETH first)`,
      };
    }
    default: {
      // Exhaustiveness guard.
      const _never: never = action;
      throw new ValidationError(
        `Unknown action type: ${String((_never as { type?: string }).type)}`
      );
    }
  }
}

function encodeCondition(cond: ConditionRequest): EncodedStep {
  switch (cond.type) {
    case "waitTime": {
      const value = toUint(cond.timestamp, "waitTime.timestamp", UINT_MAX.u256);
      const input = encodeAbiParameters(
        parseAbiParameters("uint8, uint256, address, int256"),
        [WAIT_TYPE.timestamp, value, ZERO_ADDRESS, 0n]
      );
      return {
        input,
        adapter: ADAPTERS.wait,
        value: 0n,
        summary: `Wait until unix timestamp >= ${value.toString()}`,
      };
    }
    case "waitBlock": {
      const value = toUint(cond.blockNumber, "waitBlock.blockNumber", UINT_MAX.u256);
      const input = encodeAbiParameters(
        parseAbiParameters("uint8, uint256, address, int256"),
        [WAIT_TYPE.block, value, ZERO_ADDRESS, 0n]
      );
      return {
        input,
        adapter: ADAPTERS.wait,
        value: 0n,
        summary: `Wait until block number >= ${value.toString()}`,
      };
    }
    case "waitPriceGte":
    case "waitPriceLte": {
      const feed = addr(cond.feed, `${cond.type}.feed`);
      const target = toInt256(cond.targetPrice, `${cond.type}.targetPrice`);
      const waitType =
        cond.type === "waitPriceGte" ? WAIT_TYPE.priceGte : WAIT_TYPE.priceLte;
      const input = encodeAbiParameters(
        parseAbiParameters("uint8, uint256, address, int256"),
        [waitType, 0n, feed, target]
      );
      return {
        input,
        adapter: ADAPTERS.wait,
        value: 0n,
        summary: `Wait until Chainlink feed ${feed} price ${
          cond.type === "waitPriceGte" ? ">=" : "<="
        } ${target.toString()} (no staleness check)`,
      };
    }
    case "balance": {
      const token = optAddr(cond.token, "balance.token", ZERO_ADDRESS);
      const target = addr(cond.target, "balance.target");
      const operator = resolveOperator(cond.operator, "balance.operator");
      const threshold = toUint(cond.threshold, "balance.threshold", UINT_MAX.u256);
      const input = encodeAbiParameters(
        parseAbiParameters("address, address, uint8, uint256"),
        [token, target, operator, threshold]
      );
      return {
        input,
        adapter: ADAPTERS.balance,
        value: 0n,
        summary: `Gate: ${
          token === ZERO_ADDRESS ? "native ETH" : `token ${token}`
        } balance of ${target} ${operatorSymbol(operator)} ${threshold.toString()}`,
      };
    }
    case "price": {
      const feed = addr(cond.feed, "price.feed");
      const operator = resolveOperator(cond.operator, "price.operator");
      const targetPrice = toInt256(cond.targetPrice, "price.targetPrice");
      const checkStaleness = cond.checkStaleness ?? false;
      if (typeof checkStaleness !== "boolean") {
        throw new ValidationError("price.checkStaleness must be a boolean");
      }
      const input = encodeAbiParameters(
        parseAbiParameters("address, uint8, int256, bool"),
        [feed, operator, targetPrice, checkStaleness]
      );
      return {
        input,
        adapter: ADAPTERS.price,
        value: 0n,
        summary: `Gate: Chainlink feed ${feed} price ${operatorSymbol(
          operator
        )} ${targetPrice.toString()}${checkStaleness ? " (1h staleness enforced)" : ""}`,
      };
    }
    case "query": {
      const target = addr(cond.target, "query.target");
      const calldata = hexBytes(cond.calldata, "query.calldata");
      const operator = resolveOperator(cond.operator, "query.operator");
      const expected = toUint(cond.expected, "query.expected", UINT_MAX.u256);
      const input = encodeAbiParameters(
        parseAbiParameters("address, bytes, uint8, uint256"),
        [target, calldata, operator, expected]
      );
      return {
        input,
        adapter: ADAPTERS.query,
        value: 0n,
        summary: `Gate: staticcall ${target} (uint256 result) ${operatorSymbol(
          operator
        )} ${expected.toString()}`,
      };
    }
    default: {
      const _never: never = cond;
      throw new ValidationError(
        `Unknown condition type: ${String((_never as { type?: string }).type)}`
      );
    }
  }
}

function operatorSymbol(op: number): string {
  return (["<", ">", "<=", ">=", "==", "!="] as const)[op] ?? `op(${op})`;
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

export function compileIntent(request: CompileRequest): CompiledIntent {
  if (request === null || typeof request !== "object") {
    throw new ValidationError("request body must be a JSON object");
  }

  // Chain gate: only local Base Sepolia (chainId 84532 or index 0) is buildable.
  if (request.chain !== undefined) {
    const c = toBigInt(request.chain, "chain");
    if (c !== BigInt(CHAIN_ID) && c !== BigInt(LOCAL_CHAIN_INDEX)) {
      throw new ValidationError(
        `unsupported chain ${c.toString()}; only Base Sepolia (${CHAIN_ID}) / local index ${LOCAL_CHAIN_INDEX} is supported`
      );
    }
  }

  const nonce = toUint(request.nonce ?? 0, "nonce", UINT_MAX.u256);
  const seq = toUint(request.seq ?? 0, "seq", UINT_MAX.u256);

  const conditions = request.conditions ?? [];
  const actions = request.actions ?? [];
  if (!Array.isArray(conditions)) {
    throw new ValidationError("conditions must be an array");
  }
  if (!Array.isArray(actions)) {
    throw new ValidationError("actions must be an array");
  }
  if (conditions.length === 0 && actions.length === 0) {
    throw new ValidationError("intent must contain at least one action or condition");
  }
  // Bound total work independent of body size (CPU-DoS guard).
  const totalSteps = conditions.length + actions.length;
  if (totalSteps > MAX_STEPS) {
    throw new ValidationError(
      `intent has ${totalSteps} steps; the maximum is ${MAX_STEPS}`
    );
  }

  const initiator =
    request.initiator !== undefined ? addr(request.initiator, "initiator") : undefined;

  const operations: Hex[] = [];
  const inputs: Hex[] = [];
  const steps: CompiledStep[] = [];
  const warnings: string[] = [];

  // Conditions FIRST — they gate the actions. A condition adapter returns
  // PAUSE_EXECUTION until met; on re-run the processor restarts from seq and
  // proceeds past the (now-satisfied) gate into the actions.
  let index = 0;
  const pushStep = (
    kind: "condition" | "action",
    type: string,
    encoded: EncodedStep
  ): void => {
    const operation = encodeOperation(encoded.adapter.address, encoded.value);
    operations.push(operation);
    inputs.push(encoded.input);
    if (!encoded.adapter.deployed) {
      warnings.push(
        `${type}: ${encoded.adapter.name} at ${encoded.adapter.address} is NOT deployed on Base Sepolia — this operation will revert on-chain until a real adapter address is available.`
      );
    }
    steps.push({
      index,
      kind,
      type,
      adapter: encoded.adapter.name,
      target: encoded.adapter.address,
      value: encoded.value.toString(),
      operation,
      input: encoded.input,
      summary: encoded.summary,
    });
    index += 1;
  };

  for (const cond of conditions) {
    if (cond === null || typeof cond !== "object" || typeof cond.type !== "string") {
      throw new ValidationError("each condition must be an object with a `type`");
    }
    pushStep("condition", cond.type, encodeCondition(cond));
  }
  for (const action of actions) {
    if (
      action === null ||
      typeof action !== "object" ||
      typeof action.type !== "string"
    ) {
      throw new ValidationError("each action must be an object with a `type`");
    }
    pushStep("action", action.type, encodeAction(action));
  }

  // seq is the processor's resumption cursor: `for (; seq < length;)`
  // (W3CashProcessor.sol:153). This ASP always builds a fresh intent from step 0,
  // so seq must address a real op. seq >= length -> zero iterations (the whole
  // signed intent is an inert no-op); 0 < seq < length -> the first `seq` ops are
  // silently skipped. Reject the former (>=, so seq == length is caught too) and
  // warn on the latter.
  if (operations.length > 0 && seq >= BigInt(operations.length)) {
    throw new ValidationError(
      `seq (${seq.toString()}) must be < operation count (${operations.length}); this intent would execute nothing on-chain`
    );
  }
  if (seq > 0n) {
    warnings.push(
      `seq=${seq.toString()} starts execution past step 0: the first ${seq.toString()} of ${operations.length} operations will be SKIPPED on-chain (processor loops for(; seq < length;)).`
    );
  }

  const totalValue = steps.reduce((acc, s) => acc + BigInt(s.value), 0n);
  if (totalValue > 0n) {
    warnings.push(
      `Total native ETH forwarded across ops = ${totalValue.toString()} wei; the relayer calling execute() must send at least this much msg.value.`
    );
  }

  // Replay caveat — surfaced in the artifact the signer actually consumes, not
  // just in getCapabilities(). execute() verifies but never consumes the nonce.
  warnings.push(
    "REPLAYABLE SIGNATURE: W3CashProcessor.execute() verifies but does NOT consume the nonce (W3CashProcessor.sol:124-138); this signature stays valid and can be re-executed by anyone until the initiator calls incrementNonce(). Damage is bounded by the token allowance granted to each adapter — do NOT sign or grant open-ended/unlimited approvals for transfer/swap/aaveDeposit intents; use incrementNonce() to cancel."
  );

  const { payload, payloadHash, header, instruction, toSign } = encodeEnvelope(
    operations,
    inputs,
    nonce,
    seq
  );

  const humanSummary: string[] = [];
  if (initiator) humanSummary.push(`Initiator: ${initiator}`);
  humanSummary.push(
    `Chain: Base Sepolia (${CHAIN_ID}); Processor: ${PROCESSOR}; nonce ${nonce.toString()}`
  );
  for (const s of steps) {
    humanSummary.push(`#${s.index} [${s.kind}/${s.type}] ${s.summary}`);
  }

  return {
    chainId: CHAIN_ID,
    processor: PROCESSOR,
    nonce: nonce.toString(),
    seq: seq.toString(),
    operations,
    inputs,
    header,
    payload,
    payloadHash,
    instruction,
    toSign,
    signing: {
      scheme: "eip191-personal-sign",
      messageHash: toSign,
      nonce: nonce.toString(),
      replayable: true,
      signedPayloadFormat:
        "execute(abi.encode((bytes instruction, address initiator, uint256 nonce, bytes signature)))",
      note:
        "Sign `toSign` as an EIP-191 personal message (viem: signMessage({ message: { raw: toSign } })). Serialize the signature as r||s||v (65 bytes). This ASP is non-custodial and returns no signature. This signature is nonce-scoped and REPLAYABLE: execute() does not consume the nonce, so it remains valid (re-executable by anyone) until the initiator calls incrementNonce().",
    },
    steps,
    humanSummary,
    warnings,
  };
}

// ---------------------------------------------------------------------------
// Capability catalog (for GET /capabilities)
// ---------------------------------------------------------------------------

export interface CapabilityCatalog {
  readonly chainId: number;
  readonly chainName: string;
  readonly processor: Address;
  readonly adapterRegistry: Address;
  readonly localChainIndex: number;
  readonly operators: Record<OperatorName, number>;
  readonly actions: readonly {
    readonly type: string;
    readonly adapter: string;
    readonly fields: readonly string[];
    readonly requiresPriorApprove: boolean;
    readonly note?: string;
  }[];
  readonly conditions: readonly {
    readonly type: string;
    readonly adapter: string;
    readonly fields: readonly string[];
    readonly note?: string;
  }[];
  readonly adapterCatalog: readonly (AdapterInfo & { key: string })[];
  readonly notes: readonly string[];
}

export function getCapabilities(): CapabilityCatalog {
  return {
    chainId: CHAIN_ID,
    chainName: "Base Sepolia",
    processor: PROCESSOR,
    adapterRegistry: ADAPTER_REGISTRY,
    localChainIndex: LOCAL_CHAIN_INDEX,
    operators: { ...OPERATORS },
    actions: [
      {
        type: "transfer",
        adapter: "TransferAdapter",
        fields: ["token", "to", "amount", "value?"],
        requiresPriorApprove: true,
        note: "IERC20.safeTransferFrom(initiator, to, amount) — approve TransferAdapter first.",
      },
      {
        type: "approve",
        adapter: "ApproveAdapter",
        fields: ["token", "spender", "amount", "value?"],
        requiresPriorApprove: false,
        note: "forceApprove runs in the adapter's context: sets allowance[adapter][spender], NOT the user's EOA.",
      },
      {
        type: "swap",
        adapter: "SwapAdapter",
        fields: ["tokenIn", "tokenOut", "amountIn", "minAmountOut", "fee", "value?"],
        requiresPriorApprove: true,
        note: "Uniswap V3 exactInputSingle; recipient = initiator; approve SwapAdapter for tokenIn first.",
      },
      {
        type: "aaveDeposit",
        adapter: "AaveAdapter",
        fields: ["token", "amount", "value?"],
        requiresPriorApprove: true,
        note: "Selector-prefixed input (0x47e7ef24). pool.supply on behalf of initiator; approve AaveAdapter for the underlying.",
      },
      {
        type: "aaveWithdraw",
        adapter: "AaveAdapter",
        fields: ["token", "amount", "value?"],
        requiresPriorApprove: true,
        note: "Selector-prefixed input (0xf3fef3a3). Approve AaveAdapter for the aToken; aToken must be registered on-adapter.",
      },
      {
        type: "aaveWithdrawAll",
        adapter: "AaveAdapter",
        fields: ["token", "value?"],
        requiresPriorApprove: true,
        note: "Selector-prefixed input (0xfa09e630). Approve AaveAdapter for the aToken.",
      },
      {
        type: "wrap",
        adapter: "WrapAdapter",
        fields: ["isWrap", "amount", "value?"],
        requiresPriorApprove: false,
        note: "isWrap=true ETH->WETH forwards ETH via op value (defaults to amount); isWrap=false WETH->ETH needs prior WETH approve.",
      },
    ],
    conditions: [
      {
        type: "waitTime",
        adapter: "WaitAdapter",
        fields: ["timestamp"],
        note: "Met when block.timestamp >= timestamp.",
      },
      {
        type: "waitBlock",
        adapter: "WaitAdapter",
        fields: ["blockNumber"],
        note: "Met when block.number >= blockNumber.",
      },
      {
        type: "waitPriceGte",
        adapter: "WaitAdapter",
        fields: ["feed", "targetPrice"],
        note: "Chainlink feed price >= targetPrice (no staleness check).",
      },
      {
        type: "waitPriceLte",
        adapter: "WaitAdapter",
        fields: ["feed", "targetPrice"],
        note: "Chainlink feed price <= targetPrice (no staleness check).",
      },
      {
        type: "balance",
        adapter: "BalanceAdapter",
        fields: ["token?", "target", "operator", "threshold"],
        note: "token omitted/zero => native ETH balance. NOTE: BalanceAdapter is not deployed on Base Sepolia today.",
      },
      {
        type: "price",
        adapter: "PriceAdapter",
        fields: ["feed", "operator", "targetPrice", "checkStaleness?"],
        note: "Signed Chainlink price compare. NOTE: PriceAdapter is not deployed on Base Sepolia today.",
      },
      {
        type: "query",
        adapter: "QueryAdapter",
        fields: ["target", "calldata", "operator", "expected"],
        note: "staticcall(target, calldata) decoded as a single uint256, compared unsigned.",
      },
    ],
    adapterCatalog: Object.entries(ADAPTERS).map(([key, info]) => ({
      key,
      ...info,
    })),
    notes: [
      "Local (same-chain) routing is by the operation's `target` ADDRESS (W3CashProcessor.sol:176); field-1 `amb` is ignored locally and is left 0.",
      "field-4 selector (bytes8) is dead and left 0; field-2 fee (uint64) is cross-chain-only and left 0.",
      "Signature scheme is EIP-191 personal_sign over keccak256(abi.encodePacked(keccak256(payload), nonce)) — NOT EIP-712.",
      "execute() does NOT consume the nonce; a signed payload is replayable until the initiator calls incrementNonce().",
      "BalanceAdapter and PriceAdapter addresses from the task are NOT deployed on Base Sepolia — their ops will revert until real addresses exist.",
    ],
  };
}
