# 複製 Cursor 風格的檔案 reference (`@file:line`)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

四個 Neovim 快捷鍵 (keymaps)，把 **Cursor / Claude Code 風格的檔案 reference**
——`@path`、`@path:12` 或 `@path:12-40`——複製到系統剪貼簿 (clipboard)，內容由目前的
buffer 加上游標所在行（normal mode）、選取範圍 (visual selection)（visual mode），或在
file explorer 中游標下的節點 (node) 組成。
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

## 檔案總管 (neo-tree / snacks)

在 **file-explorer** buffer 中觸發快捷鍵時，reference 會改為指向**游標下的節點 (node)**
（不帶行號）——例如在樹狀項目上按 `<leader>yf` 會複製 `@rel/path/to/that/file`。這與
neo-tree 自己的 `Y`（copy path）行為一致。

- **neo-tree**：目前已支援（透過 neo-tree 的 manager API 解析節點）。
- **snacks explorer**——LazyVim 用來取代 neo-tree 的後繼者——以 best-effort 方式處理，
  讓這組快捷鍵在遷移後仍能運作。
- 其他任何特殊 buffer（terminal、help、quickfix、未知的 explorer、未命名 buffer）都會被
  安全地拒絕，顯示 `copy-ref: no file under cursor here` 警告——絕不會產生像
  `@neo-tree filesystem [1]` 這種垃圾字串。

## Shell 版孿生指令：`cref`

在編輯器以外，[`cref`](../shells/aliases.md#shell-utilities) shell 函式能在命令列
產生**相同形態的 reference**，並複製到剪貼簿——走 `x` CLI 的 OSC 52 路徑，所以透過
SSH 也能用：

```sh
cref src/app.py:42        # 複製 @src/app.py:42
cref -a src/app.py:10-20  # @/abs/src/app.py:10-20（機器絕對）
rg -n TODO | cref         # 取 ripgrep 第一筆結果的 reference
```

它對應同樣的路徑類型——預設 git 根目錄相對（含相同的 cwd/`~`/絕對退回機制）、`-a`
為絕對——再加一個 `-c` 表示明確以 cwd 為基準。由於 shell 沒有「游標行」的概念，行號
來自 `FILE:LINE[-LINE]` 參數、尾隨的位置參數（`cref FILE 12 40`），或管線傳入的
grep/ripgrep 行（`FILE:LINE:…`，`:col` 會被去掉）。原始碼：
`dot_config/shell/59_cref.sh`。

## 實作細節

整個功能就是 `lua/config/keymaps.lua` 裡一組小的 `copy_ref_target()` + `copy_reference()`
helper，加上四個 `vim.keymap.set({ "n", "x" }, …)` 呼叫。它重用了下列既有能力，不引入新的依賴
(dependency)：

- `LazyVim.root.git()` — git 根目錄偵測。
- `vim.fs.relpath(root, abspath)` — 內建的相對路徑計算。
- `vim.fn.setreg("+", ref)` — 尊重 `lua/config/options.lua` 設定的 OSC 52 剪貼簿
  provider，所以即使透過 SSH 也會複製到你本機終端機的剪貼簿。**不要**直接呼叫
  `pbcopy`——那會繞過 OSC 52。詳見 [Clipboard](../tools/clipboard.md)。
- visual range 用 `vim.fn.line(".")` / `vim.fn.line("v")` 取得——與 gitsigns 的
  stage-selection 對映相同的做法。

Buffer 的解析放在 `copy_ref_target()` helper：真正的檔案 buffer（`buftype` 為空）會給出
檔案加上行號 context；已知的 explorer 會給出游標下的節點；其他一律回傳 `nil` 由呼叫端
發出警告。Explorer 的查詢都用 `pcall` 包起來，所以 API 有變動或不存在時會降級為那個警告，
而不是崩潰或吐出垃圾路徑。被刪除的 cwd 同樣以 `pcall` 防護（避開 Neovim 0.12 的
`vim.fs.find` ENOENT 陷阱），並退回到相對路徑。

## 為什麼選 `<leader>y`

`<leader>y` 原本是沒被用到的 prefix。`<leader>a` 底下的 AI 快捷鍵已經很擠——avante 與
claudecode 都綁了很多 `<leader>a…` 的鍵，甚至彼此互相衝突——所以另開一個 `y`
（「yank / 複製」）群組，能讓這些「複製 reference」的動作避開那塊爭用區，也更容易在
which-key 裡找到。

若要更動或擴充這組鍵，編輯 `lua/config/keymaps.lua` 裡的 `copy_reference` helper 與
`vim.keymap.set` 區塊即可。
