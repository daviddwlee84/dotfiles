# XDG Base Directory Specification

Most configs in this repo live under `~/.config/`, `~/.local/share/`, `~/.local/state/`, or `~/.cache/` rather than dot-files in `$HOME`. That layout follows the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/latest/).

## Core environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `XDG_CONFIG_HOME` | `~/.config` | Per-user config files |
| `XDG_DATA_HOME` | `~/.local/share` | Per-user application data |
| `XDG_STATE_HOME` | `~/.local/state` | Per-user state (logs, history, undo) |
| `XDG_CACHE_HOME` | `~/.cache` | Per-user non-essential cached data |
| `XDG_RUNTIME_DIR` | (set by login) | Per-session runtime files (sockets, etc.) |

## Why it matters

- **Clean `$HOME`**: the old "every app dumps a `~/.foo` dotfile" pattern gets noisy fast.
- **Predictable tooling**: backup, sync, dotfile managers (like chezmoi) all benefit from one well-known tree.
- **Easy to nuke**: wipe `~/.cache/foo` without touching configs; wipe `~/.local/state/foo` without losing settings.

## Tool-by-tool status (in this repo)

| Tool | XDG-native? | Where we put it |
|------|-------------|------------------|
| tmux | Yes (3.1+) | `~/.config/tmux/tmux.conf` (+ shim at `~/.tmux.conf`) |
| Neovim | Yes | `~/.config/nvim/` |
| Zellij | Yes | `~/.config/zellij/` |
| Starship | Yes | `~/.config/starship.toml` |
| Alacritty | Yes | `~/.config/alacritty/` |
| Ghostty | Yes | `~/.config/ghostty/` |
| Yazi | Yes | `~/.config/yazi/` |
| bat | Yes | `~/.config/bat/` |
| direnv | Yes | `~/.config/direnv/` |
| gh | Yes | `~/.config/gh/` |
| gh-dash | Yes | `~/.config/gh-dash/` |
| LazyGit | Yes | `~/.config/lazygit/` |
| Sesh | Yes | `~/.config/sesh/` |
| uv | Yes | `~/.config/uv/` |
| Bun | Yes | `~/.config/.bunfig.toml` |
| Homebrew Bundle | N/A | `~/.config/homebrew/` (our convention) |
| Claude Code | No | `~/.claude/` |
| SSH | No | `~/.ssh/` (spec doesn't cover it) |
| Git | Partial | `~/.gitconfig` (repo also uses `~/.config/git/hooks/`) |
| npm | Yes | `~/.npmrc` (via `$HOME`; XDG support exists but most tooling still writes `~/.npmrc`) |
| Cargo | Partial | `~/.cargo/config.toml` (respects `CARGO_HOME`, not XDG directly) |

Tools marked "No" or "Partial" keep legacy `$HOME` paths because upstream hasn't migrated or because the tool predates the spec; we follow whatever the tool actually reads.

## How this repo handles it

- chezmoi source paths like `dot_config/<tool>/...` map to `~/.config/<tool>/...` on apply. That is the primary way we opt into XDG.
- Legacy paths (e.g. `~/.tmux.conf`, `~/.gitconfig`) are kept as shims or top-level files when a tool expects them, often sourcing the real XDG-located config.
- For state/data/cache: we rarely commit those — they're generated at runtime and deliberately excluded from the repo.

## Further reading

- [freedesktop.org spec](https://specifications.freedesktop.org/basedir/latest/)
- [Arch Wiki — XDG Base Directory](https://wiki.archlinux.org/title/XDG_Base_Directory) — an up-to-date catalog of which tools honor the spec natively and which need workarounds.
