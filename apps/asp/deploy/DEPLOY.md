# Deploying the W3Cash Intent Compiler ASP

Target: a Linux VPS. Phase-1 is a **free** endpoint (no secrets needed) that must
be reachable over **HTTPS**. Until `asp.w3.cash` DNS is ready, we expose HTTPS via
a **Cloudflare quick tunnel** (no domain, no cert setup); swap to the real domain
later by pointing DNS at the box + running Caddy/nginx + certbot.

## 1. Build & install (on the VPS)

```bash
# prerequisites: node >= 20, git
sudo mkdir -p /opt/w3cash-asp && sudo chown "$USER" /opt/w3cash-asp
git clone <repo> /tmp/w3cash-sdk && cp -r /tmp/w3cash-sdk/apps/asp/* /opt/w3cash-asp/
cd /opt/w3cash-asp
npm ci --omit=dev && npm install --no-save typescript && npm run build   # produces dist/
```

## 2. Run as a service

```bash
sudo cp deploy/w3cash-asp.service /etc/systemd/system/
# edit User/WorkingDirectory if not www-data:/opt/w3cash-asp
sudo systemctl daemon-reload && sudo systemctl enable --now w3cash-asp
curl -s localhost:4000/health    # -> {"ok":true,"service":"w3cash-intent-compiler"}
```

## 3. Public HTTPS — interim (Cloudflare quick tunnel, no domain)

```bash
# install cloudflared, then:
cloudflared tunnel --url http://localhost:4000
# prints:  https://<random>.trycloudflare.com   <-- register THIS with OKX for now
```

Run it under its own systemd unit so it survives reboots (or use a named tunnel).
Self-check the public URL: `curl -i https://<random>.trycloudflare.com/health`
→ must be `HTTP/2 200` with the JSON body (OKX A2MCP endpoint requirement).

## 4. Public HTTPS — final (when `asp.w3.cash` DNS is ready)

Point `asp.w3.cash` A record at the VPS IP, then either:
- **Caddy** (auto-TLS): a 3-line Caddyfile `asp.w3.cash { reverse_proxy localhost:4000 }`, or
- **nginx + certbot**: reverse-proxy `localhost:4000`, `certbot --nginx -d asp.w3.cash`.

Then re-point the OKX ASP endpoint from the tunnel URL to `https://asp.w3.cash`.

## Phase-2 (x402 paid tier)

Only when enabling payments: create `/opt/w3cash-asp/.env` (0600, root-owned) with
`OKX_API_KEY / OKX_SECRET_KEY / OKX_PASSPHRASE / PAY_TO_ADDRESS / NETWORK`, restart
the service. Never commit that file. Self-check: `curl -i` with no payment header
must return `HTTP 402` + `PAYMENT-REQUIRED`.
