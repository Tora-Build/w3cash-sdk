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
 * `address`); `null` means the adapter is reachable only by direct address and
 * is NOT registry-id routed (TimeRange / GasPrice). `deployed` is retained on
 * the shape and is `true` for every adapter below — each was verified on-chain
 * (adapterId() + bytecode) on Base Sepolia. There are no undeployed adapters
 * anymore: the old stale Balance/Price entries were removed once their
 * conditions were re-routed onto the deployed QueryAdapter.
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
  // Cross-chain bridging via Across Protocol depositV3. Registry id 7; routes by
  // address. spokePool = 0x82B564983aE7274c86695917BBf8C99ECb6F0F8F.
  bridge: {
    name: "BridgeAdapter",
    address: getAddress("0x3502362cAB171ffF2bF094fC70FD5977c9AD7090"),
    adapterId: "0x716f6a28", // bytes4(keccak256("BridgeAdapter"))
    registryId: 7,
    deployed: true,
  },
  // Daily-UTC-hour OR absolute-timestamp execution window. Direct-address only
  // (NOT in the AdapterRegistry id space).
  timeRange: {
    name: "TimeRangeAdapter",
    address: getAddress("0xCC18E7E2283D3067B30D0e9a3Ba189FE25dB62EB"),
    adapterId: "0x79b4e21f", // bytes4(keccak256("TimeRangeAdapter"))
    registryId: null,
    deployed: true,
  },
  // tx.gasprice threshold gate. REDUCED operator set 0..3 (no eq/neq).
  // Direct-address only (NOT in the AdapterRegistry id space).
  gasPrice: {
    name: "GasPriceAdapter",
    address: getAddress("0x07DcD715DdAB18D449b10BB6140916e8a0F7f657"),
    adapterId: "0x62c7743a", // bytes4(keccak256("GasPriceAdapter"))
    registryId: null,
    deployed: true,
  },
  // 2nd-approver / co-signer ECDSA gate. Registry id 104; routes by address.
  signature: {
    name: "SignatureAdapter",
    address: getAddress("0xEEe61780cC5fC62B7017E46BB7f6b27fD8BAfBEe"),
    adapterId: "0xfde104a6", // bytes4(keccak256("SignatureAdapter"))
    registryId: 104,
    deployed: true,
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

/**
 * View-function selectors used to build the `calldata` a QueryAdapter staticcall
 * runs against `target`. Each MUST return exactly ONE 32-byte word — QueryAdapter
 * abi.decodes the return as a single uint256 (multi-return getters like
 * latestRoundData() would hand back the WRONG word). Verified on-chain via
 * `cast sig` on Base Sepolia.
 */
const VIEW_SELECTOR = {
  balanceOf: "0x70a08231", // balanceOf(address) -> uint256
  latestAnswer: "0x50d25bcd", // latestAnswer() -> int256 (single word; NOT latestRoundData)
  isSettled: "0x3270bb5b", // Sooth TruthMarket.isSettled() -> bool
  winningOutcome: "0x9b34ae03", // Sooth TruthMarket.winningOutcome() -> uint8 (0=NO,1=YES,2=INVALID)
  isLive: "0xb8f7a665", // Sooth TruthMarket.isLive() -> bool
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

/**
 * GasPriceAdapter's REDUCED operator set: only 0..3 (lt/gt/lte/gte). Passing
 * eq(4)/neq(5) reverts GasPriceAdapter__InvalidOperator on-chain — do NOT reuse
 * the full OPERATORS map here. (GasPriceAdapter.sol:92-98.)
 */
export const GAS_OPERATORS = {
  lt: 0,
  gt: 1,
  lte: 2,
  gte: 3,
} as const;

export type GasOperatorName = keyof typeof GAS_OPERATORS;

/** Sooth protocol-canonical outcome encoding (TruthMarket.winningOutcome()). */
export const MARKET_OUTCOME = {
  NO: 0,
  YES: 1,
  INVALID: 2,
} as const;

export type MarketOutcomeName = keyof typeof MARKET_OUTCOME;

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
    }
  | {
      // Cross-chain bridge via Across depositV3 (BridgeAdapter). Native ETH is
      // NOT supported — inputToken must be an ERC20 (bridge WETH). Initiator must
      // approve BridgeAdapter for inputAmount of inputToken before signing.
      // outputAmount + quoteTimestamp should come from the Across suggested-fees
      // quote (auto-quoting is a TODO — supply them yourself).
      type: "bridge";
      recipient: string; // recipient on the destination chain
      destinationChainId: Numeric; // REAL EVM chain id (e.g. 11155111 Sepolia)
      inputToken: string; // ERC20 on Base Sepolia to bridge
      outputToken?: string; // token on destination; omit/zero => auto (wrapped-native)
      inputAmount: Numeric; // pulled from initiator on Base Sepolia
      outputAmount: Numeric; // delivered on destination (fee = inputAmount - outputAmount)
      quoteTimestamp: Numeric; // uint32; within 3600s of chain time or depositV3 reverts
      fillDeadline: Numeric; // uint32; in [now, now+21600s]; 0 REVERTS
      exclusivityDeadline?: Numeric; // uint32; default 0 (no exclusive relayer)
      message?: string; // optional destination calldata; default 0x
      value?: Numeric; // no msg.value needed; default 0
    };

export type ConditionRequest =
  | { type: "waitTime"; timestamp: Numeric }
  | { type: "waitBlock"; blockNumber: Numeric }
  | { type: "waitPriceGte"; feed: string; targetPrice: Numeric }
  | { type: "waitPriceLte"; feed: string; targetPrice: Numeric }
  | {
      // Re-routed onto the deployed QueryAdapter as a balanceOf(target) staticcall.
      // token is REQUIRED (ERC20): native ETH has no balanceOf(), so a native
      // balance gate is not expressible and is rejected.
      type: "balance";
      token?: string; // ERC20 whose balanceOf is read; omit/zero-address => ValidationError
      target: string; // the holder address passed to balanceOf(holder)
      operator: OperatorName | number;
      threshold: Numeric;
    }
  | {
      // Re-routed onto the deployed QueryAdapter as a latestAnswer() staticcall.
      // targetPrice must be NON-NEGATIVE (compared unsigned). checkStaleness has
      // no equivalent in QueryAdapter — if requested it is DROPPED with a warning.
      type: "price";
      feed: string;
      operator: OperatorName | number;
      targetPrice: Numeric; // uint256; Chainlink 8-dec answer, must be >= 0
      checkStaleness?: boolean;
    }
  | {
      type: "query";
      target: string;
      calldata: string; // hex, selector + args
      operator: OperatorName | number;
      expected: Numeric;
    }
  | {
      // Daily UTC-hour window (recurring=true, start/end are hours 0-23,
      // end-EXCLUSIVE, overnight wrap when start>end) OR one-time absolute unix
      // window (recurring=false, both bounds INCLUSIVE). TimeRangeAdapter.
      type: "timeRange";
      startTime: Numeric;
      endTime: Numeric;
      recurring: boolean;
    }
  | {
      // Gate on tx.gasprice of the settling tx. GasPriceAdapter — REDUCED
      // operator set (lt/gt/lte/gte only). threshold in wei.
      type: "gasPrice";
      operator: GasOperatorName | number;
      threshold: Numeric;
    }
  | {
      // 2nd-approver ECDSA gate. Caller supplies a pre-obtained co-signer
      // signature; the ASP is non-custodial and cannot produce it. Use the
      // exported signatureMessageHash() to compute what the co-signer must
      // EIP-191 personal-sign. SignatureAdapter.
      type: "signature";
      requiredSigner: string; // co-signer whose recovered address must match
      actionHash: string; // bytes32, application-defined action id
      deadline: Numeric; // unix expiry
      signature: string; // 65-byte r||s||v ECDSA over the personal-signed message hash
    }
  | {
      // Convenience prediction-market gate: QueryAdapter staticcall on a Sooth
      // TruthMarket's isSettled() == true.
      type: "marketResolved";
      market: string;
    }
  | {
      // Convenience prediction-market gate: QueryAdapter staticcall on a Sooth
      // TruthMarket's winningOutcome() == outcome (0=NO,1=YES,2=INVALID or name).
      type: "marketOutcome";
      market: string;
      outcome: Numeric | MarketOutcomeName;
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
  u32: (1n << 32n) - 1n,
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

/**
 * GasPriceAdapter operator resolver — REDUCED set 0..3. Rejects eq(4)/neq(5),
 * which revert GasPriceAdapter__InvalidOperator on-chain. Same prototype-chain
 * ownership guard as resolveOperator.
 */
function resolveGasOperator(
  value: GasOperatorName | number,
  field: string
): number {
  if (typeof value === "number") {
    if (!Number.isInteger(value) || value < 0 || value > 3) {
      throw new ValidationError(
        `${field} numeric operator must be 0..3 (lt/gt/lte/gte); GasPriceAdapter has no eq/neq`
      );
    }
    return value;
  }
  if (
    typeof value !== "string" ||
    !Object.prototype.hasOwnProperty.call(GAS_OPERATORS, value)
  ) {
    throw new ValidationError(
      `${field} must be one of ${Object.keys(GAS_OPERATORS).join(", ")} or 0..3`
    );
  }
  return GAS_OPERATORS[value as GasOperatorName];
}

/** Resolve a market outcome to its canonical uint (0=NO,1=YES,2=INVALID). */
function resolveOutcome(value: Numeric | MarketOutcomeName, field: string): bigint {
  if (
    typeof value === "string" &&
    Object.prototype.hasOwnProperty.call(MARKET_OUTCOME, value)
  ) {
    return BigInt(MARKET_OUTCOME[value as MarketOutcomeName]);
  }
  const v = toUint(value, field, UINT_MAX.u8);
  if (v > 2n) {
    throw new ValidationError(
      `${field} must be 0 (NO), 1 (YES), 2 (INVALID) or one of NO/YES/INVALID`
    );
  }
  return v;
}

/** Validate a 0x-hex string is exactly 32 bytes (bytes32). */
function bytes32(value: unknown, field: string): Hex {
  const h = hexBytes(value, field);
  if (h.length - 2 !== 64) {
    throw new ValidationError(`${field} must be exactly 32 bytes (66-char 0x hex)`);
  }
  return h;
}

/** balanceOf(holder) calldata for a QueryAdapter staticcall. */
function balanceOfCalldata(holder: Address): Hex {
  return concat([
    VIEW_SELECTOR.balanceOf,
    encodeAbiParameters(parseAbiParameters("address"), [holder]),
  ]);
}

/** QueryAdapter input tuple: abi.encode(target, calldata, operator, expected). */
function queryInput(
  target: Address,
  calldata: Hex,
  operator: number,
  expected: bigint
): Hex {
  return encodeAbiParameters(
    parseAbiParameters("address, bytes, uint8, uint256"),
    [target, calldata, operator, expected]
  );
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

/**
 * Compute the RAW 32-byte message hash a co-signer must EIP-191 personal-sign to
 * satisfy a `signature` condition. Mirrors SignatureAdapter.getMessageHash()
 * EXACTLY (verified on-chain, SignatureAdapter.sol:103-109 / 138-150):
 *
 *   keccak256(abi.encodePacked(account, actionHash, deadline, chainId, adapter))
 *
 * where `account` = the intent INITIATOR (W3CashProcessor passes execute()'s
 * `account` = the envelope initiator on the local path), chainId = 84532, and
 * adapter = the deployed SignatureAdapter address. This returns the hash BEFORE
 * the EIP-191 prefix; the co-signer then personal-signs it
 * (viem: signMessage({ account: coSigner, message: { raw: <thisHash> } })) and
 * the resulting 65-byte r||s||v goes into the `signature` condition field.
 */
export function signatureMessageHash(params: {
  account: string;
  actionHash: string;
  deadline: Numeric;
}): Hex {
  const account = addr(params.account, "signatureMessageHash.account");
  const actionHash = bytes32(params.actionHash, "signatureMessageHash.actionHash");
  const deadline = toUint(
    params.deadline,
    "signatureMessageHash.deadline",
    UINT_MAX.u256
  );
  return keccak256(
    encodePacked(
      ["address", "bytes32", "uint256", "uint256", "address"],
      [account, actionHash, deadline, BigInt(CHAIN_ID), ADAPTERS.signature.address]
    )
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
  /** Per-step advisories (semantics dropped, quote TODO, etc.) surfaced to caller. */
  warnings?: readonly string[];
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
    case "bridge": {
      const recipient = addr(action.recipient, "bridge.recipient");
      const destinationChainId = toUint(
        action.destinationChainId,
        "bridge.destinationChainId",
        UINT_MAX.u256
      );
      if (destinationChainId === 0n) {
        throw new ValidationError(
          "bridge.destinationChainId must be a real EVM chain id (e.g. 11155111 for Sepolia), not 0"
        );
      }
      const inputToken = addr(action.inputToken, "bridge.inputToken");
      if (inputToken === ZERO_ADDRESS) {
        throw new ValidationError(
          "bridge.inputToken must be an ERC20 address: native ETH is not supported (the adapter always safeTransferFrom's inputToken). Bridge WETH 0x4200000000000000000000000000000000000006 instead."
        );
      }
      // outputToken 0x0 is a valid Across sentinel (auto / wrapped-native).
      const outputToken = optAddr(
        action.outputToken,
        "bridge.outputToken",
        ZERO_ADDRESS
      );
      const inputAmount = toUint(action.inputAmount, "bridge.inputAmount", UINT_MAX.u256);
      if (inputAmount === 0n) {
        throw new ValidationError("bridge.inputAmount must be > 0");
      }
      const outputAmount = toUint(
        action.outputAmount,
        "bridge.outputAmount",
        UINT_MAX.u256
      );
      if (outputAmount > inputAmount) {
        throw new ValidationError(
          "bridge.outputAmount must be <= inputAmount (Across relayer fee is implicit = inputAmount - outputAmount); an outputAmount above inputAmount can never be filled"
        );
      }
      const quoteTimestamp = toUint(
        action.quoteTimestamp,
        "bridge.quoteTimestamp",
        UINT_MAX.u32
      );
      const fillDeadline = toUint(action.fillDeadline, "bridge.fillDeadline", UINT_MAX.u32);
      if (fillDeadline === 0n) {
        throw new ValidationError(
          "bridge.fillDeadline must be > 0 and within [now, now+21600s]; 0 REVERTS on-chain (it is NOT interpreted as a default despite the adapter comment)"
        );
      }
      const exclusivityDeadline = toUint(
        action.exclusivityDeadline ?? 0,
        "bridge.exclusivityDeadline",
        UINT_MAX.u32
      );
      const message =
        action.message === undefined
          ? ("0x" as Hex)
          : hexBytes(action.message, "bridge.message");
      // Field-7 relayerFeePct (int64) is decoded but never forwarded to Across V3
      // depositV3 (fee is implicit = inputAmount - outputAmount); pinned to 0.
      const input = encodeAbiParameters(
        parseAbiParameters(
          "address, uint256, address, address, uint256, uint256, int64, uint32, bytes, uint32, uint32"
        ),
        [
          recipient,
          destinationChainId,
          inputToken,
          outputToken,
          inputAmount,
          outputAmount,
          0n, // relayerFeePct (int64) — decoded but never forwarded to depositV3
          Number(quoteTimestamp), // uint32 (bounded above; safe integer)
          message,
          Number(fillDeadline), // uint32
          Number(exclusivityDeadline), // uint32
        ]
      );
      return {
        input,
        adapter: ADAPTERS.bridge,
        value: toUint(action.value ?? 0, "bridge.value", UINT_MAX.u112),
        summary: `Bridge ${inputAmount.toString()} of ${inputToken} from Base Sepolia to chain ${destinationChainId.toString()} for ${outputAmount.toString()} of ${
          outputToken === ZERO_ADDRESS ? "auto/wrapped-native" : outputToken
        } to ${recipient} via Across depositV3 (initiator must approve BridgeAdapter for inputToken first)`,
        warnings: [
          "bridge.outputAmount and bridge.quoteTimestamp are caller-supplied and SHOULD come from the Across suggested-fees quote (GET https://testnet.across.to/api/suggested-fees?...&originChainId=84532&destinationChainId=<dst>&amount=<in>): outputAmount = inputAmount - totalRelayFee.total, quoteTimestamp = json.timestamp. quoteTimestamp must be within 3600s of chain time or depositV3 reverts; too-high outputAmount never fills. Auto-quoting is a TODO — the ASP does not fetch it in-process.",
        ],
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
      // Re-routed onto the deployed QueryAdapter: staticcall token.balanceOf(holder).
      const token = optAddr(cond.token, "balance.token", ZERO_ADDRESS);
      if (token === ZERO_ADDRESS) {
        throw new ValidationError(
          "balance.token is required and must be an ERC20 address: native ETH has no balanceOf(), so a native-ETH balance gate is not expressible via QueryAdapter (a staticcall to address(0) returns empty and QueryAdapter's abi.decode then reverts)"
        );
      }
      const holder = addr(cond.target, "balance.target");
      const operator = resolveOperator(cond.operator, "balance.operator");
      const threshold = toUint(cond.threshold, "balance.threshold", UINT_MAX.u256);
      const input = queryInput(token, balanceOfCalldata(holder), operator, threshold);
      return {
        input,
        adapter: ADAPTERS.query,
        value: 0n,
        summary: `Gate (QueryAdapter): ERC20 ${token}.balanceOf(${holder}) ${operatorSymbol(
          operator
        )} ${threshold.toString()}`,
      };
    }
    case "price": {
      // Re-routed onto the deployed QueryAdapter: staticcall feed.latestAnswer().
      const feed = addr(cond.feed, "price.feed");
      const operator = resolveOperator(cond.operator, "price.operator");
      // Compared UNSIGNED: Chainlink latestAnswer() is int256 but QueryAdapter
      // abi.decodes it as uint256, so a negative answer would wrap near 2^256 and
      // mis-compare. Reject negative targetPrice (toUint enforces >= 0).
      const targetPrice = toUint(cond.targetPrice, "price.targetPrice", UINT_MAX.u256);
      const warnings: string[] = [];
      if (cond.checkStaleness === true) {
        warnings.push(
          "price.checkStaleness was requested but is NOT enforced: QueryAdapter reads latestAnswer() only and never checks updatedAt/roundId — the staleness guard from the old PriceAdapter has no equivalent and was DROPPED. Semantics differ from the legacy signed PriceAdapter."
        );
      } else if (
        cond.checkStaleness !== undefined &&
        typeof cond.checkStaleness !== "boolean"
      ) {
        throw new ValidationError("price.checkStaleness must be a boolean");
      }
      const input = queryInput(
        feed,
        VIEW_SELECTOR.latestAnswer,
        operator,
        targetPrice
      );
      return {
        input,
        adapter: ADAPTERS.query,
        value: 0n,
        summary: `Gate (QueryAdapter): Chainlink feed ${feed}.latestAnswer() ${operatorSymbol(
          operator
        )} ${targetPrice.toString()} (unsigned; no staleness check)`,
        warnings,
      };
    }
    case "timeRange": {
      if (typeof cond.recurring !== "boolean") {
        throw new ValidationError("timeRange.recurring must be a boolean");
      }
      const startTime = toUint(cond.startTime, "timeRange.startTime", UINT_MAX.u256);
      const endTime = toUint(cond.endTime, "timeRange.endTime", UINT_MAX.u256);
      const warnings: string[] = [];
      let window: string;
      if (cond.recurring) {
        if (startTime > 23n || endTime > 23n) {
          throw new ValidationError(
            "timeRange recurring hours must be 0..23 (UTC hour-of-day); a value >= 24 never matches"
          );
        }
        if (startTime === endTime) {
          warnings.push(
            "timeRange recurring start == end yields an EMPTY window (the end-exclusive hourly check currentHour >= start && currentHour < end can never both hold at equality) — this gate can never be met. A full-day window is not expressible via a single recurring range."
          );
        }
        window =
          startTime <= endTime
            ? `UTC hours [${startTime.toString()}..${endTime.toString()}) daily (end-exclusive)`
            : `UTC hours [${startTime.toString()}..24)+[0..${endTime.toString()}) daily (overnight wrap)`;
      } else {
        window = `unix [${startTime.toString()}..${endTime.toString()}] (both inclusive)`;
      }
      const input = encodeAbiParameters(
        parseAbiParameters("uint256, uint256, bool"),
        [startTime, endTime, cond.recurring]
      );
      return {
        input,
        adapter: ADAPTERS.timeRange,
        value: 0n,
        summary: `Gate (TimeRangeAdapter): execute only within ${window}`,
        warnings,
      };
    }
    case "gasPrice": {
      const operator = resolveGasOperator(cond.operator, "gasPrice.operator");
      const threshold = toUint(cond.threshold, "gasPrice.threshold", UINT_MAX.u256);
      const input = encodeAbiParameters(parseAbiParameters("uint8, uint256"), [
        operator,
        threshold,
      ]);
      return {
        input,
        adapter: ADAPTERS.gasPrice,
        value: 0n,
        summary: `Gate (GasPriceAdapter): tx.gasprice ${operatorSymbol(
          operator
        )} ${threshold.toString()} wei`,
        warnings: [
          "gasPrice compares tx.gasprice of the SETTLING transaction — set by the relayer/processor submitter, not a network oracle.",
        ],
      };
    }
    case "signature": {
      const requiredSigner = addr(cond.requiredSigner, "signature.requiredSigner");
      const actionHash = bytes32(cond.actionHash, "signature.actionHash");
      const deadline = toUint(cond.deadline, "signature.deadline", UINT_MAX.u256);
      const signature = hexBytes(cond.signature, "signature.signature");
      if (signature.length - 2 !== 130) {
        throw new ValidationError(
          "signature.signature must be a canonical 65-byte r||s||v ECDSA signature (132-char 0x hex): a malformed-length signature REVERTS execute() on-chain (it does NOT pause)"
        );
      }
      const input = encodeAbiParameters(
        parseAbiParameters("address, bytes32, uint256, bytes"),
        [requiredSigner, actionHash, deadline, signature]
      );
      return {
        input,
        adapter: ADAPTERS.signature,
        value: 0n,
        summary: `Gate (SignatureAdapter): require co-signer ${requiredSigner} to have personal-signed action ${actionHash} (deadline ${deadline.toString()})`,
        warnings: [
          "Co-signer gate is ONE-SHOT: the adapter marks keccak256(signature) as used, so this approval passes at most once even though the outer W3Cash nonce is not consumed. Compute exactly what the co-signer must EIP-191 personal-sign with signatureMessageHash({ account: <initiator>, actionHash, deadline }).",
        ],
      };
    }
    case "marketResolved": {
      const market = addr(cond.market, "marketResolved.market");
      const input = queryInput(
        market,
        VIEW_SELECTOR.isSettled,
        OPERATORS.eq,
        1n
      );
      return {
        input,
        adapter: ADAPTERS.query,
        value: 0n,
        summary: `Gate (QueryAdapter): Sooth market ${market}.isSettled() == true (proceed only once the prediction market has settled)`,
      };
    }
    case "marketOutcome": {
      const market = addr(cond.market, "marketOutcome.market");
      const outcome = resolveOutcome(cond.outcome, "marketOutcome.outcome");
      const input = queryInput(
        market,
        VIEW_SELECTOR.winningOutcome,
        OPERATORS.eq,
        outcome
      );
      const label =
        (["NO", "YES", "INVALID"] as const)[Number(outcome)] ??
        `outcome ${outcome.toString()}`;
      return {
        input,
        adapter: ADAPTERS.query,
        value: 0n,
        summary: `Gate (QueryAdapter): Sooth market ${market}.winningOutcome() == ${outcome.toString()} (${label})`,
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
    if (encoded.warnings) {
      for (const w of encoded.warnings) warnings.push(`#${index} [${type}] ${w}`);
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

/** Replay / cancellation caveat, surfaced as a first-class field. */
export interface ReplayCaveat {
  readonly replayable: boolean;
  readonly caveat: string;
  readonly cancel: string;
}

export const REPLAY_CAVEAT: ReplayCaveat = {
  replayable: true,
  caveat:
    "W3CashProcessor.execute() verifies but does NOT consume the outer nonce, so a captured signed payload stays valid and is re-executable by anyone until the initiator advances their nonce. Damage is bounded by the token allowance each adapter holds — never grant open-ended/unlimited approvals for transfer/swap/aaveDeposit/bridge intents.",
  cancel:
    "Call incrementNonce() on the W3CashProcessor (0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE) to invalidate every outstanding signature bound to the current nonce.",
};

/** Accurate, self-describing counts (no '18 actions' overclaim). */
export interface CapabilityCounts {
  readonly actionTypes: number;
  readonly conditionTypes: number;
  readonly deployedActionAdapters: number;
  readonly deployedConditionAdapters: number;
  readonly deployedAdapters: number;
}

export interface CapabilityCatalog {
  readonly chainId: number;
  readonly chainName: string;
  readonly processor: Address;
  readonly adapterRegistry: Address;
  readonly localChainIndex: number;
  readonly operators: Record<OperatorName, number>;
  readonly gasPriceOperators: Record<GasOperatorName, number>;
  readonly marketOutcomes: Record<MarketOutcomeName, number>;
  readonly counts: CapabilityCounts;
  readonly summary: string;
  readonly replay: ReplayCaveat;
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
    gasPriceOperators: { ...GAS_OPERATORS },
    marketOutcomes: { ...MARKET_OUTCOME },
    counts: {
      // 8 action TYPES over 6 deployed action adapters (3 aave* types share
      // AaveAdapter); 12 condition TYPES over 5 deployed condition adapters
      // (4 wait* share WaitAdapter; balance/price/query/marketResolved/
      // marketOutcome share QueryAdapter). 11 deployed adapters total.
      actionTypes: 8,
      conditionTypes: 12,
      deployedActionAdapters: 6,
      deployedConditionAdapters: 5,
      deployedAdapters: 11,
    },
    summary:
      "8 action types + 12 condition types, backed by 11 on-chain-verified adapters on Base Sepolia (6 action adapters: Transfer/Approve/Swap/Aave/Wrap/Bridge; 5 condition adapters: Wait/Query/TimeRange/GasPrice/Signature).",
    replay: REPLAY_CAVEAT,
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
      {
        type: "bridge",
        adapter: "BridgeAdapter",
        fields: [
          "recipient",
          "destinationChainId",
          "inputToken",
          "outputToken?",
          "inputAmount",
          "outputAmount",
          "quoteTimestamp",
          "fillDeadline",
          "exclusivityDeadline?",
          "message?",
          "value?",
        ],
        requiresPriorApprove: true,
        note: "Across depositV3 to destinationChainId (REAL EVM chain id). ERC20 only (bridge WETH; native ETH unsupported). outputAmount/quoteTimestamp should come from the Across suggested-fees quote; fillDeadline must be in [now, now+21600s] and non-zero. Approve BridgeAdapter for inputToken first.",
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
        adapter: "QueryAdapter",
        fields: ["token", "target", "operator", "threshold"],
        note: "QueryAdapter staticcall of token.balanceOf(target) compared unsigned. token is REQUIRED (ERC20); native ETH has no balanceOf() and is rejected.",
      },
      {
        type: "price",
        adapter: "QueryAdapter",
        fields: ["feed", "operator", "targetPrice", "checkStaleness?"],
        note: "QueryAdapter staticcall of feed.latestAnswer() compared UNSIGNED (targetPrice must be >= 0). checkStaleness has no equivalent and is dropped with a warning.",
      },
      {
        type: "query",
        adapter: "QueryAdapter",
        fields: ["target", "calldata", "operator", "expected"],
        note: "staticcall(target, calldata) decoded as a single uint256, compared unsigned. The generic on-chain view-gate that balance/price/market* compile down to.",
      },
      {
        type: "timeRange",
        adapter: "TimeRangeAdapter",
        fields: ["startTime", "endTime", "recurring"],
        note: "recurring=true: startTime/endTime are UTC hours 0-23, repeat daily, END-EXCLUSIVE, overnight wrap when start>end. recurring=false: absolute unix window, BOTH bounds inclusive.",
      },
      {
        type: "gasPrice",
        adapter: "GasPriceAdapter",
        fields: ["operator", "threshold"],
        note: "Gate on tx.gasprice (wei) of the settling tx. REDUCED operator set: lt/gt/lte/gte (0..3) only — eq/neq revert on-chain.",
      },
      {
        type: "signature",
        adapter: "SignatureAdapter",
        fields: ["requiredSigner", "actionHash", "deadline", "signature"],
        note: "2nd-approver ECDSA gate. Caller supplies a pre-obtained co-signer signature; use signatureMessageHash() to compute what to personal-sign. One-shot per signature; malformed sigs REVERT (well-formed-but-wrong-signer PAUSEs).",
      },
      {
        type: "marketResolved",
        adapter: "QueryAdapter",
        fields: ["market"],
        note: "Convenience gate: Sooth TruthMarket.isSettled() == true. Compiles to a QueryAdapter staticcall.",
      },
      {
        type: "marketOutcome",
        adapter: "QueryAdapter",
        fields: ["market", "outcome"],
        note: "Convenience gate: Sooth TruthMarket.winningOutcome() == outcome (0=NO,1=YES,2=INVALID, or the names). Compiles to a QueryAdapter staticcall.",
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
      "execute() does NOT consume the nonce; a signed payload is replayable until the initiator calls incrementNonce() — see the `replay` field.",
      "balance/price/marketResolved/marketOutcome all compile to the ONE deployed QueryAdapter (0x4bC2F784...) — there is no separate Balance or Price adapter on Base Sepolia.",
      "TimeRangeAdapter and GasPriceAdapter are reachable ONLY by direct address (registryId null); they are not in the AdapterRegistry uint8 id space.",
      "GasPriceAdapter uses a REDUCED operator set (lt/gt/lte/gte); it has no eq/neq. See `gasPriceOperators`.",
      "Live adapters: Wait, Query, Aave, Transfer, Approve, Swap, Wrap, Bridge, TimeRange, GasPrice, Signature. Other *.sol adapters in the contracts repo (Borrow/Repay/Vote/HealthFactor/…) are NOT registered/deployed on Base Sepolia — do not target them.",
    ],
  };
}

// ---------------------------------------------------------------------------
// Canned recipes (for GET /recipes)
// ---------------------------------------------------------------------------

/**
 * Well-known Base Sepolia (84532) addresses used by the canned recipes. All are
 * real on-chain contracts; the recipes are runnable templates (time/price/quote
 * fields must still be refreshed to current values before signing).
 */
export const KNOWN_ADDRESSES = {
  usdc: getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e"), // Circle USDC (Base Sepolia)
  mockUsdc: getAddress("0xaf24cBb3E8A2c991412eD76acF2c7719b987Df21"), // Sooth MockUSDC
  weth: getAddress("0x4200000000000000000000000000000000000006"), // canonical WETH
  ethUsdFeed: getAddress("0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1"), // Chainlink ETH/USD (8 dec)
  demoMarket: getAddress("0x80334C47F3DcE19FcFE7dB1AEce7423D32C4ccB1"), // settled TruthMarket (YES)
  sampleWallet: getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3"), // example recipient/holder
} as const;

export interface Recipe {
  readonly id: string;
  readonly title: string;
  readonly description: string;
  /** A ready-to-POST body for /compile-intent (refresh time/price/quote fields). */
  readonly request: CompileRequest;
}

export interface RecipeBook {
  readonly chainId: number;
  readonly processor: Address;
  /** First-class replay/cancel caveat — every recipe produces a replayable signature. */
  readonly replay: ReplayCaveat;
  readonly demoMarket: Address;
  readonly recipes: readonly Recipe[];
  readonly notes: readonly string[];
}

/**
 * Five canned recipes, each using ONLY on-chain-verified deployed adapters:
 * scheduled DCA, buy-the-dip, Aave stop-loss, cross-chain sweep, and a
 * prediction-gated withdraw against the settled demo market.
 */
export function getRecipes(): RecipeBook {
  const K = KNOWN_ADDRESSES;
  return {
    chainId: CHAIN_ID,
    processor: PROCESSOR,
    replay: REPLAY_CAVEAT,
    demoMarket: K.demoMarket,
    recipes: [
      {
        id: "dca",
        title: "Scheduled DCA: wait until a time, then swap USDC -> WETH",
        description:
          "Time-gated buy. WaitAdapter holds until the unix timestamp, then SwapAdapter runs a Uniswap V3 exactInputSingle. Initiator must pre-approve SwapAdapter for USDC. Re-sign with a new timestamp for each interval.",
        request: {
          chain: CHAIN_ID,
          conditions: [{ type: "waitTime", timestamp: "1767225600" }],
          actions: [
            {
              type: "swap",
              tokenIn: K.usdc,
              tokenOut: K.weth,
              amountIn: "10000000",
              minAmountOut: "1",
              fee: 3000,
            },
          ],
        },
      },
      {
        id: "buy-the-dip",
        title: "Buy the dip: when ETH/USD <= $1,800, swap USDC -> WETH",
        description:
          "QueryAdapter staticcalls the Chainlink ETH/USD feed's latestAnswer() (8 decimals) and gates until it is <= 180000000000 ($1,800). Then SwapAdapter buys WETH. Approve SwapAdapter for USDC first.",
        request: {
          chain: CHAIN_ID,
          conditions: [
            {
              type: "price",
              feed: K.ethUsdFeed,
              operator: "lte",
              targetPrice: "180000000000",
            },
          ],
          actions: [
            {
              type: "swap",
              tokenIn: K.usdc,
              tokenOut: K.weth,
              amountIn: "25000000",
              minAmountOut: "1",
              fee: 3000,
            },
          ],
        },
      },
      {
        id: "aave-stop-loss",
        title: "Aave stop-loss: when ETH/USD <= $1,500, withdraw all WETH from Aave",
        description:
          "QueryAdapter gates on the Chainlink ETH/USD feed <= 150000000000 ($1,500); once it trips, AaveAdapter withdraws the entire WETH position back to the initiator. Approve AaveAdapter for the aToken first.",
        request: {
          chain: CHAIN_ID,
          conditions: [
            {
              type: "price",
              feed: K.ethUsdFeed,
              operator: "lte",
              targetPrice: "150000000000",
            },
          ],
          actions: [{ type: "aaveWithdrawAll", token: K.weth }],
        },
      },
      {
        id: "cross-chain-sweep",
        title: "Cross-chain sweep: when WETH balance is large enough, bridge to Sepolia",
        description:
          "QueryAdapter gates on the initiator's WETH balanceOf >= threshold, then BridgeAdapter deposits into Across for delivery on Ethereum Sepolia (11155111). Approve BridgeAdapter for WETH first. IMPORTANT: refresh outputAmount + quoteTimestamp from the Across suggested-fees quote and set fillDeadline to now+21600s before signing — the values below are placeholders.",
        request: {
          chain: CHAIN_ID,
          conditions: [
            {
              type: "balance",
              token: K.weth,
              target: K.sampleWallet,
              operator: "gte",
              threshold: "100000000000000000",
            },
          ],
          actions: [
            {
              type: "bridge",
              recipient: K.sampleWallet,
              destinationChainId: "11155111",
              inputToken: K.weth,
              outputToken: "0x0000000000000000000000000000000000000000",
              inputAmount: "100000000000000000",
              outputAmount: "99500000000000000",
              quoteTimestamp: "1752566400",
              fillDeadline: "1752588000",
            },
          ],
        },
      },
      {
        id: "prediction-gated-withdraw",
        title: "Prediction-gated withdraw: once the market resolves YES, transfer USDC",
        description:
          "QueryAdapter staticcalls the Sooth TruthMarket's winningOutcome() and gates until it equals 1 (YES); then TransferAdapter moves USDC to the recipient. The demo market is already settled YES, so this gate passes immediately. Swap in marketResolved{market} to gate on settlement regardless of outcome. Approve TransferAdapter for USDC first.",
        request: {
          chain: CHAIN_ID,
          conditions: [
            { type: "marketOutcome", market: K.demoMarket, outcome: "YES" },
          ],
          actions: [
            {
              type: "transfer",
              token: K.usdc,
              to: K.sampleWallet,
              amount: "1000000",
            },
          ],
        },
      },
    ],
    notes: [
      "Every recipe compiles to a REPLAYABLE signature (see `replay`); cancel with incrementNonce().",
      "Recipes use only on-chain-verified deployed adapters (Wait/Query/Swap/Aave/Bridge/Transfer).",
      "Time-, price-, and Across-quote fields are illustrative — refresh them to current values before signing, or the gate never trips (price/time) or the deposit reverts/never fills (stale Across quote).",
      "POST any recipe's `request` object to /compile-intent to get the signable envelope.",
    ],
  };
}
