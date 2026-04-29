# Freeze — 程式碼與終端機輸出 → 圖片

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[charmbracelet/freeze](https://github.com/charmbracelet/freeze) 把原始碼或任意終端機 (terminal) 輸出產出靜態圖片（PNG / SVG）。和 VHS（錄工作階段）不同，Freeze 是一次性快照 — 適合 issue 回報、部落格貼文、PR 縮圖。

- **安裝**：
  - macOS — Homebrew（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 macOS 列表管理）
  - Linux — 從 GitHub release tarball 安裝到 `~/.local/bin/freeze`（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 `# --- freeze (Charm) ---` 區塊管理）
- **驗證**：`freeze --version`
- **目前在這個 repo 的狀態**：已安裝、尚未使用 — 下次需要乾淨的程式碼截圖時拉進來。

---

## 兩種模式

```bash
# 1) 原始碼檔 → 圖片（用副檔名自動偵測語言）
freeze main.py --output code.png
freeze README.md --output readme.png

# 2) 終端機輸出 → 圖片 (-x 跑指令並抓 ANSI)
freeze --execute "ls -la" --output ls.png
freeze --execute "git log --oneline -n 10" --output gitlog.png
```

模式 1 是日常情境（漂亮程式碼貼到 Slack / Notion / 投影片）。模式 2 是當你就要那種終端機質感、ANSI 顏色全保留的時候用。

---

## 常用 flag

```bash
# 主題（Charm 內建約 50 個 — 詳 `freeze --help`）
freeze main.py -o code.png --theme "catppuccin-mocha"

# Window 裝飾（mac 風格紅綠燈）
freeze main.py -o code.png --window
freeze main.py -o code.png --window --border.radius 8 --shadow.blur 20

# 字型 + 大小
freeze main.py -o code.png --font.family "JetBrains Mono" --font.size 14

# 行號 + 範圍
freeze main.py -o code.png --show-line-numbers --lines 10,40

# 背景 + padding
freeze main.py -o code.png --background "#1E1E2E" --padding 30

# 多個一次出貨用 config 檔
freeze --config ~/.config/freeze/default.json main.py -o code.png
```

`freeze --help` 列出所有 flag；上游 README 有主題與 window 樣式的視覺長廊。

---

## 建議 config

存一份個人預設，每張截圖都有相同美學而不必噴 flag。沒給 `--config` 時 Charm 會自動讀 `~/.config/freeze/default.json`：

```jsonc
// ~/.config/freeze/default.json — 不由這個 repo 管理（私有）
{
  "theme": "catppuccin-mocha",
  "background": "#1E1E2E",
  "border": { "radius": 8, "thickness": 0 },
  "shadow": { "blur": 20, "x": 0, "y": 4 },
  "window": true,
  "padding": [20, 30],
  "margin": [0, 0],
  "font": { "family": "JetBrains Mono", "size": 14, "ligatures": true }
}
```

Catppuccin Mocha 與 repo 的 tmux/starship 預設主題一致。如果你切到 `tmux2k`，改成 `dracula` 或 `nord`。

---

## 用法 patterns

### Code review 縮圖

```bash
# 把改動的 hunk 拍起來當 PR cover image
git diff HEAD~1 -- src/foo.py | freeze --language diff -o /tmp/pr.png
```

### Issue 回報

```bash
# 把失敗指令 + traceback 烤成一張圖
freeze --execute "pytest tests/test_broken.py" -o /tmp/issue.png
```

`freeze --execute` 跑指令、抓帶 ANSI 顏色的 stdout 與 stderr，然後渲染。當 bug 重現是「這段彩色輸出不對」時很好用。

### 長檔的片段

```bash
freeze src/auth.py --lines 42,67 --show-line-numbers -o snippet.png
```

`--lines` 接逗號分隔的 `start,end`（1-indexed）。配合 `--show-line-numbers` 讓審查者能對照原檔。

### 部落格用 SVG

```bash
freeze main.py -o code.svg
```

SVG 輸出感知主題（透過 media query 切 light/dark）、無限縮放、通常比 PNG 小 5–10 倍。丟進 hugo / zola / jekyll，瀏覽器自己渲染。

---

## 在這個 repo 何處用得到（未來）

目前 repo 沒有 `freeze` 產生的圖。要加視覺文件時可能的位置：

- `docs/playbooks/linux-gui-apps.md` — decision-tree YAML 片段
- `docs/this_repo/upgrades.md` — `just upgrade` 範例輸出
- `docs/tools/aicapture.md` — `aifix` 呼叫帶高亮 prompt
- README — starship prompt / tmux status bar 的小張 SVG 片段

加的時候把原始 `.png` / `.svg` 與 doc 並列（例如 `docs/playbooks/linux-gui-apps.snippet.png`），用相對路徑引用。

---

## 提示

- **確定性** — 用 config 釘住字型、主題、padding，這樣同一段程式碼兩次截圖能 byte-identical。利於審查。
- **字型 fallback** — 指定的字型沒裝時，`freeze` 會靜默 fallback 到內建 monospace。若 config 引用 Nerd Font，請從 `dot_ansible/roles/fonts/` 安裝。
- **寬度控制** — 長行可能 wrap 或被截。用 `--width` 強制行數（如 `--width 100`）或先用 `fmt -w 100` 預處理。
- **不要拍機密** — `freeze --execute` 抓的是指令印出的東西。同 VHS 警告：跳過 `cat .env`，截圖前先 redact token。

---

## 另見

- [VHS](vhs.md) — **動態** demo（終端機 session → GIF / MP4）
- [Glow](glow.md)、[Gum](gum.md) — 其餘 Charm CLI 生態系
- [`bat`](https://github.com/sharkdp/bat) — 純終端機語法高亮輸出（不出圖）
