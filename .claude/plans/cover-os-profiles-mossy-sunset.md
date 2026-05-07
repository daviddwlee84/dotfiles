# Plan: Add ngrok + cloudflared as managed tunnel tools

## Context

ngrok and cloudflared are both installed ad-hoc on the dev machine but not managed by dotfiles.
The user wants them integrated so they auto-install across OS/profiles, and wants a `docs/tools/tunnels.md`
covering common dev tunnel workflows (expose localhost, SSH reverse tunnels, etc.).

These are "tunnel/expose" tools, distinct from the existing diagnostic networking tools (nmap, mtr, etc.).
Adding them under a new **`installTunnelTools`** flag keeps them independently opt-in, while reusing the
existing `networking_tools` role avoids creating a one-purpose role for just two binaries.

---

## Files to Change

| File | Action |
|------|--------|
| `.chezmoi.toml.tmpl` | Add `installTunnelTools` prompt (default `false`) |
| `dot_ansible/roles/networking_tools/tasks/main.yml` | Add ngrok + cloudflared tasks with `tags: [tunnel_tools]` |
| `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` | Add hash of networking_tools tasks (already present); add `tunnel_tools` tag when flag is true |
| `docs/tools/tunnels.md` | New EN doc — install, common commands, env patterns |
| `docs/tools/tunnels.zh-TW.md` | New zh-TW mirror |
| `mkdocs.yml` | Add nav entry under Tools section (alphabetical near "Tailscale") |

---

## Step-by-Step Implementation

### 1. `.chezmoi.toml.tmpl` — new prompt

Insert after the `installNetworkingTools` line:

```toml
# 是否安裝 tunnel 工具 (ngrok, cloudflared) — expose localhost / SSH reverse tunnel
installTunnelTools = {{ promptBoolOnce . "installTunnelTools" "Install tunnel tools (ngrok, cloudflared — expose localhost, SSH tunnels)" false }}
```

### 2. `run_onchange_after_20_ansible_roles.sh.tmpl` — new tag gating

The file already hashes `networking_tools/tasks/main.yml` (line 37), so changing that file
will trigger a re-run automatically. Add after the `installNetworkingTools` block (~line 244):

```bash
{{ $installTunnelTools := false }}{{ if hasKey . "installTunnelTools" }}{{ $installTunnelTools = .installTunnelTools }}{{ end -}}
{{ if $installTunnelTools -}}
TAGS="${TAGS},tunnel_tools"
{{ end -}}
```

Also ensure `networking_tools` role is in the playbook tag list — it already is for all profiles
(both macos.yml and linux.yml include it); the new `tunnel_tools` tag will be a sub-tag within
the same role, so no playbook changes needed.

### 3. `networking_tools/tasks/main.yml` — ngrok + cloudflared tasks

Append to the end of the file. All tasks carry `tags: [tunnel_tools]`.

**Architecture variable** (reuse existing `net_arch_deb` fact already set earlier in the role).

#### ngrok

| Platform | Method |
|----------|--------|
| macOS | `brew tap ngrok/ngrok` + `brew install ngrok` |
| Linux Debian/Ubuntu | Official apt repo: add GPG key + source list + `apt install ngrok` (system-level, sudo); fallback: download tgz to `~/.local/bin` |
| Linux RedHat/CentOS | Download tgz from GitHub releases to `~/.local/bin` (no official rpm) |

ngrok Linux tgz URL pattern: `https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-{amd64|arm64}.tgz`

#### cloudflared

| Platform | Method |
|----------|--------|
| macOS | `brew install cloudflared` |
| Linux Debian/Ubuntu | Official `.deb` from GitHub releases: `cloudflared-linux-{amd64|arm64}.deb` via `apt install deb:` |
| Linux RedHat/CentOS | Official `.rpm` from GitHub releases: `cloudflared-linux-{x86_64|aarch64}.rpm` via `rpm -i` |

Both tools follow the existing block+rescue pattern (system-level first, user-level fallback).

### 4. `docs/tools/tunnels.md` (new)

Sections:
- **Installation** — how the tools are managed (ansible flag), manual install links
- **ngrok** — expose HTTP/TCP port, auth token setup (`ngrok config add-authtoken`), custom subdomains, inspect traffic at `localhost:4040`, useful flags
- **cloudflared** — `cloudflared tunnel` quick tunnel (no account), named tunnels (`cloudflared tunnel create`), SSH access via `cloudflared access ssh`, self-hosted Cloudflare Tunnel setup
- **Comparison table** — ngrok vs cloudflared: auth required, free tier, custom domains, protocols
- **Common patterns** — webhook dev, remote SSH, share local API, VS Code Remote via tunnel

### 5. `docs/tools/tunnels.zh-TW.md` (new)

Direct zh-TW translation of the EN doc, same section structure.

### 6. `mkdocs.yml` — nav entry

Under the `Tools:` section, insert alphabetically near `Tailscale.md`:

```yaml
- Tunnels (ngrok / cloudflared): tools/tunnels.md
```

And the zh-TW mirror in the i18n block.

---

## Verification

```bash
# Confirm strict build passes (no broken links)
uv run mkdocs build --strict

# Dry-run ansible to preview what would run (on macOS)
cd dot_ansible && ansible-playbook playbooks/macos.yml --tags tunnel_tools --check -v

# Verify chezmoi template renders cleanly
chezmoi execute-template < .chezmoi.toml.tmpl | grep -A2 installTunnelTools

# After apply: confirm binaries exist
ngrok version
cloudflared version
```
