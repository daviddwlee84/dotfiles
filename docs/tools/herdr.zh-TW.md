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
- **設定 (Config)**：`~/.config/herdr/config.toml` —— chezmoi **`modify_` 覆蓋層 (overlay)**（`dot_config/herdr/modify_config.toml.tmpl` + 受管本體 `.chezmoitemplates/herdr/config.toml`）。覆蓋層在每次 `chezmoi apply` 強制套用我們受管的表 (tables)，同時保留 herdr 在執行期寫回的東西（見 [設定管理](#config-management-modify_)）。

> **升級會讓正在跑的 server 被擱淺（macOS）。** herdr 的 socket API 有 protocol 版本號，而套件管理器的升級沒辦法重啟 server —— 所以 `brew upgrade herdr` 之後，每一個 CLI 呼叫（連帶所有 `tv herdr-*` channel、`hvibe`/`hcode`、以及各個 `[[keys.command]]` helper）都會 `protocol_mismatch` 失敗，直到 server 重啟為止，而重啟會殺掉所有 pane 內的行程。`herdr update --handoff`——那個能保住 pane 的 live 路徑——在 **Homebrew/mise/Nix 安裝上是停用的**，所以 macOS 沒辦法迴避這次重啟；Linux 的自管 binary 則可以。要用 `herdr status`（看 `compatible:` / `restart_needed:`）判斷，不要看 `herdr --version`。完整的復原對照表：[`pitfalls/herdr-brew-upgrade-strands-running-server.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/herdr-brew-upgrade-strands-running-server.md)。

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

## cwd 與 workspace 命名模型

herdr 追蹤 cwd 的方式跟 tmux 不同,會顛覆兩個常見預期（皆用 `herdr pane list` 驗證）:

- **每個 pane 有兩個 cwd。** `cwd` = shell 的*啟動*目錄（spawn 時固定）;`foreground_cwd` = *即時* cwd,透過 **OSC 7** shell 整合追蹤。shell 裡 `cd` 會更新 `foreground_cwd`;啟動 `cwd` 永不變。
- **子行程 / 子 shell 裡的 `cd` 不會傳上來。** 因為追蹤是 OSC 7-based,一個沒有再送 OSC 7 的子 shell 裡的 `cd`——例如 `chezmoi cd`,它會在 source 目錄 spawn 一個*新*shell——對 herdr 是隱形的。`foreground_cwd` 不動,所以 space 的 git-repo 偵測與 `prefix+G` lazygit 位置都不跟著子 shell 走。這是 OSC 7 的固有特性,**不是** herdr bug——預期行為。
- **新 tab 跟隨聚焦 pane 的即時 cwd（herdr ≥0.7.x）。** 用 `new_cwd = "follow"`（見下）時,*新 tab* 繼承聚焦 pane 的即時 cwd——跟 *split* 一樣。herdr [issue #912](https://github.com/ogulcancelik/herdr/issues/912) 改了 `follow`,讓 tab 跟 split 行為一致;舊的「新 tab 開在 workspace 根（通常 `$HOME`）」被當成 bug 移除了。**沒有任何 `new_cwd` 值**（也沒有 workspace 層級的 cwd——`herdr workspace get` 完全沒有 cwd 欄位）能讓新 tab 開在 workspace 根;要那樣請用下方的 **`prefix+C`**。
- **workspace（space）label 自動跟隨 root/primary pane 的即時 cwd basename**（例如 → `chezmoi`、`trading-journal`）。在 **tab 1** 裡 `cd` 會改 space 名;在其他 tab 裡 `cd` 不會。沒有 config 旋鈕控制這個。

**`new_cwd` 值**（`[terminal]`）—— 沒給明確 `--cwd` 時,新 pane/tab/workspace 的 CWD 政策:

| 值 | 意義 |
|---|---|
| `follow`（預設） | 繼承**來源** pane——split 與新 tab 都取聚焦 pane 的即時 cwd（herdr ≥0.7.x） |
| `home` | `$HOME` |
| `current` | herdr **自身行程**的目錄（**不是**聚焦 pane） |
| `"~/path"` | 固定路徑 |

**沒有任何 `new_cwd` 值能讓新 tab 開在 workspace（space）根**——`follow` 現在跟隨聚焦 pane,而 herdr 沒有 workspace 層級的 cwd 欄位。本 repo 把這個行為做成 keybind:**`prefix+C`** → `~/.config/herdr/new-tab-at-space-root.sh`（`dot_config/herdr/executable_new-tab-at-space-root.sh`）,它推導出 space 根——編號最小 tab 的 pane 即時 cwd,也就是 herdr 用來當 space label 的那個——然後執行 `herdr tab create --workspace <wid> --cwd <root> --focus`。原生 `prefix+c` **與滑鼠「+」按鈕**維持跟隨聚焦 pane;keybind 無法攔截滑鼠按鈕。

```toml
[[keys.command]]
key = "prefix+C"
type = "pane"
command = "~/.config/herdr/new-tab-at-space-root.sh \"$HERDR_ACTIVE_PANE_ID\""
description = "new tab at the workspace (space) root dir"
```

## 可行性對照表 (Feasibility matrix)（現有 tmux 體驗 → herdr）

| 現有能力 | herdr 做法 | 這裡怎麼處理 |
|---|---|---|
| Catppuccin 主題 + 明暗 | **原生** `[theme]` + `auto_switch` | 在 `config.toml` 設定 |
| Splits / zoom / 開新 tab+workspace / pane 導覽 | **原生** `[keys]` actions | 重綁成 tmux 肌肉記憶 |
| Session 持久化（resurrect/continuum） | **原生** detach/reattach | 略過——原生 |
| 滑鼠 / 右鍵選單 | **原生** mouse-first | 略過——原生 |
| Agent 狀態 🤖/💬/✅（workmux，6 檔案） | **原生** 側欄 agent-state 彙整 | 略過——原生（tmux 端 workmux 不動）。面板改用**注意力佇列**排序，而非依 space 分組：`ui.agent_panel_sort = "priority"`（herdr 預設是 `"spaces"`） |
| `sesh` 模糊切換 + `tmuxp` layout | **Plugin** [herdr-plus](https://github.com/cloudmanic/herdr-plus) Projects + Quick Actions | Plugin + Projects 範本 |
| `tv` channel 彈窗（`prefix+T/U/a`） | **自訂 command pane**（`[[keys.command]] type="pane"`） | Key bindings + 2 個 herdr-aware channel |
| lazygit / scratch 彈窗 | **自訂 command pane** | Key bindings |
| URL 選單（`prefix+u`,tmux-fzf-url） | **自訂 command pane + 輔助腳本** | `prefix+u` → `url-pick.sh`（fzf → `x open`）；`--source recent` 掃描 scrollback |
| 檔案路徑選單（`prefix+p`；tmux 上為 extrakto `prefix+Tab`） | **自訂 command pane + 輔助腳本** | `prefix+p` → `path-pick.sh`——兩層（cwd 下存在的優先）→ `x copy` |
| 無縫 `Ctrl-hjkl` nvim↔pane 導覽 | **沒有 herdr-aware smart-splits** | **缺口**——見下方 workaround |
| OSC133 copy-mode（`cpout`/`cpblock`） | tmux 專屬 | **缺口**——`cpcmd`（zsh history）仍可用 |
| 每視窗狀態符號 + 書籤 ⭐📌 | 部分——`report-metadata --token`（逐 pane metadata token、與 agent 狀態正交） | **待 review 旗標**（`hmark`/`prefix+m` + `tv herdr-review` 收件匣）；純裝飾的狀態列符號仍是缺口（無 format-string 插值） |
| AI session-summary / agent-wakeup 擷取 | 可改用 `herdr pane read` / `pane list --json` 重寫 | **延後**——超出試用範圍 |

## 快捷鍵 (Keybindings)

Prefix 是 `ctrl+b`（跟 tmux 一樣）。內建 action 只能*重綁 (rebind)*（herdr 的 action 集合是固定的）；其餘一切都是 `[[keys.command]]` 自訂指令。自訂指令會收到 `$HERDR_SOCKET_PATH`、`$HERDR_ACTIVE_PANE_ID`、`$HERDR_ACTIVE_PANE_CWD`，並在聚焦 pane 的 cwd 下執行。

> **兩組 herdr 環境變數。** 上面那組 `HERDR_ACTIVE_PANE_*` **只**會被注入到 `[[keys.command]]` 的呼叫裡。而每個*跑在 herdr pane 內的 shell* 還會拿到一組**環境值 (ambient)**：`HERDR_ENV=1`、`HERDR_PANE_ID`、`HERDR_TAB_ID`、`HERDR_WORKSPACE_ID`、以及 `HERDR_SOCKET_PATH`（當前 session 的 socket）。腳本用 `HERDR_ENV` 當作「我在不在 herdr 裡？」的判斷，並繼承 `HERDR_SOCKET_PATH` 來鎖定當前 session——這正是 `hvibe`/`hcode` 依賴的東西。

| Key | Action | 類型 |
|---|---|---|
| `prefix + c` / `prefix + 1..9` | 新 tab / 切 tab | built-in default |
| `prefix + C` | 在 workspace（**space**）根目錄開新 tab——`prefix+c` 與滑鼠「+」維持跟隨聚焦 pane | command pane |
| `prefix + h/j/k/l` | 聚焦 pane | built-in default |
| `prefix + \|` / `prefix + %` · `prefix + minus` / `prefix + "` | 左右分割 / 上下分割（tmux 肌肉記憶——直覺鍵與 tmux 預設鍵都綁） | rebound（陣列 arrays） |
| `prefix + z` / `prefix + x` | zoom / 關 pane | built-in default |
| `prefix + w` / `prefix + g` | workspace 導覽（navigate-mode:**`j`/`k`** 或方向鍵移動,Enter 選定) / session navigator（[popup 內按鍵](#navigator-keys)） | built-in;`navigate_workspace_*` 重綁成 `j`/`k` + 方向鍵 |
| `prefix + ctrl + 1..9` | 直接跳到 **workspace** N（`switch_workspace`) | rebound (indexed) |
| `prefix + alt + 1..9` | 直接跳到 **agent** N 的 pane（`focus_agent`) | rebound (indexed) |

> **索引跳轉為何用 ctrl/alt 而非 shift**:herdr 使用 kitty keyboard protocol,`shift+1` 仍帶著可列印的 `!`,所以 herdr 比對到的是符號而非 `shift+1`——`prefix+shift+1..9` 會靜默失效。`ctrl+digit` / `alt+digit` 沒有可列印形式,能乾淨地區分。
| `prefix + [` | vi copy mode（`hjkl`、`w/b/e`、`{/}`、`v`、`y`） | built-in default |
| `prefix + q` | detach | built-in default |
| `prefix + ?` | 快捷鍵說明覆蓋層——列出每個當前綁定與標籤（herdr 原生 which-key；手動觸發，非逾時自動提示） | built-in default |
| `prefix + ,` | 重新命名 tab | rebound（tmux 肌肉記憶） |
| `prefix + shift + r` | reload config（`prefix + r` 保留給 resize mode） | rebound |
| `prefix + shift + b` | 新 git worktree（從 `prefix + shift + g` 移過來） | rebound |
| `prefix + G` | lazygit | command pane |
| `prefix + M` | btop 系統監控器 | command pane |
| `prefix + N` | nvtop GPU 監控器 | command pane |
| `prefix + U` | `tv tools`（CLI launcher） | command pane |
| `` prefix + u `` | **URL 選單** — 從 pane fzf 挑一個 URL 並開啟（`x open`）；tmux-fzf-url 對應物。`--source recent` = 完整 scrollback | command pane |
| `prefix + T` | `tv herdr-sesh`（workspace/dir 切換） | command pane |
| `prefix + a` | `tv herdr-agent-panes`（即時 agent panes） | command pane |
| `prefix + f` | `tv fleet-hosts`（SSH picker） | command pane |
| `prefix + m` | 切換目前 pane 的**待 review** 旗標（⭐） | command pane |
| `prefix + i` | `tv herdr-review`——待 review **收件匣**（被標記的 pane） | command pane |
| `prefix + P` | 複製聚焦 pane 的 **process 資訊** 到剪貼簿 | command pane |
| `prefix + D` | 複製聚焦 pane 的 **座標**（session>space>tab>pane） | command pane |
| `prefix + V` | 複製聚焦 pane 的 **內容**（可見畫面） | command pane |
| `prefix + S` | 複製聚焦 pane 的 **內容**（完整 scrollback） | command pane |
| `` prefix + p `` | **複製檔案路徑** ——兩層 fzf（cwd 下存在的路徑在上），複製解析後的絕對路徑（`x copy`） | command pane |
| `` prefix + ` `` | scratch shell | command pane |
| `prefix + E` | **執行任意指令**（在該 pane 的 cwd）—— 用 fzf 從歷史挑、或直接打新的；指令結束後 popup 自己關掉（[細節](#run-any-command)） | command **popup** |
| `prefix + O` | herdr-plus **Projects**（layout launcher） | plugin action |
| `prefix + y` | herdr-plus **Quick Actions** | plugin action |

> 大寫字母會解析成 `prefix+shift+<letter>`，herdr 保留給內建（`shift+g` worktree、`shift+t` rename-tab、`shift+h/j/k/l` swap-pane）。`prefix+G`/`prefix+T` 由上面的重綁釋放出來；`herdr server reload-config` 會在它的 `diagnostics` 回報任何殘餘衝突。

### Session navigator（`prefix + g`）——popup 內的按鍵 {#navigator-keys}

navigator 是 herdr 的 Cmd-K 對應物：一棵 `space → tab → pane` 樹，帶模糊搜尋與 agent 狀態過濾。它的 footer 只寫了 `enter switch · / search · b/w/i/d/a states · j/k/↑↓ move · esc close`，但還有幾個鍵是有效的、而且**上游沒有文件**（對照 herdr 0.7.5 `src/app/input/modal.rs` 驗證）：

| 按鍵 | 作用 |
|---|---|
| `space` | **展開／收起游標所在的 space** ——只在 *space* 那一行有效；停在 tab/pane 行時靜默無反應 |
| `ctrl + d` / `ctrl + u` | 下／上翻半頁 |
| `home` / `end`（或 `G`） | 跳到第一／最後一列 |
| `backspace` | 取消目前的狀態過濾（`b`/`w`/`i`/`d`），回到全部 |
| `a` | 同時清掉查詢字串**與**狀態過濾 |
| `esc` | 直接關閉 popup（≤ 0.7.2 是先清查詢＋過濾，要按第二次才關） |

**三個限制，讓 `space` 沒辦法當成 collapse-all 用**（`src/app/actions.rs`）：

1. **每次開啟都重置成全部展開** —— `open_navigator_from()` 會清掉 `expanded_workspaces` 再把每個 workspace 塞回去。收起狀態不會跨越關閉 popup。
2. **只要有搜尋字串或 `b`/`w`/`i`/`d` 過濾就強制全展開**（`expanded = query_kind != Empty || …`）。只有在 `a` / 空查詢下，收起才看得到效果。
3. **navigator 的展開集合與 sidebar 的 `collapsed_space_keys` 是兩套獨立的** —— 後者才是 `~/.config/herdr/session.json` 持久化的那個，由 sidebar 右鍵選單的 `Expand` / `Close group` 驅動。在其中一邊收起某個 space，不會影響另一邊。

**沒有 expand-all / collapse-all，也沒有深度上限。** 上游對兩者的請求都因 issue 模板政策（issue 只收 bug）被直接關掉：[#1256](https://github.com/ogulcancelik/herdr/issues/1256)（`ui.goto_depth = "workspace" | "tab" | "pane"`）與 [#1255](https://github.com/ogulcancelik/herdr/issues/1255)（vim `h`/`l` 收合展開）→ [discussion #1248](https://github.com/ogulcancelik/herdr/discussions/1248)。

> **想要只看 space 層的總覽，改用 `prefix + T`**（`tv herdr-sesh`）。它本質上就是一份扁平的 workspace 清單——等於永久的 collapse-all 視圖——而且還能從 zoxide frecency 目錄*建立*新 space，這是原生 navigator 做不到的。`prefix + w` 是另一個 space 層的選項（原生 sidebar navigate mode），但沒有模糊搜尋。

## Session 輔助函式：`hvibe` / `hcode` / `hhere` / `hroot`（`svibe` / `scode` / `shere` / `sroot` 的 herdr 版）

[`dot_config/shell/24_herdr.sh`](../shells/aliases.md#session-management) 裡有四個 shell 函式，就是 tmux 的 `svibe` / `scode` / `shere` / `sroot` 在 herdr 端的對應物。兩個**重量級**的（`hvibe` / `hcode`）能一氣呵成拉起整個 coding workspace；兩個**輕量級**的（`hhere` / `hroot`）只是在某個目錄開一個純 workspace 並 attach——不需要 git repo，也沒有 agent layout。它們呼叫原生的 `herdr workspace|tab|pane` CLI，並**原封不動重用純邏輯**（specstory 包裝、`--on-exit shell|kill|restart`、git-root 解析、agent-CLI 偵測），這些來自 `22_sesh.sh`；只有 layout 呼叫不同。需要 `herdr` server 正在跑 + `jq`。

| 指令 | 建立的 workspace | Layout |
|---|---|---|
| `hvibe [N] [CLI]` / `hvibe --agents claude,codex,opencode` | `vibe/<repo>` | tab `agents`（N 個等寬 agent pane）+ tab `git`（lazygit）+ tab `edit`（nvim） |
| `hvibe --tab-per-agent …` | `vibe/<repo>` | 每個 agent **一個 tab** + `git` + `edit` tab |
| `hcode [CLI]` | `coding-agent/<repo>` | tab `editor`（nvim 75% \| agent 25%）+ tab `monitor`（btop） |
| `hhere [CMD...]` | `<basename $PWD>` | 單一 tab，`$PWD`（或 `-p DIR`）的純 shell；`CMD` 選用，會在 root pane 執行 |
| `hroot [CMD...]` | `<basename git-root>` | 同 `hhere`，但落在當前 git root（不在 repo 時退回 `$PWD`） |

- **純開 pair（`hhere` / `hroot`）** 補上了「其他每個 herdr 入口都強制要 git repo + 完整 agent layout」的缺口。tmux 的 `tmux new-session` 會直接把你丟進 `$PWD`；herdr 多了一層 Workspace，所以少了這對指令，你得先啟動 herdr、建一個 space（會依 `new_cwd` 開在 `$HOME`）、再手動 `cd`。`hhere` 一步到位：`herdr workspace create --cwd "$PWD"` → focus → 在外部就 attach。不需要 git；選用的指令以**原始**方式執行（不做 specstory/on-exit 包裝——那留給 `hcode`/`hvibe`）。flag 見 `hhere -h` / `hroot -h`。**Label 注意事項**：tab 1 裡 `cd` 之後，herdr 會把 workspace 重新命名為 root pane 的*當前* cwd basename（見上方 **cwd & workspace-naming model** 一節），所以冪等聚焦是盡力而為——label 漂移後重跑會開一個新的 workspace。
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

**Quick Actions** 同樣由 chezmoi 管理，位於 `…/cloudmanic.herdr-plus/quick-actions/`（每個 action 一個 TOML）。本 repo 出貨四個 **copy-pane** action（見 [複製聚焦 pane 的資訊](#複製聚焦-pane-的資訊到剪貼簿prefixpdvs)）,外加 plugin 的五個**起手式**範例（GitHub / Google / Search Google / Open Repo / Reveal Working Dir）,已為 Linux 調整——macOS `open` → 本 repo 的跨平台 [`x open`](../shells/aliases.md),repo 選單指向 `daviddwlee84/*`。因為這個受管目錄非空,herdr-plus **不會** 自己 seed 那些範例（它只在*空*目錄時 seed）,所以在此 vendored;不要的 TOML 刪掉即可。要新增就往這裡丟一個 TOML,或在 `<repo>/.herdr-plus/quick-actions/` 出貨一組 repo 本地的。

> **Quick Actions 是給一次性、非互動式指令用的**（內建範例全是 `open <url>`）。herdr-plus 用 `sh -c` 跑選中的 action,沒有 PTY、沒有互動 stdin,所以互動式 TUI 會出問題——btop 立刻退出、nvtop 收不到 F10。要跑 TUI 就用 lazygit 那種*浮動 command pane*（`[[keys.command]] type="pane"`）——這就是為何 **btop**（`prefix+M`）與 **nvtop**（`prefix+N`）是快捷鍵而非 Quick Action。

## Television 整合

大多數 `tv` channel（`tools`、`fleet-hosts`、`mlflow`、`kill-process`、`ssh-config`）的 action **不與 tmux 耦合**，所以在 herdr command pane 裡原樣就能跑——綁一個鍵到 `tv <channel>` 即可。只有那些 action 會呼叫 `tmux …` 的 channel 才需要 herdr-aware 變體。這裡出貨三個：

- `herdr-sesh`（`dot_config/television/cable/herdr-sesh.toml`）—— 列出 herdr session/workspace + zoxide 目錄；Enter 會分派 `herdr session attach` / `herdr workspace focus` / `herdr workspace create --cwd`，而不是 `sesh connect` / `tmux switch-client`。
- `herdr-agent-panes`（`dot_config/television/cable/herdr-agent-panes.toml`）—— 與 `agent-panes` 同來源，但切換/kill 改用 `herdr pane focus` / `herdr pane close`。
- `herdr-review`（`dot_config/television/cable/herdr-review.toml`）—— **待 review 收件匣**：只列出帶 ⭐ 旗標的 pane（`tokens.review` 非空）。Enter 會 focus 該 pane 的 workspace/tab 並**保留**旗標;`Alt+C` 則 focus **並**清除旗標（「mark read」）。綁在 `prefix+i`。見下方 **待 review 旗標** 一節。

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
| claude | `~/.claude/hooks/herdr-agent-state.sh` **+ `~/.claude/settings.json` 裡一個 hook 項目** | 會——但 repo 的 hook-aware `modify_settings.json.tmpl` merger 會**保留**它（跟它對待 CodeIsland 一樣）。`chezmoi apply` 是 no-op；不會把 herdr hook 拔掉。 |
| codex | 只有 `~/.codex/herdr-agent-state.sh` | 不會——`~/.codex/config.toml` 不動（與 chezmoi 計算出的目標相同）。 |
| opencode | `~/.config/opencode/plugins/herdr-agent-state.js`（獨立 plugin） | 不會——只有 `workmux-status.ts` 受管；herdr 的 plugin 共存。 |
| cursor | `~/.cursor/herdr-agent-state.sh` + hook | 腳本在 chezmoi 之外；共存。 |

這些整合檔案**未**被 vendored 進 repo，所以**不會**在其他機器上重現（在那些機器再按一次 *install*，或跳過 onboarding）。它們用 herdr 自己的 socket，不會干擾 tmux/workmux（不同機制）。移除方式：`herdr integration uninstall <agent>`——而對 **claude**，之後要再跑一次 `chezmoi apply`，讓 merger 從 `settings.json` 丟掉那個已移除的 hook。

### 設定管理（為何用 `modify_`） {#config-management-modify_}

herdr 會在執行期改寫 `~/.config/herdr/config.toml`——完成 onboarding 會在檔首插入 `onboarding = false`，而 app 內的*設定*彈窗（theme / sound / toasts / pane labels）在*套用*時也會持久化到那裡。它就地編輯並保留既有註解，但執行期它擁有這個檔案。

這個檔案原本用 `create_` 前綴只植入一次，避免 `chezmoi apply` 蓋掉那些寫回。代價是：**repo 的編輯永遠傳不到已植入的機器**——你在 source 改的分割鍵重綁、註解修正,都得手動 `cp … source-path` 刷新才會抵達,否則悄悄不見。這正是為何一台機器在 `chezmoi diff` 顯示乾淨時仍會感覺「沒同步」（diff 之所以乾淨,*正是因為* `create_` 從不再碰該檔）。這與跨機器無關：source 對每台 live 檔的 `diff` 可以逐字節相同,但 repo 編輯在你刷新前仍不會落地。

現在改成 **`modify_` 覆蓋層**——`dot_config/herdr/modify_config.toml.tmpl`,一個小腳本:

- 以受管本體 `.chezmoitemplates/herdr/config.toml` 為 base（帶註解 + tmux-parity 說明）,每次 apply 強制套用 `[theme]` / `[ui]` / `[terminal]` / `[keys]` 表,並
- **原樣拉回 (pull through)** live 檔的其他每個頂層 key（`onboarding`、`[session]`、`[remote]`、`[update]`、`[experimental]`…）,讓 herdr 的執行期寫回存活。

TOML 沒有 `jq`,所以合併用 Python 透過 `uv run --with tomlkit` 跑（tomlkit 能來回保留註解**與** `[[keys.command]]` 的 array-of-tables;stdlib `tomllib` 唯讀,而 codex 的 `modify_` emitter 無法輸出 AoT）。它退化到系統 `python3`,再退化到直接輸出原始受管範本,所以沒有 Python 的全新主機仍拿到完整設定。這是繼 `~/.codex/config.toml`（`dot_codex/modify_config.toml.tmpl`）之後第二個 TOML-overlay 先例。

要改 herdr 的受管設定,編輯 `.chezmoitemplates/herdr/config.toml` 再 `chezmoi apply`——它現在會抵達每台主機。用 `herdr server reload-config` 驗證（會在 `diagnostics` 回報快捷鍵衝突;空的 `diagnostics` 陣列 + `"status":"applied"` 代表設定——含陣列鍵綁定——解析乾淨）。

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

## 在 tmux 內巢狀執行 herdr（多 remote）

本 repo 的預設立場是 herdr **或** tmux,不巢狀。但你可以刻意巢狀——tmux 當外層視窗管理器,內含數個 herdr client,有些本地、有些 `herdr --remote <host>` 連到不同 server。癥結是 **prefix 衝突**:兩者都預設 `Ctrl+b`,所以外層 tmux 吃掉它,內層 herdr 永遠收不到自己的 prefix（[herdr #759](https://github.com/ogulcancelik/herdr/discussions/759)）。

三種解法,依這裡的偏好排序:

1. **雙擊 prefix 轉發（推薦,零設定）。** tmux 保有預設的 `bind -T prefix C-b send-prefix`（已確認本 repo 未覆寫）,所以 **`Ctrl+b Ctrl+b`** 會把一個字面 `Ctrl+b` 轉發給內層 herdr;之後它的 prefix 綁定正常運作（`Ctrl+b Ctrl+b c` = 內層開新 tab）。herdr 與 tmux 都不用改——經典的 tmux-in-tmux 肌肉記憶。
2. **改內層 herdr 的 prefix。** 設 `keys.prefix`（例如 `"ctrl+a"` / `"ctrl+space"`）讓內層 herdr 用不衝突的 prefix——一次按鍵而非雙擊。代價:即使單獨跑 herdr,prefix 也變了（不再與 tmux 的 `Ctrl+b` 一致）。
3. **不巢狀——用 herdr 原生遠端。** `herdr --remote <target> [--remote-keybindings local|server]` 跑一個本機 thin client 連到遠端 herdr server,中間沒有 tmux,而 herdr 自己就託管多個具名 session。對純粹「多個 remote」的需求,這通常比巢狀乾淨;`--remote-keybindings local`（預設）沿用你的本機 keymap,`server` 用遠端的。

注意:本 repo 的 tmux 用了很多 root-table `bind -n C-*` 綁定會**遮蔽**內層 app 的 `Ctrl` 鍵,所以 herdr 的 prefix-free *direct* 終端捷徑在 tmux 下不可靠——透過它的 prefix 觸及 herdr action（用 1 或 2）。herdr 自己的 `allow_nested`（config,預設 `false`）只管 herdr-inside-**herdr**（靠 `HERDR_ENV` 偵測）,不是 herdr-inside-tmux。

## 待 review 旗標（mark-unread / ⭐）

tmux 那邊有逐視窗書籤（`@bookmark_status` + `toggle-bookmark.sh`,靠 `#{?@bookmark_status,…}` 渲染）。herdr **沒有 `#{@option}` 狀態列插值**,所以那套機制不能直接移植——但這裡真正重要的用途可以:**「agent 跑完了（`done`）但我還沒 review」**。herdr 一旦你點進去瞄一眼就把 `done` pane 塌成 `idle`,唯一還需要注意的訊號就此消失。

解法用 herdr 的**逐 pane metadata token**,它與原生 agent 偵測正交:

```bash
herdr pane report-metadata <pane> --source review --token review="⭐ REVIEW"   # 設定（永久——不帶 --ttl-ms）
herdr pane report-metadata <pane> --source review --clear-token review         # 清除
```

已驗證:一個 pane 可以同時帶 `tokens.review = "⭐ REVIEW"` 與 `agent_status:"idle"`——所以點進去**不會**清掉旗標（重點所在）。`herdr pane get` 會吐出 `tokens` map,`herdr pane list`（原生 JSON——**不**加 `--json` flag）讓收件匣列舉被標記的 pane,所以**不需要 sidecar 檔**;herdr 自己就是真相源。token 的**存在與否**就是旗標本身,所以字符文字可以自由替換。

> **只支援 herdr ≥ 0.7.4,而且 token 需要 row layout 才看得見。** 0.7.4 把 `--custom-status` / 扁平的 `custom_status` 欄位換成了這個帶命名空間的 token map——這是一次**靜默移除**,沒有被列進 breaking change。兩個後果:在更舊的 herdr 上這支 helper 會以 `unknown --custom-status` 死掉;而且不像 `custom_status`,token **只**會在 sidebar row layout 有指名它的地方渲染。這就是為什麼 `.chezmoitemplates/herdr/config.toml` 釘住了 `[ui.sidebar.agents] rows`,在 herdr 預設的第一列後面補上 `"$review"`——拿掉它旗標本身仍然運作（`prefix+i` 照樣列得出來）,但 sidebar 上的 ⭐ 會消失。見 [`pitfalls/herdr-0.7.4-drops-custom-status.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/herdr-0.7.4-drops-custom-status.md)。

各介面（共用同一支腳本 `~/.config/herdr/review-mark.sh` = `dot_config/herdr/executable_review-mark.sh`,即 tmux `toggle-bookmark.sh` 的對應物）:

| 介面 | 動作 |
|---|---|
| `hmark` / `hunmark`（`dot_config/shell/24_herdr.sh` 的 alias） | 對目前 pane（環境值 `$HERDR_PANE_ID`）set / clear,或傳入 pane id |
| `prefix+m` | 切換 focus pane 的旗標（用 `$HERDR_ACTIVE_PANE_ID`） |
| `tv herdr-review` / `prefix+i` | **收件匣**:只列出被標記的 pane。`Enter` focus 過去並**保留** ⭐（你可能還在 review 中）;`Alt+C` focus **並**清除（「mark read」） |

三個名字必須一起動:`review-mark.sh` 裡的 `TOKEN`、[`herdr-review.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/herdr-review.toml) 裡的 `.tokens.review` 查詢,以及 sidebar row layout 裡的 `"$review"`。

## 在 popup 裡執行任意指令（`prefix + E`） {#run-any-command}

`prefix + G` 已經示範了那個形狀 —— 一個暫時性的 pane，跑完就消失 —— 但它的指令是寫死的。`prefix + E` 就是它的一般化版本：**用 fzf 從 shell 歷史挑一條指令（或直接打一條新的），它會在聚焦 pane 的 cwd 執行，結束後 popup 自己關掉。** 輔助腳本：`~/.config/herdr/run-command.sh` = [`dot_config/herdr/executable_run-command.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_run-command.sh)。

**為什麼用 `type = "popup"` 而不是其他做法** —— 這是這裡唯一不是 command *pane* 的綁定：

| 做法 | 問題 |
|---|---|
| `type = "pane"`（`prefix+G/M/N/`` ` ``） | 執行期間會切開**平鋪版面**，整個重排 |
| `prefix + c` → 打指令 → `exit` | 四個步驟，而且會弄亂 tab bar |
| `prefix + `` ` ``（scratch shell） | 留下一個要自己 exit 的 shell |
| **`type = "popup"`** | session-modal，浮在版面**之上** —— 什麼都不重排，關掉就回到原位 |

`type = "popup"` 需要 **herdr ≥ 0.7.4**（#1125 加入，`width`/`height` 支援 cell 數或百分比）。它才是真正的 `tmux display-popup -E` 對應物。

**它沒辦法做成 herdr-plus Quick Action**（`prefix + y`），雖然那是最直覺會去找的地方。兩個硬阻礙：Quick Actions 透過 `sh -c` 執行、**沒有 PTY/stdin**（這正是 `btop`/`nvtop` 是 command pane 而不是 Quick Action 的原因），而且每個 action 都是寫死的 `command = "…"` 字串，沒有自由輸入欄位。

行為：

| | |
|---|---|
| **cwd** | `--cwd` → `$HERDR_ACTIVE_PANE_CWD` → `herdr pane get` 的 `foreground_cwd` → `$PWD`。優先用環境變數的好處是：即使 CLI 與舊 server protocol 不相容，它照樣能運作 |
| **選取** | fzf 翻 `$HISTFILE`（預設 `~/.zsh_history`），最新在上、已去重。打了沒 match 的字再按 Enter 就當作**新指令**執行；`Esc` 則什麼都不做。沒有 fzf 時退回純 `read` 提示 |
| **shell** | 預設 `$SHELL -ic`，所以這個 repo 的 alias 與 function 都能解析（`gst`、`cas`、`x` …）。`--sh` 改用 `sh -c` —— 快，但 alias 不存在 |
| **結束時** | 成功就關閉；失敗則印出 `[exit N]` 並等你按 Enter，讓錯誤訊息不會一閃而過。可用 `HERDR_RUN_HOLD=always\|never` 覆寫 |

> 有兩個可攜性陷阱已經在腳本裡處理掉了，如果你要改它值得先知道：`~/.zsh_history` 是 extended-history 格式（`: <ts>:<elapsed>;<cmd>`）**而且含有非 UTF-8 位元組**，所以除非在 `LC_ALL=C` 下解析，BSD `sed` 會以 `sed: RE error: illegal byte sequence` 中止；另外「最新在上」的反轉用 POSIX `awk` 實作，因為 `tail -r` 只有 BSD 有、`tac` 只有 GNU 有。

## 複製聚焦 pane 的資訊到剪貼簿（`prefix+P/D/V/S`）

四個一鍵「把這個 pane 抓到剪貼簿」的操作,全由同一支腳本驅動（`~/.config/herdr/pane-copy.sh` = [`dot_config/herdr/executable_pane-copy.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_pane-copy.sh)）。它把一個 herdr CLI 呼叫萃取成人類可讀的文字,再導入本 repo 自己的 [`x copy`](../shells/aliases.md)（自動選 pbcopy / wl-copy / xclip / xsel / OSC 52;`x` 以絕對路徑 fallback 解析,因為 command-pane 可能在沒有互動式 PATH 的情況下執行）。pane 預設為**目前聚焦的 pane**（`herdr pane current`）；keybind 傳入 `$HERDR_ACTIVE_PANE_ID`,Quick Actions 傳入 `$HERDR_PLUS_PANE_ID`,兩者為空時都會 fallback 到目前 pane 的查詢。

| 操作 | 按鍵 | Quick Action | 進剪貼簿的內容 |
|---|---|---|---|
| `process` | `prefix+P` | *Copy pane: process info* | 前景 process——`cmdline` + `pid` + `cwd`（來自 `herdr pane process-info`） |
| `coord` | `prefix+D` | *Copy pane: coordinate* | 可直接貼回 CLI 的 `session` / `workspace` / `tab` / `pane` id 區塊 + `socket` 路徑 + 一行 `# herdr pane get <pane>` |
| `content`（可見） | `prefix+V` | *Copy pane: content (visible)* | pane 目前螢幕上的文字（`herdr pane read --source visible`） |
| `content`（scrollback） | `prefix+S` | *Copy pane: content (scrollback)* | pane 完整保留的 scrollback（`--source recent`） |

**座標**回答「這是哪個 `session > space > tab > pane`?」,並以可餵回 CLI 的形式呈現。herdr 在 `pane`/`tab`/`workspace` 子命令上**沒有 `--session` 旗標**——session 只能經由 `HERDR_SOCKET_PATH` 指定——所以區塊裡納入 `socket=` 那行作為 session 選擇器（session *名稱* 則是把該 socket 對 `herdr session list --json` 比對而得）。

兩個介面共用同一支腳本:[`.chezmoitemplates/herdr/config.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoitemplates/herdr/config.toml) 的 `[[keys.command]]` 綁定,以及 `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/quick-actions/` 下的四個 `copy-pane-*.toml` **Quick Actions**（用 `prefix+y` 模糊啟動）。`P/D/V/S` 是大寫（`prefix+shift+<letter>`）,刻意避開 herdr 保留的 `shift+H/J/K/L`（swap-pane）與本 repo 的 `shift+B`（new_worktree）/ `shift+R`（reload）——用 `herdr server reload-config`（`diagnostics` 為空）確認無衝突。

## 從 pane 開啟 URL（`prefix+u`）

tmux `prefix + u`（[`joshmedeski/tmux-fzf-url`](https://github.com/joshmedeski/tmux-fzf-url)）的 herdr 對應物。`prefix+u` 開一個 fzf 彈窗,列出聚焦 pane 裡的每個 URL;挑一個(或多個——fzf 多選),每個都在瀏覽器開啟。小寫 `u` 刻意與大寫 `U`(`tv tools`)配對,延續 tmux 的肌肉記憶。

由一支腳本驅動:`~/.config/herdr/url-pick.sh` = [`dot_config/herdr/executable_url-pick.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_url-pick.sh)。它讀取 pane(`herdr pane read`),跑**與 tmux-fzf-url 相同的萃取/改寫規則**,再用本 repo 跨平台的 [`x open`](../shells/aliases.md)(wslview / open / xdg-open)開啟每個選項。它與 `pane-copy.sh` 完全同構:pane 預設為 `$HERDR_ACTIVE_PANE_ID`(keybind 變數),為空時 fallback 到 `herdr pane current`;`x` 以絕對路徑 fallback 解析,因為 command-pane 可能在沒有互動式 PATH 的情況下執行。

| 面向 | 行為 |
|---|---|
| 範圍 | **預設可見螢幕**(與 tmux-fzf-url 一致)。`url-pick.sh <pane> --source recent` 掃描完整保留的 scrollback |
| 樣式 | `http(s)` / `ftp` / `file`、裸 `www.` → `http://`、`IPv4[:port]` → `http://`、`git@…` SSH remote → `https://…`、引號 `"owner/repo"` → `github.com/owner/repo`、`import "pkg"` → `npmjs.com/package/pkg` |
| 開啟 | 每個選項 `x open <url>`;多選則全部開啟 |
| 無 URL | 印出 `no URLs found` 並暫停約 1.5 秒(command pane 在腳本退出的瞬間就關閉——tmux 是用狀態列) |

以 [`.chezmoitemplates/herdr/config.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoitemplates/herdr/config.toml) 裡的 `[[keys.command]] type="pane"` 綁定——不需要 tv channel(fzf 才是忠實移植)。Copy-mode 的 URL 開啟(tmux `tmux-open` 的 `o`)沒有 herdr 對應物;請用 `prefix+u` 選單。

## 從 pane 複製檔案路徑（`prefix+p`）

URL 選單的複製路徑姊妹版。`prefix+p` 開一個 fzf 彈窗,列出聚焦 pane 裡的檔案路徑;挑一個(或多個),路徑就複製到剪貼簿。小寫 `p`(copy **p**ath)坐落在大寫複製家族(`prefix+P/D/V/S`)之下,與 `u`/`U` 同一慣例。tmux 上的對應物是 **extrakto** plugin(`prefix + Tab`)——見 [tmux 快捷鍵](tmux/keybindings.md)。

輔助腳本:`~/.config/herdr/path-pick.sh` = [`dot_config/herdr/executable_path-pick.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_path-pick.sh),與 `url-pick.sh`/`pane-copy.sh` 完全同構(相同的 pane + `x` 解析 + `herdr pane read` 管線),用 [`x copy`](../shells/aliases.md) 複製。

**noise 問題與處理方式。** 與 URL(用 `scheme://` 自我標識)不同,檔案路徑沒有標記,所以單靠 regex 會誤中日期(`2024/01/02`)、速率(`10k/s`)與分數(`1/2`)。兩道防線:

| 防線 | 行為 |
|---|---|
| 萃取 | extrakto 的路徑啟發式——含斜線的 token(`/…`、`~/…`、`./`、`a/b/c`)+ 裸 `file.ext`;去掉尾端 `",):`;速率/分數 token 直接排除 |
| 存在檢查（noise 殺手） | 每個候選對 pane cwd(`$HERDR_ACTIVE_PANE_CWD`,否則 `herdr pane get` 的 `foreground_cwd`,否則 process-info cwd)解析後 `test -e` |
| **兩層清單** | **存在**的路徑排在最前(複製為解析後的**絕對**路徑);其餘——遠端 / 過期 / 假設的——放在 `── unverified ──` 分隔線下方(仍可選),所以真實但無法解析的路徑不會遺失 |

`path:line:col` 後綴(grep `-n` / stack trace / 編譯器輸出)在存在檢查前先剝除,所以 `pkg.py:42:5` 會以 `pkg.py` 驗證。範圍預設為可見螢幕(`--source recent` 掃 scrollback);多選以換行接合複製;無結果時印出 `no file paths found` 並暫停約 1.5 秒。

## AI 用量 / 額度狀態

herdr **沒有原生的用量/額度/token 顯示**（側欄只顯示 agent *狀態*）。它確實有一個逐 pane 的 hook——`herdr pane report-metadata <pane> --source ID --token usage="…" --ttl-ms N`——driver 可以把 `"Claude 62% • Codex 78%"` 之類的標籤推進去（與上方 **待 review 旗標** 用的是同一個 hook,但 herdr 0.7.4 起 token 是帶命名空間的 map,所以 `usage` token 與 `review` token 可以並存,不再互搶單一欄位）。有一個 Codex-only 的社群 plugin（[jerryfane/herdr-codex-usage-kit](https://github.com/jerryfane/herdr-codex-usage-kit)）已從 [CodexBar](https://github.com/steipete/CodexBar) 讀的同一份 `~/.codex` 資料做到這件事；但沒有東西涵蓋 Claude/ChatGPT 額度。延後——CodexBar 的選單列仍是多供應商的檢視。設計與選項記在 [`backlog/herdr-usage-status-driver.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/herdr-usage-status-driver.md)。

## 缺口（沒有乾淨的 herdr 對應）

- **無縫 `Ctrl-hjkl` nvim↔pane 導覽。** `vim-tmux-navigator` 與 tmux 耦合（`is_vim` 的 `ps`/`pane_tty` 啟發式 + nvim plugin）。herdr 沒有 smart-splits 對應物——它的 pane focus 是 `prefix+h/j/k/l`，在邊界不會穿透進 nvim 的 splits。Workaround：在 nvim 裡用它自己的 `<C-w>hjkl`。這是相對 tmux 最大的 UX 退步。
- **OSC133 copy-mode**（`cpout` / `cpblock`、prompt 跳轉、最後輸出 yank）是 tmux 專屬。herdr 的 copy mode（`prefix+[`）是 vi 風格但沒有 OSC133 的 prompt 邊界感知。`cpcmd`（zsh history，與多工器無關）仍可用。
- **裝飾用的狀態列符號**（📌/🔖 當作自由浮動的視窗標籤）：herdr 沒有 `#{@option}` 的 format-string 插值,所以 tmux 風格的狀態列書籤不能移植。*（但「mark-unread / 待 review ⭐」這個具體用途已解決——見上方 **待 review 旗標** 一節——靠逐 pane 的 metadata token;只剩純裝飾的狀態列符號仍是缺口。）*
- **逐鍵 pane 縮放。** tmux 把 `prefix+H/J/K/L`（與 `M-hjkl` 微調）直接綁成縮放;herdr 沒有逐鍵縮放——它用模態的 `resize_mode`（`prefix+r`）再按 `h/j/k/l`。不是精確對等,但是相近的對應物。

> **不是缺口：** vi copy-mode 本身*是*原生（`prefix+[`），且逐 pane 的 agent 狀態是原生偵測——我原本以為會缺的兩件事，結果都內建了。

## 延伸閱讀 (See also)

- [tmux 設定](tmux/README.md) · [Television (tv)](tv.md) · [sesh](sesh.md) · [workmux](workmux.md)
- [工具管理器 —— 工具從哪來](../this_repo/tool-managers.md)
