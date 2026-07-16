import { Show, For, createSignal } from 'solid-js';
import type { CompiledIntent } from '../lib/asp';
import type { Scenario } from '../lib/scenarios';
import { shorten } from '../lib/format';

function CopyHash(props: { value: string }) {
  const [copied, setCopied] = createSignal(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(props.value);
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    } catch {
      /* clipboard unavailable — no-op */
    }
  };
  return (
    <button type="button" class="copy-btn" onClick={copy}>
      {copied() ? 'copied ✓' : 'copy'}
    </button>
  );
}

export function IntentView(props: {
  intent: CompiledIntent | null;
  scenario: Scenario | undefined;
  loading: boolean;
  error: string;
}) {
  return (
    <section class="panel intent-panel">
      <Show when={props.scenario} fallback={<EmptyState />}>
        <Show when={props.error}>
          <div class="alert alert-error">Compile failed: {props.error}</div>
        </Show>

        <Show when={props.loading}>
          <div class="loading-row">
            <span class="spinner" /> Compiling intent on the live ASP…
          </div>
        </Show>

        <Show when={props.intent && !props.loading}>
          {/* Solid passes a non-null accessor here */}
          {(_present) => {
            const intent = () => props.intent as CompiledIntent;
            return (
              <div class="intent-body">
                <div class="intent-head">
                  <div>
                    <div class="intent-eyebrow">Ready-to-sign intent</div>
                    <h2>{props.scenario?.title}</h2>
                  </div>
                  <span class="pill pill-noncustodial">non-custodial</span>
                </div>

                <div class="meta-grid">
                  <div class="meta">
                    <span class="meta-label">Chain</span>
                    <span class="meta-value">Base Sepolia · {intent().chainId}</span>
                  </div>
                  <div class="meta">
                    <span class="meta-label">Processor</span>
                    <span class="meta-value mono">{shorten(intent().processor)}</span>
                  </div>
                  <div class="meta">
                    <span class="meta-label">Nonce</span>
                    <span class="meta-value mono">{intent().nonce}</span>
                  </div>
                </div>

                <div class="steps">
                  <For each={intent().steps}>
                    {(step) => (
                      <div class="step" classList={{ 'step-gate': step.kind === 'condition' }}>
                        <span class="step-index">{step.index}</span>
                        <div class="step-main">
                          <div class="step-tags">
                            <span
                              class="tag"
                              classList={{
                                'tag-gate': step.kind === 'condition',
                                'tag-action': step.kind === 'action',
                              }}
                            >
                              {step.kind === 'condition' ? 'GATE' : 'ACTION'}
                            </span>
                            <span class="tag tag-type">{step.type}</span>
                            <span class="tag tag-adapter">{step.adapter}</span>
                          </div>
                          <p class="step-summary">{step.summary}</p>
                        </div>
                      </div>
                    )}
                  </For>
                </div>

                <div class="tosign">
                  <div class="tosign-head">
                    <span class="meta-label">Digest to sign (EIP-191 personal_sign)</span>
                    <CopyHash value={intent().toSign} />
                  </div>
                  <code class="mono tosign-hash">{intent().toSign}</code>
                </div>

                <Show when={intent().warnings.length > 0}>
                  <div class="warnings">
                    <div class="warnings-head">⚠ Signer caveats</div>
                    <For each={intent().warnings}>
                      {(w) => <p class="warning-line">{w}</p>}
                    </For>
                  </div>
                </Show>

                <Show when={props.scenario && !props.scenario.executable}>
                  <div class="alert alert-info">{props.scenario?.gateNote}</div>
                </Show>
              </div>
            );
          }}
        </Show>
      </Show>
    </section>
  );
}

function EmptyState() {
  return (
    <div class="empty">
      <div class="empty-glyph">◇</div>
      <p>Pick a scenario to compile a signable on-chain intent.</p>
      <span class="empty-sub">The ASP returns a real, non-custodial automation you can inspect step by step.</span>
    </div>
  );
}
