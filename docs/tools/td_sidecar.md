# td + sidecar

`td` is a task-management CLI for AI-assisted workflows. `sidecar` is a TUI dashboard for working with those workflows.

## Opt-in task workflow

Use td when structured issues or handoffs help the selected project. Repository
navigation and worktree cleanup do not require td initialization or a td session.
Run `td usage --new-session` only when beginning an intentional td workflow;
ordinary td commands can open/migrate its database and may auto-sync configured
projects. See [shared repo navigation](dev-projects.md).

## Installation in This Dotfiles Repo

Both tools are installed automatically by the `coding_agents` ansible role.

- macOS: Homebrew preferred (`marcus/tap`)
- Linux: Homebrew (Linuxbrew) preferred; fallback to GitHub release binaries in `~/.local/bin`

## Manual Installation

### macOS (preferred)

```bash
brew install marcus/tap/td
brew install marcus/tap/sidecar
```

### GitHub Releases

- `td`: <https://github.com/marcus/td/releases>
- `sidecar`: <https://github.com/marcus/sidecar/releases>

## Verify Installation

```bash
td version
sidecar --version
```

## References

- [td docs](https://marcus.github.io/td/)
- [sidecar docs](https://sidecar.haplab.com/)

---

> ** `add` 和 `new` 都是 `create` 的 alias，三個命令指向同一個功能。

## Current td model (v0.65.0)

Audited 2026-09-25. This replaces the older workflow diagrams and local-only
conclusions below the installation notes.

- Issues hold work status, priorities, dependencies and handoff context. They
  do not prove a branch is merged or a checkout can be removed.
- Worktrees normally share the project database, but `.td-root`, a local
  `.todos`, associations and main-worktree resolution affect which store opens.
  Session/focus identity includes worktree context as well as agent/branch;
  do not describe it as branch-only isolation.
- Review policy is configurable. Trusted mode allows attributed review or
  explicit self-review with a reason; a different session is not a universal
  requirement. `review` can construct a missing handoff from logs. Query the
  installed CLI's help instead of treating the old DAG as current syntax.
- Remote sync now exists for issues, logs, handoffs, boards and work sessions.
  Sessions and host-local checkout bindings remain local. Configured CLI
  startup may auto-sync; this is not a strictly read-only inventory API.
- A future adapter must set its process cwd to the selected checkout:
  `--work-dir` selects the database base but does not change process cwd.

For daily navigation, use [dev-projects](dev-projects.md). Keep td optional,
leave issue content authoritative there, and do not map `closed` onto dev
`done` or use it as worktree deletion authority. Herdr remains the primary
runtime during the isolated Sidecar trial.

Sources: [sync client guide](https://github.com/marcus/td/blob/v0.65.0/docs/sync-client-guide.md),
[status and review](https://github.com/marcus/td/blob/v0.65.0/docs/status-and-review.md),
[session state](https://github.com/marcus/td/blob/v0.65.0/internal/db/session_state.go),
[workdir resolution](https://github.com/marcus/td/blob/v0.65.0/internal/workdir/workdir.go).
