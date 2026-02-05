# W3Cash Skill

On-chain automation for AI agents. Build intents with actions + conditions, sign once, execute later.

## Quick Start

```typescript
import { W3cash, ADAPTERS } from 'w3cash';

const w3 = new W3cash({ chain: 'base-sepolia' });
w3.connect(walletAccount);

// Build intent
const intent = w3.intent()
  .transfer({ token: USDC, to: recipient, amount: 100n * 10n**6n })
  .afterTime(Math.floor(Date.now() / 1000) + 3600)
  .build(ADAPTERS['base-sepolia']);

// Sign and execute
const signed = await w3.sign(intent);
await w3.execute(signed);
```

## Actions (What to Do)

### Transfer (ID: 3)
Send ERC20 tokens to an address.
```typescript
.transfer({ token: '0x...', to: '0x...', amount: BigInt })
```

### Swap (ID: 5)
Exchange tokens via Uniswap V3.
```typescript
.swap({ 
  tokenIn: USDC, tokenOut: WETH, 
  amountIn: 100n * 10n**6n,
  minAmountOut: 0n, slippageBps: 50 
})
```

### Yield - Aave (ID: 2)
Deposit or withdraw from Aave V3.
```typescript
.yield({ protocol: 'aave', action: 'deposit', token: USDC, amount: 1000n * 10n**6n })
.yield({ protocol: 'aave', action: 'withdraw', token: USDC, amount: 500n * 10n**6n })
.yield({ protocol: 'aave', action: 'withdrawAll', token: USDC })
```

### Borrow (ID: 8)
Borrow from Aave V3 (requires collateral).
```typescript
.borrow({ asset: USDC, amount: 1000n * 10n**6n, rateMode: 2 }) // 2 = variable rate
```

### Repay (ID: 9)
Repay Aave V3 loans.
```typescript
.repay({ asset: USDC, amount: 500n * 10n**6n, rateMode: 2 })
.repay({ asset: USDC, amount: MaxUint256, rateMode: 2 }) // repay all
```

### Approve (ID: 4)
Set ERC20 allowance.
```typescript
.approve({ token: USDC, spender: '0x...', amount: MaxUint256 })
```

### Wrap (ID: 6)
Convert ETH to WETH.
```typescript
.wrap({ amount: 1n * 10n**18n })
```

### Unwrap (ID: 16)
Convert WETH to ETH.
```typescript
.unwrap({ amount: 1n * 10n**18n })
.unwrap({ amount: MaxUint256 }) // unwrap all
```

### Bridge (ID: 7)
Cross-chain transfer via Across.
```typescript
.bridge({ token: USDC, amount: 1000n * 10n**6n, destChain: 42161 })
```

### Vote (ID: 11)
Cast vote on governance proposals.
```typescript
.vote({ governor: GOVERNOR, proposalId: 42, support: 1, reason: 'Supporting growth' })
// support: 0 = Against, 1 = For, 2 = Abstain
```

### Delegate (ID: 10)
Delegate voting power.
```typescript
.delegate({ token: GOV_TOKEN, delegatee: '0x...' })
```

### Claim (ID: 12)
Claim rewards from protocols.
```typescript
.claim({ protocol: 'aave', assets: [aUSDC, aWETH] })
.claim({ protocol: 'generic', target: REWARDS_CONTRACT, callData: '0x...' })
```

### Burn (ID: 13)
Burn ERC20 tokens.
```typescript
.burn({ token: TOKEN, amount: 100n * 10n**18n, method: 2 }) // 2 = transfer to dead address
```

### Mint (ID: 14)
Mint NFTs.
```typescript
.mint({ nftContract: NFT, method: 0, mintPrice: 0.01n * 10n**18n })
```

### Lock (ID: 15)
Time-lock tokens.
```typescript
.lock({ token: TOKEN, amount: 1000n * 10n**18n, unlockTime: timestamp })
.unlock({ lockId: 0 })
```

### FlashLoan (ID: 17)
Execute Aave flash loans.
```typescript
.flashLoan({ asset: USDC, amount: 1000000n * 10n**6n, operations: '0x...' })
```

### AddLiquidity (ID: 18)
Add liquidity to Uniswap V3.
```typescript
.addLiquidity({
  token0: WETH, token1: USDC, fee: 3000,
  tickLower: -887220, tickUpper: 887220,
  amount0: 1n * 10n**18n, amount1: 3000n * 10n**6n,
  amount0Min: 0, amount1Min: 0
})
```

### RemoveLiquidity (ID: 19)
Remove liquidity from Uniswap V3.
```typescript
.removeLiquidity({ tokenId: 12345, amount0Min: 0, amount1Min: 0 })
.closeLiquidity({ tokenId: 12345 }) // remove all + burn NFT
```

## Conditions (When to Do It)

### Time-Based (ID: 0)
Wait until a specific timestamp or block.
```typescript
.afterTime(unixTimestamp)
.afterBlock(blockNumber)
```

### Query-Based (ID: 1)
Wait until any on-chain state matches a condition.
```typescript
.when(contractAddress, encodedCalldata, '>=', expectedValue)
```

### Balance (ID: 100)
Wait until token balance meets threshold.
```typescript
.whenBalance(USDC, myAddress, '>=', 1000n * 10n**6n)
.whenBalance(address(0), myAddress, '>=', 1n * 10n**18n) // ETH balance
```

### Allowance (ID: 101)
Wait until allowance is sufficient.
```typescript
.whenAllowance(USDC, myAddress, spender, '>=', 1000n * 10n**6n)
```

### Price (ID: 102)
Wait until Chainlink price meets condition.
```typescript
.whenPrice(CHAINLINK_ETH_USD, '>=', 3000n * 10n**8n)
.whenPrice(CHAINLINK_ETH_USD, '<', 2500n * 10n**8n)
```

### Health Factor (ID: 103)
Wait until Aave health factor meets condition.
```typescript
.whenHealthFactor(myAddress, '<', 12n * 10n**17n) // < 1.2
.whenHealthFactor(myAddress, '>', 15n * 10n**17n) // > 1.5
```

**Operators:** `<`, `>`, `<=`, `>=`, `==`, `!=`

## Cancellation

Cancel all pending intents by incrementing your nonce:
```typescript
await w3.cancel();
```

## Deployed Contracts (Base Sepolia)

| Contract | Address |
|----------|---------|
| Processor | `0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE` |
| Registry | `0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82` |

### Adapters - Conditions

| ID | Name | Address |
|----|------|---------|
| 0 | Wait | `0x8448b5f4abD40830C3B980390AbcfD2822719061` |
| 1 | Query | `0x4bC2F784CC76989dA6760Bc6bFCDc3F75c49ee9F` |
| 100 | Balance | `0x78f84ea305d41D97C540B55651A5A0CA01bF61De` |
| 101 | Allowance | `0xF6795de6609178D61d383EdF1E366aEF267d6264` |
| 102 | Price | `0xa28C0E516d624D82aBd75D6B84eC08A3be5c31d1` |
| 103 | HealthFactor | `0x7Cc8c3A3Beb0695fFFB0577a7DCd618f9aA4Eb17` |
| 104 | Signature | `0xEEe61780cC5fC62B7017E46BB7f6b27fD8BAfBEe` |
| 105 | GasPrice | `0x07DcD715DdAB18D449b10BB6140916e8a0F7f657` |
| 106 | TimeRange | `0xCC18E7E2283D3067B30D0e9a3Ba189FE25dB62EB` |

### Adapters - Actions

| ID | Name | Address |
|----|------|---------|
| 2 | Aave | `0xC330e841A259E8211D1Ea84c60efD8657DB1D546` |
| 3 | Transfer | `0x6cA85B548d3512E355B63Fb390dBD197CF72d5eA` |
| 4 | Approve | `0x1ff4459D35E956BA999ECf80C20Ad559904398A0` |
| 5 | Swap | `0x9952735758c18d00D3cf2D1D0985A93b265a2126` |
| 6 | Wrap | `0xD9142Ae0fCf4Fe81b39cD196BC37C9675DC86516` |
| 7 | Bridge | `0x3502362cAB171ffF2bF094fC70FD5977c9AD7090` |
| 8 | Borrow | `0x41C8a0D5d593b325B6BD719b5Aa15f14e0C63831` |
| 9 | Repay | `0xcC0fe131416B103eB0b65AdAd7520815A8b717C0` |
| 10 | Delegate | `0xF7a73D1dA4ea2A086a086ba3b0790870953593CF` |
| 11 | Vote | `0xEEe61780cC5fC62B7017E46BB7f6b27fD8BAfBEe` |
| 12 | Claim | `0x07DcD715DdAB18D449b10BB6140916e8a0F7f657` |
| 13 | Burn | `0xCC18E7E2283D3067B30D0e9a3Ba189FE25dB62EB` |
| 14 | Mint | `0xe5f035835d6408C99083C6Bd008D56F2D3b8E817` |
| 15 | Lock | `0xe98CCf8c1f705c9a56144896F15164c6fA62D4F3` |
| 16 | Unwrap | `0xce2BAB18097fC2981c75c58075DB2BDCaace1108` |
| 17 | FlashLoan | `0xd1c3D5660048f8A677eFD8A8183CBa9012B0558b` |
| 18 | AddLiquidity | `0x863e4329dfBd3e4b4F781601aAe22A7E6BFeDc84` |
| 19 | RemoveLiquidity | `0x1B8d413aD9c3f8ee20a837481a205107d33bEf62` |
| 20 | Liquidate | `0x41C8a0D5d593b325B6BD719b5Aa15f14e0C63831` |
| 22 | Batch | `0xcC0fe131416B103eB0b65AdAd7520815A8b717C0` |
| 23 | Stake | `0xF7a73D1dA4ea2A086a086ba3b0790870953593CF` |

## Example Flows

### DCA (Dollar Cost Average)
```typescript
// Buy ETH every week for 4 weeks
for (let i = 0; i < 4; i++) {
  const intent = w3.intent()
    .swap({ tokenIn: USDC, tokenOut: WETH, amountIn: 25n * 10n**6n })
    .afterTime(now + (i * 7 * 24 * 60 * 60))
    .build(adapters);
  await w3.sign(intent);
}
```

### Leveraged Long
```typescript
// 2x leverage long ETH when price dips
const intent = w3.intent()
  .yield({ protocol: 'aave', action: 'deposit', token: WETH, amount: 1n * 10n**18n })
  .borrow({ asset: USDC, amount: 2000n * 10n**6n, rateMode: 2 })
  .swap({ tokenIn: USDC, tokenOut: WETH, amountIn: 2000n * 10n**6n })
  .whenPrice(CHAINLINK_ETH_USD, '<', 2800n * 10n**8n)
  .build(adapters);
```

### Emergency Exit
```typescript
// Deleverage when health factor drops
const intent = w3.intent()
  .repay({ asset: USDC, amount: MaxUint256, rateMode: 2 })
  .yield({ protocol: 'aave', action: 'withdrawAll', token: WETH })
  .whenHealthFactor(myAddress, '<', 12n * 10n**17n)
  .build(adapters);
```

### Auto-Compound
```typescript
// Weekly claim and re-deposit
const intent = w3.intent()
  .claim({ protocol: 'aave', assets: [aUSDC] })
  .swap({ tokenIn: AAVE, tokenOut: USDC, amountIn: MaxUint256 })
  .yield({ protocol: 'aave', action: 'deposit', token: USDC, amount: MaxUint256 })
  .afterTime(now + 7 * 24 * 60 * 60)
  .build(adapters);
```

### Governance Auto-Vote
```typescript
// Vote on proposal before deadline
const intent = w3.intent()
  .vote({ governor: GOVERNOR, proposalId: 42, support: 1, reason: 'AI agent' })
  .afterTime(voteDeadline - 3600)
  .build(adapters);
```

## Tips

1. **Always set slippage** for swaps to prevent sandwich attacks
2. **Use price conditions** for price-based triggers (Chainlink)
3. **Batch approvals** with actions to save gas
4. **Cancel old intents** if you change your mind
5. **Monitor health factor** when using leverage

## Coming Soon (50 Total Adapters)

### DeFi Protocols
- **Aerodrome** - Base native DEX (ve(3,3) model)
- **Moonwell** - Base native lending (Compound fork)
- **Compound** - Compound V3 (Comet)
- **Morpho** - Morpho Blue lending
- **Spark** - MakerDAO's Aave fork
- **Balancer** - Weighted pool swaps
- **Curve** - Stable pool swaps

### Yield & Staking
- **Yearn** - V3 vaults (ERC-4626)
- **SDAI** - MakerDAO DSR (Savings DAI)
- **Frax** - sFRAX, sfrxETH, FraxLend
- **Convex** - Curve gauge staking + CVX locking
- **Pendle** - Yield tokenization (PT/YT)
- **EigenLayer** - Restaking protocol

### Perps & Trading
- **GMX** - V1 perpetuals + GLP
- **Synthetix** - V3 perps & spot
- **LimitOrder** - Limit orders via 0x/CoW

### NFT & Misc
- **Seaport** - OpenSea/NFT marketplace
- **ENS** - Domain registration
- **GnosisSafe** - Multisig operations
- **OptimismBridge** - Native L1↔L2 bridge

## Resources

- SDK: `npm install w3cash`
- Docs: https://w3.cash
- GitHub: https://github.com/Tora-Build/w3cash
- Contracts: Base Sepolia (testnet)
