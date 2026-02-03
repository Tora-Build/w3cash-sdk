import {
  type PublicClient,
  type WalletClient,
  type Address,
  type Hash,
  type Hex,
  parseAbi,
} from 'viem';

const DCA_ABI = parseAbi([
  'function createDCA(address tokenIn, address tokenOut, uint256 amountPerInterval, uint64 interval, uint64 totalExecutions) external returns (bytes32 dcaId)',
  'function executeDCA(bytes32 dcaId) external returns (uint256 amountOut)',
  'function cancelDCA(bytes32 dcaId) external',
  'function getDCAInfo(bytes32 dcaId) external view returns (address owner, address tokenIn, address tokenOut, uint256 amountPerInterval, uint64 interval, uint64 executionsRemaining, uint64 lastExecution)',
]);

export interface DCAParams {
  tokenIn: Address;
  tokenOut: Address;
  amountPerInterval: bigint;
  interval: bigint; // Seconds between executions
  totalExecutions: bigint;
}

export interface DCAInfo {
  owner: Address;
  tokenIn: Address;
  tokenOut: Address;
  amountPerInterval: bigint;
  interval: bigint;
  executionsRemaining: bigint;
  lastExecution: bigint;
}

/**
 * DCAFlow - Dollar-Cost Averaging
 * 
 * @example
 * ```typescript
 * const dca = w3.flow('dca');
 * 
 * // Create weekly DCA: $100 USDC → ETH every week for 52 weeks
 * const dcaId = await dca.createDCA({
 *   tokenIn: USDC_ADDRESS,
 *   tokenOut: WETH_ADDRESS,
 *   amountPerInterval: parseUnits('100', 6),
 *   interval: BigInt(7 * 24 * 60 * 60), // 1 week
 *   totalExecutions: 52n,
 * });
 * 
 * // Execute next DCA (can be called by anyone/keepers)
 * await dca.executeDCA(dcaId);
 * 
 * // Get DCA status
 * const info = await dca.getDCAInfo(dcaId);
 * console.log(`${info.executionsRemaining} executions remaining`);
 * ```
 */
export class DCAFlow {
  private publicClient: PublicClient;
  private walletClient: WalletClient | null;
  readonly address: Address;

  constructor(
    publicClient: PublicClient,
    walletClient: WalletClient | null,
    address: Address
  ) {
    this.publicClient = publicClient;
    this.walletClient = walletClient;
    this.address = address;
  }

  /**
   * Create a new DCA (Dollar-Cost Averaging) schedule
   */
  async createDCA(params: DCAParams): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: DCA_ABI,
      functionName: 'createDCA',
      args: [
        params.tokenIn,
        params.tokenOut,
        params.amountPerInterval,
        params.interval,
        params.totalExecutions,
      ],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Execute the next DCA swap (can be called by anyone when interval has passed)
   */
  async executeDCA(dcaId: Hex): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: DCA_ABI,
      functionName: 'executeDCA',
      args: [dcaId],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Cancel a DCA schedule (only owner)
   */
  async cancelDCA(dcaId: Hex): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: DCA_ABI,
      functionName: 'cancelDCA',
      args: [dcaId],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Get DCA info
   */
  async getDCAInfo(dcaId: Hex): Promise<DCAInfo> {
    const result = await this.publicClient.readContract({
      address: this.address,
      abi: DCA_ABI,
      functionName: 'getDCAInfo',
      args: [dcaId],
    });

    return {
      owner: result[0],
      tokenIn: result[1],
      tokenOut: result[2],
      amountPerInterval: result[3],
      interval: BigInt(result[4]),
      executionsRemaining: BigInt(result[5]),
      lastExecution: BigInt(result[6]),
    };
  }
}
