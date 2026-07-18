/**
 * One-shot x402 payment test against a mainnet-configured ASP.
 * Pays 0.01 USD₮0 on X Layer mainnet (eip155:196) via the OKX facilitator and
 * prints the settlement transaction hash. Point at the ASP with TEST_ASP.
 */
import "dotenv/config";
import { payingFetch } from "../src/payer.js";

const ASP = process.env.TEST_ASP ?? "http://localhost:8799";

// The intent body is incidental — the PAYMENT (eip155:196) is what we're testing.
// Use a supported compile chain so the endpoint returns 200 after settlement.
const body = {
  chain: 84532,
  actions: [
    { type: "aaveWithdrawAll", token: "0x036CbD53842c5426634e7929541eC2318f3dCF7e" },
  ],
};

const res = await payingFetch(`${ASP}/compile-intent`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

console.log("HTTP status:", res.status);

const payResp = res.headers.get("x-payment-response");
if (payResp) {
  try {
    const decoded = JSON.parse(Buffer.from(payResp, "base64").toString("utf8"));
    console.log("SETTLEMENT:", JSON.stringify(decoded, null, 2));
    const tx =
      decoded.transaction ?? decoded.txHash ?? decoded.hash ?? decoded.receipt?.transactionHash;
    if (tx) console.log("TX_HASH:", tx);
  } catch {
    console.log("x-payment-response (raw base64):", payResp);
  }
} else {
  console.log("(no x-payment-response header — payment may not have settled)");
}

const json = (await res.json()) as { ok?: boolean };
console.log("ok:", json.ok);
