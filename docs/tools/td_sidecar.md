# td + sidecar

`td` is a task-management CLI for AI-assisted workflows. `sidecar` is a TUI dashboard for working with those workflows.

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
