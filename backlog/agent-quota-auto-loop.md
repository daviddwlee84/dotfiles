# Agent quota auto-continue loop

**Status**: P? deferred (2026-06)
**Effort**: L
**Related**: `dot_config/television/executable_agent-wakeup.py`, `dot_config/television/cable/agent-wakeup.toml`, `dot_config/shell/62_agent_wakeup.sh`, [docs/tools/agent-panes-discovery.md](../docs/tools/agent-panes-discovery.md), [backlog/agent-session-dashboard-tui.md](agent-session-dashboard-tui.md)

## Context

Claude Code, Codex, OpenCode, and similar agent TUIs regularly stop on
quota/rate/session limits, show a reset time, and require a later `continue`
plus Enter. The first shipped scope is explicit:

- `tv agent-wakeup` shows live panes, quota/reset status, and queued wakeups.
- `agent-continue-at` schedules one `continue` for a selected pane through
  pueue.
- Scheduled sends re-check the pane for a quota marker before typing, unless
  forced.

That handles the immediate "I'm going to sleep; continue this once after
reset" use case without building a daemon that writes into panes
autonomously.

## Deferred problem

The broader request is a supervisor that can:

1. discover all live agent panes,
2. detect quota waits,
3. schedule a `continue` after reset,
4. repeat when the same session hits another quota window,
5. stop when the agent truly finishes or exits for a non-quota reason.

Step 5 is the hard part. The supervisor must distinguish "quota-blocked and
safe to continue later" from "agent finished, waiting for user review",
"agent failed", "agent is asking a real question", and "pane contents changed
because the user took over".

## Options

| Option | Shape | Pros | Cons |
|---|---|---|---|
| A. Explicit dashboard + one-off scheduler | Current `tv agent-wakeup` / `agent-continue-at` | Low risk; no daemon; user controls every write | Does not repeat automatically after the next quota hit |
| B. Polling supervisor over tmux capture | Background process scans panes, schedules pueue tasks, and reschedules after each wake | Covers the whole sleep/overnight use case | Needs a reliable pane-state classifier; false positives type into live panes |
| C. Per-agent adapters | Claude/Codex/OpenCode-specific parsers or hooks | Better semantics than generic regex | More maintenance; every agent UI update can break parsing |
| D. Agent-side hooks/protocol | Use official events if agents expose quota/reset/status in machine-readable form | Best long-term reliability | Not currently portable across agents |

## Current decision

`2026-06-19`: ship option A first. It gives immediate operational value and
creates shared primitives (`agent-wakeup status/schedule/send-now/cancel`,
pueue labels, pane capture parsing) without committing to a fragile autonomous
loop.

Revisit B/C only after enough real pane captures accumulate to design a
state classifier with known failure modes. Any auto-loop must default to
safe-abort when the pane no longer contains an explicit quota marker.
Known classifier trap: do not treat Claude HUD `Usage ... Limit reached`
statusLine output as live quota state; see
[claude-hud-usage-statusline-stale.md](../pitfalls/claude-hud-usage-statusline-stale.md).

The broader "one screen for all agent sessions, quota state, timers, and
actions" product direction is tracked separately in
[agent-session-dashboard-tui.md](agent-session-dashboard-tui.md). Do not
force that larger design into TV+pueue if a native TUI becomes the better
shape.

## Open questions

- Should the auto-loop be a pueue task per pane, a long-running `launchd` /
  tmux daemon, or a TUI-owned timer?
- What is the minimum state vocabulary? Candidate states: `active`,
  `wait_quota`, `wait_user`, `finished`, `failed`, `unknown`.
- Should the dashboard allow opt-in "auto-repeat for this pane" as a middle
  ground before a global supervisor?
- Can workmux/Claude hooks expose enough status to avoid capture-pane parsing
  for at least Claude Code?

## References

- [docs/tools/agent-panes-discovery.md](../docs/tools/agent-panes-discovery.md)
- [docs/tools/pueue.md](../docs/tools/pueue.md)
- [pitfalls/claude-hud-usage-statusline-stale.md](../pitfalls/claude-hud-usage-statusline-stale.md)
- [pitfalls/tv-channel-bare-braces-break-substitution.md](../pitfalls/tv-channel-bare-braces-break-substitution.md)
