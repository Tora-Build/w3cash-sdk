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

/** Union of every adapter key (transfer/approve/swap/…/signature). */
export type AdapterKey = keyof typeof ADAPTERS;

// ---------------------------------------------------------------------------
// Multi-chain deployment registry
// ---------------------------------------------------------------------------

/**
 * Per-chain deployment config. `adapters` is a PARTIAL map — a chain lists only
 * the adapters actually deployed there. A request needing an adapter this chain
 * does not deploy is rejected with a ValidationError naming the chain (see
 * requireAdapter). Both supported chains use local chain INDEX 0 in their
 * AdapterRegistry (getChain(0) == chainId), so encodeOperation's LOCAL_CHAIN_INDEX
 * is correct for either.
 */
export interface ChainConfig {
  readonly chainId: number;
  readonly chainName: string;
  readonly processor: Address;
  readonly adapterRegistry: Address;
  readonly localChainIndex: number;
  readonly adapters: Partial<Record<AdapterKey, AdapterInfo>>;
}

// --- X Layer testnet (chainId 1952) — minimal core, no external-protocol legs ---
// Deployed 2026-07-15 via DeployXLayerCore.s.sol. Uniswap/Aave/Across/Chainlink
// are absent on X Layer, so Swap/Aave/Wrap/Bridge are intentionally NOT deployed.
// registry.setChain(0, 1952) was configured so the processor's local-routing
// check (getChain(op.chain) == block.chainid) passes for chain-index 0 ops.
export const XLAYER_CHAIN_ID = 1952 as const;

export const XLAYER_PROCESSOR: Address = getAddress(
  "0x3C06E44bD4d09328a4c374174b8e325c0C674b6E"
);

export const XLAYER_ADAPTER_REGISTRY: Address = getAddress(
  "0x58F35BE6A5e3D2be4C3575853043322B02FEeD84"
);

/**
 * X Layer testnet adapters. Same contract types as Base Sepolia (identical bytes4
 * self-tags), different addresses. registryId is null for all: only setChain was
 * configured on X Layer — adapters route by ADDRESS on the local path and none
 * were registered in the AdapterRegistry uint8 id space (which local exec ignores
 * anyway). Every address was returned by DeployXLayerCore's broadcast.
 */
export const XLAYER_ADAPTERS = {
  transfer: {
    name: "TransferAdapter",
    address: getAddress("0xbc7b155057Bb78BB8bF9c9F9Fa6bFCc931aEAF38"),
    adapterId: "0xecbe83c0",
    registryId: null,
    deployed: true,
  },
  approve: {
    name: "ApproveAdapter",
    address: getAddress("0x1aF3cB8B270Db3e71fC979543c32B87709EA191f"),
    adapterId: "0x61da13e4",
    registryId: null,
    deployed: true,
  },
  wait: {
    name: "WaitAdapter",
    address: getAddress("0x8629b9ca457F4088ec8346FAED61DA858FDB498d"),
    adapterId: "0x05bdc82b",
    registryId: null,
    deployed: true,
  },
  query: {
    name: "QueryAdapter",
    address: getAddress("0x50293aD4e42593A8b081960c991c198729E81192"),
    adapterId: "0x7485829c",
    registryId: null,
    deployed: true,
  },
  gasPrice: {
    name: "GasPriceAdapter",
    address: getAddress("0x12A38bc9E3bD2359265cE70451777eDe2fd875A3"),
    adapterId: "0x62c7743a",
    registryId: null,
    deployed: true,
  },
  timeRange: {
    name: "TimeRangeAdapter",
    address: getAddress("0xBE566c267A0D350e1D647Ccb621cC657FA3a1d50"),
    adapterId: "0x79b4e21f",
    registryId: null,
    deployed: true,
  },
  signature: {
    name: "SignatureAdapter",
    address: getAddress("0xaa3Ffae62A8Af00d08Ac395e9551776b0A01E492"),
    adapterId: "0xfde104a6",
    registryId: null,
    deployed: true,
  },
} as const satisfies Partial<Record<AdapterKey, AdapterInfo>>;

/** Base Sepolia (84532) — the DEFAULT chain, full adapter set. */
export const BASE_SEPOLIA_CONFIG: ChainConfig = {
  chainId: CHAIN_ID,
  chainName: "Base Sepolia",
  processor: PROCESSOR,
  adapterRegistry: ADAPTER_REGISTRY,
  localChainIndex: LOCAL_CHAIN_INDEX,
  adapters: ADAPTERS,
};

/** X Layer testnet (1952) — minimal core (transfer/approve + all gate adapters). */
export const XLAYER_CONFIG: ChainConfig = {
  chainId: XLAYER_CHAIN_ID,
  chainName: "X Layer testnet",
  processor: XLAYER_PROCESSOR,
  adapterRegistry: XLAYER_ADAPTER_REGISTRY,
  localChainIndex: LOCAL_CHAIN_INDEX, // getChain(0) == 1952 (setChain(0,1952))
  adapters: XLAYER_ADAPTERS,
};

export const XLAYER_MAINNET_CHAIN_ID = 196 as const;

/**
 * X Layer MAINNET (196) — same minimal core as testnet, deployed to the SAME
 * addresses (deterministic nonce-0 deploy by the same deployer 0xEfdB…). The
 * registry's local mapping is set on-chain (`setChain(0, 196)`, getChain(0)==196)
 * so local ops route correctly. USD₮0 here is 0x779Ded… (also the x402 mainnet
 * settlement asset).
 */
export const XLAYER_MAINNET_CONFIG: ChainConfig = {
  chainId: XLAYER_MAINNET_CHAIN_ID,
  chainName: "X Layer mainnet",
  processor: XLAYER_PROCESSOR, // identical address to testnet (deterministic deploy)
  adapterRegistry: XLAYER_ADAPTER_REGISTRY,
  localChainIndex: LOCAL_CHAIN_INDEX, // getChain(0) == 196 (setChain(0,196))
  adapters: XLAYER_ADAPTERS, // same addresses, independently deployed on 196
};

/** Supported execution chains, keyed by REAL chainId. */
export const CHAINS: Record<number, ChainConfig> = {
  [CHAIN_ID]: BASE_SEPOLIA_CONFIG,
  [XLAYER_CHAIN_ID]: XLAYER_CONFIG,
  [XLAYER_MAINNET_CHAIN_ID]: XLAYER_MAINNET_CONFIG,
};

export const SUPPORTED_CHAIN_IDS: readonly number[] = Object.values(CHAINS).map(
  (c) => c.chainId
);

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
      // outputAmount/quoteTimestamp/fillDeadline can be auto-filled by the server
      // (set autoQuote:true on the bridge action, or POST /quote/bridge); supply
      // them yourself only when quoting manually.
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
  chain?: Numeric; // 84532 Base Sepolia (default) or 1952 X Layer testnet
  nonce?: Numeric; // signer's current on-chain nonce (default 0)
  seq?: Numeric; // starting seq in header (default 0)
  initiator?: string; // optional; echoed into summary, not required
  conditions?: ConditionRequest[];
  actions?: ActionRequest[];
  /**
   * Safe-by-default expiry policy (decision #6). Controls the auto-injected
   * absolute timeRange gate that bounds how long this signature stays
   * replayable:
   *   - undefined | "auto"  → classify the intent and pick a window
   *     (immediate 1d · triggered 30d · scheduled waitTime+7d · market unbounded)
   *   - "none"              → opt out; NO time bound (rely on incrementNonce())
   *   - <seconds> (Numeric) → explicit window: expires at `now` + seconds
   * Requires `now` (a unix timestamp) to compute the absolute bound; without it
   * auto-expiry is skipped and the artifact carries a warning. The ASP injects
   * `now` server-side, so the live API is safe by default; a direct SDK caller
   * that wants the guard must pass `now` itself.
   */
  expiry?: "auto" | "none" | Numeric;
  /** Unix seconds used as the clock for `expiry`. Server-injected on the ASP. */
  now?: Numeric;
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
  /**
   * Safe-by-default expiry outcome. `applied` is true when an absolute timeRange
   * gate was auto-injected as step 0; `endTime` is its unix bound; `className`
   * is the classification that chose the window. When `applied` is false the
   * signature has no on-chain time bound (opted out, or `now` was absent).
   */
  readonly expiry: {
    readonly applied: boolean;
    readonly endTime: string | null;
    readonly className: string | null;
  };
  /**
   * Worst-case token outflow this signed intent authorizes PER execution — the
   * amount a replayed signature could move out of the initiator, per token.
   */
  readonly exposure: readonly TokenExposure[];
}

/** Per-token worst-case outflow authorized by an intent. */
export interface TokenExposure {
  readonly token: Address;
  readonly amount: string; // smallest-unit outflow of this token per execution
  readonly unlimited: boolean; // an unlimited (uint256-max) approval touches it
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
  // `value` is a "0x"-prefixed hex string here, so (length - 2) is the hex-digit
  // count. Reject odd counts, which do not form whole bytes.
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
  chain?: Numeric; // default: Base Sepolia (84532)
}): Hex {
  const cfg = resolveChain(params.chain);
  const sigAdapter = requireAdapter(cfg, "signature", "signature");
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
      [account, actionHash, deadline, BigInt(cfg.chainId), sigAdapter.address]
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

function encodeAction(action: ActionRequest, cfg: ChainConfig): EncodedStep {
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
        adapter: requireAdapter(cfg, "transfer", "transfer"),
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
        adapter: requireAdapter(cfg, "approve", "approve"),
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
        adapter: requireAdapter(cfg, "swap", "swap"),
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
        adapter: requireAdapter(cfg, "aave", action.type),
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
        adapter: requireAdapter(cfg, "aave", action.type),
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
        adapter: requireAdapter(cfg, "aave", action.type),
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
        adapter: requireAdapter(cfg, "wrap", "wrap"),
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
        adapter: requireAdapter(cfg, "bridge", "bridge"),
        value: toUint(action.value ?? 0, "bridge.value", UINT_MAX.u112),
        summary: `Bridge ${inputAmount.toString()} of ${inputToken} from Base Sepolia to chain ${destinationChainId.toString()} for ${outputAmount.toString()} of ${
          outputToken === ZERO_ADDRESS ? "auto/wrapped-native" : outputToken
        } to ${recipient} via Across depositV3 (initiator must approve BridgeAdapter for inputToken first)`,
        warnings: [
          "bridge.outputAmount and bridge.quoteTimestamp are caller-supplied and SHOULD come from the Across suggested-fees quote (GET https://testnet.across.to/api/suggested-fees?...&originChainId=84532&destinationChainId=<dst>&amount=<in>): outputAmount = inputAmount - totalRelayFee.total, quoteTimestamp = json.timestamp. quoteTimestamp must be within 3600s of chain time or depositV3 reverts; too-high outputAmount never fills. The encoder does not fetch these — set autoQuote:true on the bridge action (or POST /quote/bridge) to have the ASP fill them for you.",
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

function encodeCondition(cond: ConditionRequest, cfg: ChainConfig): EncodedStep {
  switch (cond.type) {
    case "waitTime": {
      const value = toUint(cond.timestamp, "waitTime.timestamp", UINT_MAX.u256);
      const input = encodeAbiParameters(
        parseAbiParameters("uint8, uint256, address, int256"),
        [WAIT_TYPE.timestamp, value, ZERO_ADDRESS, 0n]
      );
      return {
        input,
        adapter: requireAdapter(cfg, "wait", cond.type),
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
        adapter: requireAdapter(cfg, "wait", cond.type),
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
        adapter: requireAdapter(cfg, "wait", cond.type),
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
        adapter: requireAdapter(cfg, "query", cond.type),
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
        adapter: requireAdapter(cfg, "query", cond.type),
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
        adapter: requireAdapter(cfg, "timeRange", "timeRange"),
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
        adapter: requireAdapter(cfg, "gasPrice", "gasPrice"),
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
        adapter: requireAdapter(cfg, "signature", "signature"),
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
        adapter: requireAdapter(cfg, "query", cond.type),
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
        adapter: requireAdapter(cfg, "query", cond.type),
        value: 0n,
        summary: `Gate (QueryAdapter): Sooth market ${market}.winningOutcome() == ${outcome.toString()} (${label})`,
      };
    }
    case "query": {
      const target = addr(cond.target, "query.target");
      const calldata = hexBytes(cond.calldata, "query.calldata");
      const operator = resolveOperator(cond.operator, "query.operator");
      const expected = toUint(cond.expected, "query.expected", UINT_MAX.u256);
      const input = queryInput(target, calldata, operator, expected);
      return {
        input,
        adapter: requireAdapter(cfg, "query", cond.type),
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

/**
 * Resolve a request `chain` value to a ChainConfig. Accepts a real chainId
 * (84532 Base Sepolia / 1952 X Layer testnet) or, for backward compat, the
 * legacy local INDEX 0 (=> Base Sepolia, the historical "local" alias).
 * Undefined => Base Sepolia (default). Anything else throws ValidationError
 * (so an unsupported chain like `1` is rejected, as the tests require).
 */
export function resolveChain(chain?: Numeric): ChainConfig {
  if (chain === undefined || chain === null) return BASE_SEPOLIA_CONFIG;
  const c = toBigInt(chain, "chain");
  if (c === BigInt(LOCAL_CHAIN_INDEX)) return BASE_SEPOLIA_CONFIG; // legacy index-0 alias
  const cfg = CHAINS[Number(c)];
  if (!cfg) {
    throw new ValidationError(
      `unsupported chain ${c.toString()}; supported: ${SUPPORTED_CHAIN_IDS.join(
        ", "
      )} (Base Sepolia / X Layer testnet). Pass the real chainId.`
    );
  }
  return cfg;
}

/**
 * Fetch the deployed adapter for `key` on `cfg`, or throw a ValidationError
 * naming the chain if this chain does not deploy it. This is how per-chain
 * availability is enforced: e.g. `swap`/`aaveDeposit`/`wrap`/`bridge` on X Layer
 * (no Uniswap/Aave/Across there) are rejected here, while every gate adapter is
 * present on both chains.
 */
function requireAdapter(
  cfg: ChainConfig,
  key: AdapterKey,
  type: string
): AdapterInfo {
  const a = cfg.adapters[key];
  if (!a) {
    throw new ValidationError(
      `'${type}' is not available on ${cfg.chainName} (chainId ${
        cfg.chainId
      }); this chain deploys only: ${Object.keys(cfg.adapters).join(", ")}`
    );
  }
  return a;
}

// ---------------------------------------------------------------------------
// Safe-by-default policy: auto-expiry + exposure accounting (decision #6)
// ---------------------------------------------------------------------------

const DAY_SECONDS = 86_400n;

/**
 * Absolute-time sentinel (Dec 31, 2199 23:59:59 UTC) reused from the protocol's
 * "no expiry" convention. A non-recurring timeRange ending here is effectively
 * unbounded — used for market-gated intents whose resolution time is external.
 */
export const INFINITE_EXPIRY = 7_258_118_399n;

/** Per-class relative windows for the auto-expiry safe default. */
const EXPIRY_WINDOWS = {
  immediate: DAY_SECONDS, // no gate — should settle right away
  triggered: 30n * DAY_SECONDS, // price/query/balance/gas gate — needs time to fire
  scheduledGrace: 7n * DAY_SECONDS, // waitTime target + grace
} as const;

type ExpiryClass =
  | "immediate"
  | "triggered"
  | "scheduled"
  | "market"
  | "custom";

interface AutoExpiry {
  readonly endTime: bigint;
  readonly className: ExpiryClass;
}

/**
 * Classify an intent and pick an absolute expiry (unix seconds) for the
 * auto-injected timeRange gate. Returns null when auto-expiry does not apply:
 * opted out ("none"), no `now` clock, no actions to guard, or an explicit
 * non-recurring timeRange already bounds the signature's lifetime.
 */
function computeAutoExpiry(
  conditions: ConditionRequest[],
  actions: ActionRequest[],
  now: bigint | undefined,
  expiryOpt: CompileRequest["expiry"]
): AutoExpiry | null {
  if (expiryOpt === "none") return null;
  if (now === undefined) return null; // no time source → cannot bound
  if (actions.length === 0) return null; // nothing to guard

  // An explicit absolute (non-recurring) timeRange IS the caller's own expiry.
  const hasAbsoluteWindow = conditions.some(
    (c) => c && c.type === "timeRange" && c.recurring === false
  );
  if (hasAbsoluteWindow) return null;

  // Explicit numeric window overrides classification.
  if (expiryOpt !== undefined && expiryOpt !== "auto") {
    const secs = toUint(expiryOpt, "expiry", UINT_MAX.u256);
    return { endTime: now + secs, className: "custom" };
  }

  const has = (t: string): boolean =>
    conditions.some((c) => c && c.type === t);

  // Prediction-market gates resolve on an external schedule — unbounded
  // lifetime, protected by the gate + allowance + cancel, not by a short clock.
  if (has("marketResolved") || has("marketOutcome")) {
    return { endTime: INFINITE_EXPIRY, className: "market" };
  }
  // Scheduled (absolute future time): live until the latest waitTime + grace.
  const waitTimes = conditions
    .filter(
      (c): c is Extract<ConditionRequest, { type: "waitTime" }> =>
        Boolean(c) && c.type === "waitTime"
    )
    .map((c) => toUint(c.timestamp, "waitTime.timestamp", UINT_MAX.u256));
  if (waitTimes.length > 0) {
    const latest = waitTimes.reduce((a, b) => (b > a ? b : a), 0n);
    return {
      endTime: latest + EXPIRY_WINDOWS.scheduledGrace,
      className: "scheduled",
    };
  }
  // Any trigger gate (price/query/balance/gas/block): moderate window.
  if (
    has("price") ||
    has("waitPriceGte") ||
    has("waitPriceLte") ||
    has("query") ||
    has("balance") ||
    has("gasPrice") ||
    has("waitBlock")
  ) {
    return { endTime: now + EXPIRY_WINDOWS.triggered, className: "triggered" };
  }
  // No trigger conditions — fire immediately, short window.
  return { endTime: now + EXPIRY_WINDOWS.immediate, className: "immediate" };
}

/** Build the timeRange EncodedStep for an auto-expiry (startTime 0, end inclusive). */
function encodeAutoExpiry(exp: AutoExpiry, cfg: ChainConfig): EncodedStep {
  const input = encodeAbiParameters(parseAbiParameters("uint256, uint256, bool"), [
    0n,
    exp.endTime,
    false,
  ]);
  const iso = new Date(Number(exp.endTime) * 1000).toISOString();
  const unbounded = exp.className === "market";
  return {
    input,
    adapter: requireAdapter(cfg, "timeRange", "timeRange"),
    value: 0n,
    summary: `Auto-expiry (safe default, class=${exp.className}): executable only through unix ${exp.endTime.toString()} (${iso})${
      unbounded
        ? " — effectively unbounded; protected by the gate + allowance + cancel"
        : ""
    }. Bounds signature replay. Opt out with expiry:"none"; set a window with expiry:<seconds>.`,
    warnings: unbounded
      ? [
          "auto-expiry is effectively unbounded (market-gated): the only lifetime protection is the market gate + the token allowance + incrementNonce(). Keep allowances exact and cancel when done.",
        ]
      : undefined,
  };
}

/**
 * Worst-case token outflow the signed intent authorizes per execution. Summed
 * over the actions that move value OUT of the initiator (transfer / swap-in /
 * aave-deposit / bridge-in); an `approve` contributes its granted amount
 * (spendable) and flags unlimited (uint256-max) approvals. Runs on
 * already-validated actions, so re-parsing never throws.
 */
function computeExposure(actions: ActionRequest[]): TokenExposure[] {
  const byToken = new Map<Address, { amount: bigint; unlimited: boolean }>();
  const add = (tokenRaw: string, amount: bigint, unlimited = false): void => {
    const token = addr(tokenRaw, "exposure.token");
    const cur = byToken.get(token) ?? { amount: 0n, unlimited: false };
    cur.amount += amount;
    cur.unlimited = cur.unlimited || unlimited;
    byToken.set(token, cur);
  };
  for (const a of actions) {
    switch (a.type) {
      case "transfer":
        add(a.token, toBigInt(a.amount, "transfer.amount"));
        break;
      case "approve": {
        const amt = toBigInt(a.amount, "approve.amount");
        add(a.token, amt, amt >= UINT_MAX.u256);
        break;
      }
      case "swap":
        add(a.tokenIn, toBigInt(a.amountIn, "swap.amountIn"));
        break;
      case "aaveDeposit":
        add(a.token, toBigInt(a.amount, "aaveDeposit.amount"));
        break;
      case "bridge":
        add(a.inputToken, toBigInt(a.inputAmount, "bridge.inputAmount"));
        break;
      // wrap forwards native ETH via the op value (surfaced separately); aave
      // withdraw(All) return underlying to the initiator — net inflow, not
      // counted as outflow exposure here.
      default:
        break;
    }
  }
  return [...byToken.entries()]
    .map(([token, v]) => ({
      token,
      amount: v.amount.toString(),
      unlimited: v.unlimited,
    }))
    .sort((a, b) => (a.token < b.token ? -1 : a.token > b.token ? 1 : 0));
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

export function compileIntent(request: CompileRequest): CompiledIntent {
  if (request === null || typeof request !== "object") {
    throw new ValidationError("request body must be a JSON object");
  }

  // Chain gate: resolve the target chain (Base Sepolia 84532 default, or X Layer
  // testnet 1952). resolveChain throws ValidationError on an unsupported chain.
  const cfg = resolveChain(request.chain);

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

  // Safe-by-default expiry (decision #6): classify the intent and, when a `now`
  // clock is available and the caller has not opted out, auto-inject an absolute
  // timeRange gate as step 0 to bound how long this signature stays replayable.
  const now =
    request.now !== undefined ? toUint(request.now, "now", UINT_MAX.u256) : undefined;
  const autoExpiry = computeAutoExpiry(conditions, actions, now, request.expiry);

  // Bound total work independent of body size (CPU-DoS guard). Count the
  // auto-expiry gate against the budget so the on-chain op array can't exceed it.
  const totalSteps = conditions.length + actions.length + (autoExpiry ? 1 : 0);
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

  // Auto-expiry gate goes FIRST so an expired signature pauses before any other
  // condition or action can run.
  if (autoExpiry) {
    pushStep("condition", "timeRange", encodeAutoExpiry(autoExpiry, cfg));
  }
  for (const cond of conditions) {
    if (cond === null || typeof cond !== "object" || typeof cond.type !== "string") {
      throw new ValidationError("each condition must be an object with a `type`");
    }
    pushStep("condition", cond.type, encodeCondition(cond, cfg));
  }
  for (const action of actions) {
    if (
      action === null ||
      typeof action !== "object" ||
      typeof action.type !== "string"
    ) {
      throw new ValidationError("each action must be an object with a `type`");
    }
    pushStep("action", action.type, encodeAction(action, cfg));
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

  // Safe-by-default surfacing: worst-case per-execution outflow + expiry status.
  const exposure = computeExposure(actions);
  for (const e of exposure) {
    if (e.unlimited) {
      warnings.push(
        `UNLIMITED APPROVAL: this intent grants an unbounded (uint256-max) allowance of ${e.token}; a replayed signature can drain the entire balance. Size the approve amount to exactly what the intent needs.`
      );
    }
  }
  if (!autoExpiry) {
    warnings.push(
      request.expiry === "none"
        ? "expiry:\"none\" — this signature has NO on-chain time bound; it stays replayable until incrementNonce(). This is an explicit opt-out."
        : "auto-expiry was NOT applied (no `now` clock provided); this signature has no on-chain time bound. Pass `now` (unix seconds) to enable the safe-default expiry, or cancel via incrementNonce()."
    );
  }

  const { payload, payloadHash, header, instruction, toSign } = encodeEnvelope(
    operations,
    inputs,
    nonce,
    seq
  );

  const humanSummary: string[] = [];
  if (initiator) humanSummary.push(`Initiator: ${initiator}`);
  humanSummary.push(
    `Chain: ${cfg.chainName} (${cfg.chainId}); Processor: ${cfg.processor}; nonce ${nonce.toString()}`
  );
  for (const s of steps) {
    humanSummary.push(`#${s.index} [${s.kind}/${s.type}] ${s.summary}`);
  }
  humanSummary.push(
    autoExpiry
      ? `Expiry: valid until unix ${autoExpiry.endTime.toString()} (${new Date(
          Number(autoExpiry.endTime) * 1000
        ).toISOString()}), class=${autoExpiry.className}. Bounds signature replay.`
      : `Expiry: NONE — signature never time-expires; cancel via incrementNonce().`
  );
  if (exposure.length > 0) {
    humanSummary.push(
      `Max exposure per execution: ${exposure
        .map(
          (e) => `${e.amount}${e.unlimited ? " (UNLIMITED)" : ""} of ${e.token}`
        )
        .join(", ")}.`
    );
  }

  return {
    chainId: cfg.chainId,
    processor: cfg.processor,
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
    expiry: {
      applied: autoExpiry !== null,
      endTime: autoExpiry ? autoExpiry.endTime.toString() : null,
      className: autoExpiry ? autoExpiry.className : null,
    },
    exposure,
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

/** Per-chain replay caveat — same text, with that chain's processor address in
 *  the cancel instruction. Base Sepolia returns the frozen REPLAY_CAVEAT above. */
export function replayCaveatFor(cfg: ChainConfig): ReplayCaveat {
  if (cfg.chainId === CHAIN_ID) return REPLAY_CAVEAT;
  return {
    replayable: true,
    caveat: REPLAY_CAVEAT.caveat,
    cancel: `Call incrementNonce() on the W3CashProcessor (${cfg.processor}) to invalidate every outstanding signature bound to the current nonce.`,
  };
}

/**
 * bytes4 selector of W3CashProcessor.incrementNonce() — the one-tx "cancel
 * everything" that advances the initiator's nonce and invalidates every
 * outstanding signature bound to the current one. keccak256("incrementNonce()").
 */
export const INCREMENT_NONCE_SELECTOR = "0x627cdcb9" as Hex;

/** A ready-to-send "cancel all my outstanding intents" transaction descriptor. */
export interface CancelInstruction {
  readonly chainId: number;
  readonly chainName: string;
  readonly processor: Address;
  readonly to: Address; // == processor
  readonly data: Hex; // incrementNonce() calldata (no args)
  readonly value: string; // "0"
  readonly note: string;
}

/**
 * Build the calldata that cancels every replayable W3Cash signature the
 * initiator has outstanding on `chain`: a no-arg incrementNonce() call to that
 * chain's processor. The caller signs+submits it from their own wallet (this
 * service is non-custodial). Since execute() never consumes the nonce, this is
 * the ONLY way to invalidate a leaked signature before its expiry.
 */
export function cancelInstruction(chain?: Numeric): CancelInstruction {
  const cfg = resolveChain(chain);
  return {
    chainId: cfg.chainId,
    chainName: cfg.chainName,
    processor: cfg.processor,
    to: cfg.processor,
    data: INCREMENT_NONCE_SELECTOR,
    value: "0",
    note: `Submit this transaction from the initiator's own wallet to advance its W3CashProcessor nonce on ${cfg.chainName} (${cfg.chainId}). It invalidates EVERY outstanding signature bound to the current nonce in one tx. Non-custodial: this service does not sign or send it.`,
  };
}

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

/** Full action catalog (Base Sepolia superset). getCapabilities filters this to
 *  the adapters actually deployed on the requested chain (by `adapter` name). */
const ACTION_CAPS: CapabilityCatalog["actions"] = [
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
];

/** Full condition catalog (Base Sepolia superset), filtered per-chain like ACTION_CAPS. */
const CONDITION_CAPS: CapabilityCatalog["conditions"] = [
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
];

/**
 * Capability catalog for one chain. Defaults to Base Sepolia (84532); pass 1952
 * for X Layer testnet. Actions/conditions are filtered to the adapters actually
 * deployed on the requested chain, and the counts are derived from that filter —
 * so X Layer (no Swap/Aave/Wrap/Bridge) reports 2 action types, Base Sepolia 8.
 */
export function getCapabilities(chain?: Numeric): CapabilityCatalog {
  const cfg = resolveChain(chain);
  const availableNames = new Set(
    Object.values(cfg.adapters).map((a) => a.name)
  );
  const actions = ACTION_CAPS.filter((a) => availableNames.has(a.adapter));
  const conditions = CONDITION_CAPS.filter((c) => availableNames.has(c.adapter));
  const actionAdapterNames = new Set(actions.map((a) => a.adapter));
  const conditionAdapterNames = new Set(conditions.map((c) => c.adapter));
  const deployedAdapters = Object.keys(cfg.adapters).length;
  const queryAddr = cfg.adapters.query?.address ?? ZERO_ADDRESS;
  const liveAdapterNames = Object.values(cfg.adapters)
    .map((a) => a.name.replace(/Adapter$/, ""))
    .join(", ");
  return {
    chainId: cfg.chainId,
    chainName: cfg.chainName,
    processor: cfg.processor,
    adapterRegistry: cfg.adapterRegistry,
    localChainIndex: cfg.localChainIndex,
    operators: { ...OPERATORS },
    gasPriceOperators: { ...GAS_OPERATORS },
    marketOutcomes: { ...MARKET_OUTCOME },
    counts: {
      actionTypes: actions.length,
      conditionTypes: conditions.length,
      deployedActionAdapters: actionAdapterNames.size,
      deployedConditionAdapters: conditionAdapterNames.size,
      deployedAdapters,
    },
    summary: `${actions.length} action types + ${conditions.length} condition types, backed by ${deployedAdapters} on-chain-verified adapters on ${cfg.chainName} (${cfg.chainId}).`,
    replay: replayCaveatFor(cfg),
    actions,
    conditions,
    adapterCatalog: Object.entries(cfg.adapters).map(([key, info]) => ({
      key,
      ...(info as AdapterInfo),
    })),
    notes: [
      `Chain: ${cfg.chainName} (${cfg.chainId}); processor ${cfg.processor}. Deployed adapters: ${Object.keys(cfg.adapters).join(", ")}.`,
      "Local (same-chain) routing is by the operation's `target` ADDRESS (W3CashProcessor.sol:176); field-1 `amb` is ignored locally and is left 0.",
      "field-4 selector (bytes8) is dead and left 0; field-2 fee (uint64) is cross-chain-only and left 0.",
      "Signature scheme is EIP-191 personal_sign over keccak256(abi.encodePacked(keccak256(payload), nonce)) — NOT EIP-712.",
      "execute() does NOT consume the nonce; a signed payload is replayable until the initiator calls incrementNonce() — see the `replay` field.",
      `balance/price/marketResolved/marketOutcome all compile to the ONE deployed QueryAdapter (${queryAddr}) — there is no separate Balance or Price adapter.`,
      "TimeRangeAdapter and GasPriceAdapter are reachable ONLY by direct address (registryId null); they are not in the AdapterRegistry uint8 id space.",
      "GasPriceAdapter uses a REDUCED operator set (lt/gt/lte/gte); it has no eq/neq. See `gasPriceOperators`.",
      `Live adapters on ${cfg.chainName}: ${liveAdapterNames}. Other *.sol adapters in the contracts repo are NOT registered/deployed here — do not target them.`,
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

/**
 * Well-known X Layer testnet (1952) addresses for the X Layer recipe set. The
 * minimal core has no Uniswap/Aave/Across/Chainlink, so X Layer recipes use only
 * transfer/approve + the time/block/gas/query/co-signer gates. USD₮0 is the OKX
 * X Layer testnet USDT (also the x402 settlement asset).
 */
export const XLAYER_KNOWN_ADDRESSES = {
  usdt0: getAddress("0x9e29b3aada05bf2d2c827af80bd28dc0b9b4fb0c"), // USD₮0 (X Layer testnet)
  sampleWallet: getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3"), // example recipient/holder
} as const;

/** X Layer MAINNET (196) known addresses. USD₮0 is the canonical LayerZero OFT
 *  (also the x402 mainnet settlement asset). */
export const XLAYER_MAINNET_KNOWN_ADDRESSES = {
  usdt0: getAddress("0x779Ded0c9e1022225f8E0630b35a9b54bE713736"), // USD₮0 (X Layer mainnet)
  sampleWallet: getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3"),
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
 * X Layer testnet (1952) recipe set. The minimal core has no swap/aave/bridge, so
 * these use only transfer + the time/gas/balance gates over USD₮0. Each request
 * pins chain:1952 so /compile-intent routes to the X Layer processor. These are
 * the intents an OKX Agentic Wallet can sign (no PK export) and settle gas-free.
 */
function getXLayerRecipes(cfg: ChainConfig): RecipeBook {
  const isMainnet = cfg.chainId === XLAYER_MAINNET_CHAIN_ID;
  const K = isMainnet ? XLAYER_MAINNET_KNOWN_ADDRESSES : XLAYER_KNOWN_ADDRESSES;
  const net = isMainnet ? "X Layer mainnet" : "X Layer testnet";
  const usdt0Short = isMainnet ? "0x779Ded…" : "0x9e29…";
  return {
    chainId: cfg.chainId,
    processor: cfg.processor,
    replay: replayCaveatFor(cfg),
    demoMarket: ZERO_ADDRESS, // no Sooth market deployed on X Layer testnet
    recipes: [
      {
        id: "scheduled-transfer",
        title: "Scheduled transfer: wait until a time, then send USD₮0",
        description:
          "WaitAdapter holds until the unix timestamp, then TransferAdapter moves USD₮0 to the recipient. Initiator must approve the X Layer TransferAdapter for USD₮0 first. Re-sign with a new timestamp for each run.",
        request: {
          chain: cfg.chainId,
          conditions: [{ type: "waitTime", timestamp: "1767225600" }],
          actions: [
            { type: "transfer", token: K.usdt0, to: K.sampleWallet, amount: "1000000" },
          ],
        },
      },
      {
        id: "gas-gated-transfer",
        title: "Gas-gated transfer: only settle when gas is cheap",
        description:
          "GasPriceAdapter gates until the settling tx's gas price is <= 5 gwei, then TransferAdapter sends USD₮0. Useful to defer a payout until the network is quiet. Approve the X Layer TransferAdapter for USD₮0 first.",
        request: {
          chain: cfg.chainId,
          conditions: [{ type: "gasPrice", operator: "lte", threshold: "5000000000" }],
          actions: [
            { type: "transfer", token: K.usdt0, to: K.sampleWallet, amount: "1000000" },
          ],
        },
      },
      {
        id: "balance-gated-transfer",
        title: "Balance-gated transfer: send only once a wallet is funded",
        description:
          "QueryAdapter staticcalls USD₮0.balanceOf(holder) and gates until it is >= the threshold, then TransferAdapter sends. A do-X-only-when-Y payout conditioned purely on on-chain state. Approve the X Layer TransferAdapter for USD₮0 first.",
        request: {
          chain: cfg.chainId,
          conditions: [
            {
              type: "balance",
              token: K.usdt0,
              target: K.sampleWallet,
              operator: "gte",
              threshold: "1000000",
            },
          ],
          actions: [
            { type: "transfer", token: K.usdt0, to: K.sampleWallet, amount: "1000000" },
          ],
        },
      },
    ],
    notes: [
      `${net} (${cfg.chainId}) minimal core: transfer/approve + time/block/gas/query/co-signer gates only. No swap/aave/wrap/bridge (Uniswap/Aave/Across absent).`,
      "Every recipe compiles to a REPLAYABLE signature (see `replay`); cancel with incrementNonce().",
      `USD₮0 (${usdt0Short}) is the ${net} USDT; amounts are in its smallest unit (6 decimals). Approve the X Layer TransferAdapter for USD₮0 before signing a transfer intent.`,
      "POST any recipe's `request` object to /compile-intent to get the signable envelope.",
    ],
  };
}

/**
 * Five canned recipes, each using ONLY on-chain-verified deployed adapters:
 * scheduled DCA, buy-the-dip, Aave stop-loss, cross-chain sweep, and a
 * prediction-gated withdraw against the settled demo market.
 */
export function getRecipes(chain?: Numeric): RecipeBook {
  const cfg = resolveChain(chain);
  if (cfg.chainId === XLAYER_CHAIN_ID || cfg.chainId === XLAYER_MAINNET_CHAIN_ID) {
    return getXLayerRecipes(cfg);
  }
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
          "QueryAdapter staticcalls the Sooth TruthMarket's winningOutcome() and gates until it equals 1 (YES); then TransferAdapter moves USDC to the recipient. This example market is already settled YES, so this gate passes immediately. Swap in marketResolved{market} to gate on settlement regardless of outcome. Approve TransferAdapter for USDC first.",
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
