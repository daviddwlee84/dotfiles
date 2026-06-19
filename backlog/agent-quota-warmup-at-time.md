# Agent quota warmup at a scheduled time

**Status**: SHIPPED (2026-06-20) as `agent-warmup` — see
[docs/tools/agent-warmup.md](../docs/tools/agent-warmup.md)
**Effort**: S/M
**Related**: [backlog/agent-quota-auto-loop.md](agent-quota-auto-loop.md), [backlog/agent-delayed-run-scheduler.md](agent-delayed-run-scheduler.md), [backlog/agent-session-dashboard-tui.md](agent-session-dashboard-tui.md), [pitfalls/claude-hud-usage-statusline-stale.md](../pitfalls/claude-hud-usage-statusline-stale.md), [pitfalls/headless-claude-p-does-not-move-5h-window.md](../pitfalls/headless-claude-p-does-not-move-5h-window.md)

## Outcome (2026-06-20)

The open empirical question below ("does a minimal `claude -p` run start the
same five-hour window?") **resolved to NO.** As of the **2026-06-15** Anthropic
billing split, only *interactive* Claude Code advances the 5-hour subscription
window; headless `claude -p` / Agent SDK draws from a separate metered credit
pool. So the candidate v1 design (isolated cwd + `claude -p`) is **obsolete** —
it would burn metered credit and never move the window. See
[pitfalls/headless-claude-p-does-not-move-5h-window.md](../pitfalls/headless-claude-p-does-not-move-5h-window.md).

Shipped design pivoted to **interactive-tmux warmup**: `agent-warmup`
(`dot_dotfiles/bin/executable_agent-warmup`) spawns a detached tmux session
running real interactive `claude` (dedicated socket, isolated cwd, subscription
auth, `--model haiku`), sends a tiny prompt + Enter, logs + notifies. Backends:
pueue one-shot (`at`), launchd/systemd recurring timer (`install`). The
interactive-via-tmux classification is itself unverified — `agent-warmup verify`
exists to confirm empirically near a reset boundary before trusting the recurring
install. The original research below is kept for history.

## Context

There is a separate use case from quota recovery and delayed work:
intentionally send a tiny Claude prompt at a fixed time, such as 06:00, so the
five-hour subscription usage window starts before the user begins work. The
desired behavior is:

1. run one tiny prompt like "Reply exactly: hi";
2. avoid loading a large project context;
3. verify the quota window/reset time if possible;
4. leave a visible audit trail so the user knows whether the warmup fired.

This is not the same as `agent-continue-at`:

- no existing tmux pane or blocked agent session is required;
- the prompt should not continue real work;
- the safest default is a fresh non-interactive run in an isolated directory;
- failures should notify/report, not type into a live coding pane.

## Candidate surfaces

### Claude Code scheduled task

Inside Claude Code, ask for a one-shot scheduled task:

```text
At 6:00am tomorrow, reply exactly "hi" and do nothing else.
```

This uses Claude Code's first-party scheduler (`/loop` / cron-style scheduled
tasks) and keeps behavior inside Claude Code. It is low maintenance, but it is
session-scoped and depends on Claude Code still running and idle when the task
fires.

### macOS launchd

For a daily local warmup, a user LaunchAgent is a better fit than tmux:

```bash
mkdir -p ~/.cache/agent-warmup
cd ~/.cache/agent-warmup
claude -p 'Reply exactly: hi'
```

Use an isolated cwd like `~/.cache/agent-warmup` so the run does not read a
large repo's `CLAUDE.md`, recent files, or tool context. Log stdout/stderr to
`~/.cache/agent-warmup/` and treat non-zero exit as a notification-worthy
failure.

### pueue one-shot wrapper

For ad-hoc "tomorrow at 06:00" tasks, a wrapper can submit a delayed pueue job
instead of installing a persistent LaunchAgent. This fits the existing local
tooling model and gives `pueue status` / future dashboard visibility.

The open design question is whether `agent-quota-warmup-at` should use pueue
directly for one-shot delays and generate launchd/systemd timers only for
recurring schedules.

### tmux send-keys

Typing into an existing tmux pane can technically start activity, but it is the
wrong default for warmup. It risks consuming project/session context and may
continue real work accidentally. Reserve pane typing for actual
`agent-continue-at` / quota-recovery flows.

## Candidate v1

Add a shell function or small CLI:

```bash
agent-quota-warmup-at --agent claude --at 06:00
agent-quota-warmup-at --agent claude --at tomorrow-06:00 --prompt 'Reply exactly: hi'
agent-quota-warmup-at --agent claude --daily weekdays --time 06:00 --verify-reset
agent-quota-warmup-status
```

Defaults:

- `--agent claude` only at first; Codex/OpenCode have different quota systems
  and should not be modeled as Claude warmups.
- cwd = `~/.cache/agent-warmup/claude`.
- prompt = `Reply exactly: hi`.
- command = `claude -p "$prompt"` unless testing shows a better low-context
  Claude Code invocation.
- label/log prefix = `agent-warmup:claude:<timestamp>`.
- do not target tmux panes unless `--pane` is explicit.

Possible backends:

- one-shot: pueue `--delay` job;
- daily/weekly on macOS: launchd `StartCalendarInterval`;
- daily/weekly on Linux: systemd user timer;
- future native TUI: own timer model in `agent-session`.

## Verification

Do not rely only on the Claude HUD status line. The HUD usage line can be
stale; see
[claude-hud-usage-statusline-stale.md](../pitfalls/claude-hud-usage-statusline-stale.md).

Warmup verification should prefer one or more of:

- command exit code and output log;
- a fresh usage/reset timestamp from a reliable CLI/status source, if exposed;
- timestamped record that a warmup attempt was made;
- optional notification when the observed reset time changes.

Open empirical check: confirm whether a minimal `claude -p` run starts the same
five-hour Claude subscription window as interactive Claude Code usage on the
current plan. Do not assume Anthropic API calls count toward the same window;
this feature is specifically for Claude Code / Claude subscription usage.

## Risks

- If the scheduler runs in a large project cwd, "hi" may still consume
  project-level context.
- If auth expires overnight, warmup silently fails unless logs/notifications are
  surfaced.
- If the machine is asleep, local launchd/pueue will not fire until wake, so
  daily warmup may miss the intended reset geometry.
- If provider quota semantics change, a warmup may no longer move the window.

## References

- Claude Code scheduled tasks: https://code.claude.com/docs/en/scheduled-tasks
- Claude Code Desktop scheduled tasks: https://code.claude.com/docs/en/desktop-scheduled-tasks
- Claude Code CLI reference: https://docs.anthropic.com/en/docs/claude-code/cli-reference
- Claude Code Pro/Max usage: https://support.anthropic.com/en/articles/11145838-using-claude-code-with-your-pro-or-max-plan
