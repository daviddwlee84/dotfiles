---
name: docker ubuntu pull diagnostic
overview: Run a 3-phase diagnostic on this chezmoi-setup Mac to verify whether our Docker proxy/mirror tooling can solve the `ports.ubuntu.com` unreachable problem the V2Ray project hit, without modifying any files in this repo.
todos:
  - id: phase1_smoke
    content: "Phase 1: baseline `docker pull ubuntu:24.04` (both arches) + `apt-get update` inside amd64 and arm64 to reproduce (or disprove) the ports.ubuntu.com failure on this network"
    status: completed
  - id: phase2_proxy
    content: "Phase 2 (conditional on Phase 1 failing): probe Clash from a container via host.docker.internal:7891, then one-shot `LOCAL_PROXY_URL=http://host.docker.internal:7891 chezmoi apply`, verify `proxies.default` injected, and retest arm64 apt-get"
    status: completed
  - id: phase3_mirror
    content: "Phase 3 (fallback): document the `sed` snippet that rewrites ports.ubuntu.com to mirrors.tuna.tsinghua.edu.cn/ubuntu-ports inside the Dockerfile, independent of any host proxy"
    status: completed
  - id: phase4_revert
    content: "Phase 4: `unset LOCAL_PROXY_URL && chezmoi apply` to revert ~/.docker/config.json; verify `.proxies` back to null; no commits to this repo"
    status: completed
  - id: writeup
    content: "Summarize findings for the V2Ray project: whether Clash-via-host.docker.internal fixed the arm64 apt case, and hand over the mirror-swap snippet as a no-proxy fallback (the real fix for a VPN project's test harness: bootstrap cannot depend on the VPN being up)"
    status: completed
isProject: false
---

## Background

The other project's failure was `apt-get` inside an `ubuntu:24.04` arm64 container reaching `ports.ubuntu.com` (the non-amd64 Ubuntu archive), not the `docker pull` itself. `registry-mirrors` in `daemon.json` only proxies `docker.io`, so that layer is irrelevant here. The layer that CAN fix it is the **client-side proxy** in `~/.docker/config.json` `proxies.default`, which Docker auto-injects into every container as `HTTP_PROXY` / `HTTPS_PROXY`. See [docs/tools/containers.md](docs/tools/containers.md) section "Client-side proxy (chezmoi-managed)".

Current state on this Mac:

- `Operating System: Docker Desktop`, `Server Version: 29.1.3`.
- Docker Desktop daemon proxy already set (`http.docker.internal:3128`) — so `docker pull` should work.
- `~/.docker/config.json` → `"proxies": null`; `LOCAL_PROXY_URL` unset. Containers get **no** proxy env today. This is the gap vs. what the V2Ray Ubuntu build would need.
- Clash running at `http://127.0.0.1:7891`.

## Critical detail: container-reachable proxy URL

The [`dot_docker/modify_config.json.tmpl`](dot_docker/modify_config.json.tmpl) script (lines 24-30) copies `$LOCAL_PROXY_URL` verbatim into `proxies.default.httpProxy`. That URL is handed to processes **inside containers** — where `127.0.0.1` is the container's own loopback, not the Mac. On Docker Desktop the container-reachable hostname for the Mac host is `host.docker.internal`. So for this experiment we override at apply time:

```bash
LOCAL_PROXY_URL="http://host.docker.internal:7891" chezmoi apply ~/.docker/config.json
```

This leaves `dot_config/zsh/tools/50_networking.zsh`'s host-side helpers (`proxy-on`, `withproxy`) unaffected — they can keep using `127.0.0.1:7891` or auto-detect.

Two caveats to verify first:

- **Clash `allow-lan`** — must be `true` in Clash config so connections from `host.docker.internal` (the vpnkit NAT address, not loopback) aren't refused.
- **7891 port type** — common Clash layouts: `port: 7890` = HTTP, `socks-port: 7891` = SOCKS. If 7891 is SOCKS-only, Docker `httpProxy=http://...` will fail and we need either Clash's HTTP port or set `LOCAL_PROXY_SOCKS_URL=socks5://host.docker.internal:7891`.

## Phase 1 — baseline smoke test (no changes)

Reproduce the issue (or confirm it doesn't repro on this network today).

```bash
# 1a. Docker Hub reachability (both platforms)
docker pull ubuntu:24.04
docker pull --platform linux/arm64 ubuntu:24.04

# 1b. apt-get inside — the actual V2Ray-project failure point
#     amd64 hits archive.ubuntu.com (usually fine)
docker run --rm --platform linux/amd64 ubuntu:24.04 sh -c 'apt-get update'

#     arm64 hits ports.ubuntu.com (the one that failed for the other project)
docker run --rm --platform linux/arm64 ubuntu:24.04 sh -c 'apt-get update'
```

Expected outcomes:

- `docker pull` succeeds (Docker Desktop's built-in proxy relay already handles it).
- `amd64` apt likely succeeds.
- `arm64` apt **may** reproduce "Could not resolve 'ports.ubuntu.com'" / timeout if the network really is the blocker — or succeed trivially if the failure was LAN-specific to the other host.

## Phase 2 — if arm64 apt fails, wire up the client proxy (chezmoi-managed path)

```bash
# 2a. Probe Clash from a container BEFORE editing docker config
docker run --rm curlimages/curl:latest -fsS --max-time 5 \
  -x http://host.docker.internal:7891 https://ifconfig.me || echo "clash not reachable from container"
```

Branches:

- If 2a works → 2b straight away.
- If 2a times out → likely Clash `allow-lan: false`. Turn on "Allow LAN" in ClashX/Clash Verge GUI, retry 2a.
- If 2a returns "unsupported protocol" or similar → 7891 is SOCKS; fall to Phase 3 or set via `LOCAL_PROXY_SOCKS_URL`.

```bash
# 2b. One-shot override for chezmoi apply (shell-scoped, not persisted)
LOCAL_PROXY_URL="http://host.docker.internal:7891" chezmoi apply ~/.docker/config.json

# 2c. Verify the merge landed
jq '.proxies.default' ~/.docker/config.json
# Expect: {"httpProxy":"http://host.docker.internal:7891","httpsProxy":"...","allProxy":"...","noProxy":"localhost,127.0.0.1,.local,..."}

# 2d. Confirm containers now inherit proxy env
docker run --rm ubuntu:24.04 env | grep -iE 'proxy'

# 2e. Retest the actual failure
docker run --rm --platform linux/arm64 ubuntu:24.04 sh -c 'apt-get update'
```

Success criterion: `apt-get update` completes (hundreds of `Get:` / `Hit:` lines, no "Temporary failure resolving" / timeouts).

## Phase 3 — fallback: in-container apt-mirror swap (no proxy needed)

If the Clash route doesn't work (wrong port, `allow-lan` unfixable, or just not desired), the V2Ray Dockerfile can swap `ports.ubuntu.com` → a reachable mirror right before `apt-get update`. This is the recipe to hand back to that project:

```dockerfile
# ubuntu:24.04 on arm64 uses /etc/apt/sources.list.d/ubuntu.sources (deb822)
# Replace with Tsinghua's arm64 ports mirror
RUN sed -i -E \
      -e 's|http://ports\.ubuntu\.com/ubuntu-ports|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports|g' \
      -e 's|http://archive\.ubuntu\.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
      -e 's|http://security\.ubuntu\.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' \
      /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true \
 && apt-get update
```

Alternatives if Tsinghua is blocked: `mirrors.ustc.edu.cn`, `mirror.sjtu.edu.cn`, or `mirrors.aliyun.com/ubuntu-ports`.

## Phase 4 — revert experiment state

```bash
# Strip proxies.default so we don't leave a stale URL in place
unset LOCAL_PROXY_URL LOCAL_PROXY_SOCKS_URL
chezmoi apply ~/.docker/config.json
jq '.proxies' ~/.docker/config.json   # should print: null
```

Nothing in this chezmoi repo changes; no commits. If Phase 2 reveals the `127.0.0.1` vs `host.docker.internal` gap is worth fixing permanently in the template (adding a separate `LOCAL_PROXY_URL_DOCKER` knob, or auto-rewriting `127.0.0.1` → `host.docker.internal` on Darwin), that's a follow-up plan — out of scope here.

## Deliverable back to the V2Ray project

Write up the findings as a short note for Claude Code on the other side:

- Whether `ports.ubuntu.com` is reachable from this network right now.
- Whether Clash-via-`host.docker.internal` fixed the arm64 apt case — if yes, they can stop forcing Alpine.
- The mirror-swap snippet (Phase 3) as a no-proxy alternative that unblocks Ubuntu without depending on any VPN being up (actually the relevant fix for a VPN-project test harness: bootstrapping cannot depend on the thing you're bootstrapping).
