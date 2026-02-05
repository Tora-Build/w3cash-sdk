# W3Cash Whitepaper v4.1

**The On-Chain Automation Layer for AI Agents**

*Date: 2026-02-04*
*Status: Final Spec*

---

## Executive Summary

W3Cash is an on-chain automation layer that enables AI agents to express needs and have them executed without building solutions. Agents compose **actions** (what to do) with **conditions** (when to do it), sign once, and W3Cash handles the rest.

**Core principle:** Agent expresses need → W3Cash provides solution.

---

## 1. Problem

AI agents need to interact with on-chain protocols (swap, yield, bridge, etc.). Current options:

| Approach | Problem |
|----------|---------|
| Direct protocol calls | Agent must learn each protocol's API |
| AgentKit | No scheduling, no conditions, no batching |
| Gelato/Chainlink | Agent must set up keeper jobs (still building) |

**Gap:** No solution where agent just expresses intent and walks away.

---

## 2. Vision

**Agent says:** "DCA $100 into ETH every week for 12 weeks"

**Agent does:**
```typescript
const intent = w3.intent()
  .action('swap', { from: USDC, to: ETH, amount: 100e6 })
  .condition('interval', { every: '1 week', times: 12 })
  .build();

await w3.sign(intent);
// Done. Keepers will execute weekly.
```

**W3Cash handles:** Protocol interaction, scheduling, execution, error handling.

**Agent doesn't need to know:** Uniswap API, keeper setup, gas management, slippage.

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     AI Agent                            │
│                  (expresses need)                       │
└─────────────────────────┬───────────────────────────────┘
                          │ signs intent
                          ▼
┌─────────────────────────────────────────────────────────┐
│                   W3Cash Core                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Processor                           │   │
│  │  • Verifies signed payloads                     │   │
│  │  • Evaluates conditions (query + operators)     │   │
│  │  • Executes actions atomically                  │   │
│  │  • Handles cancel via nonces                    │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Registry                            │   │
│  │  • Registered actions (plugins)                 │   │
│  │  • Registered conditions (plugins)              │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────┬───────────────────────────────┘
                          │ calls
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    Plugins                              │
│  ┌──────────────────┐  ┌──────────────────┐            │
│  │     Actions      │  │    Conditions    │            │
│  │  • SwapAction    │  │  • TimeCondition │            │
│  │  • YieldAction   │  │  • QueryCondition│            │
│  │  • TransferAction│  │  (any view call) │            │
│  └──────────────────┘  └──────────────────┘            │
└─────────────────────────────────────────────────────────┘
```

---

## 4. Core Components

### 4.1 Processor

The execution engine. Immutable, minimal, audited.

**Responsibilities:**
- Verify signed payloads (agent authorization)
- Evaluate conditions via query + operators
- Execute actions atomically (all-or-nothing)
- Handle PAUSE_EXECUTION (resume when condition met)
- Manage cancellations via nonces

**Key design:** Only valuable for batched, conditional, or deferred execution. Single non-conditional calls should use protocols directly.

### 4.2 Cancel Mechanism (Processor-Level)

```solidity
// Nonce-based cancellation
mapping(address => uint256) public nonces;

function cancel(uint256 nonce) external {
    require(nonce >= nonces[msg.sender], "invalid nonce");
    nonces[msg.sender] = nonce + 1;
    emit Cancelled(msg.sender, nonce);
}

// On execute
function execute(bytes calldata signedPayload) external {
    ...
    require(payload.nonce >= nonces[payload.initiator], "cancelled");
    ...
}
```

**Benefits:**
- One mechanism for all intents
- No per-flow cancel logic needed
- User can cancel anytime before execution
- Sign new intent with higher nonce to replace

### 4.3 Signed Payloads

```solidity
struct SignedPayload {
    Action[] actions;       // What to do
    Condition condition;    // When to do it
    address initiator;      // Who authorized
    uint256 nonce;          // For cancellation
    uint256 deadline;       // Expiry (optional)
    bytes signature;        // Proof of authorization
}
```

---

## 5. Query System

**Query = staticcall to any contract's view function**

### 5.1 How It Works

```solidity
interface IQueryCondition {
    function check(
        address target,     // Contract to call
        bytes calldata data, // Encoded view function call
        bytes1 operator,    // Comparison operator
        bytes32 value       // Value to compare against
    ) external view returns (bool met);
}

// Under the hood
function check(...) external view returns (bool) {
    (bool success, bytes memory result) = target.staticcall(data);
    require(success, "query failed");
    
    bytes32 queryResult = abi.decode(result, (bytes32));
    return _compare(queryResult, operator, value);
}
```

### 5.2 Operators

| Operator | Symbol | Bytes1 |
|----------|--------|--------|
| Less than | `<` | `0x3C` |
| Greater than | `>` | `0x3E` |
| Less or equal | `<=` | `0x4C` |
| Greater or equal | `>=` | `0x47` |
| Equal | `==` | `0x3D` |
| Not equal | `!=` | `0x21` |

### 5.3 What Query Can Read

| Source | Example Call | Use Case |
|--------|--------------|----------|
| Token balance | `balanceOf(address)` | "If my USDC > 1000" |
| Price oracle | `latestRoundData()` | "If ETH < $2000" |
| Protocol state | `getReserveData()` | "If Aave APY > 5%" |
| Pool state | `slot0()` | "If price in range" |
| Any view function | Any `staticcall` | Flexible conditions |

### 5.4 SDK Usage

```typescript
// Query any on-chain data
w3.intent()
  .action('swap', { from: USDC, to: ETH, amount: 1000e6 })
  .condition('query', {
    target: CHAINLINK_ETH_USD,
    call: 'latestRoundData()',
    extract: '[1]', // price is second return value
    operator: '<',
    value: 2000e8
  })

// Or use built-in helpers
w3.intent()
  .action('swap', { from: USDC, to: ETH, amount: 1000e6 })
  .condition('price', { token: ETH, operator: '<', value: 2000 })
```

---

## 6. Plugins

### 6.1 Actions (What to do)

| Action | Protocol | Description |
|--------|----------|-------------|
| SwapAction | Uniswap, Aerodrome | Exchange tokens |
| YieldAction | Aave, Morpho | Deposit/withdraw for yield |
| TransferAction | Native | Send tokens |
| StakeAction | Lido | Stake for rewards |

**Interface:**
```solidity
interface IAction {
    function execute(
        address initiator,
        bytes calldata params
    ) external payable returns (bytes memory result);
}
```

### 6.2 Conditions (When to do it)

| Condition | Trigger |
|-----------|---------|
| TimeCondition | At timestamp, every interval |
| QueryCondition | Any view call + operator + value |

Built-in helpers (wrap QueryCondition):
- `price` → Chainlink query
- `balance` → balanceOf query
- `apy` → Protocol-specific query

**Interface:**
```solidity
interface ICondition {
    function check(bytes calldata params) external view returns (bool met);
}
```

### 6.3 Plugin Marketplace

| Tier | Requirements |
|------|--------------|
| Core | Full audit, immutable, official |
| Verified | Code review, community vouch |
| Community | Basic checks, use at own risk |

---

## 7. Execution Model

### 7.1 Conditional Execution

```
Agent signs: swap(USDC→ETH) when query(ETH price) < $2000
                    ↓
Keeper calls: processor.execute(signedPayload)
                    ↓
Processor: 
  1. Verify signature ✓
  2. Check nonce valid ✓
  3. Query: staticcall(chainlink.latestRoundData())
  4. Compare: result < 2000e8 → false
  5. Return PAUSE_EXECUTION
                    ↓
(later) Keeper calls again
                    ↓
Processor:
  3. Query: result = 1950e8
  4. Compare: 1950e8 < 2000e8 → true
  5. Execute SwapAction ✓
```

### 7.2 Batched Atomic Execution

```
Agent signs: [withdraw(Aave), swap(USDC→ETH)]
                    ↓
Processor: Execute all atomically
           Any failure → all revert
```

### 7.3 Recurring Execution

```
Agent signs: swap(100 USDC→ETH) every week, 12 times
                    ↓
State: { interval: 1 week, remaining: 12, lastExec: 0 }
                    ↓
Keeper calls weekly, processor:
  1. Check: block.timestamp >= lastExec + interval
  2. Execute swap
  3. Update: remaining--, lastExec = now
  4. If remaining == 0, mark complete
```

---

## 8. SDK

```typescript
import { W3Cash } from 'w3cash';

const w3 = new W3Cash({ chain: 'base' });

// Build intent
const intent = w3.intent()
  .action('swap', { from: USDC, to: ETH, amount: 100e6 })
  .condition('price', { token: ETH, operator: '<', value: 2000 })
  .build();

// Sign
const signed = await w3.sign(intent);

// Submit to keeper network
await w3.submit(signed);

// Cancel if needed
await w3.cancel(intent.nonce);
```

### SDK Methods

| Method | Description |
|--------|-------------|
| `intent()` | Start building an intent |
| `.action(name, params)` | Add action |
| `.condition(name, params)` | Add condition |
| `.build()` | Compile to payload |
| `.sign(payload)` | Sign with wallet |
| `.submit(signed)` | Submit to keeper network |
| `.cancel(nonce)` | Cancel intent |

---

## 9. Use Cases

### DCA (Dollar-Cost Averaging)
```typescript
w3.intent()
  .action('swap', { from: USDC, to: ETH, amount: 100e6 })
  .condition('interval', { every: '1 week', times: 52 })
```

### Limit Order
```typescript
w3.intent()
  .action('swap', { from: USDC, to: ETH, amount: 1000e6 })
  .condition('price', { token: ETH, operator: '<', value: 2000 })
```

### Stop-Loss
```typescript
w3.intent()
  .action('swap', { from: ETH, to: USDC, amount: ALL })
  .condition('price', { token: ETH, operator: '<', value: 1500 })
```

### Yield Rebalance
```typescript
w3.intent()
  .action('withdraw', { protocol: 'aave', token: USDC })
  .action('deposit', { protocol: 'morpho', token: USDC })
  .condition('query', {
    target: MORPHO_LENS,
    call: 'getCurrentSupplyAPY(address)',
    args: [USDC_MARKET],
    operator: '>',
    value: currentAaveAPY + 50 // +0.5% better
  })
```

### Low Balance Alert + Top-up
```typescript
w3.intent()
  .action('transfer', { from: treasury, to: agent, amount: 100e6 })
  .condition('balance', { 
    address: agent, 
    token: USDC, 
    operator: '<', 
    value: 10e6 
  })
```

---

## 10. Security Model

### 10.1 Trust Assumptions

| Component | Trust |
|-----------|-------|
| Processor | Immutable, audited, no admin |
| Plugins | Tiered (core/verified/community) |
| Keepers | Trustless (signature authorizes) |
| Agent | Signs intent, can cancel anytime |

### 10.2 Security Properties

- **Atomic execution:** All actions succeed or all revert
- **Authorization:** Only signed intents execute
- **Cancellation:** User can cancel via nonce anytime
- **Expiry:** Optional deadline for auto-invalidation
- **Bounded scope:** Signature authorizes specific actions only

---

## 11. Scope

| Feature | Status |
|---------|--------|
| Processor with nonce-based cancel | Core |
| Query (staticcall any view function) | Core |
| Operators (<, >, <=, >=, ==, !=) | Core |
| Time conditions | Core |
| Atomic batching | Core |
| Signed payloads | Core |
| PAUSE/RESUME | Core |
| Actions: Swap, Yield, Transfer | Plugins |

---

## 12. Natural Language Intent (Future)

Agent LLMs can parse natural language into structured intents. W3Cash provides a **skill** to teach agents.

### Skill Approach

```
skills/w3cash/SKILL.md
├── Available actions
├── Available conditions  
├── NL → code examples
└── Validation rules
```

**Flow:**
```
User: "DCA $100 into ETH weekly"
         ↓
Agent LLM (with w3cash skill): parses NL
         ↓
w3.intent().action('swap', {...}).condition('interval', {...})
```

### SDK Confirmation

```typescript
const intent = w3.intent()...build();
intent.summary // "Swap 1000 USDC → ETH when ETH < $2000"
// Agent shows user for confirmation before signing
```

---

## 13. Action Inventory

Comprehensive building blocks. Goal: support all AgentKit on-chain actions + more.

### Core Actions (Phase 1)

| Action | Protocols | Methods |
|--------|-----------|---------|
| Transfer | ERC20 | transfer, transferFrom |
| Approve | ERC20 | approve, permit |
| Wrap | WETH | deposit, withdraw |
| Swap | Uniswap, Aerodrome | swapExactIn, swapExactOut |
| Lend | Aave | deposit, withdraw |
| Bridge | Across | bridge |

### Expanded Actions (Phase 2)

| Category | Protocols | Methods |
|----------|-----------|---------|
| **Swap** | Uniswap, Sushi, Aerodrome, 0x, 1inch, Paraswap | swap, quote |
| **Lending** | Aave, Compound, Moonwell, Morpho | deposit, withdraw, borrow, repay |
| **Yield** | Yearn, Pendle, Yelay, vaultsfyi | stake, unstake, claim |
| **Bridge** | Across, CCTP, Stargate | bridge, quote |
| **Staking** | Lido, Rocket Pool, Eigenlayer | stake, unstake, claim |
| **NFT** | Zora, OpenSea | mint, transfer, list, buy |
| **Payments** | x402 | pay, verify |
| **Identity** | Basename, ENS | register, resolve, set |
| **Streams** | Superfluid | createStream, cancelStream |
| **Perps** | GMX, dYdX | openPosition, closePosition |
| **Stable** | Curve, Balancer | swap, addLiquidity |

### Other Sources to Monitor

| Protocol | Category | Notes |
|----------|----------|-------|
| Liquity | Borrowing | 0% interest loans |
| Spark | Lending | MakerDAO ecosystem |
| Convex | Yield | Curve boosting |
| Frax | Stablecoin | frxETH staking |
| Renzo | Restaking | ezETH |
| Kelp | Restaking | rsETH |

### Principle

> More actions = more useful. If AgentKit can do it, W3Cash can do it + conditions.

---

## 14. Roadmap

### Phase 1: Core
- [ ] Processor with query + operators + cancel
- [ ] Registry for plugins
- [ ] TimeCondition, QueryCondition
- [ ] SwapAction, YieldAction, TransferAction
- [ ] SDK v1.0

### Phase 2: Expand
- [ ] More actions: Stake, Bridge
- [ ] Built-in condition helpers (price, balance, apy)
- [ ] Keeper network integration
- [ ] Gas optimization

### Phase 3: Marketplace
- [ ] Plugin submission flow
- [ ] Community plugins
- [ ] Plugin incentives

---

## 15. Terminology

| Term | Definition |
|------|------------|
| **W3Cash** | Full system (core + SDK + plugins) |
| **Core** | Processor + Registry contracts |
| **Action** | Plugin that executes on-chain operations |
| **Condition** | Plugin that checks if action should execute |
| **Query** | staticcall to read on-chain data |
| **Operator** | Comparison operator (<, >, ==, etc.) |
| **Intent** | Action(s) + Condition composed by agent |
| **Nonce** | Counter for cancellation |

---

## 16. Conclusion

W3Cash enables AI agents to automate on-chain actions by expressing needs, not building solutions. Key features:

1. **Query system:** Read any on-chain data via staticcall
2. **Operators:** Compare query results with <, >, ==, etc.
3. **Cancel:** Nonce-based, processor-level cancellation
4. **Plugins:** Extensible actions and conditions
5. **Simplicity:** No IF/ELSE, no VM, agent decides off-chain

**W3Cash is for automation. Simple calls go direct. Complexity goes through W3Cash.**

---

*End of Whitepaper v4.1*
