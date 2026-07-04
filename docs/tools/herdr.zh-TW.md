# Herdr —— Rust 終端多工器 + AI agent 協調器（試用）

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) 是一個用 Rust 寫的終端多工器 (terminal multiplexer)，內建 **coding-agent 感知**——它會追蹤每個 pane 的 agent 狀態（idle / working / blocked / done）。它跟 tmux/zellij 屬於同一類工具，但更偏滑鼠優先 (mouse-first)、更 agent-native。官方文件：<https://herdr.dev/docs/>。

本 repo 把 herdr 當作一個**與 tmux 共存的試用工具 (trial tool)**——你只會執行 `herdr` *或* `tmux`，永不巢狀 (nested)。既有的 tmux / `sesh` / `tmuxp` / workmux 設定完全不動；herdr 純粹是加法，讓你能在不失去日常工具的前提下評估它。

- **安裝 (Install)**：
  - macOS —— Homebrew（`herdr` 在 homebrew-core；由 `dot_ansible/roles/devtools/tasks/main.yml` 的 macOS 清單管理）
  - Linux —— GitHub release 的**單一靜態 binary**（`herdr-linux-{x86_64,aarch64}`）放到 `~/.local/bin/herdr`（由同一 role 中 `# --- herdr ... ---` 區塊管理）。沒有 tarball，所以不需要解壓步驟。
- **驗證 (Verify)**：`herdr --version`；用 `herdr server reload-config` 驗證設定檔
- **升級 (Upgrade)**：macOS 用 brew；自管的 Linux binary 用 `herdr update`
- **設定 (Config)**：`~/.config/herdr/config.toml` —— chezmoi **只植入一次 (seed-once)**（`dot_config/herdr/create_config.toml`，`create_` 前綴）。herdr 會把 UI 設定寫回這個檔案（見 [設定回寫](#config-writeback-create_)），所以 chezmoi 在新機器上種下它之後就不再碰它。

> **不受 `enableVimMode` 控制。** 該 flag 管的是 shell + tmux 的 modal 編輯；herdr 的 copy mode（`prefix+[`）天生就是 vi 風格（`h/j/k/l`、`w/b/e`、`{`/`}`、`v`/Space 選取、`y`/Enter 複製、`q`/Esc 離開），沒有東西需要 gate。

---

## 與 tmux 的模型差異 (Model differences vs tmux)

herdr 的階層是 **Session → Workspace → Tab → Pane**——比 tmux（Session → Window → Pane）多一層。「Workspace」是專案層級的容器；「Tab」把多個 pane 分組。CLI（`herdr session|workspace|tab|pane|agent …`，大多支援 `--json`）是取代 `tmux switch-client` / `list-sessions` 等指令的腳本介面。

跟 tmux 最關鍵的差異：單一 herdr **server 會託管多個具名 session (named sessions)**，每個 session 各自是一棵持久化的樹、各自有自己的 socket。最上層的 **Session** 這一層，比較接近「多個 tmux server / socket」，而不是 tmux 的 session——你在 tmux 會叫做 session 的東西（`vibe/<repo>`）在 herdr 對應的是 **Workspace**，而不是 herdr Session。

### 具名 session (Named sessions) {#named-sessions}

- `herdr` —— 啟動或 attach **default** session（socket `~/.config/herdr/herdr.sock`）。
- `herdr --session NAME` —— 啟動/attach 一個**具名** session（socket `~/.config/herdr/sessions/<NAME>/herdr.sock`）。
- `herdr session list [--json]` —— 列出所有 session 及其 `running` + `socket_path`。**`--json` 的 `socket_path` 才是權威值**——純文字表格印出的是 `herdr.socket`，但真正的 socket 是 `herdr.sock`。
- `herdr session attach NAME` · `herdr session stop NAME` · `herdr session delete NAME`（stop 時 `default` 是合法的 `NAME`）。

**從 CLI 子指令鎖定某個 session**：`workspace`/`tab`/`pane`/`agent` **沒有 `--session`/`--socket` flag**。唯一的槓桿是 **`HERDR_SOCKET_PATH`** 這個環境變數 (env var)——把它設成某 session 的 `socket_path`，所有子指令就會導向該 session。在 herdr pane 內部它已經被 export 成當前 session 的 socket，所以*在 herdr 內*跑的腳本天生就鎖定當前 session。`hvibe --session NAME` 正是靠這個機制運作（見下文）。

## 可行性對照表 (Feasibility matrix)（現有 tmux 體驗 → herdr）

| 現有能力 | herdr 做法 | 這裡怎麼處理 |
|---|---|---|
| Catppuccin 主題 + 明暗 | **原生** `[theme]` + `auto_switch` | 在 `config.toml` 設定 |
| Splits / zoom / 開新 tab+workspace / pane 導覽 | **原生** `[keys]` actions | 重綁成 tmux 肌肉記憶 |
| Session 持久化（resurrect/continuum） | **原生** detach/reattach | 略過——原生 |
| 滑鼠 / 右鍵選單 | **原生** mouse-first | 略過——原生 |
| Agent 狀態 🤖/💬/✅（workmux，6 檔案） | **原生** 側欄 agent-state 彙整 | 略過——原生（tmux 端 workmux 不動） |
| `sesh` 模糊切換 + `tmuxp` layout | **Plugin** [herdr-plus](https://github.com/cloudmanic/herdr-plus) Projects + Quick Actions | Plugin + Projects 範本 |
| `tv` channel 彈窗（`prefix+T/U/a`） | **自訂 command pane**（`[[keys.command]] type="pane"`） | Key bindings + 2 個 herdr-aware channel |
| lazygit / scratch 彈窗 | **自訂 command pane** | Key bindings |
| 無縫 `Ctrl-hjkl` nvim↔pane 導覽 | **沒有 herdr-aware smart-splits** | **缺口**——見下方 workaround |
| OSC133 copy-mode（`cpout`/`cpblock`） | tmux 專屬 | **缺口**——`cpcmd`（zsh history）仍可用 |
| 每視窗狀態符號 + 書籤 ⭐📌 | **無 format-string 插值** | **缺口**——原生 agent dots 取代 agent 部分 |
| AI session-summary / agent-wakeup 擷取 | 可改用 `herdr pane read` / `pane list --json` 重寫 | **延後**——超出試用範圍 |

## 快捷鍵 (Keybindings)

Prefix 是 `ctrl+b`（跟 tmux 一樣）。內建 action 只能*重綁 (rebind)*（herdr 的 action 集合是固定的）；其餘一切都是 `[[keys.command]]` 自訂指令。自訂指令會收到 `$HERDR_SOCKET_PATH`、`$HERDR_ACTIVE_PANE_ID`、`$HERDR_ACTIVE_PANE_CWD`，並在聚焦 pane 的 cwd 下執行。

> **兩組 herdr 環境變數。** 上面那組 `HERDR_ACTIVE_PANE_*` **只**會被注入到 `[[keys.command]]` 的呼叫裡。而每個*跑在 herdr pane 內的 shell* 還會拿到一組**環境值 (ambient)**：`HERDR_ENV=1`、`HERDR_PANE_ID`、`HERDR_TAB_ID`、`HERDR_WORKSPACE_ID`、以及 `HERDR_SOCKET_PATH`（當前 session 的 socket）。腳本用 `HERDR_ENV` 當作「我在不在 herdr 裡？」的判斷，並繼承 `HERDR_SOCKET_PATH` 來鎖定當前 session——這正是 `hvibe`/`hcode` 依賴的東西。

| Key | Action | 類型 |
|---|---|---|
| `prefix + c` / `prefix + 1..9` | 新 tab / 切 tab | built-in default |
| `prefix + h/j/k/l` | 聚焦 pane | built-in default |
| `prefix + \|` / `prefix + minus` | 左右分割 / 上下分割 | rebound |
| `prefix + z` / `prefix + x` | zoom / 關 pane | built-in default |
| `prefix + w` / `prefix + g` | workspace 導覽 / session navigator | built-in default |
| `prefix + [` | vi copy mode（`hjkl`、`w/b/e`、`{/}`、`v`、`y`） | built-in default |
| `prefix + q` | detach | built-in default |
| `prefix + ?` | 快捷鍵說明覆蓋層——列出每個當前綁定與標籤（herdr 原生 which-key；手動觸發，非逾時自動提示） | built-in default |
| `prefix + ,` | 重新命名 tab | rebound（tmux 肌肉記憶） |
| `prefix + shift + r` | reload config（`prefix + r` 保留給 resize mode） | rebound |
| `prefix + shift + b` | 新 git worktree（從 `prefix + shift + g` 移過來） | rebound |
| `prefix + G` | lazygit | command pane |
| `prefix + U` | `tv tools`（CLI launcher） | command pane |
| `prefix + T` | `tv herdr-sesh`（workspace/dir 切換） | command pane |
| `prefix + a` | `tv herdr-agent-panes`（即時 agent panes） | command pane |
| `prefix + f` | `tv fleet-hosts`（SSH picker） | command pane |
| `` prefix + ` `` | scratch shell | command pane |
| `prefix + O` | herdr-plus **Projects**（layout launcher） | plugin action |
| `prefix + y` | herdr-plus **Quick Actions** | plugin action |

> 大寫字母會解析成 `prefix+shift+<letter>`，herdr 保留給內建（`shift+g` worktree、`shift+t` rename-tab、`shift+h/j/k/l` swap-pane）。`prefix+G`/`prefix+T` 由上面的重綁釋放出來；`herdr server reload-config` 會在它的 `diagnostics` 回報任何殘餘衝突。

## Session 輔助函式：`hvibe` / `hcode`（`svibe` / `scode` 的 herdr 版）

[`dot_config/shell/24_herdr.sh`](../shells/aliases.md#session-management) 裡有兩個 shell 函式，能一氣呵成拉起整個 coding workspace——就是 tmux 的 `svibe` / `scode` 在 herdr 端的對應物。它們呼叫原生的 `herdr workspace|tab|pane` CLI，並**原封不動重用 svibe 的純邏輯**（specstory 包裝、`--on-exit shell|kill|restart`、git-root 解析、agent-CLI 偵測），這些來自 `22_sesh.sh`；只有 layout 呼叫不同。需要 `herdr` server 正在跑 + `jq`。

| 指令 | 建立的 workspace | Layout |
|---|---|---|
| `hvibe [N] [CLI]` / `hvibe --agents claude,codex,opencode` | `vibe/<repo>` | tab `agents`（N 個等寬 agent pane）+ tab `git`（lazygit）+ tab `edit`（nvim） |
| `hvibe --tab-per-agent …` | `vibe/<repo>` | 每個 agent **一個 tab** + `git` + `edit` tab |
| `hcode [CLI]` | `coding-agent/<repo>` | tab `editor`（nvim 75% \| agent 25%）+ tab `monitor`（btop） |

- **每 repo 冪等 (idempotent)**：重跑會聚焦既有的 `vibe/<repo>` / `coding-agent/<repo>` workspace，而不是重複建立（對應 svibe 的「存在就 attach」）。
- **Attach 感知（像 svibe 的 `$TMUX` 分支）**：從 herdr **內部**跑 → workspace/tab 的 focus 呼叫會切換活著的 client（不開新 client）。從 herdr **外部的一般終端**跑 → 輔助函式會拉起一個 attach 到該 session 的 client，讓新 workspace 真的看得到（herdr 的 `workspace focus` 只會移動*已經 attach* 的 client，所以少了這步，整包會被建在看不見的地方）。`--no-attach` 兩種情況都以 detach 方式建立。判斷依據是環境值 `HERDR_ENV`。
- **`--session NAME`** 鎖定某個正在跑的 herdr session（見 [具名 session](#named-sessions)）。預設值：在 herdr 內部時用**當前** session（透過繼承的 `HERDR_SOCKET_PATH`），否則用 **default** session。這個覆寫用 `local -x HERDR_SOCKET_PATH` 限縮在函式範圍，所以永遠不會外洩到你的 shell。指定一個沒在跑的 `--session` 會報錯，並提示用 `herdr --session NAME` 先啟動（hvibe 不會自己 spawn server）。
- **Agent 可見性**：herdr **逐 pane** 追蹤 agent 狀態，所以在預設的 splits layout 下，每個 agent 仍會在 herdr 的 agent 追蹤裡各自現身（已驗證：同一 tab 裡兩個 agent 會在 `herdr agent list` 顯示為兩筆）。緊湊的左側欄會把一個 *tab* 的狀態彙整成一個點——若你要每個 agent 各擁有一個 tab 層級的狀態點，用 `--tab-per-agent`。
- **等寬欄位**：herdr 沒有 `select-layout even-horizontal`，所以 `hvibe` 明確設定每次分割的 `--ratio`（`1/(N-m+1)`）以維持 agent pane 等寬；`hcode` 用 `--ratio 0.75` 給 nvim 75%。
- 與 svibe/scode 相同的 flag：`--on-exit`、`--no-specstory`、`--no-attach`、`-p/--path`，外加 `--session NAME`；`hvibe` 另有 `--min-width` / `--tab-per-agent`，並吃 `$HVIBE_MIN_WIDTH` / `$HVIBE_LAUNCH_STAGGER`。完整 flag 說明：`hvibe -h` / `hcode -h`。

tmux 的 `svibe` / `scode` 仍是 tmux 端的對應物（見 [sesh](sesh.md)）；兩個家族共存——`hvibe`/`hcode` 只碰 herdr，`svibe`/`scode` 只碰 tmux。

## herdr-plus plugin（sesh + tmuxp + menu 的對應物）

[herdr-plus](https://github.com/cloudmanic/herdr-plus) 加了 **Projects**（宣告式的多 tab/多 pane workspace 範本 + 模糊選擇器——`tmuxp`/`tmuxinator` 的對應物）與 **Quick Actions**（模糊指令 launcher——彈出選單的對應物）。

**安裝已自動化**，由 `devtools` ansible role（`# --- herdr-plus plugin ---` 區塊）處理——冪等、每次 `chezmoi apply` 都會跑、裝好後就跳過。它呼叫：

```bash
herdr plugin install cloudmanic/herdr-plus   # 手動 fallback / role 實際跑的東西
```

`herdr plugin install` **在沒有 Go toolchain 時會下載預編譯 release binary**，所以有沒有 Go 都能用。唯一的陷阱：若 `PATH` 上有一個*過期*的 Go（例如舊的 `/usr/local/go` 遮蔽了較新的），herdr 會嘗試從原始碼建置並失敗（`invalid go version … must match format 1.23`），而不是 fallback。ansible task 透過在可用時把 mise 的 Go（`mise which go` → 它的 bin 目錄）前置到 PATH 來規避；手動修法：把現代 Go 放前面：`PATH="$(dirname "$(mise which go)"):$PATH" herdr plugin install cloudmanic/herdr-plus`。（Go 現在由 mise 管理，受 `installExtraRuntimes` gate。）

Projects 範本由 chezmoi 管理於 `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/projects/` → `~/.config/` 下的同一路徑。內建的 `chezmoi.toml` 對應本 repo 的 tmuxinator `chezmoi` session（editor/git/shell tab）。把 `prefix+O` 綁到 Projects、`prefix+y` 綁到 Quick Actions（設定裡已備好）。

## Television 整合

大多數 `tv` channel（`tools`、`fleet-hosts`、`mlflow`、`kill-process`、`ssh-config`）的 action **不與 tmux 耦合**，所以在 herdr command pane 裡原樣就能跑——綁一個鍵到 `tv <channel>` 即可。只有那些 action 會呼叫 `tmux …` 的 channel 才需要 herdr-aware 變體。這裡出貨兩個：

- `herdr-sesh`（`dot_config/television/cable/herdr-sesh.toml`）—— 列出 herdr session/workspace + zoxide 目錄；Enter 會分派 `herdr session attach` / `herdr workspace focus` / `herdr workspace create --cwd`，而不是 `sesh connect` / `tmux switch-client`。
- `herdr-agent-panes`（`dot_config/television/cable/herdr-agent-panes.toml`）—— 與 `agent-panes` 同來源，但切換/kill 改用 `herdr pane focus` / `herdr pane close`。

原本綁 tmux 的 `sesh` / `agent-panes` channel 保持不變以利共存。

## Agent 狀態（取代 6 檔案的 workmux 整合）

herdr 原生偵測 agent 狀態並彙整進側欄（一個 blocked 的 agent 會標記它的 pane/tab/workspace）。Claude Code 是靠 **screen-manifest 啟發式 (heuristics)**（終端標題 + OSC progress）偵測，而非生命週期 hook。若啟發式不夠用，可以明確推送狀態：

```bash
herdr pane report-agent w1:p1 --agent claude --state working
```

試用期間我們仰賴原生偵測——tmux 端的 workmux 🤖/💬/✅ 系統（Claude/OpenCode hook → `@workmux_status`）不動，且只在 tmux 下生效。

### 可選的 agent 整合（onboarding 的「install」按鈕）

herdr 首次執行的 onboarding 會提議**安裝可選的 agent 整合**（`herdr integration install <agent>`），讓 agent 直接回報狀態，而不必依賴 screen 啟發式。按下 *install* 會為每個偵測到的 agent 都設好。它會寫入什麼（本機已驗證）：

| Agent | `herdr integration install` 建立什麼 | 會碰到 repo 管理的檔案嗎？ |
|---|---|---|
| claude | `~/.claude/hooks/herdr-agent-state.sh` **+ `~/.claude/settings.json` 裡一個 hook 項目** | 會——但 repo 的 hook-aware `modify_settings.json` merger 會**保留**它（跟它對待 CodeIsland 一樣）。`chezmoi apply` 是 no-op；不會把 herdr hook 拔掉。 |
| codex | 只有 `~/.codex/herdr-agent-state.sh` | 不會——`~/.codex/config.toml` 不動（與 chezmoi 計算出的目標相同）。 |
| opencode | `~/.config/opencode/plugins/herdr-agent-state.js`（獨立 plugin） | 不會——只有 `workmux-status.ts` 受管；herdr 的 plugin 共存。 |
| cursor | `~/.cursor/herdr-agent-state.sh` + hook | 腳本在 chezmoi 之外；共存。 |

這些整合檔案**未**被 vendored 進 repo，所以**不會**在其他機器上重現（在那些機器再按一次 *install*，或跳過 onboarding）。它們用 herdr 自己的 socket，不會干擾 tmux/workmux（不同機制）。移除方式：`herdr integration uninstall <agent>`——而對 **claude**，之後要再跑一次 `chezmoi apply`，讓 merger 從 `settings.json` 丟掉那個已移除的 hook。

### 設定回寫（為何用 `create_`） {#config-writeback-create_}

herdr 會**把 UI/執行期設定寫回 `~/.config/herdr/config.toml`**——例如完成 onboarding 會在檔首插入 `onboarding = false`，而 app 內的*設定*彈窗（theme / sound / toasts / pane labels）在*套用*時也會持久化到那裡。它會就地編輯並保留既有註解，但執行期它擁有這個檔案。這就是為何 chezmoi 用 **`create_`（只植入一次）** 管理它：一般的受管檔案會在每次 `chezmoi apply` 被覆蓋（把 `onboarding=false` 再拔掉 → onboarding 畫面重現，且任何 UI 變更被還原）。後果：repo 裡對 `create_config.toml` 的編輯**不會**自動傳播到已有此檔的機器——要刻意刷新用 `cp ~/.config/herdr/config.toml "$(chezmoi source-path ~/.config/herdr/config.toml)"`（然後把執行期的 `onboarding`/state 行拿掉）。

## 持久化與還原（不小心關掉）

兩個原生層，不需要 plugin：

- **關 client/終端 ≠ 丟失 session。** herdr 跑一個持久化的 **server**（具名 session `default`，socket `~/.config/herdr/herdr.sock`）。關終端視窗只是 detach——workspace/tab/pane 及其執行中的行程都還活著。用裸 `herdr`（或 `herdr session attach default`）重新 attach；`herdr session list` 會顯示它 `running`。這就是 tmux 的 detach/reattach，內建。
- **完整 server 重啟 / 重開機 / crash。** 設定裡的 `[session]` 有 `resume_agents_on_restore = true`——在 server 重啟後把支援的 AI-agent pane 恢復到它們*原生的對話 session*（需要官方 `herdr integration install <agent>` hook）——外加一個選項可跨重啟保存最近的 pane 畫面歷史。這原生涵蓋了 tmux-resurrect/continuum 的情境，受那些 key + 整合 gate。

## 遠端 session (`herdr --remote`)

herdr 能跑一個**透過 SSH attach 到另一台主機上 herdr server 的本機 thin client**：

```bash
herdr --remote <ssh-target> [--session NAME] [--handoff]
herdr --remote local_ubuntu          # <ssh-target> 是 ~/.ssh/config 裡任何主機/別名
```

它做什麼（依 <https://herdr.dev/docs/remote>）：

- SSH 到 `<ssh-target>`，偵測遠端平台，並**在那裡自動安裝對應的 herdr server binary**——遠端**不需要**預先裝好 herdr（但需要 SSH 存取權 + 安裝/執行 binary 的權限）。
- 把你的**本機剪貼簿**（含貼圖）橋接到遠端 server，並沿用你的**本機快捷鍵**（`--remote-keybindings server` 可改用 server 的）。
- `--session NAME` 在遠端挑選/建立一個具名 session；`--handoff` 選擇加入 live handoff。

**設定**——`config.toml` 的 `[remote]` 區塊：

- `manage_ssh_config = true`（預設）—— herdr 透過一份產生的設定跑橋接 SSH，該設定先 include 你的 `~/.ssh/config`，再補上 `ServerAliveInterval`/`ServerAliveCountMax`，讓閒置的 NAT/網路逾時不會斷掉 session。設成 `false` 則用原封不動的你自己的設定跑純 SSH。
- `remote_image_paste`（`[keys]`）—— 原始按鍵的貼圖綁定，只在 `--remote` 下生效。

**排解 `remote platform detection failed: Connection closed by <host> port 22`**：這是**暫時性的 SSH 層級斷線**，不是 herdr 設定問題。先確認 herdr 用的 SSH 路徑真的通，然後重試即可：

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 <ssh-target> 'uname -sm'   # 應印出例如 "Linux x86_64"
```

若純 SSH 通，就重試 `herdr --remote <ssh-target>`；若一直失敗，在失敗當下看 `~/.config/herdr/herdr-client.log` / `herdr.log`。常見的真正原因：SSH 認證需要橋接無法回答的互動提示，或 sshd 對快速連線做速率限制（`MaxStartups`）。

## AI 用量 / 額度狀態

herdr **沒有原生的用量/額度/token 顯示**（側欄只顯示 agent *狀態*）。它確實有一個逐 pane 的 hook——`herdr pane report-metadata <pane> --source ID --custom-status "…" --ttl-ms N`——driver 可以把 `"Claude 62% • Codex 78%"` 之類的標籤推進去。有一個 Codex-only 的社群 plugin（[jerryfane/herdr-codex-usage-kit](https://github.com/jerryfane/herdr-codex-usage-kit)）已從 [CodexBar](https://github.com/steipete/CodexBar) 讀的同一份 `~/.codex` 資料做到這件事；但沒有東西涵蓋 Claude/ChatGPT 額度。延後——CodexBar 的選單列仍是多供應商的檢視。設計與選項記在 [`backlog/herdr-usage-status-driver.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/herdr-usage-status-driver.md)。

## 缺口（沒有乾淨的 herdr 對應）

- **無縫 `Ctrl-hjkl` nvim↔pane 導覽。** `vim-tmux-navigator` 與 tmux 耦合（`is_vim` 的 `ps`/`pane_tty` 啟發式 + nvim plugin）。herdr 沒有 smart-splits 對應物——它的 pane focus 是 `prefix+h/j/k/l`，在邊界不會穿透進 nvim 的 splits。Workaround：在 nvim 裡用它自己的 `<C-w>hjkl`。這是相對 tmux 最大的 UX 退步。
- **OSC133 copy-mode**（`cpout` / `cpblock`、prompt 跳轉、最後輸出 yank）是 tmux 專屬。herdr 的 copy mode（`prefix+[`）是 vi 風格但沒有 OSC133 的 prompt 邊界感知。`cpcmd`（zsh history，與多工器無關）仍可用。
- **狀態列 format 符號 + 書籤**（⭐/📌/🔖）：herdr 沒有 `#{@option}` 的 format-string 插值。原生 agent dots 涵蓋 agent 部分；手動書籤沒有對應物。

> **不是缺口：** vi copy-mode 本身*是*原生（`prefix+[`），且逐 pane 的 agent 狀態是原生偵測——我原本以為會缺的兩件事，結果都內建了。

## 延伸閱讀 (See also)

- [tmux 設定](tmux/README.md) · [Television (tv)](tv.md) · [sesh](sesh.md) · [workmux](workmux.md)
- [工具管理器 —— 工具從哪來](../this_repo/tool-managers.md)
