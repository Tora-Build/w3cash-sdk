import { describe, it, expect } from "vitest";
import { resolvePaymentNetworks, getPaymentOptions } from "../src/x402.js";

describe("resolvePaymentNetworks (dynamic payment)", () => {
  it("returns the primary network first (the default)", () => {
    expect(resolvePaymentNetworks({ network: "eip155:196" })).toEqual(["eip155:196"]);
  });

  it("appends extra networks, de-duplicated, primary first", () => {
    const nets = resolvePaymentNetworks({
      network: "eip155:196",
      extraNetworks: "eip155:8453, eip155:196, eip155:84532",
    });
    expect(nets).toEqual(["eip155:196", "eip155:8453", "eip155:84532"]); // dup 196 dropped
  });

  it("sanitizes an inline comment / whitespace (the boot-crash guard)", () => {
    expect(resolvePaymentNetworks({ network: "eip155:196 # X Layer mainnet" })).toEqual([
      "eip155:196",
    ]);
  });

  it("drops a malformed CAIP-2 id", () => {
    expect(resolvePaymentNetworks({ network: "not-a-caip2", extraNetworks: "eip155:8453" })).toEqual(
      ["eip155:8453"]
    );
  });

  it("returns [] when no network is configured", () => {
    expect(resolvePaymentNetworks({})).toEqual([]);
  });
});

describe("getPaymentOptions", () => {
  it("marks the first network as default and labels the known asset", () => {
    const opts = getPaymentOptions(
      { network: "eip155:196", payTo: "0xabc", extraNetworks: "eip155:8453" },
      "$0.01"
    );
    expect(opts.default).toBe("eip155:196");
    expect(opts.options).toHaveLength(2);
    expect(opts.options[0]).toMatchObject({
      network: "eip155:196",
      asset: "USD₮0",
      payTo: "0xabc",
      price: "$0.01",
      isDefault: true,
    });
    expect(opts.options[1]).toMatchObject({ network: "eip155:8453", asset: "USDC", isDefault: false });
  });

  it("is disabled when payTo is missing (never advertises a payable route without a payee)", () => {
    const opts = getPaymentOptions({ network: "eip155:196" }, "$0.01");
    expect(opts.enabled).toBe(false); // enabled also gated on X402_ENABLED at runtime
  });

  it("exposes the free→paid pricing ladder (item 15)", () => {
    const opts = getPaymentOptions({ network: "eip155:196", payTo: "0xabc" }, "$0.01");
    const preview = opts.tiers.find((t) => t.tier === "preview");
    const compile = opts.tiers.find((t) => t.tier === "compile");
    expect(preview?.price).toBe("free");
    expect(preview?.returns).toContain("NO signable payload");
    expect(compile?.endpoint).toBe("POST /compile-intent");
  });
});
