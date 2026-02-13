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
