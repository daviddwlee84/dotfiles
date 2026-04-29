# CodexBar CLI

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[CodexBar](https://github.com/steipete/CodexBar) 顯示 AI 編碼工具（`Codex`、`Claude Code`、`Cursor`、`Gemini`、`Copilot` 等）的使用統計，無需登入各家儀表板。

- **macOS**：完整選單列 (menu bar) 應用程式 + CLI
- **Linux**：僅 CLI

## 安裝

由 `coding_agents` ansible role 自動安裝。在 Linux 上，二進位檔置於 `~/.local/bin/codexbar`。

## Linux 用法

在 Linux 上，`usage` 命令**必須**傳入 `--source cli`。預設來源 (`auto`/`web`) 僅限 macOS。

### 檢查即時用量（rate limits / 配額）

```bash
# Claude session/weekly 限額
codexbar usage --provider claude --source cli

# 其他 provider
codexbar usage --provider codex --source cli
codexbar usage --provider gemini --source cli
codexbar usage --provider copilot --source cli

# JSON 輸出（供腳本 / Waybar 使用）
codexbar usage --provider claude --source cli --json --pretty
```

範例輸出：

```
== Claude 2.1.34 (claude) ==
Session: 14% left [=-----------]
```

### 檢查本機成本（從 JSONL 日誌讀取，無需驗證）

`cost` 命令讀取本機日誌檔（例如 `~/.claude/`），不需要驗證。

```bash
# 全部 provider
codexbar cost

# 僅 Claude
codexbar cost --provider claude

# JSON 輸出
codexbar cost --provider claude --json --pretty

# 強制重新掃描日誌
codexbar cost --refresh
```

範例輸出：

```
Claude Cost (local)
Today: $0.54 · 851K tokens
Last 30 days: $8.50 · 9.1M tokens
```

## Shell aliases

定義於 `~/.config/zsh/tools/40_codexbar.zsh`：

| Alias | 命令 | 說明 |
|-------|---------|-------------|
| `cbu` | `codexbar usage --provider claude --source cli` | Claude 用量 |
| `cbc` | `codexbar cost --provider claude` | Claude 本機成本 |
| `cbca` | `codexbar cost` | 所有 provider 本機成本 |

## 支援的 provider

`codex`、`claude`、`cursor`、`opencode`、`factory`、`gemini`、`antigravity`、`copilot`、`zai`、`minimax`、`kimi`、`kiro`、`vertexai`、`augment`、`jetbrains`、`kimik2`、`amp`

## 提示

- 在 Linux 上避免對 `usage` 使用 `--provider all`——它會依序嘗試每個 provider，若某個 CLI 未安裝可能會卡住。
- `cost` 命令會掃描本機 JSONL 日誌檔，可離線運作。
- `usage --source cli` 命令會呼叫 provider 的 CLI（例如 `claude`）以取得即時 rate-limit 資料。
- 設定檔：`~/.codexbar/config.json`
