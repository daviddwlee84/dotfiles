# television (tv) Quick Reference

[television](https://github.com/alexpasmantier/television) — blazing-fast TUI fuzzy finder with pluggable "channels".

Config source: `dot_config/television/cable/sesh.toml`

---

## Basic Usage

```bash
tv                   # Open interactive picker (default channel)
tv <channel>         # Open a specific channel, e.g. tv sesh
tv --help            # List all flags
```

From tmux: `prefix + T` opens the sesh channel as a popup (see [Tmux Integration](#tmux-integration)).

---

## Custom Channels

### `tools` channel

Parses `~/.config/docs/tools/cli-tools.md` at runtime (deployed via chezmoi from `dot_config/docs/tools/`). The markdown file is the single source of truth — edit it to add or update tools.

Open with `tv tools` or `prefix + U` in tmux.

| Key | Action |
|-----|--------|
| `Enter` | Execute selected tool immediately |
| `Ctrl+/` | Toggle preview panel (tldr or `--help`) |

For pasting an invocation to the shell buffer (with trailing space for tools that need arguments), use the fzf ZLE widget instead: **Alt+T** in any zsh session.

---

### `sesh` channel

Overrides the built-in sesh channel with richer source cycling and session management.

**Source cycling keybindings** (shown in picker header):

| Key | Source | Description |
|-----|--------|-------------|
| `Ctrl+A` | All sessions | `sesh list --icons` |
| `Ctrl+T` | Tmux sessions | `sesh list -t --icons` |
| `Ctrl+G` | Configured sessions | `sesh list -c --icons` |
| `Ctrl+X` | Zoxide directories | `sesh list -z --icons` |
| `Ctrl+F` | File search | `fd -H -d 2 -t d -E .Trash ~` |

**Action keybindings:**

| Key | Action |
|-----|--------|
| `Enter` | Connect to selected session |
| `Ctrl+D` | Kill selected tmux session + refresh list |

**Preview:** `sesh preview '{selection}'` — right panel, 55% width.

---

## Tmux Integration

| Binding | Action |
|---------|--------|
| `prefix + T` | Open sesh channel as a television popup |
| `prefix + g` | Open sesh session picker via fzf (alternative) |

> For the full tmux session management keybinding reference, see `docs/tools/tmux/keybindings.md`.

---

## Tips

- `Tab` / `Shift+Tab` — navigate results
- `Ctrl+P` / `Ctrl+N` — move up/down (vim users)
- Channels are defined as `.toml` files in `~/.config/television/cable/`
- Custom channels in this repo live at `dot_config/television/cable/` (deployed via chezmoi)
