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

### `pueue` channel

Interactive task manager for [pueue](https://github.com/Nukesor/pueue) — fuzzy-search tasks, preview logs, and pause/resume/kill/restart without leaving the picker. Parses `pueue status --json` at runtime. Requires `pueue` and `jq`.

Open with `tv pueue`. Auto-refreshes every 2 seconds.

**Source cycling** (`Ctrl+S`):

| Source | Description |
|--------|-------------|
| All tasks | Every task, newest first (default) |
| Active only | Running + Queued + Paused tasks |
| Failed only | Tasks that exited non-zero |
| Groups overview | Pueue groups with status and parallelism |

**Task management** (all `Alt+key` to avoid conflicts with TV built-ins and tmux):

| Key | Action |
|-----|--------|
| `Enter` | Follow running task / view finished task log / show group status |
| `Alt+E` | Edit task command in `$EDITOR` (stashed/queued only) |
| `Alt+P` | Pause task |
| `Alt+R` | Resume/start task |
| `Alt+K` | Kill task |
| `Alt+T` | Restart task (in-place) |
| `Alt+X` | Remove task from list |
| `Alt+L` | Clean all finished tasks |

**Clipboard:**

| Key | Action |
|-----|--------|
| `Alt+Y` | Copy raw command to clipboard |
| `Alt+A` | Copy full `pueue add -w <path> -g <group> ...` command to clipboard |

`Alt+Y` copies just the original command string. `Alt+A` reconstructs a full reproducible `pueue add` invocation including working directory, group, label, priority, and dependencies — useful for re-queuing or sharing tasks.

**Group filtering:**

| Key | Action |
|-----|--------|
| `Enter` | On groups view: show `pueue status -g <name>` text overview |
| `Alt+G` | Open a filtered view showing only the selected task's group |

`Alt+G` extracts the group name from the selected entry and launches a new `tv` instance with `--source-command` filtered to that group. The filtered view has preview but not the full action keybindings. Quit to return to the main `tv pueue` channel. Enter on the groups source (cycle 4) shows a quick text overview via `pueue status -g`.

**Preview** (`Ctrl+F` cycles):

1. Task log output (`pueue log <id>`)
2. Full JSON task details (timing, dependencies, result — envs stripped for readability)

**Implementation notes:**

- All action keybindings use `Alt+` to avoid shadowing TV built-ins (`Ctrl+P`/`Ctrl+K` for navigation, `Ctrl+A`/`Ctrl+E` for input cursor, `Ctrl+R` for reload, etc.) and tmux root-table bindings (`C-h/j/k/l` for vim-tmux-navigator). Requires terminal to send Option as Meta (Ghostty: `macos-option-as-alt = left`).
- Uses jq's `@tsv` for output formatting — avoids TOML/shell escape conflicts with jq's `\(...)` interpolation syntax
- Clipboard actions are cross-platform: pbcopy (macOS), wl-copy (Wayland), xclip (X11)
- `pueue edit` only works on stashed/queued tasks (pueue limitation); for running/finished tasks use `Alt+Y` to copy and re-add manually

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

## Keybinding Conflicts with tmux

TV's default `ctrl-h/j/k/l` bindings conflict with tmux's `vim-tmux-navigator` root-table pane navigation (`C-h/j/k/l`). The managed config (`dot_config/television/config.toml`) resolves this:

| Default | Action | Remapped to | Notes |
|---------|--------|-------------|-------|
| `ctrl-j` | select_next_entry | _(removed)_ | Use `down` or `ctrl-n` |
| `ctrl-k` | select_prev_entry | _(removed)_ | Use `up` or `ctrl-p` |
| `ctrl-h` | toggle_help | `alt-h` | Mnemonic, no conflicts |
| `ctrl-l` | toggle_layout | `alt-l` | Overridden in pueue channel (clean) |

All other TV defaults (`ctrl-s`, `ctrl-f`, `ctrl-r`, `ctrl-y`, etc.) are kept since they don't conflict with tmux root-table bindings.

---

## Tips

- `Tab` / `Shift+Tab` — navigate results
- `Ctrl+P` / `Ctrl+N` — move up/down (vim users)
- `Alt+H` — toggle help panel (remapped from `ctrl-h` to avoid tmux conflict)
- Channels are defined as `.toml` files in `~/.config/television/cable/`
- Global config at `~/.config/television/config.toml` (chezmoi-managed from `dot_config/television/config.toml`)
- Run `tv update-channels` to get/update community channels
- Custom channels in this repo live at `dot_config/television/cable/` (deployed via chezmoi, won't be overwritten by `update-channels`)
- See [tv vs fzf](tv-vs-fzf.md) for comparison and channel best practices
