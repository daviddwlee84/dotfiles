# 複製 Cursor 風格的檔案 reference (`@file:line`)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

四個 Neovim 快捷鍵 (keymaps)，把 **Cursor / Claude Code 風格的檔案 reference**
——`@path`、`@path:12` 或 `@path:12-40`——複製到系統剪貼簿 (clipboard)，內容由目前的
buffer 加上游標所在行（normal mode）或選取範圍 (visual selection)（visual mode）組成。
`@` 會觸發 agent 的檔案 mention，`:line[-line]` 則指向確切的程式碼，讓你直接貼上精準的
指標，而不用手動重打路徑與行號。

四個快捷鍵都放在 `lua/config/keymaps.lua`，歸在一個 `<leader>y`（「copy ref」）的
which-key 群組底下。按 `<leader>y`（Space 再按 `y`）即可看到它們。

## 快捷鍵

`<leader>` = Space。每個鍵在 **normal** 與 **visual** mode 都能用。

| 快捷鍵 | 路徑類型 | Normal mode（游標行） | Visual mode（選取範圍） |
|--------|----------|------------------------|--------------------------|
| `<leader>yr` | 專案相對 (project-relative) | `@rel/path:12` | `@rel/path:12-40` |
| `<leader>ya` | 機器絕對 (machine-absolute) | `@/abs/path:12` | `@/abs/path:12-40` |
| `<leader>yf` | 專案相對 | `@rel/path`（無行號） | `@rel/path`（無行號） |
| `<leader>yF` | 機器絕對 | `@/abs/path`（無行號） | `@/abs/path`（無行號） |

助記：`r`elative / `a`bsolute 會帶行號；`f`ile-only（大寫 `F` = 絕對）則是純路徑。
四個合起來涵蓋三種 reference 形態：

- `@file` → `<leader>yf`
- `@file:line` → normal mode 下的 `<leader>yr`
- `@file:line1-line2` → visual mode 下的 `<leader>yr`

單行的 visual 選取會把 `:12-12` 收斂成 `:12`。在 visual mode 複製後，該對映會離開
visual mode 並顯示 `Copied @…` 的提示 (toast)。

## 路徑類型

- **相對** (`yr` / `yf`) 以 **git 根目錄**為基準解析（`LazyVim.root.git()`，與
  [Floating TUI](floating-tui.md) 使用同一個根目錄）。git 根目錄以外的檔案會退回到
  以 `~` / cwd 為基準的相對路徑。
- **絕對** (`ya` / `yF`) 是完整的機器路徑（`expand("%:p")`），不解析 symlink。

貼給 Claude Code 時通常用相對路徑（它在專案內運作）；絕對路徑則適用於 repo 以外的
檔案，或某個工具需要完整路徑時。

## 實作細節

整個功能就是 `lua/config/keymaps.lua` 裡一個約 40 行的 `copy_reference(opts)` helper，
加上四個 `vim.keymap.set({ "n", "x" }, …)` 呼叫。它重用了下列既有能力，不引入新的依賴
(dependency)：

- `LazyVim.root.git()` — git 根目錄偵測。
- `vim.fs.relpath(root, abspath)` — 內建的相對路徑計算。
- `vim.fn.setreg("+", ref)` — 尊重 `lua/config/options.lua` 設定的 OSC 52 剪貼簿
  provider，所以即使透過 SSH 也會複製到你本機終端機的剪貼簿。**不要**直接呼叫
  `pbcopy`——那會繞過 OSC 52。詳見 [Clipboard](../tools/clipboard.md)。
- visual range 用 `vim.fn.line(".")` / `vim.fn.line("v")` 取得——與 gitsigns 的
  stage-selection 對映相同的做法。

邊界情況：未命名 / scratch buffer 會顯示 `copy-ref: buffer has no file` 警告且不複製
任何東西；被刪除的 cwd 以 `pcall` 防護（避開 Neovim 0.12 的 `vim.fs.find` ENOENT
陷阱），並退回到相對路徑。

## 為什麼選 `<leader>y`

`<leader>y` 原本是沒被用到的 prefix。`<leader>a` 底下的 AI 快捷鍵已經很擠——avante 與
claudecode 都綁了很多 `<leader>a…` 的鍵，甚至彼此互相衝突——所以另開一個 `y`
（「yank / 複製」）群組，能讓這些「複製 reference」的動作避開那塊爭用區，也更容易在
which-key 裡找到。

若要更動或擴充這組鍵，編輯 `lua/config/keymaps.lua` 裡的 `copy_reference` helper 與
`vim.keymap.set` 區塊即可。
