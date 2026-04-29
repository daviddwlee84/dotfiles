# tmux × Vim / Neovim

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

## Vi 風格複製 / 捲動 — 已啟用

當前設定有 `mode-keys vi`，所以捲動與複製模式 (copy mode) 開箱即可享有 vim 風格行為：

| 鍵 | 動作 |
|-----|--------|
| `prefix + [` | 進入複製模式 |
| `h/j/k/l` | 移動游標 |
| `C-u` / `C-d` | 半頁向上/向下 |
| `g` / `G` | 頂端 / 底端 |
| `/` / `?` | 向前 / 向後搜尋 |
| `v` / `V` / `C-v` | 字元 / 行 / 矩形選取 |
| `y` | Yank 到系統剪貼簿（OSC 52）|
| `q` 或 `Escape` | 退出 |

完整表格詳見 [keybindings.md → 複製模式](./keybindings.md#copy-mode-vim-style)。

## `common.conf` 中已設好的 Neovim 友善設定

- `escape-time 0` — 無 ESC 延遲，Neovim 反應靈敏。
- `focus-events on` — Vim 的 `autoread` 與 Neovim 的 `FocusGained` / `FocusLost` 能正確觸發。
- `default-terminal tmux-256color` + `terminal-features ...:RGB` — tmux 內提供真彩色 (true color)。
- `extended-keys always` + `extended-keys-format csi-u` — `Ctrl+/`、`Shift+Enter`、`Ctrl+Enter` 等鍵位能透過 tmux 抵達 Neovim。
- `set-clipboard on` — 在複製模式中的 OSC 52 yanks 在 SSH 下也能運作。
- `allow-passthrough on` — 有助於終端機 (terminal) 影像協定 (protocol) 與類似的 passthrough 功能。

如果 `prefix + R` 後 `Ctrl+/` 仍無作用，請重啟終端機 app 或執行一次 `tmux kill-server`，讓終端機 capability 協商重新進行。受管理的 Alacritty 設定會將 `Ctrl+/` 送出為 `\u001f`，這對應 LazyVim 內建的 `<C-_>` 終端機切換備援。

## vim-tmux-navigator

[`christoomey/vim-tmux-navigator`](https://github.com/christoomey/vim-tmux-navigator) 已安裝。免 prefix 的 `Ctrl+h/j/k/l` 可在窗格 (pane) 之間移動，透明地跨越 tmux 窗格邊界與 Neovim splits：

| 鍵 | 動作 |
|-----|--------|
| `Ctrl+h` | 聚焦左方（tmux 窗格或 vim split）|
| `Ctrl+j` | 聚焦下方 |
| `Ctrl+k` | 聚焦上方 |
| `Ctrl+l` | 聚焦右方 |
| `Ctrl+\` | 聚焦上一個（最近造訪）|

Neovim 端 spec 位於 [`dot_config/nvim/lua/exact_plugins/vim-tmux-navigator.lua`](../../../dot_config/nvim/lua/exact_plugins/vim-tmux-navigator.lua)；對應 tmux 端的 `is_vim` 綁定位於 [`dot_config/tmux/keybindings.conf`](../../../dot_config/tmux/keybindings.conf)。既有的 `prefix + h/j/k/l` 綁定保留作為備援 — 沒有被移除任何東西。

### 注意事項

- `Ctrl+h` 在某些終端機歷史上是 Backspace。若此後 Neovim 中的 `<BS>` 異常，請在 Neovim insert 模式中重新對映 `<C-h>`，或將終端機鍵盤 protocol 更新為 csi-u（在我們 tmux 設定中已透過 `extended-keys-format csi-u` 啟用）。
- `Ctrl+\` 可能與其他 app 衝突（例如某些除錯器將其作為訊號）。請避免在那些 app 內按下。
- 如果你執行巢狀 tmux session，外層 tmux 會吃掉 Ctrl+h/j/k/l，它們不會抵達 Neovim。在巢狀 sessions 中請使用 `prefix + h/j/k/l`。

## 資源

- [rothgar/awesome-tmux](https://github.com/rothgar/awesome-tmux) — 精選 tmux 外掛 (plugin)、主題 (theme) 與文章列表。
- [Tmux and Vim — even better together (SmartBear)](https://smartbear.com/blog/tmux-and-vim/) — 將 tmux 與 Vim/Neovim 配對的工作流模式。
- [omerxx/dotfiles — tmux/](https://github.com/omerxx/dotfiles/tree/master/tmux) — 含 Catppuccin + 頂部狀態列 (status bar) 的參考 config（見[影片解說](https://www.youtube.com/watch?v=GH3kpsbbERo)）。
