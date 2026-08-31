# Herdr —— Rust 終端多工器 + AI agent 協調器（試用）

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[herdrdev/herdr](https://github.com/herdrdev/herdr) 是一個用 Rust 寫的終端多工器 (terminal multiplexer)，內建 **coding-agent 感知**——它會追蹤每個 pane 的 agent 狀態（idle / working / blocked / done）。它跟 tmux/zellij 屬於同一類工具，但更偏滑鼠優先 (mouse-first)、更 agent-native。官方文件：<https://herdr.dev/docs/>。

本 repo 把 herdr 當作一個**與 tmux 共存的試用工具 (trial tool)**——你只會執行 `herdr` *或* `tmux`，永不巢狀 (nested)。既有的 tmux / `sesh` / `tmuxp` / workmux 設定完全不動；herdr 純粹是加法，讓你能在不失去日常工具的前提下評估它。

- **安裝 (Install)**：
  - **兩個平台都是** —— GitHub release 的**單一靜態 binary**（`herdr-{linux,macos}-{x86_64,aarch64}`）放到 `~/.local/bin/herdr`，由 `dot_ansible/roles/devtools/tasks/main.yml` 中 `# --- herdr ... ---` 區塊管理。沒有 tarball，所以不需要解壓步驟。
  - macOS **刻意不走** Homebrew，而且這是本 repo 唯一這樣做的工具。上游在 Homebrew/mise/Nix 安裝上停用 `herdr update`，因為 binary 歸套件管理器所有 —— 那等於拿掉了**唯一**能保住 pane 的升級路徑，只剩下重啟 server（也就是殺掉每一個 pane 內的行程）這一條。所以我們捨棄 formula 改用 release binary，讓 macOS 也拿得到 `--handoff`。切換前就裝好的機器，由同一個 role 裡的一次性 `brew uninstall herdr` 遷移（兩份都留著會讓 `PATH` 上出現兩個 binary，最糟是自己對自己 `protocol_mismatch`）。
- **驗證 (Verify)**：`herdr --version`；用 `herdr server reload-config` 驗證設定檔
- **Agent skill**：每次 `chezmoi apply` 都會從 `herdr --skill` 安裝官方 global skill
  到 `~/.agents/skills/herdr/SKILL.md`，並建立 Claude discovery symlink。binary 是版本
  權威；Git vendored 的 catalog 副本刻意不作為 runtime 來源。
- **升級 (Upgrade)**：兩個平台都用 `just upgrade-herdr`（即先執行
  `herdr update --handoff`，再刷新與 binary 同版本的 skill）—— **必須在 herdr 外面跑**，見下

> **`herdr update` 在 herdr pane 裡面會拒絕執行。** handoff 要換掉的正是持有你當下這個 pane 的 server process，所以它 fail closed：
>
> ```console
> $ herdr update --handoff          # 在 herdr 裡面的 pane 執行
> update failed: run `herdr update` outside herdr after detaching from the session
> ```
>
> 正確流程是 **detach（`prefix+q`）→ 在一般終端機執行 → 用裸的 `herdr` 重新接上**。detach 不會殺掉任何東西（關 client ≠ 掉 session），接著 `--handoff` 會在不結束 pane 行程的情況下換掉 server —— 2026-07 實測 0.7.1 → 0.7.5，pane 裡有一個 Claude Code session 全程存活。`just upgrade-herdr` 把這件事寫進流程：偵測到 `HERDR_ENV`/`HERDR_PANE_ID` 時它會**跳過並印出指示**而不是失敗，所以在 herdr pane 裡跑 `just upgrade-all` 不會死在這一步。完整記錄：[`pitfalls/herdr-update-handoff-refuses-inside-pane.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/herdr-update-handoff-refuses-inside-pane.md)。

> **安裝不看版本，升級要自己跑。** Linux 的 ansible task 是用 `herdr --version` 的 rc 當條件 —— 判斷的是「**有沒有裝**」而不是「**是不是最新**」—— 所以新機器拿到的是當天的 latest，之後 `chezmoi apply` 再也不會碰它。這是本 repo [install-vs-upgrade 分離](../this_repo/upgrades.md)的設計，但 herdr 比多數工具更容易出事，因為它的 config 會跑在 binary 前面（`[[keys.command]]` 用了 0.7.4 才有的 `type = "popup"`，舊版 herdr 會拒絕**整個 keys 區塊** —— `reload-config` 回 `status: "partial"` + `keeping current keys settings`，而且只有那一行 diagnostic 會告訴你）。

> **Herdr app 版本與 integration schema 版本是兩件事。** 目前 binary 是 **0.8.0**；`herdr integration status` 顯示的 `v7` 則是 Codex integration 的 schema 版本，不代表 binary 降版。每次 Herdr 升級後若看到 `outdated (v6 < v7)`，執行 `herdr integration install codex`。腳本 sidecar 仍由 Herdr 擁有；`~/.codex/hooks.json` 則透過 chezmoi 的 hook-aware `modify_` merger 與 peon/其他工具共存。
- **設定 (Config)**：`~/.config/herdr/config.toml` —— chezmoi **`modify_` 覆蓋層 (overlay)**（`dot_config/herdr/modify_config.toml.tmpl` + 受管本體 `.chezmoitemplates/herdr/config.toml`）。覆蓋層在每次 `chezmoi apply` 強制套用受管 tables，同時保留其餘所有 live/user-owned 頂層設定，包括 Herdr 目前的 runtime 寫入（見 [設定管理](#config-management-modify_)）。

> **為什麼套件管理器裝的 herdr 會擱淺自己的 server —— 這就是 macOS 離開 Homebrew 的原因。** herdr 的 socket API 有 protocol 版本號，而套件管理器的升級沒辦法重啟 server —— 所以 `brew upgrade herdr` 之後，每一個 CLI 呼叫（連帶所有 `tv herdr-*` channel、`hvibe`/`hcode`、以及各個 `[[keys.command]]` helper）都會 `protocol_mismatch` 失敗，直到 server 重啟為止，而重啟會殺掉所有 pane 內的行程。`herdr update --handoff`——那個能保住 pane 的 live 路徑——在 **Homebrew/mise/Nix 安裝上是停用的**，所以 brew 裝的 herdr 沒辦法迴避這次重啟。本 repo 現在在 macOS 上也改裝自管的 release binary，正是為了補掉這個缺口；下面那篇 pitfall 仍然保留，因為它描述的是任何**尚未遷移**的機器上會發生的事（而且 `just upgrade-herdr` 偵測到套件管理器安裝時會跳過並印出指示）。要用 `herdr status`（看 `compatible:` / `restart_needed:`）判斷，不要看 `herdr --version`。完整的復原對照表：[`pitfalls/herdr-brew-upgrade-strands-running-server.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/herdr-brew-upgrade-strands-running-server.md)。

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

## 用 `herdr-grep` 搜尋 pane 內容

Herdr 能讀取單一 pane，但沒有原生的跨 pane grep。本 repo 部署 **`herdr-grep`**，把 `pane list → pane read → rg` 包成一個指令，並印出每筆命中的完整 Session / Workspace / Tab / Pane 座標：

```console
$ herdr-grep -F 'connection refused'
[session=default workspace=w1 tab=w1:t2 pane=w1:p4] 183:connection refused while opening socket
```

```bash
herdr-grep 'error|failed'                   # regex；當前/default session
herdr-grep -F -i 'connection refused'       # 固定字串、不分大小寫
herdr-grep --visible 'ready'                # 只搜尋目前可見畫面
herdr-grep --source recent-unwrapped 'url'  # 搜尋保留歷史，不受硬換行切斷
herdr-grep --session work 'panic'           # 一個正在執行的具名 session
herdr-grep --all-sessions 'rate limit'      # 所有正在執行的本機 session
herdr-grep --all-sessions --json 'panic'    # 結構化 matches + errors
herdr-grep --pick 'error|failed'             # 先 grep，再以 fzf 選擇並跳轉/attach
herdr-grep --pick --all-sessions 'panic'     # Herdr 外：選擇、預先聚焦、attach session
herdr-grep -F -- -leading-dash              # 保護以 `-` 開頭的 pattern
```

| 面向 | 行為 |
|---|---|
| 預設範圍 | 有 `HERDR_SOCKET_PATH`（Herdr 內部）時搜尋 ambient session，否則搜尋 `default`。`--session NAME` 從 `herdr session list --json` 解析權威 socket；`--all-sessions` 只掃描正在執行的 session。ambient socket 無法唯一對應到 registry 時回傳 2，不會誤標成其他 session。 |
| 內容來源 | 預設 `recent`（完整保留的 scrollback）；`--visible` 只看目前畫面；終端硬換行切斷片語時使用 `--source recent-unwrapped`。 |
| 輸出 | 人類可讀輸出在每一筆命中重複 `session/workspace/tab/pane`。`--json` 另含 socket、cwd、agent 狀態、byte-offset submatches、`complete` 與結構化 errors。行號是**相對於這次 capture**，不是永久 pane 座標。 |
| 互動 picker | `--pick PATTERN` 把已過濾 matches 交給 fzf。Enter 會精確聚焦 pane；在 Herdr 外還會 attach 所選 session。Alt+S 用 `recent-unwrapped` 重跑同一 pattern；Alt+V 回到 `visible`。 |
| Exit status | `0` = 有命中且掃描完整；`1` = 完整掃描但無命中；`2` = 用法錯誤／執行錯誤／**掃描不完整**。pane 在掃描途中消失時，成功的 matches 仍會保留、錯誤送到 stderr/JSON，並回傳 2。 |

在 Herdr 內，**`prefix+Alt+F`** 執行 `herdr-grep --pick --visible`：先輸入一次 grep pattern，再用 fzf refine 已過濾的 matches。Agent pane 使用 Herdr 的精確 `agent focus`；普通 split pane 則透過驗證過的 directional `pane neighbor` / `pane focus` 最短路徑抵達，最後再確認 active workspace/tab 與 `pane layout.focused_pane_id`。已 attach 時若選到其他 session，picker 會拒絕而不是巢狀啟動（請先 detach）。從一般 shell 執行 `--pick --all-sessions`，會先聚焦所選目標再 attach 該 session，與 `hhere` 的 focus-then-attach 模型一致。Preview 行號屬於先前 capture，pane 持續輸出時可能漂移。

搜尋範圍受限於 live Herdr server 仍保留的內容：已關閉的 pane、早於 history limit 的輸出，以及 alternate screen 已丟棄的內容都無法找回。命令必須在能存取 Unix socket 的環境執行；遠端 server 請透過 SSH 執行已部署的 CLI，例如 `ssh server 'herdr-grep --all-sessions -F -- "connection refused"'`。**`herdr --remote` 是互動式 thin-client attach，不是 pane 子指令的 RPC 前綴。**

`tv herdr-agent-panes` 與 `tv herdr-review` 仍只 fuzzy-search metadata（pane/session identifiers、狀態、cwd）。可見 pane 文字只是 preview，不在 Television 的 searchable source 中。Television 在 live query 之前執行 source，且 source 收不到 query，因此 content selection 刻意採 `herdr-grep --pick` → fzf，而不是新增 `tv herdr-grep` channel。

## cwd 與 workspace 命名模型

herdr 追蹤 cwd 的方式跟 tmux 不同,會顛覆兩個常見預期（皆用 `herdr pane list` 驗證）:

- **每個 pane 有兩個 cwd。** `cwd` = shell 的*啟動*目錄（spawn 時固定）;`foreground_cwd` = *即時* cwd,透過 **OSC 7** shell 整合追蹤。shell 裡 `cd` 會更新 `foreground_cwd`;啟動 `cwd` 永不變。
- **子行程 / 子 shell 裡的 `cd` 不會傳上來。** 因為追蹤是 OSC 7-based,一個沒有再送 OSC 7 的子 shell 裡的 `cd`——例如 `chezmoi cd`,它會在 source 目錄 spawn 一個*新*shell——對 herdr 是隱形的。`foreground_cwd` 不動,所以 space 的 git-repo 偵測與 `prefix+G` lazygit 位置都不跟著子 shell 走。這是 OSC 7 的固有特性,**不是** herdr bug——預期行為。
- **新 tab 跟隨聚焦 pane 的即時 cwd（herdr ≥0.7.x）。** 用 `new_cwd = "follow"`（見下）時,*新 tab* 繼承聚焦 pane 的即時 cwd——跟 *split* 一樣。herdr [issue #912](https://github.com/ogulcancelik/herdr/issues/912) 改了 `follow`,讓 tab 跟 split 行為一致;舊的「新 tab 開在 workspace 根（通常 `$HOME`）」被當成 bug 移除了。**沒有任何 `new_cwd` 值**（也沒有 workspace 層級的 cwd——`herdr workspace get` 完全沒有 cwd 欄位）能讓新 tab 開在 workspace 根;要那樣請用下方的 **`prefix+C`**。
- **workspace（space）label 自動跟隨 root/primary pane 的即時 cwd basename**（例如 → `chezmoi`、`trading-journal`）。在 **tab 1** 裡 `cd` 會改 space 名;在其他 tab 裡 `cd` 不會。沒有 config 旋鈕控制這個。
- **相對路徑的 `--cwd` 是由 SERVER 解析的,而且解析失敗會靜默退回 `$HOME`。** `herdr workspace create --cwd ../foo` 是把 `../foo` 接在 **`herdr server` 當初啟動的目錄**後面——*不是*接在你 shell 的 `$PWD` 後面;而當那個路徑不存在時,herdr 會回傳 `{"result":{"type":"ok"}}`,pane 卻開在 `$HOME`。沒有 error,也沒有 warning。**tmux 恰好相反**:`new-session -c ../foo` 是 client 端解析的——這正是為什麼 `shere`/`scode`/`svibe` 原版不需要防護、而 herdr 移植版需要。任何使用者給的路徑都必須在**呼叫端的 shell** 先絕對化再交給 CLI——`24_herdr.sh` 用 `_herdr_abs_dir` 做這件事。見 [`pitfalls/hhere-p-relative-path-opens-workspace-at-home.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/hhere-p-relative-path-opens-workspace-at-home.md)。

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
| dev / lazygit / scratch launcher | **自訂 command pane + popup** | lazygit 等全螢幕 TUI 維持暫時 pane；短命 modal task 才用 popup |
| URL 選單（`prefix+u`,tmux-fzf-url） | **自訂 command pane + 輔助腳本** | `prefix+u` → `url-pick.sh`（fzf → `x open`）；`--source recent` 掃描 scrollback |
| 翻譯正在讀的 pane | **tmux 沒有對應物** | `prefix+t` → `pane-translate.sh` → `translate -2` 雙語 popup；範圍變體放在 `prefix+y` |
| 檔案路徑選單（`prefix+p`；tmux 上為 extrakto `prefix+Tab`） | **自訂 command pane + 輔助腳本** | `prefix+p` → `path-pick.sh`——兩層（cwd 下存在的優先）→ `x copy` |
| 本機/遠端 attach 間的 Neovim clipboard | OSC 52 **只寫入**；不支援 clipboard query | yank 送到 attached client；普通 `p` 用 Neovim register；外部文字用 terminal paste 貼入 |
| 搜尋所有 pane 內容並跳轉 | **CLI pipeline + fzf + 精確聚焦 helper** | `prefix+Alt+F` → `herdr-grep --pick --visible`；Alt+S 搜尋 unwrapped scrollback |
| 無縫 `Ctrl-hjkl` nvim↔pane 導覽 | **沒有 herdr-aware smart-splits** | **缺口**——見下方 workaround |
| OSC133 copy-mode（`cpout`/`cpblock`） | tmux 專屬 | **缺口**——`cpcmd`（zsh history）仍可用 |
| 每視窗狀態符號 + 書籤 ⭐📌 | 部分——`report-metadata --token`（逐 pane metadata token、與 agent 狀態正交） | **待 review 旗標**（`hmark`/`prefix+m` + `tv herdr-review` 收件匣）；純裝飾的狀態列符號仍是缺口（無 format-string 插值） |
| AI session-summary / agent-wakeup 擷取 | `agent-wakeup` 使用原生 `agent list/get/read` 與穩定的 agent-session ID | **已完成**——tmux/Herdr 雙 backend 狀態、排程、預覽與安全送出 |

## 快捷鍵 (Keybindings)

Prefix 是 `ctrl+b`（跟 tmux 一樣）。內建 action 只能*重綁 (rebind)*（herdr 的 action 集合是固定的）；其餘一切都是 `[[keys.command]]` 自訂指令。自訂指令會收到 `$HERDR_SOCKET_PATH`、`$HERDR_ACTIVE_PANE_ID`、`$HERDR_ACTIVE_PANE_CWD`，並在聚焦 pane 的 cwd 下執行。

> **兩組 herdr 環境變數。** 上面那組 `HERDR_ACTIVE_PANE_*` **只**會被注入到 `[[keys.command]]` 的呼叫裡。而每個*跑在 herdr pane 內的 shell* 還會拿到一組**環境值 (ambient)**：`HERDR_ENV=1`、`HERDR_PANE_ID`、`HERDR_TAB_ID`、`HERDR_WORKSPACE_ID`、以及 `HERDR_SOCKET_PATH`（當前 session 的 socket）。腳本用 `HERDR_ENV` 當作「我在不在 herdr 裡？」的判斷，並繼承 `HERDR_SOCKET_PATH` 來鎖定當前 session——這正是 `hvibe`/`hcode` 依賴的東西。

> **Pane 環境在 herdr-server 啟動時凍結。** 不像 tmux（`update-environment`），herdr **不會**在新 client 接上時更新 `SSH_CONNECTION` / `DISPLAY` / `WAYLAND_DISPLAY` / `SSH_AUTH_SOCK` —— 每個 pane 繼承的是 daemon 首次啟動時的值。實際後果：透過 SSH 時 pane 的 `$SSH_*` 是空的，而 `$WAYLAND_DISPLAY` 還指著過期的本機 display，所以按這些變數挑後端的剪貼簿工具會複製到錯的機器。`x` 與 Neovim 靠判斷 `HERDR_ENV`（→ 走 pane TTY 的 OSC 52，它*確實*代理到真正的 client）繞過。Neovim 刻意只用這條路做 **copy**：Herdr 不會轉送 OSC 52 clipboard-query response，若把完整 provider 接到 `unnamedplus`，普通 `p` 最多會卡十秒。Editor register 用普通 `p`；外部剪貼簿文字用 terminal paste。見 [`pitfalls/x-copy-over-ssh-writes-remote-clipboard-not-osc52.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/x-copy-over-ssh-writes-remote-clipboard-not-osc52.md)、[`pitfalls/nvim-p-waits-for-osc52-response-in-herdr.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/nvim-p-waits-for-osc52-response-in-herdr.md) 與 [clipboard.md](clipboard.md)。透過 `SSH_AUTH_SOCK` 轉發的 agent，需要每個 pane 重新 export，或從有它的 session 啟動 server。

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
| `prefix + Alt + e` | 只編輯 active runtime config、驗證並 reload（永不呼叫 chezmoi） | command pane |
| `prefix + shift + b` | 新 git worktree（從 `prefix + shift + g` 移過來） | rebound |
| `prefix + d` | [`dev`](https://github.com/daviddwlee84/dev-cli) repository/task/worktree dashboard | command pane |
| `prefix + G` | lazygit 暫時 pane（近全螢幕 popup 會阻止切 tab/workspace，因此試用後移除） | command pane |
| `prefix + M` | btop 系統監控器 | command pane |
| `prefix + N` | nvtop GPU 監控器 | command pane |
| `prefix + U` | `tv tools`（CLI launcher） | command pane |
| `` prefix + u `` | **URL 選單** — 從 pane fzf 挑一個 URL 並開啟（`x open`）；tmux-fzf-url 對應物。`--source recent` = 完整 scrollback | command pane |
| `prefix + T` | `tv herdr-sesh`（workspace/dir 切換） | command pane |
| `prefix + a` | `tv herdr-agent-panes`（即時 agent panes） | command pane |
| `prefix + Alt + A` | `tv agent-wakeup`（tmux/Herdr 雙 backend quota 等待與排程 continue） | command pane |
| `prefix + f` | `tv fleet-hosts`（SSH picker） | command pane |
| `prefix + Alt + F` | 輸入 pane-content pattern → `herdr-grep --pick --visible` → fzf 精確跳轉；Alt+S = scrollback、Alt+V = visible | command pane |
| `prefix + m` | 切換目前 pane 的**待 review** 旗標（⭐） | command pane |
| `prefix + i` | `tv herdr-review`——待 review **收件匣**（被標記的 pane） | command pane |
| `` prefix + p `` | **複製檔案路徑** ——兩層 fzf（cwd 下存在的路徑在上），複製解析後的絕對路徑（`x copy`） | command pane |
| `` prefix + ` `` | scratch shell | command popup |
| `prefix + E` | **執行任意指令**（在該 pane 的 cwd）—— 用 fzf 從歷史挑、或直接打新的；指令結束後 popup 自己關掉（[細節](#run-any-command)） | command **popup** |
| `prefix + O` | herdr-plus **Projects**（layout launcher） | plugin action |
| `` prefix + t `` | **翻譯這個 pane** ——在 popup 裡以雙語對照顯示當前畫面（[詳細](#translate-pane)） | popup |
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

- **純開 pair（`hhere` / `hroot`）** 補上了「其他每個 herdr 入口都強制要 git repo + 完整 agent layout」的缺口。tmux 的 `tmux new-session` 會直接把你丟進 `$PWD`；herdr 多了一層 Workspace，所以少了這對指令，你得先啟動 herdr、建一個 space（會依 `new_cwd` 開在 `$HOME`）、再手動 `cd`。`hhere` 一步到位：`herdr workspace create --cwd "$PWD"` → focus → 在外部就 attach。不需要 git；選用的指令以**原始**方式執行（不做 specstory/on-exit 包裝——那留給 `hcode`/`hvibe`）。flag 見 `hhere -h` / `hroot -h`。**Label 注意事項**：tab 1 裡 `cd` 之後，herdr 會把 workspace 重新命名為 root pane 的*當前* cwd basename（見上方 **cwd & workspace-naming model** 一節），所以冪等聚焦是盡力而為——label 漂移後重跑會開一個新的 workspace。**`-p DIR` 會先在你的 shell 絕對化**（透過 `_herdr_abs_dir`，與 `hcode`/`hvibe` 共用）再交給 herdr，所以 `hhere -p ../sibling` 這類相對路徑可以正常運作，打錯的 DIR 也會直接報錯，而不是靜默開在 `$HOME`——原因見上方 cwd 模型一節的 `--cwd` 那條。
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

**Quick Actions** 同樣由 chezmoi 管理，位於 `…/cloudmanic.herdr-plus/quick-actions/`（每個 action 一個 TOML）。本 repo 出貨六個 **copy** action（見 [複製 pane 與 space 的資訊](#copy-to-clipboard)）,外加 plugin 的五個**起手式**範例（GitHub / Google / Search Google / Open Repo / Reveal Working Dir）,已為 Linux 調整——macOS `open` → 本 repo 的跨平台 [`x open`](../shells/aliases.md),repo 選單指向 `daviddwlee84/*`。這些 copy 操作刻意集中在此處,不再占用六個 prefix 直達鍵。因為這個受管目錄非空,herdr-plus **不會** 自己 seed 那些範例（它只在*空*目錄時 seed）,所以在此 vendored;不要的 TOML 刪掉即可。要新增就往這裡丟一個 TOML,或在 `<repo>/.herdr-plus/quick-actions/` 出貨一組 repo 本地的。

> **Quick Actions 是給一次性、非互動式指令用的**（內建範例全是 `open <url>`）。herdr-plus 用 `sh -c` 跑選中的 action,沒有 PTY、沒有互動 stdin,所以互動式 TUI 會出問題——btop 立刻退出、nvtop 收不到 F10。要跑 TUI 就用 dev/lazygit 那種*浮動 command pane*（`[[keys.command]] type="pane"`）——這就是為何 **dev**（`prefix+d`）、**btop**（`prefix+M`）與 **nvtop**（`prefix+N`）是快捷鍵而非 Quick Action。

## Television 整合 {#television-integration}

大多數 `tv` channel（`tools`、`fleet-hosts`、`mlflow`、`kill-process`、`ssh-config`）的 action **不與 tmux 耦合**，所以在 herdr command pane 裡原樣就能跑——綁一個鍵到 `tv <channel>` 即可。只有那些 action 會呼叫 `tmux …` 的 channel 才需要 herdr-aware 變體。這裡出貨三個：

- `herdr-sesh`（`dot_config/television/cable/herdr-sesh.toml`）—— 列出 herdr session/workspace + zoxide 目錄；Enter 會分派 `herdr session attach` / `herdr workspace focus` / `herdr workspace create --cwd`，而不是 `sesh connect` / `tmux switch-client`。`Ctrl+D` 關閉選中的 workspace;**`Alt+Y` 複製它的目錄**（workspace 列與 zoxide 目錄列都適用——見 [`dir` 與 `cwd` 的差別](#space-dir)）。preview 會把推導出的目錄顯示在 `workspace get` 原始 JSON 之上,讓你先看清楚 `Alt+Y` 會給你什麼。
- `herdr-agent-panes`（`dot_config/television/cable/herdr-agent-panes.toml`）—— 與 `agent-panes` 同來源，但切換/kill 改用 `herdr pane focus` / `herdr pane close`。
- `herdr-review`（`dot_config/television/cable/herdr-review.toml`）—— **待 review 收件匣**：只列出帶 ⭐ 旗標的 pane（`tokens.review` 非空）。Enter 會 focus 該 pane 的 workspace/tab 並**保留**旗標;`Alt+C` 則 focus **並**清除旗標（「mark read」）。綁在 `prefix+i`。見下方 **待 review 旗標** 一節。

原本綁 tmux 的 `sesh` / `agent-panes` channel 保持不變以利共存。

> **綁在 command pane 的 channel，Enter action 要用 `mode = "execute"` 而不是 `"fork"`。** `type = "pane"` 綁定只有在它的指令結束時才會消失，而 tv 在 `execute` action 之後會退出、在 `fork` 之後則會繼續活著——所以 `fork` 的 Enter 會讓 picker pane 懸在你剛 focus 的 workspace 上面。`herdr-sesh` 的 `[actions.open]` 正是為此改用 `execute`；它的 `ctrl-d`（`close_ws`）仍保留 `fork`，因為它與 `reload_source` 搭配，tv 必須活著才能重繪清單。同樣的取捨也適用於 `herdr-agent-panes` / `herdr-review`，這兩個目前仍是 `fork`（Enter 重新 focus 但不離開 picker——對分診（triage）是刻意設計；若你想要一次性跳轉就改掉它）。

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
| codex | `~/.codex/herdr-agent-state.sh` + `~/.codex/hooks.json` 的 `SessionStart` hook（0.8.0 integration v7） | `hooks.json` 是 hook-aware `modify_` 目標：Herdr 條目會保留，peon 條目會加法合併；`config.toml` 不再放 lifecycle hooks。 |
| opencode | `~/.config/opencode/plugins/herdr-agent-state.js`（獨立 plugin） | 不會——只有 `workmux-status.ts` 受管；herdr 的 plugin 共存。 |
| cursor | `~/.cursor/herdr-agent-state.sh` + hook | 腳本在 chezmoi 之外；共存。 |

這些整合檔案**未**被 vendored 進 repo，所以**不會**在其他機器上重現（在那些機器再按一次 *install*，或跳過 onboarding）。它們用 herdr 自己的 socket，不會干擾 tmux/workmux（不同機制）。移除方式：`herdr integration uninstall <agent>`——而對 **claude**，之後要再跑一次 `chezmoi apply`，讓 merger 從 `settings.json` 丟掉那個已移除的 hook。

### 設定管理（為何用 `modify_`） {#config-management-modify_}

Herdr 是 `~/.config/herdr/config.toml` 的另一個 writer。上游 v0.8.2 與目前 `master` 會持久化 onboarding、theme/UI、sound、toast、pane-label、agent-sort 設定、update channel 與 key reset。這些編輯會保留無關行與未知 sections，但最後仍是不加鎖的 whole-file write；外部修改之後仍需明確 reload。

這個檔案原本用 `create_` 只植入一次。2026-07 轉換時，實測 source 與 live target **逐 byte 相同**；並沒有發生過已觀察到的 onboarding clobber 事故。改成 `modify_` 是在修正 split key 與 cwd 行為時做的**預防性雙 writer 修正**。`create_` 雖不覆蓋 Herdr 寫入，卻也讓後續 repo 編輯永遠到不了已植入的主機。

現在改成 **`modify_` 覆蓋層**——`dot_config/herdr/modify_config.toml.tmpl`，一個小腳本：

- 以 `.chezmoitemplates/herdr/config.toml` 為受管 base，每次 apply 完整強制套用 `[theme]`、`[ui]`、`[terminal]`、`[keys]`；並
- **原樣拉回 (pull through)** 其餘每個 live 頂層 key。`onboarding` 與 `update.channel` 是目前真正的 Herdr 寫入；其他 `[update]` subkeys、`[session]`、`[remote]`、`[experimental]`、未知 sections 等則刻意以 live/user-owned 設定保留，不能誤稱為目前的 writeback。

TOML 沒有 `jq`，所以合併用 Python 透過 `uv run --with tomlkit` 跑（tomlkit 能 round-trip 註解**與** `[[keys.command]]` array-of-tables；stdlib `tomllib` 唯讀，而 codex 的 `modify_` emitter 無法輸出 AoT）。它退化到系統 `python3`，再退化到直接輸出 raw managed template，所以沒有 Python 的全新主機仍拿到完整設定。這是繼 `~/.codex/config.toml`（`dot_codex/modify_config.toml.tmpl`）之後第二個 TOML-overlay 先例。

之後的 `chezmoi apply` 會刻意重新強制套用 canonical `[theme]`、`[ui]`、`[terminal]`、`[keys]` tables。因此要持久化某一項 runtime 實驗，必須**另外手動、選擇性編輯** `.chezmoitemplates/herdr/config.toml`。這個 `modify_` target 絕不能執行 `chezmoi add` 或 `chezmoi re-add`：它們可能取代／繞過 merger，或把 runtime-owned state 匯入 source。

### 編輯 runtime config、驗證並 reload（`prefix + Alt + e`）

`prefix + Alt + e` 會開一個暫時 command pane，執行 `~/.config/herdr/edit-config.sh`。它**只編輯 active runtime target**：非空的 `$HERDR_CONFIG_PATH` 優先，否則是 `~/.config/herdr/config.toml`。它永不呼叫 chezmoi。小寫 `e` 與 `prefix + E` 指令 popup、Herdr 內建的 `prefix + e` scrollback editor 都不同。

防護流程依序如下：

1. 要求 target 是既有 regular file（Unix symlink 直接拒絕），解析單一 blocking `$EDITOR` executable/wrapper（fallback `vi`），並在開 editor 前以 `cp -p` 建立唯一的同目錄 backup。
2. 編輯 exact target，再用 `HERDR_CONFIG_PATH="$target" herdr config check` 驗證同一路徑。
3. Editor 或 validation 失敗時，把被拒內容保存成權限受限的 sibling `config.toml.invalid-*`，再以同 filesystem move 原子還原先前有效 backup；不 reload。
4. 驗證成功後才呼叫 `herdr server reload-config`；繼承的 `$HERDR_SOCKET_PATH` 讓 reload 留在目前 session。成功時移除 backup。

Preflight 或 backup 失敗會保持 target 不變且不開 editor。Reload 失敗**不會**丟棄有效編輯：edited target 與原始 backup 都保留。只有 cleanup 失敗時同樣保留／回報 backup，不 rollback。Rollback 失敗則回報並保留所有可恢復的 target/candidate/backup 路徑。互動 command pane 會等 Enter 讓錯誤留在畫面；非互動執行不等待。

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

`prefix + E` 在適合 popup 的情境提供通用入口：**用 fzf 從 shell 歷史挑一條指令（或直接打一條新的），在聚焦 pane 的 cwd 執行，結束後關閉 popup。** 輔助腳本：`~/.config/herdr/run-command.sh` = [`dot_config/herdr/executable_run-command.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_run-command.sh)。

**為什麼用 `type = "popup"` 而不是其他做法** —— `prefix+E` 刻意浮在上方，而不是再開一個 command pane：

| 做法 | 問題 |
|---|---|
| `type = "pane"`（`prefix+d/G/M/N`） | 執行期間會切開**平鋪版面**，整個重排 |
| `prefix + c` → 打指令 → `exit` | 四個步驟，而且會弄亂 tab bar |
| **`type = "popup"`** | session-modal，浮在版面**之上** —— 什麼都不重排，關掉就回到原位 |

`type = "popup"` 需要 **herdr ≥ 0.7.4**（#1125 加入，`width`/`height` 支援 cell 數或百分比）。它才是真正的 `tmux display-popup -E` 對應物。

`prefix + `` ` ``（scratch shell）基於同樣理由也是 popup —— 當它還是 command pane 時會佔滿版面，感覺像是把當前視窗 *zoom* 起來而不是開暫存空間。`prefix+d` / `prefix+G` / `prefix+M` / `prefix+N`（dev / lazygit / btop / nvtop）維持 `type = "pane"`。近全螢幕 lazygit popup 已在試用後移除：Popup 是 **session-modal**，開著時不能切到其他 tab/workspace。這個限制適合短命 modal task，不適合可能留著的全螢幕 TUI。

**它沒辦法做成 herdr-plus Quick Action**（`prefix + y`），雖然那是最直覺會去找的地方。兩個硬阻礙：Quick Actions 透過 `sh -c` 執行、**沒有 PTY/stdin**（這正是 `btop`/`nvtop` 是 command pane 而不是 Quick Action 的原因），而且每個 action 都是寫死的 `command = "…"` 字串，沒有自由輸入欄位。

行為：

| | |
|---|---|
| **cwd** | `--cwd` → `$HERDR_ACTIVE_PANE_CWD` → `herdr pane get` 的 `foreground_cwd` → `$PWD`。優先用環境變數的好處是：即使 CLI 與舊 server protocol 不相容，它照樣能運作 |
| **選取** | fzf 翻 `$HISTFILE`（預設 `~/.zsh_history`），最新在上、已去重。**Enter** 執行反白的那筆歷史；**`Alt+Enter` 執行你字面打的內容**，即使歷史裡還有 match 也一樣；完全沒 match 時按 Enter 同樣會當作新指令執行；`Esc` 則什麼都不做。沒有 fzf 時退回純 `read` 提示 |
| **shell** | 預設 `$SHELL -ic`，所以這個 repo 的 alias 與 function 都能解析（`gst`、`cas`、`x` …）。`--sh` 改用 `sh -c` —— 快，但 alias 不存在 |
| **結束時** | 成功就關閉；失敗則印出 `[exit N]` 並等你按 Enter，讓錯誤訊息不會一閃而過。可用 `HERDR_RUN_HOLD=always\|never` 覆寫 |

> 有兩個可攜性陷阱已經在腳本裡處理掉了，如果你要改它值得先知道：`~/.zsh_history` 是 extended-history 格式（`: <ts>:<elapsed>;<cmd>`）**而且含有非 UTF-8 位元組**，所以除非在 `LC_ALL=C` 下解析，BSD `sed` 會以 `sed: RE error: illegal byte sequence` 中止；另外「最新在上」的反轉用 POSIX `awk` 實作，因為 `tail -r` 只有 BSD 有、`tac` 只有 GNU 有。

> **為什麼非要有 `Alt+Enter`。** 只要 fzf 還有 match，單純的 Enter 就無法表達「**執行我字面打的那串**」—— 打 `ls -la` 而歷史裡有 `ls -la /tmp`，Enter 會選走歷史那筆，於是整個 picker 感覺起來只能重播舊指令。`--expect=alt-enter` 就是那個逃生口。要注意 fzf 的輸出行數**不是固定的**：在 `--print-query --expect` 下，沒有 match 的 Enter 只會印出 query（一行），而選中時才印出 query / key / selection 三行。所以腳本是從第 2 行讀 key（空的或不存在 ⇒ 純 Enter），而且只在 exit code 0 時才相信第 3 行。

## 複製 pane 與 space 的資訊到剪貼簿 {#copy-to-clipboard}

六個低頻「把這個抓到剪貼簿」的操作都收在 `prefix+y` Quick Actions 清單中,並由同一支腳本驅動（`~/.config/herdr/pane-copy.sh` = [`dot_config/herdr/executable_pane-copy.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_pane-copy.sh)）。它把一個 herdr CLI 呼叫萃取成人類可讀的文字,再導入本 repo 自己的 [`x copy`](../shells/aliases.md)（自動選 pbcopy / wl-copy / xclip / xsel / OSC 52;`x` 以絕對路徑 fallback 解析,因為 Quick Action 可能在沒有互動式 PATH 的情況下執行）。action 透過 `$HERDR_PLUS_PANE_ID` 傳入聚焦 pane；為空時 helper 會 fallback 到 `herdr pane current`。

| 操作 | Quick Action | 進剪貼簿的內容 |
|---|---|---|
| `process` | *Copy pane: process info* | 前景 process——`cmdline` + `pid` + `cwd`（來自 `herdr pane process-info`） |
| `coord` | *Copy pane: coordinate* | 可直接貼回 CLI 的 `session` / `workspace` / `tab` / `pane` id 區塊 + `socket` 路徑 + 一行 `# herdr pane get <pane>` |
| `content`（可見） | *Copy pane: content (visible)* | pane 目前螢幕上的文字（`herdr pane read --source visible`） |
| `content`（scrollback） | *Copy pane: content (scrollback)* | pane 完整保留的 scrollback（`--source recent`） |
| `dir` | *Copy space: dir* | **workspace（space）的根目錄**——見下方 |
| `cwd` | *Copy pane: cwd* | 聚焦 pane 的**即時**工作目錄（等同 `pwd` / [`abspath`](../shells/aliases.md) 的答案） |

**座標**回答「這是哪個 `session > space > tab > pane`?」,並以可餵回 CLI 的形式呈現。herdr 在 `pane`/`tab`/`workspace` 子命令上**沒有 `--session` 旗標**——session 只能經由 `HERDR_SOCKET_PATH` 指定——所以區塊裡納入 `socket=` 那行作為 session 選擇器（session *名稱* 則是把該 socket 對 `herdr session list --json` 比對而得）。

所有 `copy-*.toml` Quick Actions 都共用這支 helper,並由 `prefix+y` 模糊啟動。原本的直達鍵（`prefix+P/D/V/S/d/ctrl+d`）已移除,讓 prefix namespace 優先留給互動式工具；`prefix+d` 現在啟動 dev dashboard。互動式檔案路徑 picker 仍保留在 `prefix+p`,因為 fzf 需要 PTY/stdin,無法在 Quick Action 裡執行。

### `dir` 與 `cwd` 的差別,以及為什麼右鍵選單做不到 {#space-dir}

`dir` 回答的是*「這個 space 是關於哪個目錄?」*——也就是你會想從 sidebar workspace 列右鍵 **Copy dir** 拿到的東西。兩個入口:

| 介面 | 方式 | 範圍 |
|---|---|---|
| `prefix+y` → *Copy space: dir* | herdr-plus Quick Action | **聚焦中**的 workspace |
| `prefix+T` → **`Alt+Y`** | [`herdr-sesh`](#television-integration) tv channel | 清單裡的**任一** workspace——嚴格來說比右鍵能給的還多 |

**herdr 的 context menu 無法擴充。** 它是編進 binary 的固定 enum——整份清單就是一段打包字串（space:`Rename` · `Close` · `New worktree` · `Open worktree...` · `Close group` · `Expand` · `Delete worktree checkout...`;pane:`New tab` · `Rename pane` · `Split right` · `Split down` · `Close pane` · `Swap with focused pane` · `Clear pane name`）。在 0.7.5 上從三個方向驗證過:`config.toml` 沒有任何 menu 表（只有 `[[keys.command]]` 與 `ui.right_click_passthrough_modifier`,後者管的是右鍵要不要傳給*內層 app*）;plugin manifest 的 `[[actions]]` 帶有 `contexts = ["workspace"]`,**看起來**像選單放置位置但其實是死的;而 `herdr api schema --json` 裡完全沒有 "menu" 這個字,所以執行期也無法注入。

> **上游狀態（herdr 升級時重新確認）。** 被提過四次——[#1511](https://github.com/ogulcancelik/herdr/issues/1511)（使用者自訂選單項目）、[#1671](https://github.com/ogulcancelik/herdr/issues/1671)、[#1776](https://github.com/ogulcancelik/herdr/issues/1776)、[#1830](https://github.com/ogulcancelik/herdr/issues/1830)——**全部以 `NOT_PLANNED` 關閉**,其中三個是被 `kangal-bot` 以「feature request 不該開在只收 bug 的 tracker」自動關掉的。#1776 裡明白寫著 `contexts`「目前只會出現在 `plugin action list` 的 API 回應裡」。被導去的討論串（[#1609](https://github.com/ogulcancelik/herdr/discussions/1609)、[#1672](https://github.com/ogulcancelik/herdr/discussions/1672)、[#1722](https://github.com/ogulcancelik/herdr/discussions/1722)）到現在都還開著、也沒有維護者回應。

**space 目錄怎麼推導出來的——以及唯一的但書。** herdr **在任何地方都沒有暴露 workspace 層級的 cwd**:`herdr workspace get` 與 `herdr api snapshot` 回傳的都是同一個只有 `label` / `number` / `tab_count` / `pane_count` 的物件。所以它是算出來的,由 [`~/.config/herdr/space-root.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_space-root.sh) 負責——這是 `pane-copy.sh dir`、`prefix+C` 開新 tab 的 helper,以及 tv channel 的 preview + `Alt+Y` 共用的單一真實來源:

- **space 根目錄 = 該 workspace *現存最舊* tab 的 cwd。** tab 的 `.number` 是單調遞增的**建立計數器**,不是顯示索引——一個 space 可能持有編號 `10/13/14/15` 但顯示為 `1/2/3/4` 的 tab——所以 `sort_by(.number)[0]` 代表「最舊」,這才是「這個 space 當初從哪個 tab 開始」的正確概念。
- **但書:sidebar 的 label 在建立時就固定了,之後不會重算**,所以一旦你在那個最舊的 tab 裡 `cd`,label 與推導出的目錄就會分岔,而且 API 裡沒有任何東西能還原原始路徑。實測遇過:一個標示為 `2026-05-14-grafana-provisioning-with-docker-otel-lgtm` 的 space,其最舊 tab 其實位於 `…/grafana/dashboards/Jingle.AI`。`dir` 回報的是後者——真正的當前目錄,而不是那個過時的名字。

`cwd` 之所以存在,是因為兩者在日常使用中真的會分岔:實測有個根目錄為 `2026-07-24-unify-ashare-sdk` 的 space,底下的 pane 分散在三個毫不相干的 `Documents/Program/*` 樹裡。`dir` 是專案,`cwd` 是*這個 pane* 實際待著的地方。

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

URL 選單的複製路徑姊妹版。`prefix+p` 開一個 fzf 彈窗,列出聚焦 pane 裡的檔案路徑;挑一個(或多個),路徑就複製到剪貼簿。它保留直達鍵,因為互動式 fzf 無法在 `prefix+y` Quick Actions 裡執行。tmux 上的對應物是 **extrakto** plugin(`prefix + Tab`)——見 [tmux 快捷鍵](tmux/keybindings.md)。

輔助腳本:`~/.config/herdr/path-pick.sh` = [`dot_config/herdr/executable_path-pick.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_path-pick.sh),與 `url-pick.sh`/`pane-copy.sh` 完全同構(相同的 pane + `x` 解析 + `herdr pane read` 管線),用 [`x copy`](../shells/aliases.md) 複製。

**noise 問題與處理方式。** 與 URL(用 `scheme://` 自我標識)不同,檔案路徑沒有標記,所以單靠 regex 會誤中日期(`2024/01/02`)、速率(`10k/s`)與分數(`1/2`)。兩道防線:

| 防線 | 行為 |
|---|---|
| 萃取 | extrakto 的路徑啟發式——含斜線的 token(`/…`、`~/…`、`./`、`a/b/c`)+ 裸 `file.ext`;去掉尾端 `",):`;速率/分數 token 直接排除 |
| 存在檢查（noise 殺手） | 每個候選對 pane cwd(`$HERDR_ACTIVE_PANE_CWD`,否則 `herdr pane get` 的 `foreground_cwd`,否則 process-info cwd)解析後 `test -e` |
| **兩層清單** | **存在**的路徑排在最前(複製為解析後的**絕對**路徑);其餘——遠端 / 過期 / 假設的——放在 `── unverified ──` 分隔線下方(仍可選),所以真實但無法解析的路徑不會遺失 |

`path:line:col` 後綴(grep `-n` / stack trace / 編譯器輸出)在存在檢查前先剝除,所以 `pkg.py:42:5` 會以 `pkg.py` 驗證。範圍預設為可見螢幕(`--source recent` 掃 scrollback);多選以換行接合複製;無結果時印出 `no file paths found` 並暫停約 1.5 秒。

## 翻譯 pane（`prefix+t`） {#translate-pane}

把焦點 pane 的內容送進 [`translate`](https://github.com/daviddwlee84/translate) CLI 的**雙語模式**，結果顯示在 popup 裡：原文逐行保留，每個區塊的譯文以 `  ↳ …` 交錯在下方。tmux 沒有對應物——這是 herdr 專屬的，建立在 `herdr pane read` 之上。

Helper：`~/.config/herdr/pane-translate.sh` = [`dot_config/herdr/executable_pane-translate.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/herdr/executable_pane-translate.sh)，是 `pane-copy.sh` / `url-pick.sh` / `path-pick.sh` 的兄弟（相同的 pane 解析與 `herdr pane read` 管線）。

| 入口 | 範圍 | 結果去哪裡 |
|---|---|---|
| `prefix + t` | 畫面上這一頁 | popup，用 `less -R` 分頁 |
| `prefix + y` → *Translate pane* | select 清單：當前頁 / 最近 200 / 500 / 1000 行 | 往右分割出的 pane，並自動 focus |
| `prefix + y` → *Translate pane into…* | 當前頁 | 同上，目標語言由你輸入 |
| `prefix + y` → *Translate pane: copy* | 當前頁 | 剪貼簿（`x copy`）＋一則通知 |

### 要取多少 scrollback——以及為什麼「當前頁」才是誠實的預設 {#translate-scope}

最直覺的擔心是：固定視窗會切在句子中間，而 coding agent 的 plan 可能超過一整頁。三個事實決定了答案：

- **跑在 alternate screen 上的 agent pane 根本沒有 scrollback。** Claude Code 的 pane 回報 `scroll.max_offset_from_bottom: 0`，而 `herdr pane read --source recent --lines 1000` 剛好只回傳 `viewport_rows` 行——與 `--source visible` 逐字相同。離開 alternate screen 的行永遠不會進入 herdr 的 host scrollback，所以再大的 `--lines` 也救不回來。（隔壁分頁的 shell 或 `codex` pane 則能回報數千行：這是**逐應用程式**的差異，不是全域限制。）也就是說，對於促成這個功能的情境，一頁就是全部——而且因為 `--source visible` 呈現的是你在 app **內部**捲到的位置，「當前頁」是精確的，不是猜的。在 agent 裡捲動，再按一次即可。
- **`herdr pane read` 上限是 1000 行**，而且沒有 offset/分頁參數，所以 `recent:1000` 是硬天花板——與 [`pane-copy.sh` 記錄的限制](#copy-to-clipboard)相同。
- **1000 行大約是 62 KB。** `translate` 的成本大致是 10 KB ≈ 60 秒、20 KB ≈ 95 秒，而 provider 在遠低於 62 KB 時就會拒絕。因此真正的上限是**字元預算**（`HERDR_TRANSLATE_MAX_CHARS`，預設 `12000` ≈ 75 秒），不是行數。`recent:N` 只是挑一個粗略視窗，再由預算裁切——每次裁切都會寫在 pane 標頭上，絕不無聲進行。

### 不切在內容中間

分兩個層次處理，而且第二個更重要：

| 機制 | 作用 |
|---|---|
| 上緣邊界對齊（僅 `recent:N`） | 掃描前 `clamp(15%, 5, 40)` 行找區塊邊界——空行、agent turn 標記（`●⏺⎿•✻>❯$#`）、水平分隔線，或看起來像標題的行——從那裡開始，並在前面加上 `[… earlier output omitted …]`。若在 margin 內找不到邊界，就完整保留並加上 `[… continued from earlier output …]`。`visible` 擷取**永遠不會**從上緣裁切：那正是你正在看的畫面，最多只會加標記。 |
| `--instructions` | 擷取內容會附帶一段 system prompt，告訴模型這是終端機節錄、可能從句中開始或結束、必須逐字翻譯眼前的內容而不要自行補完，並且指令 / 路徑 / 旗標 / 識別字 / 程式碼 / JSON 一律原樣保留。LLM 翻譯器不需要乾淨的邊界，它需要的是「被告知邊界不乾淨」。 |

`recent:N` 使用 `--source recent-unwrapped`，會把 soft wrap 接回去，所以長行不會以斷在字中間的形式送進翻譯。

### 翻譯前的清理

三個階段，全部有邊界限制，不會吃掉正文：

- **只清底部裝飾。** 從最後一行往上走，遇到第一行真正的內容就停：輸入框（`╭…╰`）、footer 提示（`? for shortcuts`、`⏵⏵ bypass permissions`、`-- INSERT --`、單獨的 `❯`）、狀態列（多個 ` · `/` │ ` 分隔欄位）與 spinner 行。自訂狀態列是一整個**區塊**，改用錨點裁切：底部附近的整寬分隔線，且其下方有可辨識的裝飾行。出現在 transcript 中段的分隔線不受影響。
- **眾數 dedent。** 這一步是關鍵：`translate` 的 bitext 只要區塊縮排 ≥ base + 2 就判定為 *code*，而 agent pane 會把正文整體推到一個固定左邊界。base 取的是**眾數**縮排而非最小值——transcript 會把 turn 標記放在第 0 欄、正文放在第 5 欄，用 `min()` 等於完全沒 dedent，整頁都會原封不動地回來。眾數縮排是這個 pane 的主要文字欄位，所以正文會落到 0，而真正巢狀的程式碼區塊保留相對縮排、仍然被判為 code。
- 折疊的 transcript 標記（`… +194 lines (ctrl + t to view transcript)`）換成單一 `[…]`；連續空行收斂；tab 展開。

不花任何 LLM 呼叫就能檢查上述行為：

```bash
~/.config/herdr/pane-translate.sh recent:500 "$HERDR_PANE_ID" --dry-run
```

它會把清理、修補後的擷取內容印到 stdout，並把 `raw_lines=… out_chars=… trimmed=…` 印到 stderr。

### 為什麼 `prefix+t` 是 popup、而範圍變體是 Quick Action

和 [`prefix + E`](#run-any-command) 是同一個分工：Quick Actions 透過 `sh -c` 執行、**沒有 PTY/stdin**，因此無法自己承載 pager——它們改成先擷取，再 `herdr pane split` 開一個真正的 pane 並在裡面重新執行 helper（`pane split` 沒有 `--focus` 參數，所以由共用的 `focus-pane.py` 負責 focus）。直接鍵不需要繞這一圈，而 popup 浮在版面之上，這一點在這裡比其他功能更重要：`type = "pane"` 的分割會壓窄來源 pane、讓它重新換行，正好毀掉剛剛讀到的那一頁。因此擷取**一律在分割之前**完成。

用小寫 `t`，因為 `prefix + T` 已經是 `herdr-sesh` session 選擇器。

環境變數：`HERDR_TRANSLATE_MAX_CHARS`（12000）、`HERDR_TRANSLATE_TO`（預設目標語言；未設定時由 `translate` 自己的 `[general]` 設定決定）、`HERDR_RUN_HOLD`（`fail`|`always`|`never`，與 `prefix+E` 相同）、`PAGER`。

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
