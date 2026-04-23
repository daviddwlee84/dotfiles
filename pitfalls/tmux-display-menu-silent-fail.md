# tmux display-menu silently doesn't open (no error, no menu)

**Symptoms** (grep this section):
- `prefix + <key>` bound to `display-menu` does nothing — no popup, no error message, no entry in `tmux show-messages`
- `tmux list-keys -T prefix <key>` shows the binding correctly
- Other bindings on the same key (e.g. `bind-key … display-message`) fire fine
- Right-click pane menus and other simpler `display-menu` invocations still work
- Menu opens on a tall terminal, fails on a short one — or works after deleting half the rows
- Bisecting a long flat menu by halving the rows reveals the failure depends on **menu length**, not on the bound key (the key was a red herring)

**First seen**: 2026-04
**Affects**: tmux 3.6a (likely all 3.x), any platform
**Status**: workaround documented (script-driven menu with height-aware tier trimming)

## Symptom

Bound a 50-row `display-menu` to `prefix + Space`, then to `prefix + Enter`, then to `prefix + e`. Each new key would also "not work" — no popup, no error, no log entry. Hours of debugging key encoding (`extended-keys`, `csi-u`, Ghostty `macos-option-as-alt`, upstream tmux/tmux issues #4571 #4147 #4959 #4984) all turned up nothing because **the keys were bound correctly all along**. The actual failure was that the menu was taller than the terminal.

Reproduction:

```tmux
# Bind a long menu (50+ rows) and shrink the terminal vertically.
# Above some height threshold: menu opens.
# Below it: prefix + key does nothing. No error.
bind-key Space display-menu -T 'big' -x R -y P \
  "Row 1" 1 "display-message 1" \
  "Row 2" 2 "display-message 2" \
  ... 50 more rows ...
```

This is documented behaviour buried in `man tmux`:

> If the menu is too large to fit on the terminal, it is not displayed.

It also applies in a less obvious way at moderate heights when `-y P` (anchor to status bar) leaves no room above.

## Confounding "real but smaller" bugs

Bisecting the failing menu surfaced two genuine quoting bugs that **also** broke the menu but were not the root cause of the dominant symptom:

1. **`'\;'` as an accelerator key** — tmux stored this as bare `\;` in the binding, then at menu-execution time interpreted it as a command separator, ending `display-menu` early. Subsequent menu rows became arguments to `last-pane`, producing `command last-pane: too many arguments (need at most 0)` — visible in `tmux show-messages` only when the binding was rebuilt, not on every keypress. **Fix**: use a different accelerator key (`P` instead of `'\;'` for "Last pane").
2. **`fzf-tmux ... --bind 'ctrl-d:execute(tmux kill-session -t {2..})'` inline in a menu row** — fzf's `{2..}` range syntax collides with tmux's command-block delimiters `{ }`, silently aborting parse of that row. **Fix**: extract complex commands into shell scripts (no nested-quote disasters in a real shell).

Both fixes are necessary but neither restored the menu by itself; the dominant cause was always menu-too-tall.

## Root cause

`display-menu` does not paginate. tmux measures the rendered popup height; if it exceeds available terminal height (after `status-position` and `-y` anchor offset), the popup is suppressed entirely with no log message. There is no scroll, no truncation, no error event.

Why this is hard to diagnose:
- A static config + a tall terminal means it works "always" → no one notices the limit until they ssh in from a small pane / mobile shell / split layout.
- Adding rows over time keeps it working until one row tips it over → looks like "the new row broke something".
- Bisecting a long menu by halving the rows works (because the half is short enough to render) → looks like a content problem.

## Workaround

Two changes:

1. **Generate the menu from a script** that reads `#{client_height}` and emits a tier-trimmed row list:
   - Tier 0 (always): ~7 highest-frequency rows
   - Tier 1 (height ≥ 22): adds new-window/split/zoom
   - Tier 2 (height ≥ 14): adds submenu launchers + cheatsheet/key-search
2. **Push everything else into submenus**, each implemented as its own `tmux display-menu` script. Submenus get a fresh quoting context, so nested escaping disasters go away.

Layout in this repo:

```
~/.config/tmux/menu.sh           # top menu (tier-aware)
~/.config/tmux/menu-layouts.sh   # → Layouts submenu
~/.config/tmux/menu-session.sh   # → Session mgmt submenu
~/.config/tmux/menu-sesh.sh      # → Sesh extras submenu
~/.config/tmux/menu-popups.sh    # → Popups submenu
~/.config/tmux/menu-theme.sh     # → Theme submenu
~/.config/tmux/menu-system.sh    # → System submenu (reload, plugins, detach, clock)
~/.config/tmux/sesh-picker.sh    # nested fzf-tmux extracted out
~/.config/tmux/sesh-windows.sh   # nested fzf-tmux extracted out
```

Bindings in `dot_config/tmux/keybindings.conf`:

```tmux
bind-key Space run-shell "~/.config/tmux/menu.sh"
bind-key e     run-shell "~/.config/tmux/menu.sh"
```

When adding a new menu item, add it to the relevant submenu, not the top menu. Top-menu cap is ~14 rows (fits a 20-row terminal). When adding a row that contains `{`, `}`, `;`, backticks, or more than two levels of nested quotes, extract to a script.

## Prevention

When designing a tmux popup menu:

1. **Cap the top menu at ~14 rows.** Use submenus (separate `display-menu` scripts) for everything else.
2. **Generate the menu from a script** that consults `#{client_height}` and `#{client_width}` if you want auto-trim across many heights.
3. **Verify by shrinking the terminal vertically.** A "menu works" smoke test on a full-height window does not catch this.
4. **Don't blame key encoding first.** If a `display-menu` binding doesn't fire, bind the same `display-menu` to a known-good letter key on a known-tall terminal — if it works there, the problem is height (or content), not the key.
5. **For complex commands inside menu rows** (any `{`, `}`, `;`, backtick, nested fzf binds): extract to a script.

## Related

- `dot_config/tmux/executable_menu.sh` — top-level menu generator (height-aware)
- `dot_config/tmux/executable_menu-*.sh` — submenu scripts
- `dot_config/tmux/executable_sesh-picker.sh`, `executable_sesh-windows.sh` — extracted complex commands
- `dot_config/tmux/keybindings.conf` — `bind-key Space` / `bind-key e` → `menu.sh`
- [`AGENTS.md` → Tmux ≥ 3.3 required for popup menu](../AGENTS.md) — adjacent invariant about a different `display-menu` failure mode (off-screen on tmux 3.2a). The 3.3+ position-clamping fix doesn't help with menu-too-tall — that limit is independent.
- `man tmux` → `display-menu` → "If the menu is too large to fit on the terminal, it is not displayed."
