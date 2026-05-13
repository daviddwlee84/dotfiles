# Plan: Right-click tab menu — workmux clear + manual bookmark icons

## Context

The tmux right-click tab menu (the one shown in the screenshot — `MouseDown3Status` binding in `dot_config/tmux/keybindings.conf.tmpl` lines 48–80) is currently the default-tmux window menu rendered inline. The user wants two additions:

1. **Clear status** — manually unset `@workmux_status` on the right-clicked window, so a stuck 🤖 / 💬 / ✅ icon (agent killed before its `Stop` hook fired, OOM, terminal crash) can be wiped without typing `wmclear` in the shell or hunting for the workmux sidebar.
2. **Manual bookmark / pin** — let the user tag any tab with one of four icons (⭐ / 📌 / 🔖 / 🚩) that renders **next to** the workmux icon, not in place of it. Clicking the same icon a second time clears it (toggle).

The bookmark layer must not collide with workmux. The repo already exposes the generic `tmux_status_*` API in `dot_config/shell/60_tmux_status.sh` for exactly this use case: it reserves the `workmux*` name prefix and invites other producers to register under `@<name>_status`. We use `@bookmark_status`.

Per the submenu pitfall (`pitfalls/tmux-submenu-flash-and-bottom-right.md`), nested `display-menu` via `run-shell` from a `MouseDown3Status` parent is unreliable — must inline. User has opted to accept menu height growth (+~6 rows).

## Approach

### 1. `dot_config/tmux/keybindings.conf.tmpl` — extend the menu

Insert a new section between `"Rename"` (line 78) and the trailing separator + `"New window"` (lines 79–80). Six new rows + two separators (one before, one after — matches the section pattern used elsewhere in the menu):

```tmux
"" \
"⭐ Star"     s { run-shell "~/.config/tmux/toggle-bookmark.sh '#{window_id}' '⭐'" } \
"📌 Pin"      p { run-shell "~/.config/tmux/toggle-bookmark.sh '#{window_id}' '📌'" } \
"🔖 Bookmark" b { run-shell "~/.config/tmux/toggle-bookmark.sh '#{window_id}' '🔖'" } \
"🚩 Flag"     f { run-shell "~/.config/tmux/toggle-bookmark.sh '#{window_id}' '🚩'" } \
"Clear agent status" c { set-option -w -t "#{window_id}" -u "@workmux_status" ; display-message "Cleared @workmux_status on #{window_index}:#{window_name}" } \
```

- `#{window_id}` resolves at menu-display time to the right-clicked window — confirmed by existing `"Rename"` row which uses the same expansion.
- "Clear agent status" inlines `set-option` directly (no `run-shell` needed — keeps it fast).
- The bookmark rows go through a tiny helper script (see #3) because tmux can't easily express "toggle: if current == X, unset; else set to X" in a single `display-menu` command list without nightmare quoting around emoji literals.
- Update the WARNING comment block above the binding (lines 50–60): bump "17 visible rows" → "23 visible rows" and remove the "candidates to drop" hint (user explicitly opted for growth).

### 2. `dot_config/tmux/theme.catppuccin.conf` — render the bookmark glyph

Append a second conditional to both window-text format strings (lines 31–32). The catppuccin theme already supports chained `#{?@var, …,}` conditionals — line 32 demonstrates the pattern with `window_zoomed_flag`:

Current (line 31):
```tmux
set -g @catppuccin_window_text ' #W#{?@workmux_status, #{@workmux_status},}'
```
New:
```tmux
set -g @catppuccin_window_text ' #W#{?@workmux_status, #{@workmux_status},}#{?@bookmark_status, #{@bookmark_status},}'
```

Current (line 32):
```tmux
set -g @catppuccin_window_current_text ' #W#{?window_zoomed_flag, 󰊓 ,}#{?@workmux_status, #{@workmux_status},}'
```
New:
```tmux
set -g @catppuccin_window_current_text ' #W#{?window_zoomed_flag, 󰊓 ,}#{?@workmux_status, #{@workmux_status},}#{?@bookmark_status, #{@bookmark_status},}'
```

Result: `1: shell 🤖 ⭐` when both are set; `1: shell 🤖` for agent only; `1: shell ⭐` for bookmark only; `1: shell` for neither.

Extend the existing comment block (lines 20–30) to mention the bookmark conditional and link to the toggle helper.

### 3. NEW: `dot_config/tmux/executable_toggle-bookmark.sh` — toggle helper

Deploys as `~/.config/tmux/toggle-bookmark.sh` with `chmod +x`. POSIX `sh`, no zsh-isms.

```sh
#!/usr/bin/env sh
# Toggle @bookmark_status on a tmux window.
# Usage: toggle-bookmark.sh <window-id> <glyph>
#   If @bookmark_status on <window-id> already equals <glyph>, unset it.
#   Otherwise overwrite it with <glyph>.
# Invoked by the MouseDown3Status menu in dot_config/tmux/keybindings.conf.tmpl.
# Parallels workmux's @workmux_status — independent var, both render side-by-side
# in the catppuccin window-text format.
set -eu

win="${1:-}"
glyph="${2:-}"

if [ -z "$win" ] || [ -z "$glyph" ]; then
    printf 'usage: %s <window-id> <glyph>\n' "$0" >&2
    exit 64
fi

current=$(tmux show-options -wv -t "$win" '@bookmark_status' 2>/dev/null || true)

if [ "$current" = "$glyph" ]; then
    tmux set-option -w -t "$win" -u '@bookmark_status' 2>/dev/null || true
    tmux display-message "Bookmark cleared"
else
    tmux set-option -w -t "$win" '@bookmark_status' "$glyph"
    tmux display-message "Bookmark: $glyph"
fi
```

No `chezmoi` template — pure shell. The `executable_` prefix gives it `+x` on deploy.

## Files

| Path | Change |
|---|---|
| `dot_config/tmux/keybindings.conf.tmpl` (lines 48–80) | Extend MouseDown3Status menu with 6 new rows + 2 separators; refresh the row-count comment |
| `dot_config/tmux/theme.catppuccin.conf` (lines 31–32) | Append `#{?@bookmark_status, …,}` conditional to both window-text formats; extend explanatory comment |
| `dot_config/tmux/executable_toggle-bookmark.sh` | **NEW** — POSIX `sh` toggle script |

## Existing utilities reused — do NOT reimplement

- **`tmux_status_*` API** at `dot_config/shell/60_tmux_status.sh`: already validates names, reserves `workmux*` prefix, and provides `tmux_status_set` / `_get` / `_clear` / `_clear_all` / `_list` / `_run`. Users who want to drive `@bookmark_status` from CLI or scripts can do so via this API today (`tmux_status_set bookmark '⭐'`). We do NOT need a shell wrapper or alias for the bookmark — the menu is the front-door UI; the existing helpers are the back door.
- **`wmclear` function** at `dot_config/shell/38_workmux.sh:39–73`: already the canonical CLI escape hatch for clearing `@workmux_status`. We do NOT modify it. The menu's "Clear agent status" row is the GUI equivalent, intentionally narrower (single window only — no `--all` mode in the menu to keep the surface small).
- **`#{window_id}` expansion** in `display-menu`: already used by `Rename` on line 78. Same pattern, no new tmux feature needed.

## Hard rules honored (per CLAUDE.md `workmux` 6-file invariant)

The workmux integration spans 6 files. This plan touches one (`theme.catppuccin.conf`) **additively** — appending a second conditional after the existing `@workmux_status` one. Verified:

1. ✅ `status_format: false` in `dot_config/workmux/config.yaml` — untouched
2. ✅ `command -v workmux >/dev/null 2>&1` guards in `dot_claude/modify_settings.json` — untouched
3. ✅ `Stop` / `SubagentStop` → `set-window-status done` — untouched
4. ✅ Never runs `workmux setup`
5. ✅ The `@bookmark_status` user-option is reserved by `60_tmux_status.sh`'s validator (rejects `workmux*` names, accepts anything else under `[A-Za-z0-9_-]+`)
6. ✅ Mnemonic letters `s` / `p` / `b` / `f` / `c` don't collide with any existing key in the same `MouseDown3Status` menu (existing: `l r 1 2 3 4 5 m K E X N n w`)

## Cross-file maintenance (per CLAUDE.md)

- **`docs/tools/workmux.md`** — add a one-paragraph note under "Reusing the per-window status mechanism" pointing to the new menu items + the toggle helper. (Read-only mention; the existing API table is already correct.)
- The `dot_config/tmux/theme.catppuccin.conf` change is a parallel additive line — no need to update the 6-file workmux invariant matrix in `CLAUDE.md` itself (it still spans the same 6 files; we're not adding a 7th surface to the workmux integration, we're using the documented public API).
- **No** alias added to `docs/shells/aliases.md` — we deliberately did not add a shell alias for bookmark toggle; the public `tmux_status_set bookmark <glyph>` already exists and the menu is the front door.

## Verification

1. **Reload tmux config**: `tmux source-file ~/.config/tmux/tmux.conf` (or `prefix + r` if the user has that bound; otherwise restart tmux server with `tmux kill-server` and reattach).
2. **Right-click any tab** → confirm the menu now ends with `⭐ Star`, `📌 Pin`, `🔖 Bookmark`, `🚩 Flag`, `Clear agent status` rows before `New window`.
3. **Toggle bookmark**: right-click tab → `⭐ Star` → confirm `⭐` appears next to the tab name. Right-click same tab → `⭐ Star` again → confirm `⭐` disappears. Right-click → `📌 Pin` → confirm `📌` appears. Right-click → `🔖 Bookmark` → confirm switches from `📌` to `🔖` (overwrite, not toggle, since clicked icon differs from current).
4. **Coexist with workmux**: open Claude Code in a tab so `🤖` appears. Set `⭐` on the same tab → confirm both render: `1: shell 🤖 ⭐`. Click `Clear agent status` → confirm `🤖` disappears but `⭐` remains: `1: shell ⭐`.
5. **Clear from CLI still works**: `wmclear` from a shell in the tab → confirm `🤖` clears (unchanged behavior). `tmux_status_clear bookmark` → confirm `⭐` clears.
6. **Audit per-window vars**: `tmux_status_list` → confirm shows `@workmux_status` and `@bookmark_status` entries with correct glyphs.
7. **Small-terminal check** (height growth: ~23 rows): shrink terminal to ~26 rows tall and right-click a tab → confirm the menu still renders (silent suppression threshold per `pitfalls/tmux-display-menu-silent-fail.md`). If suppressed at ≥ 30 rows, revisit and trim.
8. **Mnemonics**: from the open menu, press `s` / `p` / `b` / `f` / `c` directly (without mouse) → confirm each fires its action.
