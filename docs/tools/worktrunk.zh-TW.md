# Worktrunk —— Git Worktree 工作流程實戰手冊

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[Worktrunk](https://worktrunk.dev)（`wt`）是一個 git worktree 管理 CLI，
專為**並行 (parallel) 執行 AI coding agent** 而設計。本文是一份**工作流程實戰手冊**：
我在這套 dotfiles 環境下，搭配 `sesh` + `tmux` 實際使用它的方式。完整參考文件請見
[worktrunk.dev](https://worktrunk.dev)。

> **TL;DR**
> - 一個 repo → 多個 worktree，每個各自有分支 (branch)、各自有
>   agent／開發伺服器／資料庫。
> - `sesh` 選**專案**（每個專案一個 tmux session）。`wt` 在那個 repo 裡選
>   **worktree**。`wtcd` 用來偷看其他 worktree，但**不**改變 sesh／tmux。
> - 用 `wt step copy-ignored` 消除冷啟動 (cold-start)。用 `hash_port`
>   給每個 worktree 一個專屬開發伺服器埠號 (port)。用 `wt remove` ／
>   `wt merge` 的 hook 做清理。

## 目錄

- [心智模型](#心智模型)
- [本 repo 中的安裝與 shell 整合](#本-repo-中的安裝與-shell-整合)
- [三層導航：sesh + wt + wtcd](#三層導航sesh--wt--wtcd)
- [每個 worktree 一個 Claude／OpenCode](#每個-worktree-一個-claudeopencode)
- [每個 worktree 一個開發伺服器（`hash_port`）](#每個-worktree-一個開發伺服器hash_port)
- [每個 worktree 一個 tmux session（以及它如何與 `scode`／`svibe` 互動）](#每個-worktree-一個-tmux-session以及它如何與-scodesvibe-互動)
- [冷啟動消除](#冷啟動消除)
- [合併與清理流程](#合併與清理流程)
- [LLM commit message —— 何時值得用](#llm-commit-message--何時值得用)
- [尚未啟用的食譜](#尚未啟用的食譜)
- [交叉參考](#交叉參考)

---

## 心智模型

「我現在在做什麼？」可以拆成三個正交軸：

| 軸 | 工具 | 粒度 | 例子 |
|------|------|-------------|---------|
| **專案 (Project)** | `sesh`（`shere`／`sroot`／`scode`／`svibe`） | 每個 repo／目錄一個 | `coding-agent/dotfiles` |
| **分支 (Branch)** | `wt`（worktrunk） | 一個專案內每個並行任務一個 | `dotfiles.feat-x`、`dotfiles.fix-y` |
| **Pane** | `tmux` | 編輯器／agent／log／git | nvim ▏ claude ▏ btop |

沒有 worktrunk 時，同一個 repo 內並行的 agent 會互相干擾（checkout
衝突 (conflict)、`node_modules` 過期、開發伺服器 port 撞號）。有了
worktrunk，每個 agent 都有自己的 checkout 目錄 + 分支 +（可選）port +
（可選）DB，全部以**分支名稱**為 key。

本 repo 中**由 chezmoi 管理的
[`~/.config/worktrunk/config.toml`](../../dot_config/worktrunk/config.toml)**
刻意保持極簡 —— 只啟用 alias（`sw`／`ls`／`rm`／`cc`／`oc`）。Hook 與
LLM commit 都以註解形式提供作為 opt-in template。等到你在某個專案實際
碰到需求時再開啟，不要預先全開。

---

## 本 repo 中的安裝與 shell 整合

由 `devtools` ansible role 自動安裝：

- **macOS**：`brew install worktrunk`（Homebrew formula）。
- **Linux**：GitHub release 的 musl tar.xz → `~/.local/bin/wt`。Ansible
  task 會確保 `xz-utils` 已安裝，並從 `max-sixty/worktrunk` 下載
  `worktrunk-{x86_64,aarch64}-unknown-linux-musl.tar.xz`。Fallback 模式
  與 `sesh` 相同。

Shell 整合位於
[`dot_config/zsh/tools/37_worktrunk.zsh`](../../dot_config/zsh/tools/37_worktrunk.zsh)：

1. `eval "$(wt config shell init zsh)"` —— 將 `wt` 包成 zsh function，
   讓 `wt switch` 真的能對父 shell 做 `cd`。和 starship／zoxide／direnv
   一樣的做法；**不會**呼叫 `wt config shell install`（那會去改
   `~/.zshrc` 並與 chezmoi 互打）。
2. **僅** Linux 上透過 `COMPLETE=zsh wt` 自動產生 `~/.zfunc/_wt`
   （clap 動態補全）。macOS 上 brew formula 已附帶 `_wt` 至
   `/opt/homebrew/share/zsh/site-functions/`，因此略過產生器。
3. 定義 `wtcd` —— 一個小型 fzf-tmux 輔助函式，用於跨 worktree 導航，
   而**不**改變 tmux／sesh session（見下一節）。

> **為什麼不用 `wt config shell install`？** 它會把一個區塊寫入
> `~/.zshrc`，但 `~/.zshrc` 是 chezmoi 從 `dot_zshrc.tmpl` 管出來的。
> 每次 `chezmoi apply` 不是把它擦掉、就是永遠回報 drift。
> `eval "$(wt config shell init zsh)"` 形式給出相同的 wrapper，
> 但完全不碰 rc 檔。

---

## 三層導航：sesh + wt + wtcd

切換到 worktree 工作流程後最大的心智轉變是體認到：**在不同 worktree
之間移動，跟在不同專案之間移動，不是同一件事**。三個按鍵代表三種
不同意圖：

| 我想要... | 用 | 它做了什麼 | 副作用 |
|--------------|-----|--------------|--------------|
| 切換**專案** | `Alt+S`（sesh picker）、`sroot`、`scode` | 從目前 tmux session 卸離、attach 到該專案的 session | 整個 session 換掉 |
| 切換目前專案中的 **worktree** | `wt switch <branch>`（或 `wt sw`、或 `wt switch` 不帶參數叫出 picker） | 對父 shell 做 `cd`、執行 hook（`pre-/post-start`） | 換目錄；若 hook 為 worktree 生出 tmux session，可以再 attach 過去 |
| **偷看**其他 worktree | `wtcd`（fzf picker） | 只對父 shell 做 `cd` | 留在同一個 tmux／sesh session；適合 diff、抓檔案 |

### 具體例子

```bash
# 早上：開啟 dotfiles 專案
$ sroot                              # → tmux session "dotfiles"（或 sesh 給的名字）

# 接著昨天的 worktrunk-docs 分支繼續
$ wt switch worktrunk-docs           # → cd 到 ../dotfiles.worktrunk-docs，跑 post-start hook

# 順手看一下 main 現在長怎樣（不要丟失目前位置）
$ wtcd                               # → fzf 列出所有 worktree → 選 "main" → cd，session 不變
$ git log --oneline -5
$ cd -                               # 回到 worktrunk-docs

# 新的並行任務：一次生出 worktree + Claude
$ wt cc fix-tmux-menu -- 'Investigate the popup menu height issue documented in pitfalls/tmux-display-menu-silent-fail.md'
# 現在 ../dotfiles.fix-tmux-menu 裡跑著第二個 Claude，我繼續在這邊編輯。
```

### `wtcd` 的存在理由

95% 情況 `wt switch` 是對的工具。但 `wt switch` 會跑
`pre-start`／`post-start` hook —— 啟動開發伺服器、複製 ignored 檔案、
生成 agent。這很重。當你只是想**看一眼**其他 worktree（找個檔案、
複製片段、跑 `git log`）時，你不希望觸發這些副作用。`wtcd` 完全跳過
hook；它就是純 `cd`。

```zsh
# 定義在 dot_config/zsh/tools/37_worktrunk.zsh
function wtcd() {
    local target
    target=$(wt list --format=json 2>/dev/null \
        | jq -r '.worktrees[].path' \
        | fzf-tmux -p 60%,40% --prompt='wt cd ❯ ') || return
    [[ -n "$target" ]] && cd -- "$target"
}
```

如果常用，可在 tmux 設定中加一個專屬鍵綁定：
`bind-key W run-shell 'tmux send-keys "wtcd" Enter'`。

---

## 每個 worktree 一個 Claude／OpenCode

並行 coding agent 最有用的單一模式。每個 worktree 在自己的 checkout
目錄裡跑自己的 agent；它們不可能在檔案編輯、分支或 git state 上撞車。

Alias 寫在 `~/.config/worktrunk/config.toml`（**不**寫在 zsh —— 寫在
這裡的話，從 `wt switch` 互動式 picker 內、以及任何 shell 中都能用）：

```toml
[aliases]
cc = "wt switch --create --execute=claude"
oc = "wt switch --create --execute='opencode run'"
```

用法：

```bash
# 三個 Claude agent 並行，各拿一個 prompt
wt cc add-auth        -- 'Add JWT auth middleware. See docs/auth.md for the schema.'
wt cc fix-pagination  -- 'Fix the off-by-one in /api/list. Repro in tests/pagination.test.ts:42.'
wt cc write-tests     -- 'Write integration tests for /api/checkout.'

# 或改用 OpenCode
wt oc refactor-store  -- 'Migrate redux → zustand. Start with src/state/user.ts.'

# 看進度（marker 來自 Claude/OpenCode plugin；🤖 = 工作中、💬 = 等待輸入）
wt list
#   Branch          Status   ...  Marker  ...
# @ main                            ^
# + add-auth        +   ↕↑    ↑3   🤖
# + fix-pagination  +   ↕↑    ↑1   💬     ← 在等我回應
# + write-tests     +   ↕     ↑2   🤖

# 跳到那個正在等輸入的
wt switch fix-pagination
```

### 注意事項

- `--execute`（`-x`）會把 agent 啟動在新 shell 的**前景**。如果想讓
  agent 在獨立的 tmux session／視窗裡跑、不擋住目前 prompt，請用
  下方的[每個 worktree 一個 tmux session](#每個-worktree-一個-tmux-session以及它如何與-scodesvibe-互動)
  模式 —— `wt switch -x 'tmux new-session -d ...'`。
- `cc` ／ `oc` alias 假設你已經對每個 agent CLI（`claude`／`opencode`）
  做過全域認證。它們會繼承你的 shell 環境變數。
- 若要做 SpecStory transcript 擷取（本 repo 的 coding-agent overlay），
  `scode` ／ `svibe` 這組 sesh 輔助腳本會把 agent 包進 `specstory run`；
  `wt cc` **不會**。如果你兩者都要，自己寫 alias：
  `wsc = "wt switch --create --execute='specstory run claude'"`。

---

## 每個 worktree 一個開發伺服器（`hash_port`）

三個並行 agent 都在改一個 Next.js app，全部都想跑 `npm run dev`。
單一 repo 時：port 撞車，最後一個贏，其他都掛。worktrunk + `hash_port`
之後：每個分支會從 10000-19999 範圍內、由分支名計算出一個固定 port。

加到專案本地的 `.config/wt.toml`（每專案，**不要**放全域設定 ——
不同專案需要不同指令）：

```toml
[post-start]
server = "npm run dev -- --port {{ branch | hash_port }}"

[list]
url = "http://localhost:{{ branch | hash_port }}"

[pre-remove]
server = "lsof -ti :{{ branch | hash_port }} -sTCP:LISTEN | xargs kill 2>/dev/null || true"
```

這樣一來：

```bash
wt cc fix-checkout-ui -- 'Make the checkout button green'
# post-start 會在背景跑 `npm run dev -- --port 14823`
# Hook 輸出會寫入 log 檔；用以下指令 tail：
tail -f "$(wt config state logs get --hook=user:post-start:server)"

wt list
# URL 欄位顯示 http://localhost:14823（在 iTerm/Ghostty 內可點）
# Port 是確定性的 —— fix-checkout-ui 在任何機器上**都**是 14823

# 完成後，wt remove 會清理乾淨：
wt remove fix-checkout-ui
# pre-remove 會先把開發伺服器殺掉，再 unlink worktree
```

### 為什麼這比聽起來重要

- **不用再操心 port**：你完全不用想 port 的事。
- **可加書籤 (bookmark)**：`fix-checkout-ui` 的 URL 在重啟後、跨機器都
  穩定（筆電與桌機都會算出同一個 14823）。
- **CORS／cookie**：每個 worktree 各自有 port，cookie 不會在分支間
  互漏。如果想要漂亮的不帶 port 的 URL，可以再加上
  [Caddy subdomain 模式](https://worktrunk.dev/tips-patterns/#subdomain-routing-with-caddy)。
- **資料庫隔離**：相同的 `hash_port` 技巧也能用在每個 worktree
  生一個 Postgres container —— 見
  [worktrunk.dev/tips-patterns#database-per-worktree](https://worktrunk.dev/tips-patterns/#database-per-worktree)。

> 專案本地的 `.config/wt.toml` 通常**應**被提交到 repo，這樣協作者
> （與你所有的機器）都共用同一組 hook。chezmoi 管理的
> `~/.config/worktrunk/config.toml` 是給跨所有 repo 通用的個人預設。

---

## 每個 worktree 一個 tmux session（以及它如何與 `scode`／`svibe` 互動）

對於「我的 coding-agent 版面 (layout) 該住在哪？」有兩種互相競爭的
模型：

### 模型 A —— 每**專案**一個 `scode` ／ `svibe`（目前預設）

[`sesh-code`／`sesh-vibe`](sesh.md)（alias `scode`／`svibe`）會為每個
repo 建立**一個** tmux session，命名為 `coding-agent/<repo>` 或
`vibe/<repo>`，並有固定的 nvim + agent + lazygit 版面。該 repo 的所有
worktree 共用同一個 session —— 你在裡面用 `wt switch` 切換。

✅ **適合**：個人寫 code、不同分支間循序工作、並行 agent 數量低。
❌ **限制**：同時只看得到一個 Claude／OpenCode pane。如果你有 5 個
並行 agent，沒辦法同時盯著它們。

### 模型 B —— 每 **worktree** 一個 tmux session

為每個 worktree 開一個專屬 tmux session，各自有自己的多 pane 版面。
Worktrunk 官方食譜：

```toml
# 專案的 .config/wt.toml
[pre-start]
tmux = """
S={{ branch | sanitize }}
W={{ worktree_path }}
tmux new-session -d -s "$S" -c "$W" -n dev
tmux split-window -h -t "$S:dev" -c "$W"
tmux split-window -v -t "$S:dev.0" -c "$W"
tmux split-window -v -t "$S:dev.2" -c "$W"
tmux send-keys -t "$S:dev.1" 'npm run backend' Enter
tmux send-keys -t "$S:dev.2" 'claude' Enter
tmux send-keys -t "$S:dev.3" 'npm run frontend' Enter
tmux select-pane -t "$S:dev.0"
"""

[pre-remove]
tmux = "tmux kill-session -t {{ branch | sanitize }} 2>/dev/null || true"
```

接著 `wt switch --create feature -x 'tmux attach -t {{ branch | sanitize }}'`
會建立 worktree、跑版面、把你 attach 到新 session。

✅ **適合**：3+ 並行 agent、儀表板式 (dashboard) 全景、每個 worktree
有自己的服務（backend／frontend／db 各佔一個 pane）。
❌ **限制**：tmux session 列表會增長很快 —— 搭配 `sesh` 過濾（sesh
會自動 pick up tmux session）。冷啟動也較重。

### 兩者如何互動

兩種模型**不互斥**：

- 用 `scode` 進入專案（一個常駐 session 給編輯器 + git 全景）。
- 用模型 B 的 `pre-start` hook 為每個 worktree 生**獨立** session，
  裡面只放 agent + 開發伺服器。
- 用 `Alt+S` 在它們之間切換（sesh picker 會同時列出
  `coding-agent/dotfiles` 與 `dotfiles.feat-x`、`dotfiles.feat-y`...）。
- 把 agent session 卸離、讓它繼續跑。之後再用 sesh 重新 attach。

### Sesh + wt 的 session 命名慣例

如果你採用模型 B，建議幫 tmux session 名稱加前綴，讓 sesh 的 picker
能合理分群：

```toml
[pre-start]
tmux = "tmux new-session -d -s 'wt/{{ repo }}/{{ branch | sanitize }}' ..."
```

這樣 `Alt+S` 就會顯示：

```
coding-agent/dotfiles      ← scode session（編輯器）
wt/dotfiles/feat-x         ← wt session（agent A）
wt/dotfiles/feat-y         ← wt session（agent B）
wt/dotfiles/fix-z          ← wt session（agent C）
```

…在 fzf 中輸入 `wt/dotfiles/` 即可全部 grep 出來。

---

## 冷啟動消除

新 worktree 是全新的 checkout —— 沒有 `node_modules/`、沒有 `target/`、
沒有 `.env`、沒有 build cache。對 Rust 或 pnpm 專案來說，每次
`wt switch --create` 就是 60-180 秒的損失。兩個互補的緩解方式：

### `wt step copy-ignored`

把來源 worktree 的所有 gitignored 檔案複製到新 worktree。加進專案的
`.config/wt.toml`：

```toml
[post-start]
copy = "wt step copy-ignored"
```

如果專案有不想複製的大型 ignored 目錄（例如 `coverage/`、`dist/`、
作業系統垃圾），請建立 `.worktreeinclude` 列出**該被**複製的內容 ——
檔案必須同時被 gitignore **而且**列在這份清單裡才會被複製。

### 順序化的 pipeline

當 `pnpm install` 需要先看到複製來的 `node_modules/`，請用 `[[hook]]`
陣列形式把它們排成順序（`[[…]]` = 有順序的 pipeline、`[…]` = 並行）：

```toml
[[post-start]]
copy = "wt step copy-ignored"

[[post-start]]
install = "pnpm install"   # 重用從 node_modules 複製來的快取套件
```

### Agent 馬上需要檔案時

如果 `--execute claude` 啟動前需要 `.env` 已存在，請用 `pre-start` 而
非 `post-start`：

```toml
[pre-start]
copy = "wt step copy-ignored"
```

---

## 合併與清理流程

Worktrunk 把多步驟的「commit → push → merge → 切回去 → 移掉
worktree → 刪分支」舞蹈濃縮成一個指令：

```bash
wt merge main
# 1.（可選）由 staged diff 產生 LLM commit message
# 2. commit、rebase 到 main、fast-forward merge
# 3. 把你切回 main worktree
# 4. 在背景移除 feature worktree + 分支
```

這在並行 agent 場景下實際是這樣用：

```bash
# 三個 agent 都做完了。先在 picker 裡審 diff：
wt switch              # 互動式 picker 顯示即時 diff／log 預覽，可用 tab 切換 worktree

# 選出贏家 #1，合併之
wt merge main

# 選贏家 #2，但這次想自己寫 commit message（覆寫策略）：
wt mc                  # 如果你照
                       # https://worktrunk.dev/tips-patterns/ 的 `Manual commit messages` 設了 editor-override alias

# 拒絕 #3 —— 不合併直接關掉
wt switch reject-this-one
wt remove              # 連分支 + worktree 一起丟掉（若有未合併 commit 會警告）
```

### 每次合併的清理 hook

加入專案的 `pre-merge`（在壞 code 進入前先驗證）與 `post-merge`
（部署、通知）：

```toml
[[pre-merge]]
test = "npm test"
build = "npm run build"

[post-merge]
deploy = """
if [ {{ target }} = main ]; then npm run deploy:production; fi
"""
```

`pre-merge` **每次合併執行一次**（rebase 之後）。`pre-commit` 則**每個
被 squash 的 commit 執行一次**（合併期間）—— 把快的檢查（lint、
typecheck）放這裡，把慢的檢查（完整 test suite）放 `pre-merge`。

---

## LLM commit message —— 何時值得用

`wt merge` 可以把 staged diff 透過 pipe 餵給某個指令，由它在 stdout
回傳 commit message。三種設定法，請在
`~/.config/worktrunk/config.toml` 中至多挑一種：

| 策略 | 適用情境 | 設定 |
|----------|------|--------|
| **手動 editor** | 個人作業，你才是擁有上下文的人 | `command = '''f=$(mktemp); printf '\n\n' > "$f"; sed 's/^/# /' >> "$f"; ${EDITOR:-vi} "$f" < /dev/tty > /dev/tty; grep -v '^#' "$f"'''` |
| **Claude headless** | Agent 主導的工作流，希望 agent 一併寫 commit message | `command = "claude -p"` |
| **OpenCode** | 同 Claude，但用 OpenCode | `command = "opencode run"` |

這三種目前在本 repo 的
[`dot_config/worktrunk/config.toml`](../../dot_config/worktrunk/config.toml)
都**以註解形式停用**。理由：我還沒決定 LLM 產生的 message 是不是真的
比 coding agent 在 stage 之前已經寫好的更好。計畫是等我用 `wt merge`
用到實際感受到摩擦後再啟用 `claude -p`。

### 單次合併用 editor 覆寫

預設用 LLM，但這次合併要用 editor：

```toml
[aliases]
mc = '''WORKTRUNK_COMMIT__GENERATION__COMMAND='f=$(mktemp); printf "\n\n" > "$f"; sed "s/^/# /" >> "$f"; ${EDITOR:-vi} "$f" < /dev/tty > /dev/tty; grep -v "^#" "$f"' wt merge'''
```

於是 `wt merge` 走 Claude，`wt mc` 開 `$EDITOR`。

### 分支摘要 (Branch summaries)

開啟 LLM commit 後，順便把 `summary = true` 也開起來，就能在
`wt list --full` 與 picker（tab 5）裡看到一行 LLM 產生的分支摘要：

```toml
[list]
summary = true
```

---

## 尚未啟用的食譜

留給「未來的我」當文件 —— 等需求出現時的複製貼上目標。全部都來自
[worktrunk.dev/tips-patterns](https://worktrunk.dev/tips-patterns/)。

| 食譜 | 啟用觸發點 |
|--------|-------------------|
| **每個 worktree 一個資料庫**（Postgres container、用 `hash_port` 給 DB port、用 `vars` 協調名稱） | 第一次想在 feature 分支上測 schema migration、又不想搞壞主 DB |
| **Caddy subdomain 路由**（`feat-x.dotfiles.localhost` 取代 `:14823`） | 第一次因為基於 port 的開發 URL 而被 cookie ／ CORS 咬到 |
| **Bare repo 結構**（`<project>/.git` + `<project>/<branch>/`） | 新專案，從一開始就想要對稱的分支目錄 |
| **Stacked branches**（`wt switch --create part2 --base=@`） | 第一次想把一個大 PR 拆成一個 stack |
| **Agent handoff**（一個 agent 在卸離的 tmux session 中生出另一個 agent） | 第一次跑 agent 跑久到希望它能自己 delegate |
| **`wt list` 顯示 CI 狀態**（`wt list --full --branches`） | 第一次同時開太多 PR、追不上哪個 CI 是綠的 |

---

## 交叉參考

- [`docs/tools/sesh.md`](sesh.md) —— sesh 輔助腳本（`shere` ／ `sroot`
  ／ `scode` ／ `svibe`）；位於 worktrunk 之上的「專案」層。
- [`docs/tools/tmux/`](tmux/) —— tmux 設定、popup menu、主題切換；位於
  sesh 之下的「pane」層。
- [`docs/tools/agent-overlays.md`](agent-overlays.md) —— Claude Code、
  OpenCode、Codex CLI 的 overlay 設定（`modify_*`）；agent CLI 本身是
  怎麼被管理的。
- [`docs/tools/specstory.md`](specstory.md) —— agent transcript 擷取；
  搭配 `scode` ／ `svibe`（**不**搭配預設的 `wt cc`）。
- [`dot_config/worktrunk/config.toml`](../../dot_config/worktrunk/config.toml)
  —— 由 chezmoi 管理的使用者設定（alias 啟用；hook／LLM commit 已註解）。
- [`dot_config/zsh/tools/37_worktrunk.zsh`](../../dot_config/zsh/tools/37_worktrunk.zsh)
  —— shell 整合 + `wtcd` 輔助函式。
- [worktrunk.dev](https://worktrunk.dev) —— 上游完整文件。
