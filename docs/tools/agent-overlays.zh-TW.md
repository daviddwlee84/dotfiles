# Coding-agent CLI 覆寫 (Cursor / OpenCode / Codex)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本 repo 透過 chezmoi 的 `modify_` 覆寫 (overlay) 管理三個 coding-agent CLI 的*全域*設定檔：

| CLI | 即時檔案 | 來源腳本 | 合併引擎 |
|---|---|---|---|
| Cursor | `~/.cursor/cli-config.json` | [`dot_cursor/modify_cli-config.json.tmpl`](../../dot_cursor/modify_cli-config.json.tmpl) | `jq '. * $overlay'` |
| OpenCode（server/runtime） | `~/.config/opencode/opencode.json` | [`dot_config/opencode/modify_opencode.json.tmpl`](../../dot_config/opencode/modify_opencode.json.tmpl) | `jq '. * $overlay'` |
| OpenCode (TUI) | `~/.config/opencode/tui.json` | [`dot_config/opencode/modify_tui.json.tmpl`](../../dot_config/opencode/modify_tui.json.tmpl) | `jq '. * $overlay'` |
| Codex | `~/.codex/config.toml` | [`dot_codex/modify_config.toml.tmpl`](../../dot_codex/modify_config.toml.tmpl) | Python `tomllib` + 自製 inline emitter |

覆寫內容 (overlay payloads) 位於 [`.chezmoitemplates/agents/`](../../.chezmoitemplates/agents/) 之下，並透過 `{{ template ... }}` include 引入，讓合併邏輯可以獨立於覆寫內容進行測試。

> **為什麼不用 Charm [`crush`](https://github.com/charmbracelet/crush)？** `crush` 是 Charm 自家的 agentic coding CLI。要加進來會多出第五份 overlay（binary + auth + 每專案信任 + marketplace 狀態），而每個 agent overlay 的維運成本不低 — 任何在執行期重寫自身設定檔的 CLI 都需要一個感知 hook 的合併器、TOML/JSON round-tripper 與 `.chezmoiignore.tmpl` 的存在性 gating。現有三組（Cursor / OpenCode / Codex，加上透過 `dot_claude/modify_settings.json` 管理的 Claude Code）已涵蓋實務上的 agent CLI 設計空間。如要評估 `crush`，加第五個 CLI 的模式是：在 `dot_ansible/roles/coding_agents/tasks/main.yml` 安裝、新增 `dot_crush/modify_<config>` 與 `.chezmoitemplates/agents/crush.overlay.<json|toml>`、選擇性接到 `04_ai_capture.zsh` 的 agent 偵測鏈。

## 為什麼用 `modify_` 而非完整檔案管理

這三個 CLI 都會**在執行期重寫自己的設定檔**，以記錄機器本地狀態：認證 token、telemetry ID、每專案信任授權、含絕對路徑的 marketplace 註冊、外掛 (plugin) 快取雜湊、最後使用的 provider 提示等。若將整個檔案視為受管內容，會：

1. 將機密（`authInfo`、`auth.json` 內容）洩漏進 dotfiles repo。
2. 把某台機器的絕對路徑（`/Users/me/.codex/.tmp/...`）烙進另一台機器的 apply。
3. 隨著 CLI 不斷攪動該檔案，產生持續的 `chezmoi diff` 雜訊。

`modify_` 覆寫模型只深層合併 (deep-merge) 我們明確指定的 key；其他內容原樣穿透。

## 各覆寫實際強制了什麼

### Cursor — [`agents/cursor.cli-config.overlay.json`](../../.chezmoitemplates/agents/cursor.cli-config.overlay.json)

```json
{
  "editor": { "vimMode": true }
}
```

- `editor.vimMode = true` — 通用偏好；同層的 `editor.fontSize` 等會在深層合併中被保留。
- **`permissions.allow` / `permissions.deny` 陣列刻意不放在覆寫中。** `jq '. * $overlay'` 會在同 key path 下整個替換陣列，所以在這裡列任何項目都會在每次 `chezmoi apply` 時把使用者本機特定的 allow-list 砍掉。請改為直接在每台機器的即時檔案上管理，或當你真需要共用 baseline 時改成 `--argjson allow $merged` 的陣列聯集做法。

### OpenCode — [`agents/opencode.overlay.json`](../../.chezmoitemplates/agents/opencode.overlay.json)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": true,
  "default_agent": "build",
  "small_model": "github-copilot/gpt-5-mini",
  "agent": { "title": { "reasoningEffort": "low" } },
  "provider": {
    "github-copilot": {
      "options": { "timeout": 600000 }
    }
  }
}
```

- `$schema` — 讓編輯器知道 schema 以便自動補全 (autocomplete)。
- `autoupdate = true` — 讓 CLI 自我更新。
- `default_agent = "build"` — TUI/CLI 啟動時的主要 agent。透過 `--agent` 或挑選器可在每次工作階段時覆寫。
- `small_model = "github-copilot/gpt-5-mini"` — 用於標題生成、摘要與其他輕量呼叫的便宜模型。避免將 Claude Opus 配額用在瑣碎任務上。與 `agent.title.reasoningEffort = "low"` 搭配。
- `agent.title.reasoningEffort = "low"` — 讓短標題生成使用便宜的 completion；同層的 `agent.*` 條目（per-agent provider、模型覆寫）會被保留。
- `provider.github-copilot.options.timeout = 600000`（10 分鐘） — 請求層級的超時。預設是 5 分鐘；提升以便長時間的 Claude Opus 生成有更多空間，免得 SDK 過早中止整個呼叫。**注意**：`chunkTimeout` 刻意不在這裡設定，原因見 [docs/tools/opencode.md → Claude Opus stream stall](opencode.md#claude-opus-stream-stall-on-github-copilot)（上游 bug [anomalyco/opencode#20466](https://github.com/anomalyco/opencode/issues/20466)——SSE-chunk-timeout 錯誤不會被重試，所以設定 `chunkTimeout` 只會把無聲卡住變成無法復原的硬性失敗）。

### OpenCode TUI — [`agents/opencode.tui.overlay.json`](../../.chezmoitemplates/agents/opencode.tui.overlay.json)

```json
{
  "$schema": "https://opencode.ai/tui.json",
  "keybinds": { "leader": "ctrl+x" },
  "mouse": true,
  "diff_style": "auto",
  "scroll_acceleration": { "enabled": true }
}
```

TUI 與 server/runtime 設定位於**不同檔案**：`~/.config/opencode/tui.json`，使用自己的 schema `https://opencode.ai/tui.json`。請見上游文件：

- [Config → TUI](https://opencode.ai/docs/config/#tui) — 檔案位置、schema URL、優先順序
- [TUI → Configure → Options](https://opencode.ai/docs/tui/#options) — 每個 key 的語意

逐 key 的設計理由：

- `$schema = "https://opencode.ai/tui.json"` — TUI 的 schema（與 `opencode.json` 的 `config.json` schema 不同）。讓編輯器能驗證並自動補全。
- `keybinds.leader = "ctrl+x"` — 明確釘選 (pin) 上游預設。明文寫出可確保肌肉記憶 + [docs/keybinds](https://opencode.ai/docs/keybinds/) 中的 `<leader>` 引用，能在未來上游預設變動時繼續成立。其餘約 80 個 keybind 預設刻意不釘選——讓它們追蹤上游，OpenCode 新增的動作就能直接可用，不會因覆寫而錯過。
- `mouse = true` — 明確釘選上游預設。為 OpenCode TUI 內的滑鼠支援（捲動、點擊）犧牲終端機原生的選取-複製。
- `diff_style = "auto"` — 依終端機寬度調整 diff 版面（相對於 `"stacked"` 強制單欄）。釘選上游預設讓意圖明確。
- `scroll_acceleration.enabled = true` — macOS 風格的平滑/加速捲動。根據上游文件，這**會優先於並覆蓋** `scroll_speed`，所以我們刻意省略 `scroll_speed`（同時設定兩者會誤導——後者會被靜默忽略）。

TUI 覆寫中刻意 NOT 包含的：

- `theme` — 不設定，讓 OpenCode 的自動明/暗偵測保持有效（與本 repo 中的 `ghostty`、`tmux` 主題切換器一樣，會跟隨系統主題）。
- 除 `leader` 外的個別 `keybinds.*` 條目 — 見上述。fzf 的 shell 層級 `Ctrl+T` 與 OpenCode 的 `variant_cycle = ctrl+t` 不會衝突，因為它們處於不相交的命名空間（shell prompt vs OpenCode TUI）。
- `username_toggle` / `tips_toggle` / `display_thinking` — 這些是 TUI 的 `/help` 自訂面板在執行期持久化的內容。釘選在覆寫中會在每次 `chezmoi apply` 時砍掉使用者上一次在應用內的選擇——與管理 `plugin` 路徑或認證 token 是同一種反模式。
- `scroll_speed` — 見上述 `scroll_acceleration.enabled`；只要加速啟用，OpenCode 就會忽略 `scroll_speed`。

### Codex — [`agents/codex.config.overlay.toml`](../../.chezmoitemplates/agents/codex.config.overlay.toml)

```toml
personality = "pragmatic"
model = "gpt-5.4"
model_reasoning_effort = "xhigh"

[features]
hooks = true
unified_exec = true
shell_snapshot = true
steer = true
multi_agent = true

[plugins."github@openai-curated"]
enabled = true

[plugins."google-drive@openai-curated"]
enabled = true

[plugins."computer-use@openai-bundled"]
enabled = true
```

- 頂層的模型與 reasoning 偏好。
- `[features]` — 啟用此使用者一律想開啟的實驗性 flag。
- `[plugins."<id>".enabled]` — 精選的外掛集；使用者自行安裝的外掛會以自己的 `[plugins."..."]` 區塊出現，並在深層合併中被保留。

這個覆寫層刻意**不**持久化 `[model_providers.openai]` 覆寫。Codex CLI 允許用一次性的 `-c` 傳入這些 knob，但會拒絕在 `config.toml` 中覆寫 `openai` 這類保留的 built-in provider ID。modify 腳本會移除早期實驗留下的 `[model_providers.openai]` stale table，同時保留 `[model_providers.openai-gfw]` 這類自訂 provider ID。

## 刻意不管理的內容

| 檔案 / 子樹 | CLI | 原因 |
|---|---|---|
| `~/.cursor/{authInfo,auth*,privacyCache,statsigBootstrap,version,hasChangedDefaultModel,...}` | Cursor | 認證 + telemetry；僅執行期。 |
| `~/.cursor/{extensions,plugins,projects,worktrees,workers,browser-logs,chats,plans,prompt_history.json,argv.json,ide_state.json,agent-cli-state.json,ai-tracking,mcp.json,skills-cursor}` | Cursor | CLI 管理的狀態，每專案、機器本地。 |
| `~/.config/opencode/{node_modules,package.json,bun.lock,package-lock.json,plugins/}` | OpenCode | Node 執行期 + 本機安裝的外掛原始碼樹。 |
| `~/.config/opencode/tui.json` 中 TUI 覆寫之外的 key（`theme`、除 `leader` 外的 `keybinds.*`、`username_toggle`、`tips_toggle`、`display_thinking`、`scroll_speed`） | OpenCode | TUI 執行期自訂面板會把使用者選擇持久化於此；覆寫只釘選穩定偏好。 |
| `~/.codex/auth.json` | Codex | OpenAI 認證 token。**絕對**不要 check in。 |
| `~/.codex/[projects."<absolute-path>"]` | Codex | 每專案信任授權——絕對路徑是機器特定的。由 modify_ 腳本**完整往返保留** (round-trip)（見下文）。 |
| `~/.codex/[marketplaces.<id>]` | Codex | 含絕對 `source = "/Users/.../.codex/.tmp/..."` 路徑的 marketplace 註冊。**完整往返保留**。 |
| `~/.codex/{installation_id,history.jsonl,session_index.jsonl,sessions/,logs_*.sqlite*,state_*.sqlite,cache/,tmp/,log/,sqlite/,memories/,vendor_imports/,shell_snapshots/,models_cache.json,plugins/,skills/,rules/,ambient-suggestions/,version.json,AGENTS.md,.tmp/}` | Codex | 工作階段、log、sqlite、外掛/skills 目錄、機器本地筆記。 |

`.chezmoiignore.tmpl` 透過 `stat` 檢查對整個 `~/.cursor/`、`~/.codex/`、`~/.config/opencode/` 樹做存在閘控 (presence-gating)，因此未安裝的 CLI 永遠不會產出幽靈目錄。

## Codex TOML 合併如何運作

`jq` 不會說 TOML，而 `mikefarah/yq` 的 TOML emitter 對含特殊字元的 key（例如 `github@openai-curated`）會輸出無效內容。Codex 的 `modify_` 腳本改用 Python：

1. 透過 `tomllib` 將即時檔案讀進 `dict`（Python 3.11+ 內建；3.10 fallback 用 `tomli`）。
2. 將 `[projects]` 與 `[marketplaces]` 子樹彈出到 `state`。
3. 將覆寫 TOML 讀進一個 `dict`。
4. 深層合併：`live_minus_state <- overlay <- state`。引數順序就是合併優先順序（後者勝出）。`state` 最後勝出，使每專案信任永遠不會被覆寫攪動所砍掉。
5. 透過 30 行的 writer 輸出 TOML，並對所有非 bareword 的 key 加引號（處理 `github@openai-curated` 與 `/Users/me/foo` 風格的專案 key）。

若 `python3` 或 `tomllib`/`tomli` 都缺失，腳本會 fall through 把即時檔案原封不動傳出；這次 apply 會被 chezmoi 跳過該檔案。

## OpenCode 舊版 `config.json` 遷移

OpenCode 現在的官方文件建議以 `opencode.json` 作為標準檔名，但在改名前安裝的環境會用 `config.json`。Repo 只管理新檔名；一個一次性腳本處理遷移：

- [`run_once_before_50_opencode_migrate.sh.tmpl`](../../run_once_before_50_opencode_migrate.sh.tmpl) 會在每個 source-state 雜湊執行一次，於 chezmoi 部署檔案之前。它會：
  1. 若 `~/.config/opencode/config.json` 不存在 → no-op。
  2. 若只存在舊檔：將其更名為 `opencode.json`。
  3. 若兩者都存在：把舊檔深層合併進新檔（衝突時新檔勝出，因為推測較新），然後刪除舊檔。

此腳本執行後，`modify_opencode.json` 覆寫會在統一檔案上強制受管 key。舊檔名不會再出現，因為 OpenCode 自身往後只寫 `opencode.json`。

此遷移腳本可在推出後幾個月（一旦所有機器都至少跑過一次 `chezmoi apply`）從 repo 中移除；它是 idempotent 的，在新機器上也是 no-op，所以無限期保留也安全。

## 更新 (refresh) 流程

要變更某個覆寫所強制的內容，編輯對應的 `.chezmoitemplates/agents/<cli>.overlay.{json,toml}`。**不要** `chezmoi add` 即時設定——那會把 `modify_` 前綴去掉，並用執行期檔案（其中含你的機密）覆蓋掉腳本。

要將即時檔案中的新 key 拉進覆寫中（例如你改了一個想要共享的 Cursor 權限）：

```bash
# 1. 檢查即時檔案
jq . ~/.cursor/cli-config.json

# 2. 編輯覆寫的 JSON / TOML 並加入該 key
$EDITOR .chezmoitemplates/agents/cursor.cli-config.overlay.json

# 3. 驗證渲染後的 modify_ 腳本輸出符合預期
chezmoi execute-template < dot_cursor/modify_cli-config.json.tmpl > /tmp/m.sh
chmod +x /tmp/m.sh
cat ~/.cursor/cli-config.json | /tmp/m.sh

# 4. 套用
chezmoi apply
```

## 測試

[`tests/unit/agent_overlays.bats`](../../tests/unit/agent_overlays.bats) 涵蓋：

- 各覆寫對其宣告的 key 確實有強制效果。
- 覆寫之外的即時執行期 key 原樣保留。
- Codex 的 `[projects.*]` 與 `[marketplaces.*]` 完整往返不變（這個往返性質是承載性 (load-bearing) 不變量——破壞它，機器之間就會開始互砍對方的每專案信任）。
- `modify_` 腳本是 idempotent（將其輸出再餵回腳本會得到同一份輸出）。
- OpenCode 遷移處理三種輸入狀態：只有舊檔、兩者皆存在、兩者皆無。
- Claude 的掛鉤感知合併器 (hook-aware merger)（見下節）：notify.sh 在缺失時加入；CodeIsland 條目保留；重新 apply 時 idempotent；非掛鉤的深層合併保留使用者同層 key。

執行：`just bats`（或直接：`bats tests/unit/agent_overlays.bats`）。

## CodeIsland 整合（僅限 macOS）

[CodeIsland](https://github.com/wxtsky/CodeIsland) 是 macOS 瀏海區 (notch) 的 HUD（位置上類似 [CodexBar](https://github.com/steipete/CodexBar)），會即時顯示 11 個以上 coding-agent CLI（`Claude Code`、`Codex`、`Gemini`、`Cursor`、`Copilot`、`OpenCode`、`AntiGravity`、`Trae`、`Qoder`、`Factory`、`CodeBuddy`、`Kimi`）的活動。它的做法是注入每個 CLI 的掛鉤 (hook) 條目，這些掛鉤會觸發 `~/.codeisland/codeisland-bridge`（或 `codeisland-hook.sh`），透過 `/tmp/codeisland-<uid>.sock` 上的 Unix socket 將事件串流給 SwiftUI 應用程式。

### 為什麼僅限 macOS

- Swift 應用程式，需要 macOS 14（Sonoma）或更新版本。
- 瀏海 UI 假設 MacBook 顯示器幾何。
- 透過 brew cask（`wxtsky/tap`）或 `.dmg` 散布。

沒有 Linux 替代方案——傳輸格式仰賴 macOS 特定的 bridge binary 與 socket 路徑。我們在 Linux 上刻意不安裝任何 CodeIsland 相關內容，並跳過所有相關考量。

### 安裝

`codeisland` cask 加在 [`dot_config/homebrew/Brewfile.darwin.tmpl`](../../dot_config/homebrew/Brewfile.darwin.tmpl) 裡的 `{{ if .installAiDesktopApps }}` 區塊中，與其他 agent 桌面應用程式並列：

```ruby
tap "wxtsky/tap"
cask "codeisland"
```

### 我們如何與該應用程式共存

CodeIsland 的設定面板自稱為「Auto hook install」並標榜「auto-repair and version tracking」——意思是該**應用程式會主動寫入並重寫**每個被偵測到的 CLI 設定中的掛鉤條目，每次啟動時都會。共存有兩種模式：

> **附註（2026-04-25）**：CodeIsland v1.0.23 將 `ExitPlanMode` 從預設的 `HookServer.autoApproveTools` 白名單中移除——退出 plan-mode 現在會跳出真正的確認對話框，而 Settings → Behavior → 「Auto-approve Tools」讓使用者可以逐項切換工具。見 [`pitfalls/codeisland-auto-approves-permissionrequest.md`](../../pitfalls/codeisland-auto-approves-permissionrequest.md)。我們的合併器繼續以*累加方式* (additively) 保留每一個 CodeIsland 掛鉤條目——沒有加入扣除式 (subtractive) 邏輯，因為上游修正才是正確路徑，且 `PermissionRequest` 掛鉤現在是瀏海彈出視窗的合法輸入來源，而非繞過機制。

#### Pattern A — 周邊檔案 (sidecar files)（永遠忽略）

掛鉤位於專屬周邊檔案（除了 CodeIsland 掛鉤外什麼都沒有）的 CLI，直接不讓 chezmoi 管理。具體來說：

| 檔案 | CLI | 不管理的原因 |
|------|-----|---------------|
| `~/.codex/hooks.json` | Codex | 純 CodeIsland 周邊檔案（某些設置中也會被 Superset 的 notify.sh 擴展，但那是 Superset 安裝的，不是我們） |
| `~/.cursor/hooks.json` | Cursor | 同上 |
| `~/.copilot/hooks/codeisland.json` | GitHub Copilot CLI | 純 CodeIsland 周邊檔案 |
| `~/.gemini/settings.json` | Gemini CLI | 目前沒有其他內容需要強制 |
| `~/.antigravity/settings.json` | AntiGravity（CLI，不是編輯器） | 目前沒有其他內容需要強制 |

這些路徑被加到 [`.chezmoiignore.tmpl`](../../.chezmoiignore.tmpl) 中作為**永遠忽略**，這樣即使不小心執行 `chezmoi add ~/.codex/hooks.json` 也不會把 CodeIsland 擁有的檔案拉進 source 樹（那會砍掉應用程式的執行期更新，並與其自動安裝器形成乒乓循環）。

如果你之後想在 `~/.gemini/settings.json` 或 `~/.antigravity/settings.json` 中管理非掛鉤偏好，請寫一個遵循下方掛鉤感知模式的 `modify_` 覆寫——並移除對應的 ignore 行。

#### Pattern B — 混合檔案（掛鉤感知合併器）

當穩定的使用者偏好與 CodeIsland 掛鉤共存於同一檔案時，需要更聰明的覆寫。目前唯一這類檔案是 **`~/.claude/settings.json`**——`Claude Code` 將模型選擇、外掛、statusLine 與 `permissions.defaultMode` 與 `hooks.<event>` 陣列存在同一個檔案。簡單的 `jq '. * $overlay'` 深層合併會整個替換陣列：在覆寫中宣告一個 `hooks.Notification` 條目，會在每次 `chezmoi apply` 時靜默砍掉所有 CodeIsland 條目，然後 CodeIsland 會在下次啟動時重裝——無限乒乓，產生 diff 雜訊與壞掉的整合。

[`dot_claude/modify_settings.json`](../../dot_claude/modify_settings.json) 透過掛鉤感知合併器解決這個問題：

1. **非掛鉤的 key**（`enabledPlugins`、`extraKnownMarketplaces`、`skipDangerousModePermissionPrompt`、`permissions.defaultMode`、`statusLine`……）以正常方式透過 `base * overlay_no_hooks` 深層合併。注意：`permissions.defaultMode = "auto"` 是刻意設定的，用來繞過 `Claude Code` 在每次互動 prompt（`AskUserQuestion`、CodeIsland 彈窗、遠端控制注入）後重設目前權限模式的行為——重設一律落回 `defaultMode`，因此把它釘住就能讓重設變得無感。`auto`（由安全分類器逐一審核動作）於 2026-07 取代了 `bypassPermissions`：它同樣能修正重設問題，卻不必授予整個 repo 範圍的全面放行。見 [`pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md`](../../pitfalls/claude-code-permission-mode-resets-after-interactive-prompt.md)。深層合併會寫入 `defaultMode` 純量值，不會動到同層的 `permissions.allow` / `permissions.deny` 陣列——那些保持機器本地。
2. **`hooks.<event>` 陣列**以累加方式合併：對於覆寫中宣告的每個事件，附加那些 `.hooks[0].command` 在即時陣列中還沒出現的條目（字串相等比對）。即時條目會原樣保留，永遠不會移除任何條目。

完整 jq filter：

```jq
. as $base
| ($overlay | del(.hooks)) as $non_hook_overlay
| ($overlay.hooks // {}) as $overlay_hooks
| ($base * $non_hook_overlay) as $merged
| $merged
| .hooks = (
    ($merged.hooks // {}) as $live_hooks
    | reduce ($overlay_hooks | to_entries[]) as $ev (
        $live_hooks;
        .[$ev.key] = (
          (.[$ev.key] // []) as $live_arr
          | ($live_arr | map(.hooks[0].command? // "")) as $live_cmds
          | $live_arr + (
              $ev.value
              | map(select(
                  (.hooks[0].command? // "") as $cmd
                  | ($cmd == "") or (($live_cmds | index($cmd)) == null)
                ))
            )
        )
      )
  )
```

`tests/unit/agent_overlays.bats` 中的測試覆蓋：

- `claude modify_settings: notify.sh added to empty hooks, codeisland entries preserved` — 證明累加 append 能在不移除 CodeIsland 條目的前提下運作。
- `claude modify_settings: idempotent when notify.sh already present` — 證明重新 apply 不會出現重複。
- `claude modify_settings: empty live file produces overlay-only output` — 在新機器上的 bootstrap。
- `claude modify_settings: non-hook deep-merge preserves siblings` — 證明使用者新增的 plugins/marketplaces 會留下來。

> **同層覆寫**：`~/.claude/keybindings.json` 由獨立、較簡單的 `modify_` 腳本管理——[`dot_claude/modify_keybindings.json`](../../dot_claude/modify_keybindings.json)。它**不是**掛鉤感知的（CodeIsland 不會寫入 keybindings.json）。請見 [Claude Code keybindings](claude-code-keybindings.md) 了解其設計、`chat:cycleMode` 唯一模式跳轉的限制，以及如何加入個人綁定覆寫。

### 未來工作（暫緩）

- **`~/.claude/hooks/notify.sh` 的 Apprise-to-webhook 擴充**：腳本目前已呼叫 `apprise --tag desktop` 做本機 OS 通知。可擴充為也觸發 `apprise --tag webhook`，使用 `~/.config/apprise/apprise.yaml` 中設定的 URL 把通知送到遠端聊天應用（Slack、Discord、Telegram……）。待解決問題：雜訊過濾——webhook 應該每次 `Notification`/`Stop` 都觸發，還是只在權限請求與工作階段結束時觸發？多半需要環境變數閘 (`CLAUDE_NOTIFY_WEBHOOK=1`)，讓每台機器主動 opt-in。在另一個變更中追蹤。
- **`~/.gemini/settings.json` 與 `~/.antigravity/settings.json` 的受管覆寫**：等到具體偏好需要強制再做。新增時，仿照 Claude 的掛鉤感知合併器模式（這兩個檔案今天也都有 CodeIsland 注入的 `hooks` 區塊）。
