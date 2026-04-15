# tmux × Vim / Neovim

## Vi copy / scroll — already on

The current config sets `mode-keys vi`, so scroll and copy mode behave vim-style out of the box:

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

## Possible future add-on

[`christoomey/vim-tmux-navigator`](https://github.com/christoomey/vim-tmux-navigator) — prefix-less `Ctrl+h/j/k/l` navigation that seamlessly crosses tmux panes and Vim splits. Not installed; adopting it would replace the current `prefix + h/j/k/l` bindings.

## Resources

- [rothgar/awesome-tmux](https://github.com/rothgar/awesome-tmux) — curated list of tmux plugins, themes, and articles.
- [Tmux and Vim — even better together (SmartBear)](https://smartbear.com/blog/tmux-and-vim/) — workflow patterns for pairing tmux with Vim/Neovim.
- [omerxx/dotfiles — tmux/](https://github.com/omerxx/dotfiles/tree/master/tmux) — reference config with Catppuccin + top status bar (see [video walkthrough](https://www.youtube.com/watch?v=GH3kpsbbERo)).
