# Container Config Map — Who Reads Which File

Reference map for the sprawling "Docker config" landscape. If you're about to edit a file that looks Docker-shaped and you're not sure which layer it belongs to, start here. For operating recipes (what this repo actually manages and how to configure your box), see [containers.md](containers.md).

Short version: what looks like "one config, many locations" is actually several independent layers that happen to all mention Docker. The same filename can mean completely different things depending on who reads it.

## The four readers

Every "Docker config" file on your disk is read by exactly one of these:

1. **Docker CLI** (`docker`) — the command-line client, reads user-scoped client preferences.
2. **Docker daemon** (`dockerd`) — the engine process that actually builds/pulls/runs containers.
3. **Service manager** (systemd in practice) — reads unit files and drop-ins to decide how the daemon starts.
4. **Desktop app wrapper** (Docker Desktop, OrbStack) — a GUI/VM layer that packages its own settings store on top of the engine.
5. **Compatibility layers** (Podman, OrbStack) — read some Docker files for interop, ignore others entirely.

The canonical paths per reader:

| Reader | Canonical path | Contents | Notes |
|--------|----------------|----------|-------|
| Docker CLI | `~/.docker/config.json` | `auths`, `credsStore`, `credHelpers`, `currentContext`, `proxies.default`, `plugins`, `features` | Not a daemon file. Overridable with `$DOCKER_CONFIG`. |
| Docker daemon (rootful) | `/etc/docker/daemon.json` | `registry-mirrors`, `proxies`, `data-root`, `dns`, `insecure-registries`, `experimental`, `features`, ... | Requires root to edit. `proxies` (Engine ≥ 23) is the daemon-side proxy — the one `docker pull` obeys. |
| Docker daemon (rootless) | `~/.config/docker/daemon.json` | Same schema as rootful | Path deliberately different from the CLI dir (`~/.docker`). Two writers, one key each — see below. |
| systemd (rootful) | `/etc/systemd/system/docker.service.d/*.conf` | `Environment=HTTP_PROXY=...`, `ExecStart=` overrides | Drop-in, runs under PID 1. |
| systemd (rootless) | `~/.config/systemd/user/docker.service.d/*.conf` | Same idea | Runs under `systemctl --user`. |
| Docker Desktop (macOS) | `~/Library/Group Containers/group.com.docker/settings-store.json` | Full Desktop settings store (proxy, Kubernetes toggle, resource limits, ...) | Editing directly is discouraged; GUI overwrites. |
| Docker Desktop (Linux) | `~/.docker/desktop/settings-store.json` | Same idea | |
| Docker Desktop (Windows) | `%APPDATA%\Docker\settings-store.json` | Same idea | |
| Docker Desktop managed (enterprise) | `admin-settings.json` (platform-specific) | Policy overrides pushed by org admin | |
| OrbStack | `~/.orbstack/config/docker.json` | Same schema as `daemon.json`; governs OrbStack's embedded engine | Not `/etc/docker/daemon.json`. |
| Podman | `containers.conf`, `storage.conf`, `registries.conf`, `auth.json` | Podman's own config family, XDG-scoped | Does **not** read `daemon.json`. May fall back to `~/.docker/config.json` for auth only. |

## Install variant matrix

Same Docker command, different files actually in play. Four real-world install shapes:

### A. Docker Engine rootful (Linux, system daemon)

- **Client**: `~/.docker/config.json`
- **Daemon**: `/etc/docker/daemon.json`
- **Service override**: `/etc/systemd/system/docker.service.d/*.conf`
- **Socket**: `/var/run/docker.sock`
- **Data**: `/var/lib/docker`

Scope: daemon is machine-wide (all users in the `docker` group can talk to the same daemon). Editing the daemon config needs `sudo`. Service restart kicks all running containers.

### B. Docker Engine rootless (Linux, per-user daemon)

- **Client**: `~/.docker/config.json`
- **Daemon**: `~/.config/docker/daemon.json`
- **Service override**: `~/.config/systemd/user/docker.service.d/*.conf`
- **Socket**: `$XDG_RUNTIME_DIR/docker.sock` (typically `/run/user/$UID/docker.sock`)
- **Data**: `~/.local/share/docker`

Scope: per-user. No sudo for anything on the daemon side. Restart only affects your containers. `systemctl --user` must be active (`dbus-user-session` package + `loginctl enable-linger` for post-logout persistence). Set `DOCKER_HOST=unix://...` so the CLI finds the user socket.

This is the Linux default in this repo — see [dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml).

### C. Docker Desktop (macOS / Windows / sometimes Linux)

- **Client**: `~/.docker/config.json` (same as everywhere)
- **Desktop settings**: `settings-store.json` (platform-specific path above)
- **Daemon config editor**: GUI → Settings → Docker Engine (writes a JSON blob that Docker Desktop feeds to the VM's `dockerd`)
- **Proxy**: Settings → Resources → Proxies. **Docker Desktop ignores `daemon.json` for proxy** — this is explicit in the upstream docs; proxy has to go through the Desktop UI.
- **Enterprise policy**: `admin-settings.json` for managed deployments

Scope: the Desktop app owns the daemon lifecycle (VM boot, engine restart). Editing JSON files by hand may work until the GUI rewrites the same keys on next launch.

### D. OrbStack (macOS)

- **Client**: `~/.docker/config.json`
- **Daemon config**: `~/.orbstack/config/docker.json` (same schema as `daemon.json`) or GUI → Settings → Docker
- **Socket compat**: when granted admin privilege, OrbStack symlinks `/var/run/docker.sock` to its engine socket so third-party tools that hard-code the rootful path still work
- **Proxy**: GUI → Settings → Network → Proxy

Scope: VM-backed, similar lifecycle story to Docker Desktop but with a different settings path. Not Docker-native: the traditional `/etc/docker/daemon.json` path is unused.

### E. Podman (Linux + macOS via `podman machine`)

- **CLI auth (fallback)**: `~/.docker/config.json` — Podman looks at its own `auth.json` first, falls back here
- **Own config family**:
  - `~/.config/containers/containers.conf` — runtime, engine, network defaults
  - `~/.config/containers/storage.conf` — storage driver / graphroot
  - `~/.config/containers/registries.conf` — registry search order + mirrors (TOML `[[registry]]` blocks, not `daemon.json` schema)
  - `$XDG_RUNTIME_DIR/containers/auth.json` — auth tokens
- **Socket (rootless)**: `$XDG_RUNTIME_DIR/podman/podman.sock`
- **Data**: `~/.local/share/containers/storage`

Scope: daemonless (Podman forks processes directly as your user; no long-lived engine to restart). No `daemon.json`. Docker compatibility is via a REST API shim and a compose provider, not file-level sharing.

## Why `~/.docker` and `~/.config/docker` coexist

Historical accident:

- `~/.docker` predates the XDG Base Directory spec's broad adoption. It's the long-standing Docker CLI home.
- Rootless Docker is newer; it was designed around XDG (`~/.config/docker/daemon.json`, `~/.local/share/docker`, `$XDG_RUNTIME_DIR/docker.sock`).
- The two paths coexist because changing `~/.docker` would break every tool that hard-codes it.

Upstream docs explicitly call this out: the rootless daemon config dir (`~/.config/docker`) is **intentionally different** from the client dir (`~/.docker`). They're for different readers.

## Compatibility layer gotchas

Things that look compatible but aren't, or vice versa:

- **Podman reads `~/.docker/config.json`** — for auth fallback only. It does not read `daemon.json`. If you swap `docker` for `podman`, your registry auth still works; your mirrors don't.
- **OrbStack's socket symlink** — when `/var/run/docker.sock` points to OrbStack's engine, tools like VS Code Dev Containers, Testcontainers, and anything with `DOCKER_HOST=unix:///var/run/docker.sock` hard-coded "just work". But the actual daemon config is in `~/.orbstack/config/docker.json`, not `/etc/docker/daemon.json`.
- **Docker Desktop ignores `daemon.json` for proxy** — upstream docs are explicit: proxy config must come from the Desktop UI (or `admin-settings.json`). Writing `proxies` into `daemon.json` silently does nothing on Desktop.
- **`registry-mirrors` only mirrors Docker Hub** — not `gcr.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, etc. For those, see [containers.md's Strategy B (kubesre prefix substitution)](containers.md#strategy-b-prefix-substitution-kubesre).
- **Rootful and rootless are independent** — a systemd drop-in in `/etc/systemd/system/docker.service.d/` does nothing for the `systemctl --user` docker unit, and vice versa. Neither affects the Docker Desktop VM's engine.

## Decision rubric

When you find a "Docker config" file in the wild and aren't sure what it controls, ask three questions:

1. **Who reads it?** CLI? daemon? systemd? Desktop app? compat layer?
2. **Rootful or rootless?** (Only relevant for Linux native Docker.) Look at the path prefix: `/etc/...` or `/var/...` → rootful; `~/.config/...`, `~/.local/...`, `$XDG_RUNTIME_DIR/...` → rootless.
3. **Native Docker or compatibility layer?** `/etc/docker/...` / `~/.config/docker/...` / `~/.docker/...` → native. `~/.orbstack/...` → OrbStack. `~/.config/containers/...` → Podman. `settings-store.json` / `admin-settings.json` → Docker Desktop.

Once you've answered those, the file's scope and restart semantics follow.

## What this repo manages vs leaves alone

Recap of boundaries — full operating recipes are in [containers.md](containers.md):

| Layer | File | Who writes it |
|-------|------|---------------|
| System layer (root) | `/etc/docker/...`, `/etc/systemd/...` | Ansible (with `sudo`), only for the rootful fallback path; normally not touched |
| User layer (daemon, `registry-mirrors`) | `~/.config/docker/daemon.json` | chezmoi: [dot_config/docker/modify_daemon.json.tmpl](../../dot_config/docker/modify_daemon.json.tmpl) |
| User layer (daemon, `proxies`) | `~/.config/docker/daemon.json` | `docker-net on` / `off` at runtime ([docker-net.md](docker-net.md)) |
| User layer (systemd override) | `~/.config/systemd/user/docker.service.d/proxy.conf` | Manual, and only needed on Engine < 23 (recipe in `containers.md`) |
| User layer (client) | `~/.docker/config.json` | chezmoi: [dot_docker/modify_config.json.tmpl](../../dot_docker/modify_config.json.tmpl) |
| Install itself | Docker Engine + rootless setup | Ansible: [dot_ansible/roles/docker/tasks/main.yml](../../dot_ansible/roles/docker/tasks/main.yml) |
| Desktop apps | OrbStack / Docker Desktop settings | The GUI owns them; don't track in dotfiles |

Principle: **system-layer config goes through Ansible (with sudo), user-layer config goes through chezmoi.** The rootless pivot is what makes that line clean on Linux — the only Docker config chezmoi manages now is user-scoped, so it works without root.

`~/.config/docker/daemon.json` is the one file with two writers, and they stay out of each other's way by owning **disjoint keys**: the chezmoi `modify_` script only ever sets or deletes `registry-mirrors`, so a `proxies` block written by `docker-net` survives every apply. The split is deliberate — a mirror list is the same on every host and belongs in the template, while a proxy URL moves per host and per session and would go stale the moment it were baked in at apply time.

## Related

- [containers.md](containers.md) — operating recipes, proxy strategies, mirror endpoint notes, troubleshooting.
- [web-reader.md](web-reader.md) — the `$LOCAL_PROXY_URL` convention shared with the shell proxy helpers.
- [docker-net.md](docker-net.md) — diagnosing which of these files the live daemon actually read, and writing the daemon proxy.
- [dot_config/shell/50_networking.sh](../../dot_config/shell/50_networking.sh) — `proxy-on` / `withproxy` helpers and the rootless `DOCKER_HOST` export.
