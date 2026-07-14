/**
 * End-to-end proof: compile a W3Cash intent with the ASP encoder, sign it with a
 * relayer key, and actually call Processor.execute() on Base Sepolia so real USDC
 * moves. Demonstrates the full non-custodial flow the ASP enables.
 *
 * Run:  npx tsx scripts/execute-demo.ts
 * Requires RELAYER_PRIVATE_KEY in .env (holding a little ETH gas + test USDC).
 */
import "dotenv/config";
import {
  createPublicClient,
  createWalletClient,
  http,
  getAddress,
  parseAbi,
  parseEventLogs,
  formatUnits,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import {
  compileIntent,
  encodeSignedPayload,
  PROCESSOR,
  CHAIN_ID,
} from "../src/w3cash/encode.js";

// A single consistent node (the load-balanced sepolia.base.org round-robins
// across nodes at different sync heights, which breaks approve→execute gas
// estimation). Override with BASE_SEPOLIA_RPC in .env if desired.
const RPC = process.env.BASE_SEPOLIA_RPC ?? "https://base-sepolia-rpc.publicnode.com";
const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
const TRANSFER_ADAPTER = getAddress("0x6cA85B548d3512E355B63Fb390dBD197CF72d5eA");
const RECIPIENT = getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3"); // Agentic Wallet
const AMOUNT = 1_000_000n; // 1 USDC (6 decimals)

const pk = process.env.RELAYER_PRIVATE_KEY as Hex | undefined;
if (!pk) throw new Error("RELAYER_PRIVATE_KEY not set in .env");

const account = privateKeyToAccount(pk);
const publicClient = createPublicClient({ chain: baseSepolia, transport: http(RPC) });
const walletClient = createWalletClient({ account, chain: baseSepolia, transport: http(RPC) });

const erc20 = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
]);
const processorAbi = parseAbi([
  "function execute(bytes signedPayload) payable",
  "function nonces(address user) view returns (uint256)",
]);

async function main() {
  console.log(`relayer/initiator: ${account.address}`);
  console.log(`chain: Base Sepolia (${CHAIN_ID})  processor: ${PROCESSOR}`);

  // 1. Approve the TransferAdapter (initiator must approve; adapter pulls via transferFrom).
  const allowance = await publicClient.readContract({
    address: USDC, abi: erc20, functionName: "allowance", args: [account.address, TRANSFER_ADAPTER],
  });
  if (allowance < AMOUNT) {
    console.log("approving TransferAdapter for 1 USDC ...");
    const h = await walletClient.writeContract({
      address: USDC, abi: erc20, functionName: "approve", args: [TRANSFER_ADAPTER, AMOUNT],
    });
    const r = await publicClient.waitForTransactionReceipt({ hash: h });
    console.log(`  approve tx: ${h}  (${r.status})`);
  } else {
    console.log("allowance already sufficient");
  }

  // 2. Compile a real intent via the ASP encoder (what /compile-intent returns).
  const nonce = await publicClient.readContract({
    address: PROCESSOR, abi: processorAbi, functionName: "nonces", args: [account.address],
  });
  const intent = compileIntent({
    chain: CHAIN_ID,
    initiator: account.address,
    nonce: Number(nonce),
    actions: [{ type: "transfer", token: USDC, to: RECIPIENT, amount: AMOUNT.toString() }],
  });
  console.log(`compiled intent — payloadHash: ${intent.payloadHash}`);
  console.log(`  toSign: ${intent.toSign}`);
  intent.humanSummary.forEach((l) => console.log(`  ${l}`));

  // 3. Sign the intent (EIP-191 personal-sign of the raw 32-byte hash). Non-custodial:
  //    the ASP never does this — the caller/relayer signs with their own key.
  const signature = await walletClient.signMessage({ account, message: { raw: intent.toSign } });

  // 4. Assemble the signed payload and execute on-chain.
  const signedPayload = encodeSignedPayload({
    instruction: intent.instruction,
    initiator: account.address,
    nonce,
    signature,
  });
  console.log("submitting execute() ...");
  const txHash = await walletClient.writeContract({
    address: PROCESSOR, abi: processorAbi, functionName: "execute", args: [signedPayload], value: 0n,
  });
  const rcpt = await publicClient.waitForTransactionReceipt({ hash: txHash });

  // Verify off the receipt's USDC Transfer event (deterministic — avoids flaky
  // follow-up balanceOf reads on load-balanced public RPCs).
  const transferAbi = parseAbi([
    "event Transfer(address indexed from, address indexed to, uint256 value)",
  ]);
  const moved = parseEventLogs({ abi: transferAbi, logs: rcpt.logs }).find(
    (l) =>
      l.address.toLowerCase() === USDC.toLowerCase() &&
      l.args.from?.toLowerCase() === account.address.toLowerCase() &&
      l.args.to?.toLowerCase() === RECIPIENT.toLowerCase()
  );

  console.log("──────────────────────────────────────────────");
  console.log(`execute tx:   ${txHash}`);
  console.log(`status:       ${rcpt.status}  (block ${rcpt.blockNumber}, gas ${rcpt.gasUsed})`);
  if (moved) {
    console.log(`USDC moved:   ${formatUnits(moved.args.value ?? 0n, 6)} USDC  ${moved.args.from} -> ${moved.args.to}`);
  }
  const ok = rcpt.status === "success" && moved?.args.value === AMOUNT;
  console.log(
    ok
      ? "✅ REAL EXECUTION PROVEN — agent-compiled intent moved USDC on-chain."
      : "❌ execution did not emit the expected Transfer"
  );
  if (!ok) process.exit(1);
}

main().catch((e) => { console.error("FAILED:", e.shortMessage ?? e.message ?? e); process.exit(1); });
