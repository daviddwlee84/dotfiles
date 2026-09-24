# td + sidecar

`td` is a task-management CLI for AI-assisted workflows. `sidecar` provides both
a companion dashboard and an integrated workspace for agents, Git, files, and tasks.

## MANDATORY: Use td for Task Management

At conversation start (or after `/clear`), run:

```bash
td usage --new-session
```

For subsequent reads in the same session:

```bash
td usage -q
```

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

## td 完整 Workflow DAG

```
                          Session Layer
                    ┌──────────────────────────┐
                    │  td usage --new-session  │  ← 每個 conversation 開頭
                    │  td usage -q             │  ← 之後靜默模式
                    └──────────────────────────┘

                          Issue Lifecycle
                    ┌─────────────────────┐
                    │  td create/add/new  │  ← 建立 issue
                    └─────────┬───────────┘
                              │
                              ▼
                   ┌─────────────────┐
             ┌──── │      open       │ ◄──────────────────────────┐
             │     └──┬──────┬────┬──┘                            │
             │        │      │    │                               │
             │  start │      │    │ close                  reopen │
             │        ▼      │    │ (admin only)                  │
             │  ┌───────────┐│    │                         ┌─────┴─────┐
             │  │in_progress││    └────────────────────────►│  closed   │
             │  └──┬──┬──┬──┘│                              └───────────┘
             │     │  │  │   │                                    ▲
             │     │  │  │   │ review                             │
      block  │     │  │  │   │ (skip in_progress)          approve│
             │     │  │  └───┼────────────┐                       │
             │     │  │      │            ▼                       │
             │     │  │      │   ┌────────────────┐               │
             │     │  │ review   │   in_review    ├───────────────┘
             │     │  │      │   └───┬────────────┘
             │     │  │      │       │
             │     │  │      │  reject (→ back to in_progress)
             │     │  │      │       │
             │     │  │      │       ▼
             │     │  │ unstart  ┌───────────┐
             │     │  └──────┼──►│in_progress│  (rework cycle)
             │     │         │   └───────────┘
             │     │ block   │
             │     ▼         │
             │  ┌─────────┐  │
             └─►│ blocked │  │
                └──┬──────┘  │
                   │         │
            unblock│         │
                   └─────────┘
                    (→ open)
```

### 正常工作流 (Happy Path)

```
create → open → start → in_progress → handoff → review → approve → closed
                             │                              │
                             │        log (記錄進度)        │
                             │◄─────── reject ──────────────┘
                             │         (rework)
```

### 各狀態轉換命令表

| From | To | Command | 說明 |
| --- | --- | --- | --- |
| (none) | open | `td create` / `td add` / `td new` | 建立 issue |
| open | in_progress | `td start <id>` | 開始工作，記錄 implementer |
| in_progress | in_progress | `td log "msg"` | 記錄進度（不改狀態） |
| in_progress | in_progress | `td handoff <id>` | 捕捉工作狀態（不改狀態，但 review 前必做） |
| in_progress | in_review | `td review <id>` | 提交審核 |
| in_review | closed | `td approve <id>` | 審核通過 (必須不同 session) |
| in_review | in_progress | `td reject <id>` | 打回重做 |
| any | blocked | `td block <id>` | 標記阻塞 |
| blocked | open | `td unblock <id>` | 解除阻塞 |
| in_progress | open | `td unstart <id>` | 放棄工作 |
| any | closed | `td close <id>` | 行政關閉 (不應用於正常完成) |
| closed | open | `td reopen <id>` | 重新開啟 |

### Work Session (多 issue 批次)

```
td ws start "session name"    ← 建立 work session
td ws tag <id1> <id2> ...     ← 關聯多個 issue
td ws log "msg"               ← 對整個 session 記 log
td ws handoff                 ← 批次 handoff 所有 tagged issues
```

### 關鍵規則

1. **`td close` 不是正常完成** — 正常應走 `review` → `approve`
2. **`td approve` 必須不同 session** — 不能自己審自己（除非 `--minor`）
3. **`td handoff` 是 review 前的必要步驟** — 捕捉 git state + 工作摘要
4. **Session = 身份識別**，Work Session = 工作容器（可選）

---

## `td` 與 Git Worktree 的關係

### 數據存儲架構

`td` 的數據是一個 **SQLite 文件** (`.todos/issues.db`)，放在 project root（靠 `.td-root` 或 git root 定位）。Global flag `-w, --work-dir` 的說明寫的是：

> `resolves .td-root and git worktrees from this path`

這表示 `td` **有 worktree 感知** — 從任何 worktree 路徑啟動，它會回溯找到主 repo 的 `.todos/issues.db`。所以多個 worktree 會 **共享同一個 database**。

### Session 是 branch-scoped

從 DB schema 和實際數據可以看到：

```
sessions table: branch TEXT DEFAULT ''
session list:   列出時也是 "branch + agent scoped"
```

所有 session 都記了 `branch`，而 `td session list` 也標注每個 session 在哪個 branch。所以理論上不同 worktree (= 不同 branch) 的 session 不會互相干擾。

### 但 Issues 沒有 branch scope

```sql
CREATE TABLE issues (
    ...
    created_branch TEXT DEFAULT '',  -- 記錄建立時的 branch，但不是 filter 條件
    ...
);
```

Issues 有 `created_branch` 欄位，但這只是 metadata — `td list` 預設會顯示 **所有 issues**，不會按 branch 過濾。這表示：

- Worktree A (branch: feature-x) 建的 issue，在 Worktree B (branch: main) 也看得到
- 這可以是優點（全域 backlog），也可以造成混亂

### 結論：可以用 worktree，但有 caveats

**支持的部分：**

- 共享 DB — 多個 worktree 看到同一份 backlog (符合 "one project, one backlog" 設計)
- Session isolation by branch — 不同 branch 的 session 自動區分
- Review workflow 仍然成立 — 不同 worktree/session 之間可以互相 review

**可能不太適合的場景：**

- 如果你想要 **branch 獨立的 issue list** — `td` 沒有提供這個。所有 issues 共享同一個池子。你需要靠 labels 或 boards 自己做分類。
- 同時在多個 worktree 並行工作時，SQLite 的 WAL mode 可能有極少數的併發問題（但 CLI 工具一般不會長時間 hold lock，所以實務上應該沒問題）。

### Best Practice

```
場景 1: 單人 + 多 agent sessions（推薦方式）
  main branch, 一個 repo 目錄
  不同 agent (Claude, Codex, Cursor) 各自開 session
  用 review workflow 互相審核
  → 這是 td 的設計甜蜜點

場景 2: 單人 + worktrees
  可行，但用 labels/boards 區分不同 branch 的工作
  td create "fix auth" --label "feature-x"
  td board create "feature-x" --query "label:feature-x"
  → 能用，需要自己維護分類

場景 3: 多人多機
  不適合 — td 是 local SQLite，沒有 remote sync
  （雖然 schema 有 sync_state table，但目前看起來不 active）
```

簡單說：**`td` 設計定位是「單 project、多 AI session、local-first」**。Worktree 技術上能用（共享 DB），但它最順暢的用法就是在同一個目錄、同一個 branch 上，讓不同 agent sessions 依次接力工作。
