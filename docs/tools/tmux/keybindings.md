# tmux — Keybindings

All bindings use the default prefix `Ctrl + b`.

## Daily Workflow

| Keybinding | Action |
|------------|--------|
| `prefix + R` | Reload `~/.tmux.conf` |
| `prefix + Space` | Open the tmux popup menu |
| `prefix + g` | Open sesh picker |
| `prefix + S` | Jump to the last sesh session |
| `prefix + 9` | Jump to the git root session for the current repo |
| `prefix + N` | New session (prompts for name) |
| `prefix + X` | Kill session (with confirmation) |
| `prefix + d` | Detach |
| `prefix + t` | Show tmux clock mode |
| `prefix + C` | Switch theme to Catppuccin (top status bar) |
| `prefix + T` | Switch theme to tmux2k (bottom status bar) |

## Panes and Windows

| Keybinding | Action |
|------------|--------|
| `Ctrl + h/j/k/l` | Move between panes — crosses into Neovim splits (vim-tmux-navigator) |
| `Ctrl + \` | Focus previous pane/split (vim-tmux-navigator) |
| `prefix + h/j/k/l` | Move between panes (fallback, tmux-only) |
| `prefix + H/J/K/L` | Resize panes (5 cells, repeatable) |
| `prefix + M-h/j/k/l` | Fine resize panes (1 cell, repeatable) |
| `prefix + +` | Set current pane to 75% width |
| `prefix + \|` | Split left/right (vertical divider) |
| `prefix + -` | Split top/bottom (horizontal divider) |
| `prefix + c` | New window in current path |
| `prefix + x` | Kill pane |
| `prefix + z` | Toggle pane zoom |
| `prefix + {` | Swap pane with previous (left/up) |
| `prefix + }` | Swap pane with next (right/down) |
| `prefix + [` | Enter copy mode |

Swap-pane swaps the **content** while keeping the **sizes**. So if you have a 75%/25% split and swap, the left pane's content moves to the right (25%) and vice versa — the proportions stay fixed.

## Layouts

| Keybinding | Action |
|------------|--------|
| `M-1` | Even horizontal layout |
| `M-2` | Even vertical layout |
| `M-3` | Main horizontal layout |
| `M-4` | Main vertical layout |
| `M-5` | Tiled layout |
| `prefix + E` | Spread panes evenly (built-in) |

`M-1` through `M-5` are tmux built-ins — no prefix needed; just hold Meta (Alt/Option) and press the number.

## Floating Pane (tmux-floax)

| Keybinding | Action |
|------------|--------|
| `prefix + F` | Toggle floating pane (80% width/height) |
| `prefix + P` | Open floax popup menu |

The floating pane uses a dedicated tmux session named `float` (hidden from sesh picker via blacklist). It inherits the current pane path. Useful for quick terminal tasks without disrupting your layout.

## Copy Mode (Vim-Style)

Enter with `prefix + [`. Navigate with vim keys, then:

| Key | Action |
|-----|--------|
| `v` | Begin character selection (visual mode) |
| `V` | Select entire line |
| `C-v` | Toggle rectangle/block selection |
| `y` | Yank selection to system clipboard |
| `/` | Search forward |
| `?` | Search backward |
| `n`/`N` | Next/previous search match |
| `g`/`G` | Jump to top/bottom |
| `C-u`/`C-d` | Half-page up/down |
| `q` or `Escape` | Exit copy mode |

Mouse drag in copy mode also copies to clipboard. Double-click selects a word.

## Right-click menus

Right-click opens a context menu depending on where you click:

| Target | Menu |
|--------|------|
| Pane body (`MouseDown3Pane`) | Split / swap / zoom / kill / respawn |
| Window list (`MouseDown3Status`) | Swap / rename / kill / new window |
| Session area on the left (`MouseDown3StatusLeft`) | Next/prev/rename session, new session/window |

Our bindings use `display-menu -O` so the menu stays open after the mouse button is released — pick an item or press Escape to dismiss. (tmux's defaults omit `-O` and dismiss on release, which makes the menu unusable.)

## URL Opening

| Keybinding | Action |
|------------|--------|
| `prefix + u` | Open fzf popup listing all URLs in the pane (tmux-fzf-url) |

In copy-mode (after selecting text with `v`):

| Key | Action |
|-----|--------|
| `o` | Open selected URL/file in default browser/app (tmux-open) |
| `C-o` | Open selection in `$EDITOR` |
| `S` | Search selection in Google (tmux-open, configurable via `@open-S`) |

Typical workflow: `prefix + u` for quick URL browsing; `prefix + [` then select + `o` for precise URL opening.

## Capture Pane

| Keybinding | Action |
|------------|--------|
| `prefix + y` | Copy visible pane content to system clipboard |
| `prefix + Y` | Copy full scrollback to system clipboard |
| `prefix + C-y` | Open scrollback in fzf, select lines to copy (Tab=multi) |

Cross-platform: `pbcopy` on macOS, `xclip`/`xsel` on Linux. OSC 52 also works for the vim-style `y` yank (even over SSH).

## Built-in tmux Keys Still Available

| Keybinding | Action |
|------------|--------|
| `prefix + s` | Choose session tree |
| `prefix + w` | Choose window tree |
| `prefix + q` | Show pane numbers |
| `prefix + ,` | Rename window |
| `prefix + $` | Rename session |
| `prefix + ?` | List named keybindings |
| `prefix + /` | Prompt for a key and show what it is bound to |

## Popup Menu (`prefix + Space`)

Menu accelerator keys match the standalone `prefix + key` bindings wherever possible — pressing `R` inside the menu does the same thing as `prefix + R` outside it. Items marked "menu-only" have no standalone binding.

| Key | Action | Also works as `prefix + key`? |
|-----|--------|-------------------------------|
| `;` | Last pane | yes (built-in) |
| `w` | Choose window | yes (built-in) |
| `s` | Choose session | yes (built-in) |
| `q` | Show pane numbers | yes (built-in) |
| `c` | New window | yes |
| `\|` | Split left/right | yes |
| `-` | Split top/bottom | yes |
| `h/j/k/l` | Navigate panes | yes |
| `z` | Zoom toggle | yes (built-in) |
| `{` / `}` | Swap pane left-up / right-down | yes (built-in) |
| `E/e/v/b/T` | Layout presets | menu-only (use `M-1`..`M-5`) |
| `+` | Resize pane to 75% width | yes |
| `$` | Rename session | yes (built-in) |
| `,` | Rename window | yes (built-in) |
| `N` | New session | yes |
| `x` | Kill pane (confirm) | yes |
| `X` | Kill session (confirm) | yes |
| `Q` | Kill all sessions / server | menu-only |
| `C` | Theme: Catppuccin (top bar) | yes |
| `M` | Theme: tmux2k (bottom bar) | yes (bound to `prefix + T`) |
| `g` | Sesh picker | yes |
| `S` | Last sesh session | yes |
| `9` | Sesh git root | yes |
| `R` | Reload config | yes |
| `I` | Install plugins (TPM) | yes (TPM built-in) |
| `U` | Update plugins (TPM) | yes (TPM built-in) |
| `d` | Detach | yes (built-in) |
| `t` | Clock | yes (built-in) |
| `?` | List keys | yes (built-in) |
