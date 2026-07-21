/**
 * w3cash_simulate_intent (Phase-1 item 14) — a FREE, pre-sign dry-run.
 *
 * Given the same {chain, initiator, conditions, actions} body as /compile-intent, this
 * answers "would this fire right now / which gate is blocking / what setup you still need"
 * WITHOUT signing and WITHOUT returning the compiled payload (the paid compile's deliverable).
 *
 * It targets the DEPLOYED (Legacy) processor + adapters: conditions (gates) are evaluated by
 * eth_call-ing the gate adapter exactly as the processor would (from = processor, so the
 * OnlyProcessor pin passes); actions' prerequisites are read as the initiator's token balance +
 * the standing allowance to the adapter that will pull it (Legacy adapters pull
 * transferFrom(initiator)). The RPC reader is injected so the verdict logic is unit-testable.
 *
 * FIDELITY (honest): gates are evaluated at the CURRENT block, not the future fire time; a
 * co-signer (signature) gate can't be evaluated without the co-signature. Any RPC failure
 * degrades that one check to "unknown" — it never throws.
 */
import {
  keccak256,
  toBytes,
  encodeFunctionData,
  decodeFunctionResult,
  decodeAbiParameters,
  parseAbiParameters,
  getAddress,
  type Hex,
  type Address,
} from "viem";
import {
  compileIntent,
  resolveChain,
  type CompileRequest,
  type ChainConfig,
  type ActionRequest,
} from "./w3cash/encode.js";

/** abi.encode(keccak256("PAUSE_EXECUTION")) — the 32-byte word a paused gate returns. */
const PAUSE_WORD = keccak256(toBytes("PAUSE_EXECUTION"));

const EXECUTE_ABI = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "initiator", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [{ name: "", type: "bytes" }],
  },
] as const;

const ZERO: Address = "0x0000000000000000000000000000000000000000";

/** Injected chain reader (viem-backed in prod, mockable in tests). */
export interface SimReader {
  ethCall(to: Address, from: Address, data: Hex): Promise<Hex>;
  balanceOf(token: Address, holder: Address): Promise<bigint>;
  allowance(token: Address, holder: Address, spender: Address): Promise<bigint>;
  gasPrice(): Promise<bigint>;
}

export type CheckStatus = "pass" | "blocked" | "unknown" | "not-simulatable";

export interface GateResult {
  readonly index: number;
  readonly type: string;
  readonly status: CheckStatus;
  readonly detail: string;
}

export interface SetupResult {
  readonly action: string;
  readonly token: Address;
  readonly spender: Address;
  readonly needed: string;
  readonly balance: string | null;
  readonly allowance: string | null;
  readonly ok: boolean;
  readonly fix: string | null;
}

export interface SimulateResult {
  readonly verdict: "would-fire" | "blocked" | "needs-setup" | "unknown";
  readonly chainId: number;
  readonly initiator: Address | null;
  readonly gates: readonly GateResult[];
  readonly setup: readonly SetupResult[];
  readonly notes: readonly string[];
}

/** Map an action to the (token, spender-adapter, amount) the initiator must have ready. */
function actionSetup(
  action: ActionRequest,
  cfg: ChainConfig
): { token: Address; spender: Address; amount: bigint; label: string } | null {
  const adapters = cfg.adapters;
  const amt = (v: unknown): bigint => BigInt(String(v));
  switch (action.type) {
    case "transfer":
      if (!adapters.transfer) return null;
      return { token: getAddress(action.token), spender: adapters.transfer.address, amount: amt(action.amount), label: "transfer" };
    case "swap":
      if (!adapters.swap) return null;
      return { token: getAddress(action.tokenIn), spender: adapters.swap.address, amount: amt(action.amountIn), label: "swap" };
    case "aaveDeposit":
      if (!adapters.aave) return null;
      return { token: getAddress(action.token), spender: adapters.aave.address, amount: amt(action.amount), label: "aaveDeposit" };
    case "bridge":
      if (!adapters.bridge) return null;
      return { token: getAddress(action.inputToken), spender: adapters.bridge.address, amount: amt(action.inputAmount), label: "bridge" };
    // approve grants (no prereq); aave withdraw returns funds; wrap(true) uses native msg.value.
    default:
      return null;
  }
}

/** Evaluate one condition step (from the compiled steps) against current chain state. */
async function evalGate(
  step: { index: number; type: string; target: Address; input: Hex },
  initiator: Address,
  cfg: ChainConfig,
  reader: SimReader
): Promise<GateResult> {
  const { index, type, target, input } = step;

  if (type === "signature") {
    return { index, type, status: "not-simulatable", detail: "requires a co-signer signature; provide it, then re-simulate" };
  }

  if (type === "gasPrice") {
    // Decode (operator, threshold) and compare to the current network gas price.
    try {
      const [operator, threshold] = decodeAbiParameters(parseAbiParameters("uint8, uint256"), input) as [number, bigint];
      const gp = await reader.gasPrice();
      const ops = ["lt", "gt", "lte", "gte"];
      const pass = operator === 0 ? gp < threshold : operator === 1 ? gp > threshold : operator === 2 ? gp <= threshold : gp >= threshold;
      return {
        index, type, status: pass ? "pass" : "blocked",
        detail: `current gas ${gp.toString()} wei ${ops[operator] ?? "?"} threshold ${threshold.toString()} wei => ${pass ? "met" : "not met"}`,
      };
    } catch {
      return { index, type, status: "unknown", detail: "could not read current gas price" };
    }
  }

  // All other gates: eth_call the adapter exactly as the processor does (from = processor).
  try {
    const data = encodeFunctionData({ abi: EXECUTE_ABI, functionName: "execute", args: [initiator, input] });
    const ret = await reader.ethCall(target, cfg.processor, data);
    const inner = decodeFunctionResult({ abi: EXECUTE_ABI, functionName: "execute", data: ret }) as Hex;
    if (inner === "0x" || inner.length <= 2) return { index, type, status: "pass", detail: "gate currently met" };
    if (inner.toLowerCase() === PAUSE_WORD.toLowerCase()) return { index, type, status: "blocked", detail: "gate not met at the current block" };
    return { index, type, status: "unknown", detail: "unexpected gate return" };
  } catch {
    return { index, type, status: "unknown", detail: "gate eth_call failed (rpc error or missing state)" };
  }
}

/** Core dry-run: compile internally for validation + gate targets, then read chain state. */
export async function simulateIntent(request: CompileRequest, reader: SimReader): Promise<SimulateResult> {
  const cfg = resolveChain(request.chain);
  const initiator = request.initiator ? getAddress(request.initiator) : null;
  const notes: string[] = [];

  // Compile internally (validates the request + gives gate targets/inputs). NOT returned.
  const intent = compileIntent(request);
  const condSteps = intent.steps.filter((s) => s.kind === "condition");

  // Gates.
  const gates: GateResult[] = [];
  for (const s of condSteps) {
    gates.push(await evalGate({ index: s.index, type: s.type, target: s.target, input: s.input }, initiator ?? ZERO, cfg, reader));
  }
  if (!initiator) notes.push("no `initiator` supplied — balance/allowance setup checks were skipped; pass `initiator` for a full readiness verdict");

  // Action prerequisites (Legacy custody: adapters pull transferFrom(initiator)).
  const setup: SetupResult[] = [];
  const actions = request.actions ?? [];
  if (initiator) {
    for (const action of actions) {
      const s = actionSetup(action, cfg);
      if (!s) continue;
      let balance: bigint | null = null;
      let allowance: bigint | null = null;
      try { balance = await reader.balanceOf(s.token, initiator); } catch { /* unknown */ }
      try { allowance = await reader.allowance(s.token, initiator, s.spender); } catch { /* unknown */ }
      const balOk = balance === null ? true : balance >= s.amount; // unknown => don't fail the verdict
      const allowOk = allowance === null ? true : allowance >= s.amount;
      const ok = balOk && allowOk;
      let fix: string | null = null;
      if (allowance !== null && allowance < s.amount) fix = `approve ${s.token} for ${s.spender} (the ${s.label} adapter) for at least ${s.amount.toString()}`;
      else if (balance !== null && balance < s.amount) fix = `top up ${s.token}: need ${s.amount.toString()}, have ${balance.toString()}`;
      setup.push({
        action: s.label, token: s.token, spender: s.spender, needed: s.amount.toString(),
        balance: balance === null ? null : balance.toString(),
        allowance: allowance === null ? null : allowance.toString(),
        ok, fix,
      });
    }
  }

  // Verdict: setup-missing > gate-blocked > unknown > would-fire.
  const anySetupMissing = setup.some((x) => !x.ok);
  const anyBlocked = gates.some((g) => g.status === "blocked");
  const anyUnknown = gates.some((g) => g.status === "unknown") || (initiator !== null && setup.some((x) => x.balance === null || x.allowance === null));
  const verdict: SimulateResult["verdict"] = anySetupMissing ? "needs-setup" : anyBlocked ? "blocked" : anyUnknown ? "unknown" : "would-fire";

  notes.push("Preview only — gates are evaluated at the CURRENT block, not the future fire time. This is FREE and returns NO signable payload; POST /compile-intent to get the signable intent.");
  return { verdict, chainId: cfg.chainId, initiator, gates, setup, notes };
}

// ---------------------------------------------------------------------------
// viem-backed reader (production)
// ---------------------------------------------------------------------------

/** Per-chain public RPC, resolved LAZILY (override with SIM_RPC_<chainId> env). */
const DEFAULT_RPC: Record<number, string> = {
  84532: "https://sepolia.base.org",
  1952: "https://testrpc.xlayer.tech",
  196: "https://rpc.xlayer.tech",
};
function rpcUrl(chainId: number): string | undefined {
  return process.env[`SIM_RPC_${chainId}`] ?? DEFAULT_RPC[chainId];
}

const ERC20_ABI = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ name: "o", type: "address" }, { name: "s", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

/** A reader that fails every call — used when no RPC is configured (=> all checks "unknown"). */
const NULL_READER: SimReader = {
  ethCall: () => Promise.reject(new Error("no rpc")),
  balanceOf: () => Promise.reject(new Error("no rpc")),
  allowance: () => Promise.reject(new Error("no rpc")),
  gasPrice: () => Promise.reject(new Error("no rpc")),
};

/**
 * Server entry point: resolve the chain, build its RPC reader (or degrade to NULL_READER),
 * and run the dry-run. Throws ValidationError (from compileIntent) on a malformed request.
 */
export async function simulate(request: CompileRequest): Promise<SimulateResult> {
  const cfg = resolveChain(request.chain);
  const reader = (await createViemReader(cfg.chainId)) ?? NULL_READER;
  return simulateIntent(request, reader);
}

/** Build a viem-backed reader for a chain, or null if no RPC is configured. */
export async function createViemReader(chainId: number): Promise<SimReader | null> {
  const url = rpcUrl(chainId);
  if (!url) return null;
  const { createPublicClient, http } = await import("viem");
  // No retries: a free preview shouldn't hammer the RPC; a single failed attempt
  // degrades that check to "unknown" instantly rather than backing off for seconds.
  const client = createPublicClient({ transport: http(url, { retryCount: 0, timeout: 8_000 }) });
  return {
    async ethCall(to, from, data) {
      const res = await client.call({ to, account: from, data });
      return (res.data ?? "0x") as Hex;
    },
    balanceOf: (token, holder) =>
      client.readContract({ address: token, abi: ERC20_ABI, functionName: "balanceOf", args: [holder] }) as Promise<bigint>,
    allowance: (token, holder, spender) =>
      client.readContract({ address: token, abi: ERC20_ABI, functionName: "allowance", args: [holder, spender] }) as Promise<bigint>,
    gasPrice: () => client.getGasPrice(),
  };
}
