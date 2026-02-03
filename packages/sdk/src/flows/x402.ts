import {
  type PublicClient,
  type WalletClient,
  type Address,
  type Hash,
  type Hex,
  keccak256,
  toHex,
} from 'viem';
import { X402_ABI, ERC20_ABI } from '../constants';
import type { PaymentReceipt } from '../types';

/**
 * x402Flow - HTTP-native payments
 * 
 * @example
 * ```typescript
 * const x402 = w3.flow('x402');
 * 
 * // Pay with USDC
 * const paymentId = await x402.pay({
 *   to: '0x...',
 *   amount: parseUnits('10', 6), // 10 USDC
 *   token: USDC_ADDRESS,
 *   resourceId: keccak256(toHex('/api/premium')),
 * });
 * 
 * // Pay with ETH
 * const paymentId = await x402.payEth({
 *   to: '0x...',
 *   resourceId: keccak256(toHex('/api/premium')),
 *   value: parseEther('0.01'),
 * });
 * 
 * // Verify payment
 * const { exists, receipt } = await x402.verify(paymentId);
 * ```
 */
export class X402Flow {
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
   * Pay with ERC20 token
   * Requires prior approval to the x402Flow contract
   */
  async pay(options: {
    to: Address;
    amount: bigint;
    token: Address;
    resourceId: Hex;
  }): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required for pay');
    }

    const { to, amount, token, resourceId } = options;

    // Check and set approval if needed
    await this.ensureApproval(token, amount);

    // Execute payment
    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: X402_ABI,
      functionName: 'pay',
      args: [to, amount, token, resourceId],
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Pay with ETH
   */
  async payEth(options: {
    to: Address;
    resourceId: Hex;
    value: bigint;
  }): Promise<Hash> {
    if (!this.walletClient?.account) {
      throw new Error('Wallet client with account required for payEth');
    }

    const { to, resourceId, value } = options;

    const { request } = await this.publicClient.simulateContract({
      address: this.address,
      abi: X402_ABI,
      functionName: 'payEth',
      args: [to, resourceId],
      value,
      account: this.walletClient.account,
    });

    return this.walletClient.writeContract(request);
  }

  /**
   * Verify a payment exists
   */
  async verify(paymentId: Hex): Promise<{
    exists: boolean;
    receipt: PaymentReceipt;
  }> {
    const [exists, receipt] = await this.publicClient.readContract({
      address: this.address,
      abi: X402_ABI,
      functionName: 'verify',
      args: [paymentId],
    });

    return {
      exists,
      receipt: {
        from: receipt.from,
        to: receipt.to,
        token: receipt.token,
        amount: receipt.amount,
        resourceId: receipt.resourceId,
        timestamp: receipt.timestamp,
      },
    };
  }

  /**
   * Helper: Create resource ID from string
   */
  static resourceId(resource: string): Hex {
    return keccak256(toHex(resource));
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
