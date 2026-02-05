import type { Hash } from 'viem';

// Supported chains
export type SupportedChain = 'base-sepolia' | 'base';

// Configuration
export interface W3cashConfig {
  /** Chain to connect to */
  chain: SupportedChain;
  /** RPC URL (optional, uses public RPC if not provided) */
  rpcUrl?: string;
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
