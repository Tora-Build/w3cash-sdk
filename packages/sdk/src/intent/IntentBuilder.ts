import {
  type Address,
  type Hex,
  encodeFunctionData,
  encodeAbiParameters,
  parseAbiParameters,
  keccak256,
} from 'viem';
import type {
  IntentAction,
  IntentCondition,
  BuiltIntent,
  TransferParams,
  SwapParams,
  YieldParams,
  ApproveParams,
  TimeConditionParams,
  QueryConditionParams,
  QueryOperator,
} from './types';
import { QUERY_OPERATORS } from './types';

/**
 * Fluent builder for W3Cash intents
 * 
 * @example
 * ```typescript
 * const intent = new IntentBuilder()
 *   .action('transfer', { token: USDC, to: recipient, amount: 100n * 10n**6n })
 *   .condition('time', { after: Date.now() / 1000 + 3600 }) // 1 hour
 *   .build();
 * ```
 */
export class IntentBuilder {
  private actions: IntentAction[] = [];
  private conditions: IntentCondition[] = [];
  private chainIndex: number = 0; // Local chain by default

  /**
   * Add a transfer action
   */
  transfer(params: TransferParams): this {
    this.actions.push({ type: 'transfer', params });
    return this;
  }

  /**
   * Add a swap action
   */
  swap(params: SwapParams): this {
    this.actions.push({ type: 'swap', params });
    return this;
  }

  /**
   * Add a yield action (deposit/withdraw)
   */
  yield(params: YieldParams): this {
    this.actions.push({ type: 'yield', params });
    return this;
  }

  /**
   * Add an approve action
   */
  approve(params: ApproveParams): this {
    this.actions.push({ type: 'approve', params });
    return this;
  }

  /**
   * Add a generic action
   */
  action(type: 'transfer', params: TransferParams): this;
  action(type: 'swap', params: SwapParams): this;
  action(type: 'yield', params: YieldParams): this;
  action(type: 'approve', params: ApproveParams): this;
  action(type: string, params: any): this {
    this.actions.push({ type: type as any, params });
    return this;
  }

  /**
   * Add a time-based condition
   */
  afterTime(timestamp: number): this {
    this.conditions.push({
      type: 'time',
      params: { after: timestamp },
    });
    return this;
  }

  /**
   * Add a block-based condition
   */
  afterBlock(blockNumber: number): this {
    this.conditions.push({
      type: 'block',
      params: { afterBlock: blockNumber },
    });
    return this;
  }

  /**
   * Add a query condition (wait until on-chain state matches)
   */
  when(target: Address, data: Hex, operator: QueryOperator, value: bigint): this {
    this.conditions.push({
      type: 'query',
      params: { target, data, operator, value },
    });
    return this;
  }

  /**
   * Add a balance condition (syntactic sugar for query)
   */
  whenBalance(token: Address, account: Address, operator: QueryOperator, amount: bigint): this {
    const data = encodeFunctionData({
      abi: [{ name: 'balanceOf', type: 'function', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] }],
      functionName: 'balanceOf',
      args: [account],
    });
    return this.when(token, data, operator, amount);
  }

  /**
   * Add a generic condition
   */
  condition(type: 'time', params: TimeConditionParams): this;
  condition(type: 'query', params: QueryConditionParams): this;
  condition(type: string, params: any): this {
    this.conditions.push({ type: type as any, params });
    return this;
  }

  /**
   * Set target chain index
   */
  onChain(chainIndex: number): this {
    this.chainIndex = chainIndex;
    return this;
  }

  /**
   * Build the intent
   */
  build(adapters: AdapterAddresses): BuiltIntent {
    if (this.actions.length === 0) {
      throw new Error('Intent must have at least one action');
    }

    // Build operations array
    const operations: Hex[] = [];
    const inputs: Hex[] = [];

    // Add conditions first (they gate the actions)
    for (const condition of this.conditions) {
      const { operation, input } = this.encodeCondition(condition, adapters);
      operations.push(operation);
      inputs.push(input);
    }

    // Add actions
    for (const action of this.actions) {
      const { operation, input } = this.encodeAction(action, adapters);
      operations.push(operation);
      inputs.push(input);
    }

    // Encode payload
    const payload = encodeAbiParameters(
      parseAbiParameters('bytes[], bytes[]'),
      [operations, inputs]
    );

    const payloadHash = keccak256(payload);

    // Encode header (seq=0, length, payloadHash)
    const header = encodeAbiParameters(
      parseAbiParameters('uint256, uint256, bytes32'),
      [0n, BigInt(operations.length), payloadHash]
    );

    // Encode instruction (header, payload)
    const instruction = encodeAbiParameters(
      parseAbiParameters('bytes, bytes'),
      [header, payload]
    );

    return {
      instruction,
      payloadHash,
      summary: this.generateSummary(),
    };
  }

  private encodeCondition(condition: IntentCondition, adapters: AdapterAddresses): { operation: Hex; input: Hex } {
    if (condition.type === 'time') {
      const params = condition.params as TimeConditionParams;
      const waitType = params.after !== undefined ? 0 : 1; // TIMESTAMP or BLOCK
      const value = params.after ?? params.afterBlock ?? 0;

      const input = encodeAbiParameters(
        parseAbiParameters('(uint8, uint256, address, int256)'),
        [[waitType, BigInt(value), '0x0000000000000000000000000000000000000000' as Address, 0n]]
      );

      return {
        operation: this.encodeOperation(adapters.wait, 0n),
        input,
      };
    }

    if (condition.type === 'query') {
      const params = condition.params as QueryConditionParams;
      const operatorId = QUERY_OPERATORS[params.operator];

      const input = encodeAbiParameters(
        parseAbiParameters('address, bytes, uint8, uint256'),
        [params.target, params.data, operatorId, params.value]
      );

      return {
        operation: this.encodeOperation(adapters.query, 0n),
        input,
      };
    }

    throw new Error(`Unknown condition type: ${condition.type}`);
  }

  private encodeAction(action: IntentAction, adapters: AdapterAddresses): { operation: Hex; input: Hex } {
    // For now, placeholder encoding - real implementation depends on specific adapters
    if (action.type === 'transfer') {
      const params = action.params as TransferParams;
      // Transfer would use an ERC20 transfer adapter
      const input = encodeAbiParameters(
        parseAbiParameters('address, address, uint256'),
        [params.token, params.to, params.amount]
      );
      return {
        operation: this.encodeOperation(adapters.transfer ?? adapters.wait, 0n),
        input,
      };
    }

    if (action.type === 'yield') {
      const params = action.params as YieldParams;
      // Yield uses Aave adapter
      const input = encodeAbiParameters(
        parseAbiParameters('address, uint256, bool'),
        [params.token, params.amount, params.action === 'deposit']
      );
      return {
        operation: this.encodeOperation(adapters.aave ?? adapters.wait, 0n),
        input,
      };
    }

    // Fallback for unimplemented actions
    return {
      operation: this.encodeOperation(adapters.wait, 0n),
      input: '0x' as Hex,
    };
  }

  private encodeOperation(adapterAddress: Address, value: bigint): Hex {
    // Operation: (chain, amb, fee, target, selector, value)
    return encodeAbiParameters(
      parseAbiParameters('uint8, uint8, uint64, address, bytes8, uint112'),
      [this.chainIndex, 0, 0n, adapterAddress, '0x0000000000000000' as Hex, value]
    );
  }

  private generateSummary(): string {
    const parts: string[] = [];

    if (this.conditions.length > 0) {
      for (const c of this.conditions) {
        if (c.type === 'time') {
          const params = c.params as TimeConditionParams;
          if (params.after) {
            parts.push(`Wait until ${new Date(params.after * 1000).toISOString()}`);
          } else if (params.afterBlock) {
            parts.push(`Wait until block ${params.afterBlock}`);
          }
        } else if (c.type === 'query') {
          parts.push('Wait until query condition met');
        }
      }
    }

    for (const a of this.actions) {
      if (a.type === 'transfer') {
        const p = a.params as TransferParams;
        parts.push(`Transfer ${p.amount} to ${p.to}`);
      } else if (a.type === 'swap') {
        const p = a.params as SwapParams;
        parts.push(`Swap ${p.amountIn} for ${p.tokenOut}`);
      } else if (a.type === 'yield') {
        const p = a.params as YieldParams;
        parts.push(`${p.action} ${p.amount} on ${p.protocol}`);
      } else {
        parts.push(`${a.type}`);
      }
    }

    return parts.join(' → ');
  }
}

/**
 * Adapter addresses needed for encoding
 */
export interface AdapterAddresses {
  wait: Address;
  query: Address;
  aave?: Address;
  transfer?: Address;
  approve?: Address;
  swap?: Address;
  wrap?: Address;
}
