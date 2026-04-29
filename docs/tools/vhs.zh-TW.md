# VHS — 終端機示範錄影器

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[charmbracelet/vhs](https://github.com/charmbracelet/vhs) 從 `.tape` 腳本錄製終端機 (terminal) 工作階段為 GIF / MP4 / WebM。它在虛擬終端機裡 headless 重放你輸入的指令，產出可重現、可檢閱的成品 — 適合 README demo、bug 重現、PR 審查輔助。

- **安裝**：
  - macOS — Homebrew（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 macOS 列表管理）。在 macOS 上，Homebrew 也會自動把 `ttyd` 與 `ffmpeg` 當作 runtime 相依拉進來。
  - Linux — 從 GitHub release tarball 安裝到 `~/.local/bin/vhs`（由 `dot_ansible/roles/devtools/tasks/main.yml` 的 `# --- vhs (Charm) ---` 區塊管理）。**`ttyd` 與 `ffmpeg` 兩個 runtime 相依不會自動安裝** — 見下方 [Linux runtime 相依](#linux-runtime)。
- **驗證**：`vhs --version`
- **目前在這個 repo 的狀態**：已安裝、還沒有 `.tape` 檔。要錄影時放到 `docs/_demos/*.tape`。

---

## Hello world

```bash
cat <<'TAPE' > /tmp/hello.tape
Output /tmp/hello.gif
Set FontSize 18
Set Width 800
Set Height 400
Type "echo Hello, VHS"
Enter
Sleep 1s
TAPE

vhs /tmp/hello.tape
file /tmp/hello.gif    # → GIF image data
```

任意圖片瀏覽器打開 GIF（macOS 用 `open`、Linux 用 `xdg-open`，或拖到 Slack / PR 描述）。

---

## <a name="linux-runtime"></a>Linux runtime 相依

`vhs` 在內部呼叫 `ttyd`（web-based PTY）與 `ffmpeg`（影片編碼器）。這兩者在 Linux 上通常缺席 — 在每台會錄影的 host 上手動裝一次：

```bash
# Ubuntu / Debian
sudo apt install ffmpeg
# ttyd 在預設 repo 沒有 .deb — 用預編譯 static binary：
curl -L "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.$(uname -m)" \
  -o ~/.local/bin/ttyd && chmod +x ~/.local/bin/ttyd

# 驗證
ttyd --version
ffmpeg -version | head -1
```

ansible role 刻意不自動裝這兩個 — `ffmpeg` 是肥相依（傳遞 50+ MB），`ttyd` 又不是每個支援的 Ubuntu 版本都有乾淨的 apt 路徑。錄影是 opt-in，所以相依也是 opt-in。

如果 `vhs` 跑了但產出 0 byte 的檔案，幾乎都是缺 `ttyd` 或 `ffmpeg`。`vhs --help` 列出它預期的路徑。

---

## `.tape` 腳本入門

`.tape` 是一個指令的扁平列表。重點：

```text
# 輸出目標 (一個檔一個)
Output demo.gif
# Output demo.webm    # 也支援
# Output frames/      # 倒出個別 PNG frame

# 設定 (套用整個 tape)
Set Shell zsh
Set FontSize 16
Set FontFamily "MonoLisa, JetBrainsMono Nerd Font"
Set Theme "Catppuccin Mocha"
Set Width 1200
Set Height 600
Set Padding 20
Set TypingSpeed 50ms
Set PlaybackSpeed 1.0
Set LoopOffset 0%

# 隱藏設定指令 (照樣輸入但不顯示)
Hide
Type "cd ~/scratch && clear"
Enter
Show

# 可見互動
Type "ls -la"
Enter
Sleep 1s

Type "echo waiting"
Enter
Sleep 500ms

# 按特殊鍵
Ctrl+C
Backspace 5
Enter
Tab
Escape

# 等待 prompt 符合 regex 才繼續 (vhs ≥ 0.7)
Wait /\$\s$/
```

完整參考：`vhs --help` 與上游 `examples/` 目錄。

---

## 錄真實工作流程的範本

展示這個 repo 實際在做的事情（例如 `fleet-apply`）的骨架：

```text
# docs/_demos/fleet-apply.tape
Output fleet-apply.gif
Set Shell zsh
Set FontSize 16
Set Theme "Catppuccin Mocha"
Set Width 1400
Set Height 800
Set TypingSpeed 60ms

Hide
Type "cd ~/.local/share/chezmoi && clear"
Enter
Show

Type "just fleet-apply --status"
Enter
Sleep 3s

Type "just fleet-apply"
Enter
Sleep 8s

Type 'q'    # 離開 watch view
```

接著 commit `.tape`（小、可審）與渲染出的 `.gif`（大但 PR diff 可看）。tape 要保持確定性 — 除非 demo 的重點就是這個，否則避免會打網路或時鐘的指令。

---

## tape 放哪

這個 repo 還沒成型的慣例。錄第一個的時候，建議的版面：

```
docs/_demos/
  fleet-apply.tape
  fleet-apply.gif
  sesh-tmux.tape
  sesh-tmux.gif
```

底線前綴避免混進 MkDocs nav。在 doc 頁中嵌入用一般 markdown 圖片：

```markdown
![fleet-apply demo](../_demos/fleet-apply.gif)
```

如果 GIF 太大（> 5 MB），改成 `Output demo.mp4` 並用 raw HTML 嵌入 — 大部分瀏覽器在 markdown viewer 中能 inline 播 MP4，且檔案通常小 3–10 倍。

---

## 提示

- **可重現錄影** — 釘住 `Set TypingSpeed`、`Set PlaybackSpeed`，避開依賴 wall-clock 的指令。兩次 `vhs run X.tape` 應該產生 byte-identical 的輸出。
- **Catppuccin 主題** — `Set Theme "Catppuccin Mocha"` 與這個 repo 的 tmux / starship 美學一致。
- **`vhs serve`** — 在本地跑 HTTP UI 迭代 tape。省去 `vhs file && open file.gif` 的來回。
- **CI 渲染** — 把 `.tape` 當 source-of-truth，需要時在 CI 重新渲染 `.gif`。這個 repo 目前沒這樣做；要做的話 CI image 要有 `ffmpeg` + `ttyd`。
- **不要錄機密** — `vhs` 抓的是螢幕上的東西；用 `Hide` 包住 `cat ~/.env` 或會印 token 的 `gh auth status`。

---

## 另見

- [Glow](glow.md)、[Gum](gum.md)、[Freeze](freeze.md) — 其餘 Charm CLI 生態系
- [Freeze](freeze.md) — **靜態**程式碼/輸出截圖；GIF 殺雞用牛刀時用它
