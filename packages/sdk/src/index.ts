// Main client
export { W3cash } from './W3cash';

// Intent builder
export { IntentBuilder, type AdapterAddresses } from './intent';
export type {
  ActionType,
  ConditionType,
  QueryOperator,
  TransferParams,
  SwapParams,
  YieldParams,
  ApproveParams,
  TimeConditionParams,
  QueryConditionParams,
  BuiltIntent,
  SignedIntent,
} from './intent';
export { QUERY_OPERATORS } from './intent';

// Types
export type {
  W3cashConfig,
  SupportedChain,
  TxResult,
  TxReceipt,
} from './types';

// Constants
export {
  CHAINS,
  CONTRACTS,
  ADAPTERS,
  TOKENS,
  CORE_ABI,
  ERC20_ABI,
} from './constants';
