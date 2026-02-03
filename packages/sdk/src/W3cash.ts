import {
  createPublicClient,
  createWalletClient,
  http,
  custom,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Address,
} from 'viem';
import type { W3cashConfig, SupportedChain, FlowName } from './types';
import { CHAINS, CONTRACTS } from './constants';
import { X402Flow } from './flows/x402';
import { YieldFlow } from './flows/yield';

/**
 * W3cash SDK Client
 *
 * Pick flows. Gain on-chain economy.
 *
 * @example
 * ```typescript
 * import { W3cash } from 'w3cash';
 *
 * const w3 = new W3cash({ chain: 'base-sepolia' });
 *
 * // Get a flow
 * const x402 = w3.flow('x402');
 * const yield = w3.flow('yield');
 *
 * // Use flows
 * await x402.pay({ to, amount, token, resourceId });
 * await yield.deposit(USDC, amount);
 * ```
 */
export class W3cash {
  /** The configured chain */
  readonly chain: SupportedChain;

  /** The viem Chain object */
  readonly viemChain: Chain;

  /** Public client for read operations */
  readonly publicClient: PublicClient;

  /** Wallet client for write operations */
  private walletClient: WalletClient | null = null;

  /** Contract addresses */
  readonly contracts: typeof CONTRACTS[SupportedChain];

  // Cached flow instances
  private _x402?: X402Flow;
  private _yield?: YieldFlow;

  constructor(config: W3cashConfig) {
    this.chain = config.chain;
    this.viemChain = CHAINS[config.chain];
    this.contracts = CONTRACTS[config.chain];

    // Create public client
    this.publicClient = createPublicClient({
      chain: this.viemChain,
      transport: http(config.rpcUrl),
    });
  }

  /**
   * Connect a wallet for write operations
   * 
   * @example
   * ```typescript
   * // With private key
   * w3.connect(privateKeyToAccount('0x...'));
   * 
   * // With browser wallet
   * w3.connectBrowser(window.ethereum);
   * ```
   */
  connect(account: any): this {
    this.walletClient = createWalletClient({
      account,
      chain: this.viemChain,
      transport: http(),
    });
    // Clear cached flows to recreate with wallet
    this._x402 = undefined;
    this._yield = undefined;
    return this;
  }

  /**
   * Connect browser wallet (MetaMask, etc.)
   */
  connectBrowser(provider: any): this {
    this.walletClient = createWalletClient({
      chain: this.viemChain,
      transport: custom(provider),
    });
    this._x402 = undefined;
    this._yield = undefined;
    return this;
  }

  /**
   * Get a flow by name
   */
  flow(name: 'x402'): X402Flow;
  flow(name: 'yield'): YieldFlow;
  flow(name: FlowName): X402Flow | YieldFlow {
    switch (name) {
      case 'x402':
        if (!this._x402) {
          this._x402 = new X402Flow(
            this.publicClient,
            this.walletClient,
            this.contracts.flows.x402
          );
        }
        return this._x402;

      case 'yield':
        if (!this._yield) {
          this._yield = new YieldFlow(
            this.publicClient,
            this.walletClient,
            this.contracts.flows.yield
          );
        }
        return this._yield;

      default:
        throw new Error(`Flow '${name}' not yet supported`);
    }
  }

  /**
   * Get flow at a custom address
   */
  flowAt(name: 'x402', address: Address): X402Flow;
  flowAt(name: 'yield', address: Address): YieldFlow;
  flowAt(name: FlowName, address: Address): X402Flow | YieldFlow {
    switch (name) {
      case 'x402':
        return new X402Flow(this.publicClient, this.walletClient, address);
      case 'yield':
        return new YieldFlow(this.publicClient, this.walletClient, address);
      default:
        throw new Error(`Flow '${name}' not yet supported`);
    }
  }

  /**
   * Get the chain ID
   */
  get chainId(): number {
    return this.viemChain.id;
  }

  /**
   * Get the core contract address
   */
  get coreAddress(): Address {
    return this.contracts.core;
  }

  /**
   * Check if contracts are deployed
   */
  async isReady(): Promise<boolean> {
    try {
      const code = await this.publicClient.getCode({
        address: this.contracts.core,
      });
      return code !== undefined && code !== '0x';
    } catch {
      return false;
    }
  }

  /**
   * Get the current block number
   */
  async getBlockNumber(): Promise<bigint> {
    return this.publicClient.getBlockNumber();
  }
}
