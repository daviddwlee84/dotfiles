# Dotfiles Repository

Cross-platform dotfiles management using **chezmoi** for configuration files and **ansible** for system dependencies.

## Maintaining README.md

**IMPORTANT**: When adding or modifying configurations, update `README.md` to reflect changes:

- **New config files**: Add to "What You Get > Config Files" section
- **New ansible roles/tools**: Add to "What You Get > Tools" section
- **New platforms**: Add to "Supported Platforms" table
- **Changed setup steps**: Update "Quick Setup" section

Keep README.md concise and user-focused. Technical details belong in CLAUDE.md or docs/.

## Maintaining Custom Aliases & Shell Functions

**IMPORTANT**: When adding or modifying a custom alias or shell function in any `dot_config/zsh/` file, update `docs/zsh/aliases.md`:

- **New entry**: add a row with the command name, type (`alias` or `function`), source file (relative to repo root), and a one-line description
- **Modified entry**: update the existing row to reflect changes
- **Removed entry**: delete the row

This keeps `docs/zsh/aliases.md` as the single quick-reference for all custom shell shortcuts.

## Maintaining Dockerfile

**IMPORTANT**: When adding new chezmoi prompts in `.chezmoi.toml.tmpl`, also update `Dockerfile`:

1. Add corresponding `ARG CHEZMOI_*` build argument
2. Add `--promptBool` or `--promptString` flag to the `chezmoi init` command

This ensures Docker testing works with all configuration options.

## Maintaining Keyboard Shortcuts

**IMPORTANT**: When adding or modifying keybindings in any tool config, cross-check against other tools to avoid conflicts. Multiple tools share the terminal's key namespace — especially `Ctrl+` and `Alt+` modifiers.

**Conflict surfaces to check:**

| Tool | Config file | Key conflict risk |
|------|-------------|-------------------|
| tmux (root-table) | `dot_config/tmux/keybindings.conf` | `C-h/j/k/l` (vim-tmux-navigator), `C-1..9` (window switch) |
| Television (global) | `dot_config/television/config.toml` | `Ctrl+S/F/R/Y/T/X/O` (built-in actions) |
| Television (channels) | `dot_config/television/cable/*.toml` | Per-channel `[keybindings]` override global |
| Zellij | `dot_config/zellij/config.kdl` | Mitigated by `default_mode "locked"` |
| Ghostty | `dot_config/ghostty/config` | `macos-option-as-alt` affects `Alt+` availability |

**Known conflict zones:**

- `Ctrl+H/J/K/L` — tmux vim-tmux-navigator pane navigation; removed/remapped in TV global config
- `Ctrl+S/F/R` — TV built-in cycling/reload; avoid in channel actions
- `Alt+*` — safe namespace for channel-specific actions (used by pueue channel); requires terminal to send Option as Meta

**Resolution precedence:** tmux root-table bindings intercept keys before they reach the inner application. When running TV inside tmux, any `bind-key -n C-*` in tmux will shadow the same `ctrl-*` in TV. Prefer `Alt+` for custom actions to avoid this entirely.

## Quick Start

```bash
# Install ansible (if not already installed)
uv tool install ansible-core
ansible-galaxy collection install community.general

# Apply dotfiles
chezmoi apply

# Run ansible manually (from ~/.ansible directory)
cd ~/.ansible && ansible-playbook playbooks/macos.yml
```

## Architecture

```
chezmoi repo/
├── dot_* files               → ~/.* (config files)
├── dot_ansible/              → ~/.ansible/ (ansible playbooks)
├── run_once_before_*.tmpl    → bootstrap (runs once)
└── run_onchange_after_*.tmpl → ansible (runs on changes)
```

Installation Order:

```
1. Bootstrap (run_once_before) - installs Homebrew (macOS/Linux), uv, ansible, mise
2. chezmoi apply - deploys config files + ansible playbooks
3. Ansible (run_onchange_after) - runs on fresh install + when roles change
4. Brew bundle (run_onchange_after) - installs GUI apps if enabled
```

### Auto-run Scripts

| Script | Behavior |
|--------|----------|
| `run_once_before_00_bootstrap.sh.tmpl` | Installs Homebrew (macOS and Linux), uv, mise, ansible |
| `run_onchange_after_20_ansible_roles.sh.tmpl` | Runs ansible with all tags |
| `run_onchange_after_30_brew_bundle.sh.tmpl` | Runs brew bundle (if `installBrewApps` is enabled, or on macOS if `installAiDesktopApps` is enabled) |

The onchange script includes SHA256 hashes of all role files. It runs:

- **Fresh install**: no previous hash state → triggers run
- **Updates**: any role's `tasks/main.yml` or `defaults/main.yml` changes → triggers run

To force re-run all scripts:

```bash
chezmoi state delete-bucket --bucket=scriptState
chezmoi apply
```

## Chezmoi Commands

```bash
chezmoi diff              # Preview changes
chezmoi apply             # Apply changes
chezmoi apply --dry-run   # Test without applying
chezmoi edit <file>       # Edit source file
chezmoi cd                # Go to source directory
```

## Ansible Usage

Ansible playbooks run automatically via `chezmoi apply` when playbook files change. For manual runs, use `~/.ansible/` directory:

```bash
cd ~/.ansible

# Full setup (macOS)
ansible-playbook playbooks/macos.yml

# Full setup (Linux)
ansible-playbook playbooks/linux.yml

# Specific tags only
ansible-playbook playbooks/macos.yml --tags "neovim,lazyvim_deps"

# Skip tags requiring sudo
ansible-playbook playbooks/linux.yml --skip-tags "sudo"

# Dry run
ansible-playbook playbooks/macos.yml --check
```

### Available Tags

| Tag | Description |
|-----|-------------|
| `base` | git, git-lfs, curl, ripgrep, fd, build tools |
| `homebrew` | macOS Homebrew update (installation done by bootstrap) |
| `zsh` | zsh, oh-my-zsh, plugins (autosuggestions, syntax-highlighting, completions) |
| `starship` | Starship cross-shell prompt (replaces oh-my-zsh theme) |
| `neovim` | Neovim (>= 0.11.2) |
| `lazyvim_deps` | fzf, lazygit, tree-sitter-cli, Node.js (via mise) |
| `devtools` | bat, bats, eza, gh, glab, git-delta, git-graph, tldr, glow, thefuck, zoxide, direnv, yazi, superfile, tmux+tpm, sesh, zellij, btop, htop, taplo, television, pandoc |
| `docker` | Docker/container runtime (OrbStack on macOS, Docker Engine on Linux) |
| `nerdfonts` | Hack Nerd Font for terminal emulators |
| `coding_agents` | Claude Code, OpenCode, Cursor CLI, Copilot CLI, Gemini CLI, RTK, SpecStory |
| `bitwarden` | Bitwarden CLI (`bw`) via npm + Desktop app (snap/deb on Linux, cask on macOS) on desktop profiles, with zsh completion + SSH agent integration |
| `security_tools` | pre-commit, gitleaks |
| `python_uv_tools` | Python CLI tools via uv (apprise, mlflow, sqlit-tui, tmuxp, etc.) |
| `llm_tools` | Local LLM tools: Ollama, LiteLLM, llmfit, models |
| `rust_cargo_tools` | Rust CLI tools via cargo (pueue) |
| `ruby_gem_tools` | Ruby CLI tools via gem (try-cli, tmuxinator, toolkami) |
| `input_method` | Traditional Chinese input methods: McBopomofo + RIME (Squirrel on macOS, ibus-rime on Linux) |
| `networking_tools` | Networking CLI tools: nmap, arp-scan, mtr, iperf3, doggo, httpie, gping, trippy, bandwhich, speedtest, rustscan |
| `alacritty` | GPU-accelerated terminal emulator (cargo install on Linux, Homebrew cask on macOS) |

## Profiles

| Profile | OS | Tags Included |
|---------|-----|---------------|
| `macos` | macOS | homebrew, base, zsh, starship, neovim, lazyvim_deps, devtools, docker, nerdfonts, security_tools, rust_cargo_tools, ruby_gem_tools, alacritty |
| `ubuntu_desktop` | Ubuntu | base, zsh, starship, neovim, lazyvim_deps, devtools, docker, nerdfonts, security_tools, rust_cargo_tools, ruby_gem_tools, alacritty |
| `ubuntu_server` | Ubuntu | base, zsh, starship, neovim, lazyvim_deps, devtools, docker, security_tools, rust_cargo_tools, ruby_gem_tools |

**Tag categories:**

- **Core** (all): base, zsh, starship, neovim, lazyvim_deps, security_tools
- **Desktop** (macos, ubuntu_desktop): nerdfonts
- **macOS only**: homebrew
- **Optional** (via chezmoi config): coding_agents, bitwarden, python_uv_tools, llm_tools, input_method (desktop only), networking_tools

Note: `ubuntu_server` excludes `nerdfonts` (no GUI needed).

## No Root Mode (Linux)

For Linux servers where you don't have sudo/root access, enable `noRoot = true` during `chezmoi init`:

```bash
chezmoi init --force  # Answer "y" to "No sudo/root access" prompt
```

This skips all tasks tagged with `[sudo]` (apt packages, system-level installations). Tools with user-level fallbacks are automatically installed to `~/.local/bin` instead.

**User-level tools** (installed automatically without sudo):

- **GitHub binaries**: neovim, ripgrep, fd, jq, just, bat, bats, eza, delta, yazi, superfile, zellij, btop, gitleaks, lazygit, fzf, sesh, taplo, television
- **tmux-appimage** (x86_64 only): extracted AppImage → `~/.local/share/tmux-appimage/squashfs-root`, shim at `~/.local/bin/tmux`. Runs only when the system `tmux` is older than 3.3 (see "tmux version requirement" below).
- **mise**: Node.js, Rust runtime management
- **Installers**: zoxide, starship, pre-commit, thefuck, tldr
- **cargo tools**: pueue
- **uv tools**: mlflow, sqlit-tui, tmuxp, etc.
- **llm tools**: ollama, litellm, llmfit, models
- **npm tools**: Claude Code, OpenCode, Gemini CLI, Bitwarden CLI, etc.

What you **won't get** without root:

- zsh (needs `/etc/shells` for login shell)
- htop (requires system libraries)
- direnv (apt only)
- Docker (kernel features, daemon)
- Ollama (system service install)
- System fonts (nerdfonts)
- Ruby and gem tools (ruby-build requires `libffi-dev` which needs sudo)
- build-essential, git, curl, wget, tree (assumed pre-installed)

**Tip**: Ask your sysadmin to run: `sudo apt install git curl wget zsh tmux htop direnv build-essential tree`

## ARM / Raspberry Pi Support

Raspberry Pi 5 (64-bit OS only) works with the `ubuntu_server` profile and gets full tool support. Raspberry Pi 4 may run 32-bit Raspberry Pi OS (armhf userland) with a 64-bit kernel (`arm_64bit=1` default), which causes `uname -m` to report `aarch64` while userland is 32-bit.

**How it's handled:**

- **Bootstrap**: Detects userland architecture via `dpkg --print-architecture`; skips Linuxbrew on armhf (Homebrew requires amd64 or arm64 userland)
- **Ansible playbooks**: `linux.yml` has `pre_tasks` that override `ansible_architecture` to match the real userland (e.g. `armv7l` instead of `aarch64`), so roles download correct binaries
- **Tool availability on armhf (32-bit ARM)**: apt packages work fine; GitHub release downloads are skipped for tools without armv7l builds

**Tools with armv7l/armhf releases** (work on RPi 4 32-bit): ripgrep, fd, jq, glow, rclone, direnv, gitleaks, trippy, speedtest, bats (pure-bash, arch-agnostic)

**Tools skipped on armv7l** (no 32-bit ARM release): neovim (GitHub tarball), lazygit, eza, git-delta, yazi, superfile, zellij, sesh, taplo, television, duckdb, doggo, gping, bandwhich, SpecStory, CodexBar, Claude Code (install.sh ships arm64/amd64 only)

**Tools skipped on armv7l via mise** (no armv7l prebuilt): bun, ruby; node pinned to `node@20` (last LTS with armv7l tarball). npm-based tools (tldr, etc.) install via `mise exec -- npm` and work on armv7l. tree-sitter-cli is still skipped (cargo build needs libclang and takes 15+ min on RPi 4).

**Recommendation**: Use 64-bit Raspberry Pi OS for full tool compatibility.

## Tmux Configuration

**Minimum version: tmux >= 3.3.** The popup menu on `prefix + Space` uses `display-menu -x R -y P`; tmux 3.2a places the menu past the terminal edge and silently suppresses it ("_If the menu is too large to fit on the terminal, it is not displayed._"), while 3.3+ clamps the position. The Ansible `devtools` role detects old tmux on Debian/Ubuntu and upgrades automatically: Linuxbrew when present, otherwise a user-level install of [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage) extracted to `~/.local/share/tmux-appimage/` with a shim at `~/.local/bin/tmux`. After the upgrade, run `tmux kill-server` once so existing sessions switch over to the new binary (running servers keep the old binary in memory).

The tmux config is modular under `dot_config/tmux/` (deployed to `~/.config/tmux/`), with `dot_tmux.conf` acting as a one-line shim at `~/.tmux.conf`. Structure: `tmux.conf` (entry point + theme selector), `common.conf` (plugins, general options, terminal compat), `keybindings.conf` (all binds + popup menu), `theme.catppuccin.conf` (default, top status bar), `theme.tmux2k.conf` (alternative, bottom bar).

Theme selection priority: `$TMUX_THEME` env var → `@theme_variant` tmux option → default `catppuccin`. Switch at runtime with `prefix + M-c` (Catppuccin) or `prefix + M-t` (tmux2k). See `docs/tools/tmux/` (README, keybindings, themes, vim) for full details, including a troubleshooting note on the tmux2k bandwidth segment (`18446744073709551615K` = uint64 underflow).

The Catppuccin status bar is **responsive**: `responsive.sh` + a `client-resized` hook dynamically adjust which modules are shown based on terminal width (>= 120 full, 80-119 medium, < 80 minimal). This makes the status bar usable on mobile terminals. See `docs/tools/tmux/themes.md` for details.

### Key Settings for Coding Agents

- `extended-keys always` + `terminal-features 'xterm*:extkeys'` -- forwards Shift+Enter, Ctrl+Enter, etc. through tmux to inner applications (Claude Code, Neovim, etc.)
- `escape-time 0` -- eliminates ESC delay for Neovim
- `set-clipboard on` + `terminal-features …:clipboard` (for `xterm*`, `ghostty*`, `alacritty*`) -- OSC 52 clipboard works over SSH without relying on terminfo `Ms`. Paired with an SSH-conditional `vim.g.clipboard = vim.ui.clipboard.osc52` in `dot_config/nvim/lua/config/options.lua` so remote Neovim yanks reach the local clipboard. See `docs/tools/tmux/README.md` → "OSC 52 Clipboard" for verification steps.
- `allow-passthrough on` -- OSC passthrough for terminal images
- macOS terminals must send Option as Meta/Esc+ for `M-` keybindings (theme switching, layouts, fine resize). Ghostty/cmux: `macos-option-as-alt = left` (managed in `dot_config/ghostty/config`). See `docs/tools/ghostty.md`.

### Tmux Keybindings

| Binding | Action |
|---------|--------|
| `Ctrl + 1..9` | Switch to window 1–9 (no prefix, requires CSI-u terminal) |
| `Ctrl + 0` | Jump to git root session via sesh (no prefix, requires CSI-u) |
| `prefix + Space` | Native popup menu (layouts, sessions, sesh, resize, etc.) |
| `prefix + h/j/k/l` | Navigate panes (vim-style) |
| `prefix + H/J/K/L` | Resize panes (5 cells) |
| `prefix + M-h/j/k/l` | Fine resize panes (1 cell) |
| `prefix + +` | Set current pane to 75% width |
| `prefix + \|` | Split pane left/right |
| `prefix + -` | Split pane top/bottom |
| `prefix + F` | Toggle floating pane (tmux-floax) |
| `prefix + P` | Floax popup menu |
| `prefix + u` | Open fzf URL picker (tmux-fzf-url) |
| `prefix + [` | Enter vim-style copy mode (v/V/y to select/yank) |
| `prefix + y` | Copy visible pane to clipboard |
| `prefix + Y` | Copy full scrollback to clipboard |
| `prefix + C-y` | fzf line picker from scrollback |
| `prefix + g` | Sesh session picker (fzf popup) |
| `prefix + T` | Sesh session picker (television popup) |
| `prefix + O` | Sesh built-in picker popup |
| `prefix + W` | Sesh window picker (fzf popup) |
| `prefix + S` | Switch to last session (sesh) |
| `prefix + 9` | Jump to git root session (sesh) |
| `prefix + N` | New session (prompts for name) |
| `prefix + X` | Kill session (with confirmation) |
| `prefix + M` | Move window to another session (tab tear-out) |
| `prefix + B` | Break pane into new window in another session |
| `prefix + A` | Link window into another session (shared, not copied) |
| `prefix + R` | Reload tmux config |
| `prefix + M-c` | Switch theme to Catppuccin (top status bar) |
| `prefix + M-t` | Switch theme to tmux2k (bottom status bar) |

Note: `Ctrl+Space` is NOT bound (reserved for input method switching). `Ctrl+1..9` and `Ctrl+0` require CSI-u terminal support (Ghostty/cmux, Alacritty, Kitty); legacy terminals fall back to `prefix + number`. Popup menu accelerator keys match standalone `prefix + key` bindings (see `docs/tools/tmux/keybindings.md` for full mapping).

## Zellij Configuration

Zellij config (`dot_config/zellij/config.kdl`) uses `default_mode "locked"` so all keys pass through to inner applications by default. Press `Ctrl+G` to unlock Zellij commands. This prevents key conflicts with coding agents and vim-style applications.

On first Zellij launch (without existing config), select the "Unlock-First (non-colliding)" keybinding preset for the best experience.

## LazyVim Requirements

- Neovim >= 0.11.2
- ripgrep, fd
- Node.js (via mise on Linux, Homebrew on macOS)
- tree-sitter-cli
- lazygit, fzf (via git on Linux, Homebrew on macOS)

## Directory Structure

After `chezmoi apply`:

- Config files in `~/.*`
- Ansible playbooks in `~/.ansible/`

## Development

After modifying ansible playbooks or roles, run syntax check:

```bash
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/base.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/macos.yml
ANSIBLE_CONFIG=dot_ansible/ansible.cfg ansible-playbook --syntax-check dot_ansible/playbooks/linux.yml
```

## Ansible vs Homebrew

**Primary tool: Ansible** - manages CLI tools and system dependencies cross-platform.

| Tool | Role | When to Use |
|------|------|-------------|
| **Ansible** | CLI tools, system packages | Always (apt/brew formulas) |
| **Brewfile** | macOS GUI apps (casks), App Store | Optional (opt-in) |
| **Linuxbrew** | Linux packages not in apt | Always installed on Linux |

**How they work together:**

- Bootstrap installs Homebrew on both macOS and Linux
- Ansible roles use `community.general.homebrew` for macOS formulas
- Brewfile manages casks (GUI apps) and mas (App Store) separately
- On Linux, Ansible uses apt; Linuxbrew is available for newer packages

For a deeper comparison of Linux package sources (apt / snap / Linuxbrew / GitHub binaries) and the policy the ansible roles follow when picking between them, see [docs/linux-package-sources.md](docs/linux-package-sources.md).

## Brewfile (GUI Apps - Opt-in)

GUI applications are managed via Homebrew Brewfile in XDG-compliant location `~/.config/homebrew/`.

**Note**: Brewfile installation is **opt-in** (disabled by default). Enable general GUI apps via `chezmoi init --force` and set `installBrewApps = true`. On macOS, AI desktop apps are a separate opt-in via `installAiDesktopApps = true`.

### File Structure

```
~/.config/homebrew/
├── Brewfile          # Shared: taps, CLI formulas, mas
├── Brewfile.darwin   # macOS: casks (GUI apps), mas entries
└── Brewfile.linux    # Linux: linuxbrew-specific (minimal)
```

### Usage

```bash
# Edit Brewfiles
chezmoi edit ~/.config/homebrew/Brewfile.darwin

# Apply changes manually
brew bundle --file=~/.config/homebrew/Brewfile
brew bundle --file=~/.config/homebrew/Brewfile.darwin

# Or just run chezmoi apply (triggers run_onchange script)
chezmoi apply

# Check what would be installed
brew bundle check --file=~/.config/homebrew/Brewfile.darwin
```

### Brewfile Categories (darwin)

- **Terminals & Editors**: alacritty, iterm2, warp, cmux, cursor, visual-studio-code
- **AI & Coding**: claude, chatgpt, opencode-desktop, antigravity, codex-app (Apple Silicon only), and `ollama-app` when `installAiDesktopApps` + `installLlmTools`
- **System Utilities**: aerospace, alt-tab, raycast, jordanbaird-ice
- **Communication**: discord, telegram, wechat, tencent-meeting
- **Browsers**: arc, google-chrome, tor-browser
- **Productivity**: obsidian, google-drive, grammarly-desktop
- **Gaming**: steam, minecraft, battle-net (skipped if WORK_MACHINE env var set)
- **Finance**: binance, tradingview
- **Network**: tailscale, openvpn-connect, clash-verge-rev
- **Mac App Store**: LINE, Keynote, Numbers, Pages

### Customizing Brewfile

The Brewfiles are chezmoi templates. Conditional sections:

- Gaming apps: skipped if `WORK_MACHINE` environment variable is set
- Chinese apps (baidunetdisk): only included if `useChineseMirror` is true
- mas apps: requires signing in to App Store.app first

## Customization

See [docs/ansible.md](docs/ansible.md) for detailed ansible customization guide.
