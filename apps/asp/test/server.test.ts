import {
  describe,
  it,
  expect,
  beforeAll,
  afterAll,
} from "vitest";
import type { AddressInfo } from "node:net";
import type { Server } from "node:http";
import { app } from "../src/server.js";
import { CHAIN_ID } from "../src/w3cash/encode.js";

// Endpoint tests drive the real Express app over HTTP on an ephemeral port.
// server.ts's entrypoint guard means importing `app` here does NOT bind PORT;
// we own the listener lifecycle. Uses global fetch (Node 18+) — no supertest dep.

let server: Server;
let base = "";

beforeAll(async () => {
  await new Promise<void>((resolve) => {
    server = app.listen(0, () => resolve());
  });
  const addr = server.address() as AddressInfo;
  base = `http://127.0.0.1:${addr.port}`;
});

afterAll(async () => {
  await new Promise<void>((resolve, reject) =>
    server.close((err) => (err ? reject(err) : resolve()))
  );
});

const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const DEAD = "0x000000000000000000000000000000000000dEaD";

/** POST JSON helper returning { status, body }. */
async function postJson(
  path: string,
  body: unknown,
  contentType = "application/json"
): Promise<{ status: number; body: Record<string, unknown> }> {
  const res = await fetch(base + path, {
    method: "POST",
    headers: { "Content-Type": contentType },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
  const parsed = (await res.json()) as Record<string, unknown>;
  return { status: res.status, body: parsed };
}

describe("GET /health", () => {
  it("returns 200 { ok:true, service }", async () => {
    const res = await fetch(base + "/health");
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ok: boolean; service: string };
    expect(body.ok).toBe(true);
    expect(body.service).toBe("w3cash-intent-compiler");
  });
});

describe("GET /capabilities", () => {
  it("returns 200 with the capability catalog", async () => {
    const res = await fetch(base + "/capabilities");
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      ok: boolean;
      capabilities: {
        chainId: number;
        processor: string;
        actions: unknown[];
        conditions: unknown[];
        adapterCatalog: { key: string; deployed: boolean }[];
      };
    };
    expect(body.ok).toBe(true);
    expect(body.capabilities.chainId).toBe(CHAIN_ID);
    expect(body.capabilities.actions.length).toBeGreaterThan(0);
    expect(body.capabilities.conditions.length).toBeGreaterThan(0);
    // Balance/Price flagged not-deployed in the catalog surfaced over HTTP.
    const balance = body.capabilities.adapterCatalog.find(
      (a) => a.key === "balance"
    );
    expect(balance?.deployed).toBe(false);
  });
});

describe("POST /compile-intent — happy path", () => {
  it("compiles a conditional transfer and returns the signable envelope", async () => {
    const { status, body } = await postJson("/compile-intent", {
      chain: CHAIN_ID,
      nonce: 0,
      conditions: [{ type: "waitTime", timestamp: 1 }],
      actions: [{ type: "transfer", token: USDC, to: DEAD, amount: "1000000" }],
    });
    expect(status).toBe(200);
    expect(body.ok).toBe(true);
    const intent = body.intent as {
      chainId: number;
      operations: string[];
      inputs: string[];
      toSign: string;
      payloadHash: string;
      instruction: string;
      signing: { scheme: string; replayable: boolean };
      steps: { kind: string; type: string }[];
      warnings: string[];
    };
    expect(intent.chainId).toBe(CHAIN_ID);
    expect(intent.operations).toHaveLength(2);
    expect(intent.inputs).toHaveLength(2);
    // Frozen golden toSign for this exact intent (see encode.test.ts golden set).
    expect(intent.toSign).toBe(
      "0xce3786746701f4a1ce694c49980a5831faf9d304ddc3a3f137337ed27b853016"
    );
    expect(intent.signing.scheme).toBe("eip191-personal-sign");
    expect(intent.signing.replayable).toBe(true);
    expect(intent.steps.map((s) => s.kind)).toEqual(["condition", "action"]);
    // Replay caveat is always surfaced in the artifact the signer consumes.
    expect(
      intent.warnings.some((w) => w.includes("REPLAYABLE SIGNATURE"))
    ).toBe(true);
  });

  it("compiles an action-only intent (aaveWithdrawAll)", async () => {
    const { status, body } = await postJson("/compile-intent", {
      actions: [{ type: "aaveWithdrawAll", token: USDC }],
    });
    expect(status).toBe(200);
    expect(body.ok).toBe(true);
    const intent = body.intent as { operations: string[]; inputs: string[] };
    expect(intent.operations).toHaveLength(1);
    expect(intent.inputs[0].startsWith("0xfa09e630")).toBe(true);
  });

  it("parses a body sent as text/plain (content-type agnostic, W3C-ASP-03)", async () => {
    const { status, body } = await postJson(
      "/compile-intent",
      { actions: [{ type: "aaveWithdrawAll", token: USDC }] },
      "text/plain"
    );
    expect(status).toBe(200);
    expect(body.ok).toBe(true);
  });
});

describe("POST /compile-intent — validation 400s", () => {
  it("rejects an empty intent", async () => {
    const { status, body } = await postJson("/compile-intent", {});
    expect(status).toBe(400);
    expect(body.ok).toBe(false);
    expect(body.code).toBe("VALIDATION");
  });

  it("rejects a bad address", async () => {
    const { status, body } = await postJson("/compile-intent", {
      actions: [{ type: "transfer", token: "0xnope", to: DEAD, amount: "1" }],
    });
    expect(status).toBe(400);
    expect(body.code).toBe("VALIDATION");
  });

  it("rejects an unsupported chain", async () => {
    const { status, body } = await postJson("/compile-intent", {
      chain: 1,
      actions: [{ type: "aaveWithdrawAll", token: USDC }],
    });
    expect(status).toBe(400);
    expect(body.code).toBe("VALIDATION");
  });

  it("rejects a prototype-pollution operator (SEC-1)", async () => {
    const { status, body } = await postJson("/compile-intent", {
      conditions: [
        { type: "balance", target: DEAD, operator: "toString", threshold: "1" },
      ],
    });
    expect(status).toBe(400);
    expect(body.code).toBe("VALIDATION");
  });

  it("returns BAD_JSON on malformed JSON (terminal error middleware)", async () => {
    const res = await fetch(base + "/compile-intent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{ not json",
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { ok: boolean; code: string };
    expect(body.ok).toBe(false);
    expect(body.code).toBe("BAD_JSON");
  });

  it("never leaks a stack trace / HTML on error", async () => {
    const res = await fetch(base + "/compile-intent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{ not json",
    });
    const text = await res.text();
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(text).not.toContain("<html");
    expect(text).not.toMatch(/at .*\(.*:\d+:\d+\)/); // no V8 stack frames
    expect(text).not.toContain("/Users/"); // no absolute filesystem paths
  });
});

describe("routing & CORS", () => {
  it("returns a JSON 404 for unknown routes", async () => {
    const res = await fetch(base + "/does-not-exist");
    expect(res.status).toBe(404);
    const body = (await res.json()) as { ok: boolean; code: string };
    expect(body.ok).toBe(false);
    expect(body.code).toBe("NOT_FOUND");
  });

  it("answers CORS preflight (OPTIONS) with 204 + wildcard origin", async () => {
    const res = await fetch(base + "/compile-intent", { method: "OPTIONS" });
    expect(res.status).toBe(204);
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });

  it("sets a wildcard CORS header on normal responses", async () => {
    const res = await fetch(base + "/health");
    expect(res.headers.get("access-control-allow-origin")).toBe("*");
  });
});
