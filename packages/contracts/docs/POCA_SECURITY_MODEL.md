# POCA Security Model

> Protocol Oriented Chain Abstraction - Trust Model & Security Architecture

## Overview

POCA is built on **user-signed payloads** that authorize multi-step, cross-chain workflows. Security comes from cryptographic authorization (signatures) combined with controlled infrastructure (registry).

## Core Principle

**The user's signature IS the authorization.**

When a user signs a payload containing adapter addresses, inputs, and values — they are explicitly authorizing those operations. The Processor verifies the signature and executes exactly what was signed.

## Trust Model

### Components

| Component | Mutability | Trust Assumption |
|-----------|------------|------------------|
| PocaProcessor | Immutable | Code is law — no admin, no upgrades |
| AdapterRegistry | Admin → Frozen | Trusted until frozen, then immutable |
| Adapters | Immutable | Locked to Processor via `onlyProcessor` guard |

### Execution Paths

```
                    USER SIGNS PAYLOAD
                           │
                           ▼
                   ┌───────────────┐
                   │ PocaProcessor │
                   │ (immutable)   │
                   └───────┬───────┘
                           │
           ┌───────────────┴───────────────┐
           │                               │
           ▼                               ▼
    LOCAL EXECUTION              CROSS-CHAIN EXECUTION
           │                               │
           │                               ▼
           │                      ┌────────────────┐
           │                      │AdapterRegistry │
           │                      │ • getAdapter() │
           │                      │ • getChain()   │
           │                      └────────┬───────┘
           │                               │
           ▼                               ▼
    ┌─────────────┐               ┌─────────────┐
    │   Adapter   │               │ AMB Adapter │
    │(user-signed)│               │ (registry)  │
    └─────────────┘               └─────────────┘
```

### Local vs Cross-Chain Trust

| Aspect | Local Execution | Cross-Chain Execution |
|--------|-----------------|----------------------|
| **Target adapter** | User-specified in payload | Registry lookup via `getAdapter(amb)` |
| **Who controls?** | User (via signature) | Registry owner (until frozen) |
| **Trust source** | User's explicit authorization | Registry configuration |
| **Rationale** | User signs address they trust | AMB bridges need curation |

**Why the difference?**

- **Local adapters**: User knows what they're signing. If they sign a payload with adapter address `0xABC`, they're saying "I trust 0xABC for this operation." No registry lookup needed.

- **Cross-chain adapters**: AMB (Arbitrary Message Bridge) selection is infrastructure-level. Users shouldn't need to know bridge contract addresses. Registry provides curated, frozen mappings.

## Security Guarantees

### 1. Signature Verification
- Every payload is signed by the initiator
- Processor verifies signature before execution
- Invalid signature → transaction reverts

### 2. Adapter Isolation (`onlyProcessor` Guard)
- Adapters ONLY accept calls from the Processor
- Prevents direct calls that bypass signature verification
- Enforces single entry point for all operations

```solidity
modifier onlyProcessor() {
    if (msg.sender != processor) revert CallerNotProcessor();
    _;
}
```

### 3. Registry Freeze Mechanism
- Adapters and chains can be **frozen** individually
- Once frozen, mapping is immutable forever
- Enables progressive decentralization:
  1. Deploy with admin control
  2. Verify correct configuration
  3. Freeze critical mappings
  4. Transfer ownership or renounce

### 4. Immutable Processor
- No `Ownable`, no admin functions
- Registry reference set once at deploy
- Only state: `authorizedEndpoints` (for receiving cross-chain messages)
- Endpoint auth controlled by registry owner (for operational flexibility)

## Attack Vectors & Mitigations

| Attack | Mitigation |
|--------|------------|
| Malicious adapter in payload | User signed it — their responsibility |
| Registry admin swaps adapter | Freeze adapter after verification |
| Direct adapter call | `onlyProcessor` guard reverts |
| Replay attack | Nonce/deadline in payload (application-level) |
| Cross-chain message spoofing | `authorizedEndpoints` allowlist |

## Configuration Safety

### Chain ID Zero Guard

`setChain` and `setChains` reject `chainId == 0` to prevent silent misconfiguration:

```solidity
function setChain(uint8 chain, uint256 chainId) external onlyOwner {
    if (_chainFrozen[chain]) revert ChainAlreadyFrozen();
    if (chainId == 0) revert InvalidChainId();
    _chains[chain] = chainId;
}
```

## Deployment Checklist

1. [ ] Deploy `AdapterRegistry` with trusted owner
2. [ ] Deploy `PocaProcessor` with registry address
3. [ ] Deploy adapters with processor address (`onlyProcessor` guard)
4. [ ] Register adapters in registry
5. [ ] Register chain mappings
6. [ ] Verify all configurations
7. [ ] Freeze production adapters and chains
8. [ ] (Optional) Transfer registry ownership to multisig/DAO

## Summary

| Question | Answer |
|----------|--------|
| Who authorizes operations? | User (via signature) |
| Who controls local adapter choice? | User (address in signed payload) |
| Who controls cross-chain routing? | Registry (until frozen) |
| Can adapters be called directly? | No (`onlyProcessor` guard) |
| Can frozen mappings change? | No (immutable) |
| Is Processor upgradeable? | No (immutable) |
