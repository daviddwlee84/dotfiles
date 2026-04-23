# tmux Cheatsheet

> **Prefix** = `Ctrl + b` · Press inside tmux: `prefix + Enter` for menu, `prefix + ?` for fuzzy key search.

## Most-Used (memorize these first)

| Key | Action |
|-----|--------|
| `prefix + Enter` | Popup menu (everything below, navigable) |
| `prefix + ?` | **fzf** picker over ALL keybindings (tmux-fzf) |
| `prefix + /` | Prompt for a key, show what it's bound to |
| `prefix + d` | Detach |
| `prefix + R` | Reload config |
| `prefix + g` | Sesh session picker (fzf) |
| `prefix + S` | Last sesh session |
| `prefix + 9` | Sesh: jump to git-root session for cwd |

## Popups (floating windows)

| Key | Action |
|-----|--------|
| `prefix + F` | **Floax** floating scratchpad (toggle, persistent `float` session, history kept) |
| `prefix + P` | Floax menu |
| `prefix + \`` | One-shot popup shell (fresh shell each open, exits on `exit`/Ctrl-D) |
| `prefix + G` | Lazygit popup @ pane path |
| `prefix + T` | Sesh picker via television |
| `prefix + O` | Sesh built-in picker |
| `prefix + W` | Sesh window picker |
| `prefix + U` | CLI tools picker (tv tools) |
| `prefix + u` | URL picker (tmux-fzf-url) |

## Panes

| Key | Action |
|-----|--------|
| `Ctrl + h/j/k/l` | Move pane (also crosses into Vim splits) |
| `prefix + h/j/k/l` | Move pane (no-CSI-u fallback) |
| `prefix + H/J/K/L` | Resize 5 cells (repeatable) |
| `prefix + M-h/j/k/l` | Resize 1 cell (repeatable) |
| `prefix + \|` `prefix + -` | Split L/R · T/B |
| `prefix + z` | Toggle zoom |
| `prefix + +` | Set pane to 75% width |
| `prefix + {` `prefix + }` | Swap pane left-up · right-down |
| `prefix + x` | Kill pane (confirm) |
| `prefix + ;` | Last pane |
| `prefix + q` | Show pane numbers |

## Windows

| Key | Action |
|-----|--------|
| `Ctrl + 1..9` | Switch to window 1..9 (CSI-u terminal req'd) |
| `Ctrl + 0` | Sesh git-root |
| `prefix + 1..9` | Switch to window N |
| `prefix + c` | New window @ current path |
| `prefix + ,` | Rename window |
| `prefix + w` | Choose window tree |
| `prefix + n` `prefix + p` | Next · previous window |

## Sessions

| Key | Action |
|-----|--------|
| `prefix + s` | Choose session tree |
| `prefix + N` | New session (prompts for name) |
| `prefix + $` | Rename session |
| `prefix + X` | Kill session (confirm) |
| `prefix + M` | **Move** window to another session |
| `prefix + B` | **Break** pane into a window in another session |
| `prefix + A` | **Link** window into another session (lives in both) |

## Layouts

| Key | Action |
|-----|--------|
| `M-1` | Even horizontal |
| `M-2` | Even vertical |
| `M-3` | Main horizontal |
| `M-4` | Main vertical |
| `M-5` | Tiled |
| `prefix + E` | Spread evenly (built-in) |

> macOS: requires Option-as-Meta (Ghostty/cmux: `macos-option-as-alt = left`).

## Themes

| Key | Action |
|-----|--------|
| `prefix + M-c` | Catppuccin (top bar) |
| `prefix + M-t` | tmux2k (bottom bar) |

## Copy mode (`prefix + [`)

| Key | Action |
|-----|--------|
| `v` `V` `C-v` | Char · line · block selection |
| `y` | Yank to clipboard (works over SSH via OSC 52) |
| `/` `?` `n` `N` | Search forward · back · next · prev |
| `g` `G` `C-u` `C-d` | Top · bottom · half-page up/down |
| `o` (after select) | Open URL/file in browser/app |
| `C-o` | Open selection in `$EDITOR` |
| `S` | Google search selection |
| `q` `Esc` | Exit copy mode |

## Capture pane → clipboard

| Key | Action |
|-----|--------|
| `prefix + y` | Visible pane → clipboard |
| `prefix + Y` | Full scrollback → clipboard |
| `prefix + C-y` | fzf-pick lines from scrollback → clipboard |

## Help / Discovery

| Key | Action |
|-----|--------|
| `prefix + ?` | tmux-fzf: search all keybindings |
| `prefix + C-?` | Plain `list-keys -N` (fallback) |
| `prefix + /` | Prompt for a key, show its binding |
| `prefix + Enter` then `?` | Open this cheatsheet (glow) |
| `prefix + Enter` then `/` | Same as `prefix + ?` (tmux-fzf) |

## Right-click menus

Right-click a pane / window-list / session-area for context menu (kept open via `display-menu -O`).

---

Source: `dot_config/tmux/cheatsheet.md` (managed by chezmoi). Full docs: `docs/tools/tmux/`.
