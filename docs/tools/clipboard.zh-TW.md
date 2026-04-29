# 剪貼簿與 OSC 52

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本文件說明本 dotfiles 設定中剪貼簿 (clipboard) 同步是如何串接的，重點放在 **OSC 52** — 這條逸出序列 (escape sequence) 讓遠端 SSH session 能把文字放進你**本機**的剪貼簿。

## 太長別讀 (TL;DR)

| 你身處… | Neovim 中 yank 會送到… | 擷取 pane（`prefix+y/Y/C-y`）會送到… |
|----------|--------------------------|---------------------------------------------|
| 本機（macOS 或 Linux 桌面） | 系統剪貼簿（預設 provider：`pbcopy` / `wl-copy` / `xclip`） | 同上，透過 `tmux load-buffer -w -` 同時發出 OSC 52 *並*設定 tmux 的 paste buffer |
| SSH（遠端機器，無論有無 tmux） | **本機**的剪貼簿（透過 OSC 52） | **本機**的剪貼簿（透過 tmux → OSC 52） |

不需要額外工具、不需要 X forwarding、不需要 socat 監聽器。唯一硬性需求是你**本機**的終端機模擬器要支援 OSC 52（Ghostty、Alacritty、iTerm2、Kitty、WezTerm — 都支援）。

## 什麼是 OSC 52？

`OSC 52` 是一個 ANSI 逸出序列：

```
ESC ] 52 ; c ; <base64-of-data> BEL
```

任何能寫入終端機的程式都能發出這個序列；另一端的終端機模擬器會解開 base64 並寫入系統剪貼簿。關鍵特性是：**逸出序列會沿著 TTY 一路上行回到客戶端終端機**，所以這在 SSH、mosh、嵌套的 `tmux ssh` 鏈中皆可透明運作 — 不需要 display server、不需要 socket forwarding。

權衡點：

- **寫入**幾乎無所不在。多數現代終端機預設或經簡單同意即允許。
- **讀取**（把本機剪貼簿貼回遠端 app）支援度低很多 — 許多終端機基於明顯的安全考量（惡意伺服器可能竊取你的剪貼簿）會拒絕。Ghostty 會詢問；Alacritty 直接忽略。
- 終端機多工器 (multiplexer)（tmux、screen、zellij）介於內層 app 與外層終端機之間。它必須被設定為要嘛**發出** OSC 52 給其宿主終端機，要嘛**直通 (passthrough)** 來自內層 app 的 OSC 52。

參考：[tmux Clipboard wiki](https://github.com/tmux/tmux/wiki/Clipboard)、[XTerm control sequences (OSC)](https://www.invisible-island.net/xterm/ctlseqs/ctlseqs.html)。

## 本 repo 如何串接

四層協作。少了任何一層，遠端剪貼簿同步都會悄悄失效。

### 1. 終端機模擬器（外層，在你本機）

必須接受其內部執行的程式發出的 OSC 52 寫入。

**Ghostty / cmux** — [`dot_config/ghostty/config`](../../dot_config/ghostty/config)：

```conf
clipboard-write = allow   # 讓內層 app 設定系統剪貼簿
clipboard-read  = ask     # 讀取前先詢問（較安全的預設值）
```

兩者都符合 Ghostty 目前的預設值，但顯式釘住，免得上游政策飄移悄悄破壞（或弱化）這條鏈路。

**Alacritty** — 原生支援，無需設定。不支援 OSC 52 貼上。

**iTerm2 / Kitty / WezTerm** — 原生支援。iTerm2 需要在 `Preferences → General → Selection → Applications in terminal may access clipboard` 才能讀取。

### 2. 多工器 — tmux

[`dot_config/tmux/common.conf`](../../dot_config/tmux/common.conf)：

```tmux
set -g set-clipboard on

set -as terminal-features ",xterm*:clipboard"
set -as terminal-features ",ghostty*:clipboard"
set -as terminal-features ",alacritty*:clipboard"

set -g allow-passthrough on
```

- **`set-clipboard on`** — tmux 在自家 copy-mode 進行 yank 時會把 OSC 52 重新發出給外層終端機，並把來自內層 app（Neovim、less 等）的 OSC 52 直通過去。`external` 只會直通；`on` 是嚴格的超集且更簡單。
- **`terminal-features …:clipboard`** — 告訴 tmux 外層終端機支援 OSC 52，不需要 terminfo 的 `Ms` 能力。許多發行版附的 `tmux-256color` 條目缺少 `Ms`，所以直接宣告該特性可避免在新機器上 `chezmoi apply` 時遇到驚嚇。
- **`allow-passthrough on`** — 讓終端機圖片協定（sixel、kitty graphics）能運作；也涵蓋嵌套多工器的 OSC 直通。

**Capture-pane 輔助** — [`dot_config/tmux/keybindings.conf`](../../dot_config/tmux/keybindings.conf) — 採用 tmux 原生語法，而非外呼 shell：

```tmux
bind y   run-shell "tmux capture-pane -p   | tmux load-buffer -w -"
bind Y   run-shell "tmux capture-pane -pS - | tmux load-buffer -w -"
bind C-y run-shell "tmux capture-pane -pS - | fzf-tmux … | tmux load-buffer -w -"
```

`load-buffer -w -` 把 stdin 讀入 tmux 的 paste buffer *並*（因為 `-w`）透過 OSC 52 轉送到系統剪貼簿。先前這些綁定 (binding) 用 `pbcopy | xclip | xsel` 備援鏈，只在本機可用 — 透過 SSH 時會把資料複製到**遠端**機器的剪貼簿，毫無用處。tmux 原生形式在兩處運作完全相同。

`set-buffer -w …` 提供同樣的 `-w` flag 但以引數接資料，這在多行 pane 內容上會踩進 shell 引號的地雷區；`load-buffer -w -` 讀 stdin 可閃過。

### 3. 編輯器 — Neovim

[`dot_config/nvim/lua/config/options.lua`](../../dot_config/nvim/lua/config/options.lua)：

```lua
vim.opt.clipboard = "unnamedplus"

if vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy  = { ["+"] = osc52.copy("+"),  ["*"] = osc52.copy("*")  },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
end
```

- 本機時，使用 LazyVim 預設 provider（`pbcopy`/`xclip`/`wl-copy` — 貼上正常運作）。
- SSH 時，Neovim 內建的 `vim.ui.clipboard.osc52`（自 Neovim 0.10 起隨附）直接發出 OSC 52，繞過遠端主機上任何 `pbcopy` 二進制檔。
- 判斷條件是 `SSH_CONNECTION or SSH_TTY` — 任一個都會由 `sshd` 為互動 session 設定。

為何用條件式而非永遠開啟 OSC 52？OSC 52 貼上不可靠（見上方終端機表格）。本機 session 保留本機 provider 可保留 Neovim 的貼上行為；只有當遠端的 `pbcopy` 顯然是錯誤答案時才覆寫。

### 4. Shell CLI — `x`（跨平台剪貼簿包裝）

[`bin/executable_x`](../../bin/executable_x)（部署到 `~/.local/bin/x`）是一支 Bash 包裝，含三個子指令：

```bash
printf "hello" | x copy        # 把 stdin 複製到剪貼簿
x copy path/to/file            # 複製檔案內容
x paste                        # 把剪貼簿印到 stdout
x open https://example.com     # 在預設 app 中開啟 URL/檔案
```

它的 copy 後端依序嘗試：`clip.exe`（WSL）→ `pbcopy`（macOS）→ `wl-copy`（Wayland）→ `xclip` → `xsel` → **OSC 52 備援**直接寫入 `/dev/tty`。意思是 `x copy` 在 macOS、Linux 桌面、Linux SSH 伺服器、WSL 以及任何能觸及終端機的環境上都能直接使用 — 你完全不需要思考有哪個後端可用。

`x` 中的 OSC 52 備援也為 tmux 做了包裝：

```bash
if [[ -n "${TMUX:-}" ]]; then
  printf '\033Ptmux;\033\033]52;c;%s\033\033\\\033\\' "$data" > /dev/tty
else
  printf '\033]52;c;%s\033\\' "$data" > /dev/tty
fi
```

`DCS tmux; ... ST` 包裝是 tmux 的直通逸出 — 它告訴 tmux「把這段序列原封不動交給外層終端機」，必要原因是 tmux 否則會攔截 OSC 52。

## 驗證鏈路是否正常

在 Neovim yank 行為怪異的遠端機器上執行：

```bash
# tmux：它是否相信終端機能接受 OSC 52？
tmux info | grep -Ei 'clipboard|Ms:'
# 預期：clipboard: true，且有一個 NOT [missing] 的 Ms 條目

# shell：x copy 能否觸及剪貼簿？
printf "hello from %s" "$(hostname)" | x copy
# 然後 Cmd+V / Ctrl+V 到本機 app → 應該貼上 "hello from <remote-host>"

# Neovim：目前啟用哪個 provider？
nvim -c ':checkhealth provider.clipboard' -c ':only'
# 預期：SSH 下為 OSC 52，本機下為原生
```

如果編輯 `common.conf` 後 `tmux info` 仍顯示 `clipboard: false`，記得執行中的 tmux server **保留舊的能力表** — `tmux kill-server`（會失去 sessions；`tmux-resurrect` 可還原）然後重新接入。

## 常見失敗模式

| 症狀 | 可能原因 | 修法 |
|---------|-------------|-----|
| tmux 外 yank 正常，但 tmux 內（遠端）就消失 | `set-clipboard off` 或 server 跑著編輯前的二進制檔 | `tmux show -g set-clipboard`；`tmux kill-server` |
| `tmux info` 顯示 `Ms: [missing]` | tmux 的 TERM 條目缺 `Ms` *且*未宣告 `terminal-features …:clipboard` | 已由 [`common.conf`](../../dot_config/tmux/common.conf) 處理；如果外層 `$TERM` 不尋常，再加一行 `set -as terminal-features` |
| Ghostty 每次 yank 都詢問剪貼簿 | `clipboard-read = ask`；當 app 立即重新抓取時，Ghostty 把某些寫入解讀為讀取 | 若你信任 session 裡的所有東西，改 `clipboard-read = allow` |
| Neovim yank 正常，但 SSH 下 `"*p` 無作用 | 外層終端機不支援 OSC 52 貼上 | 預期行為 — 用滑鼠中鍵或重打；別硬抗 |
| `prefix+y` 仍複製到遠端剪貼簿 | shim 的 `tmux` 二進制檔解析到比 `load-buffer -w` 還舊的版本 | `tmux -V` 必須 ≥ 3.3 才支援 `load-buffer -w`；本 repo 透過 ansible `devtools` role 強制 ≥ 3.3 |
| 嵌套 tmux（`tmux 在 ssh 在 tmux 中`） | 內層 tmux 吃掉 OSC 52 | 內層 tmux 需要 `set -g allow-passthrough on`；本設定已開啟。雙重嵌套案例可能需要 `Ptmux;…` 包裝 |

## 設計筆記 / 非預設值

- **tmux `set-clipboard`** 為 `on`，非 `external`。`external` 會停用 tmux 自家 copy-mode 的 OSC 52 發出；`on` 是超集，能讓 `prefix+[` → `y` 持續運作。
- **Neovim OSC 52 provider** 以 `SSH_CONNECTION`/`SSH_TTY` 為閘門而非永遠開啟，特別是為了讓本機貼上（`"+p`）持續運作。如果你主要透過 SSH 工作且不在意貼上的取捨，可移除 `if …` 區塊。
- **`x` CLI 順序**偏好本機後端（`pbcopy`、`wl-copy` 等）而非 OSC 52。這是刻意的：當 `pbcopy` 可用時，它較快、不碰 TTY，且能處理非常大的酬載（OSC 52 酬載受終端機大小限制 — iTerm2 上限為 1 MB，許多其他為 64–256 KB）。

## 相關文件

- [tmux](./tmux/README.md) — 「OSC 52 Clipboard (SSH-friendly yank)」段落
- [Ghostty](./ghostty.md) — 終端機端筆記
- [`bin/executable_x`](../../bin/executable_x) — `x` 包裝原始碼

## 外部參考

- [tmux Clipboard wiki](https://github.com/tmux/tmux/wiki/Clipboard)
- [Neovim `:help clipboard-osc52`](https://neovim.io/doc/user/provider.html#clipboard-osc52)
- [XTerm OSC 52 spec](https://www.invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands)
