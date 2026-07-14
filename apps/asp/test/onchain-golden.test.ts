import { describe, it, expect } from "vitest";
import {
  decodeAbiParameters,
  parseAbiParameters,
  getAddress,
  slice,
  type Hex,
} from "viem";
import { compileIntent, CHAIN_ID } from "../src/w3cash/encode.js";

/**
 * Independent on-chain golden vectors for the NEW capabilities.
 *
 * Unlike encode.test.ts (which asserts against the encoder's own ADAPTERS.*
 * constants), this suite hardcodes the LITERAL deployed adapter addresses and
 * view-function selectors that were resolved directly on Base Sepolia
 * (chainId 84532) via `cast call adapterId()` + `AdapterRegistry.getAdapter()`
 * on 2026-07-15. If either the encoder's target-address wiring OR a view-fn
 * selector ever drifts from the deployed reality, these decode-back assertions
 * fail — they are not derivable from encode.ts itself.
 *
 *   Verified on-chain (RPC https://base-sepolia-rpc.publicnode.com):
 *     QueryAdapter      0x4bC2F784CC76989dA6760Bc6bFCDc3F75c49ee9F  id 0x7485829c  (registry id 1)
 *     BridgeAdapter     0x3502362cAB171ffF2bF094fC70FD5977c9AD7090  id 0x716f6a28  (registry id 7)
 *     TimeRangeAdapter  0xCC18E7E2283D3067B30D0e9a3Ba189FE25dB62EB  id 0x79b4e21f  (direct-address)
 *     GasPriceAdapter   0x07DcD715DdAB18D449b10BB6140916e8a0F7f657  id 0x62c7743a  (direct-address)
 *     SignatureAdapter  0xEEe61780cC5fC62B7017E46BB7f6b27fD8BAfBEe  id 0xfde104a6  (registry id 104)
 *   View selectors: balanceOf 0x70a08231, latestAnswer 0x50d25bcd,
 *                   isSettled 0x3270bb5b, winningOutcome 0x9b34ae03
 */

// Deployed adapter addresses — LITERALS (not imported from the encoder).
const QUERY_ADAPTER = getAddress("0x4bC2F784CC76989dA6760Bc6bFCDc3F75c49ee9F");
const BRIDGE_ADAPTER = getAddress("0x3502362cAB171ffF2bF094fC70FD5977c9AD7090");
const TIMERANGE_ADAPTER = getAddress("0xCC18E7E2283D3067B30D0e9a3Ba189FE25dB62EB");
const GASPRICE_ADAPTER = getAddress("0x07DcD715DdAB18D449b10BB6140916e8a0F7f657");
const SIGNATURE_ADAPTER = getAddress("0xEEe61780cC5fC62B7017E46BB7f6b27fD8BAfBEe");

// View-function selectors baked into QueryAdapter calldata.
const SEL_BALANCE_OF = "0x70a08231";
const SEL_LATEST_ANSWER = "0x50d25bcd";
const SEL_IS_SETTLED = "0x3270bb5b";
const SEL_WINNING_OUTCOME = "0x9b34ae03";

const WETH = getAddress("0x4200000000000000000000000000000000000006");
const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
const HOLDER = getAddress("0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3");
const MARKET = getAddress("0x80334C47F3DcE19FcFE7dB1AEce7423D32C4ccB1");
const ETH_USD_FEED = getAddress("0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1");

const OP_TUPLE = "uint8, uint8, uint64, address, bytes8, uint112";
const QUERY_TUPLE = "address, bytes, uint8, uint256";

/** Decode operations[0] and assert the op tuple routes to `expectedTarget`. */
function decodeOp(operation: Hex, expectedTarget: Hex): { value: bigint } {
  const [chain, amb, fee, target, selector, value] = decodeAbiParameters(
    parseAbiParameters(OP_TUPLE),
    operation
  );
  expect(chain).toBe(0); // LOCAL_CHAIN_INDEX
  expect(amb).toBe(0);
  expect(fee).toBe(0n);
  expect(selector).toBe("0x0000000000000000");
  expect(getAddress(target)).toBe(getAddress(expectedTarget));
  return { value };
}

describe("on-chain golden vectors — new capabilities route to the LITERAL deployed adapters", () => {
  it("bridge → BridgeAdapter 0x3502…7090, 11-field Across depositV3 tuple", () => {
    const intent = compileIntent({
      chain: CHAIN_ID,
      actions: [
        {
          type: "bridge",
          recipient: HOLDER,
          destinationChainId: "11155111",
          inputToken: WETH,
          outputToken: "0x0000000000000000000000000000000000000000",
          inputAmount: "1000000000000000000",
          outputAmount: "995000000000000000",
          quoteTimestamp: "1752566400",
          fillDeadline: "1752588000",
          exclusivityDeadline: "0",
        },
      ],
    });
    const { value } = decodeOp(intent.operations[0], BRIDGE_ADAPTER);
    expect(value).toBe(0n);
    const [
      recipient,
      dst,
      inTok,
      outTok,
      inAmt,
      outAmt,
      feePct,
      quoteTs,
      message,
      fillDl,
      exclDl,
    ] = decodeAbiParameters(
      parseAbiParameters(
        "address, uint256, address, address, uint256, uint256, int64, uint32, bytes, uint32, uint32"
      ),
      intent.inputs[0]
    );
    expect(getAddress(recipient)).toBe(HOLDER);
    expect(dst).toBe(11155111n);
    expect(getAddress(inTok)).toBe(WETH);
    expect(getAddress(outTok)).toBe("0x0000000000000000000000000000000000000000");
    expect(inAmt).toBe(1000000000000000000n);
    expect(outAmt).toBe(995000000000000000n);
    expect(feePct).toBe(0n); // relayerFeePct pinned; decoded but never forwarded
    expect(quoteTs).toBe(1752566400);
    expect(message).toBe("0x");
    expect(fillDl).toBe(1752588000);
    expect(exclDl).toBe(0);
  });

  it("timeRange → TimeRangeAdapter 0xCC18…62EB, (startTime,endTime,recurring)", () => {
    const intent = compileIntent({
      chain: CHAIN_ID,
      conditions: [{ type: "timeRange", startTime: "9", endTime: "17", recurring: true }],
    });
    decodeOp(intent.operations[0], TIMERANGE_ADAPTER);
    const [start, end, recurring] = decodeAbiParameters(
      parseAbiParameters("uint256, uint256, bool"),
      intent.inputs[0]
    );
    expect(start).toBe(9n);
    expect(end).toBe(17n);
    expect(recurring).toBe(true);
  });

  it("gasPrice → GasPriceAdapter 0x07Dc…f657, (uint8 operator, uint256 threshold)", () => {
    const intent = compileIntent({
      chain: CHAIN_ID,
      conditions: [{ type: "gasPrice", operator: "lte", threshold: "1500000000" }],
    });
    decodeOp(intent.operations[0], GASPRICE_ADAPTER);
    const [operator, threshold] = decodeAbiParameters(
      parseAbiParameters("uint8, uint256"),
      intent.inputs[0]
    );
    expect(operator).toBe(2); // lte
    expect(threshold).toBe(1500000000n);
  });

  it("signature → SignatureAdapter 0xEEe6…fBee, (signer,actionHash,deadline,sig)", () => {
    const sig = ("0x" + "ab".repeat(65)) as Hex;
    const actionHash = ("0x" + "cd".repeat(32)) as Hex;
    const intent = compileIntent({
      chain: CHAIN_ID,
      conditions: [
        {
          type: "signature",
          requiredSigner: HOLDER,
          actionHash,
          deadline: "2000000000",
          signature: sig,
        },
      ],
    });
    decodeOp(intent.operations[0], SIGNATURE_ADAPTER);
    const [signer, ah, deadline, signature] = decodeAbiParameters(
      parseAbiParameters("address, bytes32, uint256, bytes"),
      intent.inputs[0]
    );
    expect(getAddress(signer)).toBe(HOLDER);
    expect(ah).toBe(actionHash);
    expect(deadline).toBe(2000000000n);
    expect(signature).toBe(sig);
  });

  it("balance → QueryAdapter 0x4bC2…ee9F staticcall token.balanceOf(holder)", () => {
    const intent = compileIntent({
      chain: CHAIN_ID,
      conditions: [
        { type: "balance", token: WETH, target: HOLDER, operator: "gte", threshold: "100" },
      ],
    });
    decodeOp(intent.operations[0], QUERY_ADAPTER);
    const [target, data, operator, expected] = decodeAbiParameters(
      parseAbiParameters(QUERY_TUPLE),
      intent.inputs[0]
    );
    expect(getAddress(target)).toBe(WETH); // QueryAdapter target = the ERC20 read
    expect(slice(data, 0, 4)).toBe(SEL_BALANCE_OF);
    const [decodedHolder] = decodeAbiParameters(
      parseAbiParameters("address"),
      slice(data, 4)
    );
    expect(getAddress(decodedHolder)).toBe(HOLDER);
    expect(operator).toBe(3); // gte
    expect(expected).toBe(100n);
  });

  it("price → QueryAdapter 0x4bC2…ee9F staticcall feed.latestAnswer()", () => {
    const intent = compileIntent({
      chain: CHAIN_ID,
      conditions: [
        { type: "price", feed: ETH_USD_FEED, operator: "lte", targetPrice: "180000000000" },
      ],
    });
    decodeOp(intent.operations[0], QUERY_ADAPTER);
    const [target, data, operator, expected] = decodeAbiParameters(
      parseAbiParameters(QUERY_TUPLE),
      intent.inputs[0]
    );
    expect(getAddress(target)).toBe(ETH_USD_FEED);
    expect(data).toBe(SEL_LATEST_ANSWER); // bare selector, no args
    expect(operator).toBe(2); // lte
    expect(expected).toBe(180000000000n);
  });

  it("marketResolved → QueryAdapter staticcall market.isSettled() == 1", () => {
    const intent = compileIntent({
      chain: CHAIN_ID,
      conditions: [{ type: "marketResolved", market: MARKET }],
    });
    decodeOp(intent.operations[0], QUERY_ADAPTER);
    const [target, data, operator, expected] = decodeAbiParameters(
      parseAbiParameters(QUERY_TUPLE),
      intent.inputs[0]
    );
    expect(getAddress(target)).toBe(MARKET);
    expect(data).toBe(SEL_IS_SETTLED);
    expect(operator).toBe(4); // eq
    expect(expected).toBe(1n);
  });

  it("marketOutcome(YES) → QueryAdapter staticcall market.winningOutcome() == 1", () => {
    const intent = compileIntent({
      chain: CHAIN_ID,
      conditions: [{ type: "marketOutcome", market: MARKET, outcome: "YES" }],
    });
    decodeOp(intent.operations[0], QUERY_ADAPTER);
    const [target, data, operator, expected] = decodeAbiParameters(
      parseAbiParameters(QUERY_TUPLE),
      intent.inputs[0]
    );
    expect(getAddress(target)).toBe(MARKET);
    expect(data).toBe(SEL_WINNING_OUTCOME);
    expect(operator).toBe(4); // eq
    expect(expected).toBe(1n); // YES

    const no = compileIntent({
      chain: CHAIN_ID,
      conditions: [{ type: "marketOutcome", market: MARKET, outcome: "NO" }],
    });
    const [, , , noExpected] = decodeAbiParameters(
      parseAbiParameters(QUERY_TUPLE),
      no.inputs[0]
    );
    expect(noExpected).toBe(0n); // NO
  });
});
