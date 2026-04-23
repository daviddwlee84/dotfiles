# tmux: `join-pane -t N` interprets `N` as pane index, not window index

## Symptom

Status-bar error after picking the destination from a `command-prompt`:

```
Source and target panes must be different
```

…even though source and target visibly belong to different windows.

Reproduces with bindings like:

```tmux
bind J command-prompt -p "Send pane to (target):" "join-pane -h -t '%%'"
```

User types `1`, expecting "send to window 1". Instead tmux complains.

## Root cause

`join-pane -t target-pane` accepts a **pane** target. tmux's target parser
resolves a bare integer `N` against the **current window's pane index**, not the
window list. So `-t 1` means "pane index 1 in the current window" — which on a
2-pane window is often the source pane itself, hence "must be different".

To target window 1 you would have to type `1.0`, `:1`, `myhost:1`, or
`@<window-id>` — none of which are obvious to a user who just sees window
numbers in the status bar.

The same trap applies to `swap-pane -t`, `move-pane -t`, and any other
`-t target-pane` command.

`move-window -t`, `link-window -t`, `break-pane -t` are different — those
accept a **window** target, so a bare `N` works as expected. The asymmetry
is the source of the confusion.

## Fix

Replace the free-form `command-prompt` with `choose-tree -Zw`, which returns a
properly formatted target string (`session:window` with the colon). tmux's
target parser then unambiguously resolves to "active pane of that window" and
won't fall back to the pane-index interpretation.

Also pass an explicit `-s '#{pane_id}'` (or `'#{window_id}'`) so the source is
pinned by ID — protects against the same ambiguity on the source side.

```tmux
# Before (broken — bare N → pane index in current window):
bind J command-prompt -p "Send to:" "join-pane -h -t '%%'"

# After (works — choose-tree gives session:window, source pinned by ID):
bind J choose-tree -Zw -F "#{window_name}" \
  "join-pane -h -s '#{pane_id}' -t '%%'"
```

In our config: `dot_config/tmux/keybindings.conf` (right-click pane and window
menus) and `dot_config/tmux/executable_menu-session.sh` (popup menu Session
submenu).

## Why `#{window_id}` in the menu body wasn't enough

Initial debugging assumed `#{window_id}` in the menu row body was expanding
against the wrong context (e.g. client current window instead of the
right-clicked tab). It expands correctly — `display-menu -t =` propagates the
mouse target down. The actual failure was on the **target** side, not the
source: the user-typed `1` was interpreted as a pane index, not a window index.

Manual `tmux join-pane -h -s @20 -t 1` from a CLI happened to succeed only
because at that moment the current window was a different one whose pane index
1 was distinct from the source — an accident of test conditions, not a working
case.

## Related

- `pitfalls/tmux-display-menu-silent-fail.md` — the other tmux menu pitfall
  (height-fit suppression, also misdiagnosed at first)
- `man tmux` → "COMMANDS" → target-pane vs target-window grammar

## General rule: prefer pickers over `command-prompt` for window/session targets

Beyond the specific `join-pane -t N` trap, this debugging round upgraded a
broader heuristic for **all** tmux bindings whose target is "another
window/session/pane the user has to identify":

| Approach | When OK | When NOT OK |
|---|---|---|
| `command-prompt -p "Target:" "cmd -t '%%'"` | Target unambiguously parses to the right scope (e.g. `move-window -t`, `link-window -t`, `break-pane -t` all accept session-level targets — bare `N` works) | Target type is `target-pane` (e.g. `join-pane`, `swap-pane`, `move-pane`) — bare integer falls back to "pane index in current window" and silently picks the wrong (often source) pane |
| `choose-tree -Zs … "cmd -t '%%'"` (session picker) | Cross-session ops where session is the natural target | Single-session use that needs a specific window/pane within |
| `choose-tree -Zw … "cmd -t '%%'"` (window picker) | Cross-window pane ops — returns `session:window`, unambiguous | — |

Even when `command-prompt` is technically safe (M/B/A in this repo), the
picker form is preferred for UX reasons: live preview, no need to remember
session names, no fat-finger typos. We migrated `prefix + M / B / A` to
`choose-tree -Zs` in the same change as the join-pane fix for consistency.

Always also pin the **source** with an explicit `-s '#{pane_id}'` or `-s
'#{window_id}'` rather than relying on "current pane / current window".
`#{pane_id}` / `#{window_id}` resolve at menu-row click time against the
client's current pane, which is **not** necessarily the right-clicked tab on
status-bar menus — pinning the ID at definition time avoids that footgun too.

When introducing a new keybinding/menu row that takes a window or session as
target: reach for `choose-tree -Zw` / `-Zs` first; only fall back to
`command-prompt` if no picker fits (e.g. free-form rename, where the user
has to type a brand-new name).
