# Emacs 風格行編輯 — 起源與必知子集

> **給非 vim 使用者**：本 repo 提供 chezmoi `enableVimMode` prompt
> （預設 `true`）。設為 `false` 後，你的 shells（zsh + bash）會
> 徹底放棄 vi 模態編輯——行為完全符合本文描述（純 emacs keymap）。
> 停用流程詳見 [`docs/this_repo/vim-mode.md`](../this_repo/vim-mode.md)。

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

## TL;DR

你在到處看到的那些「奇怪」的 `Ctrl+A` / `Ctrl+E` / `Ctrl+W` / `Ctrl+R` 快捷鍵——
bash、zsh、`psql`、`python` REPL、`node`、`sqlite3`、許多 TUI 輸入框，
甚至 macOS 原生文字欄位——全都是 **Emacs 編輯器鍵盤映射 (keymap)** 的後裔，
透過 GNU **Readline** (bash 的行編輯器) 與 zsh 的 **ZLE** (Zsh Line Editor)
傳播開來。

它不是 POSIX 標準；它是一套層層疊加的慣例，會固定下來是因為它出現得早、
簡單、無模式 (modeless)，並且非常適合單行命令編輯。你不需要把整張表背起來——
參見 [下方第一層](#tier-1--8) 的 8 個按鍵，第一天就能回本。

要**實際查詢**這個 repo 中啟用的每個綁定 (內建、外掛、自訂 widget)，
可在任意 zsh 提示字元按 `Alt+/`——參見
[Zsh Keybindings & the keys-picker widget](keybindings.md)。

## 為什麼每個 Unix shell 都共用相同的快捷鍵

血緣關係大致如下：

```
Terminal (xterm / Ghostty / Alacritty / iTerm2 / …)
         ↓ raw keystrokes / escape sequences
Shell's line editor
         ├─ bash → GNU Readline (default keymap: emacs)
         ├─ zsh  → ZLE          (default keymap: emacs)
         └─ fish → fish's own line editor (emacs-flavored defaults)
         ↓ translates keys → "widgets" (named actions)
Widget (beginning-of-line, kill-line, yank, …)
```

三者**預設的 keymap 都是 Emacs**。你可以用一行設定切到 vi-mode
([§ 切換模式](#switching-modes))，但很少人這樣做——一部分是因為終端機的
編輯任務多半是短短的單行命令，無模式 (modeless) 比有模式 (modal) 更好；
另一部分是因為這些 Emacs 鍵在 REPL、`psql`、`sqlite3` 與 macOS Cocoa
文字系統用了多年後早已成為肌肉記憶。

它**不是 POSIX**。POSIX `sh` 對行編輯隻字未提——這在 bash 規格中是
選用的 `set -o emacs` / `set -o vi` 擴充功能，而 zsh 則有獨立的
`bindkey` 系統。它之所以幾近通用，純屬歷史因素：

1. 早期的 Unix shell **完全沒有**行編輯——你打字、按 Enter，打錯沒得改。
2. Bill Joy 的 **vi** (1976) 與 Stallman 的 **Emacs** (1976) 各自帶來了
   buffer 內編輯的 keymap 慣例。
3. Readline 在 1980 年代從 bash 專案中被獨立成可重用函式庫；作者選擇
   Emacs 綁定作為預設值，因為 Stallman 的 keymap 已經有完整文件，
   且為「無模式」(沒有 `Esc` 來回切換)——對新手更友善。
4. 每個想要 history + 行編輯的 CLI 工具都開始連結 Readline (或它的
   BSD 兄弟 `editline` / `libedit`)——psql、python、sqlite3、node、
   irb、gdb、lldb、mysql……
5. zsh 的 ZLE 是從零寫起的，但刻意保留與 Readline 相容的鍵綁定
   (`emacs` keymap)，讓使用者在切換 shell 時不需要重新學習。

所以這個慣例不是「Emacs 比較紅」——而是「Readline 先到，所有東西都接到
Readline 上」。連 macOS 原生文字欄位都支援其子集 (`Ctrl+A`、`Ctrl+E`、
`Ctrl+K`、`Ctrl+Y`、`Ctrl+P`、`Ctrl+N`)，因為 Cocoa 的文字系統正是
受同一慣例啟發。

## 三層分級

不要試著背 40 個快捷鍵。這些綁定可以乾淨地切成
**必背 / 知道更好 / 需要時再查**。

### 第一層 — 必背 (8 個按鍵)

第一天就回本。真正的高頻按鍵。

| 按鍵 | 動作 | 助記 |
|-----|--------|----------|
| `Ctrl+A` | 行首 | **A**head / start |
| `Ctrl+E` | 行尾 (**E**nd) | — |
| `Ctrl+U` | 砍 (kill) 到行首 | 「U-turn」往回 |
| `Ctrl+K` | 砍 (**K**ill) 到行尾 | — |
| `Ctrl+W` | 砍掉前一個字 (**w**ord) | — |
| `Ctrl+R` | 反向 (**R**everse) 歷史搜尋 (本 repo 使用 fzf) | — |
| `Ctrl+L` | 清螢幕 (保留目前命令) | **L**ight refresh |
| `Ctrl+X Ctrl+E` | 在 `$EDITOR` 中開啟目前命令 | 「Edit」 |

如果你只學這 8 個，已經涵蓋了日常約 90% 的收益。

### 第二層 — 知道更好

當第一層成為肌肉記憶後，值得再過一輪。

| 按鍵 | 動作 |
|-----|--------|
| `Alt+B` | 往**後**移一個字 (Alt = 「以字為單位」) |
| `Alt+F` | 往**前** (**f**orward) 移一個字 |
| `Alt+D` | 砍掉下一個字 (向前版的 `Ctrl+W`) |
| `Alt+.` | 插入上一個命令的**最後一個參數** |
| `Ctrl+Y` | **Y**ank (貼上) 最近一次砍掉的文字 |
| `Ctrl+T` | 對調兩個字元 (修正 typo：`teh` → `the`) |
| `Ctrl+_` | Undo |
| `Ctrl+P` / `Ctrl+N` | 上一筆 / 下一筆歷史 (= ↑/↓) |

光是 `Alt+.` 就能取代 80% 的「我又需要剛剛那個參數」場景——
例如 `mkdir foo/bar/` 後接 `cd <Alt+.>`。

### 第三層 — 需要時再查

不要背。需要時用 `Alt+/` ([keys-picker](keybindings.md)) 或
`bindings` (CLI) 來 grep。

| 按鍵 | 動作 |
|-----|--------|
| `Ctrl+X Ctrl+U` | Undo (替代版) |
| `Ctrl+X Ctrl+X` | 對調游標與 mark |
| `Ctrl+X Ctrl+R` | 重新讀取 inputrc |
| `Alt+T` | 對調兩個字 (**w**ords) |
| `Alt+U` / `Alt+L` | 把下一個字轉大寫 / 小寫 |
| `Alt+C` | 把下一個字首字母大寫 |
| `Alt+\\` | 刪除周圍的空白字元 |
| `Ctrl+V` | 逐字插入 (例如插入字面上的 `Ctrl+J`) |

## Home / End vs Ctrl+A / Ctrl+E

在大多數現代鍵盤上，`Home` 與 `End` 在 bash/zsh 中能正常運作，且效果
等同於 `Ctrl+A` / `Ctrl+E`。那為何還要用 Ctrl 版本？

1. **它們到處都能用。** `psql`、`python`、`node`、`sqlite3`、`irb`、
   `gdb`、`lldb`、ssh 進 busybox 容器、tmux copy-mode、macOS Cocoa
   文字欄位——全都支援 `Ctrl+A`/`E`，因為它們都嵌入了 Readline (或
   相容的編輯器)。`Home`/`End` 需要 terminal → app → library 整條
   鏈路在 escape 序列上達成共識，這出乎意料地常常失敗 (沒有
   `xterm-keys` 的 tmux、screen、序列主控台、recovery shell……)。
2. **手不離 home row。** 不必伸手去按方向鍵叢集。
3. **可組合。** `Ctrl+A Ctrl+K` = 「全選、剪下」一氣呵成。
   `Home Shift+End Delete` 是三鍵，且需要 shell 並沒有的選取模型。
4. **SSH 友善。** 在不穩定的連線上，單一位元組的 `Ctrl` 序列比
   多位元組的 `\e[H` / `\e[F` 序列更可靠地往返傳輸。

`Ctrl+P` / `Ctrl+N` 相對於 `↑` / `↓` 也是同樣道理——方向鍵是多位元組
的 escape 序列，某些環境會把它弄壞。

## 為什麼預設不是 vi mode？

zsh 與 bash 都內建了 `set -o vi` / `bindkey -v`。它存在、可用，也有
一群死忠擁護者。那為什麼到處都是 `emacs` 預設？

1. **無模式 (Modeless)。** 單行命令編輯很短。「我現在在 insert 還是
   normal mode？」加上每次編輯都要按一次 `Esc` 來回，成本超過 vi 的
   verb+motion 文法的好處——後者在多行 buffer 上才發揮得出來，60 字
   元的命令派不上用場。
2. **可發現性 (Discoverability)。** 新手隨手按 `Ctrl+A` 就能看到有用
   的事情發生。在 insert mode 下按 `dd` 只會打出 "dd"。
3. **歷史慣性。** Readline 在 80 年代選了 emacs；下游所有東西都繼承了。
4. **REPL 人體工學。** `python`、`node`、`psql` 等預設都是 emacs
   keymap。把 shell 切到 vi-mode 等於活在分裂大腦的世界。

話雖如此——如果你住在 Vim 裡，又想要 zsh 的 vi-mode，這個 repo 使用
[`zsh-vi-mode`](https://github.com/jeffreytse/zsh-vi-mode)，比內建的
`bindkey -v` 好太多 (visual mode、surround、yank 到系統剪貼簿、模式
指示器)。設定方式參見 [`docs/shells/zsh.md`](zsh.md)。代價：每個新的
emacs 風格綁定都必須在 `zvm_after_init` 中重新套用，因為 zsh-vi-mode
會在初始化時把 keymap 清空——範例請看
[`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl)
中 `Alt+/` 的 rebind 寫法。

## Kill-ring vs 系統剪貼簿

`Ctrl+K`、`Ctrl+U`、`Ctrl+W`、`Alt+D` 都是「砍」(kill) 文字——而
`Ctrl+Y` 把它「拉」(yank) 回來。這**不是**系統剪貼簿，而是行程內的
**kill-ring** (最近被砍掉文字的堆疊)，繼承自 Emacs。

衍生影響：

- 被砍掉的文字**不會**進到 `pbpaste` / `xclip` / `wl-paste`。你沒辦法
  把它貼進瀏覽器。
- `Ctrl+Y` 後接 `Alt+Y` (在某些 shell 中) 可循環瀏覽 kill-ring 中較舊
  的條目。
- `Ctrl+W` (砍字) + `Ctrl+Y` 是快速「複製上一個字」的招數——砍掉、
  拉回來、再拉一次。

如果你想把砍掉的文字送進系統剪貼簿，需要包一層 widget。zsh-vi-mode 在
正確設定下已為 vi-mode 的 `y` / `d` 操作做到這件事；emacs-mode 在這個
repo 中沒有橋接 (列在
[future TODO](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md))。

## 給 Vim 使用者 — `Ctrl+X Ctrl+E` 逃生艙

對被困在 emacs-keymap shell 中的 vim 使用者來說，最有用的單一綁定：

```
Ctrl+X Ctrl+E
```

把**目前的命令列**用 `$EDITOR` (本 repo 設為 `nvim`) 開啟。當作普通檔案
編輯——多行、語法高亮、完整 vim motion，若有設定還能用 LSP。存檔離開
後，編輯後的 buffer 會作為下一條命令執行。

適合用於：

- 需要 5 行以上的 `ffmpeg` / `awk` / `jq` one-liner。
- 從某處貼上的多行 snippet，先編輯再執行。
- 撰寫複雜的 `git commit -m "$(cat <<EOF ...`。
- 修正一個你打錯到第 3 層的 `for` 迴圈。

在環境變數中設定 `EDITOR=nvim` (本 repo 已設定，參見
[`dot_config/shell/00_env.sh`](https://github.com/daviddwlee84/dotfiles/tree/main/dot_config/shell))。
有了這個綁定，你就不必再為任何稍微複雜的事跟 emacs keymap 搏鬥。

## 這套慣例在 shell 之外的應用

相同的鍵、相同的預期，得益於 Readline / libedit / 原生 Cocoa 支援：

| 工具 | 備註 |
|------|-------|
| `psql`、`mysql`、`sqlite3` | 完整 Readline |
| `python` (system)、`ipython` | Readline (system) / prompt_toolkit (ipython，預設 emacs-keymap) |
| `node`、`irb`、`lua` | Readline / libedit |
| `gdb`、`lldb` | Readline / libedit |
| `ssh` 密碼提示 | 有限——`Ctrl+U` 可用 |
| `tmux` 命令提示字元 (`prefix + :`) | Emacs 鍵 (可透過 `set -g status-keys vi` 改成 vi) |
| macOS 原生文字欄位 | `Ctrl+A/E/K/Y/P/N/F/B/D/T`——Cocoa 文字系統 |
| 瀏覽器網址列 (Linux+macOS 上的 Chromium/Firefox) | 部分子集可用 |
| Slack/Discord 輸入框 | macOS 上透過 Cocoa 部分可用 |

這就是為什麼學會第一層那組是高槓桿的——肌肉記憶會跨越你已經在用的數十
個工具。

## 切換模式

各 shell，在你的 rc 檔中：

```sh
# bash
set -o emacs    # default
set -o vi

# zsh
bindkey -e      # emacs (default)
bindkey -v      # vi
```

各工具 (Readline-based，在 `~/.inputrc` 中)：

```
set editing-mode emacs
# or
set editing-mode vi
```

某些工具 (python 的 `prompt_toolkit`、ipython) 有自己的 `%config`
切換——請查該工具的文件。

## 建議的心智模型

1. **學第一層 (8 個按鍵)。** 兩天有意識地使用，之後就永久內化。
2. **設定 `EDITOR=nvim` 並使用 `Ctrl+X Ctrl+E`** 來處理任何超過一行
   的內容。
3. **使用 `Alt+/`** ([keys-picker](keybindings.md))，當你感覺到
   「這應該有個綁定吧」但又想不起來時。不要試著背完整張表。
4. **不要費心研究 vi-mode**，除非你經常寫多行 shell 區塊，且每天都
   在用 vim。分裂大腦的成本 (REPL 仍是 emacs) 通常划不來。

## 相關文件

- [Zsh Keybindings & the keys-picker widget](keybindings.md)——本 repo
  中啟用的每個綁定，搭配 `Alt+/` picker 與 `bindings` CLI。
- [Zsh setup](zsh.md)——外掛 (zsh-vi-mode、autosuggestions、
  syntax-highlighting) 與載入順序。
- [Bash setup](bash.md)——ble.sh + oh-my-bash，以及為何某些 zsh-only
  widget 還沒有 bash 版。
- GNU Readline manual：
  <https://tiswww.case.edu/php/chet/readline/rluserman.html>
- zsh ZLE manual：`man zshzle`
