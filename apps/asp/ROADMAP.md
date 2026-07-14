# W3Cash ASP — capability research & roadmap (2026-07-15)

Research finding in one line: **we expose 7 of ~40 adapters, two of them (`balance`,
`price`) are wired to DEAD adapters that revert on-chain, x402 is built-but-off, and
the ASP isn't registered on OKX.AI yet.** Almost every high-value move needs **no new
contracts**.

> ⚠️ **Ground-truth caveat:** the shipped `SKILL.md`/README adapter address tables are
> WRONG (8 dead addresses; 6 addresses each claimed by two IDs). Before exposing ANY
> adapter, resolve its address via `AdapterRegistry.getAdapter()` / `adapterId()`.
> There is **no "flows" abstraction** in this repo (only a deprecated `W3CashCore`).

## 1. Quick wins — hours each, `encode.ts`-only (no contract work)

| # | Win | Effort | Category |
|---|-----|--------|----------|
| 1 | **Fix `balance`/`price`** → re-route to the deployed **QueryAdapter** (`0x4bC2F784…`): balance = `balanceOf` compare, price = Chainlink `latestAnswer` compare. Kills the demo's only revert landmine. | S | correctness |
| 2 | **TimeRange condition** (`0xCC18E7E2…`, id `0x79b4e21f`) — recurring daily UTC windows ("DCA only 9–10am"). | S | Lifestyle / Finance Copilot |
| 3 | **GasPrice condition** (`0x07DcD715…`, id `0x62c7743a`) — "execute only when gas < X". | S | Software Utility |
| 4 | **Signature 2nd-approver condition** (`0xEEe61780…`, id `0xfde104a6`) — co-sign + replay protection + deadline. **Directly fixes our own replayable-intent caveat.** | M | Best Product / security |
| 5 | **Bridge action** — Across `depositV3` (`0x3502362c…`, id `0x716f6a28`; SpokePool exists on Base Sepolia). | S–L | Best Product / Revenue Rocket |
| 6 | **Register ERC-8004 ASP on OKX.AI** (`agent register --role asp`) — the entry ticket. | S | discovery / Social Buzz |
| 7 | **Flip `X402_ENABLED=true`** + redeploy — the paid tier is built but off. | S | Revenue Rocket |
| 8 | **Canned recipes** (DCA / buy-the-dip / Aave stop-loss / cross-chain sweep) + surface the `cancel`/`incrementNonce` caveat as a first-class field. | S | Finance Copilot |
| 9 | **Enter an OKX growth/trading competition** (list → register → leaderboard). | S | Revenue Rocket / Social Buzz |
| 10 | **Fix truthfulness gap** — `DEMO.md` claims "18 actions × conditions"; we expose 7 (12+ after 1–5). | S | credibility |

*Deployed-but-lower-value adapters (expose only if trivial): Stake (targets likely absent on testnet → may revert), Batch (redundant with the native multi-op array), Liquidate (niche).*

## 2. Bigger bets — from assets we already own

- **Bet A — Prediction-market-gated intents (flagship, effort S, zero new contracts).** QueryAdapter already staticcalls any uint256 view. `query{ target:<TruthMarket>, calldata:isSettled(), op:eq, expected:1 }` gates any W3Cash action on a Sooth market resolving — "swap/withdraw only if my prediction resolves YES." The one demo that requires owning **both** an intent compiler **and** a truth layer — no other team can tell this story. `uma-mirror-adjudicator` supplies real Polymarket-mirrored markets to gate on.
- **Bet B — Soothsayer "Revolution" oracle as a 2nd ASP (effort M).** A multi-source resolution + AI-forecast stack is already live on CF Workers (Polymarket Gamma, Binance, CoinGecko, DeFiLlama, Open-Meteo, sports, FRED) — it just has no agent endpoint. Clone the `apps/asp` Express + x402 shell → `POST /resolve-question` → `{outcome, confidence, evidence}`, reuse x402 verbatim.

*Do NOT attempt in 2 days:* deploying the ~40 written-but-undeployed adapters (GMX/Pendle/Morpho/Curve/leverage). Cherry-pick at most one; present the rest as roadmap breadth.

## 3. What we have but aren't using — ranked
1. ERC-8004 ASP registration on OKX.AI (not done — the entry ticket).
2. Seven deployed-but-hidden adapters (Bridge, TimeRange, GasPrice, Signature, Stake, Batch, Liquidate).
3. QueryAdapter as a universal gate (backs balance/price AND prediction-market gating).
4. The x402 paid tier (built, off by default).
5. Soothsayer "Revolution" oracle (live product, no agent endpoint).
6. The adjudication stack (soothsayer, uma-mirror, ZkTLS, Primus) → OKX.AI **Evaluator** role — our biggest unique moat (narrative; Evaluator staking is real OKB).
7. zkTLS attestation primitive (`kpi-resolver`) — "prove any HTTPS JSON value on-chain."
8. MPP session channels / subscription / a2a-pay links — additive x402 `accepts[]` pricing ladder (different trust model — TEE-signed).
9. OKX Market/Signal/Social data as off-chain conditions ("execute when smart-money net-buys") — needs a relayer.

## 4. Top recommendation (the ~2-day plan)
**Make the ONE live ASP bulletproof, listed, and paid — then land prediction-market-gated intents as the flagship.**
- **Day 1 (all S, no contract risk):** fix balance/price → QueryAdapter; register the ASP on OKX.AI; flip x402 on; add TimeRange + GasPrice + Signature + Bridge (encode.ts only, resolving each address via `adapterId()` first); publish recipes; fix the "18 actions" copy; enter a growth competition.
- **Day 2:** ship prediction-market-gated intents (QueryAdapter → `TruthMarket.isSettled()/winningOutcome()`, zero new contracts). If time, stand up the Soothsayer oracle as a 2nd ASP.

Spans Finance Copilot + Best Product + Software Utility + Revenue Rocket + Creative Genius, using only assets we already own.
