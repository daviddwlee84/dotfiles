# Zsh Keybindings Cheatsheet (data source)

This file is the **data source** for the `keys-picker` ZLE widget (`Alt+/`)
and the `tv keybindings` television channel and the `bindings` shell function.

> **Format contract** — every row used by the picker MUST be:
>
> ```
> | `<KEY>` | `<widget-or-action>` | <human description> |
> ```
>
> exactly three pipe-delimited columns, key wrapped in backticks. The picker
> parses with `awk -F'|'`; deviating from this format will silently drop the
> row. Group headings (`### …`) are ignored by the parser.

> **Maintenance rule** (mirrored in `AGENTS.md`): whenever you add, modify,
> or remove a custom zsh ZLE widget binding in `dot_config/zsh/tools/*.zsh`,
> update this file. Built-in / plugin rows are curated, not exhaustive — keep
> the list to ~50 entries focused on what's frequently forgotten.

---

### Movement (ZLE built-in)

| Key | Widget | Description |
|-----|--------|-------------|
| `Ctrl+A` | `beginning-of-line` | Jump to start of line |
| `Ctrl+E` | `end-of-line` | Jump to end of line |
| `Ctrl+B` | `backward-char` | Move cursor left one char |
| `Ctrl+F` | `forward-char` | Move cursor right one char |
| `Alt+B` | `backward-word` | Jump back one word |
| `Alt+F` | `forward-word` | Jump forward one word |
| `Alt+.` | `insert-last-word` | Insert last argument of previous command |

### Editing (ZLE built-in)

| Key | Widget | Description |
|-----|--------|-------------|
| `Ctrl+W` | `backward-kill-word` | Delete word before cursor |
| `Ctrl+U` | `backward-kill-line` | Delete from cursor to start of line |
| `Ctrl+K` | `kill-line` | Delete from cursor to end of line |
| `Ctrl+Y` | `yank` | Paste from kill-ring |
| `Ctrl+D` | `delete-char-or-list` | Delete char (or send EOF if buffer empty) |
| `Ctrl+T` | `transpose-chars` | Swap two chars around cursor (overridden by fzf below) |
| `Ctrl+_` | `undo` | Undo last edit |
| `Ctrl+X Ctrl+E` | `edit-command-line` | Edit current command in $EDITOR |
| `Ctrl+L` | `clear-screen` | Clear screen (keeps current command) |

### History

| Key | Widget | Description |
|-----|--------|-------------|
| `Ctrl+R` | `fzf-history-widget` | fzf fuzzy history search (overrides ZLE built-in) |
| `Ctrl+P` | `up-line-or-history` | Previous history entry |
| `Ctrl+N` | `down-line-or-history` | Next history entry |
| `Alt+R` | `tv-history` | Television-style history search (custom) |

### File / directory pickers

| Key | Widget | Description |
|-----|--------|-------------|
| `Ctrl+T` | `fzf-file-widget` | fzf file picker (overrides transpose-chars) |
| `Alt+C` | `fzf-cd-widget` | fzf directory picker (cd into selection) |
| `Alt+P` | `tv-files` | Television file picker (custom) |

### AI / suggestions

| Key | Widget | Description |
|-----|--------|-------------|
| `Tab` | `_aisuggest_accept_tab` | Accept full AI suggestion when ghost shown (dynamic swap) |
| `→` | `_aisuggest_accept_right` | Same as Tab when ghost shown; Tab/Right swap-bind |
| `Alt+;` | `aisuggest` | Trigger AI command suggestion (configurable via $AISUGGEST_KEY) |
| `End` | `autosuggest-accept` | Accept zsh-autosuggestions ghost (whole line) |

### Custom pickers (this repo)

| Key | Widget | Description |
|-----|--------|-------------|
| `Alt+T` | `tools-picker` | CLI tools picker (reads ~/.config/docs/tools/cli-tools.md) |
| `Alt+S` | `sesh-sessions` | sesh session switcher |
| `Alt+G` | `tv-gitlog` | Television git-log browser |
| `Alt+E` | `tv-env` | Television env-vars search |
| `Alt+A` | `tv-aliases` | Television aliases & functions search |
| `Alt+I` | `tv-gitops` | Television git-ops insert (VSCode/GitLens menu) |
| `Alt+/` | `keys-picker` | This cheatsheet (you are here) |
