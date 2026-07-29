# Tunnel Tools (ngrok / cloudflared)

Expose a local port or service to the internet — useful for webhook testing, sharing a dev server, SSH reverse tunnels, and Cloudflare-native access policies.

Optional role (`installTunnelTools`). Enable at `chezmoi init --force` or set `installTunnelTools = true` in `~/.config/chezmoi/chezmoi.toml`.

> **Not covered here: Tailscale.** Both tools on this page expose a local port to
> the **public internet**. `tailscale serve` is the categorical opposite —
> tailnet-only, reachable by your own devices and nobody else — which is why it
> lives under its own `installTailscale` flag and its own docs
> ([Tailscale.md](Tailscale.md), [tsnet.md](tsnet.md)) rather than in this bundle.
> The tool on this page that *is* Tailscale's analogue is `tailscale funnel`, and
> the `tsnet` CLI deliberately does not implement it.

## Tools

| Tool | Purpose | Account required? | Free tier |
|------|---------|-------------------|-----------|
| [ngrok](https://ngrok.com/) | HTTP/TCP/TLS tunnels, traffic inspection UI | Yes (free plan available) | 1 agent, 1 endpoint, random subdomain |
| [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) | Cloudflare Tunnel — production-grade, no port forwarding needed | Yes (Cloudflare account, free) | Unlimited named tunnels, custom domains via Cloudflare DNS |

## Installation

Managed by the `networking_tools` Ansible role under the `tunnel_tools` tag.

| Platform | ngrok | cloudflared |
|----------|-------|-------------|
| macOS | `brew install ngrok/ngrok/ngrok` | `brew install cloudflared` |
| Linux (Debian/Ubuntu) | apt repo (official) → tgz fallback | `.deb` from GitHub releases → binary fallback |
| Linux (CentOS/RHEL) | tgz from equinox.io → `~/.local/bin` | `.rpm` from GitHub releases |

---

## ngrok

### Initial setup

```bash
# Authenticate (one-time, token stored in ~/.config/ngrok/ngrok.yml)
ngrok config add-authtoken <YOUR_TOKEN>
```

Get your token from <https://dashboard.ngrok.com/get-started/your-authtoken>.

### Expose a local HTTP server

```bash
# Forward localhost:3000 to a random ngrok HTTPS URL
ngrok http 3000

# Fixed subdomain (paid plan)
ngrok http --domain=myapp.ngrok.app 3000

# Specific host header (useful with vhosts)
ngrok http --host-header=rewrite 3000
```

### Expose TCP / raw ports

```bash
# SSH (useful for remote access to a machine behind NAT)
ngrok tcp 22

# Any TCP service
ngrok tcp 5432
```

### Traffic inspection

ngrok runs a local web inspector at `http://127.0.0.1:4040` while a tunnel is active:

```bash
# Open inspector in browser
open http://127.0.0.1:4040

# List active tunnels via API
curl -s http://127.0.0.1:4041/api/tunnels | jq
```

### Replay requests

In the web inspector (or via `ngrok replay`) you can replay any captured request — great for debugging webhook handlers without re-triggering the upstream service.

### Named tunnels in config

`~/.config/ngrok/ngrok.yml`:

```yaml
version: "3"
agent:
  authtoken: <YOUR_TOKEN>
tunnels:
  dev-server:
    proto: http
    addr: 3000
  api:
    proto: http
    addr: 8080
    host_header: rewrite
```

```bash
# Start a specific named tunnel
ngrok start dev-server

# Start all tunnels defined in config
ngrok start --all
```

---

## cloudflared

### Quick tunnel (no config needed)

```bash
# Instantly expose port 3000 — generates a random trycloudflare.com URL, no account needed
cloudflared tunnel --url http://localhost:3000
```

This is the fastest way to share a local server with someone.

### Named tunnels (permanent, custom domain)

```bash
# Authenticate with Cloudflare (opens browser)
cloudflared tunnel login

# Create a named tunnel
cloudflared tunnel create my-tunnel

# Create DNS record pointing to the tunnel
cloudflared tunnel route dns my-tunnel dev.example.com

# Run the tunnel
cloudflared tunnel run my-tunnel
```

Config file `~/.cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /Users/you/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: dev.example.com
    service: http://localhost:3000
  - hostname: api.example.com
    service: http://localhost:8080
  - service: http_status:404
```

```bash
cloudflared tunnel run
```

### SSH access via Cloudflare Access

Cloudflare Access lets you expose SSH without opening any port — the client connects through Cloudflare's network.

**Server side** (machine to expose):

```bash
# Create tunnel and configure SSH ingress (hostname: ssh.example.com → localhost:22)
cloudflared tunnel run
```

**Client side**:

```bash
# Add to ~/.ssh/config
# Host ssh.example.com
#   ProxyCommand cloudflared access ssh --hostname %h
```

```bash
ssh user@ssh.example.com
```

### Run as a system service

```bash
# Install as launchd (macOS) or systemd (Linux) service
sudo cloudflared service install

# Check status
sudo launchctl list | grep cloudflared   # macOS
sudo systemctl status cloudflared        # Linux
```

---

## Comparison

| Feature | ngrok | cloudflared |
|---------|-------|-------------|
| Quick share (no config) | `ngrok http 3000` | `cloudflared tunnel --url localhost:3000` |
| Custom domain (free) | Paid | Yes (via Cloudflare DNS) |
| Traffic inspection UI | Yes (`localhost:4040`) | No built-in |
| Replay requests | Yes | No |
| Production-grade | Limited | Yes (runs Cloudflare CDN) |
| TCP tunnels | Yes | Yes (via Spectrum, paid) |
| SSH proxy | Yes (TCP tunnel) | Yes (Cloudflare Access, free) |
| Needs open port | No | No |
| Self-hosted option | ngrok Agent SDK | Yes (Cloudflare WARP) |

---

## Common Dev Patterns

### Webhook testing

```bash
# Start your local handler
python -m http.server 8080

# Expose it and copy the HTTPS URL into your webhook provider's dashboard
ngrok http 8080
# or
cloudflared tunnel --url http://localhost:8080
```

### Share a local dev server with a teammate

```bash
# One-liner with cloudflared (no account, no install on recipient's side)
cloudflared tunnel --url http://localhost:3000
```

### Remote SSH to a machine behind NAT

```bash
# On the remote machine (server)
ngrok tcp 22
# Note the forwarding address, e.g. 0.tcp.ngrok.io:12345

# From your laptop
ssh -p 12345 user@0.tcp.ngrok.io
```

### VS Code Remote via tunnel

```bash
# On the remote machine
code tunnel          # uses Microsoft's tunnel (no ngrok/cloudflared needed)

# Alternative: expose SSH port and use Remote-SSH extension
ngrok tcp 22
# Add to ~/.ssh/config:  Host ngrok-remote \n  HostName 0.tcp.ngrok.io \n  Port 12345
```

### Environment variables for automation

```bash
# Get the ngrok public URL from the local API (useful in scripts)
NGROK_URL=$(curl -s http://127.0.0.1:4041/api/tunnels | jq -r '.tunnels[0].public_url')
echo "Webhook URL: $NGROK_URL"
```
