# television (tv) Quick Reference

[television](https://github.com/alexpasmantier/television) — blazing-fast TUI fuzzy finder with pluggable "channels".

Custom channels: `dot_config/television/cable/` (chezmoi-managed)

---

## Basic Usage

```bash
tv                   # Open interactive picker (default channel)
tv <channel>         # Open a specific channel, e.g. tv sesh
tv list-channels     # List all available channels
tv --help            # List all flags
```

From tmux: `prefix + T` opens the sesh channel as a popup (see [Tmux Integration](#tmux-integration)).

---

## Community Channels

tv has a built-in channel package manager. Run once after install (and periodically to update):

```bash
tv update-channels
```

This downloads [community-maintained channels](https://alexpasmantier.github.io/television/community/channels-unix) into `~/.config/television/cable/`. It:

- **Skips** channels whose requirements aren't met on your system (e.g. `apt-packages` on macOS)
- **Skips** channels that already exist (won't overwrite custom channels)
- Covers git, docker, k8s, brew, cargo, GitHub, sesh, tmux, and many more

Notable community channels: `sesh`, `git-branch`, `git-log`, `git-stash`, `git-diff`, `brew-packages`, `docker-containers`, `gh-issues`, `gh-prs`, `just-recipes`, `zoxide`, `zsh-history`, `env`, `dirs`, `files`, `text`.

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

### `sesh` channel (community)

Provided by `tv update-channels`. Source cycling through session types and directory search, with connect/kill actions.

**Source cycling** (use `Ctrl+S` to cycle):

| Source | Description |
|--------|-------------|
| All sessions | `sesh list --icons` (default) |
| Tmux sessions | `sesh list -t --icons` |
| Configured sessions | `sesh list -c --icons` |
| Zoxide directories | `sesh list -z --icons` |
| File search | `fd -H -d 2 -t d -E .Trash ~` |

**Action keybindings:**

| Key | Action |
|-----|--------|
| `Enter` | Connect to selected session |
| `Ctrl+D` | Kill selected tmux session + refresh list |

**Preview:** `sesh preview` — right panel.

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
- Run `tv update-channels` to get/update community channels
- Custom channels in this repo live at `dot_config/television/cable/` (deployed via chezmoi, won't be overwritten by `update-channels`)
- See [tv vs fzf](tv-vs-fzf.md) for comparison and channel best practices
