# tv vs fzf — 比較與最佳實踐

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

兩個模糊比對 (fuzzy finder) 工具，兩種哲學。本 dotfiles repo **兩個都用**。

| | **fzf** | **television (tv)** |
|---|---------|---------------------|
| 哲學 | 低階模糊比對基本元件；以 shell 膠水 (glue) 組合工作流 | 結構化選擇器 (picker) 框架；工作流以 TOML 頻道 (channel) 宣告 |
| 比喻 | Unix pipe 構件 | 終端機原生版 Telescope.nvim |
| 比對引擎 (matcher) | 自訂的成熟引擎（多年實戰驗證） | [nucleo](https://github.com/helix-editor/nucleo)（與 Helix 共用） |
| 查詢語法 | fuzzy、exact (`'`)、prefix (`^`)、suffix (`$`)、inverse (`!`)、**OR** (`\|`) | fuzzy、exact、prefix、suffix、substring、negate — 不支援 OR |
| 擴充性 | Shell 腳本、環境變數、`--bind`、`--preview`、`--reload` | `cable/` 目錄中的 TOML 頻道檔 |
| Shell 整合 | `Ctrl+R` / `Ctrl+T` / `Alt+C` + `**<TAB>` 補全 | `Ctrl+R` / `Ctrl+T` 配合情境感知的頻道觸發 |
| 排序控制 | `--tiebreak`、`--sort`、`--no-sort` | 每個頻道的 `no_sort`、`frecency` |
| 多選 | `--multi` + Tab/Shift-Tab | 內建 |
| 預覽 (preview) | `--preview` flag（任意指令） | 頻道 TOML 中的 `[preview]` 區段 |
| 選取後動作 (action) | `--bind 'enter:execute(...)'` | `[actions]` 區段；fork/execute 模式 |
| 生態系成熟度 | 龐大：vim、tmux、zsh、bash、fish、git、kubectl 等 | 成長中；第三方整合較少 |
| 本 repo 中的設定 | `dot_config/zsh/tools/10_fzf.zsh` | `dot_config/television/cable/*.toml` |

## 何時使用何者（在本 dotfiles repo 中）

| 使用情境 | 工具 | 原因 |
|----------|------|-----|
| Shell 歷史 (`Ctrl+R`) | fzf | 排序模式更多、可用 `FZF_CTRL_R_OPTS` 客製 |
| 檔案選擇器 (`Ctrl+T`) | fzf | 深度補全整合、`**<TAB>` |
| 目錄 cd (`Alt+C`) | fzf | 內建、簡單 |
| Tab 補全預覽 | fzf | `_fzf_comprun` 可針對個別指令做預覽 |
| Sesh session 選擇器 | tv | 頻道支援來源 (source) 循環（tmux/zoxide/config/fd）、預覽、kill 動作 |
| CLI 工具選擇器 | tv | 解析 `cli-tools.md` 的頻道，預覽用 tldr |
| Aliases 選擇器 | tv | 列出所有執行期 aliases/functions 的頻道 |
| Git 分支切換 | tv | 含預覽 + checkout 動作的頻道 |
| 自訂領域選擇器 | tv | 宣告式 TOML 頻道比寫 shell 包裝快得多 |

## 「Telescope 風格工作流」說明

這個模式（由 [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) 推廣）：

```
來源 → 過濾/排序 → 預覽 → 動作
```

你用**同一個選擇器 UI** 搭配**不同的資料來源**。每個選擇器（頻道）定義要搜尋什麼、如何預覽、有哪些動作可用。你不需要切換思考模型 — 只需切換頻道。

tv 原生實作了這個模式：`cable/` 中的每個 `.toml` 檔就是一份頻道食譜。

## 頻道 / Cable 最佳實踐

### 1. 一個頻道 = 一件工作

別建巨型頻道。讓每個頻道專注：

- `files` — 找檔案
- `text` — grep 內容
- `git-branches` — 切換分支
- `dirs` — 透過 zoxide/fd 進行 cd
- `history` — shell 歷史
- `tools` — CLI 工具參考

### 2. 來源應乾淨且穩定

`[source]` 會執行 shell 指令。請保持：

- **機器友善的輸出** — 一行一筆、格式可預測
- **輕量** — 不做沉重格式化；交給 `display` / `output` / `preview` 來呈現
- **針對同一事物的變體使用來源循環**（例如：`fd -t f` 對比 `fd -t f -H` 顯示隱藏檔）

原則：只循環共用相同思考模型的來源。「檔案 vs 隱藏檔」 = 好。「檔案 vs docker containers」 = 壞。

### 3. 預覽是工作流的靈魂

好的預覽能將體驗從「盲選」轉為「帶情境瀏覽」：

| 頻道 | 預覽指令 |
|---------|----------------|
| files | `bat --color=always {}` |
| text/grep | `bat --color=always --highlight-line {line} {file}` |
| git branches | `git log --oneline --graph {}` |
| git log | `git show {}` |
| docker images | `docker inspect {} \| jq` |
| tools | `tldr {}` 或 `{} --help` |

### 4. 動作要少且一致

每個頻道定義：

| 按鍵 | 角色 | 範例 |
|-----|------|---------|
| `Enter` | 主要動作 | 開啟、連線、執行 |
| `Ctrl+E` | 編輯 | `$EDITOR {}` |
| `Ctrl+Y` | 拉取/複製 | 複製到剪貼簿 (clipboard) |
| `Ctrl+X` | 破壞性動作 | 殺掉 session、刪除 |
| `Ctrl+/` | 切換預覽 | 內建 |

### 5. 對時序資料保留原始順序

對 shell 歷史、git log 等時序來源：

- 設 `no_sort = true` 以保留來源順序
- 設 `frecency = false` 以停用以頻率為基礎的排名

你想要的是「最近的指令」，不是「6 個月前模糊分數最高的指令」。

### 6. 使用 shell 整合觸發

tv 的 shell 整合可偵測目前的指令前綴並自動選擇頻道：

```toml
# 在 shell_integration 設定中
[channel_triggers]
"git checkout" = "git-branches"
"git switch"   = "git-branches"
"cd"           = "dirs"
"ls"           = "dirs"
"vim"          = "files"
"nvim"         = "files"
"cat"          = "files"
"bat"          = "files"
"export"       = "env"
"unset"        = "env"
```

這把 shell 提示符變成**情境感知的選擇器入口**。

## Cable 組織方式

### 依資料類型（建議大多數人採用）

```
cable/
├── files.toml
├── text.toml
├── dirs.toml
├── git-branches.toml
├── git-log.toml
├── env.toml
├── history.toml
├── sesh.toml
└── tools.toml
```

### 依工作情境（適合專案密集型工作流）

```
cable/
├── code-files.toml
├── code-grep.toml
├── code-symbols.toml
├── repo-switch.toml
├── notes.toml
├── infra-docker.toml
└── infra-k8s.toml
```

## 實務比較表

| 情境 | fzf 做法 | tv 做法 |
|----------|-------------|-------------|
| 找專案檔案 | `fd -t f \| fzf --preview 'bat {}'` | `tv files`（內建頻道） |
| Grep repo 內容 | `rg --line-number foo \| fzf --preview 'bat ...'` | `tv text`（內建頻道） |
| 切換 git 分支 | `git branch \| fzf \| xargs git checkout` | `tv git-branches` → Enter 直接 checkout |
| Shell 歷史 | `Ctrl+R`（fzf 內建，可用 `Ctrl+R` 切換排序） | `Ctrl+R`（tv shell 整合） |
| Tab 補全 | `ssh **<TAB>`、`kill **<TAB>`、自訂 `_fzf_complete_*` | 不支援 — 僅 fzf 提供 |
| Session 管理 | `sesh list \| fzf-tmux`（本 repo 中為 Alt+S） | `tv sesh` 含來源循環（prefix+T） |
| tmux 中的 URL 選擇器 | `prefix + u`（tmux-fzf-url） | 不適用 — fzf 外掛 |
| 自訂工具查詢 | Alt+T（fzf ZLE widget） | `tv tools` / `tv aliases` |

## 總結

> **fzf** = 成熟的基礎建設基本元件。在 shell 整合深度、查詢語法、生態系上無人能敵。
>
> **tv** = 現代工作流框架。開箱即用的頻道/預覽/動作打包更佳，需要的 shell 膠水更少。
>
> 模糊比對品質：相當。查詢語法：fzf 運算子較多（特別是 OR）。Shell 補全：僅 fzf 支援。

兩者都用。讓 fzf 主管 shell 原生整合（`Ctrl+R`、`Ctrl+T`、`Alt+C`、`**<TAB>`）。讓 tv 主管結構化選擇器發光發熱之處（sesh、tools、aliases、領域特定工作流）。

## 社群頻道 vs 自訂頻道

tv 內附一大批 [社群維護的頻道](https://alexpasmantier.github.io/television/community/channels-unix)，涵蓋 files、dirs、env、git（branch/log/diff/stash/tags/worktrees/remotes/submodules）、docker（containers/images/volumes/networks/compose）、k8s、brew、cargo、GitHub PR/issues、systemd journal 等。

安裝/更新社群頻道：

```bash
tv update-channels
```

這會把頻道下載到 `~/.config/television/cable/`，跳過你系統上不滿足需求的頻道，也跳過已存在的頻道（不會覆蓋你的自訂頻道）。

### 我們有沒有重新發明輪子？

| 我們的頻道 | 社群對等品 | 評估 |
|---|---|---|
| `sesh.toml` | `sesh.toml`（社群） | **退役** — 社群版邏輯已追上。我方版本保留為 `sesh.toml.reference` 供參考；`tv update-channels` 會提供啟用版本。 |
| `tools.toml` | 無 | **獨有** — 解析我方 `cli-tools.md`，無對等品 |
| `aliases.toml` | `alias.toml` | **超集** — 社群版很簡陋（`$SHELL -ic 'alias'`、無 functions、無動作）。我方加上透過 `typeset -f` 列出的 functions、格式化欄位、執行動作、複製到剪貼簿 |

**結論：重複極少。** `sesh.toml` 已退役改用社群版。另外兩個自訂頻道無對等品或大幅延伸了社群版本。

### 值得採用的社群頻道

執行 `tv update-channels` 後，這些已即可使用（不需手動設定）。特別實用的有：

| 頻道 | 用途 |
|---------|-------------|
| `git-branch` | 分支選擇器，含 checkout/delete/merge/rebase 動作 |
| `git-log` | Commit log，含 cherry-pick/revert/checkout |
| `git-stash` | Stash 瀏覽器，含 apply/pop/drop |
| `git-diff` | 變更檔案，含 stage/restore/edit |
| `brew-packages` | Homebrew formula/cask 列表，含 upgrade/uninstall |
| `docker-containers` | Container 管理，含 start/stop/logs/exec/remove |
| `docker-images` | Image 選擇器，含 run/shell/remove |
| `dirs` | 透過 fd 的目錄選擇器（可用來源循環切換顯示隱藏） |
| `files` | 透過 fd + bat 預覽的檔案選擇器（可切換顯示隱藏） |
| `env` | 環境變數瀏覽器 |
| `dotfiles` | 用 bat 預覽 `~/.config` 檔案 + 編輯動作 |
| `gh-issues` / `gh-prs` | GitHub issue/PR 選擇器，含豐富預覽 |
| `just-recipes` | Justfile recipe 選擇器，含預覽 + 執行 |

要寫自訂頻道，請在 `dot_config/television/cable/` 中建立 `.toml` 檔（透過 chezmoi 部署）。自訂頻道不會被 `tv update-channels` 覆寫。TOML 格式請見 [channel 規格 (spec)](https://alexpasmantier.github.io/television/reference/channel-spec)。

## 另見

- [fzf 快速參考](fzf.md)
- [tv 快速參考](tv.md)
- [鍵盤快速鍵](../keyboard-shortcuts.md)
