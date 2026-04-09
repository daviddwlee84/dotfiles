# tmux

Managed tmux config lives at `~/.tmux.conf` and is sourced from [`dot_tmux.conf`](../../dot_tmux.conf) in this repo.

This setup is tuned for coding-agent and Neovim workflows:

- native popup menu on `prefix + Space`
- `tmux2k` status line
- vim-style pane navigation
- sesh integration for session picking
- `extended-keys` enabled with `csi-u` so keys like `Ctrl+/` reach Neovim inside tmux
- OSC 52 clipboard and OSC passthrough enabled

## Reload Config

Most tmux changes do not require restarting the server.

Reload the config with either:

```bash
tmux source-file ~/.tmux.conf
```

Or inside tmux:

```text
prefix + R
```

`prefix + R` is the fastest day-to-day option and shows a confirmation message after reloading.

If a change still does not behave correctly, try opening a new pane or window first. Only restart the tmux server when a terminal capability or plugin initialization issue clearly survives a reload.

## Exit vs Detach

- `prefix + d`: detach the current client, leaving the session running
- `exit`: close the current shell; when the last pane exits, the session ends
- `prefix + :` then `kill-session`: kill the current session immediately
- `tmux kill-server`: kill every tmux session and stop the server

This config sets `detach-on-destroy off`, so if other sessions still exist, tmux stays open and switches to one of them after you kill the current session.

## Prefix Key

The prefix remains tmux's default:

```text
Ctrl + b
```

Examples below assume `prefix = Ctrl + b`.

## Common Keybindings

### Daily Workflow

| Keybinding | Action |
|------------|--------|
| `prefix + R` | Reload `~/.tmux.conf` |
| `prefix + Space` | Open the tmux popup menu |
| `prefix + g` | Open sesh picker |
| `prefix + S` | Jump to the last sesh session |
| `prefix + 9` | Jump to the git root session for the current repo |
| `prefix + d` | Detach |
| `prefix + t` | Show tmux clock mode |

### Panes and Windows

| Keybinding | Action |
|------------|--------|
| `prefix + h/j/k/l` | Move between panes |
| `prefix + H/J/K/L` | Resize panes |
| `prefix + \|` | Split vertically |
| `prefix + -` | Split horizontally |
| `prefix + c` | New window in current path |
| `prefix + x` | Kill pane |
| `prefix + z` | Toggle pane zoom |
| `prefix + [` | Enter copy mode |

### Built-in Useful tmux Keys Still Available

| Keybinding | Action |
|------------|--------|
| `prefix + s` | Choose session tree |
| `prefix + w` | Choose window tree |
| `prefix + q` | Show pane numbers |
| `prefix + ,` | Rename window |
| `prefix + $` | Rename session |
| `prefix + ?` | List named keybindings |
| `prefix + /` | Prompt for a key and show what it is bound to |

## Popup Menu

Open the popup with:

```text
prefix + Space
```

Useful entries in the popup:

- `w`: choose window
- `p`: choose pane
- `s`: choose session
- `R`: reload config
- `D`: detach
- `?`: list keys
- `g`: open sesh picker
- `S`: jump to last sesh session
- `9`: jump to the git root session

## Coding-Agent / Neovim Notes

- `escape-time 0` removes the ESC delay, which helps Neovim feel responsive.
- `extended-keys always` with `extended-keys-format csi-u` is what allows `Ctrl+/` and similar modified punctuation keys to pass through tmux more reliably.
- The managed Alacritty config also sends `Ctrl+/` as `\u001f`, which matches LazyVim's built-in `<C-_>` fallback for terminal toggle.
- `set-clipboard on` enables OSC 52 clipboard copy over SSH.
- `allow-passthrough on` helps terminal image protocols and similar passthrough features.

If `Ctrl+/` still does not work after `prefix + R`, restart the current terminal app or fully restart tmux once to make sure the terminal capability negotiation is fresh.

## Verify Current Config

```bash
tmux list-keys -T prefix
tmux show-options -s | rg 'extended-keys|extended-keys-format|default-terminal'
tmux show-options -g | rg 'status|focus-events'
```

## Related Docs

- [Sesh](./sesh.md)
- [Starship](./starship.md)
