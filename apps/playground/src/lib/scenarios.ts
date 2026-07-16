import type { CompileBody } from './asp';
import { USDC, SOOTH_MARKET } from './chain';

export type ScenarioId = 'transfer' | 'market' | 'bridge';

export interface Scenario {
  id: ScenarioId;
  title: string;
  subtitle: string;
  badge: 'EXECUTABLE' | 'COMPILE-ONLY';
  flagship: boolean;
  executable: boolean;
  // One-liner shown near the intent explaining what happens on execution.
  gateNote: string;
  buildBody: (recipient: string) => CompileBody;
}

export const SCENARIOS: readonly Scenario[] = [
  {
    id: 'transfer',
    title: 'Wait, then send 1 USDC',
    subtitle:
      'A time gate in front of a real USDC transfer. Sign it once — it fires the instant the clock passes.',
    badge: 'EXECUTABLE',
    flagship: false,
    executable: true,
    gateNote:
      'Fully executable on Base Sepolia — the wait gate is set to a past timestamp, so it clears immediately.',
    buildBody: (recipient) => ({
      chain: 84532,
      conditions: [{ type: 'waitTime', timestamp: 1 }],
      actions: [{ type: 'transfer', token: USDC, to: recipient, amount: '1000000' }],
    }),
  },
  {
    id: 'market',
    title: 'Withdraw only if a prediction market resolves YES',
    subtitle:
      'Bind a payout to a live Sooth market outcome. The transfer is impossible until the market settles YES.',
    badge: 'COMPILE-ONLY',
    flagship: true,
    executable: false,
    gateNote:
      'Compiles a real, signable intent; execution fires only when the market resolves YES on-chain.',
    buildBody: (recipient) => ({
      chain: 84532,
      conditions: [{ type: 'marketOutcome', market: SOOTH_MARKET, outcome: 'YES' }],
      actions: [{ type: 'transfer', token: USDC, to: recipient, amount: '1000000' }],
    }),
  },
  {
    id: 'bridge',
    title: 'Bridge 5 USDC to Ethereum when gas is cheap',
    subtitle:
      'A gas-price gate in front of an Across bridge. The ASP auto-fetches the live bridge quote at compile time.',
    badge: 'COMPILE-ONLY',
    flagship: false,
    executable: false,
    gateNote:
      'Compiles a real intent (with a live Across quote); execution fires only when network gas drops below the threshold.',
    buildBody: (recipient) => ({
      chain: 84532,
      conditions: [{ type: 'gasPrice', operator: 'lt', threshold: '50000000000' }],
      actions: [
        {
          type: 'bridge',
          autoQuote: true,
          inputToken: USDC,
          destinationChainId: 11155111,
          inputAmount: '5000000',
          recipient,
        },
      ],
    }),
  },
];
