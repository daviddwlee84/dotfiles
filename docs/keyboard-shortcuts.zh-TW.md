# Keyboard Shortcuts

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

tmux、zsh ZLE widgets、與 fzf 所有自訂鍵位 (custom keybindings) 的快速參考。

深入閱讀：[tmux keybindings](tools/tmux/keybindings.md) · [tmux themes](tools/tmux/themes.md) · [fzf](tools/fzf.md) · [tv](tools/tv.md) · [tv vs fzf](tools/tv-vs-fzf.md)

---

## Unix Shell（Readline / Zsh ZLE）

以下鍵位在任何 bash / zsh 提示字元 (prompt) 都能用（以及大多數內嵌 readline 的 Unix CLI 應用程式）。

### 游標移動

| Binding | 動作 |
|---------|--------|
| `Ctrl+A` | 行首 |
| `Ctrl+E` | 行尾 |
| `Alt+F` | 往前一個 word |
| `Alt+B` | 往後一個 word |
| `Ctrl+F` | 往前一個字元 |
| `Ctrl+B` | 往後一個字元 |
| `Ctrl+XX` | 在目前位置與行首之間切換 |

### 編輯 / 刪除

| Binding | 動作 |
|---------|--------|
| `Ctrl+W` | 往後刪除一個 word（直到前一個空白） |
| `Alt+D` | 往前刪除一個 word |
| `Ctrl+K` | Kill（剪下）從游標到行尾 |
| `Ctrl+U` | Kill 從游標到行首 |
| `Ctrl+Y` | Yank（貼上）最後 kill 的內容 |
| `Alt+Y` | 旋轉 kill-ring 並 yank 上一筆 kill |
| `Ctrl+D` | 刪除游標下的字元（若 line 為空則 EOF） |
| `Ctrl+H` | 刪除游標前的字元（同 Backspace） |
| `Ctrl+T` | 交換游標前後的字元 |
| `Alt+T` | 交換游標前後的 word *(zsh：被 tools-picker 覆寫)* |
| `Alt+U` | 把游標起算的 word 轉大寫 |
| `Alt+L` | 把游標起算的 word 轉小寫 |
| `Alt+C` | 把游標起算的 word 首字母大寫 *(zsh：被 fzf cd 覆寫)* |

### 歷史

| Binding | 動作 |
|---------|--------|
| `Ctrl+R` | 反向遞增搜尋 (reverse incremental search) *(zsh：開啟 fzf history picker)* |
| `Ctrl+S` | 正向遞增搜尋 *(可能被終端機流量控制 (flow control) 攔截)* |
| `Ctrl+P` | 上一個指令（同上箭頭） |
| `Ctrl+N` | 下一個指令（同下箭頭） |
| `Alt+.` | 插入上一個指令的最後一個參數（重複以循環） |
| `!!` | 展開為上一個指令 |
| `!$` | 展開為上一個指令的最後一個參數 |

### 行程控制 (Process Control)

| Binding | 動作 |
|---------|--------|
| `Ctrl+C` | 送出 SIGINT——中斷 / 取消目前行程 |
| `Ctrl+Z` | 送出 SIGTSTP——暫停行程（用 `fg` 恢復） |
| `Ctrl+D` | 送出 EOF——離開 shell 或結束輸入串流 |
| `Ctrl+L` | 清空螢幕（保留目前 line） |
| `Ctrl+S` | 暫停終端機輸出（XOFF） |
| `Ctrl+Q` | 恢復終端機輸出（XON） |

> 此設定下的 **zsh 覆寫**：`Ctrl+R` → fzf history、`Ctrl+T` → fzf file picker、`Alt+C` → fzf cd、`Alt+T` → tools-picker、`Alt+S` → sesh-sessions。Readline 的預設值會被這些 ZLE widget 遮蔽。

---

## tmux

Prefix key：`Ctrl+B`

### Pane 與 Window

| Binding | 動作 |
|---------|--------|
| `Ctrl+1..9` | 切換到 window 1–9 *(無 prefix，需要 CSI-u 終端機)* |
| `Ctrl+0` | 透過 sesh 跳到 git root session *(無 prefix，CSI-u)* |
| `Ctrl+h/j/k/l` | 在 pane **與** Neovim split 之間無縫移動 |
| `prefix + h/j/k/l` | 切換 pane（vim 風 fallback） |
| `prefix + H/J/K/L` | 調整 pane 大小（5 cells） |
| `prefix + M-h/j/k/l` | 微調 pane 大小（1 cell） |
| `prefix + \|` | 左右切割 |
| `prefix + -` | 上下切割 |
| `prefix + +` | 把 pane 設為 75% 寬 |
| `prefix + z` | Zoom / unzoom pane |
| `prefix + x` | Kill pane |
| `prefix + c` | 新 window |
| `prefix + X` | Kill session（須確認） |
| `prefix + N` | 新 session（會詢問名稱） |

### Copy Mode  *(用 `prefix + [` 進入)*

| Key | 動作 |
|-----|--------|
| `v` / `V` | 開始字元 / 行選取 |
| `C-v` | 矩形選取 (rectangle selection) |
| `y` | Yank 到 clipboard |
| `/` / `?` | 往前 / 往後搜尋 |
| `g` / `G` | 跳到頂部 / 底部 |
| `C-u` / `C-d` | 半頁向上 / 向下 |
| `q` | 離開 copy mode |

### Clipboard 輔助

| Binding | 動作 |
|---------|--------|
| `prefix + y` | 複製可見的 pane 到 clipboard |
| `prefix + Y` | 複製整個 scrollback 到 clipboard |
| `prefix + C-y` | 從 scrollback 用 fzf 選一行 |

### URL 與 Session

| Binding | 動作 |
|---------|--------|
| `prefix + u` | fzf URL picker（tmux-fzf-url） |
| `prefix + g` | Sesh session picker（fzf popup） |
| `prefix + T` | 透過 tv 的 Sesh picker（television popup） |
| `prefix + O` | Sesh 內建 picker popup |
| `prefix + W` | Sesh window picker（fzf） |
| `prefix + S` | 切換到上一個 session |
| `prefix + 9` | 跳到 git root session |
| `prefix + U` | CLI tools picker（tv tools popup） |

### 主題與設定

| Binding | 動作 |
|---------|--------|
| `prefix + M-c` | 切換到 Catppuccin 主題（status bar 在上方） |
| `prefix + M-t` | 切換到 tmux2k 主題（status bar 在下方） |
| `prefix + R` | 重新載入 tmux 設定 |

### Popup Menu  *(`prefix + Space`)*

由腳本 (`~/.config/tmux/menu.sh`) 驅動，會根據高度自適應 (height-aware)，並有子選單 (submenu)。頂層 menu 的加速字母 (accelerator letter) 對應到上方獨立 binding。

| Key | 動作 |
|-----|--------|
| `Tab` / `P` | 上一個 window / 上一個 pane |
| `w` / `s` | 選擇 window / session 樹 |
| `q` | 顯示 pane 編號 |
| `g` / `G` | Sesh picker / Lazygit popup |
| `c` / `\|` / `-` / `z` | 新 window / split / split / zoom（高度 ≥ 22） |
| `→ Layouts (L)` | 子選單：even/main/tiled、pane 切換、swap |
| `→ Session (S)` | 子選單：rename / new / move / break / link / kill |
| `→ Sesh+ (E)` | 子選單：TV / built-in / windows / last / root / CLI tools |
| `→ Popups (o)` | 子選單：Lazygit / Shell / Floax |
| `→ Theme (T)` | 子選單：Catppuccin / tmux2k |
| `→ System (Y)` | 子選單：reload / TPM install/update / detach / clock |
| `?` / `/` | Cheatsheet（glow） / tmux-fzf 鍵位 picker |

> `Ctrl+Space` 刻意未綁定——保留給輸入法 (input method) 切換。

---

## Zsh ZLE Widgets

互動式 picker，會在 shell 提示字元打開、不必離開目前 line。

| Binding | Widget | 行為 |
|---------|--------|----------|
| `Alt+T` | `tools-picker` | CLI 工具清單；**Enter** 把指令貼到 buffer，**Ctrl+E** 直接執行 |
| `Alt+S` | `sesh-sessions` | Sesh session 切換（同 `prefix + g` 但是在 shell 內） |
| `Alt+C` | fzf cd | 模糊比對 (fuzzy) `cd` 到目錄（內建 fzf） |
| `Ctrl+T` | fzf file | 在游標處插入模糊比對的檔案路徑 |
| `Ctrl+R` | fzf history | 模糊搜尋 shell history |

### `tools-picker`（Alt+T）內部

| Key | 動作 |
|-----|--------|
| `Enter` | 把指令貼到 buffer（安全——按下一次 Enter 才會執行） |
| `Ctrl+E` | 直接執行工具（給安全的 TUI 工具用：`btop`、`lazygit` 等） |
| `Ctrl+/` | 切換 preview（tldr 或 `--help`） |

### `sesh-sessions`（Alt+S）內部

| Key | 動作 |
|-----|--------|
| `Ctrl+A/T/G/X/F` | 過濾：all / tmux / configured / zoxide / find |
| `Ctrl+D` | Kill 選中的 tmux session |

---

## tv (Television)

| 指令 | Binding | 動作 |
|---------|---------|--------|
| `tv tools` | `prefix + U`（tmux） | CLI 工具 picker；Enter 執行，preview 顯示 tldr |
| `tv sesh` | `prefix + T`（tmux） | Sesh session picker；Enter 連線 |
| `tv git-ops` | `Alt+I`（zsh） | VSCode/GitLens Git command palette；Enter 貼到 prompt，`Ctrl+Y` 複製，`Alt+E` 確認並執行 |
| `tv aliases` | `Alt+A`（zsh） | 所有執行期 (runtime) alias 與 function |
| `tv files` | `Alt+P`（zsh） | 檔案 / 路徑 picker |
| `tv git-log` | `Alt+G`（zsh） | Git log 瀏覽器 |
| `tv env` | `Alt+E`（zsh） | 環境變數 |
| `tv` shell history | `Alt+R`（zsh） | tv 風格的 history 搜尋（補充 `Ctrl+R` 的 fzf） |

### 任何 tv picker 內部

| Key | 動作 |
|-----|--------|
| `Tab` / `Shift+Tab` | 切換結果 |
| `Ctrl+P` / `Ctrl+N` | 上 / 下移動 |
| `Ctrl+D` | Kill session *(只在 sesh channel 有效)* |

---

## Zellij

預設模式為 **locked**——所有按鍵都會 pass through 到內層應用程式。

| Binding | 動作 |
|---------|--------|
| `Ctrl+G` | 解鎖 Zellij command 模式 |

> 第一次啟動時，選擇 **"Unlock-First (non-colliding)"** preset 以避免與 Neovim 與 coding agent 衝突。

---

## macOS 注意事項

- `M-` binding（例：`M-c`、`M-t`、`Alt+T`）需要終端機把 **Option 當成 Meta / Esc+** 送出。
  - **Ghostty** / **cmux**：`macos-option-as-alt = left`（在 `dot_config/ghostty/config` 中管理）
  - **iTerm2**：Preferences → Profiles → Keys → Left Option：`Esc+`
- `Ctrl+1..9` 與 `Ctrl+0` 需要 **CSI-u** 終端機支援（Ghostty、cmux、Alacritty、Kitty）。
