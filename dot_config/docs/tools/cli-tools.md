# CLI Tools Reference

All tools installed by this dotfiles project. The **Invocation** column is what gets pasted to the shell buffer by the `tools-picker` (Alt+T) and TV channel (`tv tools`). Tools with a trailing space need an argument before running.

> **Source of truth for the interactive pickers**: both `tv tools` and the fzf ZLE widget (Alt+T) parse this file at runtime.

---

## File & Search

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `rg` | `rg ` | Fast regex search (ripgrep) | `-l` files only, `-i` case-insensitive, `-t` by filetype |
| `fd` | `fd ` | Fast file finder | `-t f` files, `-t d` dirs, `-e ext` by extension |
| `bat` | `bat ` | cat with syntax highlighting | `--plain`, `--paging=never`, `-l` language |
| `eza` | `eza ` | Modern ls with git status | aliases: `ls`, `la`, `ll`, `lt`, `llt` |
| `fzf` | `fzf` | Interactive fuzzy finder | `Ctrl+T` files, `Ctrl+R` history, `Alt+C` cd |
| `yazi` | `yazi` | TUI file manager (cd on exit) | alias `y` for cd-on-exit wrapper |
| `glow` | `glow ` | Render Markdown in terminal | `glow -p` paged |
| `duckdb` | `duckdb ` | In-process SQL analytics | `.open file.db` to open, `.tables` to list |
| `rclone` | `rclone ` | Sync files to/from cloud storage | `rclone sync src dst` |

---

## Git & Diff

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `lazygit` | `lazygit` | Git TUI | alias `lg` |
| `gh` | `gh ` | GitHub CLI | `gh pr`, `gh issue`, `gh repo clone`, `gh run` |
| `delta` | `delta ` | Diff pager with syntax highlight | configured as default git pager |
| `diffnav` | `diffnav` | TUI diff navigator | `diffnav <file>` or pipe from `git diff` |
| `git-graph` | `git-graph` | Visual branch graph | `git-graph --all` |
| `gitleaks` | `gitleaks ` | Secret scanner | `gitleaks detect`, `gitleaks protect` |
| `pre-commit` | `pre-commit ` | Git hook manager | `pre-commit run --all-files`, `pre-commit install` |

---

## Sessions & Multiplexing

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `tmux` | `tmux` | Terminal multiplexer | prefix: `Ctrl+B` (this config), see tmux docs |
| `sesh` | `sesh ` | Tmux session manager | aliases: `shere` (here), `sroot` (git root) |
| `zellij` | `zellij` | Rust terminal multiplexer | `Ctrl+G` to unlock (default: locked mode) |
| `tmuxinator` | `tmuxinator ` | Tmux session templates | `tmuxinator start <name>` |

---

## Navigation & Shell

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `z` | `z ` | Smart cd with frecency (zoxide) | `zi` for interactive pick |
| `tv` | `tv ` | TUI fuzzy finder with channels | `tv sesh`, `tv files`, `tv tools` |
| `direnv` | `direnv ` | Per-directory env vars | `direnv allow` to enable `.envrc` |
| `thefuck` | `fuck` | Auto-correct last command | alias `fuck` |
| `tldr` | `tldr ` | Community-written man pages | `tldr --update` to refresh |
| `zoxide` | `zoxide ` | Frecency-based directory jumper | underlying engine for `z` |

---

## Process & System

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `btop` | `btop` | Resource monitor TUI (modern htop) | `F2` for settings |
| `htop` | `htop` | Classic interactive process viewer | `F9` kill, `F6` sort |
| `pueue` | `pueue ` | Parallel task queue | `pueue add -- cmd`, alias `pqsum` for summary |

---

## Dev Tools

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `jq` | `jq ` | JSON processor | `.` pretty-print, `.key` extract, `keys` list |
| `yq` | `yq ` | YAML/JSON/XML processor (Mike Farah Go build) | `yq .key file.yaml`, `-i` in-place edit, `-o=json` convert |
| `dasel` | `dasel ` | Unified YAML/TOML/XML/JSON/CSV query & modify | `dasel -f file.yaml '.key'`, `-r toml -w json` for cross-format conversion |
| `jnv` | `jnv ` | Interactive `jq` filter TUI on JSON | `cat data.json \| jnv` — live preview while typing |
| `just` | `just` | Command runner (Makefile alt) | bare `just` lists all recipes |
| `taplo` | `taplo ` | TOML formatter & linter | `taplo fmt`, `taplo check` |
| `tldr` | `tldr ` | Community man pages | `tldrf` for fzf interactive |
| `tree` | `tree ` | Directory tree view | `-L 2` depth, `-I pattern` ignore |
| `mise` | `mise ` | Runtime version manager | `mise use node@lts`, `mise ls` |

---

## Networking

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `doggo` | `doggo ` | Modern DNS lookup (DoH/DoT) | alias `dns`, e.g. `dns example.com A` |
| `http` | `http ` | Modern HTTP client (HTTPie) | `http GET url`, `http POST url key=val` |
| `gping` | `gping ` | Ping with live graph | `gping 8.8.8.8 1.1.1.1` for comparison |
| `trip` | `trip ` | TUI traceroute (trippy) | `sudo trip 8.8.8.8` for ICMP |
| `bw-net` | `bw-net` | Bandwidth monitor by process | alias for `sudo bandwhich` |
| `nmap` | `nmap ` | Port scanner | function `pingsweep` for /24 sweep |
| `portscan` | `portscan ` | Fast port scanner (rustscan) | alias for `rustscan` |
| `speedtest` | `speedtest` | Ookla internet speed test | `--format json` for JSON output |
| `mtr` | `mtr ` | Combined ping + traceroute | `mtr 8.8.8.8` |

---

## AI / Coding Agents

| Command | Invocation | Description | Notes |
|---------|------------|-------------|-------|
| `claude` | `claude` | Claude Code CLI | `claude --help` for flags |
| `opencode` | `opencode` | OpenCode AI assistant | — |
| `gemini` | `gemini` | Google Gemini CLI | — |
| `codex` | `codex` | OpenAI Codex CLI | — |
| `cursor` | `cursor ` | Cursor editor CLI | `cursor .` to open project |
| `ollama` | `ollama ` | Local LLM runner | `ollama run <model>`, `ollama list` |
| `litellm` | `litellm ` | LLM proxy server | `litellm --model <model>` |
