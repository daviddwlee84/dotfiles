# tmux — 鍵位綁定 (Keybindings)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

所有綁定皆使用預設 prefix `Ctrl + b`。

## 日常工作流

| 鍵位 | 動作 |
|------------|--------|
| `prefix + R` | 重新載入 `~/.tmux.conf` |
| `prefix + Space` | 開啟 tmux 彈出選單 (popup menu)（記憶法："menu"）|
| `prefix + g` | 開啟 sesh picker |
| `prefix + T` | 透過 television (tv) 開啟 sesh picker |
| `prefix + O` | 開啟 sesh 內建 picker |
| `prefix + S` | 跳到上一個 sesh session（若無則於狀態列 (status bar) 顯示訊息）|
| `prefix + 9` | 為當前目錄開啟 `scode`（repo 感知的 coding-agent 佈局 — nvim 75% \| agent 25% + btop 監控；具備 idempotent，若已建立則切換到既有 session）|
| `prefix + 0` | 在當前目錄的 git root 建立輕量 sesh session（無 nvim/agent 佈局 — 與 `prefix + 9` 對稱的版本）|
| `prefix + N` | 新建 session（提示輸入名稱）|
| `prefix + X` | 終止 session（需確認）|
| `prefix + W` | 終止視窗 (window)（需確認）|
| `prefix + r` | 重新編號視窗（補上被終止視窗留下的索引空缺）|
| `prefix + M` | 將當前視窗移動到另一個 session（提示輸入 `session[:index]`）|
| `prefix + B` | 將當前窗格 (pane) 拆成新視窗並移動到某個 session（tab tear-out）|
| `prefix + A` | 將當前視窗連結 (link) 到另一個 session（同一視窗會出現在兩處）|
| `prefix + E` | Explode — 把當前視窗的每個窗格拆成各自的視窗（同一 session）。適用於從寬螢幕多窗格切換到行動裝置/SSH 單窗格 |
| `prefix + d` | Detach |
| `prefix + t` | 顯示 tmux 時鐘模式 |
| `prefix + M-c` | 切換主題 (theme) 為 Catppuccin（頂部狀態列）|
| `prefix + M-t` | 切換主題為 tmux2k（底部狀態列）|

## 窗格與視窗

| 鍵位 | 動作 |
|------------|--------|
| `Ctrl + 1..9` | 切換到視窗 1–9（需要 CSI-u 終端機 (terminal)：Ghostty、Alacritty、Kitty）|
| `Ctrl + 0` | 為當前窗格在 repo root 建立輕量 sesh session（對應 `prefix + 0`）|
| `Ctrl + h/j/k/l` | 在窗格之間移動 — 可跨入 Neovim splits（vim-tmux-navigator）* |
| `Ctrl + \` | 聚焦上一個 pane/split（vim-tmux-navigator）* |
| `prefix + h/j/k/l` | 在窗格之間移動（備援，僅 tmux）|
| `prefix + H/J/K/L` | 調整窗格大小（5 cells，可重複）|
| `prefix + M-h/j/k/l` | 微調窗格大小（1 cell，可重複）|
| `prefix + +` | 將當前窗格設為 75% 寬度 |
| `prefix + \|` | 左右分頁 (split)（垂直分隔線）|

\* `Ctrl + h/j/k/l` 與 `Ctrl + \` (vim-tmux-navigator) 受 chezmoi
`enableVimMode` prompt 控制（預設 `true`）。設為 `false` 時，這些
綁定整段省略 —— `Ctrl+L` 會傳至內層 shell 清螢幕、`Ctrl+H` 為
backspace 等。改用 `prefix + h/j/k/l`（永遠保留）或 `prefix + Arrow`
進行 pane 導覽。詳見
[`docs/this_repo/vim-mode.md`](../../this_repo/vim-mode.md)。
| `prefix + -` | 上下分頁（水平分隔線）|
| `prefix + c` | 在當前路徑開新視窗 |
| `prefix + x` | 終止窗格（需確認）|
| `prefix + W` | 終止視窗（需確認）|
| `prefix + r` | 手動重新編號視窗（補上索引空缺）|
| `prefix + z` | 切換窗格縮放 |
| `prefix + {` | 與前一個窗格交換（左/上）|
| `prefix + }` | 與下一個窗格交換（右/下）|
| `prefix + m` | **標記**當前窗格（內建；全域僅一個標記；選單中的 Join 需要它）|
| `prefix + !` | 將當前窗格拆成同一 session 內的新視窗（內建）|
| `prefix + [` | 進入複製模式 (copy mode) |

`Ctrl+1..9` 與 `Ctrl+0` 需要終端機支援 CSI-u。Ghostty/cmux 原生送出。Alacritty 需明確的 `keyboard.bindings`（由本 repo 在 `dot_config/alacritty/alacritty.toml` 中管理）。傳統終端機（Terminal.app、純 SSH）無法送出這些 — 請改用 `prefix + number`。

Swap-pane 會交換**內容**但保留**大小**。所以如果你有 75%/25% 分頁並交換，左窗格的內容會移到右側（25%），反之亦然 — 比例維持固定。

## 佈局 (Layouts)

| 鍵位 | 動作 |
|------------|--------|
| `M-1` | Even horizontal 佈局 |
| `M-2` | Even vertical 佈局 |
| `M-3` | Main horizontal 佈局 |
| `M-4` | Main vertical 佈局 |
| `M-5` | Tiled 佈局 |
| `prefix + E` | 平均分散窗格（內建）|

`M-1` 至 `M-5` 是 tmux 內建鍵位 — 不需 prefix；只要按住 Meta（Alt/Option）並按下數字。

> **macOS 終端機需求**：Option 必須送出 Meta/Esc+，`M-` 綁定才會生效。Ghostty/cmux：`macos-option-as-alt = left`（由本 repo 在 `dot_config/ghostty/config` 中管理）。Alacritty：`window.option_as_alt: OnlyLeft`。iTerm2：Profiles > Keys > Left Option Key > Esc+。詳見 [docs/tools/ghostty.md](../ghostty.md)。

## 浮動窗格 (tmux-floax)

| 鍵位 | 動作 |
|------------|--------|
| `prefix + F` | 切換浮動窗格（80% 寬高，**持久** `float` session）|
| `prefix + P` | 開啟 floax 彈出選單 |
| `prefix + \`` | 在當前窗格路徑開啟一次性的**彈出 shell**（每次開啟皆為全新 shell，遇到 `exit`/Ctrl-D 即退出）|

兩種彈出 shell，依使用情境挑選：

- **`prefix + \``** — 用完即丟。執行一個 `curl`、檢查 `df -h`、瞄一眼某個檔案，然後退出。每次開啟都是乾淨的 shell。跨開啟之間沒有歷史。適合「我只想在不離開窗格佈局的情況下打一條命令」。
- **`prefix + F`（floax）** — 暫存區。`float` session 會持久存在，所以當你重新切換彈出視窗時，先前的 shell 歷史、環境，甚至執行中的 process 都還在。適合「我正在迭代某個東西，不想失去上下文」。

## 一次性彈出視窗

這些會在 `#{pane_current_path}` 開啟 `display-popup -E`；內部命令退出時彈出視窗即關閉。與 floax 不同，沒有 session 持久存在。

| 鍵位 | 動作 |
|------------|--------|
| `prefix + G` | [`lazygit`](https://github.com/jesseduffield/lazygit) 彈出視窗 |
| `prefix + T` | sesh picker（television）|
| `prefix + O` | sesh 內建 picker |
| `prefix + U` | CLI 工具 picker (`tv tools`) |
| `prefix + u` | URL picker（tmux-fzf-url）|
| `prefix + a` | 即時 coding-agent 窗格 picker (`tv agent-panes`) — 詳見 [agent pane discovery](../agent-panes-discovery.md) |

何時用哪一個：

- **floax (`prefix + F`)** — 重複快速使用的 shell，需要保留歷史（筆記、暫時計算、長時間執行的 curl）。
- **`prefix + \`` 彈出 shell** — 在全新 shell 中執行一條快速命令，退出即忘。
- **一次性工具彈出視窗 (`G`/...)** — 啟動 TUI 工具、做事、乾淨退出。

## 說明 / 探索（不必再硬背）

內建的 `prefix + ?`（一大堆 `list-keys -N` 列印）已被 [tmux-fzf](https://github.com/sainnhe/tmux-fzf) 取代：fzf 彈出視窗列出**每一個**綁定（包含使用者自訂），完全可模糊搜尋。

| 鍵位 | 動作 |
|------------|--------|
| `prefix + ?` | tmux-fzf：頂層模糊 picker（keybindings / sessions / windows / panes / commands / processes / clipboard）|
| `prefix + C-?` | 純 `list-keys -N`（若 tmux-fzf 缺失時的備援）|
| `prefix + /` | 內建：提示輸入按鍵，顯示其綁定（單鍵查詢）|
| `prefix + Space` 然後 `?` | 用 [`glow`](https://github.com/charmbracelet/glow) 渲染的精選速查表（來源：`dot_config/tmux/cheatsheet.md`）|
| `prefix + Space` 然後 `/` | 直接開啟 tmux-fzf **keybinding** picker（跳過分類選單）|

「我忘了那個鍵」的三層復原：

1. **精選** (`prefix + Space`)：分組彈出選單，含高頻頂層列與子選單。
2. **可搜尋** (`prefix + ?` → tmux-fzf)：對完整綁定清單進行模糊搜尋。
3. **參考** (`prefix + Space` → `?`)：以 glow 渲染的 markdown 速查表（本檔案旁的 `cheatsheet.md`），適合學習時瀏覽。

為何要三層？彈出選單在你大致知道想要什麼時最快；tmux-fzf 適用於「我知道某處有」；速查表適用於「到底有哪些可能？」。依當下的不確定程度挑選即可。

## 複製模式 (Vim 風格)

以 `prefix + [` 進入。用 vim 鍵位導航，然後：

| 鍵 | 動作 |
|-----|--------|
| `v` | 開始字元選取（visual 模式）|
| `V` | 選取整行 |
| `C-v` | 切換矩形/區塊選取 |
| `y` | 將選取內容 yank 到系統剪貼簿 |
| `/` | 向前搜尋 |
| `?` | 向後搜尋 |
| `n`/`N` | 下一個/上一個搜尋結果 |
| `g`/`G` | 跳到頂端/底端 |
| `C-u`/`C-d` | 半頁向上/向下 |
| `{` / `}` | 跳到上一個 / 下一個 prompt（需要 OSC 133 — 詳見 [OSC 133](./README.md#osc-133-command-boundary-navigation-warp-style)）|
| `M-[` / `M-]` | 跳到上一個 / 下一個命令 **output** 起始（需要 OSC 133）|
| `q` 或 `Escape` | 退出複製模式 |

在複製模式中拖曳滑鼠也會複製到剪貼簿。雙擊選取一個單字。

命令邊界鍵 (`{` `}` `M-[` `M-]`) 倚賴 `dot_config/zsh/tools/02_shell_integration.zsh` 發送的 OSC 133 標記。在執行非 zsh shell，或透過 `DISABLE_OSC133=1` 退出的窗格中，這些是靜默的 no-ops。

## 右鍵選單

右鍵會依點擊位置開啟對應的 context 選單：

| 目標 | 選單項目 |
|--------|------------|
| 窗格主體 (`MouseDown3Pane`) | Split h/v、swap up/down/left/right、zoom、resize 75% / even、mark、swap marked、**join marked here (h/v)**、**send pane to window…**、**break to new window**、copy mode、respawn、kill |
| 視窗清單 (`MouseDown3Status`) | Swap left/right、move/link to session、**merge into other window as pane (h/v)**、**even layout (horizontal / vertical / tiled)**、kill window、**renumber windows**、rename、new window |
| 左側 session 區 (`MouseDown3StatusLeft`) | Next/prev/choose/rename session、move current window、new session/window、kill session / kill-and-exit / kill-all-sessions |

我們的綁定使用 `display-menu -O`，所以滑鼠按鈕釋放後選單仍保持開啟 — 選一個項目或按 Escape 取消。（tmux 預設沒有 `-O`，按鈕釋放即關閉，這會讓選單無法使用。）

在 break / send / merge / join 後，狀態列會顯示訊息描述發生的事（例如 `Broke pane out to window 4 (zsh)`、`Merged into 1`）。

## 開啟 URL

| 鍵位 | 動作 |
|------------|--------|
| `prefix + u` | 開啟 fzf 彈出視窗，列出窗格中所有 URL（tmux-fzf-url）|

在複製模式中（用 `v` 選取文字後）：

| 鍵 | 動作 |
|-----|--------|
| `o` | 在預設瀏覽器/應用程式中開啟選取的 URL/檔案（tmux-open）|
| `C-o` | 在 `$EDITOR` 中開啟選取內容 |
| `S` | 用 Google 搜尋選取內容（tmux-open，可透過 `@open-S` 設定）|

典型工作流：`prefix + u` 快速瀏覽 URL；`prefix + [` 然後選取 + `o` 精準開啟 URL。

## 擷取窗格

| 鍵位 | 動作 |
|------------|--------|
| `prefix + y` | 將窗格可見內容複製到系統剪貼簿 |
| `prefix + Y` | 將完整捲動歷史 (scrollback) 複製到系統剪貼簿 |
| `prefix + C-y` | 在 fzf 中開啟捲動歷史，選取要複製的行（Tab=多選）|
| `prefix + M-y` | 將**最後一條命令的輸出**複製到剪貼簿（Warp 風格，需要 OSC 133 — 詳見 [OSC 133](./README.md#osc-133-command-boundary-navigation-warp-style)）|
| `prefix + M-i` | 將**最後一條命令的輸入行**（prompt + 輸入的命令）複製到剪貼簿（需要 OSC 133）|

跨平台：macOS 用 `pbcopy`、Linux 用 `xclip`/`xsel`。OSC 52 對 vim 風格的 `y` yank 也有效（即使透過 SSH）。

## 跨 sessions 移動視窗 / 窗格

像把瀏覽器分頁拖到新視窗一樣 — 但 tmux 可在三種不同粒度下做到（整個視窗、窗格 → 新視窗、窗格 → 既有視窗作為分頁）。所有跨 session/跨視窗目標皆從 `choose-tree` picker 中挑選（即時預覽、模糊搜尋），而非在 prompt 中輸入。為何如此設計，詳見下方[picker 優先於 prompt 的設計規則](#design-note-pickers-over-prompts)。

### 視窗層級（整個分頁）

| 鍵 | 底層命令 | 效果 |
|-----|-------------------|--------|
| `prefix + M` | `choose-tree -Zs … move-window -s '#{window_id}' -t '%%'` | 從這個 session 中**剪下**當前視窗，**貼上**到目標（session picker）|
| `prefix + A` | `choose-tree -Zs … link-window -s '#{window_id}' -t '%%:'` | **連結**（不是複製）：同一視窗出現在兩個 sessions 中；編輯保持同步。`unlink-window` 移除其中一邊但不會終止 |
| `prefix + W` | `kill-window` | 終止當前視窗（需確認）|
| `prefix + r` | `move-window -r` | 重新編號當前 session 中的視窗 — 補上索引空缺。`renumber-windows on`（在 `common.conf` 中設定）會在整個視窗被銷毀時自動重新編號，但對多窗格視窗執行 kill-pane 或 shell 驅動的退出仍可能留下空缺；此綁定是手動補強。|

### 窗格 → 新視窗

| 鍵 | 底層命令 | 效果 |
|-----|-------------------|--------|
| `prefix + !` | `break-pane`（內建）| 將當前窗格拆成**同一** session 中的新視窗 |
| `prefix + B` | `choose-tree -Zs … break-pane -s '#{pane_id}' -t '%%'` | 一步完成拆分 + 移動到所選 session（tab tear-out，session picker）|
| `prefix + E` | `~/.config/tmux/break-all-panes.sh` | **Explode** — 將當前視窗中每個窗格拆成各自的視窗（同一 session）。來源視窗保留第一個窗格；其餘成為兄弟視窗，按各窗格目前命令命名，並插入在來源視窗右側。使用情境：在行動裝置/SSH 上將寬螢幕多窗格佈局延續為一窗格一視窗，比起用 `prefix + z` 縮放更容易。也可透過右鍵視窗選單 → "Break all panes → windows" 取得。|
| 右鍵窗格 → "Break to new window" | `break-pane` | 與 `prefix + !` 相同，但會在狀態列回報新視窗的索引 |

### 窗格 → 既有視窗（作為分頁）

這些都使用 tmux 的 `join-pane`，會在視窗之間移動窗格。`join-pane` 永遠針對單一**窗格**操作，而非整個視窗 — 沒有「整批合併兩個視窗」的命令。兩步驟的「mark + join」是標準工作流：

1. 前往**來源**窗格（你想移動的那個）。
2. 按 `prefix + m` 來**標記**它。tmux 全域只記住一個被標記的窗格；被標記的窗格會有彩色邊框。
3. 切換到**目標**視窗。
4. 對任意窗格按右鍵 → "Join marked pane here (h-split)" 或 "(v-split)"。被標記的窗格就會跳過來成為一個分頁。

進入同一個 `join-pane` 命令的替代入口：

| 來源 | 動作 | 效果 |
|------|--------|--------|
| 右鍵窗格 → "Join marked pane here (h/v-split)" | `join-pane -h` / `-v` | 將被標記的窗格拉進這個視窗作為分頁 |
| 右鍵窗格 → "Send pane to window…" | `choose-tree -Zw … join-pane -h -s '#{pane_id}' -t '%%'` | 將**這個**窗格推到另一個視窗作為分頁（不需標記；從視窗樹 picker 中選擇目標）|
| 右鍵視窗分頁 → "Merge into other window (as pane, h/v-split)" | `choose-tree -Zw … join-pane -h -s '#{window_id}' -t '%%'` | 將此視窗的**作用中窗格**移到另一個視窗作為分頁。若來源視窗只有一個窗格，它會消失（等同於合併整個視窗）。當有多個窗格時，僅作用中那個會移動。 |
| 彈出選單 → Session → "Join marked here (h/v)" / "Send pane to…" | 同右鍵 | 相同動作，鍵盤驅動 |

> **為何沒有頂層 `prefix +` 鍵綁定 join-pane / send-pane？** 所有單字母大寫位置都已被佔用（`H/J/K/L` = resize、`S` = sesh-last、`W` = kill-window、`M/N/B/A` = window 操作）。與其重新綁定別的鍵，這些功能放在右鍵選單與彈出選單的 Session 子選單中。mark-and-join 工作流本來就比較適合滑鼠操作。

提示：`prefix + s`（內建 choose-tree）會顯示即時預覽 — 在 invoke `M`/`B`/`A` 之前預覽 sessions 很方便，雖然這些綁定現在會開啟自己的 picker，所以獨立預覽主要用於隨意瀏覽。

### 設計筆記：picker 優先於 prompt

本 repo 中所有跨視窗/跨 session 的綁定皆使用 `choose-tree -Zw`（視窗 picker）或 `-Zs`（session picker），而非 `command-prompt`。兩個原因：

1. **對 `target-pane` 命令的正確性**。tmux 的 `join-pane`、`swap-pane`、`move-pane` 將 `-t TARGET` 解析為一個*窗格* — 純整數 `N` 代表「*當前*視窗中的窗格索引 N」，而非「視窗 N」。使用者輸入 `1` 想要「視窗 1」時會靜默地指向錯誤窗格（通常就是來源窗格本身，產生 `Source and target panes must be different`）。`choose-tree -Zw` 回傳 `session:window`，parser 會無歧義地解析為該視窗的作用中窗格。完整除錯軌跡見 [`pitfalls/tmux-join-pane-numeric-target-pane-not-window.md`](../../../pitfalls/tmux-join-pane-numeric-target-pane-not-window.md)。
2. **使用者體驗**。即時預覽、模糊搜尋、無需記憶 session 名稱，皆勝過自由輸入的 prompt，即使兩者技術上都安全（如 `move-window -t` 接受 session 層級目標而無歧義）。

來源 pane/window 永遠以 `-s '#{pane_id}'` 或 `-s '#{window_id}'` 釘住，而非倚賴「當前窗格 / 當前視窗」 — `#{pane_id}` 在點擊當下對 client 的作用中窗格做解析，這在狀態列選單上可能不是被右鍵點擊的分頁。

當新增針對視窗或 session 的 keybinding/menu row 時：優先使用 `choose-tree -Zw` / `-Zs`；只有在沒有合適 picker 時（自由命名、全新 session 名稱等）才退回 `command-prompt`。

## 仍可使用的 tmux 內建鍵

| 鍵位 | 動作 |
|------------|--------|
| `prefix + s` | 選擇 session 樹 |
| `prefix + w` | 選擇 window 樹 |
| `prefix + q` | 顯示窗格編號 |
| `prefix + ,` | 重新命名視窗 |
| `prefix + $` | 重新命名 session |
| `prefix + ?` | tmux-fzf：模糊搜尋所有 keybindings（從 list-keys 改綁）|
| `prefix + C-?` | 內建 `list-keys -N`（備援）|
| `prefix + /` | 提示輸入按鍵並顯示其綁定 |

## 彈出選單 (`prefix + Space`)

彈出選單綁定於 `prefix + Space`，由**腳本產生** (`~/.config/tmux/menu.sh`)，而非在 `keybindings.conf` 中內嵌定義。兩個原因：

1. **引號處理**。tmux 的 command parser 在 literal `;`、`{`、`}` 處停止解析，即使位於巢狀引號內也是。當約 50 列選單塞滿 fzf 綁定與 shell one-liners 時，`keybindings.conf` 中的逸出 (escaping) 變得脆弱且會靜默壞掉。
2. **依高度裁減**。`display-menu` **不會**分頁。如果選單比終端機高，整個彈出視窗會被抑制且無錯誤。腳本讀取 `#{client_height}` 並輸出三組分層之一，使選單永遠能顯示。

分層：

| 終端機高度 | 頂層選單顯示 |
|-----------------|----------------|
| 任意 (Tier 0)    | Last window/pane、Choose win/sess、Pane #s、Sesh picker、Lazygit（約 9 列）|
| ≥ 14 (Tier 0+2) | + 子選單啟動器 (`→ Layouts/Session/Sesh+/Popups/Theme/System`)、Cheatsheet、Search keys |
| ≥ 22 (Tier 0+1+2) | + New window、Split `\|`/`-`、Zoom |

子選單為獨立腳本 (`menu-layouts.sh`、`menu-session.sh`、`menu-sesh.sh`、`menu-popups.sh`、`menu-theme.sh`、`menu-system.sh`)，從 row 透過 `run-shell` 啟動。每個子選單都是獨立的 `display-menu`，故引號處理 context 會重置。

> **歷史筆記**：早期一輪除錯誤以為 `prefix + Space` 與 `prefix + Enter` 因為 `extended-keys` / `csi-u` keysym 編碼（tmux/tmux#4571、#4147、#4959、#4984）而壞了，於是把選單臨時搬到 `prefix + e`。那個診斷是錯的。實際失敗原因是內嵌的 50 列扁平選單**比終端機高**，而 tmux 依 `man tmux` 所述（"If the menu is too large to fit on the terminal, it is not displayed."）會靜默抑制過大的選單。`Space` 與 `Enter` 都一直可綁定；keysym 故事是 red herring。完整除錯軌跡見 [`pitfalls/tmux-display-menu-silent-fail.md`](../../../pitfalls/tmux-display-menu-silent-fail.md)。選單一度同時綁定到 `Space`（正式）與 `e`（別名）；`e` 別名後來被**移除**，以釋放 `e` 作為子選單記憶法（例如視窗右鍵選單中的 "Even layout: horizontal"）。正式綁定維持在 `prefix + Space`。

### 頂層選單加速鍵

加速鍵盡量對應獨立的 `prefix + key` 綁定 — 在選單中按 `c` 與在選單外按 `prefix + c` 做同樣的事。

| 鍵 | 列 | Tier |
|-----|-----|------|
| `Tab` | Last window | 0 |
| `P` | Last pane | 0 |
| `w` | Choose window tree | 0 |
| `s` | Choose session tree | 0 |
| `q` | Show pane numbers | 0 |
| `g` | Sesh picker | 0 |
| `G` | Lazygit popup | 0 |
| `c` | New window | 1 (h ≥ 22) |
| `\|` | Split left/right | 1 |
| `-` | Split top/bottom | 1 |
| `z` | Zoom toggle | 1 |
| `L` | → Layouts 子選單 | 2 (h ≥ 14) |
| `S` | → Session 子選單 | 2 |
| `E` | → Sesh+ 子選單 | 2 |
| `o` | → Popups 子選單 | 2 |
| `T` | → Theme 子選單 | 2 |
| `Y` | → System 子選單 | 2 |
| `?` | Glow 速查表彈出視窗 | 2 |
| `/` | tmux-fzf keybinding picker | 2 |

### 子選單列

來源真理：`dot_config/tmux/executable_menu-*.sh`。

- **Layouts** (`L`)：Even h/v (`1`/`2`)、Main h/v (`3`/`4`)、Tiled (`5`)、Resize 75% (`+`)、Pane h/j/k/l、Swap `{`/`}`。
- **Session** (`S`)：Rename session/window (`$`/`,`)、New session (`N`)、Move window (`m`)、Break pane (`r`)、Link window (`K`)、Renumber (`R`)、Join marked here h/v (`j`/`J`)、Send pane to (`s`)、Kill pane/window/session/server (`x`/`W`/`X`/`Q`)。
- **Sesh+** (`E`)：TV picker (`V`)、Built-in (`O`)、Last sesh (`U`)、scode here (`9`)、CLI Tools tv (`B`)。
- **Popups** (`o`)：Lazygit (`g`)、Shell (`s`)、Floax scratchpad (`f`)。
- **Theme** (`T`)：Catppuccin (`c`)、tmux2k (`t`)。
- **System** (`Y`)：Reload config (`R`)、Install plugins (`I`)、Update plugins (`U`)、Detach (`d`)、Clock (`k`)。

> **硬性上限**：頂層選單目前在最大高度下為 14 列。新增第 15 列會在較小終端機（手機 SSH、半畫面分割）上開始失敗。請改將較低頻項目放入子選單，並透過垂直縮小終端機重新測試（高度 14 / 22 / 60）。
