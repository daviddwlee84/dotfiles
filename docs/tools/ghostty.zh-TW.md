# Ghostty 與 cmux

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[Ghostty](https://ghostty.org/) 是一個快速、原生的終端機模擬器 (terminal emulator)。[cmux](https://cmux.dev/) 是一個建構在 `Ghostty` 之上、用於管理 AI 編碼代理 (coding agent) 的輕量 macOS 終端機。兩者讀取相同的設定檔。

## 受管理的設定檔

本 repo 透過 `dot_config/ghostty/config` 管理 `~/.config/ghostty/config`。`cmux` 會優先讀取此檔案（在 `~/Library/Application Support/com.mitchellh.ghostty/config` 之前）。

關鍵設定：

- **`macos-option-as-alt = left`** — 左 Option 送出 Meta/Esc+，讓 tmux 的 `M-` 鍵位 (keybinding) 能運作（主題切換 `M-c`/`M-t`、layout `M-1`..`M-5`、細部調整大小 `M-h/j/k/l`）。右 Option 保留 macOS 的 compose 行為，用於重音與特殊字元。
- **`font-features = -calt, -liga, -dlig`** — 停用連字 (ligatures) 以提高程式碼可讀性。

> **注意**：修改設定後請重新啟動 Ghostty/cmux——它在啟動時讀取設定，並非熱重載 (hot-reload)。

若沒有 `macos-option-as-alt`，macOS 的 Option 會產生 Unicode compose 字元（例如 `Option+c` → `ç`）而非 `Esc+c`，會無聲地讓所有 tmux Meta 綁定失效。`Alacritty` 與 `iTerm2` 各有等同的設定（分別為 `window.option_as_alt` 與 Profiles > Keys > Left Option Key > Esc+）。

## 遠端主機上的 `xterm-ghostty` terminfo

當您 SSH 進入一台全新的遠端時，`$TERM=xterm-ghostty`，但遠端沒有對應的 terminfo 條目。症狀：line-drawing 損壞、提示符 (prompt) 亂碼、`clear`/`tput` 失敗、Neovim 渲染異常。在第一次從 cmux/tmux SSH 進入新機器時尤為明顯。

### 選項 1 — Ghostty 內建（建議用於互動式 shell）

> - [Shell Integration - Features](https://ghostty.org/docs/features/shell-integration#ssh-integration)

加到 `~/.config/ghostty/config`：

```ini
shell-integration-features = ssh-env,ssh-terminfo
```

- `ssh-terminfo`：當您從載入了 Ghostty shell integration 的互動式 shell 第一次 `ssh` 時，會自動在遠端安裝 `xterm-ghostty`。
- `ssh-env`：透過 `SendEnv` 轉發 `COLORTERM`、`TERM_PROGRAM`、`TERM_PROGRAM_VERSION`，並在需要時退回 `TERM=xterm-256color`。遠端的 `sshd_config` 需要對應的 `AcceptEnv` 行，被轉發的變數才會生效。

**限制**：僅在啟用 Ghostty wrapper 的互動式 shell 中觸發。它涵蓋不到在 tmux/cmux pane 內、從腳本中或從 wrapper 工具（`rsync`、`aws`、`gcloud`、⋯）中呼叫的 `ssh`。對這些情況，請使用下方的手動 helper。

### 選項 2 — 手動 helper（任何情境皆可用）

zsh 函式 `ghostty-ssh-terminfo` 定義於 [`dot_config/zsh/10_aliases.zsh`](../../dot_config/zsh/10_aliases.zsh)。

```bash
ghostty-ssh-terminfo <ssh-host>
```

它做了什麼：

- 驗證本機 `infocmp` 與 `xterm-ghostty` 條目存在。
- 將 `infocmp -x xterm-ghostty` 透過**單一**SSH 呼叫管送過去（不會出現雙次密碼/MFA 提示）。
- 在遠端：探測 `tic`，建立 `~/.terminfo`，並執行 `TERMINFO="$HOME/.terminfo" tic -x -`——因此不需要 root/sudo。
- 只壓制無害的 `older tic versions may treat the description field as an alias` 警告（由 ncurses < 6.3 發出）。實際錯誤仍會浮現並設定非零的 exit。

範例：

```bash
# 第一次從 cmux/tmux 連線到新機器
ghostty-ssh-terminfo remote
# → Installed xterm-ghostty terminfo on remote (in ~/.terminfo)

# 驗證
ssh remote 'infocmp xterm-ghostty >/dev/null && echo ok'
```

### 對 `localhost` 的煙霧測試

可以——若本機正在執行 `sshd`，您不需要碰真實遠端就能驗證該函式：

```bash
# 啟用 sshd（Linux）
sudo systemctl start ssh
# 或 macOS：System Settings → General → Sharing → Remote Login

ghostty-ssh-terminfo localhost
```

注意事項：

- `localhost` 已經有您自己的 `$HOME`，所以實際上是寫到您本機 shell 也會讀的*同一個* `~/.terminfo`。當作配線 / 錯誤路徑的煙霧測試很有用，但不能代表「全新遠端」的真實檢查。
- 若您本機已有該條目（您一定有，否則 `infocmp -x xterm-ghostty` 會失敗），安裝就是 no-op 覆寫——但仍會端到端跑完整個 pipeline。
- 想做更乾淨的測試，請對著一個 `xterm-ghostty` 確定缺失的容器或 VM 來測。

## 為何會出現該警告（且無法在 client 端完全修復）

Ghostty terminfo 中以 `|` 分隔的長描述，在 6.3 版以前的 `tic` / ncurses 中會被解讀為額外的別名。條目仍會正確安裝；該警告只是外觀問題。唯一真正的修法是在遠端升級 ncurses。

## 圖片預覽（yazi）

Ghostty 與 cmux 支援 **Kitty graphics protocol**，因此 [yazi](yazi-previews.md) 對 png / jpg / pdf /
影片會顯示**清晰的行內圖片**（而非 chafa 的字元藝術）——不需設定，yazi 會自動偵測終端機。

小陷阱：非常大的圖片（很寬的圖表、高 DPI 截圖）可能在預覽窗格顯示 **`Image size exceeds limit`**。這是
yazi 的圖片*解碼*上限，**不是** Ghostty/cmux 的限制——本 repo 已在 `dot_config/yazi/yazi.toml` 調高
`[tasks] image_bound`；改完後執行 `yazi --clear-cache` 並重啟 yazi 才會生效。細節與終端機支援對照表：
[yazi-previews.md → Large images](yazi-previews.md#image-size-limit) /
[哪些終端機能顯示清晰圖片](yazi-previews.md#which-terminal-gets-crisp-images-vs-ascii-art)。
在 tmux 內，圖片 passthrough 需要 `allow-passthrough on`（在 `dot_config/tmux/common.conf.tmpl` 設定）。

## 另見

- [tmux](tmux.md) — tmux 設定與鍵位（cmux 在 tmux 之上運行）。
- [sesh](../sesh.md) — tmux 設定中所使用的工作階段選擇器 (session picker)。
