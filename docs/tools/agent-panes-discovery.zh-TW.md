# Agent pane 探索

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

尋找——並跳轉到——目前在本機**任何** tmux 窗格 (pane) 中執行的
coding-agent 工作階段（`claude`、`cursor-agent`、`codex`、`opencode`）。

它解決的痛點：你在 `chezmoi` 工作階段的 pane A 啟動了 `claude`，跳到另一個視窗的 pane B 做點快速測試，又飄到 `vibe/foo` 工作階段做 Codex 任務，三個視窗之後就忘了哪個窗格裡是你想要催的那個 agent。CodeIsland（macOS）能告訴你哪個**終端機應用**正在跑 agent，但無法指出特定的 tmux 窗格——一旦同一個終端機裡有多個 agent 就沒用了。

本 repo 提供兩個互補的介面，皆以 tmux 為後端：

| 工具 | 範圍 | 最擅長 |
|---|---|---|
| `tv agent-panes` | 全部四個 agent（Claude / Codex / OpenCode / Cursor） | 「我到底在哪邊跑東西？」跨 agent 總覽、跳轉到窗格 |
| `recon`（選用） | 僅 Claude，附即時狀態（Working / Idle / Waiting），由窗格擷取內容解析得出 | 「哪個 Claude 在等我？」——recon 的即時狀態偵測比我們在 tv 中重做的版本更豐富 |

## `tv agent-panes`（主要）

在 tmux 中以 `prefix + a` 開啟挑選器，或透過彈出選單
（`prefix + Space → → Agents → Live agent panes (tv)`），或從任何 shell
執行 `tv agent-panes`。

每一列代表一個正在執行的 agent 窗格。狀態欄會顯示 ●（忙碌）或
○（閒置），這是 Claude 的狀態（讀自 `~/.claude/sessions/{pid}.json`）；其他 agent 留空。

```
[cc] ● chezmoi:1.1     │  discover-coding-agent-sessions          │  chezmoi
[cc] ○ chezmoi:2.1     │  fix-nvm-lazy-loader-permission-request  │  chezmoi
[cc] ●  vibe/foo:4.1   │  refactor auth module                    │  foo
[oc]   vibe/bar:0.0    │  Generate migration script               │  bar
```

### 鍵綁定（在挑選器中）

| 按鍵 | 動作 |
|---|---|
| `Enter` / `Alt+T` | 將 tmux 焦點切換到該工作階段/視窗/窗格 |
| `Alt+K` | 殺掉該窗格（會 `[y/N]` 確認） |
| `Ctrl+Y` | 將窗格目標 (`session:win.pane`) 複製到剪貼簿 |
| `Alt+P` | 複製目錄路徑 |
| `Alt+R` | 複製工作階段 ID |
| `Alt+S` | 複製比對到的 `.specstory/history/*.md` 路徑 |
| `Ctrl+F` | 切換預覽：即時 `tmux capture-pane` 快照 ↔ 已存的 transcript |
| `Esc` | 關閉挑選器 |

### 解析 (resolution) 如何運作

- **Claude** — `Claude Code` 會在 `~/.claude/sessions/{claude_pid}.json`
  寫入每個行程 (process) 的檔案，內含 `sessionId`、`cwd`、
  `status`，以及（若有設定）友善的 `name`。探索 walker 會直接讀這些檔案——
  Claude 部分*完全沒有* heuristic。然後它會透過 `ps -o ppid=` 沿著每個
  `claude_pid` 的父行程鏈走，直到找到 tmux 的 `pane_pid`，這就提供了窗格目標。
- **Codex / OpenCode / Cursor** — `pgrep -x <bin>` 找到正在執行的 agent
  PID，父行程鏈以同樣方式走訪。工作階段 ID 採盡力 (best-effort) 模式：walker 會去查每個 agent 的儲存空間（`opencode.db`、`~/.codex/sessions`、
  `~/.cursor/chats`）尋找最近一筆 `cwd` 等於該窗格 `pane_current_path` 的工作階段。如果有多個工作階段共用同一個 cwd，最近更新的勝出。即使比對不到工作階段 ID，該窗格仍會列出——這一列即使只是用來跳轉到窗格也很有用。

## `recon`（僅 Claude 的快速彈出視窗，選用）

[`gavraz/recon`](https://github.com/gavraz/recon) 是一個 Rust TUI 儀表板，
專注於 `Claude Code`，但會留意即時的 agent 狀態，做法是透過
`tmux capture-pane` 解析 Claude TUI 的狀態列。當你同時在處理多個 Claude
工作階段、想一眼看出「誰被擋住等我？」時，值得留著它。

### 安裝

`chezmoi apply` 時會透過 `rust_cargo_tools` ansible 角色自動安裝：

```bash
cargo install --git https://github.com/gavraz/recon --locked
```

升級走標準 cargo 路徑：

```bash
just upgrade-cargo   # 或 scripts/upgrade_tools.sh cargo
```

### 使用

從彈出選單開啟它：`prefix + Space → → Agents → Claude
dashboard (recon)`。預設沒有頂層綁定——`prefix + g`（recon 上游預設）在本 repo 已被 sesh 挑選器佔用。如果你發現自己常用，可以在 `dot_config/tmux/keybindings.conf` 中升級為頂層綁定。

`→ Agents` 子選單只在 `recon` 在 `PATH` 上時才顯示這列，
所以在沒安裝它的主機上會乾淨地消失。

## 疑難排解

### 「我看不到我在執行的 Claude」

過時的 `~/.claude/sessions/{pid}.json` 檔案會被自動跳過——若 PID 不是任何 tmux 窗格的後代行程，該列就會被略過。如果你預期看到的工作階段沒出現：

```bash
~/.config/television/agent-sessions.py panes        # 原始 TSV，看看它找到什麼
ls -lt ~/.claude/sessions/                          # 存在哪些檔案
ps -p <pid_from_filename>                           # 該行程還在嗎
tmux list-panes -aF '#{pane_id} #{pane_pid} #{pane_current_command}'
```

如果 claude PID 還活著但 `_find_pane_for_pid` 沒能走到 tmux 窗格（例如 claude 是在 tmux 之外啟動的），該列被略過是正確的——`tv agent-panes` 只顯示你能 `switch-client` 到的窗格。

### 「Codex/OpenCode/Cursor 那列沒有工作階段 ID」

基於 cwd 的反向查找找不到 `directory` 與該窗格 `pane_current_path` 相符的已存工作階段。常見原因：agent 是用 `--cd` 指到不對應儲存的路徑啟動的；儲存被遷移過了。該窗格仍會出現——Enter 仍能跳轉到它；你只是拿不到自動「resume 同一工作階段」的把手。

### 「我跳到一個窗格，但 tmux 說它不存在」

挑選器是個快照。若窗格在快照與切換之間關閉，該動作會 fall back 為 `tmux display-message` 警告並停在原地。重新開啟挑選器（`prefix + a`）以更新。

### 「Recon 沒出現在 Agents 子選單」

`menu-agents.sh` 會探測 (probe) `command -v recon`，只在該 binary 在 `PATH` 上時加入該列。若你剛安裝它，你的 tmux server 可能需要新的 shell 環境——`tmux source ~/.tmux.conf` 就足夠了，不需重啟。

## 相關資源

- [tmux keybindings](tmux/keybindings.md) — 彈出選單介面
  （`prefix + Space`），其中 `→ Agents` 所在處，加上 `prefix + ?` 完整綁定圖。
- [Agent sessions browser](agent-overlays.md) — 姊妹頻道
  `tv agent-sessions`，瀏覽**已儲存的**工作階段歷史（resume 舊工作階段 vs. 跳轉到正在執行的）。
- [SpecStory internals](specstory-internals.md) — 解釋
  `<!-- Provider Session UUID -->` 反向查找，這讓挑選器能為每一列浮出比對到的 `.specstory/history/*.md`。
- 同類暫緩工作：在 tmux 視窗清單中標示每個窗格的工作中/閒置狀態符號（[`backlog/tmux-window-status-indicators.md`](https://github.com/daviddwlee84/dotfiles/blob/main/backlog/tmux-window-status-indicators.md) 的 Option C）。
