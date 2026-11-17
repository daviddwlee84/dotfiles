# SpecStory CLI

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

`SpecStory` 記錄終端機的編碼代理 (coding agent) 工作階段 (session)，並能透過 `specstory run` 包裝受支援的代理。

## 在本 dotfiles repo 中的安裝

`specstory` 由 `coding_agents` ansible role 自動安裝。

- macOS：優先使用 Homebrew，並以 GitHub release 退回安裝至 `~/.local/bin`
- Linux：從 GitHub release tarball 安裝至 `~/.local/bin`

## 全域與專案設定

本 dotfiles repo 管理使用者層級的 SpecStory 設定 `~/.specstory/cli/config.toml`。

`SpecStory` 依以下順序讀取設定：

1. 使用者層級設定：`~/.specstory/cli/config.toml`
2. 專案層級設定：`./.specstory/cli/config.toml`
3. 傳給 `specstory` 的 CLI flag

後者覆蓋前者。也就是說 dotfile 提供全域預設值，而 repo 專屬的 `.specstory/cli/config.toml` 可在專案需要不同行為時覆寫之。

!!! note "以 overlay（`modify_`）管理，而非一般受管理檔案"
    使用者層級設定由 chezmoi `modify_` 腳本（`private_dot_specstory/private_cli/modify_private_config.toml.tmpl`）依 template `.chezmoitemplates/specstory/config.toml` 產生。SpecStory 是外部寫入者：`specstory resume` 會把 `[resume]` 區塊（`view_mode` / `last_agent`）寫回這個檔，所以一般受管理檔案會永遠 drift。每次 `chezmoi apply` 時，template 中每個**啟用中**的 key 都會以 template 為準；其他 live key 一律保留：`[resume]` 這類未知區塊整塊保留，受管理區塊裡多出的 key 也會保留，例如 `[local_sync]` 底下主機本機的 `local_time_zone = true`。從 template 刪掉某個 key **不會**從主機上移除它，請改成設定想要的值。live 檔若不是合法 TOML，apply 會直接報錯，而不是覆蓋掉。請修改 template，不要對 target 做 `chezmoi add`（會把腳本蓋掉）。這個檔以前是 `create_`（只種一次），因此 template 更新永遠到不了既有主機。`private_` 屬性是為了配合 SpecStory 自己改寫這個檔時用的 0600 權限；少了它，每次 `resume` 都會造成 mode drift。

## 受管理的預設值

受管理的設定保留上游範例區塊作為註解文件，只啟用 `[providers]` 與 `[redaction]` 預設值。

已設定的 provider（SpecStory 2.17 對本機 CLI 接受的所有 `*_cmd` key）：

| Key | 命令 | Bypass 機制 |
|---|---|---|
| `antigravity_cmd` | `agy --dangerously-skip-permissions` | 自動核准所有 tool 請求 |
| `claude_cmd` | `claude --dangerously-skip-permissions` | bypassPermissions（`--permission-mode auto` 是由 classifier 把關的替代方案） |
| `codex_cmd` | `codex --dangerously-bypass-approvals-and-sandbox -c model_reasoning_summary="detailed"` | = `-a never -s danger-full-access` |
| `copilot_cmd` | `copilot --yolo` | = `--allow-all`（tools、paths、URLs） |
| `cursor_cmd` | `cursor-agent --force` | 除非明確拒絕，否則全部執行 |
| `droid_cmd` | `droid --yolo` | — |
| `gemini_cmd` | `gemini --yolo` | 自動核准所有 tools |
| `opencode_cmd` | `opencode --auto` | 自動核准所有未明確拒絕的請求 |
| `pi_cmd` | `pi` | Pi 沒有權限提示 |
| `qwen_cmd` | `qwen --yolo` | 自動核准所有 tools |

`deepseek_cmd` / `grok_cmd` / `muse_cmd` 以註解形式提供 —— 它們的 bypass flag 尚未驗證。IDE/cloud provider（`copilotide`、`cursoride`、`cursorcloud`）不會透過 `run` 啟動本機 CLI，因此沒有對應項目。

其他非 provider 的預設值：`[redaction] enabled = true`（明確固定，避免上游預設改變時悄悄關掉 secret redaction）。Analytics 與 cloud sync 維持上游預設（cloud sync 只有登入 SpecStory Cloud 時才會開啟）。

這些是 `specstory run claude`、`specstory run codex` 與類似 provider 捷徑預設會執行的命令，除非在專案內或命令列上另行覆寫。

Codex 的 model 與 reasoning effort 刻意**不**在此固定 —— 它們來自 `~/.codex/config.toml`。只保留 `model_reasoning_summary="detailed"`，讓存下的 markdown 保有 reasoning 文字。（最初的 seed 固定了 `model_reasoning_effort="high"` 與已過時的 `model_supports_reasoning_summaries=true`；Codex 0.156+ 會把後者列為被忽略的 `session-flags` 設定。）Gemini 過去使用 `--sandbox=none`，它只控制 sandbox，從未跳過核准；真正的 bypass 是 `--yolo`。

既有主機在下一次 `chezmoi apply`（或 `fleet-apply`）時就會套用 template 變更，不需要手動重新種。

### 一律明寫 provider —— 無參數的預設值並不穩定

`<id>_cmd` 只控制某個 provider **怎麼啟動**，從來不決定裸的 `specstory run` **挑哪一個**。設定裡沒有 `default_provider` 這個 key：沒有參數時，specstory 會解析成其 provider registry 中**字母序第一個**項目。因此 2.9.0 只是「加入」`antigravity`，就在所有既有安裝上悄悄把 `claude` 從預設位置擠掉，而 `specstory run --help` 也跟著重新生成成 `By default, launches Antigravity CLI.`。由於 `agy` 已安裝，錯的 agent 會成功啟動、完全不報錯。

請一律寫 `specstory run claude`。本 repo 的包裝層已經這麼做 —— 見 `dot_config/shell/22_sesh.sh` 的 `_sesh_wrap_agent()`（由 `scode` / `svibe` / `hcode` / `hvibe` 共用）與 [pitfalls/specstory-run-default-agent-drift.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/specstory-run-default-agent-drift.md)。
## 安全取捨

設定的 provider 命令刻意傾向低摩擦的代理執行：

- Claude 與 Antigravity 使用 `--dangerously-skip-permissions`
- Codex 使用 `--dangerously-bypass-approvals-and-sandbox`（無核准、無 sandbox）
- Copilot、Droid、Gemini 與 Qwen 使用 `--yolo`；Cursor 使用 `--force`；OpenCode 使用 `--auto`
- Pi 完全沒有權限層

這移除了大部分互動式權限提示，對快速本機工作流程很有用，但同時也讓被包裝的代理擁有更廣的檔案系統或命令存取權。只有在您信任該環境並重視便利勝於更嚴格的護欄時，才保留這些預設值。若否，請在全域檔、專案本機設定或 `specstory run -c ...` flag 中覆寫相關的 provider 命令。

## 驗證

```bash
specstory --version
specstory run codex --help
chezmoi diff
```

## 另見

- [SpecStory internals (filename algorithm, reverse lookup, markdown structure)](specstory-internals.md) — 本 repo 的 `tv agent-sessions` 通道用於將即時 session 連回 `.specstory/history/*.md` 的依據。

## 參考資料

- [SpecStory CLI usage docs](https://docs.specstory.com/integrations/terminal-coding-agents/usage#configuration)
- [SpecStory CLI releases](https://github.com/specstoryai/getspecstory/releases)
- [SpecStory CLI source on DeepWiki](https://deepwiki.com/specstoryai/getspecstory) — Go 實作的技術參考（自動產生）。
