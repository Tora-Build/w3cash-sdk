// Main client
export { W3cash } from './W3cash';

// Flow classes
export { X402Flow } from './flows/x402';
export { YieldFlow } from './flows/yield';
export { ScheduledFlow } from './flows/scheduled';
export { DCAFlow } from './flows/dca';

// Types
export type {
  W3cashConfig,
  SupportedChain,
  FlowName,
  PaymentReceipt,
  PayOptions,
  PayEthOptions,
  DepositOptions,
  WithdrawOptions,
  TxResult,
  TxReceipt,
} from './types';

// Scheduled flow types
export type {
  TimeSchedule,
  PriceCondition,
} from './flows/scheduled';

// DCA flow types
export type {
  DCAParams,
  DCAInfo,
} from './flows/dca';

// Constants
export {
  CHAINS,
  CONTRACTS,
  TOKENS,
  CORE_ABI,
  X402_ABI,
  YIELD_ABI,
  ERC20_ABI,
} from './constants';
