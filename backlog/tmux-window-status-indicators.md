# tmux window status indicators (running / idle / error)

**Status**: option A shipped (2026-04) · **discovery primitive shipped 2026-04** (`tv agent-panes` + recon — see `docs/tools/agent-panes-discovery.md`) · option C still scoped, blocked on user signal
**Effort**: ~~S (option A)~~ done · S (option B) · M (option C)
**Related**: `TODO.md` · `dot_config/tmux/common.conf` (monitor-activity block) · `dot_config/tmux/theme.catppuccin.conf` · `dot_claude/modify_settings.json` + `dot_claude/hooks/executable_notify.sh.tmpl` · `dot_config/opencode/modify_opencode.json.tmpl` + `.chezmoitemplates/agents/opencode.overlay.json` · `docs/tools/agent-overlays.md` · `dot_config/television/executable_agent-sessions.py` `_panes()` mode (PID→pane resolver — reusable when option C lands)

## Context

2026-04, while watching a tmux status bar with two `opencode` panes side by side
(`0 chezmoi · 1 opencode · 2 opencode · 3 zsh · 4 zsh`), the question came up:
can window tabs show whether each agent is currently working, idle waiting for
input, or errored out? The current Catppuccin window list shows only index +
process name, which makes it impossible to tell at a glance which `opencode`
needs my attention.

This generalises beyond LLM agents — the same primitive ("tag a window with a
state read from a file or hook") would be useful for long-running builds, test
watchers, `pueue` queues, etc.

## Decision

`2026-04 option A shipped`. Three lines added to `dot_config/tmux/common.conf`
(`monitor-activity on`, `monitor-bell on`, `monitor-silence 0` with
`visual-* off`). Catppuccin's `window-status-format` already renders
`#{window_flags}`, so non-current windows that produce output now get a `#`
glyph and bell-emitting windows get `!`. `monitor-silence` is left at `0`
(disabled) on purpose: agent panes have a perpetual spinner so it would never
fire usefully and would just add noise on regular shells.

`2026-04 option C scoped, deferred`. Concrete plan documented below; not
implemented because the user has not yet signalled they want the
`status-interval 1` cost or the cross-machine hook maintenance burden. Pick
this up when at least one of these is true: (a) option A's `#` flag proves
insufficient in real use, (b) the user wants per-window error/idle distinction
strong enough to justify the polling cost, or (c) we already need a per-pane
state file for another feature (e.g. tmux statusline showing pueue queue
depth).

`2026-04 option B (tmux-nerd-font-window-name) skipped`. Pure aesthetic; the
`#W` already shown in Catppuccin tabs is readable enough, and adding a Python
polling plugin for icons-only ROI is poor.

---

## Option C implementation plan (when revisited)

### Architecture

- **State file**: `${XDG_RUNTIME_DIR:-/tmp}/tmux-agent-state-$UID/$TMUX_PANE`
  (per-pane, single-line: `running` / `idle` / `error` / blank).
  `$UID` namespacing avoids multi-user collision on shared hosts; `XDG_RUNTIME_DIR`
  is preferred on Linux (tmpfs, auto-cleaned at logout) with `/tmp` fallback for
  macOS.
- **Stale cleanup**: tmux `pane-exited` hook removes the file on pane close.
  Belt-and-suspenders: a `find $dir -mmin +60 -delete` swept by the same
  format `#()` script before reading.
- **tmux read side**: extend `@catppuccin_window_text` /
  `@catppuccin_window_current_text` (NOT `window-status-format` — see warning
  in `theme.catppuccin.conf:38-41`) with a `#(...)` substitution that
  `cat`s the active pane's state file and maps to a glyph. `status-interval 1`
  for responsive updates (current default is 15).
- **Glyph mapping**: `running → ⚙` · `idle → 💤` · `error → ❌` · empty → no
  glyph (regular shell pane). Use Nerd Font fallbacks if emojis don't render
  cleanly in Catppuccin's text style.

### Claude Code side (low cost — extend existing infra)

The repo already maintains `~/.claude/hooks/notify.sh` via
`dot_claude/hooks/executable_notify.sh.tmpl` and registers it in
`hooks.Notification` + `hooks.Stop` through the hook-aware merger in
`dot_claude/modify_settings.json`. Adding state-file writes is additive:

1. Extend `executable_notify.sh.tmpl` to `echo` to the state file on top of
   the existing apprise call. `Stop` → `idle`, `Notification` (waiting for
   user input / permission) → `idle`, errored events → `error`. Use
   `${TMUX_PANE:-}` guard so the script is a no-op outside tmux.
2. Add `UserPromptSubmit` + `PreToolUse` to the overlay's `hooks` block so
   they also point at `notify.sh`; the hook script branches on
   `$event` (`hook_event_name` field) and writes `running`. The merger
   already handles multi-entry-per-event coexistence with CodeIsland (see
   `AGENTS.md` → "modify_/create_ prefix semantics" + the hook-aware merger
   doc).
3. **No new files** — same script, two extra `case` branches plus three new
   overlay hook entries. Risk: low. Test surface: one `chezmoi apply`, then
   one Claude session per machine to verify.

### OpenCode side (higher cost — new surface)

OpenCode does **not** support shell-command hooks. It uses JS/TS plugins
(`~/.config/opencode/plugins/*.{js,ts}`). Events confirmed available
(2026-04): `session.idle`, `session.error`, `session.created`,
`session.status`, `tool.execute.before`, `tool.execute.after`, etc. The docs
explicitly show an `osascript` notification example using `session.idle`.

Implementation:

1. New file `dot_config/opencode/plugins/executable_tmux-pane-state.js` (or
   `.ts`) — must be `executable_` so chezmoi sets +x; use `.js` to avoid
   needing a `package.json` + `bun install` cycle for a 20-line plugin.
2. Plugin reads `process.env.TMUX_PANE` once at init; if unset, becomes
   no-op. Otherwise subscribes to `session.idle`/`session.error`/
   `tool.execute.before` and writes the state file.
3. Caveat: opencode's plugin API runs once per *opencode process*, not per
   pane invocation — `TMUX_PANE` is captured from the launching shell's env
   and stays valid for the lifetime of that opencode process, which is what
   we want.

Risk drivers:

- OpenCode plugin API surface is less stable than Claude's hook surface
  (Claude hooks are documented as a stable user-facing feature; opencode
  plugins are still under active development per their changelog).
- New file in `dot_config/opencode/` means a new chezmoi-managed surface;
  needs an entry in `docs/tools/agent-overlays.md` describing the plugin's
  intent (so future-us doesn't `rm` it as orphaned).
- If OpenCode ever sandboxes plugin filesystem access or moves to a
  permission model, this plugin would break silently. Mitigation: log via
  `client.app.log({level: 'debug', ...})` so failures surface in
  `opencode debug logs`.

### Order of work (if approved)

1. Ship Claude side first (additive to existing `notify.sh`, lowest risk).
   Verify the `#()` substitution + Catppuccin override actually renders
   correctly before adding the OpenCode plugin.
2. Ship OpenCode plugin second (new surface).
3. Document both in `docs/tools/agent-overlays.md` → new section "Tmux pane
   state integration".

### Why not just reuse `Piebald-AI/claude-code-statusline-tmux`

Reviewed the project shape (verify before committing — repo may have evolved):
it's Claude-only and bundles its own status-line theme. We already own a
themed status line (Catppuccin) and need OpenCode coverage too. Reusing it
would mean either (a) running both their status line and ours (visual mess),
or (b) extracting their hook-script approach, which is what option C above
describes anyway. Net: take the *idea* (per-pane state file written by
hooks), implement minimally inside our existing overlay infrastructure.

---

## Original analysis (preserved for reference)

### Investigation

tmux has three native primitives for window state:

1. **`window_flags`** (`*` current, `-` last, `#` activity, `~` silence, `!`
   bell, `Z` zoomed). Already auto-included in Catppuccin's
   `window-status-format`. Driven by `monitor-activity` / `monitor-silence` /
   `monitor-bell` per-window settings.
2. **`pane_current_command`** — the foreground process name in the active pane.
   Useful to branch in `window-status-format` (`#{?#{==:#{pane_current_command},node},⚙ ,}`)
   but every JS-based agent shows up as `node`, so it can't distinguish
   `opencode busy` from `opencode idle`.
3. **External state via `#()`** — `status-interval` re-evaluates `#(shell-cmd)`
   substitutions; combined with a per-pane state file written by hooks, this
   gives true semantic state.

LLM agents always have a spinner running while waiting for the model, so from
tmux's POV the pane is *always* producing output. `monitor-silence` therefore
cannot detect "agent is idle waiting for user prompt" — only option 3 can.

Both target agents expose hooks suitable for option 3:

- **opencode**: `session.idle`, `session.error`, plus tool-call lifecycle hooks
  (verify exact event names against `~/.config/opencode/opencode.json` schema
  before relying on them — opencode hook surface evolves).
- **Claude Code**: `SessionStart`, `Stop`, `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`. The repo already wires Claude hooks via the
  `dot_claude/modify_settings.json` jq-overlay (see `AGENTS.md` →
  "`modify_` and `create_` prefix semantics" + the CodeIsland coexistence note).

`$TMUX_PANE` is exported into every pane process and is the natural key for the
state file (`/tmp/tmux-state-$UID/$TMUX_PANE`).

## Existing prior art

- [`Piebald-AI/claude-code-statusline-tmux`](https://github.com/Piebald-AI/claude-code-statusline-tmux) —
  Claude Code → tmux status integration. Closest existing implementation; worth
  reading their hook script + `status-interval` setup before rolling our own.
- [`tmux-plugins/tmux-prefix-highlight`](https://github.com/tmux-plugins/tmux-prefix-highlight) —
  same `#()` polling pattern, different signal (prefix mode). Good minimal
  reference.
- [`ofirgall/tmux-window-name`](https://github.com/ofirgall/tmux-window-name) —
  Python plugin that auto-renames windows based on running process (git repo
  name, `vim file.py`, etc.). Solves a different problem (better names) but
  could be combined with this work.
- [`joshmedeski/tmux-nerd-font-window-name`](https://github.com/joshmedeski/tmux-nerd-font-window-name) —
  process → nerd font icon mapping. Could give `opencode` / `claude` distinct
  glyphs as a zero-effort first step.
- General `r/tmux` discussions on "idle indicator" / "build status in tmux
  status bar" — mostly hand-rolled `#()` + state file patterns; no canonical
  plugin.

## Options considered

| Option | Effort | Effectiveness for LLM agents | Side effects |
|---|---|---|---|
| **A. Enable `monitor-activity` + `monitor-silence`** | S (3 lines in `common.conf`) | Low — agents stream constantly while thinking, so the `~` (silence) flag rarely fires when "really idle" (waiting for user prompt). The `#` (activity) flag *does* mark non-current windows that produced output, which is mildly useful. | None if `visual-activity off` / `visual-silence off`. With visuals on, message-line spam. |
| **B. Install `tmux-nerd-font-window-name`** | S (one TPM line + font check) | None — purely aesthetic; gives `opencode`/`claude` distinct icons but no state info. | Adds a Python dependency and a polling shell-out. May conflict with our explicit `#W` in `@catppuccin_window_text`. |
| **C. Hook-based per-pane state file** | M (hook scripts in opencode + claude config + tmux format override) | **High** — true semantic state (running / idle / error). Can pick emoji or colour per state. | Requires `~/.config/opencode/` hook surface to stabilise; needs cross-platform `/tmp` path with `$UID` to avoid multi-user collision; poll interval (`status-interval 1`) may marginally raise CPU. Must coexist with the Catppuccin plugin's pre-built `window-status-format` (cannot just `set -g window-status-format` without breaking the theme — need to override via `@catppuccin_window_text` template, which already supports `#{...}` substitutions). |

Combination is viable: A as zero-cost background, C as the real signal. B is
orthogonal and could be added later.

## Open questions / blockers

- **opencode hook event names**: confirm current schema in `opencode.json` —
  the events `session.idle` / `session.error` are claimed but unverified
  against the running version. Spike: enable a `session.*` echo hook locally
  for one day, log to `/tmp/opencode-hook-events.log`, see what actually
  fires.
- **Claude hook coexistence with CodeIsland**: the `modify_settings.json`
  merger preserves CodeIsland-injected hook entries (see `AGENTS.md`). Adding
  our own `Stop` / `UserPromptSubmit` entries must go through the same merger
  path so we don't ping-pong on every `chezmoi apply`. Verify the merger
  handles multiple entries per event.
- **State file lifecycle**: pane closes → stale file stays in `/tmp`. Options:
  (a) `tmux` `pane-exited` hook to `rm`; (b) periodic sweep of files older
  than N minutes whose `$TMUX_PANE` is no longer in `tmux list-panes`. (a) is
  cleaner.
- **Catppuccin format override mechanism**: `theme.catppuccin.conf` line 38-41
  warns explicitly *not* to set `window-status-format` directly because the
  plugin owns it. The supported extension point is `@catppuccin_window_text` /
  `@catppuccin_window_current_text` (already used for the zoomed-flag glyph).
  The state-file `#()` substitution must go inside those values, not as a
  separate `set -g window-status-format`.
- **Multi-pane windows**: `$TMUX_PANE` is per-pane but `window-status-format`
  shows per-window. Decision needed: show the "worst" state across panes,
  or only the active pane's state? Active-pane is simpler and matches what
  `pane_current_command` already does.
- **Exit-code 0 ≠ idle**: an opencode session that finishes cleanly should
  flip to "idle waiting", not "done/green". Hook ordering: `Stop` → write
  `idle`, not `done`.

## Decision

`2026-04 deferred — research only`. Implementation gated on:

1. Quick spike to confirm opencode hook event names.
2. User signal that they actually want the visual cost of a 1-second poll
   on every tmux client.

If revisited, default plan is option C with option A enabled as cheap
background. Skip option B unless we also want better default window naming
in general.

## References

- [Catppuccin tmux window text customisation](https://github.com/catppuccin/tmux#configuration) — `@catppuccin_window_text` accepts arbitrary format strings
- [tmux(1) `FORMATS` section](https://man.openbsd.org/tmux#FORMATS) — `#()` substitution semantics, `status-interval` interaction
- [`Piebald-AI/claude-code-statusline-tmux`](https://github.com/Piebald-AI/claude-code-statusline-tmux)
- [opencode hooks docs](https://opencode.ai/docs/hooks/) — verify event names before implementing
- [Claude Code hooks reference](https://docs.claude.com/en/docs/claude-code/hooks) — `Stop`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`
- Adjacent prior art: `pitfalls/tmux-display-menu-silent-fail.md` — reminder that tmux format strings fail *silently* when malformed, so test format changes incrementally
