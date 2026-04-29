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

## 受管理的預設值

受管理的設定保留上游範例區塊作為註解文件，但只啟用 `[providers]` 預設值。

已設定的 provider：

- `claude_cmd = "claude --dangerously-skip-permissions"`
- `codex_cmd = 'codex -c model_reasoning_effort="high" --ask-for-approval never --sandbox danger-full-access -c model_reasoning_summary="detailed" -c model_supports_reasoning_summaries=true'`
- `cursor_cmd = "cursor-agent --yolo"`
- `droid_cmd = "droid --yolo"`
- `gemini_cmd = "gemini --sandbox=none"`

這些是 `specstory run claude`、`specstory run codex` 與類似 provider 捷徑預設會執行的命令，除非在專案內或命令列上另行覆寫。

## 安全取捨

設定的 provider 命令刻意傾向低摩擦的代理執行：

- Claude 使用 `--dangerously-skip-permissions`
- Codex 使用 `--ask-for-approval never` 與 `--sandbox danger-full-access`
- Cursor 與 Droid 使用 `--yolo`
- Gemini 使用 `--sandbox=none`

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
