# lazygit — branch 洞察與歷史手術速查表

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：變基
    (rebase)。**不自創翻譯**——若無公認譯名直接保留英文（如 `fixup`、
    `reflog`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

[lazygit](https://github.com/jesseduffield/lazygit) 是這裡使用的 git TUI（透過 `lazyvim_deps` role 安裝；綁定為 `lg`）。日常操作（stage、commit、branch）很直覺——這頁專收**難記的 rebase／amend「手術」**，把 **lazygit 按鍵與等價的 CLI 並排**列出，讓你兩種方式都能做。

> **黃金守則：只改寫尚未 push 的 commit。** 以下所有配方都會改寫歷史（產生新的 SHA）。若某個 commit 已在共享 remote 上，別動——否則你得用 `git push --force-with-lease` 並和他人協調。

## 受管理的 pull 行為

此 dotfiles repo 把 Git 的全域基準設為：

```gitconfig
[pull]
    rebase = true
[rebase]
    autoStash = true
```

所以 LazyGit 一般的 **`p`** pull 會以 rebase 方式執行，且工作區 (working-tree) 的髒變更會在 rebase 前被 stash、rebase 後再套用回來。若重新套用的 stash 發生衝突，Git 會保留該 autostash 而非丟棄；請檢查 `git status` 與 `git stash list`，解決工作區衝突、確認你的變更已回來之後，再丟掉 autostash。

## Branch 面板與 `I` Branch insights

受管理的設定讓 Local branches 面板更有資訊量，但不把低訊號的 commit
hash 塞進有限寬度：

- Nerd Font v3 圖示讓檔案與 pull request indicator 更直覺。
- 依常見 prefix 為 branch 名稱上色（`feat/`、`fix/`、`docs/`、維護、
  worktree 與 automation branch）。
- 預設依最近使用順序 (recency) 排列。
- 右側 `↓N` 顯示 branch 比 LazyGit 偵測到的 base branch 落後幾個 commit。

`↓N` 很有用，但它**不是 merged 標記**。Branch 即使落後 main，仍可能含有
main 沒有的 commit。同樣地，原本的 upstream `✓` 只表示 local 與 upstream
同步，不代表 branch 已被 main 包含。

在 Local branches 面板按 **`I`**，再選：

| 按鍵 | 報告 | 網路 |
|---|---|---|
| `g` | 以 local 與 remote-tracking main 做精確 Git containment 判斷 | 不使用 |
| `p` | 同一份報告，再透過一次 `gh pr list` 補近期 GitHub PR 狀態 | GitHub |

報告完全唯讀且不會 fetch。要依賴 `REM` 欄位前，先按 LazyGit 的 refresh
鍵，或等待 auto-fetch 更新 remote-tracking refs。

```text
Local base:  main
Remote base: origin/main
Local main vs origin/main: ahead 1, behind 0

SEL LOC REM  BASE-  BASE+ UPSTREAM      WORKTREE     DATE       BRANCH  PR
    Y   Y       12      0 gone          -            2026-08-20 fix/old  MERGED->main#42
>   Y   N        0      1 up1           repo-wt      2026-09-01 feat/new OPEN->main#43
```

- `LOC` / `REM`：branch tip 是否為 local / remote main 的 ancestor。`Y` 是
  `git merge-base --is-ancestor` 對 history containment 的精確定義。
- `BASE-`：只有 comparison base 擁有的 commit 數，也就是 branch 落後量。
- `BASE+`：只有 branch 擁有的 commit 數；非零代表尚未完整包含於該 base。
- `UPSTREAM`：`=`、`upN`、`downN`、`downN/upN`、`gone` 或 `-`。
- `WORKTREE`：此 branch 被目前或另一個 worktree checkout 時的末層目錄名。
- `PR`：best-effort GitHub 狀態。`MERGED` 與 `REM` 刻意分開，因為 squash
  merge 與 rebase merge 不會保留相同的 commit ancestry。

Base 依序從 `origin/HEAD`、`main`、`master` 推斷。以其他 trunk 為主的 repo
可以只在該 repo 設定，不必改全域 dotfiles：

```bash
git config lazygit.branchBase develop
```

這個設定也可以指定 `upstream/trunk` 一類的 remote-tracking ref。

## 心智模型：兩種不同的「fixup」

*fixup* 這個字出現在兩個毫不相關的 lazygit 操作裡——搞混它們是弄壞歷史的頭號原因：

| 目標 | lazygit | 實際做的事 |
|---|---|---|
| 把**工作區變更**塞進某個既有 commit | **`A`**（Commits 面板）＝ *amend commit with staged changes* | 底層跑 `git commit --fixup` + `git rebase --autosquash` |
| 把**兩個既有 commit**合併成一個 | **`f`** / **`c`**（Commits 面板）＝ *fixup / squash* | 把**選取的** commit 併入**下面那個**（較舊的） |

所以 `A` ＝「把我的編輯放進那個舊 commit」；`f` ＝「把這兩個 commit 黏在一起」。想加檔案卻按了 `f`，會把相鄰的 commit 攪在一起。

## 配方：看某個檔案的歷史（哪些 commit 改過它）

唯讀查詢——不會改寫歷史，即使對已 push 的 commit 也安全。

**lazygit**
1. **`<ctrl+s>`**（全域）→ *View options for filtering the commit log* → 輸入**路徑 (path)**。**Commits** 面板此時只列出動過該檔的 commit；在任一 commit 上按 **`<enter>`** 可深入看該檔的 diff。再按一次 **`<ctrl+s>`** 清除過濾。

lazygit 的過濾不追蹤 rename，而且得一個個 commit 打開——要認真瀏覽檔案歷史，專用工具更順手：

**CLI**
```bash
tig path/to/file                             # 最佳：範圍限定該檔的 log，<enter> 開每個 commit 的 diff，會追 rename
git log --follow -p        -- path/to/file   # 追 rename + 每次都顯示完整 diff（這裡會走 delta）
git log --follow --oneline -- path/to/file   # 快速看「哪些 commit 動過它」
```

## 配方：把一個未 commit 的檔案塞進較舊的 commit

**lazygit**
1. **Files** 面板：只在你要的那個檔案上按 **`<space>`**。**別按 `a`**——那是 *stage all*，會把不相關的編輯一起掃進 amend。
2. **Commits** 面板：選取目標 commit → **`A`**。

**CLI**
```bash
git add path/to/file
git commit --fixup=<target-sha>
git rebase --autosquash --autostash <target-sha>~1
# 非互動（跳過編輯器）：前面加上  GIT_SEQUENCE_EDITOR=true
```

## 配方：把單一檔案從某個 commit 拉回工作區

上一則的反向操作——把單一檔案從未 push 的 commit 退回成「not staged」變更。lazygit 的 **custom patch** 是原生工具。

**lazygit**
1. **Commits** 面板：選取該 commit → **`<enter>`** 檢視其檔案。
2. 反白該檔 → **`<space>`**（把整個檔案加入 custom patch——會被標記）。
3. **`<ctrl+p>`** → *View custom patch options* → **`move patch out into index`**。這會改寫該 commit、移除該檔，並把變更 stage 起來。
4. **Files** 面板：在該檔上按 **`<space>`** 以 **unstage**——現在它是一筆 *Changes not staged* 的編輯。

> 在 patch 選單裡，你要的是 `move patch out into index`。`remove patch from original commit` 會**丟棄**該變更（遺失）——想保留就別選它。

**CLI**
```bash
git rebase -i <sha>~1                 # 把 <sha> 標成 'edit'，存檔離開
git reset HEAD^ -- path/to/file       # 只把那個檔案退出 commit -> 工作區變更
git commit --amend --no-edit          # 不含它、重做該 commit
git rebase --continue
```

## 配方：把工作區變更分叉成新檔案、還原原檔

你改了一個檔案，但想把這些編輯留成一個*獨立*的新檔案，同時把原檔重設回 `HEAD`（例如把一個實驗分叉成副本）。沒有單一按鍵，但兩步就好：複製會抓住改過的內容，接著 discard 還原原檔。

**lazygit**
1. **`:`**（*Execute shell command*）→ `cp path/to/file path/to/file.new`——這份複製抓的是**當前、已修改**的內容。`:` 的 shell 在 repo root 執行。
2. **Files** 面板：選原檔 → **`d`** → *discard* → 還原回 `HEAD`。
3. 之後就在 `path/to/file.new` 上繼續改。

**CLI**
```bash
cp path/to/file path/to/file.new   # 已修改的內容 -> 新檔
git restore path/to/file           # 原檔回到 HEAD（舊版 git 用 git checkout -- <file>）
```

> 想之後**重新套用**這個變更、而不是分叉它？`git stash` 一步就能存下編輯並還原原檔——但它會落在 stash list，不是新檔案。

## 配方：從搞砸的 rebase 中恢復

**lazygit**——**`z`** undo／**`Z`** redo（適用於 branch／commit 操作；工作區必須乾淨）。更深層的恢復請透過 CLI 用 reflog：

**CLI**
```bash
git reflog                       # 找出搞砸之前的好 SHA（例如原本的 HEAD）
git reset --hard <good-sha>      # 把 branch + 工作區還原到那個點
```

- **陷阱：** `git reset --hard` 會**刪掉被 stage 成新增 (new add) 的檔案**（例如剛 `git add` 的 plan 檔）——先備份。純 untracked 的檔案它不會動。
- 之後再把任何想留的未 commit WIP 套回來（例如事前 `git diff > /tmp/wip.patch`，事後 `git apply /tmp/wip.patch`）。

## 地雷 (Footguns)

- **`a` ＝ lazygit 的 stage ALL。** 它會默默把不相關的編輯（例如一個臨時的設定調整）掃進你接下來的 amend／fixup。用 **`<space>`** 只 stage 一個檔案。
- 上述任一操作後，該 commit 的 **SHA 會改變**。對本機 commit 沒問題；正常 push（只有本來就已 push 過才需要 force）。
- 檔案部分 staged 時的 commit 紀律：先 `git reset` 清掉 index，再 `git add` 你確切要的內容，然後才 `git commit`。

## 參見

- [git diff 工作流程](git_diff_workflow.md)
- 各工具的技巧／配方放在 `docs/tools/<tool>.md`——這頁是 git/lazygit 配方的落腳處。
