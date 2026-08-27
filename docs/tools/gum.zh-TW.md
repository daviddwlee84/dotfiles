# Gum — 給 shell script 用的 TUI prompt 工具箱

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[charmbracelet/gum](https://github.com/charmbracelet/gum) 是一個單一 binary 的 TUI 元件工具箱（`choose`、`input`、`confirm`、`spin`、`filter`、`format`、`style`、`write`、`pager`），專給 shell script 用。它把 Bubble Tea / Bubbles / Lip Gloss 那套 UI 包成 CLI，腳本不需要拖進 Go build 就能擁有精緻互動 UX。

- **安裝**：
  - macOS — Homebrew（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 macOS 列表管理）
  - Linux — 從 GitHub release tarball 安裝到 `~/.local/bin/gum`（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 `# --- gum (Charm) ---` 區塊管理）
- **驗證**：`gum --version`
- **目前在這個 repo 的狀態**：已接進 `ssh-setup-remote`（`dot_config/shell/96_ssh_setup.sh`）與 `media-pick`
  （`dot_config/shell/29_media.sh`），其餘仍在清單上。詳見下方「[未來改造可放的位置](#-future-refactors)」。

---

## 速查表

```bash
# 選一個
choice=$(gum choose --header "Pick action" "train" "test" "deploy")

# 多選（空白鍵切換、Enter 確認）
items=$(gum choose --no-limit --header "Pick keys to import" id_rsa github_key work_key)

# 自由文字輸入
name=$(gum input --placeholder "experiment name" --prompt "▸ ")

# 多行輸入
notes=$(gum write --placeholder "release notes (Ctrl+D when done)")

# 是非問句
gum confirm "Run now?" && ./run.sh

# 用模糊搜尋過濾清單（gum 風味的 fzf）
host=$(printf '%s\n' alpha beta gamma | gum filter --placeholder "host…")

# 在長指令外面包一個 spinner
gum spin --title "Building…" --spinner dot -- bash -c 'sleep 3 && echo done'

# 對獨立文字加樣式
gum style --foreground 212 --border double --padding "1 2" "Hello $USER"

# Inline 渲染 markdown / 程式碼
gum format -- "# Header" "" "- bullet **bold**"

# 翻頁長輸出 (less 的替代)
some-long-command | gum pager
```

`gum --help` 列出所有子命令；每個子命令都有自己的 `--help` 與所有 flag。

---

## 為什麼適合搭這個 dotfiles repo

- **不必寫 Bash 樣板** — 取代 `read -p` / `select` / 手寫選單，一行就處理鍵盤導覽、Esc 取消、合理預設。
- **單一靜態 binary** — macOS / Linux / WSL 透過 Homebrew 或 GitHub release 一致安裝；同樣的 script 到處能跑。
- **可與 pipe 組合** — 所有輸出都到 stdout，所以 `gum choose | xargs -I{} …` 直接接進現有 pipeline。
- **遵守 `NO_COLOR`** — stdout 不是 TTY 或設了 `NO_COLOR=1` 時自動退化為純文字輸出，腳本可以接 pipe 不會壞。

---

## 常見 patterns

### `gum choose` 取代會超出 tmux `display-menu` 的選單

tmux popup 選單 (`dot_config/tmux/executable_menu.sh`) 目前用 tier-based fallback 對抗 tmux「太高就靜默失敗」的 bug（見 `pitfalls/tmux-display-menu-silent-fail.md`）。`gum choose` 沒列數上限，不需要分層：

```bash
# 取代 `tmux display-menu -T '...' "Last window" Tab last-window …`
choice=$(gum choose --header "tmux menu" --height 20 \
  "Last window" "Last pane" "Choose window" "Choose session" \
  "Pane numbers" "Sesh picker" "Lazygit" "New window" \
  "Split |" "Split -" "Zoom" "→ Layouts" "→ Theme" "→ Cheatsheet")
case "$choice" in
  "Last window") tmux last-window ;;
  …
esac
```

### `gum confirm` 取代 `read -r yes_no`

```bash
# Before
read -r -p "Overwrite [y/N]? " ans
[[ "$ans" =~ ^[Yy] ]] && do_thing

# After
gum confirm --default=No "Overwrite?" && do_thing
```

### `gum spin` 把吵雜的長指令噪音壓下去

```bash
# 把慢指令的雜訊輸出藏在 spinner 後
gum spin --show-output --title "chezmoi apply" -- chezmoi apply -v
```

`--show-output` 讓 stdout 在 spinner 下繼續流；拿掉就完全壓制。

### `gum input --password` 處理機密

```bash
# 不回顯讀入；直接 pipe 到 sudo helper
gum input --password --placeholder "sudo password" \
  | install -m 0600 /dev/stdin /tmp/sudo-pass
```

### `gum filter` 當作一次性 picker 的 `fzf` 替代

ZLE 鍵綁定（`Ctrl+T`、`Ctrl+R`）還是用 `fzf` 比較對 — 它的 preview window 與 binding 系統更緊湊。`gum filter` 適合在已使用其他 gum 元件的腳本裡保持一致 Charm 風格時。

---

## <a name="-future-refactors"></a>未來改造可放的位置

下列 repo 中的位置是 gum 候選，但安裝這個 PR 裡刻意不動。下次因其他原因進到這些檔案時，可考慮替換：

| 檔案 | 目前 UX | gum 草稿 |
|---|---|---|
| `dot_config/tmux/executable_menu.sh` | tier-based `display-menu`（~14 列上限） | `gum choose --height N` |
| `dot_config/tmux/executable_menu-theme.sh` | 2 列 `display-menu` | `gum choose "catppuccin" "tmux2k"` |
| `scripts/import_ssh_to_bw.sh` | `read -r choice` + 手動解析 | `gum choose --no-limit` + `gum confirm` |

已經換過的，可以直接照抄：

| 檔案 | 做法 |
|---|---|
| `dot_config/shell/96_ssh_setup.sh` | 金鑰選擇用 `gum choose`，其餘提示用 `gum confirm` / `gum input`。三層防護：只有在有終端機時才用 gum、`SSH_SETUP_NO_GUM=1` 可停用、沒有 gum 時退回 bash `read -e` / zsh `vared`，方向鍵一樣能用。必須保持選用性——`tsnet --setup-remote` 會用單純的 `bash -c` source 這個檔案。 |
| `dot_config/shell/29_media.sh` | 用 `command -v gum` 包住 `gum file` / `gum choose` / `gum input`。 |
| `scripts/upgrade_tools.sh` | 只接 CLI 參數 | 沒帶參時 `gum choose --no-limit` 多選類別 |

不要批次重構 — 既有腳本都能用，且 tmux 整合有微妙的 invariant（見 `CLAUDE.md` →「Tmux ≥ 3.3 required for popup menu」）。一次改一個，且當你已因其他原因進到那個檔案時再做。

---

## 環境變數 / 樣式

Gum 讀 `GUM_*` 環境變數來全域設定預設值。常用：

```bash
# 在 ~/.config/zsh/tools/99_local.zsh (private)
export GUM_INPUT_CURSOR_FOREGROUND="#FF6188"
export GUM_INPUT_PROMPT_FOREGROUND="#A9DC76"
export GUM_CHOOSE_CURSOR_FOREGROUND="#FFD866"
```

完整列表：每個子命令的 `gum --help`。這個 repo 不出貨 gum 全域預設 — 留給使用者本地設定，這樣 SSH 到其他 host 時會繼承上游預設。

---

## 提示

- **取消** — `Esc` 取消並非零離開。永遠用 `set -o pipefail` 或檢查離開碼：`choice=$(gum choose …) || exit 0`。
- **空陣列** — `gum choose --no-limit` 沒選任何東西也是 0 離開、空 stdout。用 `[[ -n "$choice" ]] || exit 0` 守。
- **TTY 偵測** — gum 在 stdin 不是 TTY（例如在 pipe 裡）時自動關閉互動。測試時用 `--height` 並用 heredoc 預先餵 stdin。
- **在 tmux popup 裡** — `gum choose` 在 `tmux display-popup -E -- gum choose …` 內可以動。用 `-w 60% -h 60%` 設大小。

---

## 另見

- [Glow](glow.md)、[VHS](vhs.md)、[Freeze](freeze.md) — 其餘 Charm CLI 生態系
- [Fzf](fzf.md) — 既有的模糊搜尋器；互補、不取代
- [tmux 概觀](tmux/README.md) — popup 選單與 `display-menu` 高度限制
