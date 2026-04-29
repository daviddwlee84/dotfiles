# OpenCode

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本機 `OpenCode` 設定的相關筆記——涵蓋 chezmoi 管理的覆蓋層 (overlay)、上游 `title` agent regression，以及 GitHub Copilot 上 Claude Opus 串流停滯 (stream stall) 的 workaround。

## 全域設定如何被管理

`~/.config/opencode/opencode.json` 全域設定**部分**透過 chezmoi `modify_` 覆蓋層（jq 深度合併）管理。標準的覆蓋層內容與每個鍵的理由請參閱 [agent-overlays.md → OpenCode](agent-overlays.md#opencode-agentsopencodeoverlayjson)。

TUI 專用的設定 `~/.config/opencode/tui.json`（獨立檔案、獨立 schema——見上游 [Config → TUI](https://opencode.ai/docs/config/#tui)）也透過 `modify_` 覆蓋層管理；釘住了哪些（目前為 `keybinds.leader`、`mouse`、`diff_style`、`scroll_acceleration.enabled`）以及哪些刻意留給 TUI 執行期自訂面板（`theme`、`username_toggle` 等）見 [agent-overlays.md → OpenCode TUI](agent-overlays.md#opencode-tui-agentsopencodetuioverlayjson)。

舊版的 `~/.config/opencode/config.json` 檔名會透過 [`run_once_before_50_opencode_migrate.sh.tmpl`](../../run_once_before_50_opencode_migrate.sh.tmpl) 在每台機器上一次性遷移為新版的 `opencode.json`；見 [agent-overlays.md → OpenCode legacy migration](agent-overlays.md#opencode-legacy-configjson-migration)。

刻意**不**放在覆蓋層中的項目（即留作機器本機狀態）：

- `plugin` 路徑——本機設定中帶有 `~/.config/opencode/plugins/` 之下的絕對路徑；覆蓋層會踩掉每台機器特有的路徑。
- 驗證 token、telemetry ID、最近使用 provider 提示——由 CLI 在執行期寫入；覆蓋層要嘛清掉它們，要嘛在每次 apply 時與 CLI 打架。

如果未來真的需要跨機器共享 plugin，請將其打包為 npm module，並以套件名稱（而非 `file://` 路徑）加入覆蓋層的 `plugin` 陣列。

## 已知問題：session 標題卡在 `New session - ...`

於本機自 OpenCode `1.4.6` 開始觀察到；在 `1.14.x` 仍適用。

症狀：

- 新 session 維持回退標題 `New session - <timestamp>`
- 標題產生未自動完成

根因：

- 隱藏的 `title` agent 使用 `github-copilot/gpt-5-mini` 來執行輕量化的標題請求
- OpenCode 送出 `reasoning_effort = "minimal"`
- `gpt-5-mini` 拒絕該值，因為它只接受 `low`、`medium` 或 `high`

上游追蹤：

- [anomalyco/opencode#22796](https://github.com/anomalyco/opencode/issues/22796) — title agent 使用不支援的 `reasoning_effort: minimal`

### Workaround（受管理）

覆蓋層強制執行：

```json
{
  "agent": { "title": { "reasoningEffort": "low" } },
  "small_model": "github-copilot/gpt-5-mini"
}
```

`reasoningEffort: "low"` 繞過 `minimal` 被拒的問題。`small_model` 被明確釘住，使得無論主 session 用哪個 provider，title-agent + 摘要 pipeline 永遠使用便宜的模型。

### 何時可移除此 workaround

確認以下所有條件後，可從覆蓋層拿掉 `agent.title.reasoningEffort` 覆寫：

- 上游 regression 已修正
- 本機已安裝新版 OpenCode
- 全新 session 自動產生非回退標題
- OpenCode 日誌不再對 title 請求顯示 `reasoning_effort: "minimal"`

## GitHub Copilot 上 Claude Opus 的串流停滯

當使用 `github-copilot/claude-opus-4.x` 通道執行長時間的工具呼叫——典型情境是針對數千行檔案的單一大型 `write`——TUI 會反覆顯示 `~ Preparing write...` 後接 `Tool execution aborted`，有時持續數分鐘，直到使用者按 ESC。

### 從日誌診斷

`~/.local/share/opencode/log/<timestamp>.log` 顯示：

- 同一個 `messageID` 重複以 SDK retry-backoff 序列重新串流：`+2009ms → +4013ms → +8045ms → +16011ms → +30023ms → +30015ms ...`（`30000ms` 上限是 SDK 的最大 backoff）
- 每次重試之間，有 `+60000ms` 的間隔且無 `message.part.delta` 事件——SSE 串流閒置了，GitHub Copilot proxy 在 server 端關掉了它
- 模型已對 `write` 發出 `tool_use`，但 JSON `input` 欄位仍在串流時 SSE 就死了——這正是產生「Preparing write...」→「aborted」UX 的原因，因為該 tool call 在結構上不完整

### 根因

GitHub Copilot 在上游 Anthropic 之前的 proxy 對串流回應強制執行閒置逾時 (idle timeout)（社群觀察為約 ~60 秒）。`Claude Opus` 在產生極大的單一 tool-call payload 時，可能足夠久維持在 chunk 發送門檻以下而觸發此機制，之後連線會無聲死掉。直連 Anthropic API 沒有此行為。Sonnet 觸發機率低於 Opus，因為它產生速度較快。

**沒有 client 端的旗標可停用 proxy 的閒置逾時**——它在 server 端強制執行。

### 上游追蹤

- [anomalyco/opencode#17578](https://github.com/anomalyco/opencode/issues/17578) — 完全吻合的症狀：`Write tool SSE timeout with claude-opus-4.x via GitHub Copilot when generating long markdown files`。回報者發現 **Pyright LSP 的診斷會被附加到 tool 回應上**，膨脹了 SSE payload，使停滯更易發生。即使是寫一個 `.md` 檔，在含有 Python 原始碼但未設定 venv 的 repo 中，也可能觸發整個專案的重新掃描。修復見 PR `#18894`（撰寫時尚未合併）。
- [anomalyco/opencode#17574](https://github.com/anomalyco/opencode/issues/17574)、[#17307](https://github.com/anomalyco/opencode/issues/17307)、[#17318](https://github.com/anomalyco/opencode/issues/17318)、[#17336](https://github.com/anomalyco/opencode/issues/17336) — 同一 SSE 停滯模式的更多回報；`#17307` 是新增 `chunkTimeout` 作為 stop-gap 的原始 issue。
- [anomalyco/opencode#20466](https://github.com/anomalyco/opencode/issues/20466) — **`chunkTimeout` 實際上不會 retry**：當 chunk-timeout 觸發時，產生的 `SSE read timed out` 錯誤被包裝為 `NamedError.Unknown`，而 `retry.ts` 中的 `retryable()` 判定式拒絕它（`JSON.parse()` 分支失敗）。淨效果：設定 `chunkTimeout` 會把無聲的數分鐘卡死轉為**沒有自動 retry** 的硬失敗，這通常比不設它而仰賴 SDK 的 request-level retry 體驗更差。修復見 PR `#21727` 與 `#23501`（兩者皆未合併）。
- [anomalyco/opencode#21173](https://github.com/anomalyco/opencode/issues/21173) — OpenAI Responses provider 上類似的問題（傳輸方式不同，形態相同）。

### 緩解（受管理）

覆蓋層設定：

```json
{
  "provider": {
    "github-copilot": {
      "options": { "timeout": 600000 }
    }
  }
}
```

- `timeout: 600000`（10 分鐘）延長 request-level 上限，讓合理長的生成不會被過早中止。
- **`chunkTimeout` 刻意不設定。** 本覆蓋層的舊版本曾設定 `chunkTimeout: 20000`，假設提早取消並 retry 會比等到完整 request timeout 更快解開卡住的串流。本機實測顯示該設定確實會觸發（`SSE read timed out` 約 ~20 秒，可在 `~/.local/share/opencode/log/2026-04-22T105313.log` 第 183、257 行看到），但因為上游 bug `#20466`，該錯誤**不會被 retry**——`retry.ts` 的 `retryable()` 拒絕該錯誤類別。淨結果是「20 秒卡住後硬失敗、無復原」，比「無聲卡住但 SDK 在 request 層 retry」更糟。已移除，等其中一個連結的 PR 合併再回來。

### LSP-payload 加重因子（Action 3 — 在 repo 根目錄管理）

依 `#17578`，SSE payload 包含了 OpenCode 為工作樹中檔案自動啟動的任何 LSP server 的診斷。在使用 PEP 723 inline-script-deps（`#!/usr/bin/env -S uv run --script`）的 chezmoi-managed dotfiles repo 中，Pyright 無法解析 inline 宣告的依賴，每個檔案會發出數十條 `reportMissingImports` 診斷，這些就會搭便車跟在每次 tool 回應上。為了壓掉這些雜訊，chezmoi repo 根目錄帶有一個 [`pyrightconfig.json`](../../pyrightconfig.json)，它：

- 排除 ansible role 樹、chezmoi 來源目錄 (`dot_*/`)、agent 轉譯目錄 (`.specstory/`、`.claude/`、`.cursor/`、`.opencode/`) 以及 `backups/`，
- 設定 `reportMissingImports = "none"`，使 PEP 723 腳本不再污染診斷通道。

該檔案位於 repo 根目錄（不在任何 `dot_*/` 來源路徑底下），因此屬於 chezmoi git repo 的一部分但永不會被部署到 `$HOME`。

### 行為性緩解（不受管理）

如果某次生成仍反覆失敗，可提示 agent 改為：

1. 先以小型 `write` 寫入精簡骨架，
2. 接著透過多次 `edit` 呼叫逐段填入（每次約 ~50–80 行，每次一個邏輯區塊）。

這避免了引發停滯的單次巨型 tool-call payload。經驗上這是本 session 中最可靠的修法——遠比任何 client 端的逾時調整更有效。並未透過全域 `instructions` 強制執行，因為那會膨脹每個 session 的 system prompt；當已知 repo 會產生大型生成檔案時，加一條 per-project `AGENTS.md` 規則更恰當。

### 何時應重新檢視

- 如果 `#20466` 合併（PR `#21727` / `#23501` 之一），就把 `chunkTimeout` 加回覆蓋層——屆時它會真的 retry 而非硬失敗。
- 如果 `#17578` / PR `#18894` 合併，LSP-payload 加重因子在上游消失，根目錄的 `pyrightconfig.json` 從關鍵修法降為雙重防線。
- 如果 GitHub Copilot 提高 proxy 閒置逾時，整節可刪除，並把覆蓋層中 `timeout` 還原為上游預設。
- 如果您改用直連 Anthropic API（`provider.anthropic.options.apiKey`）並完全停用 Copilot 通道跑 Claude，覆蓋層中的 `provider.github-copilot` 區塊可拿掉。
