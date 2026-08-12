# Codex status line

Codex 現在使用內建 TUI footer；不安裝 fork，也不加 PATH shim。Chezmoi 只把下列
provider-neutral 清單合併進 `~/.codex/config.toml`，其餘 project trust、provider、
plugin 與 live settings 都保留：

```toml
[tui]
status_line = [
  "model-with-reasoning",
  "fast-mode",
  "git-branch",
  "context-remaining",
  "task-progress",
  "current-dir",
]
```

需要確認實際路由時請看 `/status`。在 `codex-copilot` session 中，Model provider
應顯示 localhost；Account 仍顯示已登入 ChatGPT 帳號並不代表 inference 繞過 proxy，
那只是 UI/auth state。

## 為什麼不放 quota 欄位

Codex 也提供 `five-hour-limit` 與 `weekly-limit`，但 one-shot launcher 只更換 model
provider 時，這些數字仍可能屬於 ChatGPT account。和 Copilot inference 並列會造成
誤解，因此 footer 只顯示 provider-neutral 事實；帳號用量仍可用
[CodexBar](codexbar.zh-TW.md) 補充查看。

## 為什麼不裝 Claude-HUD 類 extension

原生 Codex 只接受固定 status item ID，不能執行任意 status command，也不能做自訂
ANSI/conditional rendering。第三方 `@jiawang1209/codex-hud` 必須 patch 並編譯舊版
Codex Rust tree，再把 shim 放到官方 binary 前面。為了 footer 承擔這個升級與
supply-chain surface 不划算，所以只記錄研究、不安裝。

`codex_apps` 與 footer、Codex.app 都無關；它是
`https://chatgpt.com/backend-api/wham/apps` 的遠端 ChatGPT MCP，Intel 或 Apple
Silicon 的 CLI 都能用。`copilot-proxy doctor --live` 會把它與 localhost Copilot
inference 分開，分別測 direct 與 detected HTTP proxy。

參考：[Codex configuration](https://developers.openai.com/codex/config-reference)、
[fixed status-item limitation](https://github.com/openai/codex/issues/20244)、
[custom status-line request](https://github.com/openai/codex/issues/17827)。
