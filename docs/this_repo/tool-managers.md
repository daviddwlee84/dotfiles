# Tool managers — who installs what

A map of every tool installed by this repo, organised by the manager that
owns it. Companion to [`upgrades.md`](upgrades.md) — that one is the
upgrade-side reference; this one is install-side.

If you want to know:

| Question | Section |
|---|---|
| "Where does tool X come from?" | [§ Tool index (A–Z)](#tool-index-az) |
| "What does manager Y install?" | [§ Per-manager catalog](#per-manager-catalog) |
| "I'm adding a new tool — which manager should I use?" | [§ Decision tree](#decision-tree-for-new-tools) |
| "Why is X managed by Z and not W?" | [§ Multi-mechanism tools + rationale](#multi-mechanism-tools--rationale) |
| "How is X upgraded?" | [`upgrades.md`](upgrades.md) |

> Convention reminder: install-only by design (see [`upgrades.md` § Why
> install and upgrade are split](upgrades.md#why-install-and-upgrade-are-split)).
> Every install path here uses `state: present` / `creates:` / `[[ -d … ]]`
> guards; nothing in `chezmoi apply` silently bumps a tool's version. The
> only thing that intentionally moves tools forward is
> `scripts/upgrade_tools.sh` (via `just upgrade-*`).

---

## TL;DR — manager landscape

| Manager | Owns | Where listed | Upgrade category |
|---|---|---|---|
| **Bootstrap** (`run_once_before_*.sh.tmpl`) | Homebrew itself, uv, mise, ansible-core, apt prereqs | `run_once_before_00_bootstrap.sh.tmpl` | n/a (one-shot, idempotent) |
| **Homebrew formulae** | General macOS GUI helpers (`mas`) + role-driven formulae (in `base`, `devtools`, `coding_agents`, …) | `dot_config/homebrew/Brewfile.tmpl` + scattered `community.general.homebrew:` tasks | `brew` |
| **Homebrew casks** | macOS GUI apps, gated by `installBrewApps`, `installAiDesktopApps`, or `installGamingApps` | `Brewfile.darwin.tmpl` | `brew` (`--cask --greedy`) |
| **Ansible roles** | The majority — 26 roles spanning shells, devtools, agents, language toolchains, networking, security | `dot_ansible/roles/*/tasks/main.yml` | indirect (each role calls one of: brew / apt / mise / uv / npm / cargo / go / gem / dotnet / curl-installer / github-release) |
| **mise** | Runtime versions: `node`, `bun`, `rust`, `go`, `dotnet`, `ruby` (oldEL: ruby only) | `dot_config/mise/config.toml.tmpl` | `mise` |
| **uv** | Python CLI tools (~13 entries in `python_uv_tools` + 1 in `llm_tools` + `litellm`) | `dot_ansible/roles/python_uv_tools/defaults/main.yml`, `dot_ansible/roles/llm_tools/defaults/main.yml`, ad-hoc `uv tool install` in `coding_agents` (specify-cli) + `security_tools` (pre-commit) | `uv` (`uv tool upgrade --all`) |
| **npm** (global) | JS CLIs (~5: copilot-cli, codex, gemini-cli, openchamber, bitwarden, readability-cli) + `tldr` + `tree-sitter-cli` | `js_cli_tools/defaults/main.yml`, scattered `community.general.npm:` + `mise exec -- npm install -g` | `npm` (`npm -g update`) |
| **cargo** | Rust crates: `recon`, `pueue` (Linux), `tree-sitter-cli` (fallback), `alacritty` (Linux build), `modelsdev` (Linux fallback) | `rust_cargo_tools/defaults/main.yml` (currently `[]`) + hard-coded in tasks | `cargo` (`cargo install-update -a`) |
| **go** (`go install`) | Go CLI tools: `translate` (**Linux only** — macOS installs it via Homebrew `daviddwlee84/tap`) | `go_tools/defaults/main.yml` | `go` (`go install <pkg>@latest` per entry) |
| **dotnet** (global tools) | `azure-cost-cli` (binary `azure-cost`) | `dotnet_tools/defaults/main.yml` | `dotnet` |
| **gem** | `try-cli` (binary `try`), `tmuxinator` | `ruby_gem_tools/defaults/main.yml` | `gem` |
| **curl-installer** (vendor `install.sh`) | Self-managed coding agents + a handful of system tools: claude, opencode, cursor-agent, agy, rtk, ollama, atuin, docker, zoxide, direnv, just, llmfit, starship | `dot_ansible/roles/coding_agents/`, `llm_tools/`, `devtools/`, `starship/`, `atuin/`, `docker/`, bootstrap | `agents` (subset of these has a known self-update subcommand) |
| **GitHub-release downloads** | ~30 Linux user-level fallbacks for ripgrep/fd/jq/git-lfs/gh/glab/bat/eza/git-delta/diffnav/glow/gum/vhs/freeze/yazi/superfile/btop/zellij/sesh/worktrunk/workmux/tailspin/dasel/yq/jnv/doggo/gping/trippy/bandwhich/rustscan/cloudflared/ngrok/speedtest/gitleaks/lazygit/neovim + macOS fallback for specstory | Each role's `_release_fallback` block | **none** (install-only — see [Coverage gaps](#coverage-gaps-install-only-no-automated-upgrade)) |
| **chezmoi externals** | git checkouts on weekly refresh: oh-my-zsh + plugins, oh-my-bash, ble.sh, TPM, fzf (Linux), toolkami.rb | `.chezmoiexternal.toml.tmpl` | `externals` (`chezmoi apply --refresh-externals`) |
| **apt** / **yum** | Distro packages (build deps, ffmpeg, audit, fontconfig, libnotify-bin, system git/zsh/bash, Steam launcher/runtime, …) | scattered `ansible.builtin.apt:` / `ansible.builtin.yum:` in roles | **none** (relies on `apt upgrade` outside this repo) |
| **flatpak** | Discord (default channel on Linux) | `gui_apps_linux/tasks/main.yml` | `flatpak` (`flatpak update -y`) |

---

## Install order

Five phases in chronological order. Anything earlier MUST be present
before the next phase can run.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 0 — Bootstrap (run_once_before_*)                                 │
│   curl-installer: Homebrew, uv, mise                                    │
│   apt: build-essential, git, curl (Linux prereqs for Linuxbrew)         │
│   apt: libffi-dev, libyaml-dev, python3-dev (Linux non-noRoot only)     │
│   uv: ansible-core (pinned Python 3.13)                                 │
│   ansible-galaxy: community.general collection                          │
│   mise: install runtimes from ~/.config/mise/config.toml                │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 1 — chezmoi apply (config file deploy)                            │
│   Deploys dot_* files; doesn't install tools directly                   │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 2 — Ansible (run_onchange_after_20_ansible_roles)                 │
│   Runs all 26 roles; each dispatches to its underlying manager          │
│   (brew / apt / mise / uv / npm / cargo / gem / dotnet / curl / gh-rel) │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 3 — Brew bundle (run_onchange_after_30_brew_bundle)               │
│   `brew bundle --no-upgrade` against ~/.config/homebrew/Brewfile*       │
│   Mostly GUI casks (macOS); skipped unless Brew/AI/gaming apps enabled  │
└─────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 4 — Per-application onchange scripts                              │
│   Completion regen (run_after_50_generate_completions)                  │
│   bat theme cache (run_onchange_after_25_bat_theme)                     │
│   ble.sh compile (run_onchange_after_26_install_blesh)                  │
│   Global skills restore (run_onchange_after_40_install_global_skills)   │
└─────────────────────────────────────────────────────────────────────────┘
```

The bootstrap is **single-source-of-truth** for the foundational tools
that everything else depends on. If you find yourself wanting to add
`mise` / `uv` / Homebrew elsewhere, the answer is almost always "extend
the bootstrap, then assume it in the role". The Linux noRoot path
(`profile=ubuntu_server` or RHEL/CentOS without sudo) skips the apt
prereqs and Linuxbrew, falling back to per-tool curl-installers and
GitHub releases — coverage is intentionally narrower (no GUI, no
system-wide installs).

---

## Per-manager catalog

Each subsection below covers one manager. Format:

- **Owns** — what tools end up under this manager's control
- **How a tool gets there** — the canonical "I want to add tool X via this manager" recipe
- **Per-OS notes** — branching when relevant
- **Upgrade path** — link to the matching category in `upgrades.md`

The ansible roles section is split into thematic subsections because
26 roles in one table is unreadable.

### 1. Bootstrap scripts (pre-chezmoi)

**Files**: `run_once_before_00_bootstrap.sh.tmpl`,
`run_once_before_02_fix_intel_homebrew.sh.tmpl`,
`run_once_before_50_opencode_migrate.sh.tmpl`

**Owns** — the four foundational managers that everything else
assumes:

| Tool | Mechanism | Per-OS |
|---|---|---|
| **Homebrew** | `Homebrew/install` curl script | macOS always; Linux only when `installBrewApps=true` & non-noRoot & arch∈{amd64,arm64}. Mirrors via `HOMEBREW_BREW_GIT_REMOTE` + bottle/API domains (**BFSU** baseline; `brew-mirror` switches to USTC/Aliyun/TUNA) when `useChineseMirror=true`. Aliyun's `brew.git` is broken (hangs) and `HOMEBREW_CORE_GIT_REMOTE` stays unset (API mode) — see [mirrors.md](../tools/mirrors.md#brew-update--any-brew-command-hangs-for-60s-then-does-nothing) |
| **uv** | `curl -LsSf https://astral.sh/uv/install.sh \| sh` | all OSes if missing |
| **mise** | `curl https://mise.run \| sh`, with direct `mise.jdx.dev/mise-latest-linux-${arch}[-musl]` fallback (musl forced when glibc < 2.28) | all OSes; arch detection (x64/arm64/armv7) |
| **ansible-core** | `uv tool install --force --python 3.13 ansible-core` | all OSes; force-refreshes if existing ansible runs on Python < 3.10 |
| **ansible-galaxy: community.general** | `ansible-galaxy collection install --force-with-deps` | all OSes |
| **mise runtimes** | `mise install --yes` (consumes `~/.config/mise/config.toml`) | all OSes — see [§ mise](#4-mise-runtime-versions) |

**Linux prereqs (apt)** to make Linuxbrew + mise Ruby + ansible-cryptography
buildable: `build-essential`, `procps`, `curl`, `file`, `git` (always);
`libffi-dev`, `libyaml-dev`, `python3-dev` (non-noRoot only).

**Intel-Mac-only side script**: `run_once_before_02_fix_intel_homebrew.sh.tmpl`
runs `softwareupdate -i` for Xcode CLT, then `brew cleanup` +
`brew link --overwrite git`.

**One-shot migrations**: `run_once_before_50_opencode_migrate.sh.tmpl`
moves a legacy config file (`~/.config/opencode/config.json` →
`opencode.json`). Not an install.

**Adding to bootstrap**: only when the new tool is required *before*
ansible runs — e.g. ansible itself, mise (because ansible roles call
`mise exec`), uv (because some roles call `uv tool install`). Otherwise
prefer an ansible role.

### 2. Homebrew (formulae + casks)

Three Brewfile templates + scattered `community.general.homebrew[_cask]`
tasks in ansible roles. The split is **macOS-centric**: Linux Brewfile is
empty, Linuxbrew use happens role-by-role.

**Linux glibc floor**: bootstrap skips the Linuxbrew install entirely when
glibc < 2.28 (RHEL 8 / Debian 10 floor — excludes CentOS/RHEL 7's 2.17,
leaves Ubuntu 20.04's 2.31 alone). Below that, every bottle would be
compiled from source and the installer usually aborts first anyway. Same
threshold the mise installer uses to force its musl build.

**Probe brew by output, never by exit status.** Every "is brew here?" check
in this repo tests that `brew --prefix` prints a non-empty path:

```bash
brew_usable() { [[ -n "$(brew --prefix 2>/dev/null)" ]]; }        # shell
```
```yaml
ansible.builtin.shell: '[ -n "$(brew --prefix 2>/dev/null)" ] && command -v brew || true'
```

A fake `brew` stub (`#!/bin/sh` + `exit 0`) — historically recommended in
the README to stop bootstrap installing Linuxbrew on CentOS 7 — satisfies
`command -v brew` / `which brew` and returns 0 for *every* subcommand while
printing nothing. That makes `brew list --formula <x>` succeed (misclassifying
install styles, §2.3), makes `brew bundle` "succeed" while installing
nothing, and kills `community.general.homebrew` on empty JSON with
`Expecting value: line 1 column 1 (char 0)`. See
[`pitfalls/ansible-homebrew-expecting-value-line-1-column-1.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-homebrew-expecting-value-line-1-column-1.md).

#### 2.1 Brewfiles

| File | Owns |
|---|---|
| `Brewfile.tmpl` (shared) | General macOS GUI support when `installBrewApps=true`: tap `nikitabobko/tap`, formula `mas`. Plus (macOS, **always** — not `installBrewApps`-gated): tap `daviddwlee84/tap` + formula `daviddwlee84/tap/translate` (terminal translator CLI/TUI; Linux uses `go install` via `go_tools`) |
| `Brewfile.darwin.tmpl` | All GUI casks — see table below |
| `Brewfile.linux.tmpl` | Empty (commented-out placeholders only) |

**macOS casks** (~25 active, gated by feature flags):

| Cask | Gating |
|---|---|
| `alacritty`, `warp`, `cmux`, `cursor`, `visual-studio-code` | `installBrewApps` |
| `claude`, `opencode-desktop`, `antigravity` | `installAiDesktopApps` |
| `chatgpt`, `codex-app` | `installAiDesktopApps` + arm64 |
| `codeisland` (tap `wxtsky/tap`) | `installAiDesktopApps` |
| `ollama-app` | `installAiDesktopApps` + `installLlmTools` |
| `steam` | `installGamingApps` |
| `nikitabobko/tap/aerospace`, `alt-tab`, `raycast`, `maccy`, `scroll-reverser`, `the-unarchiver`, `applite` | `installBrewApps` |
| `discord` | `installBrewApps` |
| `arc` | `installBrewApps` |
| `obsidian`, `google-drive`, `grammarly-desktop`, `super-productivity` | `installBrewApps` |
| `spotify`, `anki` | `installBrewApps` |
| `tailscale-app` | `installBrewApps` |
| `dbeaver-community` | `installBrewApps` |
| `superset` | `installBrewApps` + arm64 |

Many more entries exist in commented-out form (minecraft, telegram,
openvpn-connect, etc.) — uncomment to enable.

#### 2.2 Role-driven brew (formulae + casks)

Most CLI formulae land via ansible roles, not the Brewfile. Examples:

- `base/tasks/main.yml`: `git`, `git-lfs`, `curl`, `wget`, `ripgrep`, `fd`, `jq`, `tree`, `just`
- `devtools/tasks/main.yml`: large set — `bat`, `gh`, `glab`, `diffnav`, `git-delta`, `eza`, `tlrc`, `glow`, `gum`, `vhs`, `freeze`, `thefuck`, `zoxide`, `direnv`, `yazi`, `superfile`, `tmux`, `sesh`, `worktrunk`, `workmux`, `zellij`, `btop`, `htop`, `duckdb`, `rclone`, `coreutils`, `taplo`, `television`, `pandoc`, `tailspin`, `lnav`, `grc`, `dasel`, `yq`, `jnv`, `witr`, `figlet`, `toilet`, `lolcat`, `fastfetch`, `shellcheck`, `shfmt`, `bats-core`, `git-graph`, `mosh`, `doxx`, `libreoffice`
- `coding_agents/tasks/main.yml`: `claude-code` (cask), `codex` (cask), `gemini-cli` (formula), `rtk` (formula), `specstory`, `codexbar`, `td`, `sidecar` (all with tap setup except `codexbar`, whose cask is in homebrew-cask core)
- `networking_tools/`: `nmap`, `arp-scan`, `mtr`, `iperf3`, `doggo`, `httpie`, `gping`, `trippy`, `bandwhich`, `rustscan`, `speedtest` (tap `teamookla/speedtest`), `ngrok`, `cloudflared`
- `media_tools/`: `ffmpeg`, `imagemagick`, `exiftool`, `vips`
- `iac_tools/`: `azure-cli`, `hashicorp/tap/terraform`, `opentofu`
- `llm_tools/`: `llmfit`, `models`, `ollama`
- `security_tools/`: `gitleaks`
- `starship/`, `atuin/`, `neovim/`, `bash/` (gawk), `zsh/` — each installs its primary tool via homebrew formula on macOS
- `pueue` (from `rust_cargo_tools/`): macOS uses homebrew formula

**Per-OS dispatch** is the universal pattern in roles: macOS branch uses
`community.general.homebrew` / `homebrew_cask`; Linux branches use apt,
Linuxbrew (when present), or GitHub releases. See each role for the
explicit `when: ansible_facts["os_family"] == "Darwin"` guard.

**Tap inventory** (added by various roles): `nikitabobko/tap`,
`wxtsky/tap` (CodeIsland), `hashicorp/tap` (terraform),
`teamookla/speedtest`, `specstoryai/tap`, `steipete/tap` (CodexBar **CLI formula** — the
cask is in homebrew-cask core, no tap needed),
`marcus/tap` (td, sidecar), `dlvhdr/formulae`, `raine/workmux`.

Homebrew 6+ refuses formulae/casks from untrusted third-party taps. Role-driven
taps must run a `brew tap-info <tap>` → `brew trust <tap>` check before installing
from that tap; Brewfile taps are handled by the brew-bundle run-script before it
calls `brew bundle`. See
[`pitfalls/homebrew-6-refuses-untrusted-tap-formula.md`](../../pitfalls/homebrew-6-refuses-untrusted-tap-formula.md).

**Adding via homebrew**: prefer a brew formula/cask only when the tool
is macOS-shipped and Linux equivalents go via apt or release tarball.
Linux-first tools rarely belong in the Brewfile.

#### 2.3 Homebrew prefix dispatch helper

`scripts/upgrade_tools.sh::_uv_install_style` (and mirrored helpers in
`python_uv_tools/tasks/main.yml`) inspect whether a binary lives under
`brew --prefix` to decide between `brew upgrade <pkg>` and the tool's
native self-update. This avoids the "I `uv self update` on a brew-uv
host and silently no-op" trap — see
[`pitfalls/uv-self-update-homebrew-noop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md).

### 3. Ansible roles

26 roles under `dot_ansible/roles/`. Triggered by
`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`
(re-runs when any role's `tasks/main.yml` or `defaults/main.yml` changes
— SHA256-tracked).

**Universal patterns**:

- `state: present` / `creates:` — install-only, no silent upgrades
- Per-OS branching via `when: ansible_facts["os_family"] == "Darwin"` (or `["Debian", "RedHat"]`)
- `tags: [sudo]` on any `become: true` task (so noRoot mode skips them — see [`pitfalls/ansible-missing-sudo-tag.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-missing-sudo-tag.md))
- `failed_when: false` + `register:` for "is the tool installed?" probes
- Linux user-level fallback to `~/.local/bin` when distro package is missing or too old (handles RHEL/CentOS + noRoot + Apple-Silicon-not-bottled scenarios)

**Role feature flags** (set in `.chezmoi.toml.tmpl` via prompts):
`installBrewApps`, `installAiDesktopApps`, `installCodingAgents`,
`installLlmTools`, `installPythonUvTools`, `installJsCliTools`,
`installDotnetTools`, `installIacTools`, `installMediaTools`,
`installNetworkingTools`, `installTunnelTools`, `installBitwarden`,
`installGamingApps`, `installInputMethod`, `installAuditd`. Roles gate themselves on the
matching flag; the bundle script `scripts/init/dotfiles_init.py` defines
profile presets (`minimal`, `cloud-vm` planned, default-developer, …).

#### 3.1 Base / shared CLI

| Role | Owns | Per-OS mechanism |
|---|---|---|
| `base` | `git`, `git-lfs`, `curl`, `wget`, `ripgrep`, `fd`, `jq`, `tree`, `just`, `gcc`/`build-essential`/`make` | macOS: brew formulae · Debian: apt (`fd-find` + `/usr/bin/fd` symlink) · RedHat: yum · `just` always via `curl https://just.systems/install.sh` · Linux user-level GitHub-release fallback to `~/.local/bin` for ripgrep/fd/jq/git-lfs |
| `homebrew` | (no installs — refresh + cleanup only, 24h-throttled) | n/a |
| `atuin` | `atuin` shell history sync | macOS: brew formula · Linux: `curl https://setup.atuin.sh \| sh -s -- --non-interactive` → `~/.atuin/bin/` |
| `nerdfonts` | `font-hack-nerd-font` | macOS: brew cask · Linux: download `Hack.zip` from `nerd-fonts/releases/latest` → `~/.local/share/fonts` + `fc-cache -fv` |

#### 3.2 Shells (`bash`, `zsh`, `starship`)

| Role | Owns | Per-OS mechanism |
|---|---|---|
| `bash` | `gawk` (ble.sh dep, unconditional); homebrew `bash` 5.x + `/etc/shells` + `chsh` (macOS only when `primary_shell="bash"`) | macOS: brew · Debian: apt · RedHat: yum |
| `zsh` | system `zsh` package; **source-build zsh 5.9** to `~/.local` on RHEL/CentOS 7 if system zsh < 5.3; `chsh` when `primary_shell="zsh"` (default) | macOS: brew · Debian: apt · RedHat: yum + ncurses-devel source build fallback. oh-my-zsh + plugins ship as externals (§12) |
| `starship` | `starship` prompt | macOS: brew formula · Linux: `curl https://starship.rs/install.sh \| sh -s -- --yes` → sudo `/usr/local/bin` → user `~/.local/bin` fallback |

The `primaryShell` chezmoi prompt gates the `chsh` call only — both
shells deploy their configs everywhere. See AGENTS.md → "`primaryShell`
choice gates `chsh` only" hard invariant.

#### 3.3 DevTools (mega-role)

Single role, ~50 tools — the kitchen sink for terminal-life CLIs.
There's a backlog item ([`backlog/devtools-role-split.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/devtools-role-split.md))
considering whether to break this up.

**macOS** (homebrew, taps: `dlvhdr/formulae` for `gh-dash`,
`raine/workmux`): `bat`, `bats-core`, `gh`, `glab`, `diffnav`, `git-delta`,
`git-graph`, `eza`, `tlrc`, `glow`, `gum`, `vhs`, `freeze`, `thefuck`,
`zoxide`, `direnv`, `yazi`, `superfile`, `tmux`, `sesh`, `worktrunk`,
`workmux`, `zellij`, `btop`, `htop`, `duckdb`, `rclone`, `coreutils`,
`taplo`, `television`, `pandoc`, `tailspin`, `lnav`, `grc`, `dasel`,
`yq`, `jnv`, `witr`, `figlet`, `toilet`, `lolcat`, `fastfetch`,
`shellcheck`, `shfmt`, `doxx`.

**Linux** — per-tool dispatch. The pattern is **apt/yum (system) →
GitHub release tarball or installer (user)**:

| Tool | Linux mechanism (preferred → fallback) |
|---|---|
| `gh` | GitHub `.deb` → user tarball |
| `glab` | GitHub `.deb` → user tarball |
| `bat` | apt + `/usr/bin/bat` symlink → GitHub musl release |
| `bats` | apt → GitHub release `install.sh` |
| `zoxide` | `curl install.sh` |
| `eza` | gierens.de apt repo → user GitHub musl → brew aarch64 |
| `git-delta` | `.deb` (x86_64) → brew aarch64 → user GitHub musl |
| `diffnav` | user GitHub release |
| `gh-dash` | `gh extension install dlvhdr/gh-dash` |
| `gh-notify` | `gh extension install meiji163/gh-notify` |
| `gh-select` | `gh extension install remcostoeten/gh-select` |
| `git-graph` | user GitHub release (x86_64 only) |
| `tldr` | system npm or `mise exec -- npm install -g tldr` |
| `glow`, `gum`, `vhs`, `freeze`, `duckdb` | user GitHub release tarballs |
| `rclone` | official installer or GitHub release |
| `thefuck` | `uv tool install thefuck` (Python 3.11, distutils workaround) |
| `shellcheck`, `shfmt` | apt or release |
| `direnv` | apt or installer |
| `yazi`, `superfile`, `btop`, `zellij`, `sesh`, `worktrunk`, `workmux` | Linuxbrew or GitHub release |
| `tmux` | apt → `nelsonenzo/tmux-appimage` AppImage to `~/.local/share/tmux-appimage/` when system version < 3.3 (required by `display-menu` popup) — see AGENTS.md "Tmux popup menu ≥ 3.3 required" |
| `htop`, `pandoc` | apt |
| `taplo`, `television (tv)`, `lnav`, `grc`, `tailspin (tspin)`, `dasel`, `yq`, `jnv`, `witr` | mix of apt + release |
| `ccze` | apt only (Linux-only tool, no macOS equivalent) |

#### 3.4 Coding agents

Role: `dot_ansible/roles/coding_agents/tasks/main.yml`. Gated on
`installCodingAgents`. **The most heterogeneous role** — every agent
ships via a different mechanism upstream, and the role mirrors that.

| Agent | macOS | Linux | Notes / source lines |
|---|---|---|---|
| `terminal-notifier` / `libnotify-bin` | brew formula / apt (Debian) | apt (Debian only) | notifier helpers, lines 9–29 |
| **Claude Code** | brew cask `claude-code` | `curl https://claude.ai/install.sh \| bash` → `~/.claude/local/bin/claude` | lines 33–71; arch skip for non-amd64/arm64 |
| **OpenCode** | `curl https://opencode.ai/install \| bash -s -- --no-modify-path` → `~/.opencode/bin/opencode` | same | lines 73–107. Cross-platform unified install; `--no-modify-path` keeps installer from editing chezmoi-managed shell rc. See [`pitfalls/opencode-docker-opentui-glibc-loader-missing.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/opencode-docker-opentui-glibc-loader-missing.md) for the container-image variant |
| **Cursor CLI** (`cursor-agent`) | `curl https://cursor.com/install \| bash` | same | lines 112–124; brew cask was abandoned due to code-signing |
| **GitHub Copilot CLI** | npm `@githubnext/github-copilot-cli` (global) | `mise exec -- npm install -g` | lines 134–168 |
| **OpenAI Codex CLI** | brew cask `codex` | `mise exec -- npm install -g @openai/codex` | lines 172–236 |
| **Gemini CLI** | brew formula `gemini-cli` → npm `@google/gemini-cli` fallback | `mise exec -- npm install -g` | lines 240–300 |
| **Antigravity CLI** (`agy` + `agyc` symlink) | `curl https://antigravity.google/cli/install.sh` patched mid-flight via `sed` → `--skip-path --skip-aliases` | same | lines 317–355. Two gotchas: (a) name collision with the Antigravity IDE — collision-free `agyc` symlink keys the AICAP stack; (b) installer mutates shell profiles by default — patched away. Both documented in-source |
| **RTK** | brew formula `rtk` | `curl https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh \| sh` → `~/.local/bin/rtk` | lines 359–413 |
| **SpecStory** | brew tap `specstoryai/tap` + formula → GitHub release zip fallback | GitHub release tarball | lines 417–595 |
| **CodexBar** | brew cask `codexbar` — homebrew-cask **core** (no tap), universal binary, macOS 14+ | glibc ≥ 2.38: Linuxbrew `steipete/tap/codexbar` → GitHub release; below that: static-musl GitHub release only | lines 597–864. Guards on `/Applications/CodexBar.app`, not `which codexbar`; removes a conflicting CLI formula first (both link the same binary name); the prebuilt Linux CLI needs `GLIBC_2.38`, so old-glibc hosts skip Linuxbrew entirely. See [codexbar.md](../tools/codexbar.md) |
| **td** | brew tap `marcus/tap` + formula | Linuxbrew → GitHub release `marcus/td` | lines 865–1078. Includes "is current td Sidecar-compatible?" version check; removes conflicting formula if not |
| **sidecar** | brew tap `marcus/tap` + formula | Linuxbrew → GitHub release `marcus/sidecar` | lines 1080–1256 |
| **Specify CLI** | `uv tool install specify-cli --from git+https://github.com/github/spec-kit.git` | same | lines 1153–1184. Only role-installed tool currently using `uv tool install` directly (not via `python_uv_tools` defaults) |
| **OpenChamber** | npm `@openchamber/web` | `mise exec -- npm install -g` | lines 1188–1222 |
| **claude-hud** plugin | runs `files/claude_hud_sync.py --only-if-missing` | same | lines 1239–1247; install-only, explicit `just upgrade-plugins` for refresh |

**SSOT for the AICAP agent stack**: `dot_config/shell/04_ai_agents.sh`
defines autodetect order + `AICAP_*_MODEL` defaults. Four Python
consumers regex-parse the same file (see AGENTS.md cross-file rule).
Adding a new agent here means: install in this role + add to the SSOT
+ four Python `AGENT_CONFIG` dicts.

#### 3.5 Language toolchains (`python_uv_tools`, `ruby_gem_tools`, `rust_cargo_tools`, `go_tools`, `dotnet_tools`, `js_cli_tools`)

Wrappers around language-specific package managers. All consume a
`defaults/main.yml` list so the role's `tasks/main.yml` is a loop. See
[§ uv](#5-uv-python-cli-tools), [§ npm](#6-npm-global-node-clis),
[§ cargo](#7-cargo-rust-crates), [§ go](#8-go-go-cli-tools),
[§ dotnet](#9-dotnet-global-net-tools), [§ gem](#10-gem-ruby-gems) for the tool lists.

| Role | Underlying manager | Tools (count) | Gate |
|---|---|---|---|
| `python_uv_tools` | `uv tool install` | 13 | `installPythonUvTools` |
| `llm_tools` | `uv tool install` + brew + cargo + curl-installer | 4 (litellm, llmfit, models, ollama) | `installLlmTools` |
| `js_cli_tools` | `mise exec -- npm install -g` / system npm | 1 (`readability-cli`) | `installJsCliTools` |
| `rust_cargo_tools` | `cargo install` (after `mise install rust@latest`) | `[]` in defaults + 2 hardcoded (`recon`, `pueue`) | (no gate; rust runtime always installed via mise) |
| `ruby_gem_tools` | `gem install` (after `mise install ruby@3`) | 2 (`try-cli`, `tmuxinator`) | (no gate; gated by `mise install ruby` skip on noRoot Linux) |
| `dotnet_tools` | `dotnet tool install --global` (after `mise use -g dotnet@latest`) | 1 (`azure-cost-cli`) | `installDotnetTools` |

**Key invariant** (`with_executables_from:` entries MUST also declare
`extra_binaries:`): see AGENTS.md "Install vs upgrade is split on
purpose" hard invariant for the audit one-liner and the pitfall.

#### 3.6 Editors + plugins (`neovim`, `lazyvim_deps`, `nerdfonts`)

| Role | Owns | Per-OS mechanism |
|---|---|---|
| `neovim` | `neovim` ≥ 0.11.2 (`state: latest` on macOS) | macOS: brew formula · Linux: apt → GitHub release tarball if too old (`/opt/nvim` + `/usr/local/bin/nvim` symlink) → user-level tarball to `~/.local`; **oldEL** pulls from `neovim/neovim-releases` (glibc 2.17 rebuild repo). No snap (dropped 2026-06 — see [linux-package-sources.md → snap in this repo](../linux-package-sources.md#snap-in-this-repo)). See [`pitfalls/centos7-neovim-apt-register-defined.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/centos7-neovim-apt-register-defined.md) |
| `lazyvim_deps` | `fzf`, `lazygit`, `tree-sitter`, `node` | macOS: brew · Linux: mise (`node@lts` general; `node@20` + `rust@latest` on armv7l); fzf built from chezmoi external clone (Linux); lazygit GitHub release (its PPA was deprecated upstream in 2021 and broke `apt update`; the role now also purges leftover lazygit PPA source files); tree-sitter-cli via `mise exec -- npm install -g tree-sitter-cli` (timeout 180) → cargo fallback with `libclang-dev`/`clang-devel` |
| `nerdfonts` | (see [§ 3.1 base/shared](#31-base--shared-cli)) | — |

#### 3.7 Networking + IaC + LLM + media (`networking_tools`, `iac_tools`, `llm_tools`, `media_tools`)

| Role | Owns | Per-OS mechanism |
|---|---|---|
| `networking_tools` | `nmap`, `arp-scan`, `mtr`, `iperf3`, `doggo`, `httpie`, `gping`, `trippy`, `bandwhich`, `rustscan`, `speedtest` (Ookla) | macOS: brew (tap `teamookla/speedtest` for speedtest) · Linux: apt + GitHub-release fallback (musl) to `~/.local/bin` for tools without apt packages |
| `networking_tools` (tunnel sub-set, gated `installTunnelTools` + tag `tunnel_tools`) | `ngrok`, `cloudflared` | macOS: brew cask `ngrok` + brew formula `cloudflared` · Debian: ngrok apt repo + cloudflared `.deb` · RedHat: cloudflared `.rpm` · noRoot: user-level tarball fallback |
| `iac_tools` (gated `installIacTools`; per-tool toggles) | `azure-cli`, `terraform`, `opentofu` | macOS: brew (hashicorp/tap for terraform) · Linux: vendor apt repos (Microsoft / HashiCorp / Cloudsmith) → user-level zip/`uv tool install azure-cli` fallback |
| `llm_tools` (gated `installLlmTools`) | `litellm[proxy]` (via uv), `llmfit`, `models`, `ollama` | mixed — brew formula on macOS / curl-installer on Linux. Ollama: brew formula always (CLI) + cask `ollama-app` from Brewfile when `installBrewApps`; Linux uses `curl https://ollama.com/install.sh` (sudo, skipped in noRoot) |
| `media_tools` (gated `installMediaTools`) | `ffmpeg`, `imagemagick`, `exiftool`, `vips` | macOS: brew · Debian: apt (`libimage-exiftool-perl`, `libvips-tools`) |

#### 3.8 System / GUI / security (`docker`, `gui_apps_linux`, `auditd`, `security_tools`, `bitwarden`, `input_method`, `atuin`, `homebrew`)

| Role | Owns | Per-OS mechanism |
|---|---|---|
| `docker` | OrbStack (macOS), Docker rootless (Linux) | macOS: brew cask `orbstack` (skips if `/Applications/Docker.app` exists) · Debian/Ubuntu: `apt` prereqs (`uidmap`, `dbus-user-session`, `fuse-overlayfs`, `slirp4netns`, `iptables`) → `curl https://get.docker.com \| sh` → `docker-ce-rootless-extras` → `dockerd-rootless-setuptool.sh install` user systemd unit |
| `gui_apps_linux` (Linux Debian + `ubuntu_desktop` profile) | Alacritty, libfuse2, AppImageLauncher, VSCode, Cursor, Discord, Zen Browser, CopyQ, playerctl/wmctrl/xdotool | Alacritty: cargo build (apt deps `cmake`, `pkg-config`, font/X libs) · AppImageLauncher: PPA → GitHub `.deb` → Lite AppImage to `~/Applications/` · VSCode: Microsoft apt repo · Cursor: `.deb` from `cursor.com/api/download` · Discord: flatpak (Flathub user-scope, default) or `.deb` via `discordChannel` chooser · Zen Browser: AppImage to `~/Applications/zen.AppImage` |
| `auditd` (Linux, gated `installAuditd`) | `auditd` + `audispd-plugins` (Debian) / `audit` (RedHat); rule files `00-baseline.rules`, `05-privileged.rules`, optional `10-execve.rules`, `99-finalize.rules` | apt / yum |
| `security_tools` | `pre-commit`, `gitleaks` | macOS: brew (`gitleaks`) + uv (`pre-commit`) · Linux: gitleaks from GitHub release (system → `/usr/local/bin`; user fallback → `~/.local/bin`) + uv pre-commit. **Go is no longer here** — it moved to mise (`go = "latest"`, gated `installExtraRuntimes`). |
| `bitwarden` (gated `installBitwarden`) | `@bitwarden/cli` + Bitwarden Desktop (when `bitwarden_install_desktop=true`) | CLI: `mise exec -- npm install -g @bitwarden/cli` (preferred) / system npm fallback · Desktop: macOS brew cask · Linux: snap → `.deb` fallback |
| `input_method` (gated `installInputMethod`) | `mcbopomofo`, `squirrel` (macOS) · `ibus-rime` (Debian) | macOS: brew cask · Linux: apt |
| `atuin` | (see [§ 3.1 base/shared](#31-base--shared-cli)) | — |
| `homebrew` | (see [§ 2 Homebrew](#2-homebrew-formulae--casks)) | — |

### 4. mise (runtime versions)

**Config**: `dot_config/mise/config.toml.tmpl`

`[settings]`: `ruby.compile = false`.

**Modern hosts** (default):

| Runtime | Version | Gated on |
|---|---|---|
| `node` | `lts` | always |
| `bun` | `1` | `installExtraRuntimes` |
| `rust` | `stable` | `installExtraRuntimes` |
| `go` | `latest` | `installExtraRuntimes` |
| `dotnet` | `10` | `installDotnetTools` |
| `ruby` | `3` | `installExtraRuntimes` (+ not `noRoot`) |

**Version-pinning rationale**: `node=lts` / `rust=stable` / `go=latest` use
moving channels because each promises backward compatibility (Go's
[go1compat](https://go.dev/doc/go1compat) makes `latest` as safe as
rust's `stable`). `bun=1` and `dotnet=10` pin the **major** instead —
neither guarantees no-break across majors (bun ships behavior changes on
minors; .NET majors bump TFMs / SDK behavior), and `dotnet=10` is also the
current LTS (8/9 are at/near EOL by mid-2026). Bump `dotnet` deliberately
when the next LTS (12) lands. `ruby=3` tracks the 3.x line.

`go` replaces the old macOS-only brew install from the `security_tools`
role, so Linux hosts now get a managed Go too (previously a gap).

Ruby is **skipped in noRoot mode** (`profile=ubuntu_server` without
sudo) because it needs `libffi-dev` / `libyaml-dev` to build, which
require apt.

**oldEL (CentOS/RHEL 7, glibc 2.17)**: only `ruby = "3"` — other
runtimes have glibc/libstdc++ requirements too new for EL7.

**Upgrade**: `just upgrade-mise` → `mise self-update --yes` + `mise upgrade`
(honours the version constraints in the config; `lts`/`latest` move
forward, pinned versions don't).

**Adding a runtime**: edit `dot_config/mise/config.toml.tmpl` directly.
Runtime-version gating across hosts is on the [backlog](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/mise-runtime-gating.md).

**Why mise (not nvm/rbenv/pyenv/asdf/n)**: unified, language-agnostic,
respects `.tool-versions`, doesn't fight shell init order. Python is
deliberately **not** mise-managed — that's uv's territory (faster + no
build-from-source for CPython, which the noRoot Linux path can't do).
The [backlog](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/mise-runtime-gating.md) tracks
finer-grained per-host gating.

### 5. uv (Python CLI tools)

**Config**: `dot_ansible/roles/python_uv_tools/defaults/main.yml` (+
`llm_tools/defaults/main.yml` for `litellm`). Role-level dispatch:
`dot_ansible/roles/python_uv_tools/tasks/main.yml`.

Inspects whether `uv` is below `min_uv_version` (`0.8.5`) and dispatches
the upgrade through the right channel — `brew upgrade uv` for Homebrew
installs, `uv self update` for the curl-installer. Mirror logic in
`scripts/upgrade_tools.sh::cat_uv()`. See
[`docs/this_repo/uv-bootstrap.md`](uv-bootstrap.md) and
[`pitfalls/uv-self-update-homebrew-noop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md).

**Tool inventory** (`python_uv_tools/defaults/main.yml`):

| Tool | `--with` / `--with-executables-from` | `needs_modern_gcc` |
|---|---|---|
| `thefuck` | (python 3.11; distutils workaround) | — |
| `apprise` | — | — |
| `sqlit-tui[ssh]` | `psycopg2-binary`, `pymysql`, `mssql-python`, `pyodbc`, `duckdb` | ✓ (gcc ≥ 9) |
| `python-dotenv[cli]` (`dotenv`) | — | — |
| `git-filter-repo` | — | — |
| `mlflow` | — | ✓ |
| `tmuxp` | — | — |
| `visidata` (`vd`) | `pandas`, `pyarrow` | ✓ |
| `copyparty` | — | — |
| `trafilatura` | — | — |
| `marimo[recommended,mcp]` | `httpx[socks]` | ✓ |
| `jupyterlab` (`jupyter-lab`) | `marimo[sandbox]`, `marimo-jupyter-extension`, `ipykernel`, `ipywidgets`; `with_executables_from: notebook, jupyter-core`; `extra_binaries: jupyter, jupyter-notebook` | ✓ |
| `xonsh` | `xontrib-jedi`, `xontrib-zoxide`, `xontrib-pipeliner`, `xontrib-fzf-widgets` | — |
| `yt-dlp` | — | — |
| `markitdown[docx,xlsx,pptx]` | — (extras in name; pulls pandas 3.x) | ✓ |

From `llm_tools/defaults/main.yml`:

| Tool | Pin |
|---|---|
| `litellm[proxy]` (`litellm`) | `--python 3.13`, `--with httpx[socks]` |

Ad-hoc `uv tool install` outside the defaults YAML:

- `coding_agents/tasks/main.yml:1153-1184` — `specify-cli` (from `git+...`)
- `security_tools/tasks/main.yml` — `pre-commit` (`--python 3.13`, avoids the
  Homebrew Python 3.14 pyexpat ABI mismatch)
- `iac_tools/tasks/main.yml` — `azure-cli` user fallback (Linux noRoot)

**Upgrade**: `just upgrade-uv` → uv self-update (dispatched) + `uv tool upgrade --all`.

**Adding a uv tool**: append to `python_uv_tools/defaults/main.yml`.
If the package writes companion binaries beyond the entry point, declare
**both** `with_executables_from:` AND `extra_binaries:` — otherwise the
install guard short-circuits on hosts where the primary binary already
exists and shims are never written ([`pitfalls/uv-tool-install-creates-guard-misses-executables-from.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-tool-install-creates-guard-misses-executables-from.md)).
If gcc < 9 is in scope, set `needs_modern_gcc: true`.

### 6. npm (global Node CLIs)

**Config**: `dot_ansible/roles/js_cli_tools/defaults/main.yml` for the
JS-tools-specific list. Scattered global-npm installs live in other
roles (`coding_agents`, `bitwarden`, `lazyvim_deps`, `devtools`).

**Install dispatch** (universal pattern across roles):

```yaml
# On Linux:
mise exec -- npm install -g <package>
# Falls back to system npm if mise has no node registered
# On macOS:
community.general.npm: { name: <package>, global: true }
```

Linux explicitly uses `mise exec -- npm` to avoid the Ubuntu apt npm
(too old; system Node 12 fails `engine` checks for modern packages and
`/usr/local/lib/node_modules` is root-owned, breaking `--global` for
non-root users). See [`pitfalls/ansible-js-cli-tools-old-system-node.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-js-cli-tools-old-system-node.md).

**Inventory**:

| Package | Binary | Role / line |
|---|---|---|
| `readability-cli` | `readable` | `js_cli_tools/defaults/main.yml` |
| `@bitwarden/cli` | `bw` | `bitwarden/tasks/main.yml` |
| `@githubnext/github-copilot-cli` | `github-copilot-cli` | `coding_agents/tasks/main.yml:134-168` |
| `@openai/codex` | `codex` (Linux only — macOS uses brew cask) | `coding_agents/tasks/main.yml:172-236` |
| `@google/gemini-cli` | `gemini` (Linux always; macOS fallback if brew formula fails) | `coding_agents/tasks/main.yml:240-300` |
| `@openchamber/web` | `openchamber` | `coding_agents/tasks/main.yml:1188-1222` |
| `tldr` | `tldr` (Linux only — macOS uses `tlrc` via brew) | `devtools/tasks/main.yml` |
| `tree-sitter-cli` | `tree-sitter` | `lazyvim_deps/tasks/main.yml` (preferred over cargo fallback) |

**Upgrade**: `just upgrade-npm` → `npm -g update` with `mise exec --`
fallback.

**Adding an npm tool**: append to `js_cli_tools/defaults/main.yml` (for
general utilities); for an agent CLI, add the install task to
`coding_agents/tasks/main.yml` matching the existing dispatch pattern
(macOS via system npm, Linux via `mise exec -- npm install -g`).

### 7. cargo (Rust crates)

**Config**: `dot_ansible/roles/rust_cargo_tools/defaults/main.yml`
(currently `cargo_tools: []` — no generic entries).

**Rust install**: `mise install rust@latest` (preferred), with two
fallback layers on noRoot/oldEL boxes: direct `rustup-init`, then
`https://static.rust-lang.org` when the configured mirror's manifest
is stale.

**Inventory** (hard-coded in `tasks/main.yml`):

| Crate | Mechanism | Notes |
|---|---|---|
| `recon` | `cargo install --git https://github.com/gavraz/recon --locked` | git source (no crates.io publish yet) |
| `pueue` | macOS brew formula; Linux `cargo install pueue --locked` | + `pueued.service` systemd user unit; version check `pueue_min_version=4.0.0` (warn-only) |
| `tree-sitter-cli` | `cargo install tree-sitter-cli` (fallback only) | preferred path is `mise exec -- npm install -g tree-sitter-cli`; cargo path installs `libclang-dev`/`clang-devel` first |
| `alacritty` | cargo build (`gui_apps_linux`) | requires apt build deps (`cmake`, `pkg-config`, `libfontconfig1-dev`, `libxcb-xfixes0-dev`, `libxkbcommon-dev`) |
| `modelsdev` | cargo fallback (`llm_tools`) | only when Linuxbrew not present + brew formula `models` not available |
| `cargo-update` | `cargo install cargo-update` (bootstrap for upgrade) | installed by `upgrade_tools.sh::cat_cargo` on first run, then `cargo install-update -a` uses it |

**Upgrade**: `just upgrade-cargo` → `cargo install-update -a` (which
covers everything installed via cargo, including pueue on Linux).

**Adding a cargo tool**: prefer `cargo_tools: [<name>]` in the defaults
YAML (covered by `cargo install-update -a`); hard-code in `tasks/main.yml`
only when the install needs extra build deps or a non-crates.io source
(see `recon`, `pueue`).

### 8. go (Go CLI tools)

**Config**: `dot_ansible/roles/go_tools/defaults/main.yml`

**Go install**: the Go toolchain ships via mise (`go = "latest"`, gated on
`installExtraRuntimes`). The role resolves the mise Go bin dir via
`mise which go` and no-ops cleanly when Go is absent (so lean/CI hosts skip
it). Binaries install into `~/.local/bin` via `GOBIN` (already on PATH via
`dot_config/shell/00_exports.sh.tmpl`) — not `~/go/bin` (`GOPATH/bin`) or the
version-pinned mise toolchain dir. A `creates:` guard makes the install
idempotent.

**Inventory**:

| Package | Binary |
|---|---|
| `github.com/daviddwlee84/translate@v0.1.0` | `translate` (Linux only; macOS → Homebrew `daviddwlee84/tap/translate`) |

**Upgrade**: `just upgrade-go` → `go install <pkg>@latest` per entry (strips
the pinned version). Install pins a known-good version for reproducible fresh
boxes; upgrades move it forward — the same install-vs-upgrade split as cargo.

**Adding a go tool**: append to `go_tools/defaults/main.yml` with `name`
(`<module-path>@<version>`) and `binary` (the resulting command name, used for
the `creates:` guard).

### 9. dotnet (global .NET tools)

**Config**: `dot_ansible/roles/dotnet_tools/defaults/main.yml`

**.NET SDK** ships via `mise use -g dotnet@<version>` (default `latest`).
Once SDK is installed, the role loops `dotnet tool install --global`
for each entry — drops binaries into `~/.dotnet/tools/` (already on PATH
via `dot_config/shell/00_exports.sh.tmpl`).

**Inventory**:

| Package | Binary |
|---|---|
| `azure-cost-cli` | `azure-cost` |

**Upgrade**: `just upgrade-dotnet` → re-runs `dotnet tool update --global`
per tool.

**Adding a dotnet tool**: append to `dotnet_tools/defaults/main.yml`
with `name` (NuGet package id) and `binary` (the actual command name).

### 10. gem (Ruby gems)

**Config**: `dot_ansible/roles/ruby_gem_tools/defaults/main.yml`

**Ruby install**: `mise install ruby@3` (skipped in noRoot Linux).
Build deps installed first: `libffi-dev`, `libyaml-dev` (Debian) /
`libffi-devel`, `libyaml-devel` (RedHat).

**Inventory**:

| Gem | Binary |
|---|---|
| `try-cli` | `try` |
| `tmuxinator` | `tmuxinator` |

Plus `toolkami.rb` fetched as a chezmoi external (see § 13 — runs
standalone, not via `gem install`).

**Upgrade**: `just upgrade-gem` → `gem update`.

**Adding a gem**: append to `ruby_gem_tools/defaults/main.yml` (will
auto-skip on noRoot Linux since ruby isn't installed there).

### 11. curl-installer (self-managed CLIs)

Tools that ship via vendor `install.sh` instead of any package manager.
Mostly the AI coding agents (each vendor maintains their own installer
+ self-update subcommand). All landing paths are user-writable so
in-binary self-update works without sudo.

**Inventory**:

| Tool | Install URL | Lands at | Source role |
|---|---|---|---|
| Homebrew | `https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh` | `/usr/local/bin/brew` (macOS) / `/home/linuxbrew/.linuxbrew/` (Linux) | bootstrap |
| uv | `https://astral.sh/uv/install.sh` | `~/.local/bin/uv` (or `~/.cargo/bin/uv`) | bootstrap |
| mise | `https://mise.run` | `~/.local/bin/mise` | bootstrap |
| just | `https://just.systems/install.sh` | `/usr/local/bin/just` or `~/.local/bin/just` | `base` |
| starship | `https://starship.rs/install.sh` | `/usr/local/bin/starship` or `~/.local/bin/starship` | `starship` |
| atuin | `https://setup.atuin.sh` | `~/.atuin/bin/atuin` | `atuin` |
| docker | `https://get.docker.com` | system docker (rootless variant) | `docker` (Linux) |
| zoxide | (vendor installer) | `~/.local/bin/zoxide` | `devtools` (Linux fallback) |
| direnv | (vendor installer) | `~/.local/bin/direnv` | `devtools` (Linux fallback) |
| **Claude Code** | `https://claude.ai/install.sh` | `~/.claude/local/bin/claude` | `coding_agents` (Linux) |
| **OpenCode** | `https://opencode.ai/install` (+ `--no-modify-path`) | `~/.opencode/bin/opencode` | `coding_agents` (macOS + Linux) |
| **Cursor CLI** | `https://cursor.com/install` | `~/.local/bin/cursor-agent` | `coding_agents` |
| **Antigravity CLI** | `https://antigravity.google/cli/install.sh` (patched `--skip-path --skip-aliases`) | `~/.local/bin/agy` + `agyc` symlink | `coding_agents` |
| **RTK** | `https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh` | `~/.local/bin/rtk` | `coding_agents` (Linux) |
| **llmfit** | `https://llmfit.axjns.dev/install.sh` | `~/.local/bin/llmfit` (or system) | `llm_tools` (Linux) |
| **Ollama** | `https://ollama.com/install.sh` | system path (Linux, sudo) | `llm_tools` (Linux) |
| Ookla speedtest | `https://install.speedtest.net/app/cli/install.<distro>.sh` | system | `networking_tools` (Linux) |

**Why curl-installer over a package manager**:

- Fast-moving releases — vendor controls cadence (Claude, OpenCode,
  Cursor, Antigravity push daily/weekly)
- Self-update subcommand exists and the installer is the canonical
  reinstall path → `cat_agents` in `scripts/upgrade_tools.sh` can call
  either
- Avoids the "brew formula is 3 weeks stale" problem (see commit
  history for the OpenCode move from `anomalyco/tap` to official
  installer)
- No tap/PPA/repo to maintain

**Adding a curl-installer tool**:

1. Pick a role (or add to `coding_agents` if it's an agent)
2. Use the canonical pattern: `which` check → `creates:` guard on the
   binary path → `curl ... | bash [-s -- --no-modify-path]` shell task
3. If the installer mutates shell rc files, add a `--no-modify-path`
   flag (or equivalent — see OpenCode and Antigravity blocks). The
   chezmoi-managed PATH is the SSOT
4. Update `scripts/upgrade_tools.sh::cat_agents` if the tool has a
   self-update subcommand (or just an installer-as-upgrader path)
5. If the binary lands somewhere other than `~/.local/bin` (e.g.
   `~/.opencode/bin/opencode`), add an existence-gated PATH prepend
   to `dot_config/shell/00_exports.sh.tmpl`

### 12. GitHub-release downloads (user-level fallback)

When apt/yum can't satisfy a version requirement (e.g. Apple Silicon
brew bottle missing, RHEL/CentOS package too old, noRoot host with no
sudo), roles fall back to downloading the latest GitHub release tarball
and extracting to `~/.local/bin` (user-writable, already on PATH).

**Canonical pattern**:

```yaml
- name: Get latest <tool> release
  ansible.builtin.uri:
    url: https://api.github.com/repos/<owner>/<repo>/releases/latest
    return_content: true
  register: <tool>_release

- name: Compute <tool> arch
  ansible.builtin.set_fact:
    <tool>_arch: "{{ 'amd64' if target_architecture in ['x86_64', 'amd64'] else 'arm64' if ... else 'unsupported' }}"

- name: Download / extract / copy into ~/.local/bin
  block:
    - get_url: { url: "https://github.com/.../{{ tag }}/{{ asset }}", dest: /tmp/..., retries: 3, delay: 5, timeout: 120 }
    - unarchive: { src: ..., dest: /tmp/..., remote_src: true }
    - find:      { paths: /tmp/..., patterns: <binary>, file_type: file }
    - copy:      { src: ..., dest: "{{ ansible_facts['env']['HOME'] }}/.local/bin/<binary>", mode: '0755' }
  rescue:
    - debug: "<tool> installation failed (likely network timeout) - skipping"
```

**Tools using this pattern** (rough list — see each role's `tasks/main.yml`):

- `base`: `ripgrep`, `fd`, `jq`, `git-lfs`
- `devtools`: `gh`, `glab`, `bat`, `bats`, `eza`, `git-delta`, `diffnav`, `git-graph`, `glow`, `gum`, `vhs`, `freeze`, `duckdb`, `yazi`, `superfile`, `btop`, `zellij`, `sesh`, `worktrunk`, `workmux`, `taplo`, `tv` (television), `lnav`, `tailspin`, `dasel`, `yq`, `jnv`, `witr`
- `networking_tools`: `doggo`, `gping`, `trippy`, `bandwhich`, `rustscan`, `cloudflared`
- `neovim`: nvim tarball
- `lazyvim_deps`: `lazygit` fallback
- `coding_agents`: `specstory`, `codexbar`, `td`, `sidecar`, `agy` (all also have brew formula / cask as primary)
- `security_tools`: `gitleaks`
- `iac_tools`: `terraform`, `opentofu` user fallback (zip from `releases.hashicorp.com` / GitHub)
- `gui_apps_linux`: `AppImageLauncher Lite`, Zen Browser AppImage
- `bitwarden`: Desktop `.deb` fallback (Linux)

**⚠️ Coverage gap**: GitHub-release downloads use a `creates:` guard
on the binary path, so once installed they're **never refreshed by
`chezmoi apply`** — and `scripts/upgrade_tools.sh` has no category for
them. The only way to refresh: `rm` the binary, re-apply. See
[§ Coverage gaps](#coverage-gaps-install-only-no-automated-upgrade)
below.

**Adding a GitHub-release tool**: copy the canonical block from
e.g. `devtools/tasks/main.yml` (look for an existing tool with a
similar arch matrix), substitute owner/repo/asset-name. Always wrap in
`block:` / `rescue:` (vendor-side outages happen) and use
`retries: 3, delay: 5, timeout: 120` on the download.

### 13. chezmoi externals (refresh-periodic git/file fetches)

**Config**: `.chezmoiexternal.toml.tmpl`

`chezmoi apply` fetches these on a schedule. All set
`refreshPeriod = "168h"` (weekly), `--depth 1` clones, `--ff-only`
pulls.

| Path | Type | Source | Gating |
|---|---|---|---|
| `.oh-my-zsh` | git-repo | `ohmyzsh/ohmyzsh.git` | always |
| `.oh-my-zsh/custom/plugins/zsh-autosuggestions` | git-repo | `zsh-users/zsh-autosuggestions.git` | always |
| `.oh-my-zsh/custom/plugins/zsh-syntax-highlighting` | git-repo | `zsh-users/zsh-syntax-highlighting.git` | always |
| `.oh-my-zsh/custom/plugins/zsh-completions` | git-repo | `zsh-users/zsh-completions.git` | always |
| `.oh-my-zsh/custom/plugins/zsh-vi-mode` | git-repo | `jeffreytse/zsh-vi-mode.git` | `enableVimMode` |
| `.oh-my-bash` | git-repo | `ohmybash/oh-my-bash.git` | always |
| `.local/src/blesh` | git-repo (`--recurse-submodules`) | `akinomyoga/ble.sh.git` | always; compiled by `run_onchange_after_26_install_blesh.sh.tmpl` → `~/.local/share/blesh/ble.sh` |
| `.tmux/plugins/tpm` | git-repo | `tmux-plugins/tpm.git` | always |
| `.fzf` | git-repo | `junegunn/fzf.git` | Linux only (ansible runs `~/.fzf/install --bin`) |
| `.local/share/toolkami/toolkami.rb` | file (executable) | `https://raw.githubusercontent.com/aperoc/toolkami/refs/heads/main/toolkami.rb` | always |

**Why externals (not git clone in a role)**:

- Refresh cadence is built-in (chezmoi handles `git pull` on schedule;
  ansible roles don't have a "re-pull every N hours" primitive)
- One place to see "what third-party source code lives on this machine"
- `chezmoi update --refresh-externals` is the explicit forced refresh

**Upgrade**: `just upgrade-externals` → `chezmoi apply --refresh-externals`.

**Adding an external**: prepend an entry to `.chezmoiexternal.toml.tmpl`.
If the cloned repo needs a post-clone compile step (like ble.sh),
attach a `run_onchange_after_NN_*.sh.tmpl` script that re-runs when
the external's commit changes.

**Past pitfalls**:

- ble.sh local-changes-overwritten ([`pitfalls/chezmoi-update-blesh-local-changes-overwritten.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/chezmoi-update-blesh-local-changes-overwritten.md)) — source clone moved out of the chezmoi external path to decouple from `make install`

### 14. apt / yum (system packages)

**The pragmatic Linux backbone**. Roles use apt/yum for tools that
are well-packaged by the distro (i.e. recent enough, available, no
notable upstream-vs-downstream skew).

**Used by these roles** (non-exhaustive):

| Role | apt packages | yum packages |
|---|---|---|
| `base` | `git`, `git-lfs`, `curl`, `wget`, `ripgrep`, `fd-find`, `jq`, `tree`, `build-essential` | `git`, `git-lfs`, `curl`, `wget`, `jq`, `tree`, `gcc`, `gcc-c++`, `make` |
| `bash` | (uses brew on Linux only when primary_shell=bash) | — |
| `zsh` | `zsh` | `zsh` (or ncurses-devel + source build on RHEL 7) |
| `devtools` | `bat`, `gh`, `glab`, `eza`, `git-delta`, `htop`, `pandoc`, `tldr`, etc. (many) | similar subset |
| `media_tools` | `ffmpeg`, `imagemagick`, `libimage-exiftool-perl`, `libvips-tools` | — |
| `networking_tools` | `nmap`, `arp-scan`, `mtr`, `iperf3`, `httpie`, `tcpdump` | same (minus `httpie`) |
| `coding_agents` | `libnotify-bin` (Debian only) | — |
| `lazyvim_deps` | (mostly via mise + GitHub releases) | — |
| `auditd` | `auditd`, `audispd-plugins` | `audit` |
| `gui_apps_linux` | `cmake`, `pkg-config`, font libs (Alacritty build), `libfuse2`, `copyq`, `playerctl`, `wmctrl`, `xdotool` | — |
| `docker` | `uidmap`, `dbus-user-session`, `fuse-overlayfs`, `slirp4netns`, `iptables` (rootless prereqs) | — |
| `iac_tools` | `azure-cli`, `terraform`, `opentofu` (via vendor apt repos) | — |
| `nerdfonts` | `fontconfig` | `fontconfig` |
| `python_uv_tools` | `libffi-dev`, `libyaml-dev`, `python3-dev` (Ruby+ansible-cryptography compile deps) | `libffi-devel`, `libyaml-devel`, `python3-devel` |

**Vendor apt repos managed** (require GPG key + sources.list.d entries):

| Repo | What |
|---|---|
| `apt.releases.hashicorp.com` | terraform |
| `packages.microsoft.com` | azure-cli, vscode |
| `cli.github.com/packages` | gh |
| `gitlab.com/api/v4/projects/.../packages/debian` | glab |
| `pkgs.gierens.de` | eza |
| `ngrok-agent.s3.amazonaws.com` | ngrok |
| `apt.releases.opentofu.org` | opentofu (Cloudsmith) |
| `linux-packages.resilio.com` | resilio-sync |
| PPA `ppa:lazygit-team/release` | lazygit |
| PPA `ppa:appimagelauncher-team/stable` | AppImageLauncher |

**Upgrade**: NOT covered by `scripts/upgrade_tools.sh`. Relies on
`sudo apt upgrade` / `sudo yum update` outside the repo's flow. This is
an intentional gap — distro upgrades are a sysadmin decision, not a
dotfiles decision.

**Adding an apt/yum package**: in the relevant role's `tasks/main.yml`,
add an `ansible.builtin.apt` / `ansible.builtin.yum` task gated on
`os_family`. Always `become: true` + `tags: [sudo]` (so noRoot mode
skips it gracefully) and consider adding a user-level fallback for the
noRoot path if the tool is broadly useful.

---

### 15. ya pkg (Yazi plugins)

Yazi's built-in plugin manager. `ya` (the yazi CLI companion) clones a plugin, copies it into `~/.config/yazi/plugins/`, and pins its revision in `~/.config/yazi/package.toml`.

> **`ya` and `yazi` are a matched pair.** Every upstream release asset ships both binaries; installing only `yazi` yields a host that can never acquire a plugin, and yazi then refuses to start at all (`Failed to load plugin from …/duckdb.yazi/main.lua`). The `devtools` role installs and probes for both. See [pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md).

In this repo the **lockfile is chezmoi-managed** (`dot_config/yazi/package.toml`) and plugins are materialized by `.chezmoiscripts/global/run_after_45_yazi_plugins.sh.tmpl`, which runs `ya pkg install` whenever a declared plugin is missing from `~/.config/yazi/plugins/` **or** the lockfile hash changed. (It is deliberately `run_after_`, not `run_onchange_`: the plugins live outside chezmoi's tree, so a content hash cannot detect them going missing.) `ya pkg install` **rewrites** `package.toml` (normalizes it and strips comments), so the managed source lockfile is kept **comment-free** to match its canonical output — that's what avoids chezmoi drift (never add comments to it).

| Plugin | Purpose |
|---|---|
| `yazi-rs/plugins:piper` (`piper.yazi`) | "pipe any shell command as a previewer" — backs the Office-document previewers in `dot_config/yazi/yazi.toml` (`piper -- view-office --preview …`) and the feather/sqlite preview fallbacks. See [office-viewers.md](../tools/office-viewers.md). |
| `wylie102/duckdb` (`duckdb.yazi`) | DuckDB-powered table previewer for data files (csv/tsv/parquet/xlsx/db/duckdb) — `run = "duckdb"` in `dot_config/yazi/yazi.toml` + required (`pcall`-guarded) `require("duckdb"):setup{}` in `dot_config/yazi/init.lua`. Uses the `duckdb` CLI. See [data-viewers.md](../tools/data-viewers.md). |

**Add a plugin:** `ya pkg add <owner>/<repo>:<plugin>`, then copy `~/.config/yazi/package.toml` back into the source. **Upgrade:** `ya pkg upgrade` → `just upgrade-yazi-plugins` (install-only by design; apply never bumps revs). Requires a recent yazi (`ya pkg` replaced the older `ya pack`).

## Multi-mechanism tools + rationale

Tools where the install path differs by OS / arch / role-feature-flag,
with rationale.

| Tool | Mechanism dispatch | Why |
|---|---|---|
| **uv** | Bootstrap: curl. Later: dispatch between `brew upgrade uv` vs `uv self update` based on binary path | brew installs pin to versioned Cellar — `uv self update` no-ops there. Mirror logic in role + upgrade script keeps both paths working. See [pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md) |
| **OpenCode** | curl-installer on both OSes (2026-05) | Was brew tap (`anomalyco/tap`) on macOS, but formula version lagged + Cellar-pinning broke `opencode upgrade`. Unified on official installer with `--no-modify-path`. See `coding_agents/tasks/main.yml` `# === OpenCode` block |
| **OpenAI Codex CLI** | macOS: brew cask; Linux: npm `@openai/codex` | macOS has the brewed `.app` (richer); Linux only ships npm CLI |
| **Gemini CLI** | macOS: brew formula `gemini-cli` → npm fallback; Linux: npm | brew formula availability is inconsistent |
| **Specstory** | macOS: brew tap → GitHub release fallback; Linux: GitHub release tarball | brew formula availability + version freshness |
| **CodexBar** | macOS: brew cask (homebrew-cask core, universal); Linux: Linuxbrew formula → GitHub release | macOS ships the menu bar app, which bundles the CLI (a superset of the formula); Linux has CLI only |
| **td** / **sidecar** | macOS: brew tap; Linux: Linuxbrew → GitHub release | same maintainer (`marcus/tap`); Linuxbrew is fast path when present |
| **Ollama** | brew formula always (CLI); brew cask `ollama-app` when `installAiDesktopApps + installLlmTools`; Linux: `curl ollama.com/install.sh` | CLI vs GUI split; vendor installer is the canonical Linux path |
| **fzf** | macOS: `lazyvim_deps` brew. Linux: chezmoi external + `~/.fzf/install --bin` | brew is fine on macOS; Linux gets the latest git tip |
| **bash** | system bash always; homebrew bash 5.x only when `primary_shell="bash"` on macOS | macOS ships bash 3.2 (GPL2 vintage); brew bash 5 needed only if user actually wants it as login shell |
| **gh** | macOS: brew (via `devtools`); Linux: vendor apt repo → user tarball fallback | brew is canonical macOS; vendor apt repo is canonical Linux |
| **tmux** | macOS: brew; Linux: apt → `nelsonenzo/tmux-appimage` when system < 3.3 | `display-menu` popup requires 3.3+ — see AGENTS.md tmux hard invariant |
| **Discord** | macOS: brew cask; Linux: flatpak (default) or `.deb` via `discordChannel` chooser | apt has no Discord; flatpak is sandboxed-and-current, `.deb` is for users who hate flatpak |
| **Steam** | macOS: brew cask gated by `installGamingApps`; Linux: Valve apt repo + `steam-launcher` gated by `installGamingApps` | Valve's apt repo is the supported Linux path; Flathub exists but is community-packaged |
| **just**, **starship**, **zoxide**, **direnv** | macOS: brew; Linux: vendor curl-installer | Linux distro packages are too stale for these fast-moving tools |
| **Neovim** | macOS: brew (`state: latest`); Linux: apt → GitHub release tarball → user fallback → `neovim/neovim-releases` on oldEL | Min version 0.11.2 is too new for most distros; no snap by policy |
| **tree-sitter-cli** | npm via mise (preferred, timeout 180) → cargo fallback | npm is faster; cargo needs libclang to compile. Same binary either way |
| **bw (Bitwarden CLI)** | npm global (preferred) or system npm fallback | always npm, the dispatch is mise-npm vs system-npm |

**Adding a tool with multi-mechanism dispatch**: prefer ONE primary
mechanism per OS, with at most ONE fallback. Multiple fallbacks add
test combinations (5 levels × 5 OS variants = 25 cells) that nobody
will actually exercise. If you can't decide, write the simplest version
and add fallbacks only when an actual host fails.

---

## Fallback chains

Notable cascading-fallback patterns:

| Tool | Chain |
|---|---|
| **mise binary** | curl `https://mise.run` (preferred) → direct binary download from `mise.jdx.dev/mise-latest-linux-${arch}` → musl variant (forced when glibc < 2.28) |
| **Neovim (Linux)** | apt → GitHub release tarball when too old (`/opt/nvim` + symlink) → user-tarball to `~/.local` → `neovim-releases` fork (oldEL glibc 2.17 rebuild) |
| **Most Linux CLIs in base/devtools/networking_tools** | apt/yum (sudo) → user-level GitHub release musl tarball to `~/.local/bin`. Several have arch-specific brew-on-aarch64 branch (`eza`, `git-delta`) |
| **Rust (mise)** | configured mirror → official `static.rust-lang.org` → on oldEL: `rustup-init` directly |
| **Cursor `.deb` (Linux)** | `get_url` with retries=4 (large file, GFW-prone) — single mechanism but heavily retried |
| **Bitwarden Desktop (Linux)** | snap → `.deb` fallback |
| **CodexBar / td / sidecar / RTK / specstory / llmfit** | Linuxbrew → GitHub release tarball |
| **uv (upgrade-side)** | inspect binary path → `brew upgrade uv` or `uv self update` |
| **Discord (Linux)** | flatpak (default) → `.deb` (selectable via `discordChannel`) |
| **tree-sitter-cli (Linux)** | `mise exec -- npm install -g tree-sitter-cli` (timeout 180) → `cargo install tree-sitter-cli` (installs `libclang-dev` first) |
| **Antigravity installer** | curl → `sed` patch in-flight to inject `--skip-path --skip-aliases` → bash (avoids profile mutation) |
| **just** | macOS brew → Linux: vendor `curl install.sh` with `sudo` → user-level `--bin-dir ~/.local/bin` fallback |

**Why fallbacks**: noRoot Linux hosts, RHEL/CentOS 7 (glibc 2.17, no
modern bottles, ancient zsh), Apple Silicon Macs (some brew formulae
have no arm64 bottle), Chinese-mirror outages.

---

## Coverage gaps (install-only, no automated upgrade)

Tools that `chezmoi apply` installs but **no `upgrade_tools.sh` category
ever refreshes**. These tools stay frozen at install-time version until
manually removed and re-installed.

| Class | Why no upgrade | How to refresh |
|---|---|---|
| **GitHub-release user-level fallbacks** (~30 tools — see [§ 12](#12-github-release-downloads-user-level-fallback)) | `creates:` guard means ansible never re-downloads | `rm ~/.local/bin/<tool>` then `chezmoi apply` |
| **Vendor apt-repo packages** on Debian (terraform, azure-cli, vscode, opentofu, ngrok, lazygit-from-PPA) | Rely on `sudo apt upgrade` outside this repo | `sudo apt update && sudo apt upgrade` (not chezmoi's job) |
| **Docker convenience-script install** | No upgrade target | re-run `curl get.docker.com \| sh` |
| **OrbStack** | Macos brew cask | Covered by `cat_brew --cask --greedy` |
| **Cursor `.deb`** / **Discord `.deb`** / **VSCode (Microsoft apt)** | apt-side, not chezmoi-side | apt-upgrade |
| **Zen Browser AppImage** / **AppImageLauncher Lite** | One-shot download; Zen's guard globs `zen*.AppImage` (AppImageLauncher renames integrated copies) | Delete **every** `~/Applications/zen*.AppImage`, re-apply |
| **Hack Nerd Font** | `latest` URL, no version tracking | Delete font dir, re-apply |
| **fontconfig / libfuse2 / libnotify-bin / playerctl / wmctrl / xdotool** | System packages, no upgrade automation | apt-upgrade |
| **auditd rules** | Config files, not a "tool" with versions | Edit rule template, re-apply |
| **claude-hud / LazyVim plugins / TPM plugins / pre-commit / tldr cache / gh extensions** | **Covered** by `cat_plugins` in upgrade_tools.sh | `just upgrade-plugins` |

**Why this matters**: a developer who runs `just upgrade-all` on a Linux
host gets brew + mise + uv + npm + cargo + dotnet + gem + flatpak +
agents + plugins moved forward. But ~30 GitHub-release-installed CLIs
(many of them widely-used: ripgrep, fd, jq, git-delta, lazygit, …)
stay pinned to install time forever. This is **partially mitigated**
by:

- These tools on **macOS** all go via brew, which `cat_brew` covers
- On **Linux non-noRoot**, distro packages get apt-upgrade outside the repo
- The gap is sharpest on **noRoot Linux** where GitHub releases are
  the only install path AND there's no upgrade automation

**Coverage gap on `cat_agents`**: only `claude / opencode / cursor-agent
/ ollama / llmfit / rtk / specstory` get the self-update-then-curl loop.
**Missing**: `agy` (Antigravity), `codexbar`, `td`, `sidecar`,
`specify-cli`, `openchamber`, `codex` — these rely on brew / uv / npm
categories instead.

**Tracked on backlog**: no formal item yet, but adding a `releases`
category to `scripts/upgrade_tools.sh` (audit installed binaries
against latest GitHub tag, prompt for refresh) would close this. See
[upgrades.md](upgrades.md#category-matrix) for the current category
list.

---

## Tool index (A–Z)

> Alphabetical lookup. For tools with multiple install paths, the primary
> path is listed first; secondaries appear in the same row separated by ` / `.

| Tool | macOS | Linux | Role |
|---|---|---|---|
| **actionlint** | brew | Linuxbrew (best-effort) | devtools |
| **aerospace** | brew cask (`nikitabobko/tap`) | n/a | Brewfile.darwin |
| **agy** / **agyc** (Antigravity CLI) | curl `antigravity.google/cli/install.sh` | same | coding_agents |
| **alacritty** | brew cask | cargo build (apt deps) | Brewfile.darwin / gui_apps_linux |
| **alt-tab** | brew cask | n/a | Brewfile.darwin |
| **anki** | brew cask | n/a | Brewfile.darwin |
| **ansible-core** | uv tool install | uv tool install | bootstrap |
| **antigravity** (IDE) | brew cask | placeholder | Brewfile.darwin |
| **applite** | brew cask | n/a | Brewfile.darwin |
| **AppImageLauncher** | n/a | PPA → GitHub `.deb` → Lite AppImage | gui_apps_linux |
| **apprise** | uv tool | uv tool | python_uv_tools |
| **arc** | brew cask | n/a | Brewfile.darwin |
| **arp-scan** | brew | apt/yum | networking_tools |
| **atuin** | brew | curl `setup.atuin.sh` | atuin |
| **azure-cli** | brew | Microsoft apt repo → uv tool fallback | iac_tools |
| **azure-cost-cli** (`azure-cost`) | `dotnet tool install --global` | same | dotnet_tools |
| **bandwhich** | brew | GitHub release musl | networking_tools |
| **bash** (5.x) | brew (when `primary_shell="bash"`) | system | bash |
| **bat** | brew | apt + `/usr/bin/bat` symlink → GitHub musl | base/devtools |
| **bats-core** | brew | apt → GitHub `install.sh` | devtools |
| **Bitwarden CLI** (`bw`) | `mise exec -- npm install -g @bitwarden/cli` | same | bitwarden |
| **Bitwarden Desktop** | brew cask | snap → `.deb` | bitwarden |
| **btop** | brew | apt → GitHub release | devtools |
| **build-essential** | n/a | apt | bootstrap (Linux) |
| **bun** | mise | mise | mise |
| **calibre** (`ebook-meta`) | brew cask — opt-in `installCalibre` | apt (`calibre`) — opt-in | devtools — backs Kindle .mobi/.azw/.azw3 metadata previews in yazi via `view-ebook`. See [yazi-previews.md](../tools/yazi-previews.md) |
| **cargo-update** | cargo install (bootstrap for `cat_cargo`) | same | rust_cargo_tools |
| **chafa** | brew | apt (`chafa`) | devtools — yazi image-display fallback (unicode-art); backs all image/pdf/video/heic previews. Shadowed by a `--probe off` shim (`dot_dotfiles/bin/executable_chafa`) to stop the OSC-query→rename-popup leak. See [yazi-previews.md](../tools/yazi-previews.md) |
| **chatgpt** | brew cask (arm64) | n/a | Brewfile.darwin |
| **Claude Code** | brew cask `claude-code` | curl `claude.ai/install.sh` → `~/.claude/local/bin/claude` | coding_agents |
| **claude-hud** | python helper run from role | same | coding_agents |
| **cloudflared** | brew | GitHub `.deb`/binary / `.rpm` | networking_tools (tunnel) |
| **CMux** | brew cask | n/a | Brewfile.darwin |
| **CodexBar** | brew cask `codexbar` (homebrew-cask core) | Linuxbrew `steipete/tap/codexbar` → GitHub release; static-musl asset (and no Linuxbrew) when glibc < 2.38 | coding_agents |
| **codex-app** | brew cask (arm64) | n/a | Brewfile.darwin |
| **codex** (OpenAI Codex CLI) | brew cask `codex` | `mise exec -- npm install -g @openai/codex` | coding_agents |
| **CodeIsland** | brew cask (`wxtsky/tap`) | n/a | Brewfile.darwin |
| **CopyQ** | n/a | apt | gui_apps_linux |
| **coreutils** | brew | (GNU coreutils via apt; macOS gets via brew) | devtools |
| **copyparty** | uv tool | uv tool | python_uv_tools |
| **curl** | system | apt/yum | base + bootstrap |
| **cursor** (IDE) | brew cask | `.deb` from `cursor.com/api/download` | Brewfile.darwin / gui_apps_linux |
| **cursor-agent** (CLI) | curl `cursor.com/install` | same | coding_agents |
| **dasel** | brew | release | devtools |
| **dbeaver-community** | brew cask | n/a | Brewfile.darwin |
| **diffnav** | brew | GitHub release | devtools |
| **direnv** | brew | apt or curl-installer | devtools |
| **discord** | brew cask | flatpak (default) / `.deb` | Brewfile.darwin / gui_apps_linux |
| **docker** | brew cask `orbstack` | `curl get.docker.com` rootless | docker |
| **doggo** | brew | GitHub release | networking_tools |
| **dotenv** (python-dotenv[cli]) | uv tool | uv tool | python_uv_tools |
| **dotnet** | mise | mise | mise |
| **doxx** | brew (homebrew-core) | GitHub release `.tar.xz` | devtools |
| **duckdb** | brew | GitHub release | devtools |
| **duckdb.yazi** | `ya pkg` (Yazi plugin) | `ya pkg` | devtools (yazi) |
| **ethtool** | n/a | apt / yum (`ethtool`) | wake_on_lan |
| **exiftool** | brew | apt (`libimage-exiftool-perl`) | media_tools |
| **eza** | brew | gierens.de apt repo → GitHub musl → brew aarch64 | devtools |
| **fastfetch** | brew | (Linux release if added) | devtools |
| **fd** | brew | apt (`fd-find` + symlink) → GitHub release | base |
| **ffmpeg** | brew | apt | media_tools |
| **figlet** | brew | (apt likely) | devtools |
| **font-hack-nerd-font** | brew cask | GitHub release Hack.zip → `~/.local/share/fonts` | nerdfonts |
| **fontconfig** | (system) | apt/yum | nerdfonts |
| **freeze** | brew | GitHub release | devtools |
| **fzf** | brew (via `lazyvim_deps`) | chezmoi external + `~/.fzf/install --bin` | lazyvim_deps + externals |
| **gawk** | brew | apt/yum | bash |
| **gcc / gcc-c++ / make** | (Xcode CLT) | apt (`build-essential`) / yum | base + bootstrap |
| **gemini** (Gemini CLI) | brew formula `gemini-cli` → npm fallback | `mise exec -- npm install -g @google/gemini-cli` | coding_agents |
| **gh** | brew | vendor apt (.deb) → GitHub tarball | base/devtools |
| **gh-dash** | `gh extension install dlvhdr/gh-dash` | same | devtools |
| **gh-notify** | `gh extension install meiji163/gh-notify` | same | devtools |
| **gh-select** | `gh extension install remcostoeten/gh-select` | same | devtools |
| **git** | brew | apt/yum | base |
| **git-delta** | brew | `.deb` (x86_64) → brew aarch64 → GitHub musl user | devtools |
| **git-filter-repo** | uv tool | uv tool | python_uv_tools |
| **git-graph** | brew | GitHub release (x86_64 only) | devtools |
| **git-lfs** | brew | apt/yum → GitHub release | base |
| **gitleaks** | brew | GitHub release | security_tools |
| **glab** | brew | vendor apt (.deb) → GitHub tarball | devtools |
| **glow** | brew | GitHub release tarball | devtools |
| **go** | mise (`go = "latest"`) | same (mise) | mise (`installExtraRuntimes`) |
| **google-drive** | brew cask | n/a | Brewfile.darwin |
| **github-copilot-cli** (`@githubnext/github-copilot-cli`) | npm global | `mise exec -- npm install -g` | coding_agents |
| **gping** | brew | GitHub release musl | networking_tools |
| **grammarly-desktop** | brew cask | n/a | Brewfile.darwin |
| **grc** | brew | apt | devtools |
| **gum** | brew | GitHub release | devtools |
| **herdr** | GitHub release single binary → `~/.local/bin/herdr` (**not brew** — see note) | GitHub release single binary → `~/.local/bin/herdr` | devtools · upgrade: `just upgrade-herdr` (`herdr update --handoff`, **must run outside herdr**) |
| **herdr-plus** (herdr plugin) | `herdr plugin install cloudmanic/herdr-plus` (prebuilt binary when no Go; idempotent ansible task) | same | devtools |
| **Homebrew** | curl installer | same (Linux, gated) | bootstrap |
| **htop** | brew | apt | devtools |
| **httpie** | brew | apt (Debian) | networking_tools |
| **imagemagick** | brew | apt | media_tools |
| **input methods** (`mcbopomofo`, `squirrel`) | brew cask | (Debian) apt `ibus-rime` | input_method |
| **ipmitool** | n/a | apt/yum (gated on BMC detected) | homelab_tools |
| **iperf3** | brew | apt/yum | networking_tools |
| **jnv** | brew | release | devtools |
| **jq** | brew | apt/yum → GitHub release | base |
| **jupyterlab** (`jupyter-lab`) | uv tool (with notebook, ipykernel, etc.) | uv tool | python_uv_tools |
| **just** | curl `just.systems/install.sh` (always) | same | base |
| **lazygit** | brew (via `lazyvim_deps`) | PPA → GitHub release | lazyvim_deps |
| **libnotify-bin** | n/a | apt (Debian) | coding_agents |
| **libfuse2** | n/a | apt | gui_apps_linux |
| **libreoffice** (`soffice`) | brew cask | apt (`libreoffice-writer/calc/impress`, no-recommends) | devtools |
| **liquidctl** | n/a | apt/yum (gated on a USB cooler / telemetry PSU detected) | homelab_tools |
| **litellm[proxy]** (`litellm`) | uv tool (python 3.13) | uv tool | llm_tools |
| **llmfit** | brew formula | curl `llmfit.axjns.dev/install.sh` | llm_tools |
| **lm-sensors** (`sensors`) | n/a | apt/yum (`lm-sensors`/`lm_sensors`) | homelab_tools |
| **lnav** | brew | apt/release | devtools |
| **lolcat** | brew | (apt) | devtools |
| **maccy** | brew cask | n/a | Brewfile.darwin |
| **marimo** | uv tool (`[recommended,mcp]`) | uv tool | python_uv_tools |
| **markitdown** (`[docx,xlsx,pptx]`) | uv tool | uv tool | python_uv_tools |
| **mas** | brew (shared Brewfile, macOS only) | n/a | Brewfile.tmpl |
| **mise** | curl `mise.run` | curl `mise.run` → direct binary → musl variant | bootstrap |
| **mlflow** | uv tool | uv tool | python_uv_tools |
| **models** | brew formula | Linuxbrew → cargo `modelsdev` | llm_tools |
| **mosh** | brew | apt | devtools |
| **mtr** | brew | apt/yum | networking_tools |
| **nmap** | brew | apt/yum | networking_tools |
| **neovim** | brew (`state: latest`) | apt → GitHub release → user → oldEL fork | neovim |
| **ngrok** | brew cask | vendor apt repo → user tgz / RedHat tgz | networking_tools (tunnel) |
| **node** | brew (via `lazyvim_deps`) | mise | mise + lazyvim_deps |
| **nowplaying-cli** | brew (gated `installMediaControl`) | n/a | media_control |
| **nvme-cli** (`nvme`) | n/a | apt/yum (gated on NVMe detected) | homelab_tools |
| **obsidian** | brew cask | n/a | Brewfile.darwin |
| **ollama** | brew formula `ollama` (CLI) + cask `ollama-app` (GUI) | curl `ollama.com/install.sh` | llm_tools |
| **openchamber** (`@openchamber/web`) | npm global | `mise exec -- npm install -g` | coding_agents |
| **opencode** | curl `opencode.ai/install` (`--no-modify-path`) → `~/.opencode/bin/opencode` | same | coding_agents |
| **opencode-desktop** | brew cask | n/a | Brewfile.darwin |
| **opentofu** (`tofu`) | brew formula | Cloudsmith apt repo → GitHub release | iac_tools |
| **OrbStack** | brew cask | n/a | docker |
| **pandoc** | brew | apt | devtools |
| **peon-ping** (`peon`) | brew tap `PeonPing/tap` (needs `brew trust`, Homebrew 6 gate) | `install.sh --openpeon --no-rc` | coding_agents — agent completion sounds; **never run `peon-ping-setup`** (hooks are declared in `dot_claude/modify_settings.json.tmpl`). Gated by the `agentSounds` prompt. See [agent-sounds.md](../tools/agent-sounds.md) |
| **piper.yazi** | `ya pkg` (Yazi plugin) | `ya pkg` | devtools (yazi) |
| **playerctl / wmctrl / xdotool** | n/a (playerctl: brew via media_control) | apt | gui_apps_linux; playerctl also via media_control (gated `installMediaControl`, backs `sysplay`/`sysnow`) |
| **poppler** (`pdftoppm`) | brew | apt (`poppler-utils`) | devtools — yazi PDF preview. See [yazi-previews.md](../tools/yazi-previews.md) |
| **pre-commit** | `uv tool install --python 3.13` | same | security_tools |
| **procps** | (system) | apt | bootstrap (Linux) |
| **pueue** | brew formula | `cargo install pueue --locked` + systemd user unit | rust_cargo_tools |
| **python-dotenv[cli]** | uv tool | uv tool | python_uv_tools |
| **raycast** | brew cask | n/a | Brewfile.darwin |
| **rclone** | brew | official installer or GitHub | devtools — macOS `rclone mount` also needs **macFUSE** (5.x on macOS 26+), manual & **not** repo-managed (reboot + GUI approval); brew rclone ≥1.73 already ships `mount` so the binary isn't the blocker ([pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/macfuse-too-old-unsupported-macos-version-rclone-mount.md)) |
| **readability-cli** (`readable`) | npm global | `mise exec -- npm install -g` | js_cli_tools |
| **recon** | cargo install (git source) | same | rust_cargo_tools |
| **resilio-sync** | brew cask (GUI app) | Resilio apt repo → headless daemon + WebUI (per-user systemd service) | resilio_sync |
| **resvg** | brew | Linuxbrew → `cargo install resvg` (no apt pkg; non-fatal if absent) | devtools — yazi SVG preview. See [yazi-previews.md](../tools/yazi-previews.md) |
| **ripgrep** | brew | apt/yum → GitHub release | base |
| **rsync** | brew | apt / yum (usually preinstalled) | base — replaces macOS's built-in openrsync 2.6.9 (no `--info` etc.); brew rsync 3.x lands in brew's bin (`/opt/homebrew/bin` Apple Silicon, `/usr/local/bin` Intel) ahead of `/usr/bin` on PATH |
| **ruby** | mise | mise (skipped in noRoot) | mise |
| **rust** | mise | mise → rustup-init → `static.rust-lang.org` fallback | mise + rust_cargo_tools |
| **rustscan** | brew | GitHub release | networking_tools |
| **scroll-reverser** | brew cask | n/a | Brewfile.darwin |
| **sesh** | brew | GitHub release | devtools |
| **sevenzip** (7-Zip; `7zz` / `7z`) | brew (`sevenzip`) | apt (`p7zip-full`) | devtools — yazi archive + dmg listing. See [yazi-previews.md](../tools/yazi-previews.md) |
| **shellcheck / shfmt** | brew | apt or release | devtools |
| **sidecar** | brew tap `marcus/tap` | Linuxbrew → GitHub release | coding_agents |
| **smartmontools** (`smartctl`) | n/a | apt/yum | homelab_tools |
| **specify-cli** | `uv tool install` from git | same | coding_agents |
| **specstory** | brew tap `specstoryai/tap` → GitHub release | GitHub release tarball | coding_agents |
| **speedtest** (Ookla) | brew (tap `teamookla/speedtest`) | `install.speedtest.net` | networking_tools |
| **spotify** | brew cask | n/a | Brewfile.darwin |
| **sqlit-tui[ssh]** | uv tool | uv tool | python_uv_tools |
| **starship** | brew | curl `starship.rs/install.sh` | starship |
| **steam** | brew cask (gated by `installGamingApps`) | Valve apt repo (`steam-launcher`, x86_64, gated by `installGamingApps`) | Brewfile.darwin / gui_apps_linux |
| **storcli** | n/a | vendor/mirror download to `~/.local/bin` (gated on RAID controller detected + `homelab_storcli_url`; not in distro repos) | homelab_tools |
| **super-productivity** | brew cask | n/a | Brewfile.darwin |
| **switchaudio-osx** (`SwitchAudioSource`) | brew (gated `installMediaControl`) | n/a | media_control |
| **superfile** | brew | installer/release | devtools |
| **superset** | brew cask (arm64) | n/a | Brewfile.darwin |
| **tailscale** (CLI) | via the `tailscale-app` cask wrapper (`/usr/local/bin/tailscale` → app; no formula) | (Linux: system pkg outside repo) | Brewfile.darwin |
| **tailscale-app** | brew cask (pkg also installs the `/usr/local/bin/tailscale` CLI wrapper) | n/a | Brewfile.darwin |
| **tailspin** (`tspin`) | brew | release | devtools |
| **taplo** | brew | apt+release | devtools |
| **td** | brew tap `marcus/tap` | Linuxbrew → GitHub release | coding_agents |
| **television** (`tv`) | brew | apt+release | devtools |
| **terminal-notifier** | brew | n/a | coding_agents (macOS) |
| **terraform** | brew (`hashicorp/tap`) | HashiCorp apt repo → user zip | iac_tools |
| **the-unarchiver** | brew cask | n/a | Brewfile.darwin |
| **thefuck** | brew | uv tool (python 3.11 distutils) | devtools |
| **tldr** | (macOS uses `tlrc` via brew) | system npm or `mise exec -- npm install -g tldr` | devtools |
| **tlrc** | brew | (Linux uses `tldr` npm instead) | devtools |
| **tmux** | brew | apt → tmux-appimage when < 3.3 | devtools |
| **tmuxinator** | gem | gem | ruby_gem_tools |
| **tmuxp** | uv tool | uv tool | python_uv_tools |
| **toilet** | brew | (apt) | devtools |
| **translate** | brew (`daviddwlee84/tap`) | go install (`go_tools`) | Brewfile + go_tools |
| **tree** | brew | apt/yum | base |
| **tree-sitter** / **tree-sitter-cli** | brew | mise-npm → cargo fallback | lazyvim_deps |
| **trippy** (`trip`) | brew | apt/release | networking_tools |
| **try-cli** (`try`) | gem | gem | ruby_gem_tools |
| **uv** | curl `astral.sh/uv/install.sh` | same | bootstrap; `python_uv_tools` self-upgrade dispatch |
| **vhs** | brew | GitHub release | devtools |
| **visidata** (`vd`) | uv tool (with pandas, pyarrow) | uv tool | python_uv_tools |
| **vips** | brew | apt (`libvips-tools`) | media_tools |
| **visual-studio-code** | brew cask | Microsoft apt repo | Brewfile.darwin / gui_apps_linux |
| **warp** | brew cask | n/a | Brewfile.darwin |
| **wakeonlan** | brew | apt (`wakeonlan`) | networking_tools |
| **wget** | brew | apt/yum | base |
| **witr** | brew | (release) | devtools |
| **workmux** | brew (tap `raine/workmux`) | GitHub release `.tar.gz` | devtools |
| **worktrunk** | brew | GitHub release | devtools |
| **xonsh** | uv tool (with xontribs) | uv tool | python_uv_tools |
| **yazi** | brew | Linuxbrew/GitHub release | devtools |
| **yq** | brew | release | devtools |
| **yt-dlp** | uv tool | uv tool | python_uv_tools |
| **Zen Browser** | n/a | GitHub release AppImage → `~/Applications/zen.AppImage`, thereafter matched by glob `zen*.AppImage` | gui_apps_linux |
| **zellij** | brew | GitHub release | devtools |
| **zoxide** | brew | curl official installer | devtools |
| **zsh** | brew | apt/yum / source build (RHEL 7) | zsh |

> Tools not listed: `oh-my-zsh`, `oh-my-bash`, `zsh-autosuggestions`,
> `zsh-syntax-highlighting`, `zsh-completions`, `zsh-vi-mode`,
> `ble.sh`, `TPM`, `toolkami.rb` — these live as **chezmoi externals**
> ([§ 13](#13-chezmoi-externals-refresh-periodic-gitfile-fetches)),
> not as "binaries on PATH".

---

## Decision tree for new tools

```
Is the tool needed BEFORE ansible runs?
├── Yes → Bootstrap script (run_once_before_*) — only if absolutely necessary
└── No → continue

Is it a runtime / language interpreter (node, ruby, python, rust, go, dotnet)?
├── Yes → mise (dot_config/mise/config.toml.tmpl) — except python (use uv)
└── No → continue

Is it a Python CLI tool?
├── Yes → uv (append to python_uv_tools/defaults/main.yml)
│         · For LLM-related, llm_tools/defaults/main.yml
│         · Needs gcc ≥ 9? Set needs_modern_gcc: true
│         · Writes companion binaries? Set both with_executables_from and extra_binaries
└── No → continue

Is it a Node/JS CLI tool?
├── Yes → npm via mise (append to js_cli_tools/defaults/main.yml)
│         · Agent CLI? Add to coding_agents/tasks/main.yml instead
└── No → continue

Is it a Rust crate that's well-published on crates.io?
├── Yes → cargo (rust_cargo_tools/defaults/main.yml cargo_tools entry)
│         · Needs build deps or git-source? Hard-code in tasks/main.yml
└── No → continue

Is it a Ruby gem?
├── Yes → gem (ruby_gem_tools/defaults/main.yml)
│         · Skipped on noRoot Linux automatically
└── No → continue

Is it a .NET global tool?
├── Yes → dotnet tool (dotnet_tools/defaults/main.yml)
└── No → continue

Is it a Go CLI tool (installable via `go install`)?
├── Yes → go (append to go_tools/defaults/main.yml: name=<module>@<ver>, binary=<cmd>)
│         · Installs to ~/.local/bin via GOBIN; gated on installExtraRuntimes
│         · Upgrade handled by cat_go in scripts/upgrade_tools.sh (just upgrade-go)
└── No → continue

Is the tool a coding agent CLI (vendor-distributed, ships its own installer)?
├── Yes → curl-installer in coding_agents/tasks/main.yml
│         · Match existing pattern (Claude / OpenCode / Cursor)
│         · Pass --no-modify-path or equivalent (don't mutate shell rc)
│         · Add to cat_agents in scripts/upgrade_tools.sh
│         · Update AICAP SSOT (dot_config/shell/04_ai_agents.sh) +
│           four Python AGENT_CONFIG dicts (see AGENTS.md hard invariant)
└── No → continue

Is it a Yazi plugin?
├── Yes → ya pkg (Yazi's plugin manager; § 15). Lockfile
│         dot_config/yazi/package.toml (chezmoi-managed), materialized by
│         run_after_45_yazi_plugins. `ya pkg add owner/repo:plugin`,
│         copy package.toml back; upgrade via `ya pkg upgrade` (just upgrade-yazi-plugins)
└── No → continue

Is it macOS-shipped, GUI app?
├── Yes → brew cask in Brewfile.darwin.tmpl
│         · Gate on installAiDesktopApps for AI apps
└── No → continue

Is it macOS-shipped, CLI?
├── Yes → brew formula in the relevant role's tasks/main.yml
│         · Add Linux fallback (apt or GitHub release) in same role
│         · Consider whether macOS-only is OK (e.g. terminal-notifier)
└── No → continue

Is it Linux-only, distro-packaged?
├── Yes → apt / yum in the relevant role's tasks/main.yml
│         · become: true + tags: [sudo]
│         · Add user-level GitHub-release fallback for noRoot
└── No → continue

Is it Linux-only, vendor-distributed (ships its own install.sh)?
├── Yes → curl-installer in the relevant role
│         · Use creates: guard
│         · If the binary lands outside ~/.local/bin, add a PATH prepend
│           to dot_config/shell/00_exports.sh.tmpl
└── No → continue

GitHub release tarball (most reliable for everything else):
└── Copy the canonical pattern from devtools/tasks/main.yml
    · block: + rescue: (vendor outages happen)
    · retries: 3, delay: 5, timeout: 120 on get_url
    · Compute arch via target_architecture
    · Extract to ~/.local/bin (user) or /usr/local/bin (sudo + tags: [sudo])
    · ⚠️ This binary will NOT be upgraded automatically (see § Coverage gaps)
```

**Other things to do when adding a tool**:

1. If the tool ships shell completions (`<tool> completion zsh|bash`),
   add a `regen` row in `scripts/generate_completions.sh` (per AGENTS.md
   cross-file rule)
2. If the tool is a new in-house CLI (one of yours, in
   `dot_dotfiles/bin/`), follow the completion decision flow in
   `docs/zsh/zsh-completions.md` Section F (two hand-written completion
   files + row in section F + row in `docs/shells/aliases.md`)
3. If the tool has a notable upgrade story (self-update subcommand,
   etc.), add a category or extend an existing one in
   [`upgrades.md`](upgrades.md)
4. If the tool replaces another tool, add the deprecated path to
   `.chezmoiremove`
5. If the tool is a new alias / shell function, add a row to
   `docs/shells/aliases.md` (per AGENTS.md cross-file rule)

---

## Cross-references

**Other docs that touch this territory**:

- [`upgrades.md`](upgrades.md) — Upgrade-side reference (this doc is install-side)
- [`architecture.md`](architecture.md) — Repo layout + install flow phases
- [`bootstrap.md`](bootstrap.md) — Bootstrap script deep dive
- [`uv-bootstrap.md`](uv-bootstrap.md) — Why and how uv is special
- [`ansible_customization.md`](ansible_customization.md) — Per-host ansible variable overrides
- [`config-conventions.md`](config-conventions.md) — Where deployed config files live
- [`testing.md`](testing.md) — How to verify a tool installed correctly

**AGENTS.md hard invariants relevant here**:

- "Install vs upgrade is split on purpose" — never `state: latest`
- "`with_executables_from:` entries MUST also declare `extra_binaries:`"
- "primaryShell choice gates `chsh` only — both shells always deploy"
- "AI agent autodetect order or AICAP_*_MODEL defaults" — edit only `04_ai_agents.sh`
- "Tmux ≥ 3.3 required" — see `tmux` entry in [§ Multi-mechanism tools](#multi-mechanism-tools--rationale)

**Past pitfalls related to install paths**:

- [`uv-self-update-homebrew-noop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-self-update-homebrew-noop.md) — why uv needs the brew-vs-curl dispatch
- [`uv-tool-install-creates-guard-misses-executables-from.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/uv-tool-install-creates-guard-misses-executables-from.md) — `extra_binaries:` requirement
- [`ansible-js-cli-tools-old-system-node.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-js-cli-tools-old-system-node.md) — why npm goes through mise on Linux
- [`ansible-missing-sudo-tag.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/ansible-missing-sudo-tag.md) — `tags: [sudo]` convention
- [`centos7-neovim-apt-register-defined.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/centos7-neovim-apt-register-defined.md) — neovim user-fallback gate bug
- [`tmux-appimage-terminfo-not-found.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tmux-appimage-terminfo-not-found.md) — tmux-appimage caveat
- [`opencode-docker-opentui-glibc-loader-missing.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/opencode-docker-opentui-glibc-loader-missing.md) — opencode container variant
- [`chezmoi-update-blesh-local-changes-overwritten.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/chezmoi-update-blesh-local-changes-overwritten.md) — externals can drift when post-hook mutates the working tree

**Backlog items related to install paths**:

- [`mise-runtime-gating.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/mise-runtime-gating.md) — fine-grained per-host runtime gating
- [`devtools-role-split.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/devtools-role-split.md) — split the mega-role
- [`lean-bundle-init-ux.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/lean-bundle-init-ux.md) — bundle presets + decision-tree SSOT
- [`opencodebox-wrapper.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/opencodebox-wrapper.md) — containerized opencode wrapper
