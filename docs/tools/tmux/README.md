# tmux

Managed tmux config lives under `~/.config/tmux/`, with a shim at `~/.tmux.conf` that sources the XDG entry point.

## Source layout (in this repo)

| Source | Deployed | Purpose |
|--------|----------|---------|
| [`dot_tmux.conf`](../../../dot_tmux.conf) | `~/.tmux.conf` | one-line shim |
| [`dot_config/tmux/tmux.conf`](../../../dot_config/tmux/tmux.conf) | `~/.config/tmux/tmux.conf` | entry point, picks theme |
| [`dot_config/tmux/common.conf`](../../../dot_config/tmux/common.conf) | — | plugins + theme-agnostic options |
| [`dot_config/tmux/keybindings.conf`](../../../dot_config/tmux/keybindings.conf) | — | all bind-keys and popup menu |
| [`dot_config/tmux/theme.catppuccin.conf`](../../../dot_config/tmux/theme.catppuccin.conf) | — | default theme (top status bar) |
| [`dot_config/tmux/theme.tmux2k.conf`](../../../dot_config/tmux/theme.tmux2k.conf) | — | alternative theme (bottom status bar) |

This setup is tuned for coding-agent and Neovim workflows:

- native popup menu on `prefix + Space`
- Catppuccin (default, top status bar) or tmux2k (bottom) — switchable at runtime
- vim-style pane navigation and copy mode
- URL opening via fzf (`prefix + u`) and tmux-open in copy mode
- capture pane to clipboard helpers
- sesh integration for session picking
- `extended-keys` with `csi-u` so keys like `Ctrl+/` reach Neovim inside tmux
- OSC 52 clipboard and OSC passthrough enabled
- macOS terminal must send Option as Meta for `M-` bindings — see [ghostty.md](../ghostty.md)

## In this folder

- [keybindings.md](./keybindings.md) — all keybindings and the popup menu
- [themes.md](./themes.md) — Catppuccin / tmux2k selection, switching, troubleshooting
- [vim.md](./vim.md) — tmux × Vim/Neovim notes and external resources

## First-time setup

After `chezmoi apply`, start tmux and run `prefix + I` once to let TPM install the plugins. The theme files also auto-clone their plugin on first source as a safety net, but TPM is the canonical installer.

## Reload Config

Most changes do not need a server restart.

```bash
tmux source-file ~/.tmux.conf
```

Or, inside tmux: `prefix + R` (shows a confirmation message after reloading).

If a change still behaves wrong, try a new pane/window first. Only `tmux kill-server` when a terminal-capability or plugin-init issue clearly survives a reload — e.g. switching themes without leftover styling.

## Exit vs Detach

- `prefix + d` — detach the current client, leaving the session running
- `exit` — close the current shell; when the last pane exits, the session ends
- `prefix + :` then `kill-session` — kill the current session immediately
- `tmux kill-server` — kill every session and stop the server

`detach-on-destroy off` is set, so when you kill a session tmux switches to another one instead of detaching if other sessions exist.

## Prefix Key

Default: `Ctrl + b`. Examples in the sibling docs assume `prefix = Ctrl + b`.

## Plugins

| Plugin | Purpose |
|--------|---------|
| `tmux-resurrect` | Save/restore sessions across tmux restarts |
| `tmux-continuum` | Automatic session saving |
| `tmux-floax` | Floating scratch pane (`prefix+F` toggle, `prefix+P` menu) |
| `tmux-fzf-url` | `prefix+u` opens fzf popup with all URLs in pane |
| `tmux-open` | In copy-mode: `o` opens selection, `C-o` in editor, `S` search |
| `catppuccin/tmux` | Status bar theme (mocha, top bar) — default |
| `tmux2k` | Status bar theme (onedark, bottom bar) — alternative |

Managed by TPM; `prefix + I` to install, `prefix + U` to update.

## Verify current config

```bash
ls ~/.config/tmux/
tmux display-message -p '#{@theme_variant}'
tmux list-keys -T prefix
tmux show-options -s | rg 'extended-keys|extended-keys-format|default-terminal'
tmux show-options -g | rg 'status|focus-events'
```

## Related Docs

- [Sesh](../sesh.md)
- [Starship](../starship.md)
- [XDG Base Directory](../xdg.md) — why configs live under `~/.config/tmux/` rather than `~/.tmux.conf`
