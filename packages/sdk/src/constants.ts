import { baseSepolia, base } from 'viem/chains';

// Supported chains
export const CHAINS = {
  'base-sepolia': baseSepolia,
  'base': base,
} as const;

// Contract addresses - W3Cash v4
export const CONTRACTS = {
  'base-sepolia': {
    core: '0x82c2B342757A9DfD7e4C4F750521df72C86E4dDD' as const, // Legacy W3CashCore
    processor: '0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE' as const,
    registry: '0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82' as const,
  },
  'base': {
    core: '0x0000000000000000000000000000000000000000' as const,
    processor: '0x0000000000000000000000000000000000000000' as const,
    registry: '0x0000000000000000000000000000000000000000' as const,
  },
} as const;

// Adapter addresses - W3Cash v4 (Base Sepolia)
export const ADAPTERS = {
  'base-sepolia': {
    // Conditions
    wait: '0x8448b5f4abD40830C3B980390AbcfD2822719061' as const,     // ID: 0
    query: '0x4bC2F784CC76989dA6760Bc6bFCDc3F75c49ee9F' as const,    // ID: 1
    // Actions
    aave: '0xC330e841A259E8211D1Ea84c60efD8657DB1D546' as const,     // ID: 2
    transfer: '0x6cA85B548d3512E355B63Fb390dBD197CF72d5eA' as const, // ID: 3
    approve: '0x1ff4459D35E956BA999ECf80C20Ad559904398A0' as const,  // ID: 4
    swap: '0x9952735758c18d00D3cf2D1D0985A93b265a2126' as const,     // ID: 5
    wrap: '0xD9142Ae0fCf4Fe81b39cD196BC37C9675DC86516' as const,     // ID: 6
    bridge: '0x3502362cAB171ffF2bF094fC70FD5977c9AD7090' as const,   // ID: 7 (Across)
  },
  'base': {
    wait: '0x0000000000000000000000000000000000000000' as const,
    query: '0x0000000000000000000000000000000000000000' as const,
    aave: '0x0000000000000000000000000000000000000000' as const,
    transfer: '0x0000000000000000000000000000000000000000' as const,
    approve: '0x0000000000000000000000000000000000000000' as const,
    swap: '0x0000000000000000000000000000000000000000' as const,
    wrap: '0x0000000000000000000000000000000000000000' as const,
    bridge: '0x0000000000000000000000000000000000000000' as const,
  },
} as const;

// Known tokens
export const TOKENS = {
  'base-sepolia': {
    USDC: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' as const,
    WETH: '0x4200000000000000000000000000000000000006' as const,
  },
  'base': {
    USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as const,
    WETH: '0x4200000000000000000000000000000000000006' as const,
  },
} as const;

// ABIs
export const CORE_ABI = [
  {
    type: 'function',
    name: 'execute',
    inputs: [
      { name: 'flow', type: 'address' },
      { name: 'data', type: 'bytes' },
    ],
    outputs: [{ name: 'result', type: 'bytes' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'executeBatch',
    inputs: [
      { name: 'flows', type: 'address[]' },
      { name: 'datas', type: 'bytes[]' },
    ],
    outputs: [{ name: 'results', type: 'bytes[]' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'event',
    name: 'FlowExecuted',
    inputs: [
      { name: 'caller', type: 'address', indexed: true },
      { name: 'flow', type: 'address', indexed: true },
      { name: 'success', type: 'bool', indexed: false },
    ],
  },
] as const;

export const ERC20_ABI = [
  {
    type: 'function',
    name: 'approve',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'balanceOf',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'allowance',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
  },
] as const;
