# ⚠️ Security Notice — the DEPLOYED Legacy processor

A whole-codebase blind audit (2026-07-23, `docs/AUDIT-full-codebase.md`) found that the **currently
deployed** processor — `W3CashProcessorLegacy` (nonce-based), live on Base Sepolia 84532, X Layer
testnet 1952, and X Layer mainnet 196 — has **fundamental signing/verification weaknesses**. It is a
**hackathon/demo deployment and must not be trusted with real value.**

## The findings (all in the deployed, immutable Legacy contract)

| # | Sev | Issue |
|---|-----|-------|
| 1 | **Critical** | **Unsigned execution header.** The signature covers only `keccak256(payload)+nonce`, NOT the instruction header (`seq`, `length`). `execute()` is permissionless, so any observer of a victim's signed intent (which becomes public every time it pauses waiting on a gate) can re-submit it with a forged `seq` to **jump straight to the fund-moving action, skipping every gate** — expiry, price, time, gas, and even a required co-signer. The recipient is fixed in the signed payload (so it's forced-execution/authorization-bypass, not direct theft), but it voids the entire "do X only when Y" guarantee. |
| 2 | **High** | **Nonce verified but never consumed.** The same signed payload replays indefinitely against a standing token allowance until the user calls `incrementNonce()`. |
| 3 | **Medium** | **No EIP-712 domain.** No `chainId`/`verifyingContract`/`deadline` binding → an intent signed on one chain replays on another where the user mirrored approvals. |

## Why it can't be patched

The Legacy contract is **immutable and already on-chain** — there is no code fix. The remediation is
**replacement**, which is exactly what the next-generation **Design C** processor
(`W3CashProcessor.sol`) already does:

- **Binds the full instruction header** and asserts `seq == 0` on every public `execute()` (ADR-0001
  correction C1) → fixes #1.
- **Per-intent EIP-712 execution cursor** consumed with reserve-then-run → fixes #2.
- **EIP-712 domain = the execution chain** + per-intent `deadline` (correction C2) → fixes #3.

Design C is built + blind-audited (0 critical / 0 high after fixes) but **not yet deployed** (pending
an external professional audit).

## Operational guidance until Design C ships

1. **Treat the Legacy deployment as demo-only.** Do not route real value through it.
2. **Do not grant standing (especially unlimited) token allowances** to the Legacy adapters. The
   safe-by-default compiler already sizes approvals to the exact per-intent amount — keep it that way.
3. **Prefer short-lived / one-shot intents** and cancel (`incrementNonce()`) promptly; assume any
   compiled Legacy signature is a public bearer instrument.
4. The x402 payment path (the OKX submission) is **unaffected** — it settles a stablecoin transfer via
   the OKX facilitator and never touches this processor.

_Source: `docs/AUDIT-full-codebase.md` findings #1–#3._
