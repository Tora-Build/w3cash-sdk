import type { Address, Hex } from 'viem';

/**
 * Supported action types
 */
export type ActionType = 
  | 'transfer'
  | 'swap'
  | 'yield'
  | 'approve'
  | 'wrap';

/**
 * Supported condition types
 */
export type ConditionType =
  | 'time'
  | 'block'
  | 'query';

/**
 * Query operators for condition checks
 */
export type QueryOperator = '<' | '>' | '<=' | '>=' | '==' | '!=';

/**
 * Transfer action parameters
 */
export interface TransferParams {
  token: Address;
  to: Address;
  amount: bigint;
}

/**
 * Swap action parameters
 */
export interface SwapParams {
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  minAmountOut?: bigint;
  slippageBps?: number; // basis points (100 = 1%)
}

/**
 * Yield action parameters
 */
export interface YieldParams {
  protocol: 'aave' | 'compound' | 'moonwell';
  action: 'deposit' | 'withdraw';
  token: Address;
  amount: bigint;
}

/**
 * Approve action parameters
 */
export interface ApproveParams {
  token: Address;
  spender: Address;
  amount: bigint;
}

/**
 * Wrap action parameters (ETH ↔ WETH)
 */
export interface WrapParams {
  /** true = wrap ETH→WETH, false = unwrap WETH→ETH */
  isWrap: boolean;
  amount: bigint;
}

/**
 * Time condition parameters
 */
export interface TimeConditionParams {
  /** Wait until this timestamp (unix seconds) */
  after?: number;
  /** Wait until this block number */
  afterBlock?: number;
}

/**
 * Query condition parameters
 */
export interface QueryConditionParams {
  /** Contract to query */
  target: Address;
  /** Encoded function call data */
  data: Hex;
  /** Comparison operator */
  operator: QueryOperator;
  /** Expected value to compare against */
  value: bigint;
}

/**
 * Action definition in an intent
 */
export interface IntentAction {
  type: ActionType;
  params: TransferParams | SwapParams | YieldParams | ApproveParams | WrapParams;
}

/**
 * Condition definition in an intent
 */
export interface IntentCondition {
  type: ConditionType;
  params: TimeConditionParams | QueryConditionParams;
}

/**
 * Built intent ready for signing
 */
export interface BuiltIntent {
  /** Encoded instruction bytes */
  instruction: Hex;
  /** Payload hash for signing */
  payloadHash: Hex;
  /** Human-readable summary */
  summary: string;
  /** Estimated gas */
  estimatedGas?: bigint;
}

/**
 * Signed intent ready for execution
 */
export interface SignedIntent {
  instruction: Hex;
  initiator: Address;
  nonce: bigint;
  signature: Hex;
}

/**
 * Operator constants matching contract
 */
export const QUERY_OPERATORS = {
  '<': 0,
  '>': 1,
  '<=': 2,
  '>=': 3,
  '==': 4,
  '!=': 5,
} as const;
