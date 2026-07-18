/**
 * Minimal, self-contained landing page served at GET / on the ASP domain.
 * Read-only: fetches /capabilities for all three chains and renders them prettily, so
 * asp.w3.cash doubles as the "live service" visual and the capabilities viewer.
 * No wallet, no execution, no external assets (inline CSS/JS only).
 */
export const LANDING_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>W3Cash — conditional-execution layer for AI agents</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: #0a0b0f; color: #e7e9ee;
    font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  .wrap { max-width: 940px; margin: 0 auto; padding: 40px 22px 64px; }
  .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; letter-spacing: .2px; }
  .logo { color: #7c9cff; font-size: 20px; }
  .sub { color: #8b90a0; font-weight: 500; }
  h1 { font-size: clamp(28px, 5vw, 44px); line-height: 1.1; margin: 26px 0 10px; font-weight: 700; }
  h1 .accent { color: #7c9cff; }
  .lead { color: #a7adbe; font-size: 17px; max-width: 640px; margin: 0 0 18px; }
  .live { display: inline-flex; align-items: center; gap: 8px; font-size: 13px; color: #9aa0b2;
          border: 1px solid #23262f; border-radius: 999px; padding: 6px 12px; background: #12141b; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #38d39f; box-shadow: 0 0 0 3px rgba(56,211,159,.18); }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin: 26px 0; }
  @media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
  .card { border: 1px solid #1e2129; background: #0f1117; border-radius: 14px; padding: 16px 18px; }
  .card h3 { margin: 0 0 4px; font-size: 15px; }
  .card .chain { color: #8b90a0; font-size: 12px; font-family: ui-monospace, "JetBrains Mono", monospace; }
  .stats { display: flex; gap: 18px; margin-top: 12px; }
  .stat b { display: block; font-size: 22px; color: #fff; }
  .stat span { font-size: 12px; color: #8b90a0; }
  .mono { font-family: ui-monospace, "JetBrains Mono", SFMono-Regular, monospace; font-size: 12px; color: #7f96e0; word-break: break-all; }
  .sec { margin-top: 34px; }
  .sec h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .12em; color: #8b90a0; margin: 0 0 12px; }
  .chips { display: flex; flex-wrap: wrap; gap: 8px; }
  .chip { font-size: 12.5px; border: 1px solid #23262f; background: #12141b; border-radius: 8px; padding: 5px 10px; color: #c9cde0; }
  .chip.cond { color: #a9d3c4; border-color: #1c2b26; background: #0e1613; }
  .steps { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
  @media (max-width: 640px) { .steps { grid-template-columns: 1fr; } }
  .step { border: 1px solid #1e2129; background: #0f1117; border-radius: 12px; padding: 14px 16px; }
  .step .n { color: #7c9cff; font-weight: 700; font-size: 13px; }
  .step b { display: block; margin: 4px 0 2px; }
  .step span { color: #8b90a0; font-size: 13px; }
  pre.cmd { border: 1px solid #23262f; background: #0d0f15; border-radius: 10px; padding: 12px 14px;
            overflow-x: auto; font-family: ui-monospace, monospace; font-size: 13px; color: #cfd6ea; margin: 12px 0; }
  .links { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 8px; }
  a.btn { text-decoration: none; color: #cfd6ea; border: 1px solid #23262f; background: #12141b;
          border-radius: 8px; padding: 8px 13px; font-size: 13px; }
  a.btn:hover { border-color: #3a4256; color: #fff; }
  a.btn.pri { color: #0a0b0f; background: #7c9cff; border-color: #7c9cff; font-weight: 600; }
  footer { margin-top: 40px; color: #71768a; font-size: 12.5px; border-top: 1px solid #1a1c23; padding-top: 16px; }
  footer a { color: #8b90a0; }
</style>
</head>
<body>
<div class="wrap">
  <div class="brand"><span class="logo">&#9672;</span> W3Cash <span class="sub">Intent Compiler</span></div>

  <h1>The conditional-execution layer for AI agents<span class="accent"> — do X only when Y</span></h1>
  <p class="lead">A non-custodial A2MCP service: it compiles a structured goal into a ready-to-sign
    on-chain intent, gated by time, price, gas, a co-signer, or a prediction market. It never holds keys or funds.</p>
  <span class="live"><span class="dot"></span> <span id="livemsg">live A2MCP service &middot; OKX.AI #5934</span></span>

  <div class="grid">
    <div class="card">
      <h3>Base Sepolia <span class="chain">chain 84532</span></h3>
      <div class="stats">
        <div class="stat"><b id="bs-a">8</b><span>action types</span></div>
        <div class="stat"><b id="bs-c">12</b><span>condition types</span></div>
        <div class="stat"><b id="bs-d">11</b><span>adapters</span></div>
      </div>
      <div class="mono" id="bs-proc" style="margin-top:10px"></div>
    </div>
    <div class="card">
      <h3>X Layer testnet <span class="chain">chain 1952</span></h3>
      <div class="stats">
        <div class="stat"><b id="xl-a">2</b><span>action types</span></div>
        <div class="stat"><b id="xl-c">12</b><span>condition types</span></div>
        <div class="stat"><b id="xl-d">7</b><span>adapters</span></div>
      </div>
      <div class="mono" id="xl-proc" style="margin-top:10px"></div>
    </div>
    <div class="card">
      <h3>X Layer mainnet <span class="chain">chain 196 &middot; live</span></h3>
      <div class="stats">
        <div class="stat"><b id="xm-a">2</b><span>action types</span></div>
        <div class="stat"><b id="xm-c">12</b><span>condition types</span></div>
        <div class="stat"><b id="xm-d">7</b><span>adapters</span></div>
      </div>
      <div class="mono" id="xm-proc" style="margin-top:10px"></div>
    </div>
  </div>

  <div class="sec">
    <h2>How it works</h2>
    <div class="steps">
      <div class="step"><span class="n">01</span><b>Compile</b><span>An agent calls the tool with {conditions, actions}; it returns a signable intent.</span></div>
      <div class="step"><span class="n">02</span><b>Sign (keyless)</b><span>The agent's wallet signs it &mdash; on X Layer, an OnchainOS Agentic Wallet, no private key.</span></div>
      <div class="step"><span class="n">03</span><b>Execute</b><span>Anyone relays it; the on-chain contract enforces the gate. Runs only when Y is true.</span></div>
    </div>
  </div>

  <div class="sec">
    <h2>Actions</h2>
    <div class="chips" id="actions"></div>
  </div>
  <div class="sec">
    <h2>Condition gates</h2>
    <div class="chips" id="conditions"></div>
  </div>

  <div class="sec">
    <h2>Use it from any agent</h2>
    <pre class="cmd">claude mcp add --transport http w3cash https://asp.w3.cash/mcp</pre>
    <p class="lead" style="font-size:14px;margin:2px 0 12px">Four self-describing tools, plus the full usage skill served as a resource (<span class="mono" style="color:#7f96e0">w3cash://skill</span>) &mdash; so one command delivers the tools <em>and</em> their how-to.</p>
    <div class="links">
      <a class="btn pri" href="/capabilities?chain=196">/capabilities (X Layer mainnet)</a>
      <a class="btn" href="/capabilities?chain=1952">/capabilities (X Layer testnet)</a>
      <a class="btn" href="/capabilities">/capabilities (Base Sepolia)</a>
      <a class="btn" href="/recipes?chain=196">/recipes</a>
      <a class="btn" href="/mcp">/mcp endpoint</a>
    </div>
  </div>

  <footer>
    Non-custodial &middot; the compiler never holds keys or funds &middot; the chain enforces every gate.
    &nbsp;|&nbsp; <a href="https://w3.cash">w3.cash</a>
  </footer>
</div>

<script>
(function () {
  function fill(cap, pfx) {
    if (!cap) return;
    var a = document.getElementById(pfx + '-a'); if (a) a.textContent = cap.counts.actionTypes;
    var c = document.getElementById(pfx + '-c'); if (c) c.textContent = cap.counts.conditionTypes;
    var d = document.getElementById(pfx + '-d'); if (d) d.textContent = cap.counts.deployedAdapters;
    var p = document.getElementById(pfx + '-proc'); if (p) p.textContent = 'processor ' + cap.processor;
  }
  function chips(el, items, cls) {
    if (!el) return; el.innerHTML = '';
    for (var i = 0; i < items.length; i++) {
      var s = document.createElement('span');
      s.className = 'chip' + (cls ? ' ' + cls : '');
      s.textContent = items[i].type;
      el.appendChild(s);
    }
  }
  function j(url) { return fetch(url).then(function (r) { return r.json(); }); }
  Promise.all([j('/capabilities'), j('/capabilities?chain=1952'), j('/capabilities?chain=196')]).then(function (res) {
    var bs = res[0] && res[0].capabilities, xl = res[1] && res[1].capabilities, xm = res[2] && res[2].capabilities;
    fill(bs, 'bs'); fill(xl, 'xl'); fill(xm, 'xm');
    if (bs) { chips(document.getElementById('actions'), bs.actions, ''); chips(document.getElementById('conditions'), bs.conditions, 'cond'); }
  }).catch(function () {});
})();
</script>
</body>
</html>`;
