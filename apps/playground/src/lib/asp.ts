// Typed client for the live W3Cash Intent Compiler ASP.
// Same-origin CORS is open, so these are plain fetches — no keys, no proxy.

export const ASP_BASE = 'https://asp.w3.cash';
export const CAPABILITIES_URL = `${ASP_BASE}/capabilities`;

export interface CapabilityAction {
  type: string;
  adapter: string;
  fields: string[];
  requiresPriorApprove?: boolean;
  note?: string;
}

export interface CapabilityCondition {
  type: string;
  adapter: string;
  fields: string[];
  note?: string;
}

export interface CapabilityCounts {
  actionTypes: number;
  conditionTypes: number;
  deployedActionAdapters: number;
  deployedConditionAdapters: number;
  deployedAdapters: number;
}

export interface Capabilities {
  chainId: number;
  chainName: string;
  processor: string;
  summary: string;
  counts: CapabilityCounts;
  replay: {
    replayable: boolean;
    caveat: string;
    cancel: string;
  };
  actions: CapabilityAction[];
  conditions: CapabilityCondition[];
}

interface CapabilitiesResponse {
  ok: boolean;
  capabilities: Capabilities;
}

export interface IntentStep {
  index: number;
  kind: 'condition' | 'action';
  type: string;
  adapter: string;
  target: string;
  value: string;
  operation: string;
  input: string;
  summary: string;
}

export interface CompiledIntent {
  chainId: number;
  processor: string;
  nonce: string;
  seq: string;
  operations: string[];
  inputs: string[];
  header: string;
  payload: string;
  payloadHash: string;
  // The ABI-encoded instruction bundle that goes into the processor's execute() payload.
  instruction: string;
  // The 32-byte digest the initiator signs (EIP-191 personal_sign over the raw bytes).
  toSign: string;
  steps: IntentStep[];
  humanSummary: string[];
  warnings: string[];
}

interface CompileResponse {
  ok: boolean;
  intent?: CompiledIntent;
  error?: string;
}

export type JsonValue = string | number | boolean;

export interface CompileBody {
  chain: number;
  nonce?: number;
  initiator?: string;
  conditions: Record<string, JsonValue>[];
  actions: Record<string, JsonValue>[];
}

export async function fetchCapabilities(): Promise<Capabilities> {
  const res = await fetch(CAPABILITIES_URL);
  if (!res.ok) throw new Error(`capabilities HTTP ${res.status}`);
  const data = (await res.json()) as CapabilitiesResponse;
  if (!data.ok) throw new Error('ASP returned ok:false for /capabilities');
  return data.capabilities;
}

export async function compileIntent(body: CompileBody): Promise<CompiledIntent> {
  const res = await fetch(`${ASP_BASE}/compile-intent`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  let data: CompileResponse;
  try {
    data = (await res.json()) as CompileResponse;
  } catch {
    throw new Error(`compile-intent returned a non-JSON response (HTTP ${res.status})`);
  }
  if (!res.ok || !data.ok || !data.intent) {
    throw new Error(data.error ?? `compile-intent failed (HTTP ${res.status})`);
  }
  return data.intent;
}
