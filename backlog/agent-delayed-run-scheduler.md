# Agent delayed-run scheduler for non-quota work

**Status**: P? research captured (2026-06)
**Effort**: M
**Related**: `dot_config/television/executable_agent-wakeup.py`, `dot_config/shell/62_agent_wakeup.sh`, [docs/tools/agent-panes-discovery.md](../docs/tools/agent-panes-discovery.md), [backlog/agent-quota-auto-loop.md](agent-quota-auto-loop.md), [backlog/agent-session-dashboard-tui.md](agent-session-dashboard-tui.md)

## Context

Quota wakeups are only one instance of a broader need: leave an agent session
half-finished, then resume it at a known future time. Example: implement a
market-data pipeline now, then wait until the stock market opens to run a live
smoke test and continue fixing failures.

This differs from quota recovery:

- quota waits are imposed by the provider and show explicit reset text;
- delayed work is user-intentional and may happen while quota is available;
- the scheduler needs to remember the target session, cwd, prompt, and whether
  to resume an existing conversation or start a fresh run.

## Investigation

### Claude Code

Claude Code has first-party scheduling surfaces:

- Session-scoped scheduling with `/loop` and cron-style tools. The docs say
  scheduled tasks live in the current conversation, require Claude Code
  v2.1.72+, can be listed/cancelled via `CronList`/`CronDelete`, and are
  restored by `claude --resume` / `claude --continue` if unexpired. They only
  fire while Claude Code is running and idle, and background Bash/monitor tasks
  are not restored on resume.
- Desktop scheduled tasks start new sessions at a selected time/frequency on
  the local machine, with local files/tools available while the Desktop app is
  open and the machine is awake.
- Routines run on Anthropic-managed infrastructure and can keep running even
  when the local machine is off, but they do not have direct access to
  uncommitted local state.
- `/goal` keeps the current session working across turns until a condition is
  met; it is useful for "keep going until tests pass", but it is not itself a
  wall-clock delayed start.

### Codex

Codex has first-party Automations in the Codex app:

- Standalone automations run fresh scheduled tasks and report findings to the
  app inbox.
- Thread automations are recurring wake-ups attached to the current thread,
  preserving thread context.
- Project-scoped local automations require the local Codex app to be running,
  the machine powered on, and the selected project still available on disk.
- Codex CLI has `codex resume` for interactive sessions and
  `codex exec resume [SESSION_ID]` / `codex exec resume --last [PROMPT]` for
  non-interactive resumption, but the CLI reference does not expose a native
  local `schedule` subcommand.

### OpenCode

OpenCode core CLI is scriptable but not scheduler-first:

- `opencode run` supports non-interactive runs, `--continue`, `--session`,
  `--attach`, and `opencode serve`.
- OpenCode's GitHub integration supports GitHub Actions `schedule` events for
  cron-based runs in CI.
- The official ecosystem page lists third-party scheduler/orchestration
  projects, including `opencode-scheduler`, but that is not the same as a
  core cross-agent local scheduler.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. Use native scheduling where available | Lowest maintenance; Claude/Codex already know their own session semantics | Surface-specific; not portable across Claude/Codex/OpenCode; may not target an existing tmux pane |
| B. Repo wrapper: `agent-run-at` / `agent-resume-at` | One command for "run this prompt at 09:30"; can use pueue labels/status; works for stock-open tests and other one-shot waits | Needs per-agent adapters and careful auth/permission defaults |
| C. Extend `agent-wakeup` beyond quota | Reuses current TV + pueue backend and pane discovery | The name/mental model is quota-specific; typing into panes remains fragile |
| D. Native dashboard/daemon owns timers | Best long-term state model; unifies quota, delayed work, transcript links, and manual controls | Larger design, overlaps with `agent-session-dashboard-tui.md` |

## Current decision

`2026-06-19`: document native surfaces and keep a repo backlog item for a
cross-agent local wrapper.

Use native features first when they fit:

- Claude Code `/loop` for quick in-session polling.
- Claude Code Desktop scheduled tasks or Routines for durable Claude-only
  scheduling.
- Codex App Automations for Codex-only recurring or thread wakeups.
- OpenCode GitHub scheduled workflows for CI-based tasks.

Still worth building a repo-local wrapper when the task is specifically:

- tied to a tmux pane or existing terminal session;
- cross-agent (`claude`, `codex`, `opencode`, Cursor Agent);
- a one-shot future continuation, not a recurring automation;
- dependent on uncommitted local state and the user's exact machine/tooling;
- something the user wants visible in the same `agent-wakeup` /
  future `agent-session` dashboard.

## Candidate v1

Add `agent-run-at` or extend `agent-continue-at` with an explicit mode:

```bash
agent-run-at --agent claude --cwd "$PWD" --at 09:31 \
  --prompt "Run the live market-open smoke test and fix failures."

agent-run-at --agent codex --cwd "$PWD" --delay 2h \
  --resume-last --prompt "Continue from the previous plan and run verification."

agent-run-at --agent opencode --cwd "$PWD" --at tomorrow-09:30 \
  --session <id> --prompt "Run the post-open validation."
```

Backend:

- pueue group `agent-scheduler`, labels like
  `agent-scheduler:<agent>:<project>:<time>`;
- adapters for command construction:
  - Claude: prefer native `/loop`/Desktop for active Claude sessions; external
    fallback can launch `claude --continue` or send to a tmux pane.
  - Codex: `codex exec resume --last <prompt>` or session-specific resume.
  - OpenCode: `opencode run --continue <prompt>` or `--session <id>`.
- dashboard rows for scheduled future work independent from quota waits.

## Open questions

- Should v1 launch non-interactive CLI runs, or type into an existing tmux
  pane? Non-interactive is safer; pane typing preserves exact TUI session
  context.
- How should the wrapper resolve "last session" safely when multiple sessions
  share a cwd?
- Should scheduled tasks inherit bypass/approval modes, or require explicit
  flags per task?
- Do we want one queue group for all agent jobs, or separate
  `agent-wakeup` and `agent-scheduler` groups?
- Can Codex App Automations be controlled from CLI/API enough to avoid a
  separate local wrapper for Codex?

## References

- Claude Code scheduled tasks: https://code.claude.com/docs/en/scheduled-tasks
- Claude Code Desktop scheduled tasks: https://code.claude.com/docs/en/desktop-scheduled-tasks
- Claude Code `/goal`: https://code.claude.com/docs/en/goal
- Claude Code common workflows: https://docs.anthropic.com/en/docs/claude-code/common-workflows
- Codex Automations: https://developers.openai.com/codex/app/automations
- Codex CLI reference: https://developers.openai.com/codex/cli/reference
- OpenCode CLI: https://opencode.ai/docs/cli/
- OpenCode GitHub schedule support: https://opencode.ai/docs/github/
- OpenCode ecosystem scheduler entry: https://opencode.ai/docs/ecosystem/
