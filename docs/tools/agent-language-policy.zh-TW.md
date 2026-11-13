# Agent 語言規則（`agentLanguagePolicy`）

Coding agent 用什麼語言寫東西，取決於**誰會讀、會留多久**：對話用繁體中文；plan 檔用繁體中文，專有名詞保留英文；長期文件跟著 repo 既有慣例，沒有慣例就用英文。

> **TL;DR** —— 設定 `agentLanguagePolicy = "zh-TW"`（`personal-mac` / `work-mac` bundle 預設就是這個值），`chezmoi apply` 之後會部署 `~/.claude/rules/language-policy.md`。你自己的 `~/.claude/CLAUDE.md` 如果存在，完全不會被動到。

## 規則內容

| 輸出 | 語言 |
|---|---|
| 對話：回覆、提問（包含選擇題選項）、進度回報 | 繁體中文（台灣用語） |
| Plan mode 的 plan 檔 | 敘述用繁體中文，標題可以中英並列 |
| README、`docs/`、ADR、docstring、code comment、commit message、PR | 照 repo 慣例（以 repo 的 CLAUDE.md / AGENTS.md 為準），沒有慣例就用英文 |
| 內部推理（thinking） | 不限制，用最有效的方式（通常是英文） |

中文內容裡，翻譯後可能有歧義的技術名詞、identifier（路徑、函式名、CLI flag、config key、錯誤訊息）和產品名稱都保留英文。第一次出現時可以加中文註解，例如 `race condition（競態條件）`。

規則原文以 [`.chezmoitemplates/agent-language-policy.md`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoitemplates/agent-language-policy.md) 為準，跟 Windows repo 的那份逐字相同。要修改請改 template，不要改部署出去的檔案。

## 怎麼接起來的

- **Prompt**：`agentLanguagePolicy`（`none` | `zh-TW`，預設 `none`），而且要 `installCodingAgents` 也是 true 才會生效。
- **部署目標**：`~/.claude/rules/language-policy.md`。Claude Code 會把 `~/.claude/rules/` 底下每個檔案當作 user-level rule，在所有 project 中跟 `~/.claude/CLAUDE.md` 一起載入，所以不需要 `@import`，也不用改 CLAUDE.md。
- **Gate**：沒開 gate 時，`dot_claude/rules/language-policy.md.tmpl` 會 render 成空字串；chezmoi 遇到 render 結果是空的 target 會把它刪掉，所以改回 `none` 後，下次 apply 就會移除這個 rule。chezmoi 只管這一個檔名，`~/.claude/rules/` 底下的其他檔案都是你的。

改設定：

```bash
chezmoi init --prompt   # 或直接改 ~/.config/chezmoi/chezmoi.toml 裡的 agentLanguagePolicy
chezmoi apply
```

驗證方式：開一個新的 Claude Code session，執行 `/memory`，應該會看到這條 user rule。

## 設計取捨

- **為什麼不用 `settings.json` 的 `language`？** Claude Code 會把這個值原樣變成「always respond in X」，commit message 和 docs 也會被拉成中文，還會一起改 voice dictation 和 session title 的語言。要依場合區分語言，只能寫成規則。
- **為什麼不寫進 `~/.claude/CLAUDE.md`？** 那是你手寫的檔案。改用 rules 檔，就完全不需要 migration 或 merge。如果你的 CLAUDE.md 也寫了語言規則，兩邊會同時載入，衝突時 Claude 可能照任一邊做，所以請刪掉其中一邊。
- **為什麼 plan 檔要單獨列一條？** Plan 也是 markdown 文件，不明確寫出來的話，會被「文件用英文」那條規則吃掉。
- **為什麼不限制 thinking？** 多語言 reasoning model 的研究（例如 Qi et al. 2025，*When Models Reason in Your Language*）指出，強制用使用者的語言寫 thinking trace 會降低準確度。這份規則只管人會讀到的輸出。
- **範圍**：只涵蓋 Claude Code。Codex 的 `~/.codex/AGENTS.md` 是使用者自己的檔案，也沒有 rules 目錄，見 `TODO.md`。

跨平台的決策紀錄：[dotfiles-all `docs/agent-language-policy.md`](https://github.com/daviddwlee84/dotfiles-all/blob/main/docs/agent-language-policy.md)。
