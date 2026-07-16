import { BaseError } from 'viem';

// Turn any thrown value (viem error, wallet RPC error, string) into a readable line.
export function errorMessage(err: unknown): string {
  if (err instanceof BaseError) {
    return err.shortMessage || err.message;
  }
  if (isRpcRejection(err)) {
    return 'Request rejected in wallet.';
  }
  if (err instanceof Error) {
    return err.message;
  }
  if (typeof err === 'string') {
    return err;
  }
  return 'Unexpected error.';
}

function isRpcRejection(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: number }).code === 4001
  );
}

// 0xabc123…deadbeef
export function shorten(hex: string, lead = 10, tail = 8): string {
  if (hex.length <= lead + tail + 1) return hex;
  return `${hex.slice(0, lead)}…${hex.slice(-tail)}`;
}

// Format a 6-decimal USDC base-unit string/bigint as a human amount.
export function formatUsdc(base: bigint): string {
  const whole = base / 1_000_000n;
  const frac = base % 1_000_000n;
  if (frac === 0n) return `${whole}`;
  const fracStr = frac.toString().padStart(6, '0').replace(/0+$/, '');
  return `${whole}.${fracStr}`;
}
