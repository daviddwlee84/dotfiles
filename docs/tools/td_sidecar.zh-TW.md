# td + sidecar

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`td` 是給 AI 輔助工作流使用的任務管理 (task management) CLI。`sidecar` 則是搭配這些工作流的 TUI 儀表板 (dashboard)。

| 工具 | 角色 |
|---|---|
| `td` | Agent issue、執行 context 與 handoff。 |
| [Tasks](tasks.zh-TW.md) | Inbox、Next actions、Agenda、Projects 等個人規劃；提供 `tasks` / `tasks-tui` / `tasks-api`。 |
| Sidecar | 並排 dashboard 或整合 workspace，內嵌 td 與 Tasks 介面。 |

Tasks 使用自己的 JSONL store，與 td 的 project database 分開。首次 XDG 資料
位置與獨立工具使用方式見 [Tasks](tasks.zh-TW.md)。

## 選用 task workflow

需要 structured issues 或 handoff 時才在該 project 使用 td。Repository 導航
與 worktree 清理不需要 td init 或 td session；明確開始 td workflow 時才執行
`td usage --new-session`。一般 td 指令可能開啟／migrate database，已配置的
project 也可能 auto-sync。見 [共用 repo 導航](dev-projects.zh-TW.md)。

## 在這個 dotfiles repo 中的安裝方式

`installCodingAgents=true` 時，`coding_agents` ansible role 會安裝三個工具：
Sidecar、配套的 `marcus/td`，以及完整 [Tasks 工具組](tasks.zh-TW.md)。
Herdr 的安裝與此開關分開。

- macOS：優先使用 Homebrew (`marcus/tap`)
- Linux：優先使用 Homebrew (Linuxbrew)；備援為 GitHub release 的二進位檔，安裝到 `~/.local/bin`

## 手動安裝

### macOS（建議）

```bash
brew install marcus/tap/td
brew install marcus/tap/sidecar
```

### GitHub Releases

- `td`：<https://github.com/marcus/td/releases>
- `sidecar`：<https://github.com/marcus/sidecar/releases>

## 驗證安裝

```bash
td version
sidecar --version
```

## 參考資料

- [td docs](https://marcus.github.io/td/)
- [sidecar docs](https://sidecar.haplab.com/)

---

> ** `add` 和 `new` 都是 `create` 的 alias，三個命令指向同一個功能。

## 目前 td 模型（v0.65.0）

2026-09-25 核對；取代舊版 DAG 與「local-only、沒有 remote sync」的結論。

- Issue 管理工作狀態、priority、dependencies 與 handoff context；不能證明
  branch 已 merge 或 checkout 可移除。
- Worktrees 通常共用 project database，但 `.td-root`、local `.todos`、
  associations 與 main-worktree resolution 會影響實際 store。Session／focus
  identity 已包含 worktree 與 agent／branch，不只是 branch-scoped。
- Review policy 可配置。Trusted mode 可使用具名 reviewer 或有 reason 的
  explicit self-review；不同 session 並非普遍必要條件。`review` 可從 logs
  補建缺少的 handoff。以已安裝 CLI help 為準，不沿用旧 DAG 當現行契約。
- 已有 remote sync，可同步 issues、logs、handoffs、boards、work sessions；
  session 與 host-local checkout bindings 仍留在本機。已配置 project 的一般
  CLI 啟動可能 auto-sync，不是嚴格唯讀 inventory API。
- Adapter 必須把 process cwd 設為選定 checkout；`--work-dir` 只選 DB base，
  不更改 process cwd。

日常導航使用 [dev-projects](dev-projects.zh-TW.md)。Td 保持可選，issue content
由 td 管理；不要把 `closed` 同步為 dev `done` 或當 worktree 刪除授權。
隔離的 Sidecar 試用期間仍以 Herdr 作主要 runtime。

來源：[sync guide](https://github.com/marcus/td/blob/v0.65.0/docs/sync-client-guide.md)、
[review policy](https://github.com/marcus/td/blob/v0.65.0/docs/status-and-review.md)、
[session state](https://github.com/marcus/td/blob/v0.65.0/internal/db/session_state.go)、
[workdir resolution](https://github.com/marcus/td/blob/v0.65.0/internal/workdir/workdir.go)。
