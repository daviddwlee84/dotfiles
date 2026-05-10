# tmux pane bottom half is blank / truncated inside Alacritty

**Symptoms** (grep this section):

- Inside Alacritty (macOS), tmux status bar renders at the top, the prompt
  shows a few lines of output, then the **entire bottom of the window is
  empty** (terminal background colour, no content, no cursor visible)
- The "blank zone" persists across new commands — running `ls` or `env`
  emits 2-3 lines just below the status bar, then everything below stays empty
- `tmux list-clients` reports a sensible size (e.g. `175x46`, `177x48`) — tmux
  *thinks* it has the full pane height
- `tmux display -p '#{pane_width}x#{pane_height}'` agrees with `list-clients`
- `echo $LINES; echo $COLUMNS` inside the shell also agrees
- Resizing the Alacritty window (drag corner, or Cmd+= zoom + back) suddenly
  fills the entire pane with content / scrollback — the truncation goes away
- Trigger: the affected Alacritty window has **macOS native tabs** at the top
  (Cmd+T inside Alacritty creates a native tab strip; usually 2+ tabs visible)
- Inside tmux: `$TERM = tmux-256color` (correct), `COLORTERM = truecolor`
  (correct), gradient test paints smoothly — **NOT** a colour / TERM bug

**First seen**: 2026-05
**Affects**: Alacritty (any recent macOS build) + tmux 3.x + macOS native tabs
combo, **specifically when the Alacritty window is maximised** (green-button
zoom, not Cmd+Ctrl+F full-screen). Resizing to any smaller size un-sticks it;
re-maximising reliably reproduces it. Not seen with Ghostty. Not seen on Linux.
**Status**: confirmed (2026-05-10) — resizing the Alacritty window to any
non-maximised size un-sticks the symptom immediately; re-maximising repros it
deterministically. This proves it's PTY size desync **specific to the
maximised + tab-strip state** (most likely Alacritty reports the full screen
height to the PTY but the tab strip eats some of it from the visible
viewport, so tmux paints below the visible edge). Permanent workaround =
avoid Alacritty native tabs (consolidate to one Alacritty window + use tmux
windows instead, or switch to Ghostty); quick un-stick = un-maximise.

## Symptom

Screenshot from 2026-05-10 (full-screen Alacritty on macOS):

- Alacritty title bar
- macOS native tab strip with 9 tabs labelled "Alacritty" / "OC | Claude ke..."
- Inside the active tab: tmux status bar at top with 9 windows
  (`chezmoi / agents / git / edit / nvim / specstory / node / node / zsh`)
- 2 lines of command output (`=== TMUX env vars ===` / `COLORTERM=truecolor`)
- **Then the entire rest of the window — roughly the bottom 80% — is blank**

What tmux reports (verbatim during the incident):

```
$ tmux list-clients
/dev/ttys000: chezmoi [177x48 xterm-256color] (attached,UTF-8)
/dev/ttys004: vibe/Chinese-Chess_Xiangqi [175x46 xterm-256color] (attached,UTF-8)
/dev/ttys007: vibe/chezmoi [175x46 xterm-256color] (attached,focused,UTF-8)

$ tmux display -p '#{client_width}x#{client_height} pane=#{pane_width}x#{pane_height}'
175x46 pane=175x45     # 1 row eaten by status bar — correct
```

So tmux thinks it has 45 rows of pane to paint into. But the user's eye sees
maybe 5 rows of content area before the void. The desync is between
"how big tmux thinks the PTY is" and "how much of the Alacritty window
actually paints glyphs".

## Confounding red herring: TERM / truecolor diagnosis

ChatGPT (and similar diagnostic flows) will misread `tmux list-clients`
showing `xterm-256color` as evidence that "TERM is wrong inside tmux" and
recommend changing `default-terminal` to `tmux-256color` + adding
`terminal-features ',xterm-256color:RGB'`. Verify before applying:

```sh
# Inside the affected tmux pane:
echo "$TERM"                                 # Should be tmux-256color (correct)
tmux show -g default-terminal                # Should be tmux-256color (correct)
echo "$COLORTERM"                            # Should be truecolor (correct)
```

If those three are already correct, the `xterm-256color` you saw in
`list-clients` is the **outer terminal's** TERM (Alacritty / Ghostty
advertise themselves as `xterm-256color` to the OS). That's expected and
unrelated to the truncation. **Do not change `default-terminal` chasing this
red herring** — it's already right in this repo
([`dot_config/tmux/common.conf.tmpl:129`](../dot_config/tmux/common.conf.tmpl)).

## Root cause (confirmed via resize-fix; still no upstream issue ID)

Confirmed mechanism: **Alacritty's macOS native tab implementation reports
the full screen height to the per-tab PTY when the window is maximised, but
the on-screen viewport is shorter because the tab strip eats some rows from
the top.** tmux trusts the PTY size and paints the full 46 rows; the bottom
N rows are below the visible window edge, so they appear blank.

Confirmation (2026-05-10):

1. On a stuck full-screen Alacritty window with the 9-tab strip: dragging
   the window corner by any amount immediately filled the blank zone with
   content (delivers a fresh, correct SIGWINCH for the smaller viewport).
2. **Re-maximising the window after the fix reliably reproduced the bug.**
   This rules out "one-time SIGWINCH miss after tabs were added" and points
   to a maximise-state-specific accounting bug: every transition INTO
   maximise sets the PTY size wrong; every transition OUT sets it right.

Adjacent contributing factors that should be ruled in/out separately:

1. **`window-size latest` + multiple attached clients of different sizes**
   (3 clients of 175x46 / 175x46 / 177x48 in this incident) — tmux uses the
   most-recently-attached client's size, but if SIGWINCH never fires, the
   "latest" stays stale.
2. **`aggressive-resize off`** (current default in
   [`common.conf.tmpl:128`](../dot_config/tmux/common.conf.tmpl)) — when the
   focused client's size changes, tmux only redraws the focused window, not
   inactive ones. With macOS tab switching this could leave inactive tabs'
   tmux windows at a stale size.
3. **Alacritty `[window] padding.x = 10, padding.y = 10` + `opacity = 0.7` +
   `blur = true`** in [`alacritty.toml`](../dot_config/alacritty/alacritty.toml) — the blurred translucent backdrop makes the blank zone visually larger
   and more obvious, but isn't the cause.

None of (1)/(2)/(3) reliably reproduces in isolation; the macOS-native-tabs
combo is the trigger.

## Workaround (in order of preference)

### A. Don't use Alacritty's macOS native tabs (recommended)

The 9-tab strip in the screenshot is wasteful anyway: tmux is already a
multiplexer with 9 windows visible in the status bar. Stacking Alacritty
native tabs on top duplicates the function and causes this bug.

Use one Alacritty window per role (or just one window total), and use tmux
windows / sessions for everything else.

### B. Force a SIGWINCH manually when the symptom appears (fast un-stick)

**Confirmed working (2026-05-10):** drag the Alacritty window corner by any
amount, OR un-maximise the window. The blank zone fills with content
immediately. **Do not re-maximise** afterwards — that re-triggers the bug
deterministically (see Root cause).

```sh
# Other ways to deliver SIGWINCH if dragging is awkward:

# Cmd+= then Cmd+- to zoom font and back — also triggers SIGWINCH
# Cmd+Ctrl+F (toggle full-screen) twice — note macOS full-screen is a
#   different mode than green-button maximise; full-screen does NOT
#   reproduce this bug, only the green-button "zoom" maximise does
# Detach and reattach: Ctrl+B d, then `tmux attach`

# If you're inside tmux and want to verify the size BEFORE/AFTER:
tmux display -p '#{client_width}x#{client_height} pane=#{pane_width}x#{pane_height}'

# tmux's own refresh commands do NOT fix this — they redraw the buffer using
# the (still-stale) cached size, so the bottom stays blank:
#   tmux refresh-client -S    # status only
#   tmux refresh-client -s    # stdin/pane redraw
# Use the OS-level resize trigger above, not tmux refresh.
```

### C. Switch to Ghostty as the primary terminal

This repo already configures Ghostty in
[`dot_config/ghostty/config`](../dot_config/ghostty/config) (including
`macos-option-as-alt = left` for tmux Alt-key bindings) and tmux already
declares `ghostty*:clipboard` in
[`common.conf.tmpl:164`](../dot_config/tmux/common.conf.tmpl). Ghostty's
macOS-native-tab implementation handles SIGWINCH correctly in practice. No
config change needed beyond launching Ghostty instead.

### D. (Optional) Turn on `aggressive-resize` if you want stale clients to redraw

```diff
- setw -g aggressive-resize off   # current implicit default
+ setw -g aggressive-resize on
```

This doesn't fix the SIGWINCH bug itself — it just helps when *another*
client of a different size is attached and you switch focus between them.
Apply only if you confirm this is helpful in your workflow.

## Prevention

1. **Don't combine Alacritty's macOS native tabs with tmux.** They are
   mutually-exclusive multiplexers; using both stacks the size-tracking
   responsibilities and exposes this Alacritty bug.
2. **When debugging "tmux pane is wrong size" symptoms,** check the
   discrepancy between `tmux display -p '#{pane_height}'` and what your eye
   sees, *before* changing any TERM / colour config. Eye ≠ tmux number means
   SIGWINCH desync; eye = tmux number means it's a content / theme /
   transparent-background issue (ChatGPT's secondary diagnosis path).
3. **Do not change `default-terminal` / `terminal-features` to chase TERM
   red herrings** — see [docs/tools/tmux/](../docs/tools/tmux/) and
   [common.conf.tmpl:125-168](../dot_config/tmux/common.conf.tmpl) for the
   intentional config.

## Related

- [`dot_config/tmux/common.conf.tmpl`](../dot_config/tmux/common.conf.tmpl) —
  current `default-terminal` / `terminal-features` / `window-size` /
  `aggressive-resize` settings (all already correct; not the cause)
- [`dot_config/alacritty/alacritty.toml`](../dot_config/alacritty/alacritty.toml) —
  Alacritty config (no native-tabs setting; tabs are created via Cmd+T at runtime)
- [`dot_config/ghostty/config`](../dot_config/ghostty/config) — drop-in
  alternative terminal, repo-managed
- [`pitfalls/tmux-display-menu-silent-fail.md`](tmux-display-menu-silent-fail.md) —
  another "menu doesn't fit terminal height" tmux trap; same family of "the
  terminal is smaller than tmux thinks" issues but unrelated mechanism
- Sibling pitfall about extended-keys / paste:
  [`pitfalls/tmux-extended-keys-always-paste.md`](tmux-extended-keys-always-paste.md)
- Upstream Alacritty: search issues for "macos tab sigwinch" / "macos native
  tab pty resize" — open at time of writing, no specific issue ID confirmed
- `man tmux` → `refresh-client` (`-S` status only, `-s` stdin/pane redraw)
