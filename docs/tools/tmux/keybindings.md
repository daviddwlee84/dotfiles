# tmux — Keybindings

All bindings use the default prefix `Ctrl + b`.

## Daily Workflow

| Keybinding | Action |
|------------|--------|
| `prefix + R` | Reload `~/.tmux.conf` |
| `prefix + Space` (or `prefix + e`) | Open the tmux popup menu (mnemonic: "menu"; both keys are bound to the same script) |
| `prefix + g` | Open sesh picker |
| `prefix + T` | Open sesh picker via television (tv) |
| `prefix + O` | Open sesh built-in picker |
| `prefix + W` | Open sesh window picker (fzf) |
| `prefix + S` | Jump to the last sesh session |
| `prefix + 9` | Jump to the git root session for the current repo |
| `prefix + N` | New session (prompts for name) |
| `prefix + X` | Kill session (with confirmation) |
| `prefix + M` | Move current window to another session (prompts for `session[:index]`) |
| `prefix + B` | Break current pane into a new window and move it to a session (tab tear-out) |
| `prefix + A` | Link current window into another session (window appears in both) |
| `prefix + d` | Detach |
| `prefix + t` | Show tmux clock mode |
| `prefix + M-c` | Switch theme to Catppuccin (top status bar) |
| `prefix + M-t` | Switch theme to tmux2k (bottom status bar) |

## Panes and Windows

| Keybinding | Action |
|------------|--------|
| `Ctrl + 1..9` | Switch to window 1–9 (requires CSI-u terminal: Ghostty, Alacritty, Kitty) |
| `Ctrl + 0` | Jump to git root session via sesh (same as `prefix + 9`) |
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

`Ctrl+1..9` and `Ctrl+0` require CSI-u terminal support. Ghostty/cmux sends these natively. Alacritty needs explicit `keyboard.bindings` (managed by this repo in `dot_config/alacritty/alacritty.toml`). Legacy terminals (Terminal.app, plain SSH) cannot send these — use `prefix + number` instead.

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

> **macOS terminal requirement**: Option must send Meta/Esc+ for `M-` bindings to work. Ghostty/cmux: `macos-option-as-alt = left` (managed by this repo in `dot_config/ghostty/config`). Alacritty: `window.option_as_alt: OnlyLeft`. iTerm2: Profiles > Keys > Left Option Key > Esc+. See [docs/tools/ghostty.md](../ghostty.md).

## Floating Pane (tmux-floax)

| Keybinding | Action |
|------------|--------|
| `prefix + F` | Toggle floating pane (80% width/height, **persistent** `float` session) |
| `prefix + P` | Open floax popup menu |
| `prefix + \`` | One-shot **popup shell** at current pane path (each invocation = fresh shell, exits on `exit`/Ctrl-D) |

Two flavours of popup shell, pick by use case:

- **`prefix + \``** — quick-and-forget. Run a `curl`, check `df -h`, eyeball a file, exit. Each open is a clean shell. No history across opens. Good for "I just need to type one command without leaving my pane layout".
- **`prefix + F` (floax)** — scratchpad. The `float` session persists, so when you re-toggle the popup, your previous shell history, environment, and even running processes are still there. Good for "I'm iterating on something and don't want to lose the context".

## One-shot Popups

These open `display-popup -E` at `#{pane_current_path}`; the popup closes when the inner command exits. Unlike floax, no session persists.

| Keybinding | Action |
|------------|--------|
| `prefix + G` | [`lazygit`](https://github.com/jesseduffield/lazygit) popup |
| `prefix + T` | sesh picker (television) |
| `prefix + O` | sesh built-in picker |
| `prefix + W` | sesh window picker (fzf) |
| `prefix + U` | CLI tools picker (`tv tools`) |
| `prefix + u` | URL picker (tmux-fzf-url) |

When to use which:

- **floax (`prefix + F`)** — repeated quick-access shell, want history preserved (notes, scratch math, long-running curl).
- **`prefix + \`` popup shell** — quick command in a fresh shell, exit and forget.
- **One-shot tool popup (`G`/...)** — start a TUI tool, do work, exit cleanly.

## Help / Discovery (no more memorizing)

The built-in `prefix + ?` (a wall-of-text `list-keys -N` dump) is replaced with [tmux-fzf](https://github.com/sainnhe/tmux-fzf): an fzf popup over **every** binding (including user-defined), fully fuzzy-searchable.

| Keybinding | Action |
|------------|--------|
| `prefix + ?` | tmux-fzf: top-level fuzzy picker (keybindings / sessions / windows / panes / commands / processes / clipboard) |
| `prefix + C-?` | Plain `list-keys -N` (fallback if tmux-fzf is missing) |
| `prefix + /` | Built-in: prompt for a key, show what it's bound to (single-key lookup) |
| `prefix + Space` / `prefix + e` then `?` | Curated cheatsheet rendered with [`glow`](https://github.com/charmbracelet/glow) (source: `dot_config/tmux/cheatsheet.md`) |
| `prefix + Space` / `prefix + e` then `/` | tmux-fzf **keybinding** picker directly (skips the category menu) |

Three layers of "I forgot the key" recovery:

1. **Curated** (`prefix + Space` / `prefix + e`): grouped popup menu with the high-traffic top-level rows + submenus.
2. **Searchable** (`prefix + ?` → tmux-fzf): fuzzy-search across the full binding list.
3. **Reference** (`prefix + Space` → `?`): glow-rendered markdown cheatsheet (this file's `cheatsheet.md` sibling), good for browsing while learning.

Why three? The popup menu is fastest once you know roughly what you want; tmux-fzf is for "I know it exists somewhere"; the cheatsheet is for "what's even possible?". Pick whichever matches your current uncertainty.

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

## Moving Windows Across Sessions

Like dragging a browser tab into a new window. The target prompt accepts:

- `session:` — append to next free index in `session`
- `session:N` — specific index in `session` (fails if taken; tmux's `-k` flag would overwrite, but our binds omit it for safety — rename or use a free index)
- `session:` where `session` doesn't yet exist — fails; create first with `prefix + N` or `tmux new -ds session`

| Key | Underlying command | Effect |
|-----|-------------------|--------|
| `prefix + M` | `move-window -t '%%'` | **Cut** current window out of this session and **paste** into target |
| `prefix + B` | `break-pane -t '%%'` | Pull current **pane** out as a new window in target session |
| `prefix + A` | `link-window -t '%%'` | **Link** (not copy): same window appears in both sessions; edits stay in sync. `unlink-window` removes one side without killing |

Tip: `prefix + s` (built-in choose-tree) shows live previews — handy for picking the destination session name before invoking `M`/`B`/`A`.

## Built-in tmux Keys Still Available

| Keybinding | Action |
|------------|--------|
| `prefix + s` | Choose session tree |
| `prefix + w` | Choose window tree |
| `prefix + q` | Show pane numbers |
| `prefix + ,` | Rename window |
| `prefix + $` | Rename session |
| `prefix + ?` | tmux-fzf: fuzzy-search all keybindings (rebound from list-keys) |
| `prefix + C-?` | Built-in `list-keys -N` (fallback) |
| `prefix + /` | Prompt for a key and show what it is bound to |

## Popup Menu (`prefix + Space` / `prefix + e`)

The popup menu is bound to **both** `prefix + Space` and `prefix + e` (alias) and is **generated by a script** (`~/.config/tmux/menu.sh`) rather than defined inline in `keybindings.conf`. Two reasons:

1. **Quoting**. tmux's command parser stops at literal `;`, `{`, `}` even inside nested quotes. With ~50 menu rows full of fzf binds and shell one-liners, escaping in `keybindings.conf` was fragile and broke silently.
2. **Height-aware trimming**. `display-menu` does **not** paginate. If the menu is taller than the terminal, the entire popup is suppressed with no error. The script reads `#{client_height}` and emits one of three tier sets so the menu always fits.

Tiers:

| Terminal height | Top menu shows |
|-----------------|----------------|
| Any (Tier 0)    | Last window/pane, Choose win/sess, Pane #s, Sesh picker, Lazygit (~9 rows) |
| ≥ 14 (Tier 0+2) | + submenu launchers (`→ Layouts/Session/Sesh+/Popups/Theme/System`), Cheatsheet, Search keys |
| ≥ 22 (Tier 0+1+2) | + New window, Split `\|`/`-`, Zoom |

Submenus are separate scripts (`menu-layouts.sh`, `menu-session.sh`, `menu-sesh.sh`, `menu-popups.sh`, `menu-theme.sh`, `menu-system.sh`), invoked from rows via `run-shell`. Each is an independent `display-menu` so quoting context resets.

> **Historical note**: an earlier debugging round assumed `prefix + Space` and `prefix + Enter` were broken because of `extended-keys` / `csi-u` keysym encoding (tmux/tmux#4571, #4147, #4959, #4984), and the menu was moved to `prefix + e` as a workaround. That diagnosis was wrong. The actual failure was that the inline 50-row flat menu was **taller than the terminal**, and tmux silently suppresses oversized menus per `man tmux` ("If the menu is too large to fit on the terminal, it is not displayed."). Both `Space` and `Enter` were always bindable; the keysym story was a red herring. Full debugging trail in [`pitfalls/tmux-display-menu-silent-fail.md`](../../../pitfalls/tmux-display-menu-silent-fail.md). The menu is now bound to **both** `Space` (canonical) and `e` (alias / mnemonic "menu").

### Top-menu accelerator keys

Accelerator keys match the standalone `prefix + key` bindings wherever possible — pressing `c` inside the menu does the same thing as `prefix + c` outside it.

| Key | Row | Tier |
|-----|-----|------|
| `Tab` | Last window | 0 |
| `P` | Last pane | 0 |
| `w` | Choose window tree | 0 |
| `s` | Choose session tree | 0 |
| `q` | Show pane numbers | 0 |
| `g` | Sesh picker | 0 |
| `G` | Lazygit popup | 0 |
| `c` | New window | 1 (h ≥ 22) |
| `\|` | Split left/right | 1 |
| `-` | Split top/bottom | 1 |
| `z` | Zoom toggle | 1 |
| `L` | → Layouts submenu | 2 (h ≥ 14) |
| `S` | → Session submenu | 2 |
| `E` | → Sesh+ submenu | 2 |
| `o` | → Popups submenu | 2 |
| `T` | → Theme submenu | 2 |
| `Y` | → System submenu | 2 |
| `?` | Glow cheatsheet popup | 2 |
| `/` | tmux-fzf keybinding picker | 2 |

### Submenu rows

Source of truth: `dot_config/tmux/executable_menu-*.sh`.

- **Layouts** (`L`): Even h/v (`1`/`2`), Main h/v (`3`/`4`), Tiled (`5`), Resize 75% (`+`), Pane h/j/k/l, Swap `{`/`}`.
- **Session** (`S`): Rename session/window (`$`/`,`), New session (`N`), Move window (`m`), Break pane (`r`), Link window (`K`), Kill pane/session/server (`x`/`X`/`Q`).
- **Sesh+** (`E`): TV picker (`V`), Built-in (`O`), Windows (`W`), Last sesh (`U`), Repo root (`9`), CLI Tools tv (`B`).
- **Popups** (`o`): Lazygit (`g`), Shell (`s`), Floax scratchpad (`f`).
- **Theme** (`T`): Catppuccin (`c`), tmux2k (`t`).
- **System** (`Y`): Reload config (`R`), Install plugins (`I`), Update plugins (`U`), Detach (`d`), Clock (`k`).

> **Hard cap**: the top menu is currently 14 rows at full height. Adding a 15th row will start failing on smaller terminals (mobile SSH, half-screen splits). Push lower-frequency items into a submenu instead, and re-test by shrinking the terminal vertically (heights 14 / 22 / 60).
