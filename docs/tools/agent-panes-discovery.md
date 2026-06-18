# Agent pane discovery

Find — and jump to — coding-agent sessions (`claude`, `cursor-agent`, `codex`,
`opencode`) that are currently running in *any* tmux pane on this host.

The pain this solves: you start `claude` in pane A on session `chezmoi`, hop
into pane B in another window for a quick test, drift over to a `vibe/foo`
session for a Codex task, and three windows later you can't remember which
pane has the agent you wanted to nudge. CodeIsland (macOS) tells you which
**terminal app** is running an agent, but not the specific tmux pane —
useless once you have more than one agent inside one terminal.

Two complementary surfaces ship in this repo, both backed by tmux:

| Tool | Scope | Best at |
|---|---|---|
| `tv agent-panes` | All four agents (Claude / Codex / OpenCode / Cursor) | "Where am I running stuff?" cross-agent overview, jump-to-pane |
| `tv agent-wakeup` | Same live panes, plus pueue wakeup tasks | "Which agent is quota-blocked, when should I send `continue`?" |
| `recon` (optional) | Claude-only, with live status (Working / Idle / Waiting) parsed from pane capture | "Which Claude needs my attention?" — recon's live status detection is richer than what we replicate in tv |

## `tv agent-panes` (primary)

Open the picker with `prefix + a` inside tmux, or via the popup menu
(`prefix + Space → → Agents → Live agent panes (tv)`), or from any shell
with `tv agent-panes`.

Each row is one running agent pane. The status column shows ● (busy) or
○ (idle) for Claude (read from `~/.claude/sessions/{pid}.json`); blank for
others.

```
[cc] ● chezmoi:1.1     │  discover-coding-agent-sessions          │  chezmoi
[cc] ○ chezmoi:2.1     │  fix-nvm-lazy-loader-permission-request  │  chezmoi
[cc] ●  vibe/foo:4.1   │  refactor auth module                    │  foo
[oc]   vibe/bar:0.0    │  Generate migration script               │  bar
```

### Keybindings (in the picker)

| Key | Action |
|---|---|
| `Enter` / `Alt+T` | Switch tmux focus to that session/window/pane |
| `Alt+K` | Kill the pane (with `[y/N]` confirm) |
| `Ctrl+Y` | Copy the pane target (`session:win.pane`) to clipboard |
| `Alt+P` | Copy directory path |
| `Alt+R` | Copy session ID |
| `Alt+S` | Copy matched `.specstory/history/*.md` path |
| `Ctrl+F` | Cycle preview: live `tmux capture-pane` snapshot ↔ stored transcript |
| `Esc` | Close the picker |

### How resolution works

- **Claude** — Claude Code writes a per-process file at
  `~/.claude/sessions/{claude_pid}.json` containing `sessionId`, `cwd`,
  `status`, and (when set) a friendly `name`. The discovery walker reads
  these directly — *zero heuristics* for Claude. It then walks each
  `claude_pid`'s parent chain via `ps -o ppid=` until it finds a tmux
  `pane_pid`, which gives the pane target.
- **Codex / OpenCode / Cursor** — `pgrep -x <bin>` finds running agent
  PIDs, parent-chain walked the same way. Session ID is best-effort: the
  walker queries each agent's storage (`opencode.db`, `~/.codex/sessions`,
  `~/.cursor/chats`) for the most-recent matching session whose `cwd`
  equals the pane's `pane_current_path`. If multiple sessions share a
  cwd, the most recently updated wins. The pane is still listed even if
  no session ID matches — the row is useful for jump-to-pane regardless.

## `tv agent-wakeup` (quota waits + scheduled continue)

Open with `prefix + M-a`, via the popup menu
(`prefix + Space → → Agents → Quota wakeup (tv)`), or from a shell with
`tv agent-wakeup`.

The channel reuses the live pane resolver from `tv agent-panes`, captures the
last part of each pane scrollback, and conservatively marks panes as quota
waiting only when it sees explicit limit wording such as `session limit`,
`rate limit`, `limit reached`, or `quota`. It parses reset phrases like
`resets 1:50am`, `resets in 70m`, or `resets in 5h 20m`, then shows any
queued pueue wakeup task for the pane.

Claude HUD usage lines such as `Context ... | Usage Limit reached` are
ignored because `claude-hud` renders from cached/API usage data and is not an
authoritative live indicator that the pane is currently blocked.

`WAIT_MENU` is the Claude `/rate-limit-options` screen where option 1
(`Stop and wait for limit to reset`) is already selected. For that state the
recommended action is `enter`, not `continue`.

| Key | Action |
|---|---|
| `Enter` | Switch tmux focus to that pane |
| `Alt+C` | Schedule a smart wakeup at the detected reset time + 2 minutes |
| `Alt+T` | Prompt for a custom time/delay (`01:52am`, `70m`, `5h`, etc.) |
| `Alt+N` | Smart send now: `Enter` for `WAIT_MENU`, otherwise `continue` + Enter |
| `Alt+X` | Cancel queued wakeup tasks for that pane |
| `Ctrl+F` | Cycle preview; the default preview is live `tmux capture-pane` output |

The shell equivalent is:

```bash
agent-wakeup status
agent-continue-at --pane %12 --at 01:52am
agent-wakeup send-now --pane %44 --auto        # Enter for /rate-limit-options, continue otherwise
agent-wakeup send-now --pane %44 --enter-only  # force selecting Stop-and-wait menu item
agent-continue-at --current --delay 70m
agent-wakeup cancel --pane %12
```

Scheduled wakeups are pueue tasks in group `agent-wakeup` with labels
`agent-wakeup:%pane_id`. The scheduled task re-captures the pane right before
sending. If the quota marker has disappeared, it aborts instead of blindly
typing into a session that may already be doing unrelated work. With `--auto`,
the send step re-captures the pane and chooses `Enter` for a rate-limit menu
or `continue` for a normal prompt.

The fully automatic "detect quota, schedule, continue, repeat until non-quota
exit" supervisor is deliberately deferred; see
[`backlog/agent-quota-auto-loop.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/agent-quota-auto-loop.md).

## `recon` (Claude-only fast popup, optional)

[`gavraz/recon`](https://github.com/gavraz/recon) is a Rust TUI dashboard
that focuses on Claude Code only but pays attention to live agent status by
parsing the Claude TUI status bar via `tmux capture-pane`. Worth keeping
around when you're juggling several Claude sessions and want
"who's blocked on me?" at a glance.

### Install

Installed automatically via the `rust_cargo_tools` ansible role on
`chezmoi apply`:

```bash
cargo install --git https://github.com/gavraz/recon --locked
```

Upgrades flow through the standard cargo path:

```bash
just upgrade-cargo   # or scripts/upgrade_tools.sh cargo
```

### Use

Open it from the popup menu: `prefix + Space → → Agents → Claude
dashboard (recon)`. There's no top-level keybind by default — `prefix + g`
(recon's upstream default) is taken by the sesh picker on this repo.
Promote it to a top-level binding in `dot_config/tmux/keybindings.conf` if
you find yourself reaching for it often.

The `→ Agents` submenu only shows the recon row when `recon` is on `PATH`,
so it disappears cleanly on hosts that haven't installed it.

## Troubleshooting

### "I don't see my running Claude"

Stale `~/.claude/sessions/{pid}.json` files are skipped automatically — if
the PID isn't a descendant of any tmux pane, the row is omitted. If you
expect to see a session that isn't there:

```bash
~/.config/television/agent-sessions.py panes        # raw TSV, see what it finds
ls -lt ~/.claude/sessions/                          # what files exist
ps -p <pid_from_filename>                           # is the process alive?
tmux list-panes -aF '#{pane_id} #{pane_pid} #{pane_current_command}'
```

If the claude PID is alive but `_find_pane_for_pid` doesn't reach a tmux
pane (e.g., claude was launched outside tmux), the row is correctly
omitted — `tv agent-panes` only shows panes you can `switch-client` to.

### "Codex/OpenCode/Cursor row has no session ID"

The cwd-based reverse lookup couldn't find a stored session whose
`directory` matches the pane's `pane_current_path`. Common causes: agent
was started with `--cd` to a path that doesn't match storage; storage
was migrated. The pane still shows up — Enter still jumps to it; you just
won't get an automatic "resume this exact session" handle.

### "I jumped to a pane and tmux says it doesn't exist"

The picker is a snapshot. If a pane closes between snapshot and switch,
the action falls back to a `tmux display-message` warning and stays put.
Re-open the picker (`prefix + a`) to refresh.

### "Recon doesn't appear in the Agents submenu"

`menu-agents.sh` probes `command -v recon` and only adds the row when the
binary is on `PATH`. If you've just installed it, your tmux server may
need a fresh shell environment — `tmux source ~/.tmux.conf` is enough; no
restart required.

## Related

- [tmux keybindings](tmux/keybindings.md) — popup-menu surface
  (`prefix + Space`) where `→ Agents` lives, plus the full `prefix + ?`
  binding map.
- [Agent sessions browser](agent-overlays.md) — sister channel
  `tv agent-sessions` that browses **stored** session history (resume an old
  session vs. jump to a running one).
- [SpecStory internals](specstory-internals.md) — explains the
  `<!-- Provider Session UUID -->` reverse-lookup that lets the picker
  surface the matching `.specstory/history/*.md` for each row.
- Sibling deferred work: per-pane working/idle status glyph in the tmux
  window list itself (Option C of
  [`backlog/tmux-window-status-indicators.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/tmux-window-status-indicators.md)).
