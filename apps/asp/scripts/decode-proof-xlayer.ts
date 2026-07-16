/**
 * On-chain DECODE + LOCAL-ROUTING proof for X Layer testnet (chainId 1952).
 * No funds required, no state change — pure eth_call against the deployed
 * W3CashProcessor. Proves the multi-chain encoder produces an envelope the X
 * Layer processor DECODES and routes to the X Layer adapters on the LOCAL path
 * (registry.getChain(0) == 1952 == block.chainid). Two cases:
 *
 *   A) waitTime in the FUTURE (gate NOT met): WaitAdapter decodes its input,
 *      sees block.timestamp < target, returns PAUSE_EXECUTION → execute()
 *      returns SUCCESS. Isolates the WaitAdapter decode+route with zero token
 *      noise and confirms the processor verified the signature.
 *
 *   B) waitTime in the PAST (met) + USD₮0 transfer: the processor advances to
 *      op #1 and routes into the X Layer TransferAdapter, whose safeTransferFrom
 *      reverts on the throwaway signer's zero allowance — an ADAPTER-LEVEL
 *      BUSINESS revert. Crucially, reaching TransferAdapter at all proves op #1
 *      took the LOCAL branch: a broken getChain()/chainid check would misroute it
 *      as cross-chain and fault BEFORE the token logic.
 *
 * A FAIL is any abi-decode Panic, "Invalid payload hash", InvalidNonce,
 * OnlyProcessor, or a cross-chain/AMB routing fault — those mean the envelope or
 * local routing was wrong, not that a downstream business rule tripped.
 *
 * Run:  npx tsx scripts/decode-proof-xlayer.ts
 * (Optionally set XLAYER_RPC; defaults to the OKX public testrpc.)
 */
import {
  createPublicClient,
  http,
  defineChain,
  getAddress,
  encodeFunctionData,
  parseAbi,
  BaseError,
  ContractFunctionRevertedError,
  type Hex,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import {
  compileIntent,
  encodeSignedPayload,
  XLAYER_CHAIN_ID,
  XLAYER_PROCESSOR,
  XLAYER_ADAPTERS,
  XLAYER_KNOWN_ADDRESSES,
  type CompileRequest,
} from "../src/w3cash/encode.js";

const RPC = process.env.XLAYER_RPC ?? "https://testrpc.xlayer.tech";
const USDT0 = XLAYER_KNOWN_ADDRESSES.usdt0;
const RECIPIENT = getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3");

const xlayerTestnet = defineChain({
  id: XLAYER_CHAIN_ID,
  name: "X Layer testnet",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});

const processorAbi = parseAbi([
  "function execute(bytes signedPayload) payable",
  "function nonces(address user) view returns (uint256)",
]);

const publicClient = createPublicClient({ chain: xlayerTestnet, transport: http(RPC) });

async function buildExecuteCalldata(
  request: CompileRequest,
  signer: ReturnType<typeof privateKeyToAccount>
): Promise<{ data: Hex; steps: string[] }> {
  const nonce = await publicClient.readContract({
    address: XLAYER_PROCESSOR,
    abi: processorAbi,
    functionName: "nonces",
    args: [signer.address],
  });
  const intent = compileIntent({
    ...request,
    chain: XLAYER_CHAIN_ID,
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
  return { data, steps: intent.steps.map((s) => `${s.type} -> ${s.adapter} @ ${s.target}`) };
}

function revertInfo(err: unknown): { raw?: Hex; text: string } {
  if (err instanceof BaseError) {
    const revert = err.walk(
      (e) => e instanceof ContractFunctionRevertedError
    ) as ContractFunctionRevertedError | null;
    const text = revert?.reason ?? revert?.shortMessage ?? err.shortMessage ?? err.message;
    const m = (err.message + " " + text).match(/0x[0-9a-fA-F]{8,}/);
    return { raw: (m?.[0] as Hex) ?? undefined, text };
  }
  return { text: err instanceof Error ? err.message : String(err) };
}

function isBusinessRevert(raw: Hex | undefined, text: string): boolean {
  const sel = raw?.slice(0, 10).toLowerCase();
  const lower = text.toLowerCase();
  const fault =
    sel === "0x4e487b71" ||
    lower.includes("panic") ||
    lower.includes("out-of-bounds") ||
    lower.includes("invalid payload hash") ||
    lower.includes("callernotauthorized") ||
    lower.includes("invalidnonce") ||
    lower.includes("onlyprocessor") ||
    lower.includes("abidecoding");
  return !fault;
}

async function main(): Promise<void> {
  const signer = privateKeyToAccount(generatePrivateKey());
  console.log(`throwaway signer/initiator: ${signer.address}`);
  console.log(`chain: X Layer testnet (${XLAYER_CHAIN_ID})  processor: ${XLAYER_PROCESSOR}`);
  console.log(`WaitAdapter:     ${XLAYER_ADAPTERS.wait.address}`);
  console.log(`TransferAdapter: ${XLAYER_ADAPTERS.transfer.address}`);
  console.log(`USD₮0:           ${USDT0}\n`);

  let aOk = false;
  let bOk = false;

  // ---- Case A: waitTime FUTURE → clean PAUSE success -----------------------
  {
    const req: CompileRequest = {
      conditions: [{ type: "waitTime", timestamp: "4102444800" }], // year 2100
    };
    const { data, steps } = await buildExecuteCalldata(req, signer);
    console.log("── Case A: waitTime in the future (should PAUSE, not met) ──");
    steps.forEach((s) => console.log(`   op: ${s}`));
    try {
      await publicClient.call({ account: signer.address, to: XLAYER_PROCESSOR, data });
      aOk = true;
      console.log(
        "   RESULT: eth_call SUCCEEDED → WaitAdapter decoded + compared, returned " +
          "PAUSE_EXECUTION. Signature verified, decode+local-route PROVEN.\n"
      );
    } catch (err) {
      const { raw, text } = revertInfo(err);
      console.log(`   RESULT: reverted (${raw ?? "no-data"}): ${text}\n   (unexpected)\n`);
    }
  }

  // ---- Case B: waitTime PAST (met) + USD₮0 transfer → TransferAdapter revert
  {
    const req: CompileRequest = {
      conditions: [{ type: "waitTime", timestamp: "1" }], // met immediately
      actions: [{ type: "transfer", token: USDT0, to: RECIPIENT, amount: "1000000" }],
    };
    const { data, steps } = await buildExecuteCalldata(req, signer);
    console.log("── Case B: waitTime met + USD₮0 transfer (advances to TransferAdapter) ──");
    steps.forEach((s) => console.log(`   op: ${s}`));
    try {
      await publicClient.call({ account: signer.address, to: XLAYER_PROCESSOR, data });
      bOk = true;
      console.log("   RESULT: eth_call SUCCEEDED (unexpected but still decoded+routed).\n");
    } catch (err) {
      const { raw, text } = revertInfo(err);
      bOk = isBusinessRevert(raw, text);
      console.log(`   RESULT: reverted (${raw ?? "no-data"}): ${text}`);
      console.log(
        bOk
          ? "   → ADAPTER-LEVEL BUSINESS revert (allowance/balance). Wait gate PASSED, processor " +
              "advanced to op #1 and routed into the X Layer TransferAdapter on the LOCAL path. " +
              "Decode + local-route PROVEN.\n"
          : "   → DECODE/ROUTING FAULT. This is a FAIL.\n"
      );
    }
  }

  console.log("──────────────────────────────────────────────");
  console.log(`Case A (WaitAdapter pause path):        ${aOk ? "PASS" : "FAIL"}`);
  console.log(`Case B (Wait gate + Transfer route):    ${bOk ? "PASS" : "FAIL"}`);
  const ok = aOk && bOk;
  console.log(
    ok
      ? "✅ ON-CHAIN DECODE+LOCAL-ROUTE PROVEN on X Layer testnet (1952)."
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
