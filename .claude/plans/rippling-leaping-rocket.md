# Plan: Right-click menu fix + Catppuccin polish + XDG docs

## Context

Follow-up pass on the modular tmux config from the previous commit. User hit three issues:

1. **Right-click popup menu vanishes on mouse release** — when right-clicking in a pane, the menu appears briefly but dismisses the moment the mouse button is released, so no item can be selected.
2. **Catppuccin window tabs are centered** — user wants them left-aligned, and wants more useful modules on the status bar than just `session / application / uptime / date_time`.
3. **No docs on XDG Base Directory Specification** — useful background for why `~/.config/tmux/tmux.conf` is preferred over `~/.tmux.conf`, and applies to many other configs in this repo.

## Findings

### Right-click menu dismissal

tmux 3.4's built-in `MouseDown3Pane` / `MouseDown3Status` / `MouseDown3StatusLeft` bindings invoke `display-menu` **without** the `-O` flag. Without `-O`, `display-menu` closes if the mouse is released outside an item before a selection is made — which is exactly what happens on a quick right-click-and-release. Adding `-O` ("stay **O**pen until an item is chosen or Escape") makes the menu persist as expected.

Confirmed via `tmux list-keys -T root | grep MouseDown3` — our config doesn't override these; we're getting tmux defaults minus `-O`.

### Catppuccin alignment + modules

- Alignment: `set -g status-justify centre` (tmux default) is what centers the window list. Change to `left`.
- v2 plugin at `~/.tmux/plugins/tmux/status/` ships these modules: `application`, `battery`, `clima`, `cpu`, `date_time`, `directory`, `gitmux`, `host`, `kube`, `load`, `pomodoro_plus`, `ram`, `session`, `uptime`, `user`, `weather`. Our current theme only uses 4 (`session`, `application`, `uptime`, `date_time`).

Useful additions that don't need extra tooling:
- `directory` — current pane's `pwd` (basename). Very useful when juggling repos.
- `host` — hostname. Handy when SSH'd into many boxes.
- `user` — `$USER`. Cheap situational awareness.
- `cpu` / `ram` — already covered by tmux2k for users who want sysload; optional in catppuccin.
- `battery` — only meaningful on laptops (macOS / Linux with power); gracefully shows nothing otherwise.

Proposed composition:
- **Left**: `session` → `directory`  (what am I in)
- **Right**: `application` → `user` `@` `host` → `date_time`  (what's running, where, when)

Keep it minimal by default; document the full module list so user can remix.

### XDG Base Directory docs

No existing doc. Most tools in this repo already use XDG paths (`~/.config/nvim`, `~/.config/zellij`, etc.), and the tmux refactor just moved to `~/.config/tmux/`. A short `docs/tools/xdg.md` explaining the spec and listing where our configs live fits the existing `docs/tools/*.md` pattern.

## Changes

### 1. `dot_config/tmux/keybindings.conf` — right-click menu fix

Add, near the top of the file, a block that rebinds the three root-level MouseDown3 events with `-O`:

```tmux
# =============================================================================
# Mouse menu persistence (fix: menu dismisses on mouse release without -O)
# =============================================================================

unbind-key -n MouseDown3Pane
bind-key -n MouseDown3Pane \
  if-shell -F -t = "#{||:#{mouse_any_flag},#{&&:#{pane_in_mode},#{?#{m/r:(copy|view)-mode,#{pane_mode}},0,1}}}" \
    { select-pane -t = ; send-keys -M } \
    { display-menu -O -T "#[align=centre]#{pane_index} (#{pane_id})" -t = -x M -y M \
        "Horizontal Split" h { split-window -h } \
        "Vertical Split"   v { split-window -v } \
        "" \
        "Swap Up"     u { swap-pane -U } \
        "Swap Down"   d { swap-pane -D } \
        "" \
        "#{?window_zoomed_flag,Unzoom,Zoom}" z { resize-pane -Z } \
        "Kill pane"   X { kill-pane } \
        "Respawn"     R { respawn-pane -k } }

unbind-key -n MouseDown3Status
bind-key -n MouseDown3Status \
  display-menu -O -T "#[align=centre]#{window_index}:#{window_name}" -t = -x W -y W \
    "Swap Left"  l { swap-window -t :-1 } \
    "Swap Right" r { swap-window -t :+1 } \
    "" \
    "Kill window" X { kill-window } \
    "Rename"      n { command-prompt -F -I "#W" { rename-window -t "#{window_id}" "%%" } } \
    "" \
    "New window"  w { new-window }

unbind-key -n MouseDown3StatusLeft
bind-key -n MouseDown3StatusLeft \
  display-menu -O -T "#[align=centre]#{session_name}" -t = -x M -y W \
    Next        n { switch-client -n } \
    Previous    p { switch-client -p } \
    "" \
    Rename      N { command-prompt -I "#S" { rename-session "%%" } } \
    "" \
    "New session" s { new-session } \
    "New window"  w { new-window }
```

Simplified versus tmux defaults (dropped the copy-mode-specific items and the "mouse word / line / hyperlink" helpers) for readability; users who want that richness can fall back to `prefix + Space`. The important bit is the `-O` flag.

### 2. Left-align windows — Catppuccin only

Per user preference: Catppuccin = left, tmux2k = keep centered (habitual).

- `dot_config/tmux/theme.catppuccin.conf`: add `set -g status-justify left`
- `dot_config/tmux/theme.tmux2k.conf`: add `set -g status-justify centre` (explicit reset, so switching Catppuccin → tmux2k on the same server doesn't leak `left`)
- `common.conf`: no change

### 3. `dot_config/tmux/theme.catppuccin.conf` — richer modules

Replace the current status composition with:

```tmux
set -g status-left ""
set -g status-right ""

# Left: session + directory
set -agF status-left "#{E:@catppuccin_status_session}"
set -agF status-left "#{E:@catppuccin_status_directory}"

# Right: application, user@host, date/time
set -agF status-right "#{E:@catppuccin_status_application}"
set -agF status-right "#{E:@catppuccin_status_user}"
set -agF status-right "#{E:@catppuccin_status_host}"
set -agF status-right "#{E:@catppuccin_status_date_time}"

# Module tweaks
set -g @catppuccin_directory_text "#{b:pane_current_path}"   # basename only
set -g @catppuccin_date_time_text "%Y-%m-%d %H:%M"
```

Drop `uptime` (noisy, rarely useful). Keep settings minimal; the long list of available modules lives in docs so users can add battery/cpu/gitmux/weather by uncommenting examples.

### 4. `docs/tools/xdg.md` — new

Single-page primer:

- What XDG Base Directory Specification is, link to [freedesktop spec](https://specifications.freedesktop.org/basedir/latest/).
- The four core vars: `XDG_CONFIG_HOME` (`~/.config`), `XDG_DATA_HOME` (`~/.local/share`), `XDG_STATE_HOME` (`~/.local/state`), `XDG_CACHE_HOME` (`~/.cache`).
- Why it matters: keeps `$HOME` clean, predictable tooling, easy to back up / sync / delete.
- Table of **this repo's** config locations, with a column noting whether each tool honors XDG natively or needs a shim. Good ones to list: tmux (native in 3.1+, we use shim `~/.tmux.conf` → `~/.config/tmux/tmux.conf`), neovim, zellij, starship, alacritty, ghostty, yazi, bat, direnv, gh, claude (some still use `~/.*`).
- Short "how this repo handles it" note pointing at `dot_config/` vs dotfiles in `$HOME`.

### 5. `docs/tools/tmux/README.md` — link to XDG doc

Add under "Related Docs":

```markdown
- [XDG Base Directory Specification](../xdg.md) — why configs live under `~/.config/tmux/` rather than `~/.tmux.conf`
```

### 6. `docs/tools/tmux/keybindings.md` — document the mouse menu behavior

Add a short "Right-click menus" subsection under the existing mouse content, explaining that right-click opens a context menu on panes (`MouseDown3Pane`), the window list (`MouseDown3Status`), and session area (`MouseDown3StatusLeft`), and that they stay open until Escape or selection.

### 7. `docs/tools/tmux/themes.md` — catalog Catppuccin modules

Add a section listing every available module from `~/.tmux/plugins/tmux/status/` with a one-line description and a toggle-on example so users can remix. Also note the `@catppuccin_directory_text`, `@catppuccin_date_time_text` knobs.

## Files touched

**Modified:**
- `dot_config/tmux/keybindings.conf` — add `-O` mouse rebindings
- `dot_config/tmux/theme.catppuccin.conf` — `status-justify left`, richer modules, directory/user/host
- `dot_config/tmux/theme.tmux2k.conf` — explicit `status-justify centre` reset
- `docs/tools/tmux/README.md` — link to XDG doc
- `docs/tools/tmux/keybindings.md` — mouse menu note
- `docs/tools/tmux/themes.md` — module catalog

**New:**
- `docs/tools/xdg.md` — XDG Base Directory primer

## Verification

1. `chezmoi apply`
2. In a fresh tmux (cleanest: `tmux kill-server && tmux`):
   - Right-click in a pane → menu opens, stays open on mouse release, Escape or selection to close. Repeat on the window list and the session area on the left of the status bar.
   - Window tabs are left-aligned right after the session segment.
   - Status right shows `application`, `user@host`, `YYYY-MM-DD HH:MM`.
   - Left shows session + current directory basename; open a second pane in a different path, move to it, confirm the basename updates.
3. `prefix + T` to switch to tmux2k → bottom bar, left-aligned (same `status-justify left` applies).
4. Render `docs/tools/xdg.md` and the tmux README — XDG link resolves.

## Out of scope

- Not adding battery / weather / gitmux / kube modules by default — documented in themes.md so users can opt in.
- Not rewriting the rest of the default mouse bindings (drag-to-copy, double-click word select, etc.); those aren't broken.
- No changes to tmux2k theme file — this pass is about the default (Catppuccin) and shared behavior.


## Context

User wants to extend the current tmux setup in three coordinated ways:

1. **Refactor the monolithic `dot_tmux.conf`** into a modular directory layout so shared settings and per-theme settings are cleanly separated.
2. **Add a second theme (Catppuccin + top status bar)** inspired by [omerxx/dotfiles](https://github.com/omerxx/dotfiles/tree/master/tmux) / [this video](https://www.youtube.com/watch?v=GH3kpsbbERo), and make it the **default**. Keep tmux2k as an opt-in alternative, selectable via env var **or** runtime key-binding.
3. **Expand `docs/tools/tmux.md`** with: the two reference links the user supplied, a tmux × Neovim section (confirming the existing vi-style copy/scroll support), the new theme-switch mechanics, and a troubleshooting entry for the tmux2k bandwidth bug (`18446744073709551615K` = `UINT64_MAX` underflow).

The bandwidth bug will be **documented only**, not patched in config (per user answer).

## Findings from current `dot_tmux.conf`

- vi copy-mode is already wired: `mode-keys vi` (line 62) + `v / V / C-v / y / g / G / / / ?` (lines 165–180). Doc just needs to cross-reference it in the new Vim section — no config change.
- Theme = `tmux2k` onedark, status-position **bottom** (lines 39–49, 77).
- TPM path is `~/.tmux/plugins` (line 9). After refactor, we should keep that path (standard) even though the main config moves to `~/.config/tmux/`.
- Bandwidth segment comes from `@tmux2k-right-plugins "bandwidth network time"` (line 49). UINT64 underflow is a known tmux2k issue (bandwidth script's `prev − curr` wraps on first tick / when iface changes).
- Commented-out alternative themes exist at lines 291–297 (dracula, tmux-power, pimux, mem-cpu-load) — safe to drop during refactor; we're adding proper Catppuccin support.

## Target layout (chezmoi source → deployed path)

```
chezmoi:  dot_config/tmux/                  →  ~/.config/tmux/
          ├── tmux.conf                     (entry point, selects theme)
          ├── common.conf                   (everything theme-agnostic)
          ├── keybindings.conf              (all bind-key / popup menu)
          ├── theme.catppuccin.conf         (new — default)
          └── theme.tmux2k.conf             (existing theme, moved)
```

The legacy `dot_tmux.conf` (→ `~/.tmux.conf`) becomes a one-line shim so existing users / scripts that `source ~/.tmux.conf` keep working:

```tmux
# ~/.tmux.conf — shim: delegate to XDG location
source-file ~/.config/tmux/tmux.conf
```

Rationale: tmux auto-reads `~/.config/tmux/tmux.conf` on modern versions, but keeping the shim avoids breaking anything that references `~/.tmux.conf` (e.g. the `prefix + R` reload binding, install scripts, the `Verify Current Config` snippet in the doc).

## File-by-file plan

### `dot_config/tmux/tmux.conf` (new entry point)

```tmux
# Shared base (no status/theme styling)
source-file ~/.config/tmux/common.conf
source-file ~/.config/tmux/keybindings.conf

# Theme selection — priority:
#   1. TMUX_THEME env var (catppuccin | tmux2k)
#   2. tmux option @theme_variant (persisted across reload within server)
#   3. default: catppuccin
if-shell '[ -n "$TMUX_THEME" ]' \
  'set -g @theme_variant "$TMUX_THEME"'
if-shell '[ -z "#{@theme_variant}" ]' \
  'set -g @theme_variant "catppuccin"'

if -F '#{==:#{@theme_variant},catppuccin}' \
  'source-file ~/.config/tmux/theme.catppuccin.conf'
if -F '#{==:#{@theme_variant},tmux2k}' \
  'source-file ~/.config/tmux/theme.tmux2k.conf'

# TPM init must be last
run 'PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH" ~/.tmux/plugins/tpm/tpm'
```

### `dot_config/tmux/common.conf` (new — theme-agnostic)

Contains, lifted verbatim from `dot_tmux.conf`:

- TPM env + `set -g @plugin 'tmux-plugins/tpm'`
- Non-theme plugins: `tmux-resurrect`, `tmux-continuum`, `tmux-floax` (+ floax options), `tmux-fzf-url`, `tmux-open` (+ `@open-S`)
- General settings: `escape-time 0`, `mouse on`, `mode-keys vi`, `history-limit 50000`, `base-index 1`, `pane-base-index 1`, `renumber-windows on`, `focus-events on`, `detach-on-destroy off`
- Terminal/keys: `default-terminal tmux-256color`, `terminal-features RGB`, `extended-keys always`, csi-u conditional, `set-clipboard on`, `allow-passthrough on`
- **Both** theme plugins declared (so TPM installs both; only one is activated):
  ```tmux
  set -g @plugin 'catppuccin/tmux'
  set -g @plugin '2kabhishek/tmux2k'
  ```
- **Not** included here: `status-position`, `status-left/right`, `window-status-*`, any color/style — those belong to the theme files.

### `dot_config/tmux/keybindings.conf` (new — all bindings & popup menu)

Moved verbatim from `dot_tmux.conf`:

- Copy-mode vi bindings (v/V/C-v/y, mouse drag, double-click)
- Capture pane helpers (`y`, `Y`, `C-y`)
- Pane/window: `h/j/k/l`, `H/J/K/L`, `M-h/j/k/l`, `|`, `-`, `+`, `c`, `x`, `R`, `N`, `X`
- Sesh: `g`, `S`, `9`
- Popup menu (`prefix + Space`) — full `display-menu` block
- **New**: `prefix + C` → switch to catppuccin, `prefix + T` → switch to tmux2k:
  ```tmux
  bind C run-shell 'tmux set -g @theme_variant catppuccin; \
    tmux source-file ~/.config/tmux/tmux.conf; \
    tmux display-message "Theme: catppuccin"'
  bind T run-shell 'tmux set -g @theme_variant tmux2k; \
    tmux source-file ~/.config/tmux/tmux.conf; \
    tmux display-message "Theme: tmux2k"'
  ```
  Add corresponding rows to the popup menu ("Theme: catppuccin" / "Theme: tmux2k").

### `dot_config/tmux/theme.catppuccin.conf` (new — default)

```tmux
# Reset any inherited status styling
set -g status-left ""
set -g status-right ""
set -g window-status-format ""
set -g window-status-current-format ""

# Top status bar (omerxx-style)
set -g status-position top

# Catppuccin options
set -g @catppuccin_flavor "mocha"
set -g @catppuccin_window_status_style "rounded"

# Load plugin (TPM install path)
run '~/.tmux/plugins/tmux/catppuccin.tmux'

# Compose status line
set -g status-left "#{E:@catppuccin_status_session} "
set -g status-right "#{E:@catppuccin_status_application}"
set -agF status-right "#{E:@catppuccin_status_uptime}"
set -agF status-right "#{E:@catppuccin_status_date_time}"
```

Exact modules/flavour are easy to tweak after first render; the key invariants are `status-position top` and Catppuccin being self-contained.

### `dot_config/tmux/theme.tmux2k.conf` (new — lifted from current config)

```tmux
# Reset so toggling from catppuccin leaves no residue
set -g status-left ""
set -g status-right ""
set -g window-status-format ""
set -g window-status-current-format ""
set -g status-position bottom

set -g @tmux2k-theme 'onedark'
set -g @tmux2k-start-icon ""
set -g @tmux2k-left-plugins "git cpu ram"
set -g @tmux2k-right-plugins "bandwidth network time"

run '~/.tmux/plugins/tmux2k/tmux2k.tmux'
```

### `dot_tmux.conf` (replace content — becomes a shim)

Shrink the existing 305-line file to the 2-line shim shown above. This is the cleanest migration: chezmoi will rewrite `~/.tmux.conf` on apply, nothing else needs to know about the move.

### `run_once_before_00_bootstrap.sh.tmpl` / TPM

No change needed — TPM lives at `~/.tmux/plugins/tpm`, which is installed independently. `prefix + I` still installs both theme plugins declared in `common.conf`.

### `docs/tools/tmux.md`

Add / update:

1. **Config Layout** section (new, near the top, after "tmux" intro): describe `~/.config/tmux/` structure, the shim at `~/.tmux.conf`, and that the entry point picks a theme via `$TMUX_THEME` env var → `@theme_variant` option → default `catppuccin`.
2. **Themes** section (new): document the two themes, defaults, how to switch:
   - Persistent for new tmux servers: `TMUX_THEME=tmux2k tmux` (or shell alias `tmuxt` / `tmuxc`).
   - Runtime within a session: `prefix + C` (catppuccin) / `prefix + T` (tmux2k), also surfaced in popup menu.
   - Note the "cleanest switch is `tmux kill-server`" caveat.
3. **Tmux × Vim / Neovim** (new subsection under existing "Coding-Agent / Neovim Notes"):
   - Confirm vi copy/scroll already works (cross-link to existing Copy-Mode table). Answers the user's question: *yes, vi support in scroll/copy mode is already on.*
   - Mention `focus-events on`, extended keys, true color are already configured for Vim.
   - Flag [`christoomey/vim-tmux-navigator`](https://github.com/christoomey/vim-tmux-navigator) as a possible future add-on (not installed).
4. **Resources** section (new, before "Related Docs"):
   - [rothgar/awesome-tmux](https://github.com/rothgar/awesome-tmux)
   - [Tmux and Vim — even better together (SmartBear)](https://smartbear.com/blog/tmux-and-vim/)
   - [omerxx/dotfiles — tmux/](https://github.com/omerxx/dotfiles/tree/master/tmux) + [video](https://www.youtube.com/watch?v=GH3kpsbbERo)
5. **Troubleshooting** section (new):
   - `tmux2k bandwidth shows 18446744073709551615K`: explain it's `2^64 − 1` uint64 underflow in tmux2k's bandwidth delta calculation (wrong/missing interface, first-tick prev-counter missing). Workarounds: (a) switch to catppuccin default (`prefix + C`), (b) set `@tmux2k-network-name` to a real iface, (c) drop `bandwidth` from `@tmux2k-right-plugins`. No config change applied this pass.
6. Update the existing **Keybindings → Daily Workflow** table to include `prefix + C` and `prefix + T`, and update the **Popup Menu** table to list the two theme entries.
7. Update **Verify Current Config** snippet to reference `~/.config/tmux/tmux.conf` in addition to `~/.tmux.conf`.

### `CLAUDE.md`

The top-level `CLAUDE.md` has a "Tmux Configuration" section that currently says "The tmux config (`dot_tmux.conf`) includes …". Update to reference the new layout (`dot_config/tmux/`), add `prefix + C / T` to the keybinding table, and note the default theme is Catppuccin with top status bar. Keep it brief — detailed content stays in `docs/tools/tmux.md`.

### `README.md`

No structural changes needed — the README's "Config Files" list already points to the tmux doc, which will cover the new layout.

## Files touched

**New:**
- `dot_config/tmux/tmux.conf`
- `dot_config/tmux/common.conf`
- `dot_config/tmux/keybindings.conf`
- `dot_config/tmux/theme.catppuccin.conf`
- `dot_config/tmux/theme.tmux2k.conf`

**Modified:**
- `dot_tmux.conf` (shrink to shim)
- `docs/tools/tmux.md` (add Config Layout, Themes, Vim notes, Resources, Troubleshooting; update keybinding tables)
- `CLAUDE.md` (update "Tmux Configuration" section)

## Verification

1. `chezmoi diff` — review all new/changed files look right.
2. `chezmoi apply` — deploy.
3. Inside a **new** tmux server (cleanest; `tmux kill-server && tmux`):
   - Status bar appears on **top** with Catppuccin styling. No `18446744073709551615K` anywhere.
   - `prefix + [` → copy mode; `j/k`, `v`, `y` work (vi confirm).
   - `prefix + T` → switches to tmux2k (bottom bar, onedark). `prefix + C` → back to catppuccin.
   - `prefix + I` (TPM) installs `catppuccin/tmux` and `2kabhishek/tmux2k` on first run.
   - `prefix + R` still reloads without error (the binding sources `~/.tmux.conf`, which is now the shim; verify shim re-sources the XDG entry point).
4. `TMUX_THEME=tmux2k tmux` in a fresh shell starts in tmux2k.
5. `tmux show-options -g @theme_variant` reflects the active theme.
6. `tmux list-keys | grep -E " C | T "` shows the new theme bindings.
7. Render `docs/tools/tmux.md` (VS Code preview or `glow`); every new link resolves.

## Out of scope (explicit)

- Actually fixing tmux2k's bandwidth underflow in config — user chose docs-only for this pass.
- Changing sesh / floax / fzf-url / open / resurrect / continuum behavior.
- Migrating to non-TPM plugin manager.
- Adding `vim-tmux-navigator` (mentioned in docs as future option only).
