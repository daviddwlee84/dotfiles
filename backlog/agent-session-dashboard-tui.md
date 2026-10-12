# Native agent-session dashboard TUI

**Status**: P? design backlog (2026-06; research updated 2026-09-25)
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

`2026-09-25`: capture the Sidecar Activity-style Herdr dashboard investigation
here; the user chose research only. No new dashboard, Sidecar plugin, CLI,
keybinding, status hook, or agent-control automation is authorized by this
backlog note. The broader dashboard remains **P? / XL**.

## 2026-09-25 — Sidecar Activity-style Herdr view

### Goal and existing pieces

Use Sidecar's Activity view as a visual reference for seeing Herdr agents by
status and jumping to the selected agent. This adds a Herdr-focused candidate
to the broader dashboard above; it does not replace its tmux, quota, scheduler,
or transcript research.

Herdr **0.9.1** already supplies the needed current-state data. One
`herdr api snapshot` response includes agents, workspaces, tabs, panes, and
layouts. Agent records carry `agent_status`, `terminal_title_stripped`,
`foreground_cwd`/`cwd`, `workspace_id`, `tab_id`, `pane_id`, `revision`, and
`state_change_seq`. Workspace/tab records provide display labels. Use that
API as the status source; a status board does not need per-pane process scans
or its own transcript-based classifier.

Existing repo surfaces to reuse:

- `dot_config/television/executable_herdr-panes.py` and its `herdr-panes` TV
  channel already list the attached session's panes, clean display text, encode
  routes, preview output, and jump. This is a picker with manual reload, not a
  status-column dashboard. Its extra `process-info` calls classify ordinary
  processes and shells; an agent-only board can avoid them.
- `dot_config/herdr/executable_focus-pane.py` accepts a versioned route token
  containing `socket_path`, `workspace_id`, `tab_id`, and `pane_id`. It validates
  the target, uses exact `agent focus` for agents, and verifies final focus. Its
  ordinary-pane fallback handles split topology. Reuse it rather than guessing
  pane positions or interpolating titles into shell commands.
- `dot_dotfiles/bin/executable_herdr-grep` already resolves running local
  sessions and implements focus-then-attach when invoked outside Herdr. Its
  in-Herdr picker refuses cross-session nesting.
- The managed Herdr sidebar already uses `agent_panel_sort = "priority"`, with
  state, workspace/tab, machine/agent, task title, and review marker rows.
  Herdr's `agent.view.set` API can filter/sort that sidebar, but does not create
  an Activity-style board. The installed herdr-plus plugin covers projects and
  actions rather than this view.

### Preserve Herdr's state and navigation semantics

- Keep all five native states: **blocked, done, working, idle, unknown**.
  `unknown` means detection uncertainty; never relabel it **Paused** or infer
  that the agent has stopped. `blocked` denotes an approval/question UI, not
  an automatically diagnosed quota wait.
- `done` and `idle` both mean ready for input; `done` is not yet marked seen.
  Reading snapshots does not mark it seen, but an explicit jump via
  `agent focus`/`pane focus` does. A card can therefore move from Done to Idle
  after selection. Each Herdr TUI client also tracks viewed completions, so its
  badge need not exactly match the CLI's server-side seen state.
- `state_change_seq` and `revision` are ordering/version values, not timestamps.
  The existing API cannot reconstruct historical Activity entries or truthful
  "working for 20 minutes" durations. A future view may track changes observed
  while it is running, clearly distinguishing that from prior history.
- Pane IDs are scoped to a server and can change when panes move across
  workspaces. Keep the session/socket route with every selection and revalidate
  before jumping; stale or disappeared targets require refresh.

### Integration options investigated

Verified against **Sidecar v1.14.0**; no option was selected for implementation.

| Option | What it can deliver | Boundary / cost |
|---|---|---|
| Sidecar external plugin | A separate Herdr global tab or resource pane, using the host's table/list and detail UI, with an explicit "Focus in Herdr" action | Cannot inject Herdr rows into built-in Activity or render a custom kanban/widget layout. Enter/double-click opens the item document; jump belongs in an action or permitted action key. Polling is clamped to 15–900 seconds unless local watched-file/plugin-change notifications are used. |
| Separate Herdr TUI | An Activity-like status layout with direct selection/jump and refresh behavior under our control; reuse the Herdr data and focus helpers | Adds a maintained UI/CLI. Python Textual/Rich already has repo precedents, but the final stack and exact presentation remain undecided. This is the closest fit if the layout and quick navigation matter more than living inside Sidecar. |
| Sidecar fork / upstream change | Extend the built-in Activity data source and navigation to understand real Herdr agents | Highest coupling and maintenance cost: Sidecar Activity currently projects its own tmux-backed workspace/agent inventory, and activation reveals a Sidecar Sessions row. Requires upstream agreement or a separately built/distributed Sidecar, not a dotfiles-only setting. |

Sidecar external plugins run without a PTY. Their default environment allowlist
does not include `HERDR_*` or `SSH_AUTH_SOCK`; any adapter needs explicit
`passEnv` for the minimal Herdr routing context it uses. `sourceUrl` accepts
HTTP(S), so a `herdr://` link is not an escape hatch. Keep `list`/`get` read-only
and perform focus through an explicit action. Sidecar's imported Herdr detection
manifests/hooks do **not** mean it connects to live Herdr sessions.

### Candidate first scope and remaining decisions

Resume with the smallest candidate: **all agent panes across all workspaces in
the same attached Herdr session**, displaying native status and an exact jump.
Do not silently add quota classification, prompts, continue/schedule/kill
actions, transcript ingestion, or persistent history to that slice.

- Decide whether the user needs a tab **inside Sidecar**, the **Activity-like
  layout itself**, or actual modification of Sidecar's built-in Activity. The
  three options above are not interchangeable.
- Reading all running **local sessions** is possible through
  `herdr session list --json` and each authoritative socket. Jumping across them
  from an already attached Herdr TUI needs a separate UX decision; today's
  helper requires detaching first. Outside Herdr, focus-then-attach is reusable.
- Remote reads/focus are available through
  `herdr --machine <profile-id> api snapshot` / `agent focus`. Each saved profile
  selects one remote session; it is not an all-session host inventory. IDs and
  agent names may collide between machines. The CLI has no `machine select`
  operation to switch the current local client's active machine, so focusing a
  remote server alone is not a complete cross-machine jump experience.
- A same-session view launched in a Herdr command pane can reuse the picker's
  focus-and-exit lifecycle. A persistent dashboard or a Sidecar plugin that
  stays open after jumping needs its return/focus behavior chosen explicitly.

### Research sources

- [Herdr 0.9.1 socket API and snapshot](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/next/website/src/content/docs/socket-api.mdx)
- [Herdr agent identity, status, and seen semantics](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/next/website/src/content/docs/agent-automation.mdx)
- [Herdr saved-machine routing limits](https://github.com/herdrdev/herdr/blob/v0.9.1/docs/next/website/src/content/docs/cli-reference.mdx#saved-ssh-machines)
- [Sidecar 1.14 external plugin protocol and freshness](https://github.com/marcus/sidecar/blob/v1.14.0/docs/reference/plugin-protocol.md)
- [Sidecar host-owned keys and item activation](https://github.com/marcus/sidecar/blob/v1.14.0/docs/guides/active/creating-plugins.md#the-keys-are-the-hosts)
- [Sidecar child execution environment](https://github.com/marcus/sidecar/blob/v1.14.0/docs/reference/terminal-resource-provider-protocol.md#execution-environment)
- [Sidecar built-in Activity activation and board projection](https://github.com/marcus/sidecar/blob/v1.14.0/internal/overview/model.go#L1517)

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
