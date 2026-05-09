# Zsh 鍵位綁定 (keybindings) 與 `keys-picker` 小工具 (widget)

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> **TL;DR** ——在任何 zsh 提示字元下按 `Alt+/`，即可模糊搜尋 (fuzzy-search)
> 所有非平凡的鍵位綁定（內建、外掛 (plugin)、自訂）並附帶說明。
> Bash 使用者（或腳本）可透過 `bindings` 以 `tv` / `bat` / `cat`
> 取得相同資料。真實來源 (source-of-truth) 的 markdown 檔：
> [`dot_config/docs/shells/keybindings.md`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/docs/shells/keybindings.md)
> （部署到 `~/.config/docs/shells/keybindings.md`）。

關於 `Ctrl+A` / `Ctrl+E` / `Ctrl+W` / `Alt+.` 等鍵的**歷史由來**，
以及為什麼每一種 Unix shell 都共用這些鍵位，請參閱
[Emacs 風格的命令列編輯——起源與必知核心子集](emacs-line-editing.md)。

---

## 為什麼需要這個

Zsh 沒有真正等同於 `which-key` 的機制——該模式需要「leader 鍵 + 逾時
(timeout)」(Vim 的 `<leader>`、tmux 的 `prefix`)，而 ZLE 對按鍵的解析
是貪婪式 (eager) 的，所以自訂的 `Alt` 按鍵永遠無法做到「等待後續輸入」。
務實的替代方案是**一個列出所有綁定的 fzf picker**，由單一熱鍵開啟。

有三類「容易遺忘」的痛點促成了這個設計：

1. **本 repo 的自訂 `Alt+*` widgets**（`Alt+T` tools-picker、
   `Alt+S` sesh、`Alt+R` atuin、`Alt+P/G/E/A/I` television channels、
   `Alt+;` aisuggest、`Alt+/` keys-picker）
   ——這個命名空間 (namespace) 很擁擠；新增的 widget 幾天內就會被忘掉。
2. **覆蓋 ZLE 內建 (built-in) 的外掛**——例如 `Ctrl+R` 已不再是
   `history-incremental-search-backward`；在 zsh 上是
   `fzf-history-widget`，在 bash 上是 atuin 的 TUI（刻意做成不對稱
   ——詳見 [atuin 文件](../tools/atuin.md#keybindings-cross-shell-asymmetry--read-this)）。
3. **平時用不到、用到時才想起來的內建編輯捷徑**——
   `Ctrl+X Ctrl+E`（在 `$EDITOR` 中開啟目前命令）、`Alt+.`
   （插入上一條命令的最後一個參數）、`Ctrl+_`（復原 (undo)）。

## 四層綁定 (binding) 結構

這份速查表 (cheatsheet) 是經過篩選的，並非窮舉——內建 / 外掛的列項
是依「最常被忘記」而非「列出所有 widget」來挑選的。

| # | 層級 | 來源 | cheatsheet 中的範例 |
|---|-------|--------|------------------------|
| 1 | **ZLE 內建** (emacs keymap) | zsh 內建提供 | `Ctrl+A`、`Ctrl+E`、`Ctrl+W`、`Alt+.`、`Ctrl+X Ctrl+E` |
| 2 | **OMZ / 第三方外掛** | `dot_zshrc.tmpl:21-26`（`zsh-autosuggestions`、`zsh-syntax-highlighting`、`zsh-vi-mode`*）+ fzf shell 整合 | `Ctrl+R` → fzf、`Ctrl+T` → fzf、`Alt+C` → fzf、`End` → autosuggest-accept |
| 3 | **本 repo 的自訂 widgets** | `dot_config/zsh/tools/{05_aisuggest,11_tools_picker,12_television,22_sesh,13_keys_picker}.zsh` + `dot_config/shell/15_atuin.sh` | 所有 `Alt+*` pickers + `Tab` / `→` aisuggest swap + `Alt+R` atuin |
| 4 | **模式切換 (vi)** | `zsh-vi-mode` 外掛* | 刻意**不列出**——`Esc` / `i` / `:` 屬於模式轉換，並非綁定 |

\* 受 chezmoi `enableVimMode` prompt 控制（預設 `true`）。當設為 `false`
時，`zsh-vi-mode` 不會加入 OMZ plugin array，模式切換隨之消失。完整
受影響清單見 [`docs/this_repo/vim-mode.md`](../this_repo/vim-mode.md)。

第 4 層按設計規格刻意省略：列出每一個 `vicmd` 模式的鍵會讓 picker
膨脹到 200+ 列，稀釋訊號 (signal)。

## 三種進入點

| 方法 | 觸發鍵 | 適用環境 | 備註 |
|--------|---------|----------------|-------|
| **ZLE picker**（標準作法） | `Alt+/` | zsh 互動式 (interactive) | 預覽中即時 `bindkey` 查詢；`Ctrl+E` 直接觸發該 widget；`Ctrl+L` 切換成原始 `bindkey -M emacs` 檢視（給進階使用者的逃生口 (escape hatch)） |
| **Television channel** | `tv keybindings` | zsh 與 bash，任何 TTY | 相同資料來源；`Enter` 貼上註解、`Ctrl+Y` 複製鍵位組合 |
| **靜態檢視器** | `bindings` | zsh 與 bash（位於 `dot_config/shell/10_aliases.sh` 的 POSIX function） | 依序選擇 `tv` → `bat` → `less` → `cat`；在非互動式 `bash -c` 中也安全 |

ZLE widget 在
[`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl)
中由 `zvm_after_init` 重新綁定，以避開 `zsh-vi-mode` 在 init 時清除
keybind 的問題——和 `aisuggest` 採用相同模式。Bash 目前沒有對應的
ZLE widget 移植版；CLI fallback 為 `bindings`（沒有 ble.sh keybind，
因為設計這個會與[計畫中的 bash `Alt+/` ble.sh 綁定](#future-bash-port)重複）。

## Picker 內部鍵位綁定 (fzf overlay 中)

| 鍵 | 動作 |
|-----|--------|
| `Enter` | 將 `# <key> → <widget>: <desc>` 以 shell 註解形式貼到 buffer（結果為唯讀；再按一次 Enter 為空動作，或按 `Ctrl+U` 丟棄） |
| `Ctrl+E` | 透過 `zle <widget-name>` 直接觸發該 widget（僅對目前 zsh 已註冊的 widget 有效；未註冊會警告） |
| `Ctrl+L` | 以 `bindkey -M emacs` 原始輸出重新載入 picker——用來找出 cheatsheet 沒收錄的綁定的**逃生口** |
| `Ctrl+/` | 切換預覽面板（即時 `bindkey` 查詢 + 對 `~/.config/zsh/` 中該 widget 原始檔的 `grep`） |

## 資料來源的格式契約

資料來源 [`dot_config/docs/shells/keybindings.md`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/docs/shells/keybindings.md)
是用 `awk -F'|'` 解析的。每一列 cheatsheet 必須**精確**為：

```
| `<KEY>` | `<widget>` | <description> |
```

三個由 pipe 分隔的欄位，鍵以反引號 (backtick) 包住。群組標題
（`### …`）是合法的 markdown 但會被 parser 略過。新增第四欄或反引號
不平衡會**靜默地丟棄該列**——並非硬錯誤 (hard error)，但該列會從
picker 中消失。

`tv keybindings` channel 使用同一份 awk 程式的內嵌複本——詳見
[`dot_config/television/cable/keybindings.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/keybindings.toml)。

## 維護規則

每當你在 `dot_config/zsh/tools/*.zsh` 中新增、修改或移除自訂 zsh
ZLE widget 的綁定時，必須在同一個 commit 中更新**兩個**檔案：

1. [`dot_config/docs/shells/keybindings.md`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/docs/shells/keybindings.md)——picker 的資料來源（每個綁定一列）。
2. [`docs/shells/aliases.md`](aliases.md)——**僅當**該變更新增了使用者
   可呼叫的 function（例如手動執行的 `bindings`、`tools-picker`）時才需要。
   純 ZLE widgets（`tv-files`、`keys-picker`）不需要 aliases.md 的列項。

此規則同時記錄在
[`AGENTS.md`](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md)
的跨檔案維護規則章節中。

## 未來：bash 移植版 {#future-bash-port}

Bash 沒有等同 zsh ZLE widgets 的機制，但 ble.sh 的 `ble-bind`
支援在按鍵組合上執行 shell 指令。bash 版的 picker 會：

1. 放在 `dot_config/bash/13_keys_picker.bash`（依 `AGENTS.md` 中的
   三層規則屬於 bash-only 層）。
2. 在 `~/.bashrc.adhoc`（於 `ble-attach` 後 source）內使用
   `ble-bind -f 'M-/' '_keys_picker_bash'`（Alt+/）。
3. 重用相同的資料來源與 awk parser；只需把動作從
   `zle keys-picker` 換成一個重新讀取 `READLINE_LINE` 與
   `READLINE_POINT` 的 function。

延後實作，直到出現具體的 bash-primary 使用者需求；若有人提出，
請見 [`backlog/`](https://github.com/daviddwlee84/dotfiles/tree/main/backlog)。

## 相關文件

- [Emacs 風格的命令列編輯——起源與必知核心子集](emacs-line-editing.md)——1970／80 年代的歷史，說明為什麼每個 Unix shell 都共用 `Ctrl+A` / `Ctrl+E` / `Ctrl+W` / `Ctrl+R`、kill-ring 與系統剪貼簿 (system clipboard) 的差異，以及推薦給新手的 8 鍵核心。
- [Aliases 與 functions](aliases.md)——shell aliases 的姊妹速查表（不是鍵位綁定）。
- [Bash bootstrap](bash.md)——bash 為何需要 `atuin init bash --disable-up-arrow`，以及 ble.sh 如何整合進來。
- [Architecture](architecture.md)——shared / zsh-only / bash-only 的三層 loader 慣例。
