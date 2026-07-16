import { Show } from 'solid-js';
import type { Scenario } from '../lib/scenarios';

export function ScenarioCard(props: {
  scenario: Scenario;
  active: boolean;
  loading: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      class="scenario-card"
      classList={{ active: props.active, flagship: props.scenario.flagship }}
      onClick={() => props.onSelect()}
      disabled={props.loading}
    >
      <div class="scenario-badges">
        <span
          class="badge"
          classList={{
            'badge-exec': props.scenario.badge === 'EXECUTABLE',
            'badge-compile': props.scenario.badge === 'COMPILE-ONLY',
          }}
        >
          {props.scenario.badge}
        </span>
        <Show when={props.scenario.flagship}>
          <span class="badge badge-flagship">FLAGSHIP</span>
        </Show>
      </div>
      <h3>{props.scenario.title}</h3>
      <p>{props.scenario.subtitle}</p>
      <span class="scenario-cta">
        {props.active && props.loading ? 'Compiling…' : 'Compile intent →'}
      </span>
    </button>
  );
}
