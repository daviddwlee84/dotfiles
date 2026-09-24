# td + sidecar

`td` is a task-management CLI for AI-assisted workflows. `sidecar` provides both
a companion dashboard and an integrated workspace for agents, Git, files, and tasks.

## Opt-in task workflow

Use td when structured issues or handoffs help the selected project. Repository
navigation and worktree cleanup do not require td initialization or a td session.
Run `td usage --new-session` only when beginning an intentional td workflow;
ordinary td commands can open/migrate its database and may auto-sync configured
projects. See [shared repo navigation](dev-projects.md).

## Installation in This Dotfiles Repo

Both tools are installed automatically by the `coding_agents` ansible role when
`installCodingAgents=true`. This shared switch installs Sidecar and its companion
`marcus/td`; Herdr's installation is separate.

- macOS: Homebrew preferred (`marcus/tap`)
- Linux: Homebrew (Linuxbrew) preferred; fallback to GitHub release binaries in `~/.local/bin`

## Two Workflows: Companion Dashboard and Integrated Workspace {#ux-evolution}

Checked **2026-09-25** against [v1.14.0 (2026-09-05)](https://github.com/marcus/sidecar/releases/tag/v1.14.0).
The familiar **agent in one terminal pane, Sidecar beside it** workflow remains
supported: the [v1.14.0 introduction](https://github.com/marcus/sidecar/blob/v1.14.0/website/docs/intro.md#recommended-workflow)
still documents it, including tmux splits and multiple Sidecar instances.
The [v1.14.0 README](https://github.com/marcus/sidecar/blob/v1.14.0/README.md#suggested-use)
now recommends running agents inside Sidecar's embedded Workspaces terminals.
Both workflows are available; an upgrade does not require moving your agent.
These labels describe where you launch the agent, not an old/new mode switch.

### What changed since v0.71.1?

This is an evolution, not the first appearance of agent hosting. The
[v0.71.1 README](https://github.com/marcus/sidecar/blob/v0.71.1/README.md#workspaces)
already included worktrees, agent launching, task linking, and merge workflows;
its [workspace guide](https://github.com/marcus/sidecar/blob/v0.71.1/website/docs/workspaces-plugin.md#quick-start)
ran agents in isolated tmux sessions with output previews and interactive attach.

| Release | Practical change |
|---|---|
| [v0.71.1 — 2026-02-10](https://github.com/marcus/sidecar/releases/tag/v0.71.1) | The documented default workflow put the agent beside Sidecar; Workspaces already offered managed agents and Output / Diff / Task views. |
| [v0.98 — 2026-08-13](https://github.com/marcus/sidecar/blob/v1.14.0/CHANGELOG.md#v0980---2026-08-13) / [v0.99 — 2026-08-14](https://github.com/marcus/sidecar/blob/v1.14.0/CHANGELOG.md#v0990---2026-08-14) | Cross-project workspaces gained live interaction; files and td issues became real nested panes beside the terminal, with tabs and saved layouts. |
| [v1.0.0 — 2026-08-17](https://github.com/marcus/sidecar/blob/v1.14.0/CHANGELOG.md#v100---2026-08-17) | Project/global workspaces converged on one pane model. In-app Configuration arrived; Diff and Task panes replaced the old mutually exclusive Output / Diff / Task row. |
| [v1.14.0 — 2026-09-05](https://github.com/marcus/sidecar/releases/tag/v1.14.0) | The integrated workspace remains central, with a public plugin protocol, more agent integrations, and plugin/project CLI commands. |

Current Sidecar also exposes `sidecar open` for files/issues/diffs,
`sidecar layout` for composing panes, and a global Sessions screen for monitoring
projects. These describe the audited v1.14.0 experience; check
`sidecar --version` before expecting them on an older install.
The [Conversations history tab](https://github.com/marcus/sidecar/blob/v1.14.0/website/docs/intro.md#7-conversations-opt-in)
is now opt-in (`conversations_plugin`), so its absence after upgrading does not
mean the companion workflow has been removed.

### Which workflow fits?

| Aspect | Agent beside Sidecar | Agent inside Sidecar |
|---|---|---|
| Who splits the screen? | Your outer tmux, Herdr, Zellij, or terminal emulator. | Sidecar's own pane layout. |
| Where does the agent run? | An ordinary outer pane you launch and manage. | A Sidecar-managed shell/worktree, backed by tmux. |
| What do you gain? | Keep the existing agent session and multiplexer habits; use Sidecar for Git, files, tasks, and history. | One UI for interactive terminals, content panes, worktrees, and cross-project sessions; agents can open relevant content through the Sidecar CLI. |
| What is tmux doing? | It is the outer splitter if you choose tmux. Opening Sidecar's managed shells or tmux-backed editor still uses its internal backend. | It supplies the embedded terminal/session backend, even if the outer terminal is Herdr or a plain terminal. |
| What is `td` doing? | Task tracking and handoffs through the same project workflow. | The same task role, with issues also available beside managed terminals. |

**Companion mode:** leave the agent running, then start Sidecar in another pane
against the same checkout:

```bash
sidecar --project /path/to/repo
```

The shipped `~/.config/tmuxp/claude-sidecar.yaml` and
`~/.config/zellij/layouts/claude-sidecar.kdl` both use this arrangement. Herdr's
[`prefix+S`](#open-sidecar-beside-an-agent-in-herdr) adds the same companion view
to your current pane; it does not move the existing agent into Sidecar.

**Integrated mode:** start Sidecar for the project in a full pane or tab, open
**Workspaces**, then create a **Shell** (`Ctrl+n`) or **Worktree** (`n`) and
launch/attach an installed agent (`a`). Enter the terminal to interact; open files, issues, and diffs
beside it as needed. This starts an agent inside Sidecar; existing Herdr panes
are not migrated automatically.
See the [v1.14.0 workspace shortcuts](https://github.com/marcus/sidecar/blob/v1.14.0/README.md#workspace-shortcuts).

For this integrated route, use **tmux 3.4+**. The v1.14.0
[runtime readiness check](https://github.com/marcus/sidecar/blob/v1.14.0/internal/configchecks/tmux.go)
and [tested compatibility guide](https://github.com/marcus/sidecar/blob/v1.14.0/docs/guides/active/tmux-compatibility.md)
agree on 3.4; the Workspaces website page's older “3.0+” prerequisite is stale.

## Open Sidecar Beside an Agent in Herdr

Press **`Ctrl+b`, then `Shift+s`** (`prefix+S`) in the agent's pane. Herdr opens
Sidecar to its right, sharing that pane's area 50/50 and using its current
directory. Focus moves to Sidecar; exiting closes the temporary pane and restores
the previous layout. Each invocation opens another pane.

The binding uses Herdr's native `type = "pane"` lifecycle with
`~/.config/herdr/sidecar.sh`, which removes the command pane's initial zoom so both
panes remain visible. It neither installs tools nor runs `td init`; a missing
Sidecar produces an installation hint. See [Herdr keybindings](herdr.md#keybindings).

The minimum usable pane changed from **80 columns × 24 rows in 0.71.1** to
**60 columns × 24 rows in 1.14.0**. Below either dimension, Sidecar displays
`Terminal too small` instead of its normal UI; see the
[v1.14.0 size guard](https://github.com/marcus/sidecar/blob/v1.14.0/internal/app/view.go#L206).
The shortcut was checked with 1.14.0 and a path containing spaces, an apostrophe,
and Chinese characters.

On a phone, keep the normal split binding and press **`prefix+z`** to zoom Sidecar.
Herdr's mobile layout hides its sidebar but retains tiled splits, so it cannot
make a half-width Sidecar usable automatically. If the full pane is still below
60×24, reduce font size or change orientation; landscape may improve width but
leave fewer than 24 rows. Press `prefix+z` again to restore the split. Upgrading
does not replace an already-running Sidecar process: an old process, or an older
remote installation, can still report the 80×24 minimum.

## Diagnose td Identity and Setup Prompts

There are two unrelated Homebrew packages named `td`:
[Homebrew core's `td`](https://formulae.brew.sh/formula/td) is Swatto/td, while
**`marcus/tap/td`** is Sidecar's companion. Always use the fully qualified formula
for installation or explicit upgrades (`brew upgrade marcus/tap/td`). This repo's
installer checks for the `session` command in `td --help` before accepting an
existing binary and installs `marcus/tap/td` when needed. A bare `brew info td`
catalog result does not establish which executable your PATH resolves.

During the 2026-09-25 audit, the local executable resolved to the Homebrew
**marcus/tap 0.34.0** installation, as confirmed by its install receipt and CLI
help; the identity guard passed. Sidecar 1.14.0, however, embeds
[td 0.65.0](https://github.com/marcus/sidecar/blob/v1.14.0/go.mod#L20) for its task
monitor and also calls the external CLI for Notes. Keeping the external CLI
current is useful, but this version gap alone does not prove a setup failure.
Later that day, `brew upgrade marcus/tap/td` upgraded the external CLI to 0.65.0;
`td --version` confirmed the result. This resolved the version gap without
replacing the tool with the unrelated Homebrew core formula.

Sidecar's [td detection](https://github.com/marcus/sidecar/blob/v1.14.0/internal/plugins/tdmonitor/plugin.go#L199)
only checks whether `td` exists on PATH, without validating its identity or a
minimum CLI version. If the embedded monitor fails to initialize for **any**
reason while the binary exists, its
[error handling](https://github.com/marcus/sidecar/blob/v1.14.0/internal/plugins/tdmonitor/plugin.go#L287)
can show **Set up td**. That can mean an uninitialized project or a database
open/permission/migration error; it is not evidence of a conflicting CLI.

Check the existing debug log before initializing anything. The local audit found
a Notes error containing `database is locked (5) (SQLITE_BUSY)`, despite an
existing readable `.todos/issues.db`. Do not run `td init` or accept the setup
dialog merely to re-detect an existing database: setup can initialize data and
change agent instructions. Use executable paths, install receipts, `td --help`,
and `td --version` for identity checks; ordinary task commands can open/migrate
the database and are not a strictly read-only diagnostic.

## Windows Compatibility

Audited **2026-09-25**. The companion
[Windows dotfiles installer](https://github.com/daviddwlee84/dotfiles-windows/blob/main/.chezmoiscripts/run_onchange_after_10_packages.ps1.tmpl)
does not install Sidecar or `td`, and its native PowerShell Herdr configuration
does not include this Sidecar shortcut.

- **Sidecar on native Windows:** not an upstream-supported platform. Its
  [requirements](https://github.com/marcus/sidecar#requirements) list macOS, Linux,
  and WSL; the [PowerShell support request](https://github.com/marcus/sidecar/issues/130)
  remains open. [v1.14.0](https://github.com/marcus/sidecar/releases/tag/v1.14.0)
  provides macOS/Linux binaries only.
- **`td` on native Windows:** upstream merged
  [Windows file-locking support](https://github.com/marcus/td/pull/79), with a
  reported native build/version smoke test. The fix is present in
  [v0.65.0 source](https://github.com/marcus/td/blob/v0.65.0/internal/config/config_lock_windows.go),
  but that [release](https://github.com/marcus/td/releases/tag/v0.65.0) still has no
  Windows binary. This does not establish support for the complete Sidecar pair.
- **WSL:** the supported Windows route is to run the Linux workflow, including
  the agent, Sidecar, and `td`, inside WSL. Sidecar's embedded shells/workspaces
  also need **tmux 3.4+**, even when its outer terminal is Herdr, per the
  [v1.14.0 compatibility guide](https://github.com/marcus/sidecar/blob/v1.14.0/docs/guides/active/tmux-compatibility.md).

This was a source/release audit from macOS; native Windows and WSL runtime behavior
were not tested. No Windows package installation or shortcut was added.

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
