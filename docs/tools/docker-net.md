# docker-net — Docker registry egress under the GFW

`docker-net` is a shell function family ([dot_config/shell/51_docker_net.sh](../../dot_config/shell/51_docker_net.sh), shared bash + zsh) that answers one question this repo previously had no tool for: **why did that `docker pull` fail, and which of the three possible layers do I need to fix?**

It reuses the same proxy detector as [`proxy-status`](../shells/aliases.md) (`__net_detect_proxy` in `50_networking.sh`), so the two can never disagree about which local proxy is up.

```bash
docker-net status            # one screen: install shape, daemon proxy, mirrors, local proxy
docker-net doctor [--deep]   # full diagnosis, layer by layer
docker-net on [URL] [-y]     # give the daemon itself a proxy (restarts it)
docker-net off [-y]          # take it away again
docker-net mirrors           # mirror health only (fast)
docker-net pull REF [args…]  # pull with a fallback ladder
```

## The one thing to understand first

**`docker pull` is executed by the daemon, not by the CLI.** Everything else follows from that:

- Your shell's `HTTPS_PROXY` does **not** affect `docker pull`. The daemon is a separate process with its own environment.
- `~/.docker/config.json`'s `proxies.default` does **not** affect `docker pull` either. That block only injects proxy env *into containers* at `docker run` / `docker build` time.
- Therefore there are exactly three levers, and they cover different sets of registries:

| # | Lever | Covers | Cost |
|---|---|---|---|
| 1 | `registry-mirrors` in `daemon.json` | **Docker Hub only** | free — SIGHUP-reloadable, containers survive |
| 2 | `proxies` in `daemon.json` | everything | daemon **restart** — kills running containers |
| 3 | `skopeo copy` (client-side fetch) | everything | nothing — no daemon change at all |

`docker-net` drives levers 2 and 3, and measures lever 1.

## Why "image not in the mirror" happens

`registry-mirrors` is a Docker-Hub-only mechanism. `ghcr.io`, `gcr.io`, `quay.io`, `registry.k8s.io`, `nvcr.io`, `mcr.microsoft.com` are **never** mirrored by it, no matter what you put in the list.

Even for Docker Hub, a pull-through mirror only serves what it is willing to serve. DaoCloud answers `403 Forbidden` for images it has not cached or has rate-limited, and Docker surfaces that as:

```
Error response from daemon: unknown: failed to resolve reference
"docker.io/library/foo:1.2": unexpected status from HEAD request to
https://docker.m.daocloud.io/v2/library/foo/manifests/1.2?ns=docker.io: 403 Forbidden
```

That reads like *"the image does not exist"*. It is not — the URL inside the message names the mirror that refused. `docker-net doctor` parses exactly this and says so in words. See [pitfalls/docker-pull-fails-dead-registry-mirrors.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/docker-pull-fails-dead-registry-mirrors.md).

## `docker-net pull` — the fallback ladder

Each rung announces itself on stderr, the way `try_direct_then_proxy` prints `[retry via proxy …]`.

```
docker-net pull ghcr.io/foo/bar:v1

  rung 1  docker pull <ref>                     mirrors apply (Docker Hub only), daemon proxy applies
  rung 2  docker pull <mirror>/<path> + retag   Docker Hub only; names the mirror explicitly so
                                                Docker cannot abandon the chain on the first error
  rung 3  skopeo copy docker://<ref> \          the CLIENT does the network, honouring your shell
            docker-daemon:<ref>                 proxy, and writes straight into the daemon
  rung 4  (advice) docker-net on / doctor
```

Rung 3 is the important one. It is the only way to fetch an image the mirrors do not carry **without restarting the daemon** — which matters when you have containers you cannot drop.

Rung 2 inserts the implicit `library/` that Docker Hub official images carry: `nginx` is really `library/nginx`, and a mirror 404s without it.

```bash
DOCKER_NET_PLATFORM=linux/amd64 docker-net pull ghcr.io/foo/bar:v1   # cross-arch fetch
```

## Client-side registry tools

Rung 3 needs a client that speaks the registry API itself. This repo installs **skopeo** (devtools ansible role: apt on Debian/Ubuntu, brew on macOS). The alternatives, for when you want something else:

| Tool | Install | Writes into the Docker daemon | Honours `HTTPS_PROXY` | What it is for |
|---|---|---|---|---|
| **skopeo** | apt (`universe`) + brew | **yes** — `docker-daemon:` transport | yes | Registry↔registry and registry↔daemon copying without a local daemon pull. Also `skopeo inspect` for manifests/digests without downloading layers. The repo's choice: the only one in both apt and brew, and the only one that needs no intermediate tarball. |
| **crane** (`go-containerregistry`) | brew, GitHub release | via `crane pull REF - \| docker load` | yes | Single static Go binary, no deps — nice in CI images. `crane copy`, `crane digest`, `crane ls` are pleasant. Not in Ubuntu apt. |
| **regctl** (`regclient`) | brew, GitHub release | via `regctl image export … \| docker load` | yes | The most precise manifest/index surgery: `regctl index create`, per-platform manifest edits, digest pinning. Reach for it when you care about multi-arch manifest lists. |
| **nerdctl** | GitHub release | no — talks to **containerd**, not dockerd | yes | Docker-compatible CLI for containerd/k3s hosts. Useful if your images need to land in containerd's store (k8s), not Docker's. |
| **oras** | brew, GitHub release | no | yes | OCI *artifacts* (Helm charts, SBOMs, WASM, signatures) rather than runnable images. Not a `docker pull` substitute. |
| **podman** | apt + brew | no — its own image store | yes | A whole second runtime. `podman pull` + `podman save \| docker load` works but is a heavy answer to a fetch problem. |

Quick recipes if you prefer one of the others:

```bash
# crane
withproxy crane pull ghcr.io/foo/bar:v1 - | docker load

# regctl
withproxy regctl image export ghcr.io/foo/bar:v1 - | docker load

# skopeo, but to a file you can carry to an air-gapped host
withproxy skopeo copy docker://ghcr.io/foo/bar:v1 docker-archive:/tmp/bar.tar:ghcr.io/foo/bar:v1
```

All of them are ordinary user-space clients, so `withproxy` (or any `HTTPS_PROXY` export) is enough — that is the entire reason this rung exists.

## `docker-net on` — giving the daemon a proxy

Writes `proxies` into the daemon.json that the **active** daemon reads, then restarts it:

```json
{
  "proxies": {
    "http-proxy": "http://127.0.0.1:7890",
    "https-proxy": "http://127.0.0.1:7890",
    "no-proxy": "localhost,127.0.0.1,::1,*.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,docker.m.daocloud.io"
  }
}
```

Notes:

- **Every configured mirror host is added to `no-proxy` automatically.** A CN mirror routed back out through your proxy is slower and often broken.
- The URL comes from `__net_detect_proxy` when you do not pass one — same answer as `proxy-status`. Override with `DOCKER_NET_PROXY` (`auto|always|never|http://host:port`) or a positional argument.
- `socks://` is **rejected**. It is not a scheme Go's proxy parser or curl accepts, and a daemon configured with it makes no connections at all while looking configured. Use `socks5://`.
- Running containers are listed and confirmed before the restart. Without a TTY (e.g. `fleet exec`) it refuses rather than hangs unless you pass `-y`.
- Requires Docker Engine ≥ 23 for the `proxies` key. Older engines need the systemd drop-in recipe under "Daemon-side proxy" in [containers.md](containers.md).
- **Not available on macOS** — Docker Desktop and OrbStack run the daemon in a VM, so this refuses and points at their UI. See [macOS](#macos).

### Why daemon.json and not a systemd drop-in

One file instead of two mechanisms; identical for rootless and rootful; no systemd knowledge; and it works on hosts without systemd. `dockerd --http-proxy/--https-proxy/--no-proxy` exist as flags, which is the same config surface.

### Why chezmoi does not manage it

`daemon.json` has two writers, each owning **only its own key**:

| Key | Owner |
|---|---|
| `registry-mirrors` | chezmoi — [`modify_daemon.json.tmpl`](../../dot_config/docker/modify_daemon.json.tmpl), declarative, same on every host |
| `proxies` | `docker-net on` / `off`, at runtime |

The `modify_` script only ever sets or deletes `registry-mirrors`, so a `proxies` block written by `docker-net` survives every `chezmoi apply`. The split exists because the local proxy port moves between hosts and sessions (Clash Verge 7897, mihomo 7890, a random SSH tunnel) — a value baked in at apply time goes stale fast.

For fleet-wide setup, broadcast it explicitly:

```bash
just fleet-exec 'docker-net on -y'
just fleet-exec 'docker-net doctor'
```

## Two reload costs, not one

Measured on Docker 29.6.2 rootless, 2026-07, with 8 containers running:

| Change | Command | Containers |
|---|---|---|
| `registry-mirrors` | `systemctl --user reload docker` (SIGHUP) | **survive** — daemon PID and start timestamp unchanged |
| `proxies` | `systemctl --user restart docker` | killed |

`registry-mirrors` is in Docker's SIGHUP-reloadable config set; `proxies` is not. Older revisions of this repo told you to restart for both, which needlessly killed containers on every mirror edit.

## macOS

`docker-net` runs on macOS, but one verb is deliberately unavailable there.

| Verb | macOS | Why |
|---|---|---|
| `status` | ✅ | reports OrbStack / Docker Desktop, mirrors, detected local proxy |
| `doctor` | ✅ | all sections; the netns question is answered as "VM" instead |
| `mirrors` | ✅ | reads the live daemon, whichever engine is behind it |
| `pull` | ✅ | all three rungs — rung 3 needs `brew install skopeo` |
| `on` / `off` | ❌ refuses | the daemon lives in a VM; its proxy is a GUI setting |

### Why `on` refuses

Docker Desktop and OrbStack run `dockerd` inside a Linux VM. `127.0.0.1` in that VM is **the VM's own loopback**, not your Mac's — so writing `http://127.0.0.1:7890` into a daemon config produces a daemon that looks configured and connects to nothing. That is the same silent failure as the detached-netns case on Linux, except macOS has no `/proc` for `docker-net` to detect it from.

So it refuses early, before it prompts about killing containers, and points at the real control:

```
$ docker-net on
docker-net: orbstack runs the daemon inside a VM — its proxy is a UI setting,
  and a 127.0.0.1 URL written here would point at the VM, not your Mac.
  OrbStack: Settings > Network > Proxy
```

- **OrbStack** — Settings → Network → Proxy
- **Docker Desktop** — Settings → Resources → Proxies

Both restart their VM's daemon for you.

### What still helps on macOS

`docker-net pull`'s rung 3 does not care where the daemon lives: `skopeo` runs on your **Mac**, uses your Mac's proxy env, and hands the finished image to the daemon over the Docker socket. So the "image no mirror carries" problem is solved on macOS by exactly the same command, with no VM proxy configured at all:

```bash
brew install skopeo
docker-net pull ghcr.io/foo/bar:v1
```

Real `doctor` output from a Mac behind the GFW shows why the direct-vs-proxy pair of rows matters:

```
Upstream registries (direct)
  ✗ docker.io                  blackholed (timeout)                       10.01s
  ✓ ghcr.io                    healthy                                    0.595s

Upstream registries (via http://127.0.0.1:7897)
  ✓ docker.io                  healthy                                    0.979s
```

Docker Hub is blackholed on that network while ghcr.io is not — so mirrors are load-bearing for Hub images and irrelevant for everything else, which is exactly the split this tool exists to make visible.

`registry-mirrors` on macOS lives in OrbStack's own `~/.orbstack/config/docker.json` (or Docker Desktop's GUI JSON editor) — this repo's [`modify_daemon.json.tmpl`](../../dot_config/docker/modify_daemon.json.tmpl) is Linux-gated and does not touch them. `docker-net mirrors` still measures whatever the live daemon reports, so it is the right tool either way.

### Portability notes

Two macOS-specific traps this file is written around, both silent rather than loud:

- **`/bin/bash` is 3.2.57.** Apple froze it at the last GPLv2 release, so `mapfile`, `declare -A` and `${x^^}` are unavailable. The bash completion uses the repo's usual `COMPREPLY=( $(compgen …) )` form instead. A `tests/unit/docker_net.bats` case greps for bash-4 builtins so this cannot regress.
- **BSD `mktemp` requires a template.** Bare `mktemp` is a usage error on macOS, which would have cost the probe its curl stderr — and with it the difference between "DNS gone", "TLS reset" and "timeout", all of which surface as HTTP `000`. Probes use `mktemp "${TMPDIR:-/tmp}/docker-net.XXXXXX"`.
- **`docker info` never gives up on its own.** Measured on macOS with Docker Desktop installed but *stopped*: it hung past 120 s while printing a well-formed all-empty record, so every verb would have wedged forever and an empty record would have read as a live daemon. Every daemon call now goes through a timeout (with a polling fallback, since stock macOS has no coreutils `timeout`) and a live daemon must produce a non-empty `ServerVersion`. Checking for the socket file is **not** a substitute — Docker Desktop leaves `~/.docker/run/docker.sock` on disk after the daemon stops.
- **Never `local path` in a zsh-sourced file.** zsh ties the `path` array to `PATH`, so the declaration blanks `PATH` for the rest of the function; `command -v` guards then silently flip to false and branches change with no error. This bit `docker-net on` on the first real macOS run and reproduces identically on Linux zsh — bash-only tests cannot see it. Full write-up: [pitfalls/zsh-local-path-blanks-PATH.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/zsh-local-path-blanks-PATH.md).

## Where the daemon lives: `127.0.0.1` is not always your loopback

### Rootless Linux: it *can*, on Docker ≥ 25

Widely repeated advice says a rootless daemon cannot reach a proxy on the host loopback, because it lives in a slirp4netns network namespace with `--disable-host-loopback`. **On Docker ≥ 25 that is out of date.**

RootlessKit ≥ 2.0 passes `--detach-netns`: `dockerd` itself stays in the **host** network namespace, and only containers get the detached one. Verify on your own box:

```bash
readlink /proc/$(pgrep -x dockerd)/ns/net
readlink /proc/self/ns/net
# same inode -> 127.0.0.1 in daemon.json reaches your local proxy
```

`docker-net status` and `docker-net doctor` both check this and say which case you are in — because when they differ, a `127.0.0.1` proxy URL points at the *daemon's* loopback and silently connects to nothing. In that case use the host's LAN IP:

```bash
docker-net on http://192.168.1.50:7890
```

### Transparent (TUN) proxies

If mihomo / clash is running in TUN mode (`auto-route: true`), it intercepts at layer 3 — and since `dockerd` is in the host netns, **the daemon is already proxied with no `proxies` block at all**. `docker-net` detects the TUN interface plus its fake-ip route (`198.18.0.0/15` by default) and says so:

```
✓ Meta                       up, fake-ip route present — daemon egress is proxied at L3
                             → an explicit `docker-net on` is optional while this holds
```

Without this line you cannot tell whether `docker-net on` changed anything, because everything works either way — until the TUN goes down.

## Reading `docker-net doctor`

Nine sections, in dependency order. The last one is the one that matters most:

| Section | Answers |
|---|---|
| Install shape | rootless / rootful / Desktop / OrbStack, and whether the daemon.json you are editing is the one being read |
| Daemon locality | is `127.0.0.1` a usable proxy address here — `host` / detached `netns` / inside a `vm` |
| Stale configuration | orphaned rootful proxy config left behind by the rootless pivot |
| Local proxy | what `proxy-status` sees, plus malformed/half-set proxy env vars |
| Transparent proxy | is a TUN already doing the job |
| Registry mirrors | per-mirror health, classified |
| Upstream registries | direct and via-proxy, for Hub / ghcr / gcr / quay / k8s |
| **Daemon-side egress** | **the same question asked from inside the daemon** |
| Summary | `N failed, M warning(s)` |

The daemon-side section pulls a tag that cannot exist (nothing is downloaded) and classifies the reply. This is the only check that tests the **daemon's** network path; every `curl` above it tests your *shell's*, and the two genuinely differ — different namespace, different proxy config, different DNS. `--deep` extends it past Docker Hub to ghcr/gcr/quay/registry.k8s.io.

Mirror verdicts are classified from the HTTP status and the curl error text:

| Result | Verdict |
|---|---|
| `200` / `401` | healthy (an unauthenticated 401 means the registry answered) |
| `403` | reachable but refusing — campus-only or geo-blocked |
| `5xx` | mirror broken |
| `Could not resolve host` | the domain has no DNS record any more |
| `SSL_ERROR_SYSCALL` / `tlsv1 alert` | TLS reset — blocked, or internal-only |
| timeout | blackholed |

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `DOCKER_NET_PROXY` | `auto` | `auto` \| `always` \| `never` \| `http://host:port`. `auto` delegates to `__net_detect_proxy`. |
| `DOCKER_NET_NO_PROXY` | — | extra comma-separated `no-proxy` entries |
| `DOCKER_NET_MIRRORS` | from `docker info` | override the mirror list used for probing |
| `DOCKER_NET_PLATFORM` | host platform | `os/arch` for the skopeo rung, e.g. `linux/amd64` |

The mirror list is read from the **live daemon** (`docker info`), never from `daemon.json` on disk — a file edited since the last reload would otherwise report mirrors that are not in effect.

## Related

- [containers.md](containers.md) — the wider operating book: four install variants, client-vs-daemon proxy layers, kubesre prefix substitution for non-Hub registries
- [container-config-map.md](container-config-map.md) — who reads which config file
- [mirrors.md](mirrors.md) — every GFW mirror this repo configures, and the trust model for pull-through caches
- [docs/shells/aliases.md](../shells/aliases.md) § Proxy helpers — `proxy-status`, `withproxy`, `try_direct_then_proxy`
- [copilot-claude-proxy.md](copilot-claude-proxy.md) — the other tool built on `__net_detect_proxy`; `docker-net` borrows its `auto|always|never` knob and doctor layout
