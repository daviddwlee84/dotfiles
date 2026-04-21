---
name: container-config-map-rootless-pivot
overview: Document the full "who reads which container config" map as a new reference doc, and pivot the Linux ansible role from rootful convenience-script install to rootless Docker so that the existing chezmoi-managed ~/.config/docker/daemon.json mirrors actually take effect.
todos:
  - id: new_map_doc
    content: Create docs/tools/container-config-map.md with the who-reads-what landscape (CLI/daemon/systemd/Desktop/compat, rootful vs rootless vs Desktop).
    status: completed
  - id: update_containers_doc
    content: "Update docs/tools/containers.md: top-of-file pointer to the new map, flip Linux default to rootless, add migration callout for existing rootful installs."
    status: completed
  - id: pivot_ansible
    content: "Rewrite Debian branch of dot_ansible/roles/docker/tasks/main.yml: install rootless prereqs (uidmap, dbus-user-session, fuse-overlayfs, slirp4netns), run convenience script, disable rootful service, run dockerd-rootless-setuptool.sh install, enable linger, enable user docker service; drop docker-group step."
    status: completed
  - id: docker_host_env
    content: Add guarded DOCKER_HOST export to dot_config/zsh/tools/50_networking.zsh so the CLI targets the rootless socket on Linux.
    status: completed
  - id: template_comment_refresh
    content: "Refresh the header comment in dot_config/docker/modify_daemon.json.tmpl: drop the rootless hedge, point to the new map doc."
    status: completed
isProject: false
---

## Motivation

Two issues surfaced:

1. The ChatGPT mind-map ("CLI vs daemon vs systemd vs Desktop vs compat layer, × rootful/rootless/Desktop") is not in the repo docs. Current [docs/tools/containers.md](docs/tools/containers.md) skips the "who reads what" layer and jumps straight to recipes.
2. Silent mismatch: [dot_ansible/roles/docker/tasks/main.yml](dot_ansible/roles/docker/tasks/main.yml) installs **rootful** Docker on Linux via `get.docker.com`, but [dot_config/docker/modify_daemon.json.tmpl](dot_config/docker/modify_daemon.json.tmpl) writes mirrors to `~/.config/docker/daemon.json` which is the **rootless** path. The rootful daemon reads `/etc/docker/daemon.json` only, so `useChineseMirror=true` is currently a no-op on Linux.

User decision: **pivot Linux to rootless** (matches chezmoi path, no sudo for daemon.json, cleaner "system layer = Ansible, user layer = chezmoi" boundary).

## 1) New doc: docs/tools/container-config-map.md

A reference-only doc covering the full config landscape. Sections:

- **Who reads what** — four readers (CLI / daemon / systemd / Desktop app) explained, with their canonical paths.
- **Variant × file matrix** — bullet lists (no markdown tables in plan per rules; in the doc itself we use tables) for:
  - Docker Engine rootful
  - Docker Engine rootless
  - Docker Desktop (macOS / Windows / Linux)
  - OrbStack
  - Podman
- **Why `~/.docker` and `~/.config/docker` coexist** — historical vs XDG, 1-paragraph explanation.
- **Compatibility layer notes** — Podman `auth.json` falling back to `~/.docker/config.json`; OrbStack's `/var/run/docker.sock` symlink; Docker Desktop ignoring `daemon.json` for proxy.
- **Decision rubric** — three questions to classify any config file you find in the wild ("who reads", "rootful/rootless", "native/compat").
- **Cross-references** to [docs/tools/containers.md](docs/tools/containers.md) (operating recipes) and the two chezmoi template files.

Rationale for a new doc (over expanding `containers.md`): keeps the reference map separate from the operating/recipe content; `containers.md` stays "how do I configure my box" while the new doc is "what are all these files and who owns them".

## 2) Update docs/tools/containers.md

Minimal edits to stay consistent after the pivot:

- Top of file: add a one-line pointer to the new map doc.
- **Runtimes at a glance** table (L30-36): change the "Repo default" line (L38) from "Docker Engine convenience script on Ubuntu" to "rootless Docker Engine on Ubuntu (installed by ansible role; `systemctl --user` lifecycle)".
- **Where each install variant stores config** (L40-49): keep the four rows but reorder/annotate so Rootless is the primary Linux row (System Docker becomes "fallback / legacy").
- **Daemon-side proxy** recipe (L110-123): already correctly describes the rootless drop-in; unchanged.
- **Registry mirrors > Where to put it per install variant** (L201-229): flip the order so rootless is first/default for Linux.
- Add a **Migration note** callout near the registry-mirrors section: "If you previously installed rootful Docker on Linux with this repo (pre-pivot), your mirrors in `~/.config/docker/daemon.json` did not take effect. Re-run the ansible role to set up rootless, or manually copy the mirrors into `/etc/docker/daemon.json`."

## 3) Pivot dot_ansible/roles/docker/tasks/main.yml to rootless on Linux

Replace the current Debian branch (L28-68) with a rootless-oriented flow. Keep the same trigger (docker not yet installed) and idempotent via `creates:` / stat checks.

Concrete task list (in execution order):

- Install packages required by rootless (become=true):
  - `uidmap` (provides `newuidmap` / `newgidmap` for user-namespace mapping)
  - `dbus-user-session` (so `systemctl --user` works over SSH sessions)
  - `iptables`, `fuse-overlayfs`, `slirp4netns` (rootless networking + overlay storage)
- Install Docker Engine packages via the convenience script (unchanged command, still rootful-capable, but we won't start the system daemon):
  - `sh /tmp/get-docker.sh` — still installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, and critically `docker-ce-rootless-extras` which provides `dockerd-rootless-setuptool.sh`.
- Disable the system daemon so only rootless runs (prevents port conflicts / socket confusion):
  - `systemctl disable --now docker.service docker.socket` (become=true, ignore_errors if not present)
- As the target user (become=false), run the rootless setup:
  - Check for `~/.config/systemd/user/docker.service` first (skip if present).
  - `dockerd-rootless-setuptool.sh install` — this creates the systemd --user unit and writes `~/bin/` or `/usr/bin/` helpers.
- Enable lingering so the user daemon survives logout: `loginctl enable-linger {{ ansible_facts['env']['USER'] }}` (become=true).
- Start + enable the user unit via `systemctl --user enable --now docker` (run as the target user; needs `XDG_RUNTIME_DIR` exported — use `ansible.builtin.systemd_service` with `scope: user` and set `environment`).
- Remove the `docker` group membership step (L48-63) — rootless doesn't use a shared docker group; the user-scoped socket in `/run/user/$UID/docker.sock` is user-owned.

Skeleton (new file structure, not literal final code):

```yaml
- when: ansible_facts["os_family"] == "Debian"
  block:
    - name: Install rootless prerequisites
      become: true
      ansible.builtin.apt:
        name: [uidmap, dbus-user-session, fuse-overlayfs, slirp4netns, iptables]
        state: present
        update_cache: true
      tags: [sudo]

    - name: Install Docker packages via convenience script
      # same as today; ensures docker-ce-rootless-extras is present
      ...

    - name: Disable rootful daemon
      become: true
      ansible.builtin.systemd_service:
        name: "{{ item }}"
        enabled: false
        state: stopped
      loop: [docker.service, docker.socket]
      failed_when: false
      tags: [sudo]

    - name: Run rootless setuptool (idempotent)
      ansible.builtin.command: dockerd-rootless-setuptool.sh install
      args:
        creates: "{{ ansible_env.HOME }}/.config/systemd/user/docker.service"

    - name: Enable linger for persistent user services
      become: true
      ansible.builtin.command: "loginctl enable-linger {{ ansible_user_id }}"
      args:
        creates: "/var/lib/systemd/linger/{{ ansible_user_id }}"
      tags: [sudo]

    - name: Enable and start rootless docker user service
      ansible.builtin.systemd_service:
        name: docker
        scope: user
        enabled: true
        state: started
```

## 4) Shell env: export DOCKER_HOST on Linux

Add to [dot_config/zsh/tools/50_networking.zsh](dot_config/zsh/tools/50_networking.zsh) (it already handles Linux-conditional exports for proxies, same neighborhood) a small guarded block:

```zsh
# Rootless Docker: point CLI at user-scoped socket if it exists.
if [[ "$(uname -s)" == "Linux" && -S "${XDG_RUNTIME_DIR:-/run/user/$UID}/docker.sock" ]]; then
  export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$UID}/docker.sock"
fi
```

Purpose: without this, `docker` CLI defaults to `/var/run/docker.sock` which rootless doesn't use. Guarding on socket existence means if the user has rootful Docker for some reason, the export is skipped.

## 5) modify_daemon.json.tmpl touch-up

[dot_config/docker/modify_daemon.json.tmpl](dot_config/docker/modify_daemon.json.tmpl) is already correct for rootless — no template logic change needed. Just update the top comment (L2-16) to:

- Drop the "if applicable" hedge; after the pivot, Linux = rootless in this repo.
- Keep the post-apply reminder (`systemctl --user daemon-reload && restart docker`).
- Point to the new `container-config-map.md` for the full map.

## Out of scope

- Podman install role (stays a "known alternative", not automated).
- Writing `/etc/docker/daemon.json` via ansible (not needed once Linux is rootless; document the recipe in `containers.md` only).
- Windows / macOS changes (OrbStack + Docker Desktop flow is unchanged).
- Auto-migration for machines that currently have rootful installed — document the manual migration step ("disable rootful, run setuptool") in `containers.md` and let the user run it.
