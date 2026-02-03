import {
  type PublicClient,
  type WalletClient,
  type Address,
  type Hash,
} from 'viem';
import { YIELD_ABI, ERC20_ABI } from '../constants';

/**
 * YieldFlow - Aave V3 deposits and withdrawals
 * 
 * @example
 * ```typescript
 * const yield = w3.flow('yield');
 * 
 * // Deposit USDC
 * await yield.deposit(USDC_ADDRESS, parseUnits('1000', 6));
 * 
 * // Check balance
 * const balance = await yield.balance(USDC_ADDRESS, myAddress);
 * 
 * // Withdraw all
 * await yield.withdrawAll(USDC_ADDRESS);
 * ```
 */
export class YieldFlow {
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
   * Deposit tokens to earn yield
   * Requires prior approval to the YieldFlow contract
   */
  async deposit(token: Address, amount: bigint): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required for deposit');
    }

    // Check and set approval if needed
    await this.ensureApproval(token, amount);

    // Execute deposit
    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: YIELD_ABI,
      functionName: 'deposit',
      args: [token, amount],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Withdraw tokens
   * Requires approval for aTokens to the YieldFlow contract
   */
  async withdraw(token: Address, amount: bigint): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required for withdraw');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: YIELD_ABI,
      functionName: 'withdraw',
      args: [token, amount],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Withdraw all tokens
   */
  async withdrawAll(token: Address): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required for withdrawAll');
    }

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: YIELD_ABI,
      functionName: 'withdrawAll',
      args: [token],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Get balance in Aave (aToken balance)
   */
  async balance(token: Address, account: Address): Promise<bigint> {
    const balance = await this.publicClient.readContract({
      address: this.address,
      abi: YIELD_ABI,
      functionName: 'balance',
      args: [token, account],
    });

    return balance;
  }

  /**
   * Helper: Check and set approval
   */
  private async ensureApproval(token: Address, amount: bigint): Promise<void> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet account required');
    }

    const allowance = await this.publicClient.readContract({
      address: token,
      abi: ERC20_ABI,
      functionName: 'allowance',
      args: [this.walletClient.account.address, this.address],
    });

    if (allowance < amount) {
      const { request } = await this.publicClient.simulateContract({
        address: token,
        abi: ERC20_ABI,
        functionName: 'approve',
        args: [this.address, amount],
        account: this.walletClient.account,
      });
      await this.walletClient.writeContract(request);
    }
  }
}
