import {
  createPublicClient,
  createWalletClient,
  http,
  custom,
  keccak256,
  encodeAbiParameters,
  parseAbiParameters,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Address,
  type Hex,
} from 'viem';
import type { W3cashConfig, SupportedChain } from './types';
import { CHAINS, CONTRACTS } from './constants';
import { IntentBuilder, type BuiltIntent, type SignedIntent } from './intent';

/**
 * W3cash SDK Client
 *
 * Core POCA (Programmable On-Chain Automation) client.
 *
 * @example
 * ```typescript
 * import { W3cash } from 'w3cash';
 *
 * const w3 = new W3cash({ chain: 'base-sepolia' });
 * 
 * // Check if ready
 * const ready = await w3.isReady();
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
  protected _walletClient: WalletClient | null = null;

  /** Contract addresses */
  readonly contracts: typeof CONTRACTS[SupportedChain];

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
    this._walletClient = createWalletClient({
      account,
      chain: this.viemChain,
      transport: http(),
    });
    return this;
  }

  /**
   * Connect browser wallet (MetaMask, etc.)
   */
  connectBrowser(provider: any): this {
    this._walletClient = createWalletClient({
      chain: this.viemChain,
      transport: custom(provider),
    });
    return this;
  }

  /**
   * Get the connected wallet client
   */
  get walletClient(): WalletClient | null {
    return this._walletClient;
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

  /**
   * Create a new intent builder
   * 
   * @example
   * ```typescript
   * const intent = w3.intent()
   *   .transfer({ token: USDC, to: recipient, amount: 100n * 10n**6n })
   *   .afterTime(Math.floor(Date.now() / 1000) + 3600)
   *   .build(adapters);
   * ```
   */
  intent(): IntentBuilder {
    return new IntentBuilder();
  }

  /**
   * Get user's current nonce
   */
  async getNonce(address: Address): Promise<bigint> {
    const nonce = await this.publicClient.readContract({
      address: this.contracts.processor,
      abi: PROCESSOR_ABI,
      functionName: 'nonces',
      args: [address],
    });
    return nonce as bigint;
  }

  /**
   * Sign a built intent
   * 
   * @example
   * ```typescript
   * const signedIntent = await w3.sign(builtIntent);
   * ```
   */
  async sign(intent: BuiltIntent): Promise<SignedIntent> {
    if (!this._walletClient?.account) {
      throw new Error('No wallet connected. Call connect() first.');
    }

    const account = this._walletClient.account;
    const nonce = await this.getNonce(account.address);

    // Sign over (payloadHash, nonce)
    const messageHash = keccak256(
      encodeAbiParameters(
        parseAbiParameters('bytes32, uint256'),
        [intent.payloadHash as Hex, nonce]
      )
    );

    const signature = await this._walletClient.signMessage({
      account,
      message: { raw: messageHash },
    });

    return {
      instruction: intent.instruction,
      initiator: account.address,
      nonce,
      signature,
    };
  }

  /**
   * Cancel all pending intents by incrementing nonce
   * 
   * @example
   * ```typescript
   * const newNonce = await w3.cancel();
   * ```
   */
  async cancel(): Promise<bigint> {
    if (!this._walletClient?.account) {
      throw new Error('No wallet connected. Call connect() first.');
    }

    const hash = await this._walletClient.writeContract({
      address: this.contracts.processor,
      abi: PROCESSOR_ABI,
      functionName: 'incrementNonce',
      account: this._walletClient.account,
      chain: this.viemChain,
    });

    await this.publicClient.waitForTransactionReceipt({ hash });
    
    // Return new nonce
    return this.getNonce(this._walletClient.account.address);
  }

  /**
   * Execute a signed intent
   * 
   * @example
   * ```typescript
   * const result = await w3.execute(signedIntent);
   * ```
   */
  async execute(signedIntent: SignedIntent): Promise<Hex> {
    if (!this._walletClient?.account) {
      throw new Error('No wallet connected. Call connect() first.');
    }

    const encodedPayload = encodeAbiParameters(
      parseAbiParameters('(bytes, address, uint256, bytes)'),
      [[signedIntent.instruction, signedIntent.initiator, signedIntent.nonce, signedIntent.signature]]
    );

    const hash = await this._walletClient.writeContract({
      address: this.contracts.processor,
      abi: PROCESSOR_ABI,
      functionName: 'execute',
      args: [encodedPayload],
      account: this._walletClient.account,
      chain: this.viemChain,
    });

    return hash;
  }
}

/**
 * W3CashProcessor ABI (minimal for SDK)
 */
const PROCESSOR_ABI = [
  {
    name: 'nonces',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'user', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    name: 'incrementNonce',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [],
    outputs: [{ name: 'newNonce', type: 'uint256' }],
  },
  {
    name: 'execute',
    type: 'function',
    stateMutability: 'payable',
    inputs: [{ name: 'encodedSignedPayload', type: 'bytes' }],
    outputs: [],
  },
] as const;
