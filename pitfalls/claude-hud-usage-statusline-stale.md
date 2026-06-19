# Agent wakeup reports quota wait from stale Claude HUD usage line

**Symptoms** (grep this section): `agent-wakeup status` reports
`WAIT_QUOTA` or a future reset time even though Claude Code already accepted
`continue`; tmux pane bottom bar still shows `Usage ... Limit reached`; pane
shows `Scampering` / active work while the detector says quota-blocked;
`Context ... | Usage ... Limit reached (resets ...)` appears in captured pane
scrollback.
**First seen**: 2026-06-19
**Affects**: Claude Code panes using the `claude-hud` statusLine plugin plus
tmux capture-based quota detectors
**Status**: fixed in `agent-wakeup` by ignoring Claude HUD usage lines

## Symptom

A Claude Code pane can be working normally after quota reset, while the bottom
status area still contains a line like:

```text
Context ... | Usage ... Limit reached (resets 1h 22m)
```

If a quota detector scans the last screenful of tmux output for `Limit reached`,
it may classify the pane as `WAIT_QUOTA` even though the agent is active and
has already accepted `continue`.

In the first incident, `vibe/libkdc-simple-demo` accepted a smart
`agent-wakeup send-now --auto`, printed `Scampering`, and continued running.
The old HUD usage line remained visible long enough for the detector to keep
reporting quota wait until the parser was fixed.

## Root cause

`claude-hud` is a Claude Code `statusLine` command, not a live agent-state
protocol. Claude Code launches the plugin for rendering; the plugin reads
stdin/transcript/cwd and fetches usage through its own cached API layer.

The installed plugin implementation stores usage in:

```text
~/.claude/plugins/claude-hud/.usage-cache.json
```

The source in the plugin cache documents that the HUD runs as a new process
each render and therefore uses a file-based cache. It also preserves
`lastGoodData` during usage API rate-limited periods. That is correct for a
human status bar, but it means `Usage ... Limit reached` is not proof that
the current pane is blocked on `/rate-limit-options`.

## Fix

The repo-side detector now strips ANSI and ignores Claude HUD usage lines
before applying quota regexes:

- `dot_config/television/executable_agent-wakeup.py`
- Commit: `4c0bf51f Ignore Claude HUD quota status in wakeup detector`

Real quota/menu detection should come from fresh agent output such as:

```text
You've hit your session limit
/rate-limit-options
What do you want to do?
Stop and wait for limit to reset
```

Do not treat `Context ... | Usage ... Limit reached` or `Usage ... Limit
reached` from the HUD as an authoritative pane state.

## Diagnostics

```bash
# See what the wakeup detector thinks now.
agent-wakeup status

# Inspect the pane tail directly.
tmux capture-pane -p -S -80 -t %39 | tail -n 60

# Inspect the HUD usage cache without dumping credentials.
jq '{timestamp, data: {planName: .data.planName, fiveHour: .data.fiveHour,
    sevenDay: .data.sevenDay, fiveHourResetAt: .data.fiveHourResetAt,
    sevenDayResetAt: .data.sevenDayResetAt, apiError: .data.apiError}}' \
  ~/.claude/plugins/claude-hud/.usage-cache.json
```

If the pane is actively thinking/running but only the HUD line mentions
`Limit reached`, the pane is not quota-blocked.

## Prevention

- For tmux capture parsers, separate user-facing status bars from agent
  conversation/tool output.
- Prefer explicit state markers (`/rate-limit-options`, quota error text,
  process/session status files) over broad `limit reached` regexes.
- Re-check a pane immediately before sending scheduled input, and abort if the
  explicit quota marker is gone.

## Related

- [docs/tools/agent-panes-discovery.md](../docs/tools/agent-panes-discovery.md)
- [backlog/agent-quota-auto-loop.md](../backlog/agent-quota-auto-loop.md)
- [backlog/agent-session-dashboard-tui.md](../backlog/agent-session-dashboard-tui.md)
