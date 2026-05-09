# tmux × Vim / Neovim

> **Note**: Everything on this page is gated by the chezmoi `enableVimMode`
> prompt (default `true`). When `false`: `mode-keys vi` becomes
> `mode-keys emacs`, the `copy-mode-vi` table swaps to `copy-mode`, and
> the vim-tmux-navigator block (`Ctrl+h/j/k/l`) is omitted entirely.
> See [`docs/this_repo/vim-mode.md`](../../this_repo/vim-mode.md) for
> the full catalog. Neovim is unaffected.

## Vi copy / scroll — already on (when `enableVimMode = true`)

The default config sets `mode-keys vi`, so scroll and copy mode behave vim-style out of the box:

| Key | Action |
|-----|--------|
| `prefix + [` | Enter copy mode |
| `h/j/k/l` | Move cursor |
| `C-u` / `C-d` | Half-page up/down |
| `g` / `G` | Top / bottom |
| `/` / `?` | Search forward / backward |
| `v` / `V` / `C-v` | Char / line / rectangle selection |
| `y` | Yank to system clipboard (OSC 52) |
| `q` or `Escape` | Exit |

See [keybindings.md → Copy Mode](./keybindings.md#copy-mode-vim-style) for the full table.

## Neovim-friendly settings already in `common.conf`

- `escape-time 0` — no ESC delay, Neovim feels responsive.
- `focus-events on` — Vim's `autoread` and Neovim's `FocusGained` / `FocusLost` fire correctly.
- `default-terminal tmux-256color` + `terminal-features ...:RGB` — true color inside tmux.
- `extended-keys always` + `extended-keys-format csi-u` — `Ctrl+/`, `Shift+Enter`, `Ctrl+Enter` etc. reach Neovim through tmux.
- `set-clipboard on` — OSC 52 yanks from copy mode work over SSH.
- `allow-passthrough on` — helps terminal image protocols and similar passthrough features.

If `Ctrl+/` still does not work after `prefix + R`, restart the terminal app or `tmux kill-server` once so terminal capability negotiation is fresh. The managed Alacritty config sends `Ctrl+/` as `\u001f`, which matches LazyVim's built-in `<C-_>` fallback for terminal toggle.

## vim-tmux-navigator

[`christoomey/vim-tmux-navigator`](https://github.com/christoomey/vim-tmux-navigator) is installed. Prefix-less `Ctrl+h/j/k/l` moves between panes, transparently crossing tmux pane boundaries and Neovim splits:

| Key | Action |
|-----|--------|
| `Ctrl+h` | Focus left (tmux pane or vim split) |
| `Ctrl+j` | Focus down |
| `Ctrl+k` | Focus up |
| `Ctrl+l` | Focus right |
| `Ctrl+\` | Focus previous (last-visited) |

The Neovim spec lives at [`dot_config/nvim/lua/exact_plugins/vim-tmux-navigator.lua`](../../../dot_config/nvim/lua/exact_plugins/vim-tmux-navigator.lua); the matching tmux-side `is_vim` bindings live in [`dot_config/tmux/keybindings.conf`](../../../dot_config/tmux/keybindings.conf). The existing `prefix + h/j/k/l` bindings are kept as a fallback — nothing is removed.

### Caveats

- `Ctrl+h` is historically Backspace in some terminals. If `<BS>` misbehaves in Neovim after this, remap `<C-h>` inside Neovim insert mode or update your terminal's keyboard protocol to csi-u (already enabled in our tmux config via `extended-keys-format csi-u`).
- `Ctrl+\` may clash with other apps (e.g. some debuggers use it as a signal). Avoid pressing it inside those apps.
- If you run a nested tmux session, the outer tmux eats the Ctrl+h/j/k/l and they don't reach Neovim. Use `prefix + h/j/k/l` inside nested sessions.

## Resources

- [rothgar/awesome-tmux](https://github.com/rothgar/awesome-tmux) — curated list of tmux plugins, themes, and articles.
- [Tmux and Vim — even better together (SmartBear)](https://smartbear.com/blog/tmux-and-vim/) — workflow patterns for pairing tmux with Vim/Neovim.
- [omerxx/dotfiles — tmux/](https://github.com/omerxx/dotfiles/tree/master/tmux) — reference config with Catppuccin + top status bar (see [video walkthrough](https://www.youtube.com/watch?v=GH3kpsbbERo)).
