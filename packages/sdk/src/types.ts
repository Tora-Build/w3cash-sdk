import type { Address, Hash, Hex } from 'viem';

// Supported chains
export type SupportedChain = 'base-sepolia' | 'base';

// Configuration
export interface W3cashConfig {
  /** Chain to connect to */
  chain: SupportedChain;
  /** RPC URL (optional, uses public RPC if not provided) */
  rpcUrl?: string;
}

// Flow types
export type FlowName = 'x402' | 'yield' | 'erc8004' | 'swap' | 'bridge';

// Payment types for x402
export interface PaymentReceipt {
  from: Address;
  to: Address;
  token: Address;
  amount: bigint;
  resourceId: Hex;
  timestamp: bigint;
}

export interface PayOptions {
  /** Recipient address */
  to: Address;
  /** Amount to pay (in token units) */
  amount: bigint;
  /** Token address */
  token: Address;
  /** Resource identifier (e.g., API endpoint hash) */
  resourceId: Hex;
}

export interface PayEthOptions {
  /** Recipient address */
  to: Address;
  /** Resource identifier */
  resourceId: Hex;
  /** Amount of ETH to send (in wei) */
  value: bigint;
}

// Yield types
export interface DepositOptions {
  /** Token address */
  token: Address;
  /** Amount to deposit */
  amount: bigint;
}

export interface WithdrawOptions {
  /** Token address */
  token: Address;
  /** Amount to withdraw */
  amount: bigint;
}

// Transaction result
export interface TxResult {
  hash: Hash;
  wait: () => Promise<TxReceipt>;
}

export interface TxReceipt {
  status: 'success' | 'reverted';
  blockNumber: bigint;
  gasUsed: bigint;
}
