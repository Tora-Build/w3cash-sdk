import { baseSepolia, base } from 'viem/chains';

// Supported chains
export const CHAINS = {
  'base-sepolia': baseSepolia,
  'base': base,
} as const;

// Contract addresses
export const CONTRACTS = {
  'base-sepolia': {
    core: '0x82c2B342757A9DfD7e4C4F750521df72C86E4dDD' as const,
    flows: {
      x402: '0x799224988457e60F8436b3a46f604070940F495C' as const,
      yield: '0x026Ce3Aed0199b7Ed053287B49066815A519891C' as const,
      swap: '0x1ba08495bd89e82043b439d72de49b42603282f1' as const,
      scheduled: '0xD393C92Bc53D936D8eD802896f872f4a007EEc98' as const,
      dca: '0x7fCC5416b10b3f01920C9AB974e9C4116e4dc6ae' as const,
    },
  },
  'base': {
    core: '0x0000000000000000000000000000000000000000' as const, // Not deployed yet
    flows: {
      x402: '0x0000000000000000000000000000000000000000' as const,
      yield: '0x0000000000000000000000000000000000000000' as const,
      swap: '0x0000000000000000000000000000000000000000' as const,
      scheduled: '0x0000000000000000000000000000000000000000' as const,
      dca: '0x0000000000000000000000000000000000000000' as const,
    },
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

export const X402_ABI = [
  {
    type: 'function',
    name: 'pay',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'token', type: 'address' },
      { name: 'resourceId', type: 'bytes32' },
    ],
    outputs: [{ name: 'paymentId', type: 'bytes32' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'payEth',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'resourceId', type: 'bytes32' },
    ],
    outputs: [{ name: 'paymentId', type: 'bytes32' }],
    stateMutability: 'payable',
  },
  {
    type: 'function',
    name: 'verify',
    inputs: [{ name: 'paymentId', type: 'bytes32' }],
    outputs: [
      { name: 'exists', type: 'bool' },
      {
        name: 'receipt',
        type: 'tuple',
        components: [
          { name: 'from', type: 'address' },
          { name: 'to', type: 'address' },
          { name: 'token', type: 'address' },
          { name: 'amount', type: 'uint256' },
          { name: 'resourceId', type: 'bytes32' },
          { name: 'timestamp', type: 'uint256' },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'event',
    name: 'Payment',
    inputs: [
      { name: 'paymentId', type: 'bytes32', indexed: true },
      { name: 'from', type: 'address', indexed: true },
      { name: 'to', type: 'address', indexed: true },
      { name: 'token', type: 'address', indexed: false },
      { name: 'amount', type: 'uint256', indexed: false },
      { name: 'resourceId', type: 'bytes32', indexed: false },
    ],
  },
] as const;

export const YIELD_ABI = [
  {
    type: 'function',
    name: 'deposit',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [
      { name: 'success', type: 'bool' },
      { name: 'deposited', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'withdraw',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [
      { name: 'success', type: 'bool' },
      { name: 'withdrawn', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'withdrawAll',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [
      { name: 'success', type: 'bool' },
      { name: 'withdrawn', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'balance',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'account', type: 'address' },
    ],
    outputs: [{ name: 'balance', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'event',
    name: 'Deposited',
    inputs: [
      { name: 'caller', type: 'address', indexed: true },
      { name: 'token', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'Withdrawn',
    inputs: [
      { name: 'caller', type: 'address', indexed: true },
      { name: 'token', type: 'address', indexed: true },
      { name: 'amount', type: 'uint256', indexed: false },
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
