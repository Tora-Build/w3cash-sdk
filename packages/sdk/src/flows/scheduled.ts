import {
  type PublicClient,
  type WalletClient,
  type Address,
  type Hash,
  type Hex,
  parseAbi,
} from 'viem';

const SCHEDULED_ABI = parseAbi([
  'function createSchedule(address token, address recipient, uint256 amount, uint64 executeAt) external returns (bytes32 scheduleId)',
  'function createPriceCondition(address token, address recipient, uint256 amount, address priceFeed, uint256 targetPrice, bool above) external returns (bytes32 scheduleId)',
  'function executeSchedule(bytes32 scheduleId) external returns (bool)',
  'function cancelSchedule(bytes32 scheduleId) external',
]);

export interface TimeSchedule {
  token: Address;
  recipient: Address;
  amount: bigint;
  executeAt: bigint; // Unix timestamp
}

export interface PriceCondition {
  token: Address;
  recipient: Address;
  amount: bigint;
  priceFeed: Address;
  targetPrice: bigint;
  above: boolean;
}

/**
 * ScheduledFlow - Time and price-based conditional transfers
 * 
 * @example
 * ```typescript
 * const scheduled = w3.flow('scheduled');
 * 
 * // Create time-based transfer
 * const scheduleId = await scheduled.createTimeSchedule({
 *   token: USDC_ADDRESS,
 *   recipient: '0x...',
 *   amount: parseUnits('100', 6),
 *   executeAt: BigInt(Math.floor(Date.now() / 1000) + 86400), // 24h from now
 * });
 * 
 * // Create price-based transfer
 * const scheduleId = await scheduled.createPriceCondition({
 *   token: WETH_ADDRESS,
 *   recipient: '0x...',
 *   amount: parseEther('1'),
 *   priceFeed: ETH_USD_FEED,
 *   targetPrice: parseUnits('4000', 8), // When ETH hits $4000
 *   above: true,
 * });
 * ```
 */
export class ScheduledFlow {
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
   * Create a time-based scheduled transfer
   */
  async createTimeSchedule(schedule: TimeSchedule): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: SCHEDULED_ABI,
      functionName: 'createSchedule',
      args: [schedule.token, schedule.recipient, schedule.amount, schedule.executeAt],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Create a price-condition scheduled transfer
   */
  async createPriceCondition(condition: PriceCondition): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: SCHEDULED_ABI,
      functionName: 'createPriceCondition',
      args: [
        condition.token,
        condition.recipient,
        condition.amount,
        condition.priceFeed,
        condition.targetPrice,
        condition.above,
      ],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Execute a schedule (can be called by anyone when conditions are met)
   */
  async executeSchedule(scheduleId: Hex): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: SCHEDULED_ABI,
      functionName: 'executeSchedule',
      args: [scheduleId],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Cancel a schedule (only owner)
   */
  async cancelSchedule(scheduleId: Hex): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: SCHEDULED_ABI,
      functionName: 'cancelSchedule',
      args: [scheduleId],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }
}
