# w3cash

**Economic workflows for autonomous agents.**

Agents need more than wallets. w3cash gives agents yield, DCA, scheduled transfers, and conditional execution.

## Installation

```bash
npm install w3cash
```

## Quick Start

```typescript
import { W3cash } from 'w3cash';

const w3 = new W3cash({ chain: 'base-sepolia' });
await w3.connect(agentWallet);

// Earn yield on idle funds
await w3.flow('yield').deposit(USDC, amount);

// Set up weekly DCA
await w3.flow('dca').createDCA({
  tokenIn: USDC,
  tokenOut: WETH,
  amountPerInterval: parseUnits('100', 6),
  interval: 7n * 24n * 60n * 60n,
  totalExecutions: 52n,
});

// Schedule a transfer
await w3.flow('scheduled').createTimeSchedule({
  token: USDC,
  recipient: '0x...',
  amount: parseUnits('1000', 6),
  executeAt: BigInt(Date.parse('2026-03-01') / 1000),
});
```

## Flows

| Flow | Type | Description |
|------|------|-------------|
| `yield` | Instant | Deposit to Aave V3, earn yield |
| `swap` | Instant | Token swaps via Uniswap V3 |
| `x402` | Instant | HTTP-native payments |
| `dca` | Workflow | Dollar-cost averaging |
| `scheduled` | Workflow | Time/price triggered transfers |

## Contracts (Base Sepolia)

| Contract | Address |
|----------|---------|
| W3CashCore | `0x82c2B342757A9DfD7e4C4F750521df72C86E4dDD` |
| YieldFlow | `0x026Ce3Aed0199b7Ed053287B49066815A519891C` |
| DCAFlow | `0x7fCC5416b10b3f01920C9AB974e9C4116e4dc6ae` |
| ScheduledFlow | `0xD393C92Bc53D936D8eD802896f872f4a007EEc98` |
| x402Flow | `0x799224988457e60F8436b3a46f604070940F495C` |
| SwapFlow | `0x1ba08495bd89e82043b439d72de49b42603282f1` |

## Documentation

- [SDK Documentation](./packages/sdk/README.md)
- [Contract Documentation](./packages/contracts/README.md)
- [Website](https://w3.cash)

## License

MIT
