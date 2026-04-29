# Glow — terminal Markdown 閱讀器

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[charmbracelet/glow](https://github.com/charmbracelet/glow) 在終端機 (terminal) 渲染 Markdown，支援語法高亮與分頁器 (pager)。在這個 repo 裡它驅動 tmux 提示卡片彈窗 (popup) 與 `readurl` / `readlocal` web reader pipeline。

- **安裝**：
  - macOS — Homebrew（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 macOS 列表管理）
  - Linux — 從 GitHub release tarball 安裝到 `~/.local/bin/glow`（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 `# --- glow ---` 區塊管理）
- **使用者**：
  - tmux popup 選單裡的 cheatsheet — `prefix + Space` → `?`（見 `dot_config/tmux/executable_menu.sh`）
  - Web reader pipeline — `readurl` / `readlocal` / `readnode` / `readraw`（見 [Web reader](web-reader.md)）
  - 當 stdout 是 markdown 形狀時，`aicapture` 用它渲染 agent 輸出

---

## 日常指令

```bash
# 開分頁器渲染檔案 (q 離開、j/k 捲動)
glow -p README.md

# 渲染遠端檔案
glow https://raw.githubusercontent.com/foo/bar/main/README.md

# 透過 pipe 渲染（不進分頁器，直接輸出）
echo '# hello\n- a\n- b' | glow

# 限制寬度給窄終端機
glow -w 80 README.md

# 明確選 style
glow -s dark README.md     # dark | light | notty | <path-to-json>
```

`-p` 用的是與 `bat` 類似的捲動鍵盤習慣，所以 `glow -p file.md` 對純文字最接近 `bat README.md` 的對應。

---

## 建議別名 (alias)

這個 repo 沒設全域 glow alias，因為各個呼叫點（tmux cheatsheet、web reader）已用對的 flag 直接呼叫。如要私人別名，加到不追蹤的 zsh fragment：

```bash
# ~/.config/zsh/tools/99_local.zsh (gitignored)
alias mdv='glow -p'
alias mdvw='glow -w "$(($(tput cols) - 4))" -p'
```

---

## 提示

- **TUI 模式** — `glow` 不帶任何參數會啟動目前目錄的 TUI 檔案瀏覽器；箭頭鍵移動，`Enter` 開啟。`glow -a` 也會列出 dotfiles。
- **Stash** — Charm 提供雲端 stash 收藏常讀文件。我們不用雲端側；要用的話 `glow stash add <file>`，列出用 `glow stash`。
- **Style 檔** — Glow 接受指向 JSON style 的路徑來完整主題化。tmux cheatsheet 倚賴預設的 dark style，在 Catppuccin 與 tmux2k 兩個 tmux 主題上都能用。
- **Fallback** — 當 `glow` 還沒安裝（例如新機器初始 bootstrap 階段）時，tmux 選單會 fallback 到 `less`。見 `dot_config/tmux/executable_menu.sh` 的 `Cheatsheet` 列、`glow … 2>/dev/null || less …` 的 pattern。

---

## 另見

- [Web reader](web-reader.md) — `readurl`、`readlocal`、`readnode`、`readraw`
- [tmux 概觀](tmux/README.md) — popup 選單與 cheatsheet
- [Gum](gum.md)、[VHS](vhs.md)、[Freeze](freeze.md) — 這個 repo 中其他的 Charm CLI 生態系
