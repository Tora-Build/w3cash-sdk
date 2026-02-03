# POCA - Protocol Oriented Chain Abstraction

Standalone module for resumable, conditional, and cross-chain workflows.

## Overview

POCA enables workflows that can:
- **Pause and resume** based on time, block, or price conditions
- **Execute cross-chain** via multiple AMB adapters
- **Verify signatures** for authorized execution

## Structure

```
poca/
├── Processor.sol          # Simple adapter-based processor
├── PocaProcessor.sol      # Full POCA with SignedPayload + cross-chain
├── adapters/
│   ├── WaitAdapter.sol    # Time/block/price conditions
│   ├── AaveAdapter.sol    # Aave V3 integration
│   └── interfaces/
│       └── IAdapter.sol   # Adapter interface
├── interfaces/
│   └── IProcessor.sol     # Processor interface
└── utils/
    ├── DataTypes.sol      # Shared types (PAUSE_EXECUTION, SignedPayload)
    └── Errors.sol         # Shared errors
```

## Key Concepts

### PAUSE_EXECUTION

When a condition isn't met, adapters return `PAUSE_EXECUTION`:

```solidity
if (block.timestamp < targetTime) {
    return abi.encode(DataTypes.PAUSE_EXECUTION);
}
```

The Processor:
1. Saves the current sequence number
2. Emits `WorkflowPaused`
3. Returns successfully (no revert)

Later, anyone can re-trigger the workflow to continue.

### SignedPayload

Users sign workflow logic once. Execution can happen later:

```solidity
struct SignedPayload {
    bytes instruction;    // Encoded workflow
    address initiator;    // Who authorized this
    bytes signature;      // ECDSA signature
}
```

### WaitAdapter Conditions

| Type | Description |
|------|-------------|
| `TIMESTAMP` | Wait until `block.timestamp >= value` |
| `BLOCK` | Wait until `block.number >= value` |
| `PRICE_GTE` | Wait until Chainlink price >= target |
| `PRICE_LTE` | Wait until Chainlink price <= target |

## Usage

### Simple Processor

```solidity
Processor processor = new Processor(owner);
processor.registerAdapter(waitAdapterAddress);

// Execute: [adapterId (4 bytes)][data]
bytes memory instruction = abi.encodePacked(
    WaitAdapter.ADAPTER_ID,
    abi.encode(WaitParams({
        condition: WaitType.TIMESTAMP,
        value: block.timestamp + 1 hours,
        feed: address(0),
        targetPrice: 0
    }))
);

processor.execute(instruction);
// → Returns PAUSE_EXECUTION bytes, emits WorkflowPaused
```

### PocaProcessor (Full)

```solidity
// 1. Build workflow
bytes memory payload = buildPayload(commands, inputs);
bytes32 payloadHash = keccak256(payload);

// 2. Sign payload
bytes memory signature = sign(payloadHash, privateKey);

// 3. Execute
SignedPayload memory sp = SignedPayload({
    instruction: encodeInstruction(header, payload),
    initiator: signer,
    signature: signature
});

pocaProcessor.execute(abi.encode(sp));
```

## Deployed (Base Sepolia)

| Contract | Address |
|----------|---------|
| POCA Processor | `0x908fc6777a0ef98d83684aacb8aa0668cedc5ff9` |
| WaitAdapter | `0xa7a6836e3d08b3c3bb63b877822c08f01ab70bae` |
| AaveAdapter | `0x7B3489a60eEA93141A5b8D63640286755E4F730B` |

## Integration with Flows

POCA-powered flows (ScheduledFlow, DCAFlow) import from this module:

```solidity
import { DataTypes } from "../poca/utils/DataTypes.sol";

// Use PAUSE_EXECUTION pattern
if (!conditionMet) {
    return abi.encode(DataTypes.PAUSE_EXECUTION);
}
```

## References

- [POCA Whitepaper](../../docs/POCA/POCA-whitepaper.md)
- [POCA Architecture](../../docs/POCA_ARCHITECTURE.md)
- [POCA + Flows Integration](../../docs/POCA_FLOWS_INTEGRATION.md)
