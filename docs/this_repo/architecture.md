# Repo architecture & install flow

How `chezmoi apply` deploys configs and triggers ansible / brew on this machine.

## Layout

```
chezmoi repo/
├── dot_* files               → ~/.* (config files)
├── dot_ansible/              → ~/.ansible/ (ansible playbooks)
├── run_once_before_*.tmpl    → bootstrap (runs once)
└── run_onchange_after_*.tmpl → ansible (runs on changes)
```

## Install order

1. **Bootstrap** (`run_once_before`) — installs Homebrew (macOS/Linux), uv, ansible, mise.
2. **`chezmoi apply`** — deploys config files + ansible playbooks.
3. **Ansible** (`run_onchange_after`) — runs on fresh install + when roles change.
4. **Brew bundle** (`run_onchange_after`) — installs GUI apps when enabled.

## Auto-run scripts

| Script | Behavior |
|--------|----------|
| `run_once_before_00_bootstrap.sh.tmpl` | Installs Homebrew (macOS and Linux), uv, mise, ansible |
| `.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl` | Runs ansible with all tags |
| `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` | Runs brew bundle (if `installBrewApps`, or on macOS if `installAiDesktopApps`) |

The onchange script includes SHA256 hashes of all role files. It runs on **fresh install** (no previous hash state) and on **updates** (any role's `tasks/main.yml` or `defaults/main.yml` changes).

To force re-run all scripts:

```bash
chezmoi state delete-bucket --bucket=scriptState
chezmoi apply
```

See [sudo-session.md](sudo-session.md) for the shared sudo cache used by all three run-scripts.

## Externals (`.chezmoiexternal.toml.tmpl`)

Upstream git repos / single-file downloads that used to be cloned by Ansible are declared in `.chezmoiexternal.toml.tmpl` at the repo root. chezmoi fetches them during `chezmoi apply` and re-pulls weekly (`refreshPeriod = "168h"`):

- oh-my-zsh core + 4 custom plugins (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-completions`, `zsh-vi-mode`)
- TPM (tmux plugin manager, `~/.tmux/plugins/tpm`)
- fzf git source (Linux only, `~/.fzf`; apt version lacks `--zsh`)
- toolkami.rb (`~/.local/share/toolkami/toolkami.rb`)

```bash
chezmoi apply                          # normal: pull if older than 168h
chezmoi apply --refresh-externals      # force: pull every external now
```

Ansible retains only the post-clone steps externals can't do:

- `zsh` role — install `zsh` package + change login shell.
- `devtools` role — run `tpm/bin/install_plugins` once (sentinel: `~/.tmux/plugins/.ansible-installed`).
- `lazyvim_deps` role — run `~/.fzf/install --bin` (idempotent via `creates:`).

**When to add an entry here vs Ansible**: use `.chezmoiexternal` when the content is a plain clone / single file and the only conditional is `.chezmoi.os`. Keep things in Ansible when they need arch / `noRoot` / `armv7l` logic, dynamic version paths, or `become: true`. Full schema notes: [chezmoi-prefixes.md → Companion file: `.chezmoiexternal.<format>`](../tools/chezmoi-prefixes.md#companion-file-chezmoiexternalformat).

## Ansible vs Homebrew

**Primary tool: Ansible** — manages CLI tools and system dependencies cross-platform.

| Tool | Role | When to Use |
|------|------|-------------|
| **Ansible** | CLI tools, system packages | Always (apt/brew formulas) |
| **Brewfile** | macOS GUI apps (casks), App Store | Optional (opt-in) |
| **Linuxbrew** | Linux packages not in apt | Always installed on Linux |

Bootstrap installs Homebrew on both macOS and Linux. Ansible roles use `community.general.homebrew` for macOS formulas. Brewfile manages casks (GUI apps) and mas (App Store) separately. On Linux, Ansible uses apt; Linuxbrew is available for newer packages.

Deeper comparison of Linux package sources (apt / snap / Linuxbrew / GitHub binaries) and the policy ansible roles follow: [docs/linux-package-sources.md](../linux-package-sources.md).

## Ansible usage

Ansible playbooks run automatically via `chezmoi apply` when playbook files change. For manual runs, use `~/.ansible/`:

```bash
cd ~/.ansible

ansible-playbook playbooks/macos.yml                    # Full setup (macOS)
ansible-playbook playbooks/linux.yml                    # Full setup (Linux)
ansible-playbook playbooks/macos.yml --tags "neovim"    # Specific tags only
ansible-playbook playbooks/linux.yml --skip-tags "sudo" # Skip sudo tasks
ansible-playbook playbooks/macos.yml --check            # Dry run
```

After modifying playbooks/roles, syntax check:

```bash
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/base.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
```

Or use `just ansible-syntax-check`.

### Available tags

| Tag | Description |
|-----|-------------|
| `base` | git, git-lfs, curl, ripgrep, fd, build tools |
| `homebrew` | macOS Homebrew update (installation done by bootstrap) |
| `zsh` | zsh, oh-my-zsh, plugins (autosuggestions, syntax-highlighting, completions) |
| `starship` | Starship cross-shell prompt |
| `neovim` | Neovim (>= 0.11.2) |
| `lazyvim_deps` | fzf, lazygit, tree-sitter-cli, Node.js (via mise) |
| `devtools` | bat, bats, eza, gh, glab, git-delta, git-graph, tldr, glow, thefuck, zoxide, direnv, yazi, superfile, tmux+tpm, sesh, zellij, btop, htop, taplo, television, pandoc |
| `docker` | Docker/container runtime (OrbStack on macOS, Docker Engine on Linux) |
| `nerdfonts` | Hack Nerd Font for terminal emulators |
| `coding_agents` | Claude Code, OpenCode, Cursor CLI, Copilot CLI, Gemini CLI, RTK, SpecStory |
| `bitwarden` | Bitwarden CLI (`bw`) via npm + Desktop app on desktop profiles, with zsh completion + SSH agent integration |
| `security_tools` | `pre-commit` (via `uv tool install --python 3.13` on all OSes — single source of truth; run `just pre-commit-doctor` if hook envs break), gitleaks |
| `python_uv_tools` | Python CLI tools via uv (apprise, mlflow, sqlit-tui, tmuxp, etc.) |
| `js_cli_tools` | Standalone JS/npm CLI utilities (readability-cli for `readnode`) |
| `llm_tools` | Local LLM tools: Ollama, LiteLLM, llmfit, models |
| `rust_cargo_tools` | Rust CLI tools via cargo (pueue) |
| `ruby_gem_tools` | Ruby CLI tools via gem (try-cli, tmuxinator, toolkami) |
| `input_method` | Traditional Chinese input methods: McBopomofo + RIME (Squirrel on macOS, ibus-rime on Linux) |
| `networking_tools` | nmap, arp-scan, mtr, iperf3, doggo, httpie, gping, trippy, bandwhich, speedtest, rustscan |
| `iac_tools` | Azure CLI (`az`), Terraform, OpenTofu (`tofu`) |
| `gui_apps` | Linux-only desktop app installer: Alacritty (cargo), AppImageLauncher, VSCode, Cursor, libfuse2. macOS equivalents in `dot_config/homebrew/Brewfile.darwin.tmpl`. See [docs/tools/appimage.md](../tools/appimage.md). |

Full customization guide: [ansible_customization.md](ansible_customization.md).

## Profiles

| Profile | OS | Tags Included |
|---------|-----|---------------|
| `macos` | macOS | homebrew, base, zsh, starship, neovim, lazyvim_deps, devtools, docker, nerdfonts, security_tools, rust_cargo_tools, ruby_gem_tools (alacritty via Brewfile cask) |
| `ubuntu_desktop` | Ubuntu | base, zsh, starship, neovim, lazyvim_deps, devtools, docker, nerdfonts, security_tools, rust_cargo_tools, ruby_gem_tools, gui_apps |
| `ubuntu_server` | Ubuntu | base, zsh, starship, neovim, lazyvim_deps, devtools, docker, security_tools, rust_cargo_tools, ruby_gem_tools |

**Tag categories:**

- **Core** (all): base, zsh, starship, neovim, lazyvim_deps, security_tools
- **Desktop** (macos, ubuntu_desktop): nerdfonts
- **macOS only**: homebrew
- **Optional** (via chezmoi config): coding_agents, bitwarden, python_uv_tools, js_cli_tools, llm_tools, input_method (desktop only), networking_tools, iac_tools

`ubuntu_server` excludes `nerdfonts` (no GUI needed).

## No-root mode (Linux)

For Linux servers without sudo/root access, enable `noRoot = true` during `chezmoi init`:

```bash
chezmoi init --force  # Answer "y" to "No sudo/root access" prompt
```

This skips all tasks tagged with `[sudo]` (apt packages, system-level installations). Tools with user-level fallbacks are automatically installed to `~/.local/bin`.

**User-level tools** (installed automatically without sudo):

- **GitHub binaries**: neovim, ripgrep, fd, jq, just, bat, bats, eza, delta, yazi, superfile, zellij, btop, gitleaks, lazygit, fzf, sesh, taplo, television
- **tmux-appimage** (x86_64 only): extracted AppImage → `~/.local/share/tmux-appimage/squashfs-root`, shim at `~/.local/bin/tmux`. Runs only when system `tmux` is older than 3.3.
- **mise**: Node.js, Rust runtime management
- **Installers**: zoxide, starship, thefuck, tldr
- **cargo tools**: pueue
- **uv tools**: `pre-commit` (pinned to `--python 3.13`, see [docs/tools/pre-commit.md](../tools/pre-commit.md)), mlflow, sqlit-tui, tmuxp
- **llm tools**: ollama, litellm, llmfit, models
- **npm tools**: Claude Code, OpenCode, Gemini CLI, Bitwarden CLI

**What you won't get without root**: zsh (needs `/etc/shells`), htop, direnv (apt only), Docker, Ollama service, system fonts, ruby + gem tools, build-essential / git / curl / wget / tree (assumed pre-installed).

**Tip**: ask sysadmin to run `sudo apt install git curl wget zsh tmux htop direnv build-essential tree`.

## ARM / Raspberry Pi support

Raspberry Pi 5 (64-bit OS only) works with the `ubuntu_server` profile and gets full tool support. Raspberry Pi 4 may run 32-bit Raspberry Pi OS (armhf userland) with a 64-bit kernel (`arm_64bit=1` default), which causes `uname -m` to report `aarch64` while userland is 32-bit.

**How it's handled:**

- **Bootstrap** detects userland architecture via `dpkg --print-architecture`; skips Linuxbrew on armhf (Homebrew requires amd64 or arm64 userland).
- **Ansible playbooks** (`linux.yml`) override `ansible_architecture` in `pre_tasks` to match real userland (e.g. `armv7l` instead of `aarch64`), so roles download correct binaries.
- **Tool availability on armhf**: apt packages work fine; GitHub release downloads are skipped for tools without armv7l builds.

**Tools with armv7l/armhf releases** (work on RPi 4 32-bit): ripgrep, fd, jq, glow, rclone, direnv, gitleaks, trippy, speedtest, bats.

**Tools skipped on armv7l** (no 32-bit ARM release): neovim (GitHub tarball), lazygit, eza, git-delta, yazi, superfile, zellij, sesh, taplo, television, duckdb, doggo, gping, bandwhich, SpecStory, CodexBar, Claude Code (install.sh ships arm64/amd64 only).

**Skipped via mise on armv7l**: bun, ruby; node pinned to `node@20` (last LTS with armv7l tarball). npm-based tools install via `mise exec -- npm`. tree-sitter-cli skipped (cargo build needs libclang, takes 15+ min on RPi 4).

**Recommendation**: use 64-bit Raspberry Pi OS for full tool compatibility.

## Brewfile (GUI apps, opt-in)

GUI applications managed via Homebrew Brewfile in `~/.config/homebrew/`. Installation is **opt-in** (disabled by default): enable via `chezmoi init --force` and set `installBrewApps = true`. On macOS, AI desktop apps are a separate opt-in via `installAiDesktopApps = true`.

```
~/.config/homebrew/
├── Brewfile          # Shared: taps, CLI formulas, mas
├── Brewfile.darwin   # macOS: casks (GUI apps), mas entries
└── Brewfile.linux    # Linux: linuxbrew-specific (minimal)
```

```bash
chezmoi edit ~/.config/homebrew/Brewfile.darwin       # Edit
brew bundle --file=~/.config/homebrew/Brewfile        # Apply manually
brew bundle check --file=~/.config/homebrew/Brewfile.darwin  # Check
chezmoi apply                                         # Or trigger via run_onchange
```

**Categories (darwin)**: terminals & editors (alacritty, iterm2, warp, cmux, cursor, vscode), AI & coding (claude, chatgpt, opencode-desktop, antigravity, codex-app on Apple Silicon, ollama-app gated on `installAiDesktopApps` + `installLlmTools`), system utilities (aerospace, alt-tab, raycast, jordanbaird-ice), communication (discord, telegram, wechat, tencent-meeting), browsers (arc, google-chrome, tor-browser), productivity (obsidian, google-drive, grammarly-desktop), gaming (steam, minecraft, battle-net — skipped if `WORK_MACHINE` env set), finance (binance, tradingview), network (tailscale, openvpn-connect, clash-verge-rev), Mac App Store (LINE, Keynote, Numbers, Pages).

**Conditional sections** (Brewfiles are chezmoi templates):

- Gaming apps: skipped if `WORK_MACHINE` is set.
- Chinese apps (baidunetdisk): only included if `useChineseMirror` is true.
- mas apps: requires signing in to App Store.app first.
