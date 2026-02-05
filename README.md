# W3Cash SDK

On-chain automation for AI agents. Build intents with actions + conditions, sign once, execute later.

## Quick Start

```bash
npm install w3cash
```

```typescript
import { W3cash, ADAPTERS } from 'w3cash';

const w3 = new W3cash({ chain: 'base-sepolia' });
w3.connect(walletAccount);

// Build intent: transfer USDC when balance is sufficient
const intent = w3.intent()
  .transfer({ token: USDC, to: recipient, amount: 100n * 10n**6n })
  .whenBalance(USDC, myAddress, '>=', 100n * 10n**6n)
  .build(ADAPTERS['base-sepolia']);

// Sign and execute
const signed = await w3.sign(intent);
await w3.execute(signed);
```

## What is W3Cash?

W3Cash is an on-chain automation layer. Agent expresses need → W3Cash provides solution.

- **Actions** — What to do (swap, transfer, yield, bridge, stake, vote...)
- **Conditions** — When to do it (time, price, balance, health factor...)
- **Intents** — Actions + Conditions, signed once, executed when ready

## Deployed Contracts (Base Sepolia)

| Contract | Address |
|----------|---------|
| W3CashProcessor | `0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE` |
| AdapterRegistry | `0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82` |

### Adapters (50 total, 30 deployed)

**Conditions:** Wait, Query, Balance, Allowance, Price, HealthFactor, Signature, GasPrice, TimeRange

**Actions:** Aave, Transfer, Approve, Swap, Wrap, Bridge, Borrow, Repay, Delegate, Vote, Claim, Burn, Mint, Lock, Unwrap, FlashLoan, AddLiquidity, RemoveLiquidity, Liquidate, Batch, Stake + 20 more ready to deploy

## Repository Structure

```
w3cash-sdk/
├── packages/
│   ├── contracts/     # Solidity contracts (Foundry)
│   │   └── src/w3cash/
│   │       ├── W3CashProcessor.sol
│   │       ├── AdapterRegistry.sol
│   │       └── adapters/        # 50 adapter contracts
│   └── sdk/           # TypeScript SDK
│       └── src/
│           ├── W3cash.ts
│           └── intent/          # Intent builder
├── skills/
│   └── w3cash/
│       └── SKILL.md   # AI agent skill reference
└── docs/
    └── WHITEPAPER_V4.md
```

## For AI Agents

See [`skills/w3cash/SKILL.md`](skills/w3cash/SKILL.md) for the complete agent reference.

## Use Cases

- **DCA** — Buy tokens at regular intervals
- **Stop Loss** — Sell when price drops below threshold
- **Conditional Yield** — Deposit when balance reaches threshold
- **Scheduled Payments** — Pay rent on the 1st of each month
- **Auto-Compound** — Claim rewards and reinvest
- **Emergency Exit** — Withdraw if health factor drops

## Links

- **Website:** https://w3.cash
- **Docs:** https://w3.cash/#/docs
- **Skill:** https://w3.cash/#/skill
- **GitHub:** https://github.com/Tora-Build/w3cash-sdk

## License

MIT
