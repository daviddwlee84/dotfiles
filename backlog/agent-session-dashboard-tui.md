# Native agent-session dashboard TUI

**Status**: P? design backlog (2026-06)
**Effort**: XL
**Related**: `dot_config/television/executable_agent-wakeup.py`, `dot_config/television/executable_agent-sessions.py`, `dot_config/tmux/executable_tmux-session-summary.py`, [docs/tools/agent-panes-discovery.md](../docs/tools/agent-panes-discovery.md), [backlog/agent-quota-auto-loop.md](agent-quota-auto-loop.md)

## Context

`tv agent-panes`, `tv agent-sessions`, and `tv agent-wakeup` are useful v1
surfaces, but they are still separate pickers. The user wants to keep
iterating toward one "agent control center" where the important state is
visible at a glance:

- which agent panes are live,
- which are active / idle / waiting for user / quota-blocked,
- reset timers and scheduled `continue` actions,
- transcript / SpecStory links,
- tmux session/window/pane location,
- direct actions like jump, continue, schedule, cancel, copy session name,
  kill pane, or open transcript.

The likely end state may not be a TV channel plus pueue. TV is excellent for
picker workflows, but a dashboard with timers, repeated updates, per-row
state machines, and richer actions may want a native TUI.

## Scope Candidates

### Minimal native TUI

- One table of live agent panes.
- Side preview with `tmux capture-pane`.
- Actions: jump to pane, send `continue`, schedule one wakeup, cancel wakeup.
- Reuse existing `agent-wakeup` detection and pueue scheduling backend.

### Full dashboard

- Live panes plus stored sessions in one UI.
- Pane status classifier: active, idle, waiting user, wait quota, scheduled,
  finished, failed, unknown.
- Countdown timers for quota reset and scheduled wakeups.
- Per-agent adapters for Claude/Codex/OpenCode/Cursor storage and status.
- Transcript / SpecStory preview with jump-to-file.
- Optional auto-repeat quota loop per pane.
- tmux actions: jump pane, copy pane target/session name, kill pane/session,
  rename, clear workmux status.

### Supervisor-backed TUI

- Long-running daemon owns state polling and scheduling.
- TUI is only a client, so it can restart without losing timers.
- Scheduler may use pueue initially, but could migrate to an internal queue
  if per-pane state and repeat policies become first-class.

## Architecture Options

| Option | Shape | Pros | Cons |
|---|---|---|---|
| A. Extend TV channels | Keep adding `tv agent-*` channels and shell helpers | Fast, low dependency, follows current repo patterns | Hard to model timers/state machines; fragmented UX |
| B. Python Textual/Rich TUI | Single Python app using existing helper code | Fast to build; good tables/previews/keybindings | Adds a heavier runtime; packaging/versioning needs care |
| C. Rust Ratatui TUI | Native binary with tmux/pueue integration | Fast, distributable, robust TUI ergonomics | Larger implementation cost; duplicates Python discovery unless refactored |
| D. Go Bubble Tea TUI | Single static-ish binary, good terminal UX | Good deployment story | Another stack in repo; still needs adapters |
| E. Daemon + thin TUI | Separate state/scheduler service plus UI client | Best for resilient timers and auto-repeat | Highest complexity; needs lifecycle management |

## Current Decision

`2026-06-19`: keep the shipped v1 on TV + pueue for immediate one-off wakeups,
but track the native TUI as a separate backlog item. Do not force the
auto-continue loop design into the TV channel if the feature naturally wants
a richer dashboard.

## Open Questions

- Is the primary UI a tmux popup, a standalone terminal app, or both?
- Should the scheduler remain pueue-backed for persistence, or should a
  daemon own timers directly?
- Which implementation stack fits the repo best: Python Textual/Rich, Rust
  Ratatui, or Go Bubble Tea?
- Should this become a general `agent-session` command, or live under an
  existing namespace like `fleet` / `tmux` / `tv`?
- What is the first safe autonomous action beyond one-off `continue`?

## References

- [docs/tools/agent-panes-discovery.md](../docs/tools/agent-panes-discovery.md)
- [docs/tools/pueue.md](../docs/tools/pueue.md)
- [backlog/agent-quota-auto-loop.md](agent-quota-auto-loop.md)
