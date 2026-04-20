# Linux Package Sources: apt vs Linuxbrew vs snap vs GitHub binaries

This repo mixes several package sources on Linux. This document explains what each is good at, the trade-offs, and the policy the ansible roles follow.

These package managers are **complementary, not substitutes**. Picking the right source for a tool is what keeps this dotfiles setup fast, portable, and safe across `ubuntu_desktop`, `ubuntu_server`, and `noRoot` profiles.

## Side-by-side comparison

| Dimension | apt | snap | Linuxbrew | GitHub binary |
|---|---|---|---|---|
| Version freshness | Poor (LTS freeze) | Medium–Good | **Good** (near-upstream) | Good |
| Sudo required | Yes | Yes (+ snapd daemon, needs systemd) | Yes at install (chown `/home/linuxbrew`) | **No** |
| Cross-platform with macOS | Linux-only | Linux-only | **Same formula names as macOS Homebrew** | If upstream ships binaries |
| Sandboxing | None | **AppArmor + strict interfaces** | None | None |
| Startup / resource cost | Lowest | High (squashfs mount + bundled libs per snap) | Medium (bottles ship own lib paths) | Lowest |
| System services / daemons | **Best** | OK but constrained by confinement | Poor (`brew services` on Linux is experimental) | Manual |
| Catalog breadth | Largest | Medium (GUI-heavy) | Strong for CLI / dev tools | One tool per source |
| Upgrade control | Ships with distro upgrades | Auto-refresh (hard to disable cleanly) | Explicit `brew upgrade` (rolling) | Manual / ansible-driven |
| Disk footprint | Small (shared libs) | Large (redundant libs, retains prev. revisions) | Medium (~/.linuxbrew 10–15 GB common) | Small |
| Breakage risk | Low (distro maintainers vetted) | Medium (silent refresh can change behaviour) | Low (rolling, explicit) | Low |
| Works in `noRoot` mode | ❌ | ❌ (snapd needs sudo + systemd) | ⚠️ Unsupported `~/homebrew` mode exists but loses bottles → needs `libevent-dev` etc. → circles back to sudo | ✅ |

## Pick-by-tool-type

| Tool type | Preferred source | Why |
|---|---|---|
| Modern CLI dev tools (tmux, neovim, ripgrep, fd, zoxide, starship, eza, yazi, sesh, television) | **Linuxbrew** if sudo available; **GitHub binary** in `noRoot` | Freshest versions, shared formula names with macOS `Brewfile.darwin`, no confinement friction |
| System daemons / kernel or systemd-adjacent tools (Docker Engine, OpenSSH server, NetworkManager, CUDA, nvidia drivers) | **apt** | snap sandbox fights with host-integrated daemons; brew has no story for system services on Linux |
| Sandboxed or closed-source GUI (Slack, some IDEs, Bitwarden Desktop) | **snap** / flatpak / vendor `.deb` | brew-linux has no cask; apt versions lag; snap's automatic updates + confinement are a fit |
| Language runtimes (Node, Python, Ruby, Rust) | **mise** (already used) | Multi-version, project-aware, user-level — beats every OS package manager for this job |
| Language-ecosystem CLI tools (`uv tool`, `gem`, `cargo install`, `npm -g`) | **Language tool** | Latest upstream, auto-resolves ecosystem deps, installs to user prefix |
| Fully no-sudo environment | **GitHub binary + mise + language tools** | The `noRoot=true` branch of this repo |

## Linuxbrew vs apt

**Prefer Linuxbrew when:**

- The tool is also installed on macOS (shared mental model with `Brewfile.darwin`).
- The apt version is too old for the repo's config (e.g. tmux: Ubuntu 22.04 ships 3.2a, but our popup menu needs ≥ 3.3 — see [tools/tmux/README.md](tools/tmux/README.md)).
- You want explicit, rolling upgrades rather than waiting for the next distro release.

**Stay on apt when:**

- The tool is a system daemon or needs PAM / systemd / `/etc/shells` integration (e.g. `zsh`, `openssh-server`, `docker.io`).
- The machine is disk-constrained — apt shares system libs, brew ships its own stack.
- Unattended security updates matter more than version freshness.

## Linuxbrew vs snap

These cover different surfaces. If the choice is forced:

- **CLI tools → Linuxbrew.** snap-confined CLIs frequently hit issues reading `~/.config`, `~/.ssh`, `/tmp`, or other dotfiles because of AppArmor interface rules. Slow startup (squashfs mount + confinement enforce) is also noticeable for tools invoked often.
- **GUI apps → snap.** Fits the confinement model, auto-update works well for interactive apps that don't need deep filesystem access.

## Repo policy

Summarising how the ansible roles route tool installs:

```
macOS:
  Homebrew (CLI + cask), mas for App Store, mise for language runtimes.

Linux with sudo (ubuntu_desktop, ubuntu_server):
  a) CLI dev tools      → apt baseline; Linuxbrew upgrade when available
                          (or when apt version fails our minimum)
  b) System daemons     → apt
  c) Sandboxed GUI      → snap or flatpak or vendor .deb
                          (dotfiles role does not manage these beyond what
                          Brewfile.linux and explicit snap tasks touch)
  d) Language tooling   → mise / uv / cargo / gem / npm

Linux noRoot (ubuntu_server + noRoot=true):
  GitHub release binaries → ~/.local/bin
  AppImage (extracted)    → ~/.local/share/<tool>/
  mise + language tools   → ~/.local/bin, ~/.local/share
```

### Example: tmux

A concrete case where the policy above matters:

1. apt installs tmux 3.2a on Ubuntu 22.04.
2. The config uses `display-menu -x R -y P` which 3.2a silently suppresses (per its man page: _"If the menu is too large to fit on the terminal, it is not displayed."_).
3. The devtools role runs a version check and upgrades:
   - If Linuxbrew is present → `brew install tmux` (3.5a+).
   - Else on x86_64 → downloads [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage), extracts it (no FUSE), drops a shim at `~/.local/bin/tmux`.
   - Else (non-x86_64 + no brew) → prints a warning; user must build from source or enable Linuxbrew.

This is the pattern to replicate whenever an apt-shipped tool is too old for what the dotfiles config relies on.

## Why not "just use Linuxbrew for everything"?

- **Disk:** 10–15 GB for `/home/linuxbrew` is non-trivial on VMs / servers.
- **System services:** brew cannot replace `systemctl`-managed packages cleanly.
- **First-boot cost:** every Linux provision pays the brew-install time even if 90% of tools came from apt faster.
- **Second-class platform:** Homebrew's own docs treat Linux as "best-effort"; Linux-only bottles sometimes lag macOS. `brew services` is experimental.
- **No sandbox benefit over apt** — both run as the user (or root) with full filesystem access.

## Why not "just use snap for everything"?

- **CLI tools suffer under confinement** — `snap install nvim` then trying to read `~/.config/nvim/init.lua` via a hardlink or external editor plugin can silently fail under AppArmor rules.
- **Refresh surprises** — snaps auto-refresh by default on a cadence you don't fully control; a CI or deploy script relying on a specific CLI version can break overnight.
- **Slow launch** — matters when a tool is invoked many times per shell session (shell prompts, completion scripts).
- **Server profile avoids snapd** — `ubuntu_server` deliberately keeps snapd out of the loop.

## Related docs

- [ansible.md](ansible.md) — how to run and customise the ansible roles
- [tools/tmux/README.md](tools/tmux/README.md) — the tmux ≥ 3.3 requirement and fallback install
- Root [CLAUDE.md](../CLAUDE.md) — "Ansible vs Homebrew" section and per-tag tool breakdown
