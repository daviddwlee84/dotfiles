# Plan: Copy current tmux pane path (session:window.pane)

## Context

When collaborating with an AI agent inside a shared tmux session, there's currently
no quick way to grab the address of the pane you're looking at. You either want to
reconnect to it later, or tell an agent "operate on *this* pane" — which requires the
tmux target `session:window.pane` (e.g. `main:2.1`).

Today the repo can copy a **session name** (`MouseDown3StatusLeft` menu → "Copy session
name", `keybindings.conf.tmpl:119`) but nothing copies the full pane target. This plan
fills that gap with three coordinated entry points, matching the existing "same verb via
mouse + keyboard + shell" pattern already used across the tmux config:

1. **Right-click menu item** on a pane (`MouseDown3Pane`)
2. **Prefix keybinding** (`prefix + P`)
3. **Shell function** (`tpath`) usable from any shell, pipe-friendly

Decided with the user:
- Clipboard gets the **readable target** `session:window.pane` only.
- The shell function additionally **prints `target` / `pane_id` / `cwd` to stdout** for
  reference (the stable `%N` pane_id and cwd are handy to paste into an agent chat).
- **Yes**, add a prefix keybinding in addition to the menu item + shell alias.

Canonical format string (already used at `dot_config/television/executable_agent-sessions.py:1158`
and `60_tmux_status.sh:164`): `#{session_name}:#{window_index}.#{pane_index}`.

## Changes

### 1. Right-click pane menu item — `dot_config/tmux/keybindings.conf.tmpl`

Add one row to the **inline** `MouseDown3Pane` `display-menu` block (currently lines
24–52), in the copy-related area near `"Enter copy mode" "["` (line 50). Use key `y`
(free in this menu; mirrors the `y` used by "Copy session name"):

```
"Copy pane path" y { set-buffer -w "#{session_name}:#{window_index}.#{pane_index}" ; display-message "Copied pane path: #{session_name}:#{window_index}.#{pane_index}" } \
```

Reuse of `set-buffer -w` (tmux buffer + OSC 52 bridge, SSH-safe) matches the existing
"Copy session name" precedent (`keybindings.conf.tmpl:119`) — no capture-pane needed.

**Hard rule (per the inline `*** IF YOU EDIT THE MENU BODY … ***` comment at
`keybindings.conf.tmpl:20` and pitfalls/tmux-submenu-flash-and-bottom-right.md):** the
mouse menu body MUST stay inline, and the same item MUST be mirrored into the keyboard
script — see step 2. Do NOT extract it into a `run-shell` script for the mouse path
(queued mouse-release dismisses it).

### 2. Keyboard mirror of the pane menu — `dot_config/tmux/executable_menu-pane.sh`

Add the matching entry to the `rows=(…)` array (near `"Enter copy mode" "[" …`, line 36),
keeping keys/order identical to the inline mouse menu:

```
"Copy pane path" y "set-buffer -w '#{session_name}:#{window_index}.#{pane_index}' ; display-message 'Copied pane path: #{session_name}:#{window_index}.#{pane_index}'"
```

(This script is the `prefix + M-p` keyboard equivalent.)

### 3. Prefix keybinding — `dot_config/tmux/keybindings.conf.tmpl`

Add a direct binding alongside the capture/clipboard helpers (the `prefix + y/Y/C-y`
cluster, ~lines 170–212). Recommend `prefix + P` (capital P):

```
# Copy current pane path (session:window.pane) to clipboard
bind P run-shell "tmux set-buffer -w \"#{session_name}:#{window_index}.#{pane_index}\" ; tmux display-message \"Copied pane path: #{session_name}:#{window_index}.#{pane_index}\""
```

Before finalizing the key: `grep -nE 'bind(-key)?[^-]*[[:space:]]P([[:space:]]|$)'
dot_config/tmux/keybindings.conf.tmpl` to confirm `P` is unused (lowercase `p` =
previous-window default; capital `P` is expected free). Fall back to another free letter
if it clashes.

### 4. Shell function — new file `dot_config/shell/63_tmux_path.sh`

Next free slot in the tmux cluster (`60_tmux_status.sh`, `61_tmux_summary.sh`,
`62_agent_wakeup.sh`). POSIX, sourced by both shells. Follow the `60_tmux_status.sh`
header style (source-path comment + doc pointer + `command -v tmux >/dev/null 2>&1 ||
return 0` guard).

Behavior of `tpath`:
- Guard: if not inside tmux (`[ -z "${TMUX:-}" ]`), print a hint to stderr and return 1.
- Single query, tab-separated:
  `tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}\t#{pane_id}\t#{pane_current_path}'`
- Copy **only the target** to the clipboard via `tmux set-buffer -w -- "$target"`
  (consistent with the menu/keybinding; OSC 52 bridge honors `set-clipboard on`).
- Print to stdout for reference (pipe-friendly):
  ```
  target : main:2.1
  pane_id: %5
  cwd    : /Users/you/project
  ```
- Emit "copied" confirmation to **stderr** (so stdout stays clean for piping, e.g.
  `tpath | head -1`).

Rationale for `set-buffer -w` over the `_cpx_to_clipboard`/`x copy` backends: the
function is guaranteed to run inside tmux (guarded), so tmux's own OSC 52 bridge is the
simplest cross-platform + SSH-safe path and matches the menu item exactly.

### 5. Docs — `docs/shells/aliases.md`

Add a row to the **`## Tmux Integration`** section table (starts line 729), 4-column
format `| Command | Type | Source File | Description |`:

```
| `tpath` | function | `dot_config/shell/63_tmux_path.sh` | Print (`target`/`pane_id`/`cwd`) + copy the current pane's `session:window.pane` target to the clipboard — for reconnecting or telling an agent which pane to act on. |
```

### 6. tmux cheatsheet (if the new binding should be discoverable)

Add `prefix + P` and the "Copy pane path" menu item to `dot_config/tmux/cheatsheet.md`
in the copy/clipboard section, matching how `prefix + y/Y` are listed. Optional but
keeps the popup cheatsheet accurate.

## Cross-file rules honored

- **Menu dual-write** (inline `MouseDown3Pane` ↔ `menu-pane.sh`) — mandatory per the
  inline comment + pitfalls/tmux-submenu-flash-and-bottom-right.md. Both edited in steps
  1 & 2.
- **CLAUDE.md**: "Alias / shell function in `dot_config/{shell,zsh,bash}/`" → row in
  `docs/shells/aliases.md` (step 5).
- **CLAUDE.md**: keybinding change → cross-check namespace and update
  `docs/shells/keybindings.md` if it documents prefix bindings; add to cheatsheet
  (step 6). This is a `prefix + P` binding (not a root `Ctrl-`/`Alt-` binding), so it
  cannot shadow inner apps — low collision risk, but still grep-verify `P` is free.

## Verification (end-to-end)

1. Render + apply: `chezmoi diff dot_config/tmux/ dot_config/shell/63_tmux_path.sh`,
   then `chezmoi apply`.
2. Reload tmux config: `tmux source-file ~/.config/tmux/tmux.conf` (should report no
   parse errors — display-menu is unforgiving of quoting; see
   pitfalls/tmux-display-menu-silent-parse-failure.md).
3. **Right-click** a pane → choose "Copy pane path" → confirm the status line shows
   `Copied pane path: <sess>:<win>.<pane>` and paste (`prefix + ]` or system paste)
   yields the correct target.
4. **Keyboard menu**: `prefix + M-p` → "Copy pane path" behaves identically.
5. **Prefix binding**: `prefix + P` → same confirmation + clipboard content.
6. **Shell function**: open a new shell, run `tpath` → verify the 3 stdout lines, the
   stderr "copied" note, and that the clipboard holds only `session:window.pane`. Test
   `tpath | head -1` pipes cleanly. Run under bash too (`bash -c 'source
   ~/.config/shell/63_tmux_path.sh; tpath'`) to confirm POSIX-safety.
7. Verify the pane menu still fits (it grows by 1 row) — retest at terminal heights ~14
   / 22 / 60 per the display-menu height-fit rule (menu is inline, not tiered, so this
   is just a sanity check that it isn't silently suppressed on short terminals).
