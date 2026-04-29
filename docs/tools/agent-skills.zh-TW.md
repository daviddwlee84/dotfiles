# Agent skills (`vercel-labs/skills`)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本 repo 以兩種方式管理 [`vercel-labs/skills`](https://github.com/vercel-labs/skills)
agent skills，兩者的範圍迥異。

## TL;DR

| 範圍 | 鎖定檔 (lock file) | skill 所在位置 | 還原來源 |
|---|---|---|---|
| **全域** (Global)（每個專案、每個 shell） | `~/.agents/.skill-lock.json`（chezmoi 管理） | `~/.agents/skills/<name>/` | 每次 `chezmoi apply` 由 `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl` 執行 |
| **專案** (Project)（僅在本 repo 工作目錄內，用於編輯 skills） | `./skills-lock.json`（git 追蹤） | `./.agents/skills/<name>/` | 每次 `chezmoi apply` 由 `.chezmoiscripts/repo/run_onchange_after_45_bootstrap_skills.sh.tmpl` 執行（當 source dir == repo 時）；手動備援：`just bootstrap-skills` |

兩個範圍今天碰巧重疊（都會安裝
`project-knowledge-harness`），但用途不同——見下方「為什麼兩個範圍？」。

## 全域範圍：每台機器都必備的 skills

skills CLI **目前還不支援**從 lock 檔執行 `npx skills install -g`
（[上游 issue #283](https://github.com/vercel-labs/skills/issues/283)、
[#549](https://github.com/vercel-labs/skills/issues/549)）。所以我們手工拼出兩段式還原：

### `dot_agents/modify_dot_skill-lock.json.tmpl` — 合併器

一個 `modify_` 腳本，負責 `~/.agents/.skill-lock.json`。每次 `chezmoi
apply`：

1. 從 stdin 讀取即時 lock 檔。
2. 將腳本頂端 `$managed` 中宣告的**受管集合** (managed-set) 合併進
   `.skills`，並保留即時條目中的任何 `installedAt`/`updatedAt`/`skillFolderHash`。
3. 保留**不在**受管集合中的任何 `.skills.<name>` 條目（這樣臨時用
   `npx skills add … -g` 安裝的也能存活）。
4. 原樣保留 `.dismissed` 與 `.lastSelectedAgents` 等每台機器的狀態。

要宣告新的全域必備 skill，編輯該腳本中的 inline `$managed` JSON：

```json
{
  "skills": {
    "your-new-skill": {
      "source": "owner/repo",
      "sourceType": "github",
      "sourceUrl": "https://github.com/owner/repo.git",
      "skillPath": "skills/your-new-skill/SKILL.md"
    }
  }
}
```

然後執行 `chezmoi apply`。合併器會把新條目寫進 lock；還原腳本（下一節）會看到磁碟上缺少 skill 並安裝它。

### `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl` — 還原器

`onchange` 雜湊觸發是合併器腳本自身的 SHA256——所以這個腳本只在**受管集合**被編輯時重跑（不會因為來自隨機 `npx skills update -g` 活動的即時 lock 變化而重跑）。

對 `~/.agents/.skill-lock.json` 中的每個條目：

- 若 `~/.agents/skills/<name>/SKILL.md` 存在 → 跳過（已安裝）。
- 否則 → `npx skills add <source> -s <name> -g -y`。

這是 idempotent 的：在已完全安裝的機器上重跑會印出
「All globally-managed agent skills present; nothing to install」並退出。

### 手動安裝新 skill 之後

如果你在某台機器上以互動方式執行了 `npx skills add foo/bar -g`，並想讓它變成全機隊受管：

1. `cat ~/.agents/.skill-lock.json` — 找到 CLI 剛寫入的條目。
2. 把 `source` / `sourceType` / `sourceUrl` / `skillPath` 複製進
   `dot_agents/modify_dot_skill-lock.json.tmpl` 的 `$managed.skills` 區塊。
3. Commit。其他主機在下一次 `chezmoi apply` 時就會抓到。

如果你只想在某一台機器上保留它，什麼都不用做——合併器會在來源機器上保留即時條目，其他主機根本看不到它。

## 專案範圍：編輯本 repo 用的便利

`./skills-lock.json` + `./.agents/skills/` 純粹是為了讓**你在編輯 chezmoi repo 自身時**，從 repo 根目錄啟動的 agent 能對它所文件化的 repo 使用 `project-knowledge-harness`。它們**不會**被部署（被 chezmoi 忽略：見 `.chezmoiignore.tmpl` → `.agents/skills`、
`.claude/skills`、`skills-lock.json`），且**不被** git 追蹤，唯獨
`skills-lock.json` 例外（`.gitignore` 涵蓋 `.agents/`、`.claude/skills/`）。

`chezmoi apply` 時透過
`.chezmoiscripts/repo/run_onchange_after_45_bootstrap_skills.sh.tmpl` 自動還原。腳本會：

1. 檢查 `.chezmoi.sourceDir` 是否包含 `skills-lock.json`（即這台機器的 chezmoi 來源目錄就是 repo）。若否則靜默退出——專案 skills 只在你以 agent 編輯 repo 時才有意義。
2. 快速路徑：若 lock 中列出的每個 skill 都已有
   `./.agents/skills/<name>/SKILL.md`，無需呼叫 npx 即退出。
3. 否則從來源目錄執行 `npx skills@latest experimental_install`，重建
   `./.agents/skills/...` 與 `./.claude/skills/...` 符號連結 (symlink)。

觸發雜湊：`skills-lock.json` 內容的 SHA256，所以腳本只在 lock 真的變動時才重跑。

手動備援（如果你想強制重新 bootstrap，或你把 repo clone 到不是 chezmoi 來源目錄的路徑）：

```sh
just bootstrap-skills
# → npx skills@latest experimental_install
```

## 為什麼兩個範圍？

| 使用情境 | 安裝在哪 |
|---|---|
| 你想在每台機器、每個專案中都有的 skill | 全域（編輯合併器腳本中的 `$managed`） |
| 只在這個特定 repo 內才有意義的 skill | 專案（從 repo 根目錄執行 `npx skills add ... -y`，commit `skills-lock.json`） |
| 還在本機原型階段、尚未決定的 skill | 專案，穩定後再升級為全域 |

`project-knowledge-harness` 今天同時在**兩個**範圍中存在，因為（a）這個 harness 本身針對*任何*專案，所以屬於全域；（b）我們想立刻在 chezmoi repo 上使用它，全域安裝涵蓋了這點，但專案範圍讓 lock 檔依賴對任何讀 `skills-lock.json` 的人都明確可見。

## `npx skills` 實際如何接到 agent（機制參考）

由閱讀 [`vercel-labs/skills/src/agents.ts`](https://github.com/vercel-labs/skills/blob/main/src/agents.ts)
與 [`installer.ts`](https://github.com/vercel-labs/skills/blob/main/src/installer.ts) 驗證。重要的原因是：CLI 的「我幫你為 agent X 安裝了 skill」訊息**不**代表 agent X 在執行期真的會去讀 `~/.agents/skills/`——那是各 agent 的慣例，不是保證。

### 兩種安裝策略

| 策略 | CLI 寫入什麼 | 使用此策略的 agent |
|---|---|---|
| **通用** (Universal)（`skillsDir: '.agents/skills'`） | 不在 agent 特定目錄寫任何東西；agent 直接讀 `~/.agents/skills/`（全域）或 `./.agents/skills/`（專案） | `cursor`、`opencode`、`codex`、`gemini-cli`、`copilot`、`antigravity`、`warp`、`replit`、`cline`、`kimi-cli`、`firebender`、`deep-agents` |
| **每 agent 符號連結** (per-agent symlink) | 將 `~/.<agent>/skills/<name>` 符號連結 → `~/.agents/skills/<name>`（在 Windows 上是複製） | `claude-code`、`augment`、`bob`、`cortex`、`crush`、`goose`、`junie`、`kilo`、`kiro`、`kode`、`roo`、`trae`、`windsurf` 等 |

跳過的判斷發生在 `installer.ts`：

```ts
if (isGlobal && isUniversalAgent(agentType)) {
  return { /* skipped: no symlink, no copy */ };
}
```

所以 `npx skills add foo -g -a cursor -a opencode` 在
`~/.cursor/skills/` 或 `~/.opencode/skills/` 下產生**零**個檔案。Cursor 與 OpenCode 在執行期是否真的會抓 `~/.agents/skills/foo/SKILL.md`，取決於那些 agent 自己（Anthropic 的 Skills 規範是 `Claude Code` 的；其他 agent 是按慣例採用，不是契約）。

### Lock 檔名衝突（容易搞混）

| 路徑 | 範圍 | 擁有者 |
|---|---|---|
| `~/.agents/.skill-lock.json` | 全域，**單數** `skill-` | Skills CLI |
| `./skills-lock.json` | 專案，**複數** `skills-` | Skills CLI |

Schema 不同（全域是 v3，含 `dismissed`/`lastSelectedAgents`；專案較扁平）。不要把其中一個 symlink 到另一個。

### 還原指令與其怪癖

| 指令 | 它做什麼 |
|---|---|
| `npx skills experimental_install` | 只還原**專案** lock（`./skills-lock.json`） |
| `npx skills experimental_install -g` | `-g` 會被**靜默忽略**，仍只是專案範圍（[#283](https://github.com/vercel-labs/skills/issues/283)、[#549](https://github.com/vercel-labs/skills/issues/549)） |
| `npx skills update -g` | 更新已安裝的全域 skill；**不會**從 lock 回填遺失的條目 |
| `npx skills add <source> -s <name> -g -y` | 唯一可用的「還原一個遺失的全域 skill」慣用法——也就是 `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl` 迴圈所執行的內容 |

### CLI flag 陷阱

- **當 skills 位於 `skills/` 之下時，repo 簡寫需要 `/skills` 後綴**。
  `npx skills add owner/repo` 會看該 repo 的 `.agents/skills/`；
  `npx skills add owner/repo/skills` 會看 `skills/`。大多數第三方 skill repo 採用後者佈局。
- **`-a` 不接受逗號分隔值**。請重複 flag：
  `-a claude-code -a opencode -a cursor`。
- **Agent 名稱會被正規化** (normalised)（`claude-code` 而非 `claude`、
  `gemini-cli` 而非 `gemini`、`copilot` 而非 `github-copilot`）。執行
  `npx skills add --list`（或觸發驗證錯誤）以查看正規名單。

### 各 agent 的環境變數覆寫

支援自訂設定目錄的 agent 會改變 symlink/skill 讀取位置：

| 環境變數 | 預設 | 效果 |
|---|---|---|
| `CLAUDE_CONFIG_DIR` | `~/.claude` | Skills CLI 改在這裡寫 symlink |
| `CODEX_HOME` | `~/.codex` | Codex 從這裡抓 skills（Codex 屬於通用策略，所以全域安裝無論如何都依賴 `~/.agents/skills/`） |
| `XDG_CONFIG_HOME` | `~/.config` | 影響 Cursor/OpenCode/Gemini-CLI 的查找路徑 |

如果你設定了任一個並重新執行 `npx skills add -g`，CLI 會寫到新位置；chezmoi 的 lock 檔管理仍使用
`~/.agents/.skill-lock.json`（lock 與位置無關）。

## 反模式 (anti-patterns)

- **不要把 skill 來源檔案（`.agents/skills/<name>/SKILL.md`、
  templates 等）放進 chezmoi 來源。** 它們由 npx skills CLI 擁有；
  chezmoi 管理它們會與 CLI 的 `skillFolderHash` 不斷打架。只有**lock 檔**由 chezmoi 管理。
- **不要執行 `chezmoi re-add ~/.agents/.skill-lock.json`** 來捕捉本地變更。請改編輯合併器的 `$managed` 區塊——那是真實來源 (source-of-truth) 的清單。`re-add` 會把某台機器的狀態快照凍結進來源中，破壞合併器的每機器保留行為。
- **不要 commit `./.agents/skills/`**。它們是 npx CLI 在每次 `update` 時會重寫的 skill 來源 clone；追蹤它們會產生雜訊 diff 並與上游 skill 更新意外衝突。
- **不要在 `bootstrap-skills` 加 `-g`**。該 recipe 設計上是專案範圍；全域由 `chezmoi apply` 擁有。

## 參考資料

- 即時的 `dot_agents/modify_dot_skill-lock.json.tmpl` — 合併器真實來源
- 即時的 `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl` — 還原迴圈
- [`vercel-labs/skills` README](https://github.com/vercel-labs/skills) — CLI 文件
- [Issue #283 — `skills install -g`](https://github.com/vercel-labs/skills/issues/283)
- [Issue #549 — global lock restore](https://github.com/vercel-labs/skills/issues/549)
- [`docs/tools/agent-overlays.md`](agent-overlays.md) — 同類模式：Claude/Cursor/OpenCode `settings.json` 覆寫（同樣以 `modify_` 為基礎）
