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
  GitHub release binaries → ~/.local/bin (prefer musl over gnu)
  AppImage (extracted)    → ~/.local/share/<tool>/
  mise + language tools   → ~/.local/bin, ~/.local/share
```

### GitHub binary asset selection policy

When a tool is installed from a GitHub release (either as the system-level
source or as the user-level `noRoot` fallback), the ansible roles follow this
selection order:

1. **Prefer `unknown-linux-musl`** (or `musleabihf` for armhf) assets when
   upstream publishes them. musl binaries are statically linked against libc
   and therefore run on any glibc version the kernel can boot.
2. **Use `unknown-linux-gnu` only when no musl asset exists** and the fallback
   is explicitly justified in the role with a comment. gnu binaries inherit
   whatever glibc version the upstream CI uses, which on modern
   `ubuntu-latest` runners is already newer than Ubuntu 22.04 LTS ships.
3. **If no safe musl asset exists for a given arch, prefer Linuxbrew** (when
   available on the host). Homebrew bottles track an older glibc baseline than
   random upstream CI images, so `brew install <tool>` is usually safer than
   the latest gnu release binary.
4. **If Linuxbrew is unavailable too, skip with an explicit `debug:` message**
   instead of silently installing a binary that may fail to start on the user's
   libc. The skip message should name the tool, the arch, and tell the user
   either to install Linuxbrew or to wait for an upstream musl build.

### Example: glibc compatibility on Ubuntu 22.04

Ubuntu 22.04 LTS ships **glibc 2.35**. Several Rust/Go tools now produce
`unknown-linux-gnu` release tarballs that link against glibc 2.38 or 2.39
because their CI runs on `ubuntu-latest` (Ubuntu 24.04) or Debian 13. A
concrete example surfaced in this repo:

```
❯ tv sesh
tv: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found (required by tv)
```

The `devtools` role used to blindly fetch `tv-<version>-<arch>-unknown-linux-gnu.tar.gz`
which caused this failure on a fresh Jammy box. The fix — and the pattern
replicated for all similar cases in the repo — was:

- **television** — upstream ships no musl asset → brew-install when Linuxbrew
  is present, otherwise skip with a debug message pointing to the `GLIBC_2.X`
  error.
- **yazi, fd** — upstream publishes musl assets → switch to
  `unknown-linux-musl.{deb,zip,tar.gz}` for both sudo and noRoot paths.
- **git-delta, eza** — upstream publishes musl for x86_64 only → use musl on
  x86_64; on aarch64 fall through the "brew or skip" path.
- **trippy** — musl targets already exist for every supported arch → the
  system-level path is aligned with the user fallback on `*-unknown-linux-musl`.

This matches the general "install vs upgrade is split on purpose" philosophy
in [CLAUDE.md → Hard repo invariants](../CLAUDE.md#install-vs-upgrade-is-split-on-purpose): `chezmoi apply` should never surprise
a running box by installing a binary that won't run.

If you hit a `GLIBC_2.X not found` failure **after** applying this repo
(e.g. from a stale binary installed before the musl switch, or from a tool
added later that slipped back to gnu), see the symptom-first recovery
entry in [ansible_customization.md → `GLIBC_2.XX not found`](this_repo/ansible_customization.md#glibc_2xx-not-found-when-running-an-installed-cli-ubuntu-2204--older-distros).

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

- **CLI tools suffer under confinement** — the strictly-confined btop snap crashes on launch because AppArmor blocks reads of `~/.config/btop/themes` (see [tools/btop.md](tools/btop.md)). Classic snaps escape the sandbox but keep every other snap downside below.
- **Refresh surprises** — snaps auto-refresh by default on a cadence you don't fully control; a CI or deploy script relying on a specific CLI version can break overnight.
- **Slow launch** — matters when a tool is invoked many times per shell session (shell prompts, completion scripts).
- **Server profile avoids snapd** — `ubuntu_server` deliberately keeps snapd out of the loop.

## snap in this repo

Current state: **exactly one role installs anything via snap** — Bitwarden
Desktop (`dot_ansible/roles/bitwarden/tasks/main.yml`, gated behind the
`installBitwarden` prompt, snap first with a vendor `.deb` fallback). That is
deliberate: a closed-source GUI app is the one category where snap's
auto-update + confinement model is a good fit (see the pick-by-tool-type
table above). Everything else stays off snap.

### Why the Neovim role dropped its snap path (2026-06)

Until June 2026 the neovim role had a middle tier: apt too old + `snap`
on PATH → `snap install nvim --classic`. It was removed (apt too old now
goes straight to the GitHub release tarball → `/opt/nvim` +
`/usr/local/bin/nvim` symlink) because the snap tier contradicted the
repo's own rules:

1. **Auto-refresh violates the [install/upgrade split](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md#install-vs-upgrade-is-split-on-purpose).**
   Snaps refresh themselves on snapd's schedule — nvim could change
   version overnight, outside the explicit `just upgrade-*` path. No
   other tool in this repo upgrades implicitly.
2. **Policy contradiction.** This very page says the server profile
   keeps snapd out of the loop and routes CLI tools to
   Linuxbrew / GitHub binaries — yet a stock `ubuntu_server` devbox
   (old apt nvim + snapd preinstalled) landed on the snap tier.
3. **`~/snap` home clutter** — the symptom that triggered the review:
   a bare `~/snap/nvim` directory appearing in `$HOME` (see below).
4. **Track record.** The repo had already been burned twice by snap
   builds of CLI tools: the chezmoi snap's stdin/stdout bug
   (`scripts/init/dotfiles_init.py` actively detects and avoids it) and
   the btop snap's AppArmor crash
   ([pitfalls/btop-themes-permission-denied-core-dumped.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/btop-themes-permission-denied-core-dumped.md)).
5. The `nvim` snap is community-published (a Canonical employee), not an
   official Neovim project artifact; the GitHub tarball is the upstream
   release itself.

The tarball tier was already battle-tested — it was the existing
"no snap available" fallback and the noRoot user-level path — so the
change only deleted the middle tier, it added no new mechanism.

### snap knowledge worth keeping

- **`~/snap/<name>/` is snapd's per-user data home**, created
  automatically the first time a snap runs. Layout:
  `~/snap/<name>/<revision>/` (versioned `$HOME` for the app),
  `current` symlink, and `common/` (revision-independent data). It is
  *not* an installation directory — binaries live under `/snap/` —
  and nothing is misplaced when you see it. It famously ignores XDG
  conventions (upstream bug open since 2016; an experimental
  `hidden-snap-folder` option to move it to `~/.snap` exists but never
  became default).
- **`classic` vs strict confinement**: strict snaps run inside
  AppArmor with whitelisted interfaces (this is what breaks dotfile
  reads — hidden directories like `~/.config` are blocked by the
  `home` interface). `--classic` snaps run unconfined, like a normal
  package — the nvim snap was classic, so its problem was never the
  sandbox, only refresh/clutter/ownership.
- **Holding refreshes is possible but not our policy**:
  `sudo snap refresh --hold` (snapd ≥ 2.58) holds all updates
  indefinitely, `--hold=72h` per-snap and time-boxed. The repo prefers
  not to depend on per-host snapd state — tools that must not move
  come from apt / tarball instead.
- **Disk/teardown**: snapd keeps previous revisions
  (`refresh.retain`, default 2-3), so even small CLIs cost 2× their
  squashfs size plus a loop mount each.

### Cleaning up a host that got the old snap nvim

Hosts provisioned before the change keep working (the role's version
check passes, so it touches nothing), but converge manually with:

```bash
sudo snap remove nvim          # binary + /snap/nvim revisions
rm -rf ~/snap/nvim             # per-user data dir (safe: nvim state lives in ~/.config/nvim etc.)
# then re-apply so the role installs the tarball tier:
chezmoi apply    # or: just fleet-apply <host>
```

Only remove the **per-app** directory, not all of `~/snap` — on
`ubuntu_desktop` hosts `~/snap` can hold real user data for other snaps
(e.g. the preinstalled Firefox snap keeps its entire profile there).

## Related docs

- [glibc-and-musl.md](glibc-and-musl.md) — when a GitHub binary errors with `GLIBC_2.X not found`, decision tree for musl swap vs Linuxbrew vs distrobox vs OS upgrade
- [this_repo/ansible_customization.md](this_repo/ansible_customization.md) — how to run and customise the ansible roles
- [tools/tmux/README.md](tools/tmux/README.md) — the tmux ≥ 3.3 requirement and fallback install
- [this_repo/architecture.md](this_repo/architecture.md) — "Ansible vs Homebrew" section and per-tag tool breakdown
