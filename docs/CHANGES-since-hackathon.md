# W3Cash — what changed since the hackathon (team brief)

_A short, honest summary for the team. Full detail: `docs/OVERVIEW.md`, `DECISIONS.md`, `apps/asp/BUILD_PLAN.md`._

## TL;DR
The hackathon shipped a working demo. Since then we (a) **hardened + expanded the live off-chain
service**, and (b) **designed, built, audited, and proved a next-generation on-chain core** — not
yet deployed. Nothing about the OKX submission or the live service was broken; every change is
additive and on `develop`.

## What is LIVE (deployed / shipping)
- **Multi-chain** — the compiler went from single-chain testnet to **3 chains incl. X Layer mainnet
  (196)**; contracts deployed + verified on OKLink; x402 payment moved to mainnet (USD₮0).
- **Safe-by-default compile** — every intent auto-gets an expiry bound, exact-sized exposure, and a
  one-tap cancel; plus compile-time sanity lints (gwei-vs-wei, past-time, decimals slips).
- **New agent endpoints/tools** (ship on the current deployment when the VPS pulls `develop`):
  - `POST /simulate-intent` + `w3cash_simulate_intent` — **FREE dry-run**: "would it fire / which
    gate blocks / what approval you need" (no payload leak).
  - `GET /payment-options` + `w3cash_payment_options` — **dynamic payment**: advertise every
    supported chain, caller picks or gets the default, response says which chain settled.
  - `GET /agent-card` + `/.well-known/agent-card.json` — machine-readable discovery descriptor.
  - `w3cash_cancel_all` — one-tx cancel calldata.
- **Telemetry worker** (`apps/telemetry/`, scaffolded, not deployed) — a Cloudflare Worker that
  indexes on-chain events → intent **status** + neutral **reliability stats**. Gives the service a
  memory. Read-only; reads public chain events (not tied to any relayer).

## What is BUILT but NOT deployed (the flagship — needs an external audit first)
The **Design C on-chain core** — the upgrade from the hackathon's nonce-based processor:

| Hackathon (deployed) | Design C (built, 159 tests, not deployed) |
|---|---|
| 1 signature, replayable until nonce bumped | 2-sig **session keys** (root grants a hot agent key), EIP-712, per-intent replay counter |
| no spend limits | typed **Policy**: codehash-pinned targets + verb mask + **per-token rolling-window caps** |
| adapters pull your funds directly | **SOLE-MOVER**: the processor pulls + pushes; adapters never touch root funds |
| one nonce cancels everything | **three revocation tiers** + per-intent cancel |
| — | balance-**threading**, a **flash-loan frame**, keeper **tips**, ERC-1271 + **ERC-7739** roots |

**Status:** internally audited (0 critical / 0 high; 2 mediums fixed), release-gate security proofs
in-repo (flash-frame isolation, transient zero-on-exit, domain separation, Permit2 witness). New
roles: **root** (fund owner), **session key** (hot agent signer), **keeper** (executes + gets a tip),
**relayer** (submits, pays gas).

## The one-liner for outsiders
W3Cash = a **non-custodial "if-this-then-that" engine for on-chain money that an AI agent can drive
on your behalf** — with spending limits, without your keys, and with no counterparty in the middle.

## What's left before a Design C launch (all external, not features)
1. A **professional external audit**.
2. A real-deployed-Permit2 **fork test** of the funding pull.
3. Provision the telemetry **D1** + point the compiler at the new addresses (a deliberate, separate step).

_Everything is on `develop`. The live service + OKX submission are untouched until we choose to
promote it._
