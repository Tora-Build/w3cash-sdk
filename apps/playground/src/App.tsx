import { createSignal, createResource, onMount, onCleanup, Show, For } from 'solid-js';
import type { Address } from 'viem';
import { fetchCapabilities, compileIntent } from './lib/asp';
import type { CompiledIntent } from './lib/asp';
import {
  AGENTIC_WALLET,
  CHAIN_ID,
  EXPLORER_TX,
  connectWallet,
  currentChainId,
  ensureBaseSepolia,
  executeTransferScenario,
} from './lib/chain';
import type { ExecState } from './lib/chain';
import { SCENARIOS } from './lib/scenarios';
import type { ScenarioId } from './lib/scenarios';
import { errorMessage, shorten } from './lib/format';
import { ScenarioCard } from './components/ScenarioCard';
import { IntentView } from './components/IntentView';

// 1 USDC (6 decimals) — the amount the executable scenario moves.
const EXECUTE_AMOUNT = 1_000_000n;

export default function App() {
  const [capabilities] = createResource(fetchCapabilities);

  // Scenario + compile state
  const [selectedId, setSelectedId] = createSignal<ScenarioId | null>(null);
  const [intent, setIntent] = createSignal<CompiledIntent | null>(null);
  const [compiling, setCompiling] = createSignal(false);
  const [compileError, setCompileError] = createSignal('');

  // Wallet state
  const [account, setAccount] = createSignal<Address | null>(null);
  const [chainId, setChainId] = createSignal<number | null>(null);
  const [connecting, setConnecting] = createSignal(false);
  const [walletError, setWalletError] = createSignal('');

  // Execute state
  const [execState, setExecState] = createSignal<ExecState | null>(null);

  const selected = () => SCENARIOS.find((s) => s.id === selectedId());
  const recipient = () => AGENTIC_WALLET;
  const chainOk = () => chainId() === CHAIN_ID;
  const execBusy = () => {
    const st = execState();
    return st !== null && st.phase !== 'success' && st.phase !== 'error';
  };

  const statLine = () => {
    const caps = capabilities();
    const actions = caps?.counts.actionTypes ?? 8;
    const conditions = caps?.counts.conditionTypes ?? 12;
    return `${actions} actions × ${conditions} conditions, live on Base Sepolia`;
  };

  async function selectScenario(id: ScenarioId) {
    const scenario = SCENARIOS.find((s) => s.id === id);
    if (!scenario) return;
    setSelectedId(id);
    setIntent(null);
    setCompileError('');
    setExecState(null);
    setCompiling(true);
    try {
      const compiled = await compileIntent(scenario.buildBody(recipient()));
      setIntent(compiled);
    } catch (err) {
      setCompileError(errorMessage(err));
    } finally {
      setCompiling(false);
    }
  }

  async function onConnect() {
    setWalletError('');
    setConnecting(true);
    try {
      const acct = await connectWallet();
      setAccount(acct);
      setChainId(await currentChainId());
    } catch (err) {
      setWalletError(errorMessage(err));
    } finally {
      setConnecting(false);
    }
  }

  async function onSwitchNetwork() {
    setWalletError('');
    try {
      await ensureBaseSepolia();
      setChainId(await currentChainId());
    } catch (err) {
      setWalletError(errorMessage(err));
    }
  }

  async function onExecute() {
    const acct = account();
    if (!acct) return;
    setExecState({ phase: 'preparing', message: 'Preparing…' });
    try {
      await ensureBaseSepolia();
      setChainId(await currentChainId());
      // Sends 1 USDC from the connected wallet to a different address (the Agentic
      // Wallet) so the transfer is a real outbound movement, not a self-transfer.
      await executeTransferScenario(acct, recipient(), EXECUTE_AMOUNT, setExecState);
    } catch (err) {
      setExecState({ phase: 'error', message: errorMessage(err) });
    }
  }

  onMount(() => {
    const eth = window.ethereum;
    if (!eth) return;
    const handleAccounts = (accounts: Address[]) => {
      setAccount(accounts[0] ?? null);
      setExecState(null);
    };
    const handleChain = (chainIdHex: string) => setChainId(parseInt(chainIdHex, 16));
    eth.on('accountsChanged', handleAccounts);
    eth.on('chainChanged', handleChain);
    onCleanup(() => {
      eth.removeListener('accountsChanged', handleAccounts);
      eth.removeListener('chainChanged', handleChain);
    });
  });

  return (
    <div class="page">
      <div class="bg-gradient" aria-hidden="true" />

      <header class="hero">
        <div class="hero-brand">
          <span class="logo">◈</span>
          <span class="brand-name">
            W3Cash <span class="brand-sub">Intent Compiler</span>
          </span>
        </div>
        <h1 class="hero-tagline">
          The conditional-execution layer for agents
          <span class="accent"> — do X only when Y</span>
        </h1>
        <p class="hero-stat">
          <span class="live-dot" /> {statLine()}
        </p>
      </header>

      <main class="content">
        <section class="scenarios" aria-label="Scenarios">
          <For each={SCENARIOS}>
            {(scenario) => (
              <ScenarioCard
                scenario={scenario}
                active={selectedId() === scenario.id}
                loading={compiling() && selectedId() === scenario.id}
                onSelect={() => void selectScenario(scenario.id)}
              />
            )}
          </For>
        </section>

        <div class="workspace">
          <IntentView
            intent={intent()}
            scenario={selected()}
            loading={compiling()}
            error={compileError()}
          />

          <aside class="side-col">
            <section class="panel wallet-panel">
              <div class="panel-title">Wallet</div>
              <Show
                when={account()}
                fallback={
                  <>
                    <p class="muted">
                      Connect an injected wallet (MetaMask) to execute the intent for real on Base
                      Sepolia.
                    </p>
                    <button
                      type="button"
                      class="btn btn-primary"
                      onClick={() => void onConnect()}
                      disabled={connecting()}
                    >
                      {connecting() ? 'Connecting…' : 'Connect Wallet'}
                    </button>
                  </>
                }
              >
                {(acct) => (
                  <>
                    <div class="wallet-row">
                      <span class="muted">Address</span>
                      <span class="mono">{shorten(acct(), 8, 6)}</span>
                    </div>
                    <div class="wallet-row">
                      <span class="muted">Network</span>
                      <Show
                        when={chainOk()}
                        fallback={
                          <button type="button" class="btn btn-warn btn-sm" onClick={() => void onSwitchNetwork()}>
                            Switch to Base Sepolia
                          </button>
                        }
                      >
                        <span class="net-ok">Base Sepolia ✓</span>
                      </Show>
                    </div>
                  </>
                )}
              </Show>
              <Show when={walletError()}>
                <div class="alert alert-error">{walletError()}</div>
              </Show>
            </section>

            <Show when={selected()}>
              {(sc) => (
                <Show
                  when={sc().executable}
                  fallback={
                    <section class="panel note-panel">
                      <div class="note-icon">🔒</div>
                      <strong>Compile-only scenario</strong>
                      <p class="muted">{sc().gateNote}</p>
                      <p class="note-sub">
                        A real agent submits this signed intent to the processor; it stays pending
                        until the gate is met.
                      </p>
                    </section>
                  }
                >
                  <section class="panel exec-panel">
                    <div class="panel-title">Execute on-chain</div>
                    <Show
                      when={account() && chainOk()}
                      fallback={
                        <p class="muted">
                          {account()
                            ? 'Switch to Base Sepolia to execute.'
                            : 'Connect your wallet to execute this intent on-chain.'}
                        </p>
                      }
                    >
                      <p class="muted">
                        Recompiles for your address + nonce, approves USDC if needed, signs the
                        digest, and calls execute(). Runs as a self-transfer — real tx, no funds
                        leave your wallet.
                      </p>
                      <button
                        type="button"
                        class="btn btn-primary"
                        onClick={() => void onExecute()}
                        disabled={execBusy() || !intent()}
                      >
                        {execBusy() ? 'Working…' : 'Execute on-chain'}
                      </button>
                    </Show>

                    <Show when={execState()}>
                      {(st) => (
                        <div class="exec-status">
                          <Show when={st().phase !== 'success' && st().phase !== 'error'}>
                            <div class="loading-row">
                              <span class="spinner" /> {st().message}
                            </div>
                          </Show>
                          <Show when={st().phase === 'error'}>
                            <div class="alert alert-error">{st().message}</div>
                          </Show>
                          <Show when={st().phase === 'success'}>
                            <div class="success-box">
                              <div class="success-check">✅</div>
                              <div>
                                <strong>Executed on-chain</strong>
                                <p class="muted">{st().message}</p>
                              </div>
                            </div>
                          </Show>
                          <Show when={st().approveTxHash}>
                            {(h) => (
                              <a class="tx-link" href={EXPLORER_TX + h()} target="_blank" rel="noreferrer">
                                approval: {shorten(h(), 8, 6)} ↗
                              </a>
                            )}
                          </Show>
                          <Show when={st().txHash}>
                            {(h) => (
                              <a class="tx-link" href={EXPLORER_TX + h()} target="_blank" rel="noreferrer">
                                execute tx: {shorten(h(), 8, 6)} ↗
                              </a>
                            )}
                          </Show>
                        </div>
                      )}
                    </Show>
                  </section>
                </Show>
              )}
            </Show>
          </aside>
        </div>
      </main>

      <footer class="footer">
        <p>
          This is a demo of an A2MCP agent service (OKX.AI #5934). Real agents call the API directly;
          this page just visualizes it.
        </p>
        <a href="https://asp.w3.cash/capabilities" target="_blank" rel="noreferrer">
          View live /capabilities ↗
        </a>
      </footer>
    </div>
  );
}
