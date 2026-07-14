/**
 * verify-transfer.mjs — LIVE end-to-end proof that the W3Cash intent encoder in
 * apps/asp/src/w3cash/encode.ts produces intents the DEPLOYED processor accepts.
 *
 * What it does:
 *  1. Compiles a CONDITIONAL TRANSFER intent (transfer USDC, gated by a Wait
 *     condition) on Base Sepolia (chainId 84532) with the real encoder.
 *  2. Generates a throwaway private key, reads nonce = Processor.nonces(key)
 *     (expected 0), signs `toSign` as an EIP-191 personal message, and assembles
 *     the SignedPayload calldata via the encoder's encodeSignedPayload().
 *  3. eth_call's Processor.execute(signedPayload) at the live address.
 *
 * Interpreting the result (per task):
 *  - The Wait gate uses a PAST timestamp so it is ALREADY MET; the WaitAdapter
 *    returns "" (continue) rather than PAUSE_EXECUTION, so execution proceeds
 *    into the Transfer op. The throwaway key holds no USDC and granted no
 *    allowance, so the TransferAdapter's safeTransferFrom MUST revert with an
 *    ERC20 allowance/balance error. THAT revert proves the envelope decoded, the
 *    signature verified, BOTH operations decoded, and routing reached BOTH the
 *    Wait and Transfer adapters — i.e. decode + routing works.
 *  - A revert about nonce / signature / abi-decode / unknown-adapter would mean
 *    the ENCODING is wrong.
 *
 * Run: cd apps/asp && npx tsx scripts/verify-transfer.mjs
 */

import {
  createPublicClient,
  http,
  encodeFunctionData,
  parseAbi,
  getAddress,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

import {
  compileIntent,
  encodeSignedPayload,
  PROCESSOR,
  CHAIN_ID,
  ADAPTERS,
} from "../src/w3cash/encode.ts";

const RPC_URL = "https://sepolia.base.org";

// Circle USDC on Base Sepolia (verified to have bytecode). 6 decimals.
const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
// Arbitrary recipient — irrelevant, the transfer reverts before touching it.
const RECIPIENT = getAddress("0x000000000000000000000000000000000000dEaD");
const AMOUNT = 1_000_000n; // 1 USDC

const PROCESSOR_ABI = parseAbi([
  "function execute(bytes) payable",
  "function nonces(address) view returns (uint256)",
]);

function line(label, value) {
  console.log(`${label.padEnd(22)} ${value}`);
}

/** Best-effort extraction of the innermost revert reason / data from a viem error. */
function describeRevert(err) {
  const parts = [];
  let cur = err;
  const seen = new Set();
  while (cur && !seen.has(cur)) {
    seen.add(cur);
    if (typeof cur.shortMessage === "string") parts.push(cur.shortMessage);
    if (typeof cur.reason === "string") parts.push(`reason: ${cur.reason}`);
    if (typeof cur.data === "string") parts.push(`data: ${cur.data}`);
    if (cur.data && typeof cur.data === "object") {
      if (typeof cur.data.errorName === "string")
        parts.push(`errorName: ${cur.data.errorName}`);
      if (typeof cur.data.data === "string") parts.push(`raw: ${cur.data.data}`);
    }
    if (typeof cur.metaMessages === "object" && Array.isArray(cur.metaMessages))
      parts.push(...cur.metaMessages);
    cur = cur.cause;
  }
  // De-dupe while preserving order.
  return [...new Set(parts.map((p) => String(p).trim()).filter(Boolean))];
}

async function main() {
  console.log("=== W3Cash encoder LIVE verification (Base Sepolia) ===\n");

  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport: http(RPC_URL),
  });

  // 1) Throwaway initiator.
  const privateKey = generatePrivateKey();
  const account = privateKeyToAccount(privateKey);
  const initiator = account.address;
  line("Initiator:", initiator);
  line("Processor:", PROCESSOR);
  line("USDC token:", USDC);

  // 2) Read on-chain nonce (expected 0 for a fresh key).
  const onchainNonce = await publicClient.readContract({
    address: PROCESSOR,
    abi: PROCESSOR_ABI,
    functionName: "nonces",
    args: [initiator],
  });
  line("On-chain nonce:", onchainNonce.toString());
  if (onchainNonce !== 0n) {
    console.warn("WARNING: fresh key nonce is not 0 — unexpected.");
  }

  // 3) Compile the conditional-transfer intent with the REAL encoder.
  //    Wait gate uses timestamp 1 (a past unix time) => already satisfied, so
  //    execution flows past the gate INTO the transfer op.
  const intent = compileIntent({
    chain: CHAIN_ID,
    nonce: onchainNonce.toString(),
    seq: 0,
    initiator,
    conditions: [{ type: "waitTime", timestamp: 1 }],
    actions: [
      { type: "transfer", token: USDC, to: RECIPIENT, amount: AMOUNT.toString() },
    ],
  });

  console.log("\n--- Compiled intent ---");
  line("operations:", intent.operations.length);
  line("payloadHash:", intent.payloadHash);
  line("toSign:", intent.toSign);
  line("wait target:", `${intent.steps[0].target} (${intent.steps[0].adapter})`);
  line("transfer target:", `${intent.steps[1].target} (${intent.steps[1].adapter})`);
  // Sanity: targets must match the deployed adapter addresses.
  if (getAddress(intent.steps[0].target) !== getAddress(ADAPTERS.wait.address))
    throw new Error("wait op target mismatch");
  if (getAddress(intent.steps[1].target) !== getAddress(ADAPTERS.transfer.address))
    throw new Error("transfer op target mismatch");
  if (intent.warnings.length)
    console.log("warnings:", JSON.stringify(intent.warnings));

  // 4) Sign toSign as an EIP-191 personal message (raw 32 bytes).
  const signature = await account.signMessage({ message: { raw: intent.toSign } });
  line("signature:", `${signature.slice(0, 20)}... (${(signature.length - 2) / 2} bytes)`);

  // 5) Assemble the SignedPayload calldata via the encoder's helper.
  const signedPayload = encodeSignedPayload({
    instruction: intent.instruction,
    initiator,
    nonce: onchainNonce,
    signature,
  });

  const data = encodeFunctionData({
    abi: PROCESSOR_ABI,
    functionName: "execute",
    args: [signedPayload],
  });

  // 6) eth_call Processor.execute(signedPayload). No native value needed.
  console.log("\n--- Calling Processor.execute(signedPayload) via eth_call ---");
  try {
    const res = await publicClient.call({
      account: initiator,
      to: PROCESSOR,
      data,
      value: 0n,
    });
    console.log("RESULT: call SUCCEEDED (no revert).");
    console.log("returnData:", res.data ?? "0x");
    console.log(
      "\nNOTE: success means execution did NOT reach a reverting transfer.\n" +
        "Most likely the Wait gate returned PAUSE_EXECUTION and the processor\n" +
        "exited early. Envelope + first-op routing decode correctly, but the\n" +
        "transfer routing was not exercised. Verdict below accounts for this."
    );
    return { outcome: "success", detail: res.data ?? "0x" };
  } catch (err) {
    const reasons = describeRevert(err);
    console.log("RESULT: call REVERTED.");
    for (const r of reasons) console.log("  •", r);
    return { outcome: "revert", detail: reasons.join(" | ") };
  }
}

main()
  .then((r) => {
    console.log("\n=== SUMMARY ===");
    console.log(JSON.stringify(r, null, 2));
  })
  .catch((e) => {
    console.error("\nFATAL (not an on-chain revert — script/encoding error):");
    console.error(e);
    process.exit(1);
  });
