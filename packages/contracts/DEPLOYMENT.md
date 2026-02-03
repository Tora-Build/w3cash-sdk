# Contract Deployment Guide

This guide covers deploying w3cash contracts to Base Sepolia testnet.

## Prerequisites

1. **Foundry installed**: https://book.getfoundry.sh/getting-started/installation
2. **Base Sepolia ETH**: Get testnet ETH from https://www.alchemy.com/faucets/base-sepolia
3. **Environment variables**: Copy `.env.example` to `.env` and fill in values

## Environment Setup

```bash
cd packages/contracts
cp .env.example .env
```

Edit `.env`:
```
PRIVATE_KEY=your_deployer_private_key_without_0x
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
BASESCAN_API_KEY=your_api_key_for_verification
```

## Deployment Commands

### Full Deployment

Deploy all contracts (Processor, Factory, Paymaster, AaveAdapter):

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base_sepolia \
  --broadcast \
  --verify
```

### Individual Scripts

**Deploy Paymaster Only:**
```bash
forge script script/Deploy.s.sol:DeployPaymasterOnly \
  --rpc-url base_sepolia \
  --broadcast \
  --verify
```

**Fund Paymaster:**
```bash
export PAYMASTER_ADDRESS=0x...  # From deployment output
forge script script/Deploy.s.sol:FundPaymaster \
  --rpc-url base_sepolia \
  --broadcast \
  --value 0.1ether
```

**Grant Sponsorship:**
```bash
export PAYMASTER_ADDRESS=0x...
export USER_ACCOUNT=0x...
forge script script/Deploy.s.sol:GrantSponsorship \
  --rpc-url base_sepolia \
  --broadcast
```

## Post-Deployment Steps

1. **Fund the Paymaster**
   ```bash
   cast send $PAYMASTER_ADDRESS "deposit()" \
     --value 0.1ether \
     --rpc-url base_sepolia \
     --private-key $PRIVATE_KEY
   ```

2. **Update SDK Constants**

   Edit `packages/sdk/src/constants.ts` with deployed addresses:
   ```typescript
   export const CONTRACT_ADDRESSES: Record<SupportedChain, ContractAddresses> = {
     'base-sepolia': {
       processor: '0x...',        // Processor address
       accountFactory: '0x...',   // W3cashAccountFactory address
       paymaster: '0x...',        // W3cashPaymaster address
       entryPoint: '0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789',
     },
     // ...
   };
   ```

3. **Verify Contracts** (if not done automatically)
   ```bash
   forge verify-contract $PROCESSOR_ADDRESS Processor \
     --chain base-sepolia \
     --watch
   ```

## Contract Addresses

### Base Sepolia External Dependencies

| Contract | Address |
|----------|---------|
| EntryPoint v0.6 | `0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789` |
| Aave V3 Pool | `0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b` |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

### Deployed w3cash Contracts

Update this section after deployment:

| Contract | Address |
|----------|---------|
| Processor | `0xd49E346d5086127A48Cf188DCD88Fe6CA7835E93` |
| W3cashAccountFactory | `0xA83654A132A0620e3cC418Cc4a63d3185e7cFAF7` |
| W3cashPaymaster | `0x1B9cE4e00898c8a276df7325C0298f4E15de1E9D` |
| AaveAdapter | `0xF8AEC865656f74C019c67a717cc6F51439fc5e57` |

## Dry Run (Simulation)

Test deployment without broadcasting:

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base_sepolia \
  -vvvv
```

## Gas Estimates

Approximate deployment costs (at 0.01 gwei gas price):

| Contract | Gas Used | Cost (ETH) |
|----------|----------|------------|
| Processor | ~800,000 | ~0.000008 |
| W3cashAccountFactory | ~1,200,000 | ~0.000012 |
| W3cashPaymaster | ~900,000 | ~0.000009 |
| AaveAdapter | ~600,000 | ~0.000006 |
| **Total** | ~3,500,000 | ~0.000035 |

## Troubleshooting

### "Insufficient funds"
Get more testnet ETH from the faucet.

### "Contract verification failed"
- Ensure BASESCAN_API_KEY is set
- Try manual verification with `forge verify-contract`

### "Nonce too low"
Wait for pending transactions or manually increment nonce:
```bash
forge script ... --nonce <next_nonce>
```
