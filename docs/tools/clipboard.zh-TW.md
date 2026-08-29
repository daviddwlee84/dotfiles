# 剪貼簿與 OSC 52

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

本文件說明本 dotfiles 設定中剪貼簿 (clipboard) 同步是如何串接的，重點放在 **OSC 52** — 這條逸出序列 (escape sequence) 讓遠端 SSH session 能把文字放進你**本機**的剪貼簿。

## 太長別讀 (TL;DR)

| 你身處… | Neovim 中 yank 會送到… | 擷取 pane（`prefix+y/Y/C-y`）會送到… |
|----------|--------------------------|---------------------------------------------|
| 直接本機 terminal / 純 tmux | 系統剪貼簿（provider 二進制檔：macOS 用 `pbcopy` / Linux 用 `wl-copy` / `xclip`） | 同上，透過 `tmux load-buffer -w -` 同時發出 OSC 52 *並*設定 tmux 的 paste buffer |
| SSH / Herdr / Zellij | **目前 attached client** 的剪貼簿（copy-only OSC 52） | **目前 attached client** 的剪貼簿（OSC 52） |

不需要 X forwarding、不需要 socat 監聽器。SSH 時唯一硬性需求是你**本機**的終端機模擬器要支援 OSC 52（Ghostty、Alacritty、iTerm2、Kitty、WezTerm — 都支援）。在**本機 Linux 桌面**上，provider 二進制檔不是內建的：`wl-clipboard` + `xclip` + `xsel` 由 [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) ansible role 安裝（`ubuntu_desktop` profile）。伺服器 profile 一律沒有 — 那裡只靠 OSC 52。

遠端 / multiplexer 路徑刻意保持**單向**：Neovim yank 會寫入 attached
client 的剪貼簿；普通 `p` 只讀 Neovim 自己的 unnamed register，絕不送出
OSC 52 query。要把外部剪貼簿文字貼進 Neovim，使用 terminal 原生貼上
（`Cmd+V` / `Ctrl+Shift+V`）。

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
if use_osc52 then
  vim.opt.clipboard = "" -- 普通 p 維持使用 Neovim unnamed register
  vim.g.clipboard = {
    name = "OSC 52 copy-only",
    copy = { ["+"] = osc52_copy("+"), ["*"] = osc52_copy("*") },
    paste = { ["+"] = cached_paste("+"), ["*"] = cached_paste("*") },
  }
  -- TextYankPost 只同步 yank，不同步 delete/change。
else
  vim.opt.clipboard = "unnamedplus"
end
```

- 本機時，使用 LazyVim 預設 provider（`pbcopy`/`wl-copy`/`xclip` — 貼上正常運作）。這個 provider 是**執行期二進制檔偵測** — Neovim 沒有編譯期的 `+clipboard`。macOS 內建 `pbcopy`；Linux 桌面的二進制檔來自 `wl-clipboard` / `xclip`，由 [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) role 安裝（「Install clipboard CLIs」）。沒有它，`:checkhealth provider.clipboard` 會回報「No clipboard tool found」，yank 靜默失效 — 見 [`pitfalls/lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md`](../../pitfalls/lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md)。
- 遠端 / 多工環境 —— `SSH_CONNECTION`/`SSH_TTY`/`SSH_CLIENT`（互動 `sshd` session），**或 `HERDR_ENV`/`ZELLIJ`** —— Neovim 只在 copy 時發出 OSC 52，讓 yank 送到目前 attached terminal；普通 `p` 留在 editor 內且立即完成。Delete/change 不會覆寫 attached client 的剪貼簿。herdr 與 zellij 要各自判斷，因為其 pane 環境在 multiplexer server 啟動時就凍結了（該處的 `wl-copy` 打到過期 display），而 pane TTY 仍代理到真正 client。`tmux` 透過 `update-environment` 更新這些變數，所以純 tmux session 維持用 native provider。
- 自訂 `+` / `*` paste 函式只會回傳同一個 Neovim process 先前送出的內容，絕不呼叫 `osc52.paste()`。尚未 copy 過時，顯式 `"+p` 會警告後 no-op；外部剪貼簿請用 terminal paste。
- `X_CLIPBOARD=osc52` 強制 copy-only OSC 52；`X_CLIPBOARD=<任何本機工具>` 強制 native provider。它與 [`x`](#4-shell-cli--x跨平台剪貼簿包裝) 共用環境變數與選擇判斷，但刻意不共用 `x paste` 語意。

為何用條件式而非永遠開啟 OSC 52？本機 native provider 快且真正雙向；遠端或可重新 attach 的 multiplexer pane 中，server 端 provider 可能打到錯的機器，而 OSC 52 read 不可攜，因此只啟用可靠的 write 方向。

### 下游消費者 — lazygit `Ctrl+O`

[`dot_config/lazygit/config.yml`](../../dot_config/lazygit/config.yml) 設定：

```yaml
os:
  copyToClipboardCmd: "printf '%s' {{text}} | x copy"
```

`Ctrl+O`（「複製到剪貼簿」）改走 `x`，而非 lazygit 內附的 `atotto/clipboard`。本機會解析為 `wl-copy`/`xclip`；SSH 時則落到 `x` 的 OSC 52 路徑，讓 yank 也能送到**本機**剪貼簿（lazygit 原生函式庫會送到遠端的 X/Wayland 剪貼簿）。lazygit 在代入前會對 `{{text}}` 做 shell 引號處理，因此含空格的 commit 標題與路徑都安全。

### 4. Shell CLI — `x`（跨平台剪貼簿包裝）

[`dot_dotfiles/bin/executable_x`](../../dot_dotfiles/bin/executable_x)（部署到 `~/.dotfiles/bin/x`）是一支 Bash 包裝，含三個子指令：

```bash
printf "hello" | x copy        # 把 stdin 複製到剪貼簿
x copy path/to/file            # 複製檔案內容
x paste                        # 把剪貼簿印到 stdout
x open https://example.com     # 在預設 app 中開啟 URL/檔案
```

它的 copy 後端依序嘗試：`clip.exe`（WSL）→ `pbcopy`（macOS）→ `wl-copy`（Wayland）→ `xclip` → `xsel` → **OSC 52 備援**直接寫入 `/dev/tty`。意思是 `x copy` 在 macOS、Linux 桌面、Linux SSH 伺服器、WSL 以及任何能觸及終端機的環境上都能直接使用 — 你完全不需要思考有哪個後端可用。Linux 桌面上 `wl-copy` / `xclip` / `xsel` 二進制檔來自 [`gui_apps_linux`](../../dot_ansible/roles/gui_apps_linux/tasks/main.yml) role；沒有它們時 `x copy` 仍可透過 OSC 52 運作，但 `x copy-file` 就沒有後端了。

**在 SSH、herdr、zellij 下** —— `prefer_osc52()`：`SSH_CONNECTION`/`SSH_TTY`/`SSH_CLIENT`、`HERDR_ENV`、或 `ZELLIJ` —— 順序會顛倒：先試 OSC 52，因為該處的本機 `wl-copy` / `xclip` 打到**錯的機器**（SSH）或**凍結的 display**（herdr/zellij pane 繼承的是其 server 啟動時的環境，不是現在接上的 client；但 pane TTY 永遠代理到真正的 client）。若 `/dev/tty` 無法開啟（無 PTY 的 `ssh`），`x` 才退回顯示伺服器工具，涵蓋 `ssh -X`。`x copy-file` 在此直接拒絕 — OSC 52 只能帶文字。與 Neovim `options.lua` 同一個判斷式。

**`X_CLIPBOARD`** 完全覆蓋自動偵測：`osc52 | wl-copy | xclip | xsel | pbcopy | clip.exe`。在一台你總是透過某種會隱藏 `SSH_*` 又不是 herdr/zellij 的東西（純 `mosh`、某些 Remote-SSH）連進去的機器上，把 `export X_CLIPBOARD=osc52` 放進 `~/.shellrc.adhoc`。

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
# 預期：SSH/Herdr/Zellij 下為 OSC 52 copy-only，直接本機下為原生
```

如果編輯 `common.conf` 後 `tmux info` 仍顯示 `clipboard: false`，記得執行中的 tmux server **保留舊的能力表** — `tmux kill-server`（會失去 sessions；`tmux-resurrect` 可還原）然後重新接入。

## 常見失敗模式

| 症狀 | 可能原因 | 修法 |
|---------|-------------|-----|
| tmux 外 yank 正常，但 tmux 內（遠端）就消失 | `set-clipboard off` 或 server 跑著編輯前的二進制檔 | `tmux show -g set-clipboard`；`tmux kill-server` |
| `tmux info` 顯示 `Ms: [missing]` | tmux 的 TERM 條目缺 `Ms` *且*未宣告 `terminal-features …:clipboard` | 已由 [`common.conf`](../../dot_config/tmux/common.conf) 處理；如果外層 `$TERM` 不尋常，再加一行 `set -as terminal-features` |
| Neovim 在 `p` 後顯示 `Waiting for OSC 52 response from the terminal. Press Ctrl-C to interrupt...` | 完整 OSC 52 provider 搭配 `clipboard=unnamedplus`，讓普通 paste 變成 terminal clipboard query；Herdr 不會回傳 | 已用 copy-only provider 修正；普通 `p` 用 Neovim register，外部剪貼簿用 terminal `Cmd+V` / `Ctrl+Shift+V`。見 [`pitfalls/nvim-p-waits-for-osc52-response-in-herdr.md`](../../pitfalls/nvim-p-waits-for-osc52-response-in-herdr.md) |
| SSH/Herdr/Zellij 下顯式 `"+p` 沒有外部剪貼簿內容 | copy-only mode 刻意不讀 client clipboard，只能重播本 Neovim process 最近送出的 `+` 內容 | 預期行為 — 使用 terminal 原生 paste |
| `prefix+y` 仍複製到遠端剪貼簿 | shim 的 `tmux` 二進制檔解析到比 `load-buffer -w` 還舊的版本 | `tmux -V` 必須 ≥ 3.3 才支援 `load-buffer -w`；本 repo 透過 ansible `devtools` role 強制 ≥ 3.3 |
| 嵌套 tmux（`tmux 在 ssh 在 tmux 中`） | 內層 tmux 吃掉 OSC 52 | 內層 tmux 需要 `set -g allow-passthrough on`；本設定已開啟。雙重嵌套案例可能需要 `Ptmux;…` 包裝 |
| 在 herdr（或 zellij/mosh）裡 `x copy` / nvim yank 沒把東西放進本機剪貼簿，或跑到**遠端**機器的 | pane 環境在 multiplexer server 啟動時凍結：`$WAYLAND_DISPLAY` 有設、`$SSH_*` 空，所以 `x`/nvim 以為是「本機 Wayland」而用 `wl-copy`。見 [`pitfalls/x-copy-over-ssh-writes-remote-clipboard-not-osc52.md`](../../pitfalls/x-copy-over-ssh-writes-remote-clipboard-not-osc52.md) | 已修正 —— `prefer_osc52` 現在也對 `HERDR_ENV`/`ZELLIJ` 生效。其他會隱藏 `SSH_*` 的情況用 `export X_CLIPBOARD=osc52`。若仍失敗，是**本機**終端機沒轉送 OSC 52，或本機 tmux server 過期（`tmux kill-server`） |

## 設計筆記 / 非預設值

- **tmux `set-clipboard`** 為 `on`，非 `external`。`external` 會停用 tmux 自家 copy-mode 的 OSC 52 發出；`on` 是超集，能讓 `prefix+[` → `y` 持續運作。
- **Neovim OSC 52 在 `SSH_*` / `HERDR_ENV` / `ZELLIJ` / `X_CLIPBOARD=osc52` 下只負責 copy。** 絕不在這些環境把 `vim.ui.clipboard.osc52.paste()` 接進 `unnamedplus`：否則一次 `p` 就可能等十秒，等待 multiplexer 或 terminal 永遠不會送回的 response。當 server 端 clipboard 確實才是目標時，仍可用 `X_CLIPBOARD=<本機工具>` 明確退出。
- **`x` CLI 順序**偏好本機後端（`pbcopy`、`wl-copy` 等）而非 OSC 52 —— *除非* `prefer_osc52()` 為真（`SSH_*` / `HERDR_ENV` / `ZELLIJ`）或 `X_CLIPBOARD=osc52`，此時 OSC 52 優先（本機後端會是錯的機器或凍結的 display）。本機優先是刻意的：`pbcopy`/`wl-copy` 較快、不碰 TTY，且能處理非常大的酬載（OSC 52 受終端機大小限制 — iTerm2 ~1 MB，許多其他 64–256 KB）。OSC 52 優先的分支會在消耗 stdin 之前真正開啟 `/dev/tty`（而非只做 `[[ -w ]]`），所以無 PTY 的 `ssh` 仍能乾淨地往下退。

## 相關文件

- [tmux](./tmux/README.md) — 「OSC 52 Clipboard (SSH-friendly yank)」段落
- [Ghostty](./ghostty.md) — 終端機端筆記
- [`dot_dotfiles/bin/executable_x`](../../dot_dotfiles/bin/executable_x) — `x` 包裝原始碼

## 外部參考

- [tmux Clipboard wiki](https://github.com/tmux/tmux/wiki/Clipboard)
- [Neovim `:help clipboard-osc52`](https://neovim.io/doc/user/provider.html#clipboard-osc52)
- [XTerm OSC 52 spec](https://www.invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands)
