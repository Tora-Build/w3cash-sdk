import { describe, it, expect } from "vitest";
import {
  decodeAbiParameters,
  parseAbiParameters,
  keccak256,
  encodePacked,
  getAddress,
  slice,
  type Hex,
} from "viem";
import {
  compileIntent,
  encodeOperation,
  encodeEnvelope,
  encodeSignedPayload,
  getCapabilities,
  getRecipes,
  signatureMessageHash,
  ValidationError,
  ADAPTERS,
  CHAIN_ID,
  MAX_STEPS,
  type CompileRequest,
} from "../src/w3cash/encode.js";

// Frozen golden vectors — produced INDEPENDENTLY from encode.ts using viem
// primitives that reproduce the Solidity layout (DataTypes.Command operation
// tuple + W3CashProcessor envelope: payload=abi.encode(bytes[],bytes[]),
// header=abi.encode(seq,len,payloadHash), instruction=abi.encode(header,payload),
// toSign=keccak256(encodePacked(keccak256(payload),nonce))). Any drift in field
// order / layout / hashing breaks these.
const USDC = getAddress("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
const DEAD = getAddress("0x000000000000000000000000000000000000dEaD");

const GOLDEN = {
  opWait:
    "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008448b5f4abd40830c3b980390abcfd282271906100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as Hex,
  opTransfer:
    "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006ca85b548d3512e355b63fb390dbd197cf72d5ea00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as Hex,
  transferInput:
    "0x000000000000000000000000036cbd53842c5426634e7929541ec2318f3dcf7e000000000000000000000000000000000000000000000000000000000000dead00000000000000000000000000000000000000000000000000000000000f4240" as Hex,
  waitInput:
    "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as Hex,
  payloadHash:
    "0xe1771727493d882055ba0576cd1d6566a15a843cb882084db236fa7098eeb72f" as Hex,
  header:
    "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002e1771727493d882055ba0576cd1d6566a15a843cb882084db236fa7098eeb72f" as Hex,
  toSign:
    "0xce3786746701f4a1ce694c49980a5831faf9d304ddc3a3f137337ed27b853016" as Hex,
  toSignNonce7:
    "0xae2c5d00ff981781f8f0e42e029d29da248be8e42edb3e88f46b87a99e4f1989" as Hex,
  aaveDeposit:
    "0x47e7ef24000000000000000000000000036cbd53842c5426634e7929541ec2318f3dcf7e00000000000000000000000000000000000000000000000000000000000f4240" as Hex,
} as const;

/** The canonical conditional-transfer intent the golden vectors were seeded from. */
function goldenRequest(nonce: number | string = 0): CompileRequest {
  return {
    chain: CHAIN_ID,
    nonce,
    seq: 0,
    initiator: DEAD,
    conditions: [{ type: "waitTime", timestamp: 1 }],
    actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1000000" }],
  };
}

/** Cast helper for deliberately-malformed inputs without leaking `any`. */
function compileRaw(req: unknown) {
  return compileIntent(req as CompileRequest);
}

const OP_TUPLE = "uint8, uint8, uint64, address, bytes8, uint112";

describe("golden vectors (frozen against the Solidity reference)", () => {
  it("encodeOperation matches the Command tuple layout", () => {
    expect(encodeOperation(ADAPTERS.wait.address, 0n)).toBe(GOLDEN.opWait);
    expect(encodeOperation(ADAPTERS.transfer.address, 0n)).toBe(GOLDEN.opTransfer);
  });

  it("compileIntent reproduces the exact envelope", () => {
    const intent = compileIntent(goldenRequest(0));
    expect(intent.operations).toEqual([GOLDEN.opWait, GOLDEN.opTransfer]);
    expect(intent.inputs).toEqual([GOLDEN.waitInput, GOLDEN.transferInput]);
    expect(intent.payloadHash).toBe(GOLDEN.payloadHash);
    expect(intent.header).toBe(GOLDEN.header);
    expect(intent.toSign).toBe(GOLDEN.toSign);
    // instruction = abi.encode(header, payload); re-derive to confirm it embeds both.
    const env = encodeEnvelope(intent.operations, intent.inputs, 0n, 0n);
    expect(intent.instruction).toBe(env.instruction);
    expect(intent.processor).toBe(getAddress(intent.processor));
    expect(intent.chainId).toBe(CHAIN_ID);
  });

  it("targets route by adapter ADDRESS (field-3), amb/fee/selector are zero", () => {
    const intent = compileIntent(goldenRequest(0));
    expect(intent.steps[0].target).toBe(ADAPTERS.wait.address);
    expect(intent.steps[1].target).toBe(ADAPTERS.transfer.address);
  });

  it("aaveDeposit input carries the 0x47e7ef24 selector prefix", () => {
    const intent = compileIntent({
      actions: [{ type: "aaveDeposit", token: USDC, amount: "1000000" }],
    });
    expect(intent.inputs[0]).toBe(GOLDEN.aaveDeposit);
    expect(slice(intent.inputs[0], 0, 4)).toBe("0x47e7ef24");
  });
});

describe("round-trip decode (operation tuple + per-adapter input schemas)", () => {
  it("decodes every operation tuple back to (0,0,0,target,0x00..,value)", () => {
    const intent = compileIntent({
      actions: [
        { type: "transfer", token: USDC, to: DEAD, amount: "5", value: "9" },
      ],
    });
    const [chain, amb, fee, target, selector, value] = decodeAbiParameters(
      parseAbiParameters(OP_TUPLE),
      intent.operations[0]
    );
    expect(chain).toBe(0);
    expect(amb).toBe(0);
    expect(fee).toBe(0n);
    expect(getAddress(target)).toBe(ADAPTERS.transfer.address);
    expect(selector).toBe("0x0000000000000000");
    expect(value).toBe(9n);
  });

  it("transfer input == (token, to, amount)", () => {
    const intent = compileIntent({
      actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1000000" }],
    });
    const [token, to, amount] = decodeAbiParameters(
      parseAbiParameters("address, address, uint256"),
      intent.inputs[0]
    );
    expect(getAddress(token)).toBe(USDC);
    expect(getAddress(to)).toBe(DEAD);
    expect(amount).toBe(1000000n);
  });

  it("swap input == (tokenIn, tokenOut, amountIn, minOut, uint24 fee)", () => {
    const intent = compileIntent({
      actions: [
        {
          type: "swap",
          tokenIn: USDC,
          tokenOut: DEAD,
          amountIn: "100",
          minAmountOut: "90",
          fee: 3000,
        },
      ],
    });
    const [tokenIn, tokenOut, amountIn, minOut, fee] = decodeAbiParameters(
      parseAbiParameters("address, address, uint256, uint256, uint24"),
      intent.inputs[0]
    );
    expect(getAddress(tokenIn)).toBe(USDC);
    expect(getAddress(tokenOut)).toBe(DEAD);
    expect(amountIn).toBe(100n);
    expect(minOut).toBe(90n);
    expect(fee).toBe(3000);
  });

  it("aave withdraw / withdrawAll selectors + params", () => {
    const wd = compileIntent({
      actions: [{ type: "aaveWithdraw", token: USDC, amount: "7" }],
    });
    expect(slice(wd.inputs[0], 0, 4)).toBe("0xf3fef3a3");
    const [wToken, wAmount] = decodeAbiParameters(
      parseAbiParameters("address, uint256"),
      slice(wd.inputs[0], 4)
    );
    expect(getAddress(wToken)).toBe(USDC);
    expect(wAmount).toBe(7n);

    const all = compileIntent({
      actions: [{ type: "aaveWithdrawAll", token: USDC }],
    });
    expect(slice(all.inputs[0], 0, 4)).toBe("0xfa09e630");
    const [aToken] = decodeAbiParameters(
      parseAbiParameters("address"),
      slice(all.inputs[0], 4)
    );
    expect(getAddress(aToken)).toBe(USDC);
  });

  it("wait / price / balance / query condition inputs decode as declared", () => {
    const waitPrice = compileIntent({
      conditions: [
        { type: "waitPriceGte", feed: USDC, targetPrice: "-42" },
      ],
    });
    const [wtype, wval, wfeed, wtarget] = decodeAbiParameters(
      parseAbiParameters("uint8, uint256, address, int256"),
      waitPrice.inputs[0]
    );
    expect(wtype).toBe(2); // PRICE_GTE
    expect(wval).toBe(0n);
    expect(getAddress(wfeed)).toBe(USDC);
    expect(wtarget).toBe(-42n); // signed int256 preserved

    // price re-routes onto the deployed QueryAdapter: staticcall latestAnswer().
    const price = compileIntent({
      conditions: [
        { type: "price", feed: USDC, operator: "gte", targetPrice: "100", checkStaleness: true },
      ],
    });
    expect(price.steps[0].adapter).toBe("QueryAdapter");
    expect(price.steps[0].target).toBe(ADAPTERS.query.address);
    const [pfeed, pdata, poperator, ptarget] = decodeAbiParameters(
      parseAbiParameters("address, bytes, uint8, uint256"),
      price.inputs[0]
    );
    expect(getAddress(pfeed)).toBe(USDC);
    expect(pdata).toBe("0x50d25bcd"); // latestAnswer()
    expect(poperator).toBe(3);
    expect(ptarget).toBe(100n); // unsigned
    // checkStaleness has no QueryAdapter equivalent — dropped with a warning.
    expect(price.warnings.some((w) => w.includes("checkStaleness"))).toBe(true);

    // balance re-routes onto the deployed QueryAdapter: staticcall balanceOf(holder).
    const balance = compileIntent({
      conditions: [
        { type: "balance", token: USDC, target: DEAD, operator: "gte", threshold: "1" },
      ],
    });
    expect(balance.steps[0].adapter).toBe("QueryAdapter");
    expect(balance.steps[0].target).toBe(ADAPTERS.query.address);
    const [btarget, bdata, boperator, bthreshold] = decodeAbiParameters(
      parseAbiParameters("address, bytes, uint8, uint256"),
      balance.inputs[0]
    );
    expect(getAddress(btarget)).toBe(USDC); // QueryAdapter target = the ERC20
    expect(slice(bdata, 0, 4)).toBe("0x70a08231"); // balanceOf selector
    const [holder] = decodeAbiParameters(
      parseAbiParameters("address"),
      slice(bdata, 4)
    );
    expect(getAddress(holder)).toBe(DEAD);
    expect(boperator).toBe(3);
    expect(bthreshold).toBe(1n);

    const query = compileIntent({
      conditions: [
        { type: "query", target: DEAD, calldata: "0xabcd", operator: "lt", expected: "1" },
      ],
    });
    const [qtarget, qdata, qoperator, qexpected] = decodeAbiParameters(
      parseAbiParameters("address, bytes, uint8, uint256"),
      query.inputs[0]
    );
    expect(getAddress(qtarget)).toBe(DEAD);
    expect(qdata).toBe("0xabcd");
    expect(qoperator).toBe(0); // "lt" is value 0 — must still be accepted
    expect(qexpected).toBe(1n);
  });
});

describe("round-trip decode (remaining actions & conditions)", () => {
  it("approve input == (token, spender, amount)", () => {
    const intent = compileIntent({
      actions: [{ type: "approve", token: USDC, spender: DEAD, amount: "42" }],
    });
    expect(intent.steps[0].adapter).toBe("ApproveAdapter");
    const [token, spender, amount] = decodeAbiParameters(
      parseAbiParameters("address, address, uint256"),
      intent.inputs[0]
    );
    expect(getAddress(token)).toBe(USDC);
    expect(getAddress(spender)).toBe(DEAD);
    expect(amount).toBe(42n);
  });

  it("aaveDeposit input == 0x47e7ef24 || (token, amount)", () => {
    const intent = compileIntent({
      actions: [{ type: "aaveDeposit", token: USDC, amount: "1000000" }],
    });
    expect(slice(intent.inputs[0], 0, 4)).toBe("0x47e7ef24");
    const [token, amount] = decodeAbiParameters(
      parseAbiParameters("address, uint256"),
      slice(intent.inputs[0], 4)
    );
    expect(getAddress(token)).toBe(USDC);
    expect(amount).toBe(1000000n);
  });

  it("wrap input == (bool isWrap, uint256 amount); ETH->WETH forwards value", () => {
    const wrap = compileIntent({
      actions: [{ type: "wrap", isWrap: true, amount: "1000" }],
    });
    const [isWrap, amount] = decodeAbiParameters(
      parseAbiParameters("bool, uint256"),
      wrap.inputs[0]
    );
    expect(isWrap).toBe(true);
    expect(amount).toBe(1000n);
    // isWrap=true forwards ETH via the op value (defaults to amount).
    expect(wrap.steps[0].value).toBe("1000");

    const unwrap = compileIntent({
      actions: [{ type: "wrap", isWrap: false, amount: "1000" }],
    });
    const [uw] = decodeAbiParameters(
      parseAbiParameters("bool, uint256"),
      unwrap.inputs[0]
    );
    expect(uw).toBe(false);
    // WETH->ETH forwards no native value.
    expect(unwrap.steps[0].value).toBe("0");
  });

  it("waitTime input == (0, timestamp, zeroAddr, 0)", () => {
    const intent = compileIntent({
      conditions: [{ type: "waitTime", timestamp: "1700000000" }],
    });
    const [wtype, wval, wfeed, wtarget] = decodeAbiParameters(
      parseAbiParameters("uint8, uint256, address, int256"),
      intent.inputs[0]
    );
    expect(wtype).toBe(0); // TIMESTAMP
    expect(wval).toBe(1700000000n);
    expect(getAddress(wfeed)).toBe("0x0000000000000000000000000000000000000000");
    expect(wtarget).toBe(0n);
  });

  it("waitBlock input == (1, blockNumber, zeroAddr, 0)", () => {
    const intent = compileIntent({
      conditions: [{ type: "waitBlock", blockNumber: "12345" }],
    });
    const [wtype, wval] = decodeAbiParameters(
      parseAbiParameters("uint8, uint256, address, int256"),
      intent.inputs[0]
    );
    expect(wtype).toBe(1); // BLOCK
    expect(wval).toBe(12345n);
  });

  it("waitPriceLte input == (3, 0, feed, targetPrice)", () => {
    const intent = compileIntent({
      conditions: [{ type: "waitPriceLte", feed: USDC, targetPrice: "250000000000" }],
    });
    const [wtype, wval, wfeed, wtarget] = decodeAbiParameters(
      parseAbiParameters("uint8, uint256, address, int256"),
      intent.inputs[0]
    );
    expect(wtype).toBe(3); // PRICE_LTE
    expect(wval).toBe(0n);
    expect(getAddress(wfeed)).toBe(USDC);
    expect(wtarget).toBe(250000000000n);
  });
});

describe("signature binding", () => {
  it("toSign = keccak256(encodePacked(keccak256(payload), nonce))", () => {
    const intent = compileIntent(goldenRequest(0));
    const expected = keccak256(
      encodePacked(["bytes32", "uint256"], [intent.payloadHash, 0n])
    );
    expect(intent.toSign).toBe(expected);
    expect(intent.toSign).toBe(GOLDEN.toSign);
    expect(intent.signing.messageHash).toBe(intent.toSign);
    expect(intent.signing.replayable).toBe(true);
  });

  it("toSign changes with the nonce (bound signature)", () => {
    const n0 = compileIntent(goldenRequest(0));
    const n7 = compileIntent(goldenRequest(7));
    expect(n7.toSign).not.toBe(n0.toSign);
    expect(n7.toSign).toBe(GOLDEN.toSignNonce7);
    // Same payload, different nonce.
    expect(n7.payloadHash).toBe(n0.payloadHash);
  });

  it("encodeSignedPayload round-trips the SignedPayload tuple", () => {
    const intent = compileIntent(goldenRequest(0));
    const sig = ("0x" + "11".repeat(65)) as Hex;
    const encoded = encodeSignedPayload({
      instruction: intent.instruction,
      initiator: DEAD,
      nonce: 0n,
      signature: sig,
    });
    const [[instruction, initiator, nonce, signature]] = decodeAbiParameters(
      parseAbiParameters("(bytes, address, uint256, bytes)"),
      encoded
    );
    expect(instruction).toBe(intent.instruction);
    expect(getAddress(initiator)).toBe(DEAD);
    expect(nonce).toBe(0n);
    expect(signature).toBe(sig);
  });
});

describe("validation errors (clean 400 path)", () => {
  it("rejects a bad address", () => {
    expect(() =>
      compileRaw({ actions: [{ type: "transfer", token: "0xnope", to: DEAD, amount: "1" }] })
    ).toThrow(ValidationError);
  });

  it("rejects oversized uints (uint24 fee, uint112 value)", () => {
    expect(() =>
      compileRaw({
        actions: [
          { type: "swap", tokenIn: USDC, tokenOut: DEAD, amountIn: "1", minAmountOut: "1", fee: 16777216 },
        ],
      })
    ).toThrow(ValidationError);
    expect(() =>
      compileRaw({
        actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1", value: (1n << 112n).toString() }],
      })
    ).toThrow(ValidationError);
  });

  it("rejects an unsupported chain", () => {
    expect(() => compileRaw({ chain: 1, actions: [{ type: "aaveWithdrawAll", token: USDC }] })).toThrow(
      ValidationError
    );
  });

  it("rejects an empty intent", () => {
    expect(() => compileRaw({})).toThrow(ValidationError);
    expect(() => compileRaw({ conditions: [], actions: [] })).toThrow(ValidationError);
  });

  it("rejects a non-boolean wrap.isWrap", () => {
    expect(() => compileRaw({ actions: [{ type: "wrap", isWrap: "yes", amount: "1" }] })).toThrow(
      ValidationError
    );
  });

  it("SEC-1: prototype-chain operator names are rejected", () => {
    for (const bad of ["toString", "constructor", "valueOf", "hasOwnProperty", "__proto__"]) {
      expect(() =>
        compileRaw({
          conditions: [
            { type: "balance", token: USDC, target: DEAD, operator: bad, threshold: "1" },
          ],
        })
      ).toThrow(ValidationError);
    }
  });

  it("balance without a token (native ETH) is rejected — no balanceOf()", () => {
    expect(() =>
      compileRaw({
        conditions: [{ type: "balance", target: DEAD, operator: "gte", threshold: "1" }],
      })
    ).toThrow(ValidationError);
  });

  it("price with a negative targetPrice is rejected (compared unsigned)", () => {
    expect(() =>
      compileRaw({
        conditions: [{ type: "price", feed: USDC, operator: "gte", targetPrice: "-1" }],
      })
    ).toThrow(ValidationError);
  });

  it("gasPrice rejects eq/neq (reduced 0..3 operator set)", () => {
    for (const bad of ["eq", "neq", 4, 5]) {
      expect(() =>
        compileRaw({ conditions: [{ type: "gasPrice", operator: bad, threshold: "1" }] })
      ).toThrow(ValidationError);
    }
  });

  it("signature rejects a non-65-byte signature (would revert, not pause)", () => {
    expect(() =>
      compileRaw({
        conditions: [
          {
            type: "signature",
            requiredSigner: DEAD,
            actionHash: ("0x" + "11".repeat(32)) as Hex,
            deadline: "2000000000",
            signature: "0x1234",
          },
        ],
      })
    ).toThrow(ValidationError);
  });

  it("bridge rejects native ETH input, zero fillDeadline, and outputAmount > inputAmount", () => {
    const base = {
      recipient: DEAD,
      destinationChainId: "11155111",
      inputToken: "0x4200000000000000000000000000000000000006",
      inputAmount: "100",
      outputAmount: "99",
      quoteTimestamp: "1752566400",
      fillDeadline: "1752588000",
    } as const;
    // native ETH (zero-address inputToken)
    expect(() =>
      compileRaw({
        actions: [
          { type: "bridge", ...base, inputToken: "0x0000000000000000000000000000000000000000" },
        ],
      })
    ).toThrow(ValidationError);
    // fillDeadline = 0 reverts on-chain
    expect(() =>
      compileRaw({ actions: [{ type: "bridge", ...base, fillDeadline: "0" }] })
    ).toThrow(ValidationError);
    // outputAmount > inputAmount never fills
    expect(() =>
      compileRaw({ actions: [{ type: "bridge", ...base, outputAmount: "101" }] })
    ).toThrow(ValidationError);
  });

  it("ASP-06: odd-length query calldata is rejected", () => {
    expect(() =>
      compileRaw({
        conditions: [{ type: "query", target: DEAD, calldata: "0xabc", operator: "lt", expected: "1" }],
      })
    ).toThrow(ValidationError);
  });

  it("W3C-ASP-05: binary/octal numeric strings are rejected", () => {
    for (const bad of ["0b101", "0o17", "1e3", "5.0"]) {
      expect(() =>
        compileRaw({ actions: [{ type: "transfer", token: USDC, to: DEAD, amount: bad }] })
      ).toThrow(ValidationError);
    }
  });

  it("W3C-ASP-04: seq >= operation count is rejected", () => {
    // 1 op, seq 1 -> zero iterations on-chain.
    expect(() =>
      compileRaw({ seq: 1, actions: [{ type: "aaveWithdrawAll", token: USDC }] })
    ).toThrow(ValidationError);
  });

  it("SEC-5: exceeding MAX_STEPS is rejected", () => {
    const actions = Array.from({ length: MAX_STEPS + 1 }, () => ({
      type: "aaveWithdrawAll" as const,
      token: USDC,
    }));
    expect(() => compileRaw({ actions })).toThrow(ValidationError);
  });
});

describe("warnings surfaced in the compiled artifact", () => {
  it("SEC-4: replay caveat is always present", () => {
    const intent = compileIntent(goldenRequest(0));
    expect(intent.warnings.some((w) => w.includes("REPLAYABLE SIGNATURE"))).toBe(true);
  });

  it("ASP: balance/price now route to the deployed QueryAdapter (no not-deployed warning)", () => {
    const balance = compileIntent({
      conditions: [
        { type: "balance", token: USDC, target: DEAD, operator: "gte", threshold: "1" },
      ],
    });
    expect(balance.steps[0].adapter).toBe("QueryAdapter");
    expect(balance.warnings.some((w) => w.includes("NOT deployed"))).toBe(false);

    const price = compileIntent({
      conditions: [
        { type: "price", feed: USDC, operator: "gte", targetPrice: "1", checkStaleness: true },
      ],
    });
    expect(price.steps[0].adapter).toBe("QueryAdapter");
    expect(price.warnings.some((w) => w.includes("NOT deployed"))).toBe(false);
    expect(price.warnings.some((w) => w.includes("checkStaleness"))).toBe(true);
  });

  it("value-forwarding warning appears when an op forwards ETH", () => {
    const intent = compileIntent({
      actions: [{ type: "wrap", isWrap: true, amount: "1000" }],
    });
    expect(intent.warnings.some((w) => w.includes("native ETH forwarded"))).toBe(true);
  });
});

describe("Day 1+2 capabilities (bridge, timeRange, gasPrice, signature, market gates)", () => {
  const WETH = getAddress("0x4200000000000000000000000000000000000006");
  const MKT = getAddress("0x80334C47F3DcE19FcFE7dB1AEce7423D32C4ccB1");
  const QUERY_TUPLE = "address, bytes, uint8, uint256";

  it("bridge encodes the 11-field Across tuple, targets BridgeAdapter (id 7)", () => {
    const intent = compileIntent({
      actions: [
        {
          type: "bridge",
          recipient: DEAD,
          destinationChainId: "11155111",
          inputToken: WETH,
          outputToken: "0x0000000000000000000000000000000000000000",
          inputAmount: "1000000000000000000",
          outputAmount: "995000000000000000",
          quoteTimestamp: "1752566400",
          fillDeadline: "1752588000",
        },
      ],
    });
    const step = intent.steps[0];
    expect(step.adapter).toBe("BridgeAdapter");
    expect(step.target).toBe(ADAPTERS.bridge.address);
    expect(ADAPTERS.bridge.address).toBe(
      getAddress("0x3502362cAB171ffF2bF094fC70FD5977c9AD7090")
    );
    expect(ADAPTERS.bridge.registryId).toBe(7);
    expect(ADAPTERS.bridge.adapterId).toBe("0x716f6a28");
    const [recipient, dst, inTok, outTok, inAmt, outAmt, feePct, quoteTs, message, fillDl, exclDl] =
      decodeAbiParameters(
        parseAbiParameters(
          "address, uint256, address, address, uint256, uint256, int64, uint32, bytes, uint32, uint32"
        ),
        intent.inputs[0]
      );
    expect(getAddress(recipient)).toBe(DEAD);
    expect(dst).toBe(11155111n);
    expect(getAddress(inTok)).toBe(WETH);
    expect(getAddress(outTok)).toBe("0x0000000000000000000000000000000000000000");
    expect(inAmt).toBe(1000000000000000000n);
    expect(outAmt).toBe(995000000000000000n);
    expect(feePct).toBe(0n); // relayerFeePct pinned to 0 (decoded, never forwarded)
    expect(quoteTs).toBe(1752566400);
    expect(message).toBe("0x");
    expect(fillDl).toBe(1752588000);
    expect(exclDl).toBe(0);
    expect(step.value).toBe("0"); // no msg.value forwarded
    expect(intent.warnings.some((w) => w.includes("suggested-fees"))).toBe(true);
  });

  it("timeRange encodes (startTime, endTime, recurring); recurring hours 0..23", () => {
    const intent = compileIntent({
      conditions: [{ type: "timeRange", startTime: "9", endTime: "17", recurring: true }],
    });
    expect(intent.steps[0].adapter).toBe("TimeRangeAdapter");
    expect(intent.steps[0].target).toBe(ADAPTERS.timeRange.address);
    const [start, end, recurring] = decodeAbiParameters(
      parseAbiParameters("uint256, uint256, bool"),
      intent.inputs[0]
    );
    expect(start).toBe(9n);
    expect(end).toBe(17n);
    expect(recurring).toBe(true);
    expect(() =>
      compileRaw({
        conditions: [{ type: "timeRange", startTime: "24", endTime: "1", recurring: true }],
      })
    ).toThrow(ValidationError);
    const oneTime = compileIntent({
      conditions: [{ type: "timeRange", startTime: "1000", endTime: "2000", recurring: false }],
    });
    const [, , rec2] = decodeAbiParameters(
      parseAbiParameters("uint256, uint256, bool"),
      oneTime.inputs[0]
    );
    expect(rec2).toBe(false);
  });

  it("gasPrice encodes (uint8 operator, uint256 threshold)", () => {
    const intent = compileIntent({
      conditions: [{ type: "gasPrice", operator: "lte", threshold: "1000000000" }],
    });
    expect(intent.steps[0].adapter).toBe("GasPriceAdapter");
    expect(intent.steps[0].target).toBe(ADAPTERS.gasPrice.address);
    const [operator, threshold] = decodeAbiParameters(
      parseAbiParameters("uint8, uint256"),
      intent.inputs[0]
    );
    expect(operator).toBe(2); // lte
    expect(threshold).toBe(1000000000n);
  });

  it("signature encodes (address, bytes32, uint256, bytes)", () => {
    const sig = ("0x" + "ab".repeat(65)) as Hex;
    const actionHash = ("0x" + "cd".repeat(32)) as Hex;
    const intent = compileIntent({
      conditions: [
        {
          type: "signature",
          requiredSigner: DEAD,
          actionHash,
          deadline: "2000000000",
          signature: sig,
        },
      ],
    });
    expect(intent.steps[0].adapter).toBe("SignatureAdapter");
    expect(intent.steps[0].target).toBe(ADAPTERS.signature.address);
    const [signer, ah, deadline, signature] = decodeAbiParameters(
      parseAbiParameters("address, bytes32, uint256, bytes"),
      intent.inputs[0]
    );
    expect(getAddress(signer)).toBe(DEAD);
    expect(ah).toBe(actionHash);
    expect(deadline).toBe(2000000000n);
    expect(signature).toBe(sig);
  });

  it("signatureMessageHash mirrors SignatureAdapter.getMessageHash exactly", () => {
    const actionHash = ("0x" + "11".repeat(32)) as Hex;
    const got = signatureMessageHash({
      account: DEAD,
      actionHash,
      deadline: "2000000000",
    });
    const expected = keccak256(
      encodePacked(
        ["address", "bytes32", "uint256", "uint256", "address"],
        [DEAD, actionHash, 2000000000n, BigInt(CHAIN_ID), ADAPTERS.signature.address]
      )
    );
    expect(got).toBe(expected);
  });

  it("marketResolved -> isSettled()==1; marketOutcome -> winningOutcome()==outcome", () => {
    const resolved = compileIntent({
      conditions: [{ type: "marketResolved", market: MKT }],
    });
    expect(resolved.steps[0].adapter).toBe("QueryAdapter");
    const [rt, rd, ro, re] = decodeAbiParameters(
      parseAbiParameters(QUERY_TUPLE),
      resolved.inputs[0]
    );
    expect(getAddress(rt)).toBe(MKT);
    expect(rd).toBe("0x3270bb5b"); // isSettled()
    expect(ro).toBe(4); // eq
    expect(re).toBe(1n);

    const outcome = compileIntent({
      conditions: [{ type: "marketOutcome", market: MKT, outcome: "YES" }],
    });
    const [ot, od, oo, oe] = decodeAbiParameters(
      parseAbiParameters(QUERY_TUPLE),
      outcome.inputs[0]
    );
    expect(getAddress(ot)).toBe(MKT);
    expect(od).toBe("0x9b34ae03"); // winningOutcome()
    expect(oo).toBe(4); // eq
    expect(oe).toBe(1n); // YES

    const no = compileIntent({
      conditions: [{ type: "marketOutcome", market: MKT, outcome: 0 }],
    });
    const [, , , ne] = decodeAbiParameters(parseAbiParameters(QUERY_TUPLE), no.inputs[0]);
    expect(ne).toBe(0n);
    expect(() =>
      compileRaw({ conditions: [{ type: "marketOutcome", market: MKT, outcome: 3 }] })
    ).toThrow(ValidationError);
  });

  it("every canned recipe compiles to a signable envelope", () => {
    const book = getRecipes();
    expect(book.recipes.length).toBeGreaterThanOrEqual(5);
    expect(book.replay.replayable).toBe(true);
    for (const r of book.recipes) {
      const intent = compileIntent(r.request);
      expect(intent.operations.length).toBeGreaterThan(0);
      expect(intent.toSign).toMatch(/^0x[0-9a-f]{64}$/);
    }
  });
});

describe("capabilities catalog", () => {
  it("exposes the deployed processor + adapter catalog with deploy flags", () => {
    const caps = getCapabilities();
    expect(caps.chainId).toBe(CHAIN_ID);
    expect(caps.actions.length).toBeGreaterThan(0);
    expect(caps.conditions.length).toBeGreaterThan(0);
    // Stale Balance/Price adapters were removed once re-routed to QueryAdapter.
    expect(caps.adapterCatalog.find((a) => a.key === "balance")).toBeUndefined();
    expect(caps.adapterCatalog.find((a) => a.key === "price")).toBeUndefined();
    // Every remaining adapter is deployed (verified on-chain).
    expect(caps.adapterCatalog.every((a) => a.deployed)).toBe(true);
    const transfer = caps.adapterCatalog.find((a) => a.key === "transfer");
    expect(transfer?.deployed).toBe(true);
    const query = caps.adapterCatalog.find((a) => a.key === "query");
    expect(query?.deployed).toBe(true);
    // New adapters are present and deployed.
    for (const key of ["bridge", "timeRange", "gasPrice", "signature"]) {
      expect(caps.adapterCatalog.find((a) => a.key === key)?.deployed).toBe(true);
    }
    // Accurate, self-describing counts (no "18 actions" overclaim).
    expect(caps.counts.actionTypes).toBe(8);
    expect(caps.counts.conditionTypes).toBe(12);
    expect(caps.counts.deployedAdapters).toBe(11);
    expect(caps.replay.replayable).toBe(true);
  });
});
