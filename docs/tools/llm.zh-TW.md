# 本地 LLM 工具

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

選用角色 (`installLlmTools`)。透過 `chezmoi init --force` 安裝並啟用此 prompt。

## 相關筆記

- [OpenCode](opencode.md)：local-only 的 OpenCode 設定筆記、已知的標題生成 (title-generation) 退化問題，以及目前的 workaround。

## 工具

| 工具 | 執行檔 | 用途 | 安裝路徑 |
|------|--------|------|----------|
| [Ollama](https://ollama.com/) | `ollama` | 本地 LLM runtime 與 API 伺服器 (server) | macOS：Homebrew formula 或透過 Brewfile 的 `ollama-app`；Linux：官方安裝程式 |
| [LiteLLM](https://github.com/BerriAI/litellm) | `litellm` | LLM 後端的本地代理 (proxy) / 統一 API | `uv tool install litellm[proxy] --with httpx[socks]` |
| [llmfit](https://github.com/AlexsJones/llmfit) | `llmfit` | 推薦適合你硬體的模型 | macOS：Homebrew formula；Linux：官方本地安裝程式 |
| [models](https://github.com/arimxyer/models) | `models` | 瀏覽模型、benchmarks、coding agents、供應商狀態 | macOS/Linuxbrew：Homebrew formula；Linux fallback：`cargo install modelsdev` |

## 平台說明

- **macOS，`installBrewApps=false`**：ansible 透過 Homebrew formulas 安裝 `ollama`、`llmfit` 與 `models`。
- **macOS，`installBrewApps=true`**：ansible 仍會安裝 `llmfit` 與 `models`，但 `ollama` 改由 `~/.config/homebrew/Brewfile.darwin` 中的 `ollama-app` 處理。
- **Linux 含 sudo**：ansible 安裝 `litellm`、`llmfit`、`models` 與 `ollama`。
- **Linux 含 `noRoot=true`**：ansible 安裝 `litellm`、`llmfit` 與 `models`，並明確跳過 `ollama`。

## macOS GUI vs CLI

- 當你已透過 `installBrewApps=true` 選擇加入 GUI 應用時，優先使用 `ollama-app`。
- 若只想要 CLI/runtime 而不要 GUI 應用，使用 `brew install ollama`。
- macOS 應用程式也會在 app bundle 內提供 `ollama` CLI。

## 常見用法

```bash
# 啟動 Ollama API 伺服器
ollama serve

# 執行 LiteLLM proxy
litellm --help

# 檢查哪些模型適合你的硬體
llmfit

# 瀏覽模型與 benchmarks
models
```

## noRoot 提醒

`noRoot=true` 會跳過 `ollama`，因為官方 Linux 安裝路徑會設定系統層級位置與 systemd 服務 (service)。其他工具仍以使用者層級安裝。
