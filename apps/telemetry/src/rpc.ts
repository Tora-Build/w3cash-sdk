/**
 * Minimal JSON-RPC (dependency-light, Workers-friendly). Only the two calls the indexer needs:
 * eth_blockNumber and eth_getLogs (topic-filtered, block-ranged).
 */
import { EVENT_TOPIC0S, type RawLog } from "./parse.js";

async function rpc<T>(url: string, method: string, params: unknown[]): Promise<T> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const json = (await res.json()) as { result?: T; error?: { message: string } };
  if (json.error) throw new Error(`${method}: ${json.error.message}`);
  return json.result as T;
}

export async function blockNumber(url: string): Promise<number> {
  const hex = await rpc<string>(url, "eth_blockNumber", []);
  return Number.parseInt(hex, 16);
}

/** eth_getLogs for the processor, filtered to our event topic0 set, over [from, to]. */
export async function getLogs(url: string, address: string, from: number, to: number): Promise<RawLog[]> {
  return rpc<RawLog[]>(url, "eth_getLogs", [
    {
      address,
      fromBlock: "0x" + from.toString(16),
      toBlock: "0x" + to.toString(16),
      topics: [EVENT_TOPIC0S], // any of our events (topic0 OR-set)
    },
  ]);
}
