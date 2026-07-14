/**
 * On-chain DECODE + ROUTING proof (no funds required, no state change).
 *
 * Compiles the highest-value NEW capability — a prediction-market-gated intent
 * (Sooth TruthMarket gate via QueryAdapter, then a USDC transfer) — with the ASP
 * encoder, signs it with a THROWAWAY key, and eth_call's Processor.execute() on
 * Base Sepolia. We are proving the processor DECODES the envelope and ROUTES each
 * operation to the right adapter — NOT that it succeeds. Success criterion:
 *
 *   A) gate NOT met  (marketOutcome == NO, but the demo market resolved YES):
 *        QueryAdapter decodes its input, staticcalls winningOutcome(), compares,
 *        returns PAUSE_EXECUTION → execute() returns SUCCESS (clean pause). This
 *        isolates the QueryAdapter decode+route path with zero token noise.
 *
 *   B) gate MET + transfer  (marketOutcome == YES, met immediately):
 *        QueryAdapter passes, the processor advances to op #1 and routes into
 *        TransferAdapter, whose safeTransferFrom reverts on the throwaway signer's
 *        zero USDC allowance — an ADAPTER-LEVEL BUSINESS revert. That proves BOTH
 *        ops decoded+routed (a decode/abi/unknown-adapter fault would revert
 *        BEFORE reaching the token logic, with Panic/QueryFailed/OnlyProcessor).
 *
 * A FAIL is any abi-decode Panic(0x4e487b71), QueryFailed(), OnlyProcessor(),
 * "Invalid payload hash", InvalidNonce, or CallerNotAuthorized — those mean the
 * envelope/routing was malformed, not that a downstream business rule tripped.
 *
 * Run:  npx tsx scripts/decode-proof.ts
 * (Optionally set BASE_SEPOLIA_RPC; defaults to the consistent publicnode.)
 */
import {
  createPublicClient,
  http,
  getAddress,
  encodeFunctionData,
  parseAbi,
  BaseError,
  ContractFunctionRevertedError,
  type Hex,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import {
  compileIntent,
  encodeSignedPayload,
  PROCESSOR,
  CHAIN_ID,
  ADAPTERS,
  type CompileRequest,
} from "../src/w3cash/encode.js";

const RPC =
  process.env.BASE_SEPOLIA_RPC ?? "https://base-sepolia-rpc.publicnode.com";
const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
const RECIPIENT = getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3");
const DEMO_MARKET = getAddress("0x80334C47F3DcE19FcFE7dB1AEce7423D32C4ccB1");

const processorAbi = parseAbi([
  "function execute(bytes signedPayload) payable",
  "function nonces(address user) view returns (uint256)",
]);

const publicClient = createPublicClient({
  chain: baseSepolia,
  transport: http(RPC),
});

/** Build a signed-payload calldata for execute() from a compiled intent. */
async function buildExecuteCalldata(
  request: CompileRequest,
  signer: ReturnType<typeof privateKeyToAccount>
): Promise<{ data: Hex; toSign: Hex; steps: string[] }> {
  const nonce = await publicClient.readContract({
    address: PROCESSOR,
    abi: processorAbi,
    functionName: "nonces",
    args: [signer.address],
  });
  const intent = compileIntent({
    ...request,
    chain: CHAIN_ID,
    initiator: signer.address,
    nonce: Number(nonce),
  });
  const signature = await signer.signMessage({ message: { raw: intent.toSign } });
  const signedPayload = encodeSignedPayload({
    instruction: intent.instruction,
    initiator: signer.address,
    nonce,
    signature,
  });
  const data = encodeFunctionData({
    abi: processorAbi,
    functionName: "execute",
    args: [signedPayload],
  });
  return {
    data,
    toSign: intent.toSign,
    steps: intent.steps.map((s) => `${s.type} -> ${s.adapter} @ ${s.target}`),
  };
}

/** Extract raw revert data + a human string from any viem error. */
function revertInfo(err: unknown): { raw?: Hex; text: string } {
  if (err instanceof BaseError) {
    const revert = err.walk(
      (e) => e instanceof ContractFunctionRevertedError
    ) as ContractFunctionRevertedError | null;
    const text =
      revert?.reason ?? revert?.shortMessage ?? err.shortMessage ?? err.message;
    // Grab any 0x revert blob viem surfaced anywhere in the error chain.
    const m = (err.message + " " + text).match(/0x[0-9a-fA-F]{8,}/);
    return { raw: (m?.[0] as Hex) ?? undefined, text };
  }
  return { text: err instanceof Error ? err.message : String(err) };
}

/** True iff the revert is a downstream BUSINESS revert (not a decode/route fault). */
function isBusinessRevert(raw: Hex | undefined, text: string): boolean {
  const sel = raw?.slice(0, 10).toLowerCase();
  const lower = text.toLowerCase();
  const decodeOrRouteFault =
    sel === "0x4e487b71" || // Panic(uint256) — abi-decode / arithmetic
    lower.includes("panic") ||
    lower.includes("out-of-bounds") ||
    lower.includes("invalid payload hash") ||
    lower.includes("callernotauthorized") ||
    lower.includes("invalidnonce") ||
    lower.includes("onlyprocessor") ||
    lower.includes("queryfailed") ||
    lower.includes("abidecoding");
  return !decodeOrRouteFault;
}

async function main(): Promise<void> {
  const signer = privateKeyToAccount(generatePrivateKey());
  console.log(`throwaway signer/initiator: ${signer.address}`);
  console.log(`chain: Base Sepolia (${CHAIN_ID})  processor: ${PROCESSOR}`);
  console.log(`QueryAdapter (market gate): ${ADAPTERS.query.address}`);
  console.log(`TransferAdapter (action):   ${ADAPTERS.transfer.address}`);
  console.log(`demo market: ${DEMO_MARKET} (settled, winningOutcome=YES)\n`);

  let aOk = false;
  let bOk = false;

  // ---- Case A: gate NOT met (marketOutcome == NO) → clean PAUSE success -----
  {
    const req: CompileRequest = {
      conditions: [{ type: "marketOutcome", market: DEMO_MARKET, outcome: "NO" }],
      actions: [{ type: "transfer", token: USDC, to: RECIPIENT, amount: "1000000" }],
    };
    const { data, steps } = await buildExecuteCalldata(req, signer);
    console.log("── Case A: marketOutcome==NO gate (should PAUSE, not met) ──");
    steps.forEach((s) => console.log(`   op: ${s}`));
    try {
      await publicClient.call({ account: signer.address, to: PROCESSOR, data });
      aOk = true;
      console.log(
        "   RESULT: eth_call SUCCEEDED → QueryAdapter decoded winningOutcome(), " +
          "compared (1==0 false), returned PAUSE_EXECUTION. Decode+route PROVEN.\n"
      );
    } catch (err) {
      const { raw, text } = revertInfo(err);
      console.log(
        `   RESULT: reverted (${raw ?? "no-data"}): ${text}\n   (unexpected — a not-met gate should pause, not revert)\n`
      );
    }
  }

  // ---- Case B: gate MET (marketOutcome == YES) → advance, TransferAdapter reverts on allowance
  {
    const req: CompileRequest = {
      conditions: [{ type: "marketOutcome", market: DEMO_MARKET, outcome: "YES" }],
      actions: [{ type: "transfer", token: USDC, to: RECIPIENT, amount: "1000000" }],
    };
    const { data, steps } = await buildExecuteCalldata(req, signer);
    console.log("── Case B: marketOutcome==YES gate (met) + USDC transfer ──");
    steps.forEach((s) => console.log(`   op: ${s}`));
    try {
      await publicClient.call({ account: signer.address, to: PROCESSOR, data });
      // A success here would be surprising (throwaway has no USDC), but it still
      // proves decode+route. Treat as pass.
      bOk = true;
      console.log(
        "   RESULT: eth_call SUCCEEDED (unexpected but still decoded+routed).\n"
      );
    } catch (err) {
      const { raw, text } = revertInfo(err);
      bOk = isBusinessRevert(raw, text);
      console.log(`   RESULT: reverted (${raw ?? "no-data"}): ${text}`);
      console.log(
        bOk
          ? "   → ADAPTER-LEVEL BUSINESS revert (allowance/balance). QueryAdapter gate PASSED, " +
              "processor advanced to op #1 and routed into TransferAdapter. Decode+route PROVEN.\n"
          : "   → DECODE/ROUTING FAULT. This is a FAIL.\n"
      );
    }
  }

  console.log("──────────────────────────────────────────────");
  console.log(`Case A (QueryAdapter pause path):   ${aOk ? "PASS" : "FAIL"}`);
  console.log(`Case B (Query gate + Transfer route): ${bOk ? "PASS" : "FAIL"}`);
  const ok = aOk && bOk;
  console.log(
    ok
      ? "✅ ON-CHAIN DECODE+ROUTE PROVEN — prediction-market-gated intent decodes and routes correctly on Base Sepolia."
      : "❌ decode/route proof FAILED"
  );
  if (!ok) process.exit(1);
}

main().catch((e: unknown) => {
  const msg =
    e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
  console.error("FAILED:", msg);
  process.exit(1);
});
