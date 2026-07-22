/**
 * Per-chain indexing config. Each entry is the deployed processor to watch + how to page
 * eth_getLogs (X Layer caps ranges at 100 blocks — learned the hard way). Overridable via env
 * (RPC_<id>, START_<id>) so operators can point at their own RPC + the real deploy block.
 */
export interface ChainCfg {
  readonly chainId: number;
  readonly name: string;
  readonly rpc: string;
  readonly processor: string;
  readonly startBlock: number; // the processor's deploy block (MUST be set per deployment)
  readonly logChunk: number;   // max blocks per eth_getLogs (RPC-dependent cap)
}

const DEFAULTS: ChainCfg[] = [
  { chainId: 84532, name: "Base Sepolia", rpc: "https://sepolia.base.org", processor: "0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE", startBlock: 0, logChunk: 2000 },
  { chainId: 1952, name: "X Layer testnet", rpc: "https://testrpc.xlayer.tech", processor: "0x3C06E44bD4d09328a4c374174b8e325c0C674b6E", startBlock: 0, logChunk: 100 },
  { chainId: 196, name: "X Layer mainnet", rpc: "https://rpc.xlayer.tech", processor: "0x3C06E44bD4d09328a4c374174b8e325c0C674b6E", startBlock: 0, logChunk: 100 },
];

/** Resolve the chain configs, applying env overrides (RPC_<id>, START_<id>). */
export function resolveChains(env: Record<string, string | undefined>): ChainCfg[] {
  return DEFAULTS.map((c) => ({
    ...c,
    rpc: env[`RPC_${c.chainId}`] ?? c.rpc,
    startBlock: env[`START_${c.chainId}`] ? Number(env[`START_${c.chainId}`]) : c.startBlock,
  }));
}
