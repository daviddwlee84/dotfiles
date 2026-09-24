# Tasks — 個人任務規劃

[Tasks (`marcus/tasks`)](https://github.com/marcus/tasks) 是以本機資料為主的
任務管理工具，提供 Inbox、Next actions、Agenda 與 Projects，資料以 JSONL
檔案儲存。它處理個人規劃；[`td`](td_sidecar.zh-TW.md) 處理 agent 的 issue 與
handoff；Sidecar 則提供兩者的使用介面。

## 安裝的工具組

`installCodingAgents=true` 時，`coding_agents` role 會安裝三個執行檔：

| 指令 | 用途 |
|---|---|
| `tasks` | 讀取與修改任務清單的 CLI。 |
| `tasks-tui` | 獨立的鍵盤與滑鼠介面。 |
| `tasks-api` | 手動啟動的 loopback HTTP API；安裝不會啟動服務。 |

macOS 使用 `marcus/tap/tasks`。Linux 優先使用同一個 Linuxbrew formula，
失敗時改用經校驗碼 (checksum) 驗證的官方 amd64/arm64 release，將整組安裝到
`~/.local/bin`，不需要 Go toolchain。見
[上游安裝說明](https://github.com/marcus/tasks/blob/v1.17.0/README.md#install)。

此 installer 不支援原生 Windows。截至 2026-09-25，
[v1.17.0 release](https://github.com/marcus/tasks/blob/v1.17.0/.goreleaser.yml)
只提供 macOS 與 Linux；Windows 請在 WSL 內使用 Linux 安裝方式。
本次沒有驗證原生 Windows 執行。

## 首次設定資料位置

Tasks 要求明確指定資料位置。只有在 **config 不存在**，且 `TASKS_DIR`、
`TASKS_FILE`、`TASKS_ARCHIVE`、`TASKS_MEMORY` 都沒有非空值時，dotfiles 才會
建立一次性的 `key = value` 設定，沿用本機 XDG 路徑：

| 項目 | XDG 位置 | 預設值 |
|---|---|---|
| Config | `$XDG_CONFIG_HOME/tasks/config` | `~/.config/tasks/config` |
| 資料目錄 | `$XDG_DATA_HOME/tasks` | `~/.local/share/tasks` |

首次設定會建立這兩個目錄，並寫入**絕對資料路徑**：
`dir = /absolute/path/to/tasks`。這不是 TOML，路徑不要加引號。
不會建立任務紀錄、範例資料或同步設定。相對 XDG 路徑會被拒絕，不會以
apply 當下的目錄解讀。

此後 config 與任務資料由使用者維護；後續 apply 會保留既有檔案、符號連結
(symlink) 與環境變數覆寫。遇到不完整的既有設定時只回報，不會取代。
用 `tasks config --json` 查看生效路徑；installer 也使用此 CLI 驗證設定。

每個檔案先讀取**對應的環境變數，再讀 config 的 `file` / `archive` / `memory`
設定**。沒有逐檔設定的 live/archive 才由目錄推導，目錄依序讀 `TASKS_DIR`、
config `dir`；未指定 memory 時則放在最終 live 檔案旁。因此 `TASKS_DIR` 不會
蓋過 config 已指定的逐檔路徑。逐檔配置需要同時提供 live 與 archive。
要換資料位置，編輯既有 config 或環境變數；dotfiles 不會搬移資料。見
[v1.17.0 resolver](https://github.com/marcus/tasks/blob/v1.17.0/internal/config/config.go#L89)，
並以 `tasks config --json` 確認實際結果。

## 開始使用

```bash
tasks --version
tasks config --json
tasks-tui
```

`tasks inbox`、`tasks next`、`tasks agenda` 可在 shell 查看規劃清單。
例如 `tasks capture "Review the release notes"` 會新增任務；`tasks help`
列出指令。需要本機 API 時才手動執行 `tasks-api`，預設 endpoint 為
`http://127.0.0.1:4747/api/v1`。見
[CLI 與 API 概覽](https://github.com/marcus/tasks/blob/v1.17.0/README.md#use)。

## Sidecar 裡的 Tasks

Sidecar 內嵌 Tasks 分頁；**Tasks / Beta 是否啟用仍由使用者決定**，在
Configuration → Panels & Integrations 調整。安裝工具組不會改寫 Sidecar
設定。獨立指令與內嵌介面可使用同一份 Tasks store；此 store 與 td 的 project
database 分開，不會取代 td issue 或 handoff。

Sidecar 帶有自己的 Tasks UI 程式碼，因此升級獨立工具組不會更新內嵌版本；
Sidecar 需另外升級。見
[Sidecar Tasks 指南](https://github.com/marcus/sidecar/blob/v1.14.0/website/docs/tasks.md)
及[三個工具的角色](td_sidecar.zh-TW.md)。

## 升級與選用同步

Homebrew/Linuxbrew 安裝由 `just upgrade-brew` 更新，或明確執行 `brew update`
後再執行 `brew upgrade marcus/tap/tasks`。Linux release fallback 則需明確下載、
驗證 checksum，並一起替換**三個執行檔**；`chezmoi apply` 仍只負責安裝。
見[升級步驟](../this_repo/upgrades.zh-TW.md#tasks-suite)。

私人 Git 同步由使用者選用與配置；dotfiles 不建立同步 repository、不安裝
merge driver，也不啟動 API 服務。有需要時參考
[上游多裝置同步](https://github.com/marcus/tasks/blob/v1.17.0/docs/multi-device-sync.md)。
