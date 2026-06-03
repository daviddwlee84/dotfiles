# Sesh - 智慧型 Tmux 會話管理員

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[Sesh](https://github.com/joshmedeski/sesh) 是一個 CLI 工具，使用 zoxide 管理 tmux 會話 (session)，讓你能即時存取最常用的專案，並提供智慧型會話命名、啟動指令 (startup command) 與預覽 (preview) 功能。

## 安裝 (Installation)

Sesh 由 `devtools` ansible role 自動安裝：

- **macOS**：`brew install sesh`
- **Linux**：GitHub release 二進位檔 → `~/.local/bin/sesh`

執行 `chezmoi apply` 後不需手動安裝。

## 快捷鍵 (Keybindings)

### ZSH (`Alt+S`)

在 shell 中任何位置按 `Alt+S` 即可開啟 sesh 選擇器 (picker)。此功能使用 `fzf-tmux` 作為彈出視窗 (popup)，並支援完整的過濾功能。

來源：`~/.config/zsh/tools/22_sesh.zsh`

### ZSH 輔助函式 (Helpers)

託管的 zsh 設定提供四個 shell 輔助函式，每個有不同的「重量等級」，讓你可以針對當下情境挑選合適的工具：

| 指令 | 重量 | 使用時機 | 會話名稱 |
|---------|--------|-------------|--------------|
| `shere` | 純 shell | 臨時 cd：只想在 `$PWD` 開一個 tmux 會話，不需要編輯器、不需要排版 | `<basename>` |
| `sroot` | sesh 預設行為 | 想在 git 根目錄套用 sesh 的萬用字元 (wildcard) / `default_session` 行為 | 由 sesh 決定 (`dir_length=2`) |
| `scode` | 重量級 | 「為**此**儲存庫開啟 coding-agent 排版」——nvim 75% \| `specstory run` 25% + btop 視窗 | `coding-agent/<repo>` |
| `svibe` | 最重量級 | 「Vibe coding」——N 個並排的 agent 窗格 (pane) + lazygit + nvim | `vibe/<repo>` |

底層函式分別為 `sesh-here` / `sesh-root` / `sesh-code` / `sesh-vibe`；如果你偏好函式名而非別名 (alias)，可以直接呼叫它們。

#### `shere` — 在 `$PWD` 開純 shell

刻意設計為輕量級：建立一個以目錄 basename 命名的 tmux 會話，把你丟進 shell，**不會**觸發 sesh 的 `default_session.startup_command`（nvim）或任何萬用字元排版。當你 cd 到某個臨時目錄、只想要會話的持久性時使用它。

```bash
shere                          # 在 $PWD 開純 shell 會話
shere npm run dev              # 會話執行 `npm run dev` 而非 shell
shere -c "specstory run"       # 明確使用 --command flag
shere -p ~/some/dir            # 明確指定路徑；-p + 純參數也可以
```

> **行為變更 (2026-04)**：`shere` 過去會繼承 sesh 的預設 startup_command，因此會開啟 nvim。它被改名為「輕量級會話」，因為重量級的編輯器優先工作流程現在改由 `scode` 負責。如果你想要舊行為，請使用 `sroot`（會遵循 sesh 的萬用字元/預設值），或直接呼叫 `sesh connect "$PWD"`。

#### `sroot` — git 根目錄搭配 sesh 預設行為

連結 (attach) 到目前 git 儲存庫的最上層（若不在儲存庫中則是 `$PWD`），並遵循整份 sesh.toml：萬用字元排版（例如 `/Volumes/Data/Program/*/*` 自動套用 `project.yaml`）、`default_session.startup_command` 等。如果你一直在自訂 sesh.toml 並希望那些自訂內容生效，這就是正確選擇。

```bash
sroot                          # 連結到 git 根目錄，由 sesh.toml 決定排版
sroot specstory run codex      # 明確指定指令覆寫
```

#### `scode` — 範圍限定於儲存庫的 coding-agent 排版

`scode` 建立**以目前儲存庫命名**的會話，因此不同儲存庫不再會在單一的 `coding-agent` 會話名稱上互撞。這正是舊版 `sesh connect coding-agent` 工作流程最大的痛點：從另一個儲存庫第二次呼叫時，會靜默地重用既存的會話，但它指向**錯誤的**儲存庫。

```bash
scode                          # 目前儲存庫，預設 agent（specstory → claude）
scode codex                    # 右側窗格執行 `specstory run codex`
scode opencode                 # 右側窗格直接執行 `opencode`（尚未是 specstory provider）
scode --no-specstory claude    # 右側窗格直接執行 `claude`（不自動儲存 markdown）
scode --on-exit kill claude    # Ctrl+C 會關閉右側窗格（vs 預設：掉回 shell）
scode --on-exit restart codex  # codex 在崩潰時自動重啟
scode -p ~/work/foo            # 明確指定儲存庫路徑
scode --no-attach              # 在背景建立會話，不切換過去
scode -h                       # 說明
```

排版（視窗 (window) 1「editor」）：

```
┌─────────────────────────────┬──────────────┐
│ nvim                        │ specstory    │
│ (75% width)                 │ run [agent]  │
│                             │ (25% width)  │
└─────────────────────────────┴──────────────┘
```

視窗 2「monitor」：`btop`（若無則退回 `htop` / `top`）。

**在 git 儲存庫之外會被拒絕** — 如果你不在儲存庫中，你不會想要這個重量級的排版。請使用 `shere` 開純 shell，或在你真的想在非儲存庫目錄中使用 vibe 排版時用 `svibe`（svibe 同樣要求是儲存庫，因為缺少 git 上下文時 vibe 排版更沒意義）。

##### Agent 包裝（自動，使用 `--no-specstory` 退出）

| 參數 | 右側窗格指令 |
|----------|--------------------|
| （無） | `specstory run`（預設使用 claude 並自動儲存 md） |
| `claude` / `codex` / `cursor` / `droid` / `gemini` | `specstory run <name>`（已知的 specstory provider） |
| `opencode` 與其他未知 CLI | 直接執行該執行檔 |
| 任何 agent + `--no-specstory` | 直接執行該執行檔（raw） |

> `opencode` 目前是 raw 執行，因為 specstory 上游尚未支援它作為 provider。追蹤於
> [`backlog/specstory-opencode-support.md`](../../backlog/specstory-opencode-support.md)
> — 等到 `specstoryai/getspecstory#156` 合併之後，`_sesh_wrap_agent` 中的 case
> 語句只需更新一行，opencode 就會加入自動包裝清單。

##### `--on-exit` 模式

當排版中**任何**窗格指令結束時（`scode` 中的 agent、nvim、btop；`svibe` 中的 agent、lazygit、nvim）會發生什麼——不論是正常離開、Ctrl+C 或崩潰：

| 模式 | 行為 |
|------|----------|
| `shell`（預設） | 窗格印出黃色提示並掉進 `$SHELL`。你可以重新啟動指令（提示會顯示確切的呼叫方式）、切換視窗，或手動關閉窗格。在指令未執行時，每個窗格會多花一個背景 `$SHELL` 程序。 |
| `kill` | 指令結束時窗格/視窗關閉。這是歷史上 / tmux 的預設行為。 |
| `restart` | 將指令包在 `while true; do CMD \|\| true; sleep 1; done` 中。連按兩次 Ctrl+C 可以中斷迴圈並掉到 shell。在反覆迭代某個容易崩潰的工具時很有用。 |

> `shell` 預設拿每個窗格一個背景程序的代價，換取大幅更好的可恢復性——舊版 `coding-agent` 工作流程最常被回報的痛點是「我在 agent 中按了 Ctrl+C，結果窗格沒了，連 75/25 的排版也沒了」；同樣情況也適用於不小心 `:q` 退出 nvim 或關閉 btop/lazygit。

> 此 flag 統一套用於排版中每一個執行指令的窗格——沒有逐個介面分別覆寫的選項。如果你希望例如 lazygit 退出時就死掉，但 agent 退出時掉回 shell，請提交功能需求。

##### 僅支援單一 agent

`scode` 在設計上是單一 agent。如果你想要多個 agent 並行，請使用 `svibe --agents …`。對 `scode` 傳入 `--agents` 會錯誤並提示切換到 `svibe`。

> `sesh.toml` 中舊有的 `coding-agent` 命名會話**為了向後相容而保留**（仍會出現在 sesh 選擇器中，仍可用 `sesh connect coding-agent` 呼叫），但 `scode` 是建議的進入點。詳見 sesh.toml 中標註 "DEPRECATED" 的註解區塊。

#### `svibe` — 參數化的多 agent vibe 排版

直接以 tmux 腳本實作（不使用 tmuxp），因為窗格數量是參數化的，而 tmuxp YAML 無法表達這點。

有兩種方式指定要執行哪些 agent：

```bash
# 同質性（位置參數）：所有窗格執行同一個 agent
svibe                                            # N 個自動挑選 × claude（見下文）
svibe 2                                          # 2× claude
svibe 4 codex                                    # 4× codex
svibe 6 opencode                                 # 6× opencode（重量級——建議搭配大顯示器）

# 異質性（--agents）：每個窗格一個項目，清單長度 = 窗格數
svibe --agents claude,codex,codex,opencode       # 4 個窗格、混搭
svibe --agents claude,opencode                   # 2 個窗格、混搭
svibe --agents 'claude, codex, opencode'         # 逗號旁邊允許空白

# 其他 flag（兩種模式皆可用）
svibe --on-exit kill 4 claude                    # Ctrl+C 關閉窗格
svibe --on-exit restart --agents codex,opencode  # 自動重啟迴圈
svibe --no-specstory 4 claude                    # 4× raw claude（不自動儲存 markdown）
svibe --min-width 120                            # 較寬的窗格 → 自動欄數較少
svibe -p ~/repo --agents claude,codex            # 明確指定路徑
svibe -h                                         # 說明
```

混合使用位置參數 `[N] [CLI]` 與 `--agents` 會被**拒絕**，以保持語意明確——擇一即可。

##### 依寬度自適應的預設值

當省略 `N` 時，**窗格數**及**它們的排版方式**都是依目前終端機 (terminal) 寬度 ÷ 最小寬度門檻推導出來的。

| 旋鈕 | 預設值 | 覆寫方式 |
|------|---------|----------|
| `min_width`（欄數） | `80` | 環境變數 `SVIBE_MIN_WIDTH` 或 flag `--min-width COLS` |
| `term_width`（欄數） | `$COLUMNS`，若無則退回 `tput cols` | （在呼叫時讀取） |

- **自動 N**（當位置參數 `N` 與 `--agents` 都未提供時）：
  `N = clamp(term_width / min_width, 1, 12)`。所以在 240 欄的終端機上：
  `min-width 80` → `N=3`；`min-width 120` → `N=2`；`min-width 60` → `N=4`。
- **agents 視窗排版**：若所有 `N` 個窗格能以 `≥ min_width` 並排放下，使用 `even-horizontal`（N 欄）。否則退回 `tiled`（網格）。如果你想要不同的呈現方式，可以按 `prefix + Space` 互動式循環切換 tmux 內建的排版。

排版（3 個視窗）：

```
window 1 "agents"    — N 個 agent 窗格（若全部以 ≥min-width 並排則為欄、
                       否則為 tiled 網格；允許混搭 agent）
window 2 "git"       — lazygit（或退回 `git status`）
window 3 "edit"      — nvim
```

窗格數量限制在 `[1, 12]`。超過約 6 之後 tiled 網格在多數顯示器上就太擠了——上限是保守、非技術性的。

##### 啟動錯開（同時啟動多個 agent）

`svibe` 在啟動每個 agent 窗格之間會等待一小段間隔，讓那些在冷啟動時共用同一全域資源的 agent 不會互搶。觸發此設計的案例：`opencode` 會開啟單一全域 SQLite 資料庫（`~/.local/share/opencode/`）並執行 `PRAGMA journal_mode = WAL`，這需要短暫的獨占鎖——若以零延遲執行 `svibe 4 opencode`，其中一個實例會搶不到鎖而以 `Failed to run the query 'PRAGMA journal_mode = WAL'` 退出。

| 旋鈕 | 預設值 | 覆寫方式 |
|------|---------|----------|
| 啟動錯開（秒） | `0.25` | 環境變數 `SVIBE_LAUNCH_STAGGER`（接受 `0` 或小數） |

```bash
SVIBE_LAUNCH_STAGGER=0.4 svibe 4 opencode   # 留更多餘裕
SVIBE_LAUNCH_STAGGER=0   svibe 4 claude      # 一次啟動所有窗格
```

##### 驗證（fail-fast）

`svibe` 在建立任何東西之前先驗證：

1. `--agents` 與位置參數 `[N] [CLI]` 不能同時設定
2. `--on-exit` 必須是 `shell` / `kill` / `restart`
3. 窗格數必須在 `[1, 12]` 範圍內
4. 必須在 git 儲存庫中
5. 清單中**每一個** agent CLI 都必須存在於 `$PATH`

這避免了若採取逐窗格驗證會出現的「4 個窗格中有一個靜默死掉」失敗模式。

##### `--no-specstory` 與 `--on-exit`

語意與 `scode` 相同。包裝是**逐窗格**的，所以你可以自由地讓 opencode（raw）與 claude（specstory 包裝）混合：

```bash
# 3 個窗格——opencode raw、claude 包裝、codex 包裝，全部共用 --on-exit shell
svibe --agents opencode,claude,codex
```

與 `scode` 一樣，`svibe` 在 git 儲存庫之外會被拒絕。如果要在任意目錄中開純 shell，請使用 `shere`。

### 在四個之間挑選

決策樹：

```
你在 git 儲存庫中嗎？
├── 否  → shere（純 shell）或 sroot（如果想要 sesh 預設值）
└── 是  → 你想要排版嗎？
          ├── 否                         → shere 或 sroot
          ├── 單一編輯器 + 側欄          → scode
          └── 多個並行 agent             → svibe
```

四者都是冪等 (idempotent) 的：以同樣的目標重新呼叫時會連結到既存的會話，而不會建立重複的會話。

### tmux

所有快捷鍵都使用 tmux prefix（預設 `Ctrl+B`）。

| 快捷鍵 | 動作 |
|------------|--------|
| `prefix + g` | 開啟 sesh 選擇器彈出視窗（fzf 帶預覽、圖示、過濾） |
| `prefix + T` | 透過 television (tv) 在 tmux 彈出視窗中開啟 sesh 選擇器 |
| `prefix + O` | 在 tmux 彈出視窗中開啟 sesh 內建選擇器 |
| `prefix + W` | 開啟 sesh 視窗選擇器 (fzf) -- 切換或建立 tmux 視窗 |
| `prefix + S` | 切換到上一個會話（透過 `sesh last`） |
| `prefix + 9` | 跳到目前 git 儲存庫/worktree 的根目錄 |

來源：`~/.tmux.conf`

`prefix + g` 不依賴 `Shift`，所以在某些無法可靠回報大寫 prefix 綁定的終端機上，不會穿透到 tmux 內建的 `prefix + t` 時鐘捷徑。

### 選擇器快捷鍵（fzf 彈出視窗內）

| 按鍵 | 動作 |
|-----|--------|
| `Ctrl+A` | 顯示所有會話 |
| `Ctrl+T` | 過濾：僅 tmux 會話 |
| `Ctrl+G` | 過濾：僅已設定的會話 |
| `Ctrl+X` | 過濾：僅 zoxide 目錄 |
| `Ctrl+F` | 過濾：尋找目錄 (`fd`) |
| `Ctrl+D` | 終止選取的 tmux 會話 |
| `Tab` / `Shift+Tab` | 向下/向上瀏覽 |

## Shell 自動補全 (Shell Completion)

`sesh` 子指令與 flag 的 ZSH tab 自動補全會在首次載入時自動生成到 `~/.zfunc/_sesh`（並在 sesh 版本變動時重新生成）。這遵循專案的[補全慣例](zsh/zsh-completions.md)。

手動重新生成：

```bash
sesh completion zsh > ~/.zfunc/_sesh
rm -f ~/.zcompdump && compinit
```

## 設定 (Configuration)

設定檔：`~/.config/sesh/sesh.toml`（由 chezmoi 託管）

### Schema 自動補全

設定檔包含 JSON Schema 指示，讓編輯器透過 [taplo](https://taplo.tamasfe.dev/) 提供自動補全：

```toml
#:schema https://github.com/joshmedeski/sesh/raw/main/sesh.schema.json
```

### 主要選項

| 選項 | 說明 |
|--------|-------------|
| `sort_order` | 會話類型顯示順序：`tmux`、`config`、`tmuxinator`、`zoxide` |
| `dir_length` | 會話名稱中的目錄層級數（預設：1） |
| `blacklist` | 要從選擇器隱藏的正規表達式樣式 |
| `cache` | 啟用 stale-while-revalidate 快取（實驗性） |

### 預設會話 (Default Session)

套用至所有會話，除非被覆寫：

```toml
[default_session]
startup_command = "nvim"
preview_command = "eza --all --git --icons --color=always {}"
```

- `startup_command`：建立新會話時執行
- `preview_command`：顯示在 fzf 預覽窗格（`{}` = 會話路徑）

### 命名會話 (Named Sessions)

以自訂名稱與指令釘住常用目錄：

```toml
[[session]]
name = "chezmoi"
path = "~/.local/share/chezmoi"
tmuxinator = "chezmoi"    # 委派給 tmuxinator 以可靠地建立多視窗

[[session]]
name = "home"
path = "~"
disable_startup_command = true
```

可用欄位：`name`、`path`、`startup_command`、`preview_command`、`disable_startup_command`、`windows`。

### 萬用字元會話 (Wildcard Sessions)

對符合 glob 樣式的目錄套用設定：

```toml
[[wildcard]]
pattern = "~/repos/*"
startup_command = "nvim"
```

- `*` 比對一層、`**` 遞迴比對
- 明確的 `[[session]]` 項目優先於萬用字元

#### 透過 tmuxp `--append` 設定每個專案的排版

對於受益於結構化排版（editor / shell / lazygit 視窗）的儲存庫，萬用字元可以在 sesh 建立的純會話之上鏈式呼叫 `tmuxp load --append`。這與 `coding-agent` 命名會話用的是相同技巧——詳見[下方的方法 B](#approach-b-tmuxp-via-startup_command-active) 中的底層機制。

```toml
# /Volumes/Data/Program/<group>/<repo> 下的所有儲存庫
[[wildcard]]
pattern = "/Volumes/Data/Program/*/*"
startup_command = "cd {} && tmuxp load -a -y ~/.config/tmuxp/project.yaml && tmux kill-window -t :1 2>/dev/null; tmux select-window -t :editor 2>/dev/null"
```

`{}` 佔位符是匹配到的路徑。前置的 `cd {}` 是關鍵性的，並且與 yaml 中同樣關鍵性的**省略**配對：`project.yaml` 與 `coding-agent.yaml` 都不設定會話層級的 `start_directory`。每一個「看起來理所當然」的值都會在三種方式之一靜默故障——tmuxp 透過 Python 的 `os.path.expandvars` 解析 yaml 字串（沒有 bash 的 `${VAR:-default}` 退回機制）；tmuxp 把 `.` / `./foo` 解析成相對於 yaml **檔案**所在目錄（不是程序的 cwd）；當 libtmux 將上述任一結果傳給 `tmux new-window -c` 時，無效的路徑會靜默退回 `$HOME`。藉由完全省略 `start_directory`，libtmux 呼叫 `tmux new-window` 時不帶 `-c`，因此 tmux 會從呼叫者繼承 cwd——而 sesh 的 `send-keys` 會在已被 `cd {}` 移到匹配路徑的窗格內執行 tmuxp。完整的撰寫紀錄在 [pitfalls/tmuxp-append-ignores-session-start-directory.md](../../pitfalls/tmuxp-append-ignores-session-start-directory.md)。

附加 (append) 完成後，sesh 永遠會建立的初始空白視窗會被終止 (`-t :1`)，焦點會移到 `editor` 視窗，使 nvim 立即被前景化。

樣式針對的是 `/Volumes/Data/Program/*/*`（標準路徑，canonical paths），而非 `~/Documents/Program/*/*`，因為 zoxide 記錄的是標準路徑（詳見 [zoxide.md](zoxide.md) → `_ZO_RESOLVE_SYMLINKS`）。一個樣式同時涵蓋表面與標準兩種項目。

### 自訂多區塊預覽

預設的 `eza` 預覽只顯示檔案列表。[`~/.dotfiles/bin/sesh-preview`](../../dot_dotfiles/bin/executable_sesh-preview) 腳本在 fzf 預覽窗格中呈現更豐富的視圖：

1. **標頭**：目錄名、上層路徑、git branch + dirty 計數 + ahead/behind、mtime
2. **README**：前 25 行，若有 `bat` 則語法高亮
3. **最近提交**：最後 5 條 oneline 提交（僅 git 儲存庫）
4. **檔案樹**：`eza --tree --level=2`，忽略 build 目錄

在 `sesh.toml` 中接上：

```toml
[default_session]
preview_command = "~/.dotfiles/bin/sesh-preview {}"
```

若 `bat`/`eza` 不存在，會退回 `head`/`ls`；對非目錄參數也能優雅處理（sesh 有時會把原始的會話字串而非路徑交給選擇器）。輸出限制在約 50 行以內，避免 fzf 預覽窗格在第一次繪製時就需要捲動。

### 視窗 (Windows)

定義可重用的視窗排版：

```toml
[[session]]
name = "my-project"
path = "~/repos/my-project"
windows = ["git"]

[[window]]
name = "git"
startup_script = "lazygit"
```

## 建議的 tmux 設定

下列設定已在 `~/.tmux.conf` 中：

```
set -g detach-on-destroy off   # 關閉會話時保留在 tmux 中
bind-key x kill-pane           # 跳過 kill-pane 確認
```

## 與其他工具的整合

### fzf

Sesh 的主要選擇器整合。`fzf-tmux` 包裝在 tmux 彈出視窗內呈現 fzf。我們的設定使用 `--icons` 顯示 Nerd Font 字符，並用 `sesh preview` 提供預覽窗格。

### zoxide

Sesh 使用 zoxide 的 frecency 資料庫建議目錄。任何你 `cd` 過的目錄都會自動被追蹤，並出現在 `sesh list -z` 中。

`_ZO_RESOLVE_SYMLINKS=1`（在 [`zsh/tools/20_zoxide.zsh`](../../dot_config/zsh/tools/20_zoxide.zsh) 中設定）讓 zoxide 在儲存路徑前先標準化它們，因此符號連結 (symlink) 密集的設定（例如 `~/Documents/Program -> /Volumes/Data/Program`）不會把單一實體目錄的 frecency 切分到兩個幻影項目之間。Sesh 萬用字元應該針對標準樣式 (`/Volumes/Data/Program/*/*`)，而非表面的 symlink。

要為一個全新的資料庫播種 (bootstrap)、讓 sesh 立刻能呈現你想要的目錄（不必等待自然的 `cd` 流量），最簡單的做法是寫一個一次性的 Python 腳本，讀取二進位 `db.zo`（version 3 格式：`u32 ver, u64 count, then per-entry: u64 path_len, path bytes, f64 rank, u64 ts`），以 `rank=1.0` 插入新項目，再寫回去。分數較高的既存項目會被保留。範例工作流程如果之後該 pitfall 文件被建立，會放在 [pitfalls/zoxide-symlink-fragmentation.md](../../pitfalls/zoxide-symlink-fragmentation.md)。

### Neovim（編輯器內 zoxide 選擇器）

要在不離開 Neovim 的情況下在儲存庫之間跳轉，[`nvim/lua/plugins/zoxide-picker.lua`](../../dot_config/nvim/exact_plugins/zoxide-picker.lua) 在 `zoxide query --list --score` 之上加上一個 snacks.picker：

| Keymap | 動作 |
|--------|--------|
| `<leader>fz` | 挑選儲存庫，透過 `:tcd` 變更分頁本地 cwd |
| `<leader>fZ` | 挑選儲存庫，透過 `:cd` 變更全域 cwd |

預設使用 `:tcd`（分頁本地）以避免在你開著多個專案的緩衝區時，把 LazyVim 的專案根偵測搞混。當你真的想讓整個 nvim 會話跟著切換時，再用 `:cd`（`<leader>fZ`）。

### 三個專案選擇器比較

LazyVim 最終會有**三個重疊但不同**的專案跳轉進入點。挑選符合你意圖的那一個：

| 位置 | 觸發 | 來源 | 作用 |
|-------|---------|--------|--------------|
| nvim 內 | `<leader>fp`（或 dashboard `p`） | `snacks.picker.projects` — oldfiles 的 git 根 + 在 `dev` 目錄上跑 `fd` | `:tcd` + `persistence.nvim` 還原（該 cwd 上次的 buffer/視窗） |
| nvim 內 | `<leader>fz` / `<leader>fZ` | 完整的 zoxide 資料庫（frecency，100+ 項目） | 純 `:tcd` / `:cd`，不還原會話 |
| tmux 內 | `prefix + g`（sesh fzf） | tmux + sesh.toml + zoxide | 切換/建立 tmux 會話，重新開啟 nvim + lazygit |

粗略的判斷準則：

- **已在 nvim 中、想瞄一下另一個儲存庫的檔案** → `<leader>fz`
  （便宜、不需要會話儀式）
- **已在 nvim 中、想完整恢復另一個儲存庫的工作** →
  `<leader>fp`（還原你上次擁有的 buffer/視窗）
- **在 nvim 之外、想要乾淨的逐儲存庫工作空間** → 從 tmux 用 `prefix+g`
  （取得 `~/.config/tmuxp/project.yaml` 中定義的排版）

### 設定 snacks projects 選擇器

預設值會看 `~/dev` 與 `~/projects`（你的機器上大概不存在），加上從 oldfiles 推導出的 git 根。要讓 `<leader>fp` 呈現你的專案首頁下的每一個儲存庫，把它加入 `dev`——
[`projects.lua`](../../dot_config/nvim/exact_plugins/projects.lua) 為 `/Volumes/Data/Program` 做了這件事：

```lua
{
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        projects = {
          dev = { "/Volumes/Data/Program" },  -- 標準路徑，不是 symlink
          max_depth = 2,                       -- 抓到 <group>/<repo>
        },
      },
    },
  },
}
```

要**手動釘選**沒有 `.git` 的專案（或不論 `fd` 探索結果都希望永久呈現），把 `projects` 設成路徑清單：

```lua
projects = {
  vim.fn.expand("~/.local/share/chezmoi"),
  vim.fn.expand("~/.config/nvim"),
  "/Volumes/Data/Program/Personal/some-repo",
},
```

`dev`（透過 `fd` 自動探索）與 `projects`（手動清單）兩者都會在 fzf 渲染前與 oldfiles 項目合併。Snacks 會依路徑去重。

`confirm = "load_session"` 預設委派給 `persistence.nvim`（同樣在 `projects.lua` 中接好）；它會還原該 cwd 上次的 buffer/視窗排版。如果未安裝 `persistence.nvim`，`load_session` 會靜默退回到 `:tcd` 之後開啟檔案選擇器。

### Television (tv)

[Television](https://github.com/alexpasmantier/television) 內建 [sesh channel](https://alexpasmantier.github.io/television/community/channels-unix/#sesh)。Television 由 `devtools` ansible role 安裝（macOS 上 `brew install television`；Linux 上有 Linuxbrew 時使用，否則跳過並警告，因為上游目前只發佈 `unknown-linux-gnu` 二進位檔，需要 glibc ≥ 2.39——與 Ubuntu 22.04 LTS 不相容。詳見 [docs/linux-package-sources.md](../linux-package-sources.md)）。

**tmux 快捷鍵：** `prefix + T` 在 tmux 彈出視窗中開啟 television 的 sesh channel。

```
bind-key "T" display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' Sesh (tv) ' "tv sesh"
```

使用 `Ctrl-s` 在來源（all、tmux、config、zoxide、fd）之間循環切換，`Ctrl-d` 終止反白的會話。

`~/.config/television/cable/sesh.toml` 中的自訂 cable channel 設定覆寫了內建 channel，提供更豐富的來源循環與符合我們 fzf 選擇器設定的動作。

### Raycast (macOS)

[sesh Raycast 擴充套件](https://www.raycast.com/joshmedeski/sesh) 在終端機之外提供 GUI 形式的會話切換。

## 自訂技巧

1. **加入專案會話**：編輯 `~/.config/sesh/sesh.toml`（透過 `chezmoi edit ~/.config/sesh/sesh.toml`）以釘住最常用的專案。

2. **monorepo 萬用字元**：使用 `pattern = "~/work/monorepo/packages/*"` 自動設定所有子專案。

3. **逐專案啟動**：將 `startup_command` 設定為自動啟動開發伺服器、編輯器或 TUI 工具。

4. **bat 預覽**：使用 `preview_command = "bat --color=always {}/README.md"` 在選擇器中顯示專案的 README。

5. **多重視窗**：定義 `[[window]]` 項目並在會話中參考它們，以建立多窗格排版（例如 editor + lazygit）。

## 窗格排版（進階）

### Sesh 的限制

Sesh **無法**原生建立窗格切割。每個 `[[window]]` 只能有一個窗格、一個 `startup_script`。沒有 `panes`、`layout`、`size` 或 `ratio` 設定。

如果你需要預先定義的窗格排版（例如「左窗格 = nvim 75%、右窗格 = specstory run 25%」），就必須使用外部工具。

### `tmuxp` 欄位是死碼（截至 sesh v2.24）

**重要**：`sesh.toml` 中的 `tmuxp` 欄位（出現在 `[[session]]` 與 `[default_session]`）有定義在 Go struct 與 JSON schema 中，但**從未被 sesh 原始碼讀取或使用**。只有 `tmuxinator` 有可運作的整合。

原始碼中的證據：
- `startup/config.go` 檢查 `Tmuxinator` 與 `StartupCommand`，但**沒有** `Tmuxp`
- `connector/connect.go` 有 `tmuxinatorStrategy`，但**沒有** `tmuxpStrategy`
- 在 sesh.toml 中設定 `tmuxp = "..."` 完全沒有作用——會話會穿透到 `default_session.startup_command`

### 方法 B：透過 `startup_command` 使用 tmuxp（採用中）

利用 sesh 的 `startup_command` 呼叫 `tmuxp load --append`，將 tmuxp YAML 的視窗附加到 sesh 建立的會話中，然後終止初始的空白視窗。

`sesh.toml` 設定：
```toml
[[session]]
name = "coding-agent"
path = "~"
startup_command = "cd ~ && tmuxp load -a -y ~/.config/tmuxp/coding-agent.yaml && tmux kill-window -t coding-agent:1"
```

（前置的 `cd ~` 是關鍵性的，理由與上方萬用字元章節描述的 tmuxp-append 機制相同。）

排版定義在 `~/.config/tmuxp/coding-agent.yaml`：
```yaml
session_name: coding-agent
windows:
  - window_name: editor
    layout: main-vertical
    options:
      main-pane-width: 75%    # 3:1 比例
    panes:
      - shell_command: nvim
      - shell_command: specstory run
  - window_name: monitor
    panes:
      - shell_command: btop
```

**運作方式：**
1. `sesh connect coding-agent` → sesh 在 `~` 建立名為 `coding-agent` 的 tmux 會話
2. `startup_command` 透過 `tmux send-keys` 在第一個窗格內執行
3. `tmuxp load -a -y` 將「editor」與「monitor」視窗附加到目前會話
4. `tmux kill-window -t coding-agent:1` 移除 sesh 建立的初始空白視窗

**優點：** tmuxp 已經安裝、宣告式 YAML、`--append` 避免會話衝突。
**缺點：** 空白視窗被終止時會短暫閃爍；`startup_command` 是 `send-keys`，因此對時序敏感。

**需要：** `tmuxp`（`pip install tmuxp` 或 `uv tool install tmuxp`）

### 方法 C：tmuxinator 原生整合（替代方案）

Sesh 對 tmuxinator 有完整原生支援。當 `tmuxinator` 欄位被設定時，sesh **跳過**自己的 `NewSession` + `startup.Exec`，完全委派給 `tmuxinator start`。

`sesh.toml` 設定：
```toml
[[session]]
name = "coding-agent"
path = "~"
tmuxinator = "coding-agent"
```

排版定義在 `~/.config/tmuxinator/coding-agent.yml`：
```yaml
name: coding-agent
root: <%= @settings["root"] || "~" %>
on_project_start: tmux set-window-option main-pane-width 75%
windows:
  - editor:
      layout: main-vertical
      panes:
        - nvim
        - specstory run
  - monitor:
      panes:
        - btop
```

**運作方式：**
1. `sesh connect coding-agent` → sesh 偵測到 `tmuxinator` 欄位
2. `connector/tmuxinator.go` 直接呼叫 `tmuxinator start coding-agent`
3. tmuxinator 建立整個會話，包括所有視窗與窗格
4. sesh 隨後切換/連結到該會話

**優點：** 整合最乾淨、沒有空白視窗的 hack、sesh 原生管理生命週期。
**缺點：** 需要 tmuxinator（`gem install tmuxinator`），有 Ruby 依賴。

**需要：** `tmuxinator`（由 `ruby_gem_tools` ansible role 安裝）

### 方法 A：純 shell 腳本（後備）

對於沒有 tmuxp 或 tmuxinator 的環境，使用原始的 tmux 指令：

```toml
[[session]]
name = "coding-agent"
path = "~"
startup_command = "tmux split-window -h -p 25 'specstory run' && tmux select-pane -L && tmux new-window -n monitor 'btop' && tmux select-window -t 1 && nvim"
```

**優點：** 零額外依賴。
**缺點：** 脆弱、難讀、難維護。

### 比較幾種方法

`coding-agent`（tmuxp）與 `coding-agent-mux`（tmuxinator）兩者都已在 `sesh.toml` 中設定，方便 A/B 比較：

```bash
sesh connect coding-agent       # 方法 B：tmuxp --append
sesh connect coding-agent-mux   # 方法 C：tmuxinator 原生
```

測試之後，保留偏好的那一個並移除/註解掉另一個。

## try + sesh 整合

[try-cli](https://github.com/tobi/try) 在 `~/src/tries/` 下建立短期的專案工作空間。一個 sesh 萬用字元會自動對任何 try 專案套用 `startup_command = "nvim"`。

### 用法

```bash
# 一步到位：開啟專案並啟動編碼會話
try-sesh some-project
try-sesh https://github.com/user/repo

# 兩步：先 try、再 sesh
try some-project
shere                    # sesh connect "$PWD"
```

`try-sesh` 函式（別名：`tsesh`）執行 `try` 然後立即 `sesh connect "$PWD"`。會話名稱遵循 `dir_length=2` 慣例：`tries/2026-04-14-some-project`。

來源：`~/.config/zsh/tools/32_try.zsh`

## 上游議題（tmuxp）

Sesh 的 `tmuxp` 設定欄位有記錄在 schema 與 README 中，但**並未在原始碼中實作**。相關上游議題：

- [#87 - Add tmuxp support](https://github.com/joshmedeski/sesh/issues/87) -- 加入 tmuxp 支援的功能需求。狀態：已關閉（在專案看板上標為「Done」），但實作只把欄位加到 config struct/schema，並未接到 connect/startup 邏輯中。
- [#198 - Built-in Window and Pane management](https://github.com/joshmedeski/sesh/issues/198) -- 要求原生窗格/視窗排版支援（避免 tmuxp/tmuxinator 依賴）。狀態：已關閉。Sesh v2.25 加入了基本的視窗支援，但仍無窗格切割。
- [#188 - startup_command sent too early](https://github.com/joshmedeski/sesh/issues/188) -- startup_command 在 shell 準備好之前就送出的 bug。狀態：開啟中。如果存在時序問題，這可能影響方法 B（`tmuxp load -a`）。

## 另見

- [`docs/tools/worktrunk.md`](worktrunk.md) — git-worktree 管理員 (`wt`)，
  位於 sesh 專案層之下的 **branch** 層。建議的三層心智模型是
  **sesh = 儲存庫、wt = 儲存庫內的 worktree、tmux = worktree 內的窗格**。
  詳見 [三層導覽](worktrunk.md#the-three-layer-navigation-sesh--wt--wtcd) 與
  [每個 worktree 一個 tmux 會話](worktrunk.md#tmux-session-per-worktree-and-how-it-interacts-with-scodesvibe)
  小節，了解 `scode`/`svibe` 與 `wt` 如何組合。

## 參考資料

- [sesh GitHub](https://github.com/joshmedeski/sesh)
- [Smart tmux sessions with sesh](https://www.youtube.com/watch?v=-yX3GjZfb5Y)（Josh Medeski）
- [DevOps Toolbox sesh review](https://www.youtube.com/watch?v=ejdzk_L6nIk)（Omer Hamerman）
- [joshmedeski/dotfiles sesh.toml](https://github.com/joshmedeski/dotfiles/blob/main/.config/sesh/sesh.toml)
- [omerxx/dotfiles television cable](https://github.com/omerxx/dotfiles/blob/master/television/cable/sesh.toml)
