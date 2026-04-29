# Neovim 中的浮動 TUI 工具 (Floating TUI Tools)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

提供 TUI 工具的浮動終端視窗 (floating terminal windows)，由 [Snacks.terminal](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md) 驅動（隨 LazyVim 一起捆綁）。

## 運作方式

所有 TUI 的快捷鍵 (keymaps) 都放在 `lua/plugins/floating-tui.lua`。每個工具都是單一個 `Snacks.terminal.toggle(cmd, opts)` 呼叫——不需要自訂的 Lua 模組 (module)。Snacks 會處理：

- 浮動視窗的生命週期 (lifecycle)（建立、顯示、隱藏、調整大小）
- 終端 session 持久化 (persistence)（用 `q` 隱藏、用相同快捷鍵重新開啟）
- 連按兩次 Esc 離開終端的 insert mode
- 程式結束時自動清理

這也是 `<leader>gg`（透過 `Snacks.lazygit()` 啟動 LazyGit）背後的相同機制。

## 預設快捷鍵

| 快捷鍵 | 工具 | 類別 |
|--------|------|----------|
| `<leader>gg` | LazyGit | Git（LazyVim 內建） |
| `<leader>zg` | gh dash | Git / GitHub |
| `<leader>zs` | sqlit | 資料庫 |
| `<leader>fy` | yazi | 檔案管理員 |
| `<leader>zb` | btop | 系統監控 |
| `<leader>zd` | lazydocker | 容器 |
| `<leader>zi` | ipython | REPL |

在浮動 TUI 視窗內：

- **連按兩次 Esc** — 離開終端 insert mode（回到 normal mode）
- **q**（normal mode） — 隱藏視窗，程式持續執行
- **再次按下相同快捷鍵** — 重新開啟已隱藏的視窗

關於 `<leader>zg` 背後託管的 `gh-dash` / `diffnav` / `lazygit` 設定，請見 [Git Diff 工作流程](../tools/git_diff_workflow.md)。

## 新增一個 TUI

在 `lua/plugins/floating-tui.lua` 的 `keys` 表格中加一筆：

```lua
{
  "<leader>zX",
  function()
    Snacks.terminal.toggle("mytool", {
      win = { title = " mytool " },
    })
  end,
  desc = "MyTool",
},
```

### 常見選項

```lua
Snacks.terminal.toggle(cmd, {
  cwd = vim.uv.cwd(),          -- 工作目錄
  cwd = LazyVim.root.git(),    -- 或使用 git 根目錄
  env = { FOO = "bar" },       -- 環境變數
  auto_close = false,           -- 程式結束後保留視窗（適用於短生命週期工具）
  win = {
    title = " tool name ",      -- 浮動視窗標題
    width = 0.9,                -- 0-1 = 比例，>1 = 欄數
    height = 0.9,
    border = "rounded",         -- "rounded", "double", "single", "none"
    position = "float",         -- "float"（cmd 預設）, "bottom", "left", "right"
  },
})
```

### 多字命令

要傳入帶參數的命令時，使用 table：

```lua
Snacks.terminal.toggle({ "gh", "dash" }, { ... })
Snacks.terminal.toggle({ "psql", "postgres://localhost/mydb" }, { ... })
```

### 會快速離開的工具

某些工具（如 `sqlit`）可能會結束並顯示 `[Process exited 0]`。設定 `auto_close = false` 可保留視窗顯示，方便檢查輸出。關閉後下次切換 (toggle) 會建立新的實例 (instance)。

### 具有類 Vim 鍵綁定的工具

把 Esc 用於內部按鍵的工具（例如 sqlit 的 vim mode）能與 Snacks 的 **double-Esc** 計時器良好搭配——單次 Esc 會送到 TUI，在 200ms 內再按一次 Esc 才會離開終端 insert mode。

### 使用 `q` 退出的工具

預設情況下，Snacks 會把 normal mode 中的 `q` 對映到**隱藏**浮動視窗（程式持續執行）。然而某些 TUI 工具（如 `sqlit`）會把 `q` 當成自己的 quit 命令，這會結束程式。

**衝突點：** 若你按 Double-Esc 回到 Neovim 的 normal mode 並按下 `q`，Snacks 會隱藏視窗——但若你還在終端 insert mode 時按 `q`，TUI 會收到該按鍵並可能直接結束程式。

**解法：** 把 Snacks 的隱藏鍵 (hide key) 重新對映到 `<C-q>`，這樣 `q` 永遠不會被 Snacks 攔截：

```lua
Snacks.terminal.toggle("sqlit", {
  win = {
    title = " sqlit ",
    keys = {
      q = false,                              -- 停用預設的 q-to-hide
      hide = { "<C-q>", "hide", mode = "n" }, -- 改用 Ctrl-q 來隱藏
    },
  },
  auto_close = false,
})
```

這類工具的工作流程：

- **連按兩次 Esc** — 離開終端 insert mode
- **Ctrl-q**（normal mode） — 隱藏視窗，程式持續執行
- **相同快捷鍵**（例如 `<leader>zs`） — 重新開啟已隱藏的視窗

這個模式適用於任何 `q` 帶有特殊意義的 TUI 工具（例如資料庫 client、互動式檢視器）。

## 何時改用專用外掛 (Dedicated Plugin)

對大多數 TUI 工具來說，`Snacks.terminal.toggle` 已經足夠。在以下情況才考慮專用外掛：

- **深度 Neovim 整合** — 例如 `Snacks.lazygit()` 會自動設定 colorscheme 主題與 nvim-remote 編輯
- **檔案選擇 callback** — 例如 [yazi.nvim](https://github.com/mikavilpas/yazi.nvim) 可在 Neovim buffer 中開啟所選檔案
- **輸出解析 / RPC** — 需要把結構化資料 (structured data) 送回 Neovim 的工具

| 工具 | 通用 (Snacks) | 專用外掛 |
|------|:-:|:-:|
| lazygit | OK | `Snacks.lazygit()`（內建，推薦） |
| yazi | 瀏覽用 OK | 若需要 file-open callbacks 則用 `yazi.nvim` |
| gh dash | OK | 若每天使用則用 `gh-dash.nvim` |
| btop, htop, k9s 等 | 推薦 | N/A |
