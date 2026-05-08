# Zsh Keybindings & the `keys-picker` Widget

> **TL;DR** — press `Alt+/` in any zsh prompt to fuzzy-search every
> non-trivial keybinding (built-in, plugin, custom) with descriptions.
> Bash users (or scripts) can run `bindings` for the same data via `tv` /
> `bat` / `cat`. Source-of-truth markdown:
> [`dot_config/docs/shells/keybindings.md`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/docs/shells/keybindings.md)
> (deployed to `~/.config/docs/shells/keybindings.md`).

For the **why** behind `Ctrl+A` / `Ctrl+E` / `Ctrl+W` / `Alt+.` etc. and
why every Unix shell shares them, see
[Emacs-style line editing — origin & the must-know subset](emacs-line-editing.md).

---

## Why this exists

Zsh has no real `which-key` equivalent — that pattern needs a "leader key
+ timeout" mechanism (Vim's `<leader>`, tmux's `prefix`), and ZLE parses
keys eagerly, so a custom `Alt` keypress can never be made to "wait for
follow-up input". The pragmatic substitute is **a fzf picker that lists
every binding**, opened by a single hotkey.

Three forgetfulness traps motivate it:

1. **Custom `Alt+*` widgets in this repo** (`Alt+T` tools-picker,
   `Alt+S` sesh, `Alt+R` atuin, `Alt+P/G/E/A/I` television channels,
   `Alt+;` aisuggest, `Alt+/` keys-picker)
   — the namespace is dense; new widgets are forgotten within days.
2. **Plugin overrides** that shadow ZLE built-ins — e.g. `Ctrl+R` is no
   longer `history-incremental-search-backward`; on zsh it's
   `fzf-history-widget`, on bash it's atuin's TUI (asymmetric on purpose
   — see [atuin docs](../tools/atuin.md#keybindings-cross-shell-asymmetry--read-this)).
3. **Built-in editing shortcuts you rarely need until you do** —
   `Ctrl+X Ctrl+E` (open command in `$EDITOR`), `Alt+.` (insert last
   argument of previous command), `Ctrl+_` (undo).

## Four layers of binding

The cheatsheet is curated, not exhaustive — built-in / plugin rows are
selected for "frequently forgotten" rather than "every widget exists".

| # | Layer | Source | Examples in cheatsheet |
|---|-------|--------|------------------------|
| 1 | **ZLE built-in** (emacs keymap) | Ships with zsh | `Ctrl+A`, `Ctrl+E`, `Ctrl+W`, `Alt+.`, `Ctrl+X Ctrl+E` |
| 2 | **OMZ / third-party plugins** | `dot_zshrc.tmpl:21-26` (`zsh-autosuggestions`, `zsh-syntax-highlighting`, `zsh-vi-mode`) + fzf shell integration | `Ctrl+R` → fzf, `Ctrl+T` → fzf, `Alt+C` → fzf, `End` → autosuggest-accept |
| 3 | **Custom widgets in this repo** | `dot_config/zsh/tools/{05_aisuggest,11_tools_picker,12_television,22_sesh,13_keys_picker}.zsh` + `dot_config/shell/15_atuin.sh` | All `Alt+*` pickers + `Tab`/`→` aisuggest swap + `Alt+R` atuin |
| 4 | **Mode switches (vi)** | `zsh-vi-mode` plugin | Intentionally **not listed** — `Esc` / `i` / `:` are mode transitions, not bindings |

Layer 4 omitted on purpose (per the design spec): listing every
`vicmd`-mode key would balloon the picker to 200+ rows and dilute signal.

## Three entry points

| Method | Trigger | Where it works | Notes |
|--------|---------|----------------|-------|
| **ZLE picker** (canonical) | `Alt+/` | zsh interactive | Live `bindkey` lookup in preview; `Ctrl+E` triggers the widget directly; `Ctrl+L` swaps to raw `bindkey -M emacs` view (escape hatch for power users) |
| **Television channel** | `tv keybindings` | zsh & bash, any TTY | Same data source; `Enter` paste-comment, `Ctrl+Y` copy key combo |
| **Static viewer** | `bindings` | zsh & bash (POSIX function in `dot_config/shell/10_aliases.sh`) | Picks `tv` → `bat` → `less` → `cat` in that order; safe in non-interactive `bash -c` too |

The ZLE widget is rebound from `zvm_after_init` in
[`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl)
to survive `zsh-vi-mode`'s init-time keybind wipe — the same pattern as
`aisuggest`. Bash currently has no ZLE widget port; CLI fallback is
`bindings` (no ble.sh keybind because designing one duplicates the work
of [the planned bash `Alt+/` ble.sh binding](#future-bash-port)).

## Picker keybindings (inside the fzf overlay)

| Key | Action |
|-----|--------|
| `Enter` | Paste `# <key> → <widget>: <desc>` as a shell comment to the buffer (read-only result; press Enter again to noop, or `Ctrl+U` to discard) |
| `Ctrl+E` | Trigger the widget directly via `zle <widget-name>` (only works for widgets registered in current zsh; warns if not) |
| `Ctrl+L` | Reload picker with `bindkey -M emacs` raw output — the **escape hatch** for finding bindings the cheatsheet didn't curate |
| `Ctrl+/` | Toggle preview panel (live `bindkey` lookup + `grep` of the widget's source file in `~/.config/zsh/`) |

## Format contract for the data source

The data source [`dot_config/docs/shells/keybindings.md`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/docs/shells/keybindings.md)
is parsed by `awk -F'|'`. Every cheatsheet row MUST be exactly:

```
| `<KEY>` | `<widget>` | <description> |
```

Three pipe-delimited cells, key wrapped in backticks. Group headings
(`### …`) are valid markdown but skipped by the parser. Adding a fourth
column or unbalanced backticks **silently drops the row** — not a hard
error, but the row vanishes from the picker.

The `tv keybindings` channel uses an embedded copy of the same awk
program — see
[`dot_config/television/cable/keybindings.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/keybindings.toml).

## Maintenance rule

Whenever you add, modify, or remove a custom zsh ZLE widget binding in
`dot_config/zsh/tools/*.zsh`, update **two** files in the same commit:

1. [`dot_config/docs/shells/keybindings.md`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/docs/shells/keybindings.md) — the picker data source (one row per binding).
2. [`docs/shells/aliases.md`](aliases.md) — only if the change adds a
   user-callable function (`bindings`, `tools-picker` invoked manually).
   Pure ZLE widgets (`tv-files`, `keys-picker`) don't need an aliases.md row.

This rule is also recorded in the cross-file maintenance section of
[`AGENTS.md`](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md).

## Future: bash port {#future-bash-port}

Bash has no equivalent of zsh ZLE widgets, but ble.sh's `ble-bind`
supports running a shell command on a key combo. A bash version of the
picker would:

1. Live in `dot_config/bash/13_keys_picker.bash` (bash-only tier per the
   three-tier rule in `AGENTS.md`).
2. Use `ble-bind -f 'M-/' '_keys_picker_bash'` (Alt+/) inside
   `~/.bashrc.adhoc` (sourced after `ble-attach`).
3. Reuse the same data source and awk parser; just swap the action from
   `zle keys-picker` to a function that re-reads `READLINE_LINE` and
   `READLINE_POINT`.

Deferred until there's a concrete bash-primary user need; see
[`backlog/`](https://github.com/daviddwlee84/dotfiles/tree/main/backlog)
if it gets requested.

## Related

- [Emacs-style line editing — origin & must-know subset](emacs-line-editing.md) — the 1970s/80s history of why every Unix shell shares `Ctrl+A`/`Ctrl+E`/`Ctrl+W`/`Ctrl+R`, the kill-ring vs system clipboard distinction, and the recommended 8-key core for new users.
- [Aliases & functions](aliases.md) — sister cheatsheet for shell aliases (not keybindings).
- [Bash bootstrap](bash.md) — why bash needs `atuin init bash --disable-up-arrow` and how ble.sh fits in.
- [Architecture](architecture.md) — the shared / zsh-only / bash-only three-tier loader convention.
