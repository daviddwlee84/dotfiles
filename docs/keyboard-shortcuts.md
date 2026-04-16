# Keyboard Shortcuts

Quick reference for all custom keybindings across tmux, zsh ZLE widgets, and fzf.

For deep dives: [tmux keybindings](tools/tmux/keybindings.md) · [tmux themes](tools/tmux/themes.md) · [fzf](tools/fzf.md) · [tv](tools/tv.md)

---

## tmux

Prefix key: `Ctrl+B`

### Panes & Windows

| Binding | Action |
|---------|--------|
| `Ctrl+1..9` | Switch to window 1–9 *(no prefix, requires CSI-u terminal)* |
| `Ctrl+0` | Jump to git root session via sesh *(no prefix, CSI-u)* |
| `Ctrl+h/j/k/l` | Move across panes **and** Neovim splits seamlessly |
| `prefix + h/j/k/l` | Navigate panes (vim-style fallback) |
| `prefix + H/J/K/L` | Resize pane (5 cells) |
| `prefix + M-h/j/k/l` | Fine-resize pane (1 cell) |
| `prefix + \|` | Split left/right |
| `prefix + -` | Split top/bottom |
| `prefix + +` | Set pane to 75% width |
| `prefix + z` | Zoom/unzoom pane |
| `prefix + x` | Kill pane |
| `prefix + c` | New window |
| `prefix + X` | Kill session (confirm) |
| `prefix + N` | New session (prompted) |

### Copy Mode  *(enter with `prefix + [`)*

| Key | Action |
|-----|--------|
| `v` / `V` | Begin char / line selection |
| `C-v` | Rectangle selection |
| `y` | Yank to clipboard |
| `/` / `?` | Search forward / backward |
| `g` / `G` | Jump to top / bottom |
| `C-u` / `C-d` | Half-page up / down |
| `q` | Exit copy mode |

### Clipboard Helpers

| Binding | Action |
|---------|--------|
| `prefix + y` | Copy visible pane to clipboard |
| `prefix + Y` | Copy full scrollback to clipboard |
| `prefix + C-y` | fzf line picker from scrollback |

### URL & Sessions

| Binding | Action |
|---------|--------|
| `prefix + u` | fzf URL picker (tmux-fzf-url) |
| `prefix + g` | Sesh session picker (fzf popup) |
| `prefix + T` | Sesh picker via tv (television popup) |
| `prefix + O` | Sesh built-in picker popup |
| `prefix + W` | Sesh window picker (fzf) |
| `prefix + S` | Switch to last session |
| `prefix + 9` | Jump to git root session |
| `prefix + U` | CLI tools picker (tv tools popup) |

### Themes & Config

| Binding | Action |
|---------|--------|
| `prefix + M-c` | Switch to Catppuccin theme (top status bar) |
| `prefix + M-t` | Switch to tmux2k theme (bottom status bar) |
| `prefix + R` | Reload tmux config |

### Popup Menu  *(`prefix + Space`)*

One-key access to all major operations. Accelerator letters match the standalone bindings above.

| Key | Action |
|-----|--------|
| `\|` / `-` | Split pane |
| `h/j/k/l` | Navigate panes |
| `z` | Zoom toggle |
| `c` | New window |
| `N` / `X` | New / kill session |
| `E/e/v/b/T` | Layout presets (even-h/v, main-v/h, tiled) |
| `g` / `V` / `O` | Sesh pickers (fzf / tv / built-in) |
| `W` / `S` / `9` | Sesh window / last / root |
| `B` | CLI tools picker (tv tools) |
| `C` / `M` | Theme: Catppuccin / tmux2k |
| `R` / `I` / `U` | Reload config / TPM install / TPM update |
| `?` | List all tmux keys |

> `Ctrl+Space` is intentionally unbound — reserved for input method switching.

---

## Zsh ZLE Widgets

Interactive pickers that open at the shell prompt without leaving the current line.

| Binding | Widget | Behavior |
|---------|--------|----------|
| `Alt+T` | `tools-picker` | CLI tools list; **Enter** pastes invocation to buffer, **Ctrl+E** executes |
| `Alt+S` | `sesh-sessions` | Sesh session switcher (same as `prefix + g` but in-shell) |
| `Alt+C` | fzf cd | Fuzzy `cd` into a directory (built-in fzf) |
| `Ctrl+T` | fzf file | Insert fuzzy-matched file path at cursor |
| `Ctrl+R` | fzf history | Fuzzy search shell history |

### Inside `tools-picker` (Alt+T)

| Key | Action |
|-----|--------|
| `Enter` | Paste invocation to buffer (safe — runs when you press Enter again) |
| `Ctrl+E` | Execute tool directly (for safe TUI tools: `btop`, `lazygit`, etc.) |
| `Ctrl+/` | Toggle preview (tldr or `--help`) |

### Inside `sesh-sessions` (Alt+S)

| Key | Action |
|-----|--------|
| `Ctrl+A/T/G/X/F` | Filter: all / tmux / configured / zoxide / find |
| `Ctrl+D` | Kill selected tmux session |

---

## tv (Television)

| Command | Binding | Action |
|---------|---------|--------|
| `tv tools` | `prefix + U` (tmux) | CLI tools picker; Enter executes, preview shows tldr |
| `tv sesh` | `prefix + T` (tmux) | Sesh session picker; Enter connects |

### Inside any tv picker

| Key | Action |
|-----|--------|
| `Tab` / `Shift+Tab` | Navigate results |
| `Ctrl+P` / `Ctrl+N` | Move up / down |
| `Ctrl+D` | Kill session *(sesh channel only)* |

---

## Zellij

Default mode is **locked** — all keys pass through to inner apps.

| Binding | Action |
|---------|--------|
| `Ctrl+G` | Unlock Zellij command mode |

> On first launch, select **"Unlock-First (non-colliding)"** preset to avoid conflicts with Neovim and coding agents.

---

## macOS Notes

- `M-` bindings (e.g. `M-c`, `M-t`, `Alt+T`) require your terminal to send **Option as Meta/Esc+**.
  - **Ghostty** / **cmux**: `macos-option-as-alt = left` (managed in `dot_config/ghostty/config`)
  - **iTerm2**: Preferences → Profiles → Keys → Left Option: `Esc+`
- `Ctrl+1..9` and `Ctrl+0` require **CSI-u** terminal support (Ghostty, cmux, Alacritty, Kitty).
