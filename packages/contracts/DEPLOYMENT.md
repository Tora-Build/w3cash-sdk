# Contract Deployment Guide

This guide covers deploying w3cash contracts to Base Sepolia testnet.

## Architecture Overview

The W3Cash system uses **Option 4: Immutable Processor + Upgradeable Registry**:

| Component | Trust Model | Upgrade Path |
|-----------|-------------|--------------|
| W3CashProcessor | **Trustless** | None (immutable) |
| AdapterRegistry | Admin-controlled | Can add new adapters |
| Individual Adapters | **Trustless after freeze** | None once frozen |

**Key Benefits:**
- Core execution logic is immutable (no admin functions)
- Adapters can be frozen for permanent immutability
- New adapter IDs can still be added without touching processor
- Gradual decentralization (owner → multisig → DAO)

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

### W3Cash Deployment (Recommended)

Deploy the W3Cash architecture (AdapterRegistry + Adapters + W3CashProcessor):

```bash
forge script script/DeployPoca.s.sol:DeployPoca \
  --rpc-url base_sepolia \
  --broadcast \
  --verify
```

This deploys (in order):
1. **AdapterRegistry** - Owned by deployer, manages adapter registration
2. **W3CashProcessor** - Immutable processor with registry reference
3. **WaitAdapter** - Time/block/price conditions (requires processor address)
4. **AaveAdapter** - Aave V3 lending operations (requires processor address)

> **Note:** Adapters require the processor address in their constructor due to the `onlyProcessor` guard. This prevents direct calls that bypass signature verification.

### Freeze Adapters (Production)

After testing, freeze production adapters for immutability:

```bash
export ADAPTER_REGISTRY=0x...  # From deployment output
forge script script/DeployPoca.s.sol:FreezeAdapters \
  --rpc-url base_sepolia \
  --broadcast
```

### Add New Adapter

Add a new adapter to an existing registry:

```bash
export ADAPTER_REGISTRY=0x...
export ADAPTER_ID=5
export ADAPTER_ADDRESS=0x...
forge script script/DeployPoca.s.sol:AddAdapter \
  --rpc-url base_sepolia \
  --broadcast
```

### Full Deployment (Legacy)

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

### W3Cash Lifecycle

1. **Bootstrap** - Deploy registry and adapters
2. **Test** - Run on testnet, verify everything works
3. **Freeze** - Call `freezeAdapter(id)` for each production adapter
4. **Decentralize** - Transfer registry ownership to multisig/DAO

### After W3Cash Deployment

1. **Verify Deployment**
   ```bash
   # Check registry owner
   cast call $ADAPTER_REGISTRY "owner()" --rpc-url base_sepolia

   # Check adapter is registered
   cast call $ADAPTER_REGISTRY "isAdapterRegistered(uint8)" 0 --rpc-url base_sepolia

   # Check processor registry reference
   cast call $W3Cash_PROCESSOR "registry()" --rpc-url base_sepolia
   ```

2. **Test Adapters**
   ```bash
   # Get fee estimate
   cast call $W3Cash_PROCESSOR "estimateFee(uint8,uint8,uint112,uint256)" 0 0 1000000000000000000 100000 --rpc-url base_sepolia
   ```

3. **Freeze Production Adapters** (when ready)
   ```bash
   cast send $ADAPTER_REGISTRY "freezeAdapter(uint8)" 0 \
     --rpc-url base_sepolia \
     --private-key $PRIVATE_KEY
   ```

4. **Transfer Ownership** (optional, for decentralization)
   ```bash
   cast send $ADAPTER_REGISTRY "transferOwnership(address)" $MULTISIG_ADDRESS \
     --rpc-url base_sepolia \
     --private-key $PRIVATE_KEY
   ```

### Legacy Steps

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

**W3Cash v4 Architecture (Base Sepolia):**

| Contract | Address | Trust Model |
|----------|---------|-------------|
| AdapterRegistry | `0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82` | Admin until frozen |
| W3CashProcessor | `0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE` | **Immutable** |
| WaitAdapter (ID: 0) | `0x8448b5f4abD40830C3B980390AbcfD2822719061` | Trustless after freeze |
| QueryAdapter (ID: 1) | `0x4bC2F784CC76989dA6760Bc6bFCDc3F75c49ee9F` | Trustless after freeze |
| AaveAdapter (ID: 2) | `0xC330e841A259E8211D1Ea84c60efD8657DB1D546` | Trustless after freeze |
| TransferAdapter (ID: 3) | `0x6cA85B548d3512E355B63Fb390dBD197CF72d5eA` | Trustless after freeze |
| ApproveAdapter (ID: 4) | `0x1ff4459D35E956BA999ECf80C20Ad559904398A0` | Trustless after freeze |
| SwapAdapter (ID: 5) | `0x9952735758c18d00D3cf2D1D0985A93b265a2126` | Trustless after freeze |
| WrapAdapter (ID: 6) | `0xD9142Ae0fCf4Fe81b39cD196BC37C9675DC86516` | Trustless after freeze |
| BridgeAdapter (ID: 7) | `0x3502362cAB171ffF2bF094fC70FD5977c9AD7090` | Trustless after freeze |

**Legacy Contracts:**

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
