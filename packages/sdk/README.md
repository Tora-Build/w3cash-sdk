# w3cash SDK

**Pick flows. Gain on-chain economy.**

TypeScript SDK for w3cash flow infrastructure.

## Installation

```bash
npm install w3cash
```

## Quick Start

```typescript
import { W3cash } from 'w3cash';
import { privateKeyToAccount } from 'viem/accounts';

// Initialize
const w3 = new W3cash({ chain: 'base-sepolia' });

// Connect wallet
w3.connect(privateKeyToAccount('0x...'));

// Get a flow
const x402 = w3.flow('x402');

// Use it
await x402.pay({
  to: '0x...',
  amount: parseUnits('10', 6),
  token: USDC,
  resourceId: X402Flow.resourceId('/api/endpoint'),
});
```

## Flows

### x402Flow - HTTP Payments

```typescript
const x402 = w3.flow('x402');

// Pay with ERC20
await x402.pay({
  to: recipient,
  amount: parseUnits('10', 6),
  token: USDC_ADDRESS,
  resourceId: X402Flow.resourceId('/api/premium'),
});

// Pay with ETH
await x402.payEth({
  to: recipient,
  resourceId: X402Flow.resourceId('/api/premium'),
  value: parseEther('0.01'),
});

// Verify payment
const { exists, receipt } = await x402.verify(paymentId);
```

### YieldFlow - Aave Deposits

```typescript
const yld = w3.flow('yield');

// Deposit
await yld.deposit(USDC_ADDRESS, parseUnits('1000', 6));

// Check balance
const balance = await yld.balance(USDC_ADDRESS, myAddress);

// Withdraw
await yld.withdraw(USDC_ADDRESS, parseUnits('500', 6));

// Withdraw all
await yld.withdrawAll(USDC_ADDRESS);
```

### SwapFlow - Uniswap Swaps

```typescript
const swap = w3.flow('swap');

// Swap exact input
await swap.swapExactIn(
  WETH_ADDRESS,     // tokenIn
  USDC_ADDRESS,     // tokenOut
  3000,             // fee (0.3%)
  parseEther('1'),  // amountIn
  parseUnits('3000', 6), // minAmountOut
);
```

## Configuration

```typescript
const w3 = new W3cash({
  chain: 'base-sepolia', // or 'base'
  rpcUrl: 'https://...', // optional custom RPC
});
```

## Connecting Wallets

### Private Key

```typescript
import { privateKeyToAccount } from 'viem/accounts';

w3.connect(privateKeyToAccount('0x...'));
```

### Browser Wallet

```typescript
w3.connectBrowser(window.ethereum);
```

## Custom Flow Addresses

```typescript
// Use flow at custom address
const customX402 = w3.flowAt('x402', '0x...');
```

## Contract Addresses

### Base Sepolia

| Contract | Address |
|----------|---------|
| W3CashCore | `0x82c2B342757A9DfD7e4C4F750521df72C86E4dDD` |
| x402Flow | `0x799224988457e60F8436b3a46f604070940F495C` |
| YieldFlow | `0x026Ce3Aed0199b7Ed053287B49066815A519891C` |
| SwapFlow | `0x1ba08495bd89e82043b439d72de49b42603282f1` |

## Types

```typescript
import type {
  W3cashConfig,
  SupportedChain,
  FlowName,
  PaymentReceipt,
} from 'w3cash';
```

## ABIs

```typescript
import {
  CORE_ABI,
  X402_ABI,
  YIELD_ABI,
  ERC20_ABI,
} from 'w3cash';
```

## Requirements

- Node.js 18+
- viem ^2.21.0

## License

MIT
