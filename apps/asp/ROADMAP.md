# W3Cash ASP — Roadmap

The W3Cash Intent Compiler is **live** on Base Sepolia today: **8 action types × 12
condition types over 11 on-chain-verified adapters**, free by default with a one-flag
x402 paid tier. Everything the items below build on — the compiler, the
envelope/signing scheme, the QueryAdapter view-gate, the Across `message` hook — already
ships. What's next deepens *conditional* execution (the layer we own) rather than
re-adding commodity legs.

## 1. Conditional embedded cross-chain — Across + MulticallHandler *(flagship)*

Gate a bridge **and** a destination-side DeFi action in a single signed intent:
*"bridge USDC to Ethereum **and** deposit it into Aave there — only when [condition]."*
The on-chain hook is already live: Across `depositV3` carries a `message` field, and the
`bridge` action already exposes it (`message?` in `src/w3cash/encode.ts`, encoded into
the depositV3 tuple). Across's canonical **MulticallHandler** executes that message on
the destination chain the moment a relayer fills. What's missing is purely off-chain:
(a) an **encoding helper** that builds the MulticallHandler payload —
`abi.encode((Call{ address target, bytes callData, uint256 value }[] calls, address
fallbackRecipient))` — and points `recipient` at the MulticallHandler; and (b) a
**recipe** wiring it end-to-end (approve → gated `depositV3` → destination Aave supply).
Result: one signature, one condition, a cross-chain deposit — no destination keys, no
second transaction, and **no new W3Cash contracts**.

## 2. More deployed adapters — leverage / perps / yield

Broaden the *action* menu with specialist legs (perps, leveraged positions, and yield
via GMX / Hyperliquid / Pendle / Morpho) as each is deployed and registry-verified on
Base Sepolia. Every adapter is just an `encode.ts` entry + a `/capabilities` row + a
recipe once its address is resolved via `adapterId()` — the compiler/envelope shape
never changes; only the catalog grows.

## 3. Off-chain-data conditions via a relayer

Extend gating beyond on-chain views to conditions a keeper attests: *"execute when
smart-money net-buys"* or *"…when a KPI crosses a threshold."* QueryAdapter already
staticcalls any on-chain `uint256`; a thin relayer (reusing the zkTLS / `kpi-resolver`
attestation primitive) writes an off-chain value on-chain so the existing `query` /
`price` gates apply unchanged to real-world data.

## 4. x402 pricing ladder via MPP

Today's paid tier is a single `exact` $0.01 charge. Add tiers to the x402 `accepts[]`
array — MPP session channels, subscriptions, and a2a-pay links — so a caller picks a
trust/price model (per-call, metered session, or prepaid). Purely additive; the
free-by-default posture is unchanged.

## 5. `asp.w3.cash` + mainnet

Cut the interim `sslip.io` host over to `asp.w3.cash` (one endpoint update on OKX.AI),
and promote the execution target from Base Sepolia to a mainnet deployment once the
adapter set is audited. Payment settlement follows: X Layer testnet → mainnet
(`eip155:1952` → `eip155:196`).
