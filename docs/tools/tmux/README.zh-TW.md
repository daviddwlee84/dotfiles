# tmux

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

由 chezmoi 管理的 tmux 設定 (config) 位於 `~/.config/tmux/`，並在 `~/.tmux.conf` 留一個 shim 以載入 XDG 入口檔。

## 原始檔案佈局 (本 repo 內)

| 原始檔 | 部署位置 | 用途 |
|--------|----------|------|
| [`dot_tmux.conf`](../../../dot_tmux.conf) | `~/.tmux.conf` | 一行式 shim |
| [`dot_config/tmux/tmux.conf`](../../../dot_config/tmux/tmux.conf) | `~/.config/tmux/tmux.conf` | 入口檔，挑選主題 (theme) |
| [`dot_config/tmux/common.conf`](../../../dot_config/tmux/common.conf) | — | 外掛 (plugin) + 與主題無關的選項 |
| [`dot_config/tmux/keybindings.conf`](../../../dot_config/tmux/keybindings.conf) | — | 所有 bind-keys 與彈出選單 (popup menu) |
| [`dot_config/tmux/theme.catppuccin.conf`](../../../dot_config/tmux/theme.catppuccin.conf) | — | 預設主題（頂部狀態列 (status bar)） |
| [`dot_config/tmux/theme.tmux2k.conf`](../../../dot_config/tmux/theme.tmux2k.conf) | — | 替代主題（底部狀態列） |
| [`dot_config/tmux/executable_responsive.sh`](../../../dot_config/tmux/executable_responsive.sh) | `~/.config/tmux/responsive.sh` | Catppuccin 的響應式狀態列 |

此設定針對 coding-agent 與 Neovim 工作流調校：

- 原生彈出選單於 `prefix + Space`；以腳本驅動 (`~/.config/tmux/menu.sh`)，含子選單與依高度分層裁減 — 詳見 [keybindings.md](./keybindings.md#popup-menu-prefix--space)
- `prefix + ?` 提供模糊鍵位 (keybinding) 搜尋（tmux-fzf，取代內建的 list-keys 列印）
- Markdown 速查表透過 `prefix + Space` → `?`（以 `glow` 渲染）
- `prefix + F` 開啟浮動 (floating) 暫存窗格 (pane)（tmux-floax，持久），`prefix + \`` 一次性彈出 shell，`prefix + G` 彈出 lazygit
- Catppuccin（預設，頂部狀態列）或 tmux2k（底部）— 可於執行時切換
- Catppuccin 狀態列為響應式 — 模組依終端機 (terminal) 寬度自適應（適合手機）
- vim 風格的窗格切換與複製模式 (copy mode)
- 透過 fzf (`prefix + u`) 開啟 URL，並在複製模式中使用 tmux-open
- 擷取窗格至剪貼簿的輔助快捷鍵
- 整合 sesh 進行會話 (session) 挑選
- 啟用 `extended-keys` 與 `csi-u`，使 `Ctrl+/` 等鍵位能在 tmux 內傳達到 Neovim
- 啟用 OSC 52 剪貼簿與 OSC passthrough
- macOS 終端機必須將 Option 送出為 Meta，`M-` 綁定才會生效 — 詳見 [ghostty.md](../ghostty.md)

## 本資料夾內

- [keybindings.md](./keybindings.md) — 所有鍵位綁定與彈出選單
- [themes.md](./themes.md) — Catppuccin / tmux2k 選擇、切換、疑難排解
- [vim.md](./vim.md) — tmux × Vim/Neovim 筆記與外部資源

## 首次設定

執行 `chezmoi apply` 後啟動 tmux，按一次 `prefix + I` 讓 TPM 安裝外掛。主題檔案在第一次載入時也會自動 clone 對應外掛作為保險，但 TPM 是正式安裝器。

## 版本需求：tmux >= 3.3

彈出選單（綁定於 `prefix + Space`）由 `~/.config/tmux/menu.sh` 產生，並使用 `display-menu -x R -y P`。當前設計是兩種不同的失敗模式驅動的：

1. **位置 clamping（需要 tmux 3.3+）。** 在 tmux 3.2a（Ubuntu 22.04 apt 隨附版本）中，選單會被定位到終端機右邊緣之外並被靜默抑制。tmux 3.3 引入了 `-x`/`-y` 的位置 clamping 與算術運算，因此選單能正確渲染。man page 明確指出：_「If the menu is too large to fit on the terminal, it is not displayed.」_
2. **選單過高是另一種失敗模式。** `display-menu` 不會分頁。即使在 tmux 3.6+ 上，一個 50 列的扁平選單在低於約 50 行的終端機（手機 SSH、半畫面分割等）也會靜默開啟失敗 — 沒有錯誤、沒有日誌。已透過腳本驅動、依高度分層的方式修復：腳本讀取 `#{client_height}`，並輸出三組分層之一，使頂層選單永不超過約 14 列。較低頻的項目移入子選單。完整除錯故事：[`pitfalls/tmux-display-menu-silent-fail.md`](../../../pitfalls/tmux-display-menu-silent-fail.md)。

ansible `devtools` role 現在會檢查 tmux 版本，當低於 3.3 時自動升級：

1. **存在 Linuxbrew** → `brew install tmux`（最新穩定版）。
2. **無 Linuxbrew、x86_64 Linux** → 下載 [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage)，解壓到 `~/.local/share/tmux-appimage/squashfs-root/`（不需 FUSE），並在 `~/.local/bin/tmux` 安裝一個 shim 以 exec 內附二進位檔。`~/.local/bin` 在 PATH 中位於 `/usr/bin` 之前，因此較新的二進位檔勝出。
3. **無 Linuxbrew、非 x86_64**（如 armv7l、aarch64 伺服器且無 brew）→ ansible 會印出警告；請從原始碼編譯或啟用 Linuxbrew。

### 將執行中的伺服器切換到新二進位檔

升級後，現有的 tmux 伺服器仍會執行舊二進位檔（執行中的 process 不會因 PATH 改變而 re-exec）。連到同一個 socket 的客戶端 (client) 也會留在舊版本。要切換過去：

```bash
# 失去現有 sessions，但取得乾淨的 3.3+ 伺服器
tmux kill-server

# 或：在新 socket 上啟動新伺服器，並手動遷移 sessions
tmux -L new new-session -s work
```

以 `tmux -V`（二進位版本）以及 tmux 內 format string 中的 `#{version}`（伺服器版本）驗證。

### Terminfo (`missing or unsuitable terminal`)

若 `tmux attach` 失敗並出現 `missing or unsuitable terminal: <name>`，代表該主機缺少對應你外層終端機所宣告 `$TERM` 的 terminfo 條目（在最小化 Ubuntu、Docker images、剛開好的伺服器上常見 — 基本 ncurses 只附 `xterm`、`vt100`、`linux`…）。

在 Debian/Ubuntu 上，`devtools` role 現在會在 tmux 基線旁額外安裝 [`ncurses-term`](https://packages.ubuntu.com/jammy/ncurses-term)，加入 `tmux-256color`、`alacritty`、`ghostty`、`rxvt-unicode-256color`、`screen-256color` 等條目。macOS 預設即附帶完整目錄。

若你無法安裝該套件（例如在受限主機上的 `noRoot` 模式），備援方案：

```bash
# 快速測試 — 挑一個已存在的 terminfo
TERM=xterm-256color tmux a

# 使用者層級安裝：透過 SSH 將本機的 terminfo 條目複製過去
infocmp -x | ssh remote -- tic -x -
# 落於 ~/.terminfo/，不需要 sudo
```

## OSC 52 剪貼簿（SSH 友善的 yank）

跨層級的完整說明（terminal ↔ tmux ↔ Neovim ↔ `x` CLI）：詳見 [**clipboard.md**](../clipboard.md)。以下為 tmux 提供部分的摘要：

[`common.conf`](../../../dot_config/tmux/common.conf) 內的 `set-clipboard on` + `allow-passthrough on` 讓 tmux 能將內層 TUI 發出的 OSC 52 escape 序列轉送至外層終端機模擬器，因此 yank 即使在 SSH 環境下也能抵達本機剪貼簿。同一檔案為 `xterm*`、`ghostty*`、`alacritty*` 宣告 `clipboard` terminal-feature，使 tmux 不需要 terminfo 中的 `Ms` 條目即可發送 OSC 52。

擷取窗格 (capture-pane) 的輔助快捷鍵（[`keybindings.conf`](../../../dot_config/tmux/keybindings.conf) 中的 `prefix + y` / `Y` / `C-y`）透過 `tmux load-buffer -w -` 而非 `pbcopy`/`xclip` 傳送，因此在 SSH 下也能運作（`-w` flag 會讓 tmux 在 paste buffer 之外，亦透過 OSC 52 轉送 buffer）。

Neovim 端在 [`dot_config/nvim/lua/config/options.lua`](../../../dot_config/nvim/lua/config/options.lua) 中對應設定：當 `SSH_CONNECTION`/`SSH_TTY` 被設定時，`vim.g.clipboard` 會覆寫為 `vim.ui.clipboard.osc52`（Neovim 0.10 起內建）。本機 sessions 仍維持預設的 `pbcopy`/`xclip` provider，使 paste 能正常運作。

### 驗證設定是否生效

```bash
# tmux 應回報目前 client 支援 clipboard
tmux info | grep -Ei 'clipboard|Ms:'
# 預期看到：clipboard: true，且 Ms 條目「不是」[missing]

# 在 Neovim 內
:checkhealth provider.clipboard
# 在 SSH 下，預期 OSC 52 provider 啟用
```

如果編輯 `common.conf` 後 `tmux info` 仍顯示 `Ms: [missing]` 且 yank 失敗，那是因為執行中的 tmux 伺服器仍保留舊的 capability table。執行 `tmux kill-server`（會失去 sessions — `tmux-resurrect` 可恢復）後重新 attach。

終端機支援度：

| 終端機 | OSC 52 寫入 | OSC 52 讀取 |
|----------|--------------|-------------|
| Ghostty / cmux | 支援（`clipboard-write = allow`，於 `dot_config/ghostty/config` 明確設定） | 會詢問 (`clipboard-read = ask`) |
| Alacritty | 原生支援 | 不支援 |
| iTerm2 | 支援 | 需於偏好設定中啟用 |
| kitty / WezTerm | 支援 | 支援 |

因此透過 OSC 52 從系統剪貼簿 paste 為盡力而為；yank 才是可靠的方向。如果遠端 paste 比遠端 yank 更重要，請使用 SSH 的 `LocalForward`/`ForwardAgent` 工作流，或專用的剪貼簿橋接工具（如 `lemonade`）。

## 捲動歷史 (Scrollback) 與 Coding Agents

串流式 TUI（Claude Code、OpenCode、Codex）會透過 ANSI 序列重繪同一塊螢幕區域。在**替代螢幕 (alternate screen)** 上（vim、htop、Claude Code 互動會話）tmux 的捲動歷史不受影響 — alt-screen 有自己的 buffer。在**主螢幕 (main screen)** 上（部分 agents、即時進度條、`cargo build` 帶 ASCII 狀態），預設情況下每一幀 (frame) 都可能被推入歷史，產生重影/重複行，使捲動回看相較於原生終端機看起來像壞掉了。

兩個設定加上一個工作流可保持乾淨：

- `set -g scroll-on-clear off`（位於 [`common.conf`](../../../dot_config/tmux/common.conf)）— 在全螢幕清除 (ED) 時直接丟棄清除前內容，而非推入歷史。tmux 3.3 起預設為 `on`。
- `history-limit 50000` — 已設定；即使整天的 agent sessions 也綽綽有餘。
- **捲動前先凍結畫面**：`prefix + [` 進入複製模式，會快照當前畫面。捲動滾輪或使用 `C-u` / `C-d` 時，UI 不會在你下方繼續重繪。`q` 退出。

關於為什麼這無法被「進一步修好」（ANSI 重繪 + 線性捲動歷史本質上即有失真）的 pitfall 等級說明，詳見 [`pitfalls/tmux-scrollback-tui-repaint-ghosting.md`](../../../pitfalls/tmux-scrollback-tui-repaint-ghosting.md)。

## OSC 133 命令邊界導航（Warp 風格）

[`dot_config/zsh/tools/02_shell_integration.zsh`](../../../dot_config/zsh/tools/02_shell_integration.zsh) 透過 `add-zsh-hook precmd` / `preexec` 發送 [OSC 133 prompt 標記](https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md)（A = prompt 開始，C = command output 開始，D = output 結束 + exit code）。可乾淨地與 starship / zsh-vi-mode / oh-my-zsh 鏈結 — 無 precmd 覆蓋。tmux 3.4+ 會解析這些標記，並在複製模式中提供導航，加上一鍵「複製最後輸出」：

| 鍵位 | 情境 | 動作 |
|---|---|---|
| `{` / `}` | 複製模式 | 跳到上一個 / 下一個 **prompt** 行 |
| `Alt+[` / `Alt+]` | 複製模式 | 跳到上一個 / 下一個 **command output** 起始（prompt 之後的那一行）|
| `prefix + M-y` | 頂層 | 將**最後一條命令的輸出**複製到剪貼簿（Warp 風格一鍵）|
| `prefix + M-i` | 頂層 | 將**最後一條命令的輸入行**（prompt + 輸入的命令）複製到剪貼簿 |

`prefix + M-i` 會複製整行 prompt，因為我們刻意不發送 B 標記（詳見 [`02_shell_integration.zsh`](../../../dot_config/zsh/tools/02_shell_integration.zsh) 底部的註記）— 所以剪貼簿內容會像是 `❯ echo hi` 而非僅 `echo hi`。如有需要，請在貼上的目標處自行修剪。

shell 層級的等價指令位於 [`03_tmux_capture.zsh`](../../../dot_config/zsh/tools/03_tmux_capture.zsh) — 可在 prompt 直接執行、可串接 pipe（`cpout | grep ERROR`），並會以副作用 (side effect) 複製到剪貼簿。每個指令都接受可選的位置參數 `N`，代表「倒數第 N 條命令」（預設 1）：

| 命令 | 等同於 | 複製內容 |
|---|---|---|
| `cpout [N]` | `prefix + M-y`（N=1）| 倒數第 N 條命令的輸出 |
| `cpcmd [N]` | `prefix + M-i`（N=1）| 倒數第 N 條命令的輸入行 |
| `cpblock [N]` | — | 倒數第 N 條命令的完整區塊（prompt + 輸入 + 輸出）|

## 透過 AI agents 回顧過去命令

AI 包裝器 — `aifix` / `aiexplain` 加上 `aiblock` TUI — 會將擷取的區塊以非互動建議模式 pipe 給 coding-agent CLI（Claude Code / OpenCode / Codex / Cursor Agent）。模型預設值、prettify/metadata/spinner 開關、獨立安裝（不需 chezmoi）以及疑難排解皆收錄於專屬使用者指南：

- [`docs/tools/aicapture.md`](../aicapture.md) — 單頁說明，可分享給任何想試用工具的人
- [`docs/this_repo/instant-llm-fix-prior-art.md`](../../this_repo/instant-llm-fix-prior-art.md) — 該層相對於 `thefuck`、Warp、`wut`/`tmuxai`、`butterfish`、`atuin` 與 OSC 133 終端機的定位

依 shell 個別停用 OSC 133：在啟動 zsh 之前 `export DISABLE_OSC133=1`。當標記不存在時，複製模式中的綁定會自動成為 no-op — **包含在加入該 hook 的那次 `chezmoi apply` 之前就已啟動的 shell**（重新載入 tmux config 不會 re-source zsh；請在受影響的窗格中執行 `exec zsh` 或開新窗格）。前置 hook shell 的症狀：`prefix + M-y` / `M-i` 顯示成功訊息但貼上為空。可用 `echo $precmd_functions | tr ' ' '\n' | grep osc133` 驗證。

## 重新載入設定

大多數變更不需要重啟伺服器。

```bash
tmux source-file ~/.tmux.conf
```

或在 tmux 內：`prefix + R`（重新載入後會顯示確認訊息）。

如果某個變更仍行為異常，請先嘗試新窗格/新視窗 (window)。只有當終端 capability 或外掛初始化問題明顯能跨越重新載入時，才使用 `tmux kill-server` — 例如切換主題時殘留的樣式。

## Exit 與 Detach

- `prefix + d` — detach 當前 client，session 仍持續執行
- `exit` — 關閉當前 shell；最後一個窗格退出時，session 結束
- `prefix + :` 然後 `kill-session` — 立即終止當前 session
- `tmux kill-server` — 終止所有 sessions 並停止伺服器

已設定 `detach-on-destroy off`，因此當你終止某個 session 時，若還有其他 sessions 存在，tmux 會切換到另一個而非 detach。

## Prefix 鍵

預設：`Ctrl + b`。同層其他文件中的範例皆假設 `prefix = Ctrl + b`。

## 外掛

| 外掛 | 用途 |
|--------|---------|
| `tmux-resurrect` | 跨 tmux 重啟保存／還原 sessions |
| `tmux-continuum` | 自動保存 sessions |
| `tmux-floax` | 浮動暫存窗格（`prefix+F` 切換、`prefix+P` 選單）|
| `tmux-fzf` | 模糊挑選 keybindings/sessions/windows/panes（`prefix+?`，從 list-keys 改綁）|
| `tmux-fzf-url` | `prefix+u` 開啟 fzf 彈出視窗，列出窗格中所有 URL |
| `extrakto` | `prefix+Tab` fzf 彈窗，萃取路徑/URL/字詞（Enter=複製、Tab=插入、Ctrl-f=切換 filter）|
| `tmux-open` | 在複製模式中：`o` 打開選取項、`C-o` 在編輯器中打開、`S` 搜尋 |
| `catppuccin/tmux` | 狀態列主題（mocha，頂部）— 預設 |
| `tmux2k` | 狀態列主題（onedark，底部）— 替代方案 |

由 TPM 管理；`prefix + I` 安裝、`prefix + U` 更新。

## 驗證目前設定

```bash
ls ~/.config/tmux/
tmux display-message -p '#{@theme_variant}'
tmux list-keys -T prefix
tmux show-options -s | rg 'extended-keys|extended-keys-format|default-terminal'
tmux show-options -g | rg 'status|focus-events'
```

## 相關文件

- [Sesh](../sesh.md)
- [Starship](../starship.md)
- [XDG Base Directory](../xdg.md) — 為何設定檔放在 `~/.config/tmux/` 而不是 `~/.tmux.conf`
