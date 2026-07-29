# Container Runtimes, Proxies, and GFW Mirror Strategies

Operating notes for Docker / OrbStack / Docker Desktop / Podman across the four real-world install variants, with a focus on what this repo auto-manages vs what stays in the "apply when needed" manual-recipe book.

For the "who reads which config file" reference (CLI vs daemon vs systemd vs Desktop app, rootful vs rootless), see [container-config-map.md](container-config-map.md). This doc focuses on how to operate your box; the map doc focuses on understanding the landscape.

See also: [docs/infra/virtualization.md](../infra/virtualization.md#desktop-vm-managers) for OrbStack's VM-manager side (vs Proxmox / UTM / VirtualBox), and [docs/infra/shared-storage.md](../infra/shared-storage.md#storage-for-containers-and-k8s) for when container volumes hit CSI / CephFS / NFS in a multi-node cluster.

Primary pain points this doc addresses:

- **Which config file do I edit?** The answer depends on runtime and install mode; there are at least four different locations with overlapping schemas.
- **GFW / China-mirror story.** `daemon.json` `registry-mirrors` covers Docker Hub only. For `gcr.io` / `ghcr.io` / `quay.io` you need a separate strategy (prefix substitution).
- **Proxy is at two layers.** Daemon-side (for `docker pull`) is distinct from client-side (for `docker run` / `docker build`); forgetting the distinction is a common source of "why doesn't my proxy work inside the container" confusion.

## TL;DR

| Concern | File | Managed by chezmoi? | Trigger |
|---------|------|---------------------|---------|
| Container proxy env (`docker run`, `docker build`) | `~/.docker/config.json` `proxies.default` | Yes, cross-platform | `$LOCAL_PROXY_URL` set at apply time |
| Rootless daemon registry mirrors (`docker pull` via mirror) | `~/.config/docker/daemon.json` `registry-mirrors` | Yes, Linux + `useChineseMirror` only | `useChineseMirror=true` in chezmoi data |
| Rootless daemon HTTP proxy (`docker pull` via proxy) | `~/.config/docker/daemon.json` `proxies` (Engine ≥ 23) | No — written at runtime by [`docker-net on`](docker-net.md) | explicit command; needs a daemon restart |
| System daemon proxy / mirrors | `/etc/docker/daemon.json` + `/etc/systemd/system/docker.service.d/http-proxy.conf` | No (requires sudo) | — |
| Docker Desktop / OrbStack proxy + mirrors | GUI settings | No (GUI-managed) | — |
| Non-Docker-Hub registries (`gcr.io`, `ghcr.io`, `quay.io`, ...) | Rewrite image refs | No (application-level) | See [kubesre strategy](#strategy-b-prefix-substitution-kubesre) below |

Source files:

- [dot_docker/modify_config.json.tmpl](../../dot_docker/modify_config.json.tmpl) — client proxy merge script.
- [dot_config/docker/modify_daemon.json.tmpl](../../dot_config/docker/modify_daemon.json.tmpl) — rootless registry-mirrors merge script.
- [dot_config/shell/50_networking.sh](../../dot_config/shell/50_networking.sh) — shared `$LOCAL_PROXY_URL` convention and `proxy-on` / `withproxy` helpers.
- [dot_config/shell/51_docker_net.sh](../../dot_config/shell/51_docker_net.sh) — `docker-net`: diagnose all of the above against the live daemon, write the daemon proxy, and pull through a fallback ladder. Start here when a pull fails: [docker-net.md](docker-net.md).

## Runtimes at a glance

| Runtime | Platform | Mode | Best for | Gotchas |
|---------|----------|------|----------|---------|
| [Docker Engine](https://docs.docker.com/engine/) | Linux | System (root daemon) | Traditional Linux server use; widest tooling compatibility | Daemon runs as root; requires sudo for config/restart |
| [Docker Engine rootless](https://docs.docker.com/engine/security/rootless/) | Linux | Per-user daemon (systemd --user) | Development boxes, shared servers, locked-down environments | Reduced networking (no `iptables` MASQ by default); some storage drivers unavailable |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | macOS / Windows | VM-backed daemon | Feature parity with upstream Docker; enterprise-friendly | License tiers for large orgs; higher RAM footprint than OrbStack; slow cold start |
| [OrbStack](https://orbstack.dev) | macOS (Apple Silicon + Intel) | Lightweight VM | The macOS default in this repo; fast boot, low idle RAM, native ARM | macOS-only (no Windows/Linux); no enterprise support contracts |
| [Podman](https://podman.io) | Linux + Mac (via `podman machine`) | Daemonless, rootless-by-default | License-clean swap; matches rootless Docker's security story without systemd unit | `podman compose` lags `docker compose` on some networking edge cases; no Swarm; BuildKit parity gaps |

Repo default: OrbStack on macOS, **rootless Docker Engine on Ubuntu** (installed by the ansible role; `systemctl --user` lifecycle, no `sudo` for day-to-day config). See [dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml). System (rootful) Docker remains available as a fallback if you need the machine-wide daemon for specific tooling, but it's no longer the installed-by-default path.

## Where each install variant stores config

Four installs, three distinct file schemas, two layers (client vs daemon). Summary:

| Install | Daemon proxy | Daemon registry-mirrors | Client proxy (`docker run`) |
|---------|--------------|--------------------------|------------------------------|
| **Rootless Docker Engine (Linux, repo default)** | `~/.config/systemd/user/docker.service.d/proxy.conf` | `~/.config/docker/daemon.json` (chezmoi-managed) | `~/.docker/config.json` (chezmoi-managed) |
| OrbStack (macOS, repo default) | GUI: Settings > Network > Proxy | `~/.orbstack/config/docker.json` (`registry-mirrors` key, or GUI) | `~/.docker/config.json` (chezmoi-managed) |
| Docker Desktop (macOS/Win, fallback) | GUI: Settings > Resources > Proxies | GUI: Settings > Docker Engine > `registry-mirrors` JSON | `~/.docker/config.json` (chezmoi-managed) |
| System Docker Engine (Linux, fallback) | `/etc/systemd/system/docker.service.d/http-proxy.conf` (sudo) | `/etc/docker/daemon.json` (sudo) | `~/.docker/config.json` (chezmoi-managed) |

Notes:

- The **client** file (`~/.docker/config.json`) is the same path on every variant — the Docker CLI doesn't know or care which daemon it talks to.
- The **daemon** files live in different places because each install variant has a different lifecycle owner (systemd root, systemd --user, VM-inside-GUI, etc.).
- GUI-managed variants (Docker Desktop, OrbStack) serialize their settings to JSON on disk, but editing those files directly is discouraged — the app overwrites them on next launch.

## Client-side proxy (chezmoi-managed)

### What it does

`~/.docker/config.json` has a top-level `proxies.default` block that the Docker CLI reads on every `docker run` / `docker build` / `docker compose up` and uses to inject `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` / `ALL_PROXY` into the container's environment (and as build-args during image builds).

It does **not** affect `docker pull` — that's a daemon operation and needs daemon-side config (next section).

### How this repo manages it

[dot_docker/modify_config.json.tmpl](../../dot_docker/modify_config.json.tmpl) is a chezmoi `modify_` script. On every `chezmoi apply`:

1. Reads the existing `~/.docker/config.json` from stdin.
2. If `$LOCAL_PROXY_URL` is set in the apply-time environment, merges `proxies.default` into the JSON via `jq`. Any `auths` / `credsStore` / `credHelpers` / `currentContext` / `plugins` / `features` keys written by `docker login` or the CLI itself are preserved.
3. If `$LOCAL_PROXY_URL` is unset, strips `proxies.default` and, if that leaves `.proxies` empty, removes that key too. Idempotent cleanup.

The URL convention is shared with the shell proxy helpers ([docs/tools/web-reader.md](web-reader.md) > "Proxy behavior"):

```bash
export LOCAL_PROXY_URL="http://127.0.0.1:7890"           # HTTP/HTTPS
export LOCAL_PROXY_SOCKS_URL="socks5://127.0.0.1:7891"   # Optional; fills allProxy
chezmoi apply
```

### Verify

```bash
# Should show proxies.default block
jq '.proxies' ~/.docker/config.json

# Run a container, check env
docker run --rm alpine env | grep -iE 'proxy'
# Expect: HTTP_PROXY, HTTPS_PROXY, NO_PROXY, http_proxy, https_proxy, no_proxy, all_proxy

# docker info shows proxy the daemon itself knows about (different layer!)
docker info 2>/dev/null | grep -iE 'proxy'
```

### Toggling off

```bash
# Temporarily: unset env var, re-apply
unset LOCAL_PROXY_URL
chezmoi apply

# Permanently: remove the export from ~/.zshenv or wherever you set it,
# then chezmoi apply removes proxies.default on next run.
```

## Daemon-side proxy

Needed when `docker pull` goes through the proxy (e.g. pulling images in GFW territory) — which is every image no mirror carries: `ghcr.io`, `gcr.io`, `quay.io`, `registry.k8s.io`, and any Hub image the mirror rate-limits.

### The short way: `docker-net on`

```bash
docker-net status      # what is configured right now, and is a proxy even needed
docker-net on          # detect the local proxy, write daemon.json `proxies`, restart
docker-net off
```

`docker-net` picks the right file for your install variant, resolves the proxy through the same detector as `proxy-status`, adds every configured mirror host to `no-proxy`, lists the containers a restart would kill, and verifies afterwards that `docker info` actually picked it up. Full guide, including why rootless *can* use a `127.0.0.1` proxy on Docker ≥ 25: [docker-net.md](docker-net.md).

On Engine ≥ 23 this writes `daemon.json`'s `proxies` key rather than a systemd drop-in — one file, identical for rootless and rootful, and it works on hosts without systemd. The manual recipes below remain correct for older engines, and for anyone who prefers the systemd layer.

**macOS**: `docker-net on` deliberately refuses. Docker Desktop and OrbStack run the daemon inside a VM, where `127.0.0.1` is the VM's loopback rather than your Mac's, so their proxy is a UI setting (OrbStack: Settings → Network → Proxy; Desktop: Settings → Resources → Proxies). Everything else — `status`, `doctor`, `mirrors`, and all three rungs of `docker-net pull` — works there unchanged. See [docker-net.md](docker-net.md).

**macOS**: `docker-net on` deliberately refuses. Docker Desktop and OrbStack run the daemon inside a VM, where `127.0.0.1` is the VM's loopback rather than your Mac's, so their proxy is a UI setting (OrbStack: Settings → Network → Proxy; Desktop: Settings → Resources → Proxies). Everything else — `status`, `doctor`, `mirrors`, and all three rungs of `docker-net pull` — works there unchanged. See [docker-net.md](docker-net.md).

### Rootless Docker (Linux) — systemd --user drop-in

```bash
mkdir -p ~/.config/systemd/user/docker.service.d/
cat > ~/.config/systemd/user/docker.service.d/proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
EOF

systemctl --user daemon-reload
systemctl --user restart docker
```

Verify:

```bash
docker info | grep -iE 'proxy'
# Expect:
#  HTTP Proxy: http://127.0.0.1:7890
#  HTTPS Proxy: http://127.0.0.1:7890
#  No Proxy: localhost,127.0.0.1,...
```

This is **not** chezmoi-managed. Reason: editing it requires a daemon restart, which kills running containers — unacceptable for an automated apply path, and the proxy port differs per host and per session anyway (Clash Verge 7897, mihomo 7890, an ad-hoc SSH tunnel). An explicit command may do what an implicit `chezmoi apply` must not, which is why `docker-net on` exists. Manage it yourself when the proxy URL changes.

A drop-in left behind here after switching to rootless is a common trap: it is read by the *rootful* `docker.service`, which the rootless pivot disabled, so `docker info` keeps reporting no proxy while a perfectly correct-looking config file sits on disk. `docker-net doctor` flags it. See [pitfalls/docker-proxy-set-but-docker-info-shows-empty.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/docker-proxy-set-but-docker-info-shows-empty.md).

If the user unit is in a non-canonical location (some distros ship it differently), find it with `systemctl --user status docker` and look for the `Loaded:` line.

### System Docker Engine (Linux) — systemd drop-in (sudo)

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d/
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker
```

### Docker Desktop / OrbStack

Use the GUI:

- **Docker Desktop**: Settings > Resources > Proxies. Toggle "Manual proxy configuration" and fill in HTTP / HTTPS / bypass list. Docker Desktop restarts the VM's daemon automatically.
- **OrbStack**: Settings > Network > Proxy. Same idea.

Editing the JSON files directly (`~/Library/Group Containers/group.com.docker/settings.json` for Desktop; `~/.orbstack/config/docker.json` for OrbStack) works but gets clobbered if the GUI writes the same keys on next launch.

## Registry mirrors — two strategies

### Strategy A: `registry-mirrors` in `daemon.json`

Native Docker mechanism. `daemon.json`:

```json
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io"
  ]
}
```

Order matters: Docker tries mirrors sequentially and falls back to `docker.io` on failure. **A dead entry is not free** — it costs a timeout, and a mirror that answers `403`/`502` produces an error containerd surfaces as `failed to resolve reference`, which reads like "that image does not exist". Keep the list short and measured, not aspirational. `docker-net mirrors` re-measures it in about a second.

**Critical limitation**: `registry-mirrors` only mirrors `docker.io` (Docker Hub). It does **nothing** for `gcr.io` / `ghcr.io` / `quay.io` / `registry.k8s.io` / `mcr.microsoft.com` / `nvcr.io`. Those need [Strategy B](#strategy-b-prefix-substitution-kubesre).

**Mirror endpoint rot**: mirror providers go dark, rate-limit, or get blocked — and the managed list rots silently, because nothing fails loudly until you pull. Measured 2026-07 from a CN residential line (`curl https://<host>/v2/`):

| Mirror | Result | Status |
|---|---|---|
| `docker.m.daocloud.io` | `401`, 47 ms | **kept** — the only survivor |
| `docker.mirrors.ustc.edu.cn` | `Could not resolve host` | removed — the domain has no DNS record at all |
| `docker.nju.edu.cn` | `403` | removed — campus network only |
| `mirror.iscas.ac.cn` | `502` | removed |
| `mirror.baidubce.com` | `SSL_ERROR_SYSCALL` | removed — reachable only from inside Baidu Cloud |

DaoCloud still has the known stall on large pulls ([DaoCloud/public-image-mirror#2328](https://github.com/DaoCloud/public-image-mirror/issues/2328)), and it answers `403 Forbidden` for images it has not cached or has rate-limited. With four dead entries behind it there was nothing to fall through to, which is what made GFW pulls feel randomly broken. The replacement for "more mirrors" is the daemon proxy and [`docker-net pull`](docker-net.md#docker-net-pull--the-fallback-ladder), not a longer list — fewer pull-through caches is also a smaller `tag→digest` trust surface.

Re-measure at any time:

```bash
docker-net mirrors
```

**Removed for supply-chain safety** (2026-07): `dockerhub.azk8s.cn` (deprecated Azure-China mirror) and `dockerproxy.com` (third-party, ToS-churned) were dropped from the managed list. A pull-through mirror resolves `tag→digest`, and Docker Content Trust is off by default, so a dead/third-party mirror domain that lapses and gets re-registered by an attacker becomes a malicious pull-through cache that can serve a tampered image for a tag like `latest`. If you re-add any mirror, prefer high-reputation operators; for sensitive images pull by digest (`repo@sha256:…`) or enable Content Trust. See [mirrors.md → Security and trust model](mirrors.md#security-and-trust-model).

Verify after apply + daemon restart:

```bash
docker info | grep -A10 'Registry Mirrors'
```

#### Where to put it per install variant

- **Rootless Docker (Linux, repo default)** — `~/.config/docker/daemon.json`. **Chezmoi-managed** via [dot_config/docker/modify_daemon.json.tmpl](../../dot_config/docker/modify_daemon.json.tmpl), gated on `useChineseMirror=true` + Linux OS. After apply, run:

  ```bash
  systemctl --user reload docker      # SIGHUP — running containers survive
  ```

  `registry-mirrors` is in Docker's SIGHUP-reloadable config set, so a **reload is enough** and your containers keep running (measured on Engine 29.6.2 rootless with 8 containers up: daemon PID and start timestamp unchanged). A full `restart` is only needed for keys that are not reloadable — notably `proxies`. chezmoi does neither automatically.

- **OrbStack** — `~/.orbstack/config/docker.json` or GUI Settings > Docker > "Docker daemon config". OrbStack reapplies on save.

- **Docker Desktop** — GUI: Settings > Docker Engine, paste `registry-mirrors` into the JSON editor, apply + restart.

- **System Docker Engine (Linux, fallback)** — `/etc/docker/daemon.json`. Not chezmoi-managed (requires sudo; the chezmoi-managed rootless path doesn't apply here). Recipe:

  ```bash
  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
  {
    "registry-mirrors": [
      "https://docker.m.daocloud.io"
    ]
  }
  EOF
  sudo systemctl reload docker
  ```

##### Migration note: pre-pivot rootful installs

If this repo set up your Linux box before the rootless pivot (i.e. via the old `get.docker.com` convenience-script task that left only rootful `dockerd` running), the chezmoi-managed `~/.config/docker/daemon.json` mirrors were silently ignored — the rootful daemon only reads `/etc/docker/daemon.json`. Verify with `docker info | grep -A10 'Registry Mirrors'`; if it's empty despite `useChineseMirror=true` and `~/.config/docker/daemon.json` has content, you're in this state.

Two ways out:

1. **Pivot to rootless (recommended)** — matches the repo default. Re-run the ansible role: it now installs `docker-ce-rootless-extras` + prereqs, disables the rootful daemon, runs `dockerd-rootless-setuptool.sh install`, and enables `loginctl enable-linger`. After it finishes, `systemctl --user daemon-reload && systemctl --user restart docker`, then verify `docker info` shows your mirrors.
2. **Stay rootful** — copy the mirrors into `/etc/docker/daemon.json` using the recipe above, restart the system daemon, and set `useChineseMirror=false` in chezmoi (or accept the no-op rootless file sitting unused).

#### Toggling the chezmoi-managed one

Turn mirrors off without editing the template:

```bash
chezmoi init --force   # answer `n` to useChineseMirror
chezmoi apply
# the modify script strips .["registry-mirrors"] on next apply
systemctl --user reload docker
```

### Strategy B: prefix substitution (kubesre)

For registries that `registry-mirrors` can't help with. Model: rewrite the image reference to route through a mirror's own domain. No `daemon.json` entry needed.

Source: [kubesre/docker-registry-mirrors](https://github.com/kubesre/docker-registry-mirrors). The public endpoint is rate-limited (20 req/min per IP at time of writing); self-host if you care about sustained throughput — upstream README has a one-file Cloudflare Worker recipe.

Two forms:

1. **Prefix-add** (recommended):

   ```text
   k8s.gcr.io/coredns/coredns        =>  kubesre.xyz/k8s.gcr.io/coredns/coredns
   ```

2. **Prefix-replace** per registry:

   | Upstream | Replace with |
   |----------|-------------|
   | `docker.io` | `dhub.kubesre.xyz` (note: `docker.kubesre.xyz` is blocked) |
   | `gcr.io` | `gcr.kubesre.xyz` |
   | `ghcr.io` | `ghcr.kubesre.xyz` |
   | `k8s.gcr.io` | `k8s-gcr.kubesre.xyz` |
   | `registry.k8s.io` | `k8s.kubesre.xyz` |
   | `mcr.microsoft.com` | `mcr.kubesre.xyz` |
   | `nvcr.io` | `nvcr.kubesre.xyz` |
   | `quay.io` | `quay.kubesre.xyz` |
   | `docker.elastic.co` | `elastic.kubesre.xyz` |
   | `cr.l5d.io` | `l5d.kubesre.xyz` |

Example workflow — pull through the mirror, then re-tag to the canonical name so local references don't have to change:

```bash
docker pull ghcr.kubesre.xyz/kubevirt/virt-launcher:v1.2.0
docker tag  ghcr.kubesre.xyz/kubevirt/virt-launcher:v1.2.0 \
            ghcr.io/kubevirt/virt-launcher:v1.2.0
```

Or for a Dockerfile / compose.yaml, change the image reference in-place.

**When to use which:**

- `docker.io/foo:bar` → Strategy A (daemon.json) handles it transparently. No image-ref change needed.
- `gcr.io/foo:bar`, `ghcr.io/...`, `quay.io/...` → Strategy B (rewrite).
- Practical pattern: both at once — daemon.json for Docker Hub, rewrite non-Hub refs as needed.

## OrbStack evaluation

Current macOS default in [dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml) (falls back to Docker Desktop if Docker Desktop is already installed — to avoid fighting with an existing install).

Why it won the slot:

- **RAM**: OrbStack idles at a few hundred MB; Docker Desktop typically sits around 2 GB+ for the same zero-container state.
- **Boot**: sub-second cold start vs Docker Desktop's 10-30 s VM boot.
- **Apple Silicon**: native virtualization, no Rosetta penalty for `arm64` images.
- **Built-in K8s**: single-toggle lightweight cluster, faster than Docker Desktop's embedded k8s.
- **Docker CLI drop-in**: `docker` / `docker compose` / `docker buildx` work identically; `~/.docker/config.json` is respected (so the chezmoi-managed client proxy works).

When to fall back to Docker Desktop:

- **Enterprise policies** that mandate Docker Desktop (auth, audit, support contract).
- **Compose V1 edge cases** — rare, but Docker Desktop ships with the reference implementation.
- **Windows host** — OrbStack is macOS-only.

OrbStack stores its daemon overrides in `~/.orbstack/config/docker.json` (same schema as `/etc/docker/daemon.json`). Registry mirrors added there take effect after an OrbStack restart (GUI handles the restart automatically on save).

## Podman evaluation

A reasonable future swap for Linux / macOS developer boxes. Not switched by default because the Docker compose ergonomics are still slightly smoother in the Docker ecosystem.

When to consider:

- **License cleanliness** — Podman is Apache-2.0 all the way down; no Docker Desktop license tier to worry about.
- **Daemonless + rootless-by-default** — matches the security story of rootless Docker without the systemd user-unit machinery. `podman run` forks directly as your user; there's no long-lived daemon to restart.
- **`alias docker=podman`** — covers 80-90% of day-to-day `docker run` / `docker build` / `docker ps` usage without code changes.

When to hold off:

- **`podman compose` lags `docker compose`** on networking edge cases (user-defined bridges with custom DNS, service aliases across networks) and some volume semantics.
- **BuildKit feature parity** — podman uses `buildah` under the hood; most BuildKit features work but occasionally a specific `--mount=type=cache` or secret-handling syntax diverges.
- **No Swarm** (rarely relevant for personal use, but existing).
- **macOS** requires `podman machine` — another VM with its own lifecycle, negating some of podman's "no daemon" appeal on a Mac.

Proxy config: pure environment variables (no daemon). The `proxy-on` shell function from [dot_config/zsh/tools/50_networking.zsh](../../dot_config/zsh/tools/50_networking.zsh) exports `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` into the current shell — those are exactly the vars `podman run` / `podman build` honor.

Registry mirrors: different schema. `~/.config/containers/registries.conf` uses `[[registry]]` blocks with `mirror` sub-blocks:

```toml
unqualified-search-registries = ["docker.io"]

[[registry]]
prefix   = "docker.io"
location = "docker.io"
  [[registry.mirror]]
  location = "docker.m.daocloud.io"
  [[registry.mirror]]
  location = "docker.mirrors.ustc.edu.cn"
```

Not chezmoi-managed in this repo (no Podman install role yet). Add one if you actually switch.

Verdict: useful to know, not worth switching today. Revisit if Docker's license situation tightens or if rootless-Docker's networking story becomes a real blocker.

## Verification checklist

```bash
# 1. Client proxy (chezmoi-managed)
jq '.proxies' ~/.docker/config.json
docker run --rm alpine env | grep -iE 'proxy'

# 2. Daemon proxy
docker info | grep -iE 'proxy'

# 3. Registry mirrors
docker info | grep -A10 'Registry Mirrors'

# 4. End-to-end: pull an image, measure time. Should use mirror first if set.
time docker pull hello-world

# 5. Confirm chezmoi-managed files are what you expect
chezmoi managed | grep -iE 'docker'
chezmoi diff ~/.docker/config.json ~/.config/docker/daemon.json
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `docker pull` is slow / times out | No daemon proxy set on a GFW network | Write the systemd drop-in ([above](#rootless-docker-linux--systemd---user-drop-in)) or add `registry-mirrors`; restart daemon |
| `docker run` inside container can't reach the internet | No client proxy; or `$LOCAL_PROXY_URL` unset when `chezmoi apply` ran | Export `$LOCAL_PROXY_URL`, re-apply: `chezmoi apply`; verify with `docker run --rm alpine env \| grep -i proxy` |
| `docker info` shows old proxy after config change | Daemon not restarted | `systemctl --user daemon-reload && systemctl --user restart docker` (or equivalent for your variant) |
| Registry-mirrors in `daemon.json` ignored for `gcr.io` pull | Strategy A is Docker-Hub-only by design | Use [kubesre prefix substitution](#strategy-b-prefix-substitution-kubesre) |
| `chezmoi diff` churns every apply with formatting-only changes | `jq` always pretty-prints; the pre-existing file was minified | Cosmetic — accept the diff once; subsequent applies are no-ops |
| `~/.docker/config.json` got clobbered and I lost my `auths` | Did you bypass the `modify_` script? | The repo's script uses `jq --arg` path-scoped writes and preserves other keys. If you edited by hand, restore from `docker login` (or your cred store) |
| `useChineseMirror=false` but `~/.config/docker/daemon.json` still has mirrors | Stale from a previous apply + template runs correctly but target daemon file isn't being touched | Check `chezmoi diff ~/.config/docker/daemon.json`; on macOS the modify-script emits empty output and chezmoi leaves the file alone, so you may need to delete it manually |

## Related

- [docs/tools/container-config-map.md](container-config-map.md) — reference map for every container config file (who reads it, rootful vs rootless, native vs compat).
- [docs/tools/web-reader.md](web-reader.md) — the `$LOCAL_PROXY_URL` convention and shell proxy helpers shared with this setup.
- [docs/shells/aliases.md](../shells/aliases.md) — `proxy-on` / `proxy-off` / `withproxy` / `try_direct_then_proxy` quick reference.
- [docs/linux-package-sources.md](../linux-package-sources.md) — broader Linux package policy (apt vs snap vs brew vs GitHub binaries) if you're deciding whether to install Docker via apt or Linuxbrew.
