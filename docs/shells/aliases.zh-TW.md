# 自訂別名與 Shell 函式

本 dotfiles repo 中所定義的自訂別名 (alias) 與 shell 函式 (function) 的快速參考。

!!! note "Terminology rule (zh-TW pages)"
    技術名詞首次出現以「中文 (English original)」格式呈現，例：依賴注入
    (dependency injection)。**不自創翻譯**——若無公認譯名直接保留英文
    （如 `embedding`、`tokenizer`）。代碼、API 名、CLI flag、套件名、檔名一律不翻。

> **維護規則**（鏡像於 `CLAUDE.md`）：每當你新增、修改或刪除自訂別名或 shell 函式時，請更新此表格 —— 包含類型（`alias` 或 `function`）、來源檔案（相對於 repo 根目錄）以及一行描述。

---

## 目錄

- [Editor](#editor)
- [File Listing](#file-listing)
- [Navigation](#navigation)
- [Git](#git)
- [Tools Picker](#tools-picker)
- [Session Management](#session-management)
- [Worktree Management](#worktree-management)
- [GitHub / GitLab](#github--gitlab)
- [AI Usage Tracking](#ai-usage-tracking)
- [Task Queue](#task-queue)
- [Networking](#networking)
- [Log Viewers](#log-viewers)
- [Media / AV](#media--av)
- [Shell Utilities](#shell-utilities)
- [Tmux Integration](#tmux-integration)
- [AI Capture](#ai-capture)
- [Claude Code](#claude-code)
- [Package Managers & Runtime](#package-managers--runtime)

---

## Editor

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `v` | alias | `dot_config/shell/10_aliases.sh` | 開啟 Neovim (`nvim`) |

---

## File Listing

> 由 `eza`（現代化的 `ls` 替代品）提供。僅在已安裝 `eza` 時生效。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ls` | alias | `dot_config/shell/26_eza.sh` | 緊湊列表，含圖示、顏色、git 狀態 |
| `la` | alias | `dot_config/shell/26_eza.sh` | 長列表，含隱藏檔，目錄優先排序 |
| `ll` | alias | `dot_config/shell/26_eza.sh` | 長列表，目錄優先排序（不含隱藏檔） |
| `lt` | alias | `dot_config/shell/26_eza.sh` | 樹狀檢視，2 層深 |
| `llt` | alias | `dot_config/shell/26_eza.sh` | 長樹狀檢視，3 層深 |

---

## Navigation

> `cd` 僅在已安裝 `zoxide` 時被取代。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cd` | alias | `dot_config/shell/20_zoxide.sh` | 透過 zoxide (`z`) 智慧 `cd`，採用 frecency 配對 |

---

## Git

### 自訂（本 repo）

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `gcam-amend` | function | `dot_config/shell/10_aliases.sh` | `git commit --amend -m "<msg>"`（取代訊息） |
| `gundo` | function | `dot_config/shell/10_aliases.sh` | 還原最後一次 commit → 回到 staged；印出已還原的 commit 訊息 |
| `lg` | alias | `dot_config/shell/37_lazygit.sh` | 開啟 lazygit TUI |

### oh-my-zsh git 外掛

> 來源：[oh-my-zsh git plugin](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/git)。當 `git` 外掛啟用時自動載入。請**勿**在自訂設定中重新定義這些。

<details>
<summary>函式</summary>

| Command | Description |
|---------|-------------|
| `git_main_branch` | 偵測預設分支（`main`、`master`、`trunk` 等） |
| `git_develop_branch` | 偵測開發分支（`dev`、`devel`、`develop` 等） |
| `grename <old> <new>` | 在本機與 origin 重新命名分支 |
| `gunwipall` | 遞迴 unwip 所有最近的 `--wip--` commits |
| `work_in_progress` | 若最後一個 commit 是 WIP，印出 "WIP!!" |
| `gccd` | `git clone` 之後 `cd` 進入複製的目錄 |
| `gdv` | `git diff -w` 管線送至 `view` |
| `gdnolock` | 排除 lock 檔的 `git diff` |
| `ggu` | `git pull --rebase origin <current-branch>` |
| `ggl` | `git pull origin <current-branch>` |
| `ggp` | `git push origin <current-branch>` |
| `ggf` | `git push --force origin <current-branch>` |
| `ggfl` | `git push --force-with-lease origin <current-branch>` |
| `ggpnp` | Pull 後 push origin |
| `gbda` | 刪除已合併 (merge) 的分支（除了 main/develop） |
| `gbds` | 刪除以 squash-merge 合併的分支 |

</details>

<details>
<summary>別名 — Basic</summary>

| Command | Command Expanded |
|---------|-----------------|
| `g` | `git` |
| `grt` | `cd "$(git rev-parse --show-toplevel)"` |
| `ghh` | `git help` |
| `gcf` | `git config --list` |
| `gst` | `git status` |
| `gss` | `git status --short` |
| `gsb` | `git status --short --branch` |

</details>

<details>
<summary>別名 — Add & Apply</summary>

| Command | Command Expanded |
|---------|-----------------|
| `ga` | `git add` |
| `gaa` | `git add --all` |
| `gapa` | `git add --patch` |
| `gau` | `git add --update` |
| `gav` | `git add --verbose` |
| `gap` | `git apply` |
| `gapt` | `git apply --3way` |

</details>

<details>
<summary>別名 — Branch</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gb` | `git branch` |
| `gba` | `git branch --all` |
| `gbd` | `git branch --delete` |
| `gbD` | `git branch --delete --force` |
| `gbm` | `git branch --move` |
| `gbnm` | `git branch --no-merged` |
| `gbr` | `git branch --remote` |
| `gbg` | 顯示 upstream 已消失 (gone) 的分支 |
| `gbgd` | 刪除 upstream 已消失的分支 |
| `gbgD` | 強制刪除 upstream 已消失的分支 |
| `ggsup` | `git branch --set-upstream-to=origin/<current>` |

</details>

<details>
<summary>別名 — Checkout & Switch</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gco` | `git checkout` |
| `gcor` | `git checkout --recurse-submodules` |
| `gcb` | `git checkout -b` |
| `gcB` | `git checkout -B` |
| `gcm` | `git checkout $(git_main_branch)` |
| `gcd` | `git checkout $(git_develop_branch)` |
| `gsw` | `git switch` |
| `gswc` | `git switch --create` |
| `gswm` | `git switch $(git_main_branch)` |
| `gswd` | `git switch $(git_develop_branch)` |

</details>

<details>
<summary>別名 — Commit</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gc` | `git commit --verbose` |
| `gcn` | `git commit --verbose --no-edit` |
| `gc!` | `git commit --verbose --amend` |
| `gcn!` | `git commit --verbose --no-edit --amend` |
| `gca` | `git commit --verbose --all` |
| `gca!` | `git commit --verbose --all --amend` |
| `gcan!` | `git commit --verbose --all --no-edit --amend` |
| `gcans!` | `git commit --verbose --all --signoff --no-edit --amend` |
| `gcann!` | `git commit --verbose --all --date=now --no-edit --amend` |
| `gcam` | `git commit --all --message` |
| `gcmsg` | `git commit --message` |
| `gcsm` | `git commit --signoff --message` |
| `gcas` | `git commit --all --signoff` |
| `gcasm` | `git commit --all --signoff --message` |
| `gcs` | `git commit --gpg-sign` |
| `gcss` | `git commit --gpg-sign --signoff` |
| `gcssm` | `git commit --gpg-sign --signoff --message` |
| `gcfu` | `git commit --fixup` |

</details>

<details>
<summary>別名 — Diff</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gd` | `git diff` |
| `gdca` | `git diff --cached` |
| `gdcw` | `git diff --cached --word-diff` |
| `gds` | `git diff --staged` |
| `gdw` | `git diff --word-diff` |
| `gdup` | `git diff @{upstream}` |
| `gdt` | `git diff-tree --no-commit-id --name-only -r` |

</details>

<details>
<summary>別名 — Fetch & Pull</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gf` | `git fetch` |
| `gfa` | `git fetch --all --tags --prune --jobs=10` |
| `gfo` | `git fetch origin` |
| `gl` | `git pull` |
| `gpr` | `git pull --rebase` |
| `gprv` | `git pull --rebase -v` |
| `gpra` | `git pull --rebase --autostash` |
| `gprav` | `git pull --rebase --autostash -v` |
| `gprom` | `git pull --rebase origin $(git_main_branch)` |
| `gprum` | `git pull --rebase upstream $(git_main_branch)` |
| `ggpull` | `git pull origin <current-branch>` |
| `gluc` | `git pull upstream $(git_current_branch)` |
| `glum` | `git pull upstream $(git_main_branch)` |

</details>

<details>
<summary>別名 — Push</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gp` | `git push` |
| `gpd` | `git push --dry-run` |
| `gpv` | `git push --verbose` |
| `gpf` | `git push --force-with-lease` |
| `gpf!` | `git push --force` |
| `gpsup` | `git push --set-upstream origin <current-branch>` |
| `gpsupf` | `git push --set-upstream origin <current-branch> --force-with-lease` |
| `gpoat` | `git push origin --all && git push origin --tags` |
| `gpod` | `git push origin --delete` |
| `ggpush` | `git push origin <current-branch>` |
| `gpu` | `git push upstream` |

</details>

<details>
<summary>別名 — Rebase</summary>

| Command | Command Expanded |
|---------|-----------------|
| `grb` | `git rebase` |
| `grba` | `git rebase --abort` |
| `grbc` | `git rebase --continue` |
| `grbi` | `git rebase --interactive` |
| `grbo` | `git rebase --onto` |
| `grbs` | `git rebase --skip` |
| `grbm` | `git rebase $(git_main_branch)` |
| `grbd` | `git rebase $(git_develop_branch)` |
| `grbom` | `git rebase origin/$(git_main_branch)` |
| `grbum` | `git rebase upstream/$(git_main_branch)` |

</details>

<details>
<summary>別名 — Reset & Restore</summary>

| Command | Command Expanded |
|---------|-----------------|
| `grh` | `git reset` |
| `gru` | `git reset --` |
| `grhh` | `git reset --hard` |
| `grhk` | `git reset --keep` |
| `grhs` | `git reset --soft` |
| `groh` | `git reset origin/<current-branch> --hard` |
| `gpristine` | `git reset --hard && git clean --force -dfx` |
| `gwipe` | `git reset --hard && git clean --force -df` |
| `grs` | `git restore` |
| `grss` | `git restore --source` |
| `grst` | `git restore --staged` |

</details>

<details>
<summary>別名 — Log</summary>

| Command | Command Expanded |
|---------|-----------------|
| `glo` | `git log --oneline --decorate` |
| `glog` | `git log --oneline --decorate --graph` |
| `gloga` | `git log --oneline --decorate --graph --all` |
| `glg` | `git log --stat` |
| `glgp` | `git log --stat --patch` |
| `glgg` | `git log --graph` |
| `glgga` | `git log --graph --decorate --all` |
| `glgm` | `git log --graph --max-count=10` |
| `glol` | `git log --graph --pretty`（簡短格式，含作者 + 相對日期） |
| `glols` | 同 `glol` 加 `--stat` |
| `glola` | 同 `glol` 加 `--all` |
| `glod` | 同 `glol` 改絕對日期 |
| `glods` | 同 `glod` 加 `--date=short` |
| `glp` | `git log --pretty=<format>` |

</details>

<details>
<summary>別名 — Merge</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gm` | `git merge` |
| `gma` | `git merge --abort` |
| `gmc` | `git merge --continue` |
| `gms` | `git merge --squash` |
| `gmff` | `git merge --ff-only` |
| `gmom` | `git merge origin/$(git_main_branch)` |
| `gmum` | `git merge upstream/$(git_main_branch)` |
| `gmtl` | `git mergetool --no-prompt` |
| `gmtlvim` | `git mergetool --no-prompt --tool=vimdiff` |

</details>

<details>
<summary>別名 — Cherry-pick, Revert, Blame</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gcp` | `git cherry-pick` |
| `gcpa` | `git cherry-pick --abort` |
| `gcpc` | `git cherry-pick --continue` |
| `grev` | `git revert` |
| `greva` | `git revert --abort` |
| `grevc` | `git revert --continue` |
| `gbl` | `git blame -w` |

</details>

<details>
<summary>別名 — Remote</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gr` | `git remote` |
| `grv` | `git remote --verbose` |
| `gra` | `git remote add` |
| `grrm` | `git remote remove` |
| `grmv` | `git remote rename` |
| `grset` | `git remote set-url` |
| `grup` | `git remote update` |

</details>

<details>
<summary>別名 — Stash</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gsta` | `git stash push` |
| `gstaa` | `git stash apply` |
| `gstc` | `git stash clear` |
| `gstd` | `git stash drop` |
| `gstl` | `git stash list` |
| `gstp` | `git stash pop` |
| `gsts` | `git stash show --patch` |
| `gstall` | `git stash --all` |
| `gstu` | `git stash --include-untracked` |

</details>

<details>
<summary>別名 — Tag, Worktree, Submodule, Bisect 與其他</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gta` | `git tag --annotate` |
| `gts` | `git tag --sign` |
| `gtv` | `git tag \| sort -V` |
| `gtl` | `git tag --sort=-v:refname -n --list "<pattern>*"` |
| `gwt` | `git worktree` |
| `gwta` | `git worktree add` |
| `gwtls` | `git worktree list` |
| `gwtmv` | `git worktree move` |
| `gwtrm` | `git worktree remove` |
| `gsi` | `git submodule init` |
| `gsu` | `git submodule update` |
| `gbs` | `git bisect` |
| `gbsb` | `git bisect bad` |
| `gbsg` | `git bisect good` |
| `gbsn` | `git bisect new` |
| `gbso` | `git bisect old` |
| `gbsr` | `git bisect reset` |
| `gbss` | `git bisect start` |
| `gclean` | `git clean --interactive -d` |
| `gcl` | `git clone --recurse-submodules` |
| `gclf` | `git clone --recursive --shallow-submodules --filter=blob:none` |
| `gcount` | `git shortlog --summary --numbered` |
| `gdct` | `git describe --tags`（最新 tag） |
| `gfg` | `git ls-files \| grep` |
| `gignored` | 列出被忽略的檔案 |
| `gignore` | `git update-index --assume-unchanged` |
| `gunignore` | `git update-index --no-assume-unchanged` |
| `grf` | `git reflog` |
| `gsh` | `git show` |
| `gsps` | `git show --pretty=short --show-signature` |
| `gwch` | `git log --patch --abbrev-commit --pretty=medium --raw` |
| `gam` | `git am` |
| `gama` | `git am --abort` |
| `gamc` | `git am --continue` |
| `gams` | `git am --skip` |
| `gamscp` | `git am --show-current-patch` |
| `gg` | `git gui citool` |
| `gga` | `git gui citool --amend` |
| `gk` | `gitk --all --branches` |
| `gke` | `gitk --all`（含 reflogs） |
| `gsd` | `git svn dcommit` |
| `gsr` | `git svn rebase` |
| `gwip` | Stage 全部 + WIP commit（略過 CI） |
| `gunwip` | 還原最後一個 WIP commit |

</details>

---

## Tools Picker

> 需要 `fzf`。資料檔案 (`~/.config/docs/tools/cli-tools.md`) 必須透過 `chezmoi apply` 部署。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `tools-picker` | function | `dot_config/zsh/tools/11_tools_picker.zsh` | 已安裝 CLI 工具的 fzf picker；Enter 將呼叫貼到緩衝區 (buffer)，Ctrl+E 執行（綁定為 `Alt+T`） |
| `tv tools` | tv channel | `dot_config/television/cable/tools.toml` | CLI 工具的 Television picker；Enter 執行，Ctrl+T 顯示 tldrf 頁面 |
| `tv aliases` | tv channel | `dot_config/television/cable/aliases.toml` | 所有執行期 (runtime) 別名與函式的 Television picker；Enter 執行，Ctrl+Y 複製名稱（綁定為 `Alt+A`） |
| `tv files` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television 檔案 picker（綁定為 `Alt+P`） |
| `tv history` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television shell 歷史搜尋（綁定為 `Alt+R`） |
| `tv git-log` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television git log 瀏覽器（綁定為 `Alt+G`） |
| `tv env` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television 環境變數 picker（綁定為 `Alt+E`） |
| `tv ssh-config` | tv channel | `dot_config/television/cable/ssh-config.toml` | SSH host picker，支援 `Include config.d/*`；Enter 連線 |
| `tv ports` | tv channel | `dot_config/television/cable/ports.toml` | 含 PID 的監聽埠 (listening ports) picker；Ctrl+K 終止程序、Ctrl+D 強制終止 |
| `tv kill-process` | tv channel | `dot_config/television/cable/kill-process.toml` | Raycast 風格的 process killer：依名稱模糊搜尋、CPU/MEM 統計 |

---

## Session Management

> `sesh-*` 需要 `sesh` + `tmux`；`tsesh` 還需要 `try-cli` Ruby gem。`mrun` / `tmrun` / `zjrun` 只需 tmux 或 zellij（取決於選擇的後端 (backend)） —— 不依賴 sesh。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `sesh-sessions` | function | `dot_config/zsh/tools/22_sesh.zsh` | 所有 sesh sessions 的 fzf 彈出 picker（也綁定為 `Alt+S`） |
| `sesh-here` / `shere` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | 輕量：在 `$PWD` 的純 shell session（無 nvim、無專案 layout）。傳入 args 或 `-c CMD` 覆寫 |
| `sesh-root` / `sroot` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | 將 sesh 連到目前的 git 根目錄（退回 `$PWD`）；遵循 sesh.toml 萬用模式/預設值 |
| `sesh-code` / `scode` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | 以 repo 為範圍的 coding-agent layout：nvim 75% \| `specstory run [agent]` 25%，外加 btop 視窗。Session 命名為 `coding-agent/<repo>`（防衝突）。在 git repo 之外會拒絕。Flags：`--on-exit shell\|kill\|restart`、`--no-specstory` |
| `sesh-vibe` / `svibe` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | 參數化的多 agent layout：`svibe [N] [CLI]`（同質）或 `svibe --agents claude,codex,opencode,…`（異質）。N 個平鋪 (tiled) agent panes + lazygit 視窗 + nvim 視窗。Session 命名為 `vibe/<repo>`。`--on-exit` / `--no-specstory` flags 同 scode |
| `herdr-vibe` / `hvibe` | function / alias | `dot_config/shell/24_herdr.sh` | **herdr** 版的 `svibe`（需要 `herdr` server + `jq`）。`hvibe [N] [CLI]` 或 `hvibe --agents claude,codex,opencode`。建立 workspace `vibe/<repo>`：`agents` tab 含 N 個等寬 agent panes（`--tab-per-agent` → 每個 agent 一個 tab）+ `git` + `edit` tab。重用 svibe 的 specstory/on-exit/git-root 邏輯。每 repo 冪等。從 herdr 外部跑會 attach（在內部則只聚焦）。`--on-exit` / `--no-specstory` / `--min-width` flags，外加 `--session NAME`（鎖定某個正在跑的 herdr session；預設為當前/`default`） |
| `herdr-code` / `hcode` | function / alias | `dot_config/shell/24_herdr.sh` | **herdr** 版的 `scode`（需要 `herdr` + `jq`）。建立 workspace `coding-agent/<repo>`：`editor` tab（nvim 75% \| agent 25%）+ `monitor` tab（btop）。在 git repo 之外會拒絕。從 herdr 外部跑會 attach。Flags：`--on-exit`、`--no-specstory`、`-a/--agent`、`--session NAME` |
| `try-sesh` / `tsesh` | function / alias | `dot_config/zsh/tools/32_try.zsh` | 開啟一個 `try` 短暫 (ephemeral) 工作空間，並立即透過 sesh 連線 |
| `mrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | 設定即忘 (fire-and-forget)：在 `$PWD` 跑 CMD 的脫離 (detached) tmux/zellij session，立即返回。`mrun [-b tmux\|zellij] [-n NAME] [-d DIR] [-f] [--on-exit shell\|kill\|restart] [-k] [--] CMD [ARGS...]`。預設 `--on-exit shell` 在 CMD 退出後保留 session（掉到登入 shell，可透過 history-Up 重跑）；`-k` 還原 fire-and-forget 的終止語意。後端預設為 tmux（透過 `$MRUN_BACKEND` 覆寫）。對 TUI 命令會軟性警告。將 attach 提示印至 stderr |
| `tmrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | `mrun -b tmux`。執行 CMD 的脫離 tmux session；以 `tmux attach -t NAME` 附加 (attach) |
| `zjrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | `mrun -b zellij`。在 `$TMPDIR/mrun-layout-*` 下產生短暫 KDL（含 `default_tab_template`，恢復標準 tab-bar / status-bar 外掛），生成脫離的 zellij session；以 `zellij attach NAME` 附加 |

---

## Worktree Management

> 需要 `dev-cli` (`dev`) 與／或 `worktrunk` (`wt`)。`wtcd` 還需要 `jq` + `fzf`。
>
> Worktrunk 自身的別名（`wt sw`、`wt ls`、`wt rm`、`wt cc`、`wt oc`）定義在 `dot_config/worktrunk/config.toml` 中，不在 zsh 中 —— 它們在任何 shell 與互動式 picker 中皆可使用。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `dev` | function | `dot_config/shell/39_dev.sh` | `dev` binary 的包裝器；保留真實 TTY，並透過 child-only file descriptor 將目錄切換交回父 shell。bash/zsh 內容由 `dev shell-init` 產生 |
| `wt` | function | `dot_config/zsh/tools/37_worktrunk.zsh` | `wt` 二進位檔的包裝器，會擷取 `cd`/`exec` 指令以便 `wt switch` 真正改變父 shell 的 `$PWD`（從 `wt config shell init zsh` eval 而來） |
| `wtcd` | function | `dot_config/zsh/tools/37_worktrunk.zsh` | 對 `wt list --format=json` 路徑的 fzf-tmux picker；`cd` 進入所選 worktree 但**不切換** tmux/sesh session —— 適合偷看姊妹 worktree |

---

## GitHub / GitLab

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ghget` | function | `dot_config/shell/41_github.sh` | 從 GitHub tree URL 下載一個子目錄 |
| `ghrepo` | function | `dot_config/shell/41_github.sh` | 模糊搜尋你的 GitHub repos（fzf）→ 預覽 README，然後 clone 後 cd／開啟／複製 URL。`Enter` clone 到 `${GHREPO_ROOT:-$PWD}`。孿生：`tv github-repos` |
| `glcreate` | function | `dot_config/shell/42_gitlab.sh` | 在某 group 下建立私有 GitLab repo、設定 origin 並 push |
| `glcreate-ai` | function | `dot_config/shell/42_gitlab.sh` | 同 `glcreate`，但使用 AI agent 自動產生描述 |
| `glrepo` | function | `dot_config/shell/42_gitlab.sh` | 模糊搜尋你的 GitLab repos（fzf）→ 預覽，然後 clone 後 cd／開啟／複製 URL。孿生：`tv gitlab-repos`。自架：`GITLAB_HOST=…` |

---

## AI Usage Tracking

> `cbu`/`cbc`/`cbca` 需要 `codexbar`。`ccusage` 需要 `bun`。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cbu` | alias | `dot_config/shell/40_codexbar.sh` | Claude Code 使用統計 (`codexbar usage --provider claude`) |
| `cbc` | alias | `dot_config/shell/40_codexbar.sh` | Claude Code 成本明細 (`codexbar cost --provider claude`) |
| `cbca` | alias | `dot_config/shell/40_codexbar.sh` | 跨所有 provider 的成本明細 (`codexbar cost`) |
| `ccusage` | alias | `dot_config/shell/07_bunx_cli.sh` | 透過 `bunx ccusage` 的 Claude Code 用量追蹤 |

---

## Task Queue

> 需要 `pueue` 與 `jq`。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `pqsum` | function | `dot_config/zsh/tools/36_pueue.zsh` | 摘要 pueue 佇列狀態：整體進度、ETA、各 group 細分 |

---

## Networking

> 條件式別名 —— 僅在對應工具已安裝時定義。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ports` | alias | `dot_config/zsh/tools/50_networking.zsh` | 列出所有監聽埠 (`lsof -i -P -n \| grep LISTEN`) |
| `myip` | alias | `dot_config/zsh/tools/50_networking.zsh` | 顯示公開 IP 位址 |
| `localip` | alias | `dot_config/zsh/tools/50_networking.zsh` | 顯示本機 IP 位址（依平台調整） |
| `pingsweep` | function | `dot_config/zsh/tools/50_networking.zsh` | 透過 `nmap -sn` 對本機 `/24` 子網段進行 ping sweep *(需要 nmap)* |
| `arpscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | 對本機網路進行 ARP 掃描 (`sudo arp-scan -l`) *(需要 arp-scan)* |
| `dns` | alias | `dot_config/zsh/tools/50_networking.zsh` | 透過 doggo 進行 DNS 查詢（DoH/DoT/DoQ） *(需要 doggo)* |
| `bw-net` | alias | `dot_config/zsh/tools/50_networking.zsh` | 即時頻寬監看 (`sudo bandwhich`) *(需要 bandwhich)* |
| `portscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | 透過 rustscan 的快速 port 掃描 *(需要 rustscan)* |
| `lanscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | 對 LAN 完整掃描裝置 + port，輸出至 `~/.cache/tv/`（餵給 `tv lan-devices`） |
| `tv-lan` | alias | `dot_config/zsh/tools/50_networking.zsh` | 開啟 `lan-devices` Television 頻道 |
| `ssh-setup-remote` | function | `dot_config/shell/96_ssh_setup.sh` | 互動式精靈：選擇／建立 SSH 金鑰（若私鑰旁邊缺 `.pub` 會自動修復）、把公鑰裝到遠端（POSIX 遠端用 `ssh-copy-id`；Windows sshd 遠端則走對應的 PowerShell 路徑，管理員帳號會寫入 `administrators_authorized_keys`），再把金鑰接進本機 `~/.ssh/config` —— 若別名**已設定過**就**就地編輯既有 `Host` 區塊**（會遞迴沿 `Include config.d/*` 找到正確檔案），否則附加新別名並可補上缺漏的 `Include`。**會先解析目標完整的 `ProxyJump` 鏈**，由外而內對每一跳都重跑一次整套流程——以前透過跳板連線時，只有最後一跳會設成免密碼。在有終端機且已安裝 [`gum`](../tools/gum.zh-TW.md) 時，提示會用 gum（方向鍵操作、金鑰以清單挑選），否則退回 bash `read -e` / zsh `vared`，再退回單純的 `read`。環境變數：`SSH_SETUP_ASSUME_YES=1`（每個提示都取預設值）、`SSH_SETUP_KEY=<path>`（跳過金鑰選擇）、`SSH_SETUP_NO_MUX=1`（停用每次執行的 `ControlMaster`）、`SSH_SETUP_NO_GUM=1`（即使有 gum 也用純文字提示）。就地編輯需 `python3`，否則退回僅附加。 |

### Proxy 輔助

> 可攜的 loopback proxy 輔助函式。遵循 `$LOCAL_PROXY_URL`（可選 `$LOCAL_PROXY_SOCKS_URL` 用於分離的 Clash `socks-port:` 設定）。偵測順序：環境變數 → **macOS System Proxy**（HTTPEnable 且 loopback 埠在聽 —— Clash Verge / CFW「系統代理」寫入處）→ Clash Verge / mihomo / CFW 設定檔（宣告的埠必須真的在聽）→ 探測 `7897/7890/7891/17890/1087/8118/8080`。優先 System Proxy 可避免舊的 `~/.config/clash` 蓋過正在跑的 Verge `7897`。偵測結果按 shell 快取；`proxy-off` / `proxy-refresh` 會清除。設定 `$LOCAL_PROXY_AUTO_ACTIVATE=1` 可在啟動時自動匯出。完整指南：[docs/tools/web-reader.md](../tools/web-reader.md)。Copilot 的 Node 客戶端需另外帶 `HTTPS_PROXY` / `--proxy-env`——見 [docs/tools/copilot-claude-proxy.md](../tools/copilot-claude-proxy.md)。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `withproxy` | function | `dot_config/zsh/tools/50_networking.zsh` | 執行單一命令，僅將 proxy 環境變數匯出到子程序（例如 `withproxy curl ...`） |
| `try_direct_then_proxy` | function | `dot_config/zsh/tools/50_networking.zsh` | 直連執行命令；失敗則透過 `withproxy` 重試。reader 函式預設使用此。 |
| `proxy-on` | function | `dot_config/zsh/tools/50_networking.zsh` | 在當前 shell 匯出 `http_proxy`/`https_proxy`/`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` |
| `proxy-off` | function | `dot_config/zsh/tools/50_networking.zsh` | 在當前 shell 取消所有 proxy 環境變數 |
| `proxy-status` | function | `dot_config/zsh/tools/50_networking.zsh` | 回報狀態：**active**（已匯出）、**available**（已偵測到）或 **unavailable** |
| `proxy-test` | function | `dot_config/zsh/tools/50_networking.zsh` | 以 `curl https://www.google.com/generate_204` 測試已偵測 proxy 是否可出網（HTTP，不是 ICMP ping） |
| `proxy-refresh` | function | `dot_config/zsh/tools/50_networking.zsh` | 清除快取的偵測結果、重新探測、印出狀態（在切換 proxy 後使用） |

### Docker registry 出口（`docker-net`）

> `docker pull` 是在 **daemon** 裡執行的，所以你 shell 的 proxy 環境變數和 `~/.docker/config.json` 的 `proxies.default` 都影響不到它 —— 後者只在 `docker run` / `docker build` 時注入到 container 裡。`docker-net` 管的是 daemon 這一層：用和 `proxy-status` 同一個 `__net_detect_proxy` 解析本機 proxy、寫入 `daemon.json` 的 `proxies` key（Engine ≥ 23），並為 mirror 沒有的 image 提供逐次 pull 的降級階梯。完整指南：[docs/tools/docker-net.md](../tools/docker-net.md)。mirror 策略與四種安裝變體：[docs/tools/containers.md](../tools/containers.md)。macOS：除了 `on`/`off` 之外都能用 —— 那兩個會拒絕，因為 Docker Desktop / OrbStack 把 daemon 跑在 VM 裡（`127.0.0.1` 是 VM 的 loopback 不是你 Mac 的），proxy 要在它們的 UI 設。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `docker-net status` | function | `dot_config/shell/51_docker_net.sh` | 一屏現況：安裝形態、daemon proxy、生效中的 mirror、偵測到的本機 proxy、TUN 攔截、死設定警告 |
| `docker-net doctor` | function | `dot_config/shell/51_docker_net.sh` | 九段診斷。`--deep` 會額外從 **daemon 那一側**探測 ghcr/gcr/quay/registry.k8s.io（不會下載任何東西） |
| `docker-net on` | function | `dot_config/shell/51_docker_net.sh` | 用偵測到的 proxy 寫入 `daemon.json` 的 `proxies` 並重啟 daemon（會先確認 —— 重啟會殺掉執行中的 container） |
| `docker-net off` | function | `dot_config/shell/51_docker_net.sh` | 移除該區塊並重啟 |
| `docker-net mirrors` | function | `dot_config/shell/51_docker_net.sh` | 只測 mirror 健康度 —— 分類出 DNS 消失 / 403 / 502 / TLS reset / timeout |
| `docker-net pull` | function | `dot_config/shell/51_docker_net.sh` | 以降級階梯拉取：一般 pull → 明確指定 mirror 前綴再 retag → `skopeo copy` 走 shell 的 proxy（不必重啟 daemon） |

### Web reader

> 在終端機中將網頁渲染為 markdown。所有函式都使用 `try_direct_then_proxy`，因此非 GFW'd 的 URL 不會付出 proxy 開銷。依函式名稱挑選擷取器 (extractor)。完整指南：[docs/tools/web-reader.md](../tools/web-reader.md)。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `readurl` | function | `dot_config/zsh/tools/55_web_reader.zsh` | 透過 jina.ai Reader + glow 閱讀文章（遠端，本地除 glow 外無依賴） |
| `readlocal` | function | `dot_config/zsh/tools/55_web_reader.zsh` | 透過 trafilatura + glow 閱讀文章（本地、離線） *(需要 `trafilatura`)* |
| `readnode` | function | `dot_config/zsh/tools/55_web_reader.zsh` | 透過 readability-cli (`readable`) + glow 閱讀文章（Mozilla Readability） *(需要 `readable`)* |
| `readraw` | function | `dot_config/zsh/tools/55_web_reader.zsh` | 渲染整頁：`curl | pandoc -f html -t gfm | glow -`（無文章擷取） *(需要 `pandoc`)* |

---

## Log Viewers

> 對 `tailspin` (`tspin`) 與 `ccze` 的薄包裝，用以著色任意 log 檔案。完整指南：[docs/tools/log-tools.md](../tools/log-tools.md)。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `catl` | function | `dot_config/zsh/tools/29_log_tools.zsh` | 透過 `tspin --print` 對 log 檔上色的 `cat`（stdout 模式；可乾淨地管線） *(需要 tspin)* |
| `lessl` | function | `dot_config/zsh/tools/29_log_tools.zsh` | 透過 `ccze -A \| less -RSFX` 顯示 ANSI 著色 log 的 pager *(需要 ccze)* |
| `logtail` | function | `dot_config/zsh/tools/29_log_tools.zsh` | 即時 tailspin 高亮的 `tail -f`（優先 `tspin --follow`，退回 `tail -F \| tspin --print`） |
| `svclog` | function | `dot_config/zsh/tools/29_log_tools.zsh` | 跨平台服務 log 跟隨器 —— Linux 用 `journalctl -fu`、macOS 用 `tail -F StdoutPath` / `log stream --predicate`，皆透過 tailspin 管線。接受 `--user` 用於使用者範圍。用法：`svclog [--user] <service>`。見 [services.md](../tools/services.md) |
| `svcstat` | function | `dot_config/zsh/tools/29_log_tools.zsh` | 跨平台服務狀態 —— Linux 用 `systemctl status`、macOS 用 `launchctl print DOMAIN/LABEL`。接受 `--user`。用法：`svcstat [--user] <service>` |

---

## Media / AV

> 影音由 `ffmpeg` 提供、圖片由 `ImageMagick` 提供。只要任何一個媒體工具在 `$PATH` 上就會載入（通常透過 `installMediaTools=true`）。每個 function 自行檢查需要的工具。底層工具見 [docs/tools/ffmpeg.md](../tools/ffmpeg.md) 與 [docs/tools/imagemagick.md](../tools/imagemagick.md)。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `compress-video <input>` | function | `dot_config/zsh/tools/29_media.zsh` | 用 x264 CRF 28 重編碼 → `<name>_compressed.mp4`（更小；想換畫質直接改 CRF） |
| `extract-audio <input>` | function | `dot_config/zsh/tools/29_media.zsh` | 去掉影像、複製音訊 stream → `<name>.m4a`（不重新編碼） |
| `to-wav16k <input>` | function | `dot_config/zsh/tools/29_media.zsh` | Resample 成 16 kHz 單聲道 WAV → `<name>_16k.wav`（Whisper / faster-whisper 輸入格式） |
| `compress-image <input> [<mb>=1]` | function | `dot_config/zsh/tools/29_media.zsh` | 重編碼成體積在目標 MB 以下的 JPEG → `<name>_<mb>mb.jpg`；使用 ImageMagick `-define jpeg:extent=NMB`（內部自動迭代品質，不用手動二分搜）。Alpha 會被攤平成白色。 |
| `resize-image <input> <width_px>` | function | `dot_config/zsh/tools/29_media.zsh` | 縮放到寬度 = `<width_px>`，保持比例 → `<name>_<width>w.<ext>`；輸出延用原本格式 |
| `media-pick` | function | `dot_config/zsh/tools/29_media.zsh` | 互動式入口：[gum](../tools/gum.md) `file` 選檔 → 動作選單 →（必要時）參數輸入。把上面所有 helper 串起來；只有在 `gum` 已在 `$PATH` 時才載入。 |

---

## Shell Utilities

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `zsh-profile` | alias | `dot_config/zsh/10_aliases.zsh` | 對 zsh 啟動時間做效能剖析 (`ZSH_PROF=1 zsh -i -c exit`) |
| `ghostty-ssh-terminfo` | function | `dot_config/shell/10_aliases.sh` | 透過 SSH 在遠端主機上安裝 `xterm-ghostty` terminfo（無需特權） |
| `source-rc` | function | `dot_config/shell/10_aliases.sh` | **就地**重新載入目前 shell 的 rc（`~/.zshrc` 或 `~/.bashrc`，依 `$ZSH_VERSION`/`$BASH_VERSION` 自動偵測）—— `chezmoi apply` 後不必開新 login shell 就能吃到新的 alias/function。是 `exec` 型 `cas`/`cau` 的輕量版本；與手動 `source ~/.zshrc` 有相同的注意事項 |
| `reload` | alias | `dot_config/shell/10_aliases.sh` | `source-rc` 的簡短別名。現已跨 shell（先前僅 bash 的 `. ~/.bashrc`） |
| `tldrf` | function | `dot_config/zsh/tools/28_tldr.zsh` | 帶語言退回的 `tldr`：zh_TW → zh → en *(需要 tldr)* |

---

## Tmux Integration

> 需要 tmux + pane scrollback 中的 OSC 133 標記（由 [`02_shell_integration.zsh`](../../dot_config/zsh/tools/02_shell_integration.zsh) 發出 —— 若缺少，執行 `exec zsh` 重新載入）。三個函式都會輸出至 stdout（可管線：`cpout | grep ERROR`），並透過 tmux 的 OSC 52 橋接複製到系統剪貼簿。對應於 `prefix + M-y` / `M-i` tmux 綁定的 shell 層版本 —— 見 [docs/tools/tmux/README.md → OSC 133](../tools/tmux/README.md#osc-133-command-boundary-navigation-warp-style)。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cpout [N]` | function | `dot_config/zsh/tools/03_tmux_capture.zsh` | 印出 + 複製**第 N 個最近命令的輸出**（預設 N=1）。接受位置整數 (positional integer) 作為回看 |
| `cpcmd [N]` | function | `dot_config/zsh/tools/03_tmux_capture.zsh` | 印出 + 複製**第 N 個最近命令的輸入行**（預設 N=1）。讀取 zsh 歷史，因此在 tmux 之外也能用 |
| `cpblock [N]` | function | `dot_config/zsh/tools/03_tmux_capture.zsh` | 印出 + 複製**第 N 個最近命令的完整區塊**（prompt + input + output）。預設 N=1 |

---

## AI Capture

> 一次性管線：擷取過去的區塊（透過 `cpblock N`），並以非互動式 / 顧問模式傳給 coding-agent CLI（claude / opencode / codex / cursor-agent）。Agent 依列出順序自動偵測；以 `-a AGENT` 覆寫。Prompt 以 `-p PROMPT` 覆寫。Agent 回覆送至 stdout（可管線：`aifix | tee /tmp/advice.md`），狀態行送至 stderr。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `aifix [N] [-a AGENT] [-p PROMPT]` | function | `dot_config/zsh/tools/04_ai_capture.zsh` | 擷取第 N 個區塊（tmux），請 agent 診斷 + 建議修復 |
| `aiexplain [N] [-a AGENT] [-p PROMPT]` | function | `dot_config/zsh/tools/04_ai_capture.zsh` | 擷取第 N 個區塊（tmux），請 agent 解釋發生什麼事 |
| `aifix-stdin [-a AGENT] [-p PROMPT]` | function | `dot_config/zsh/tools/04_ai_capture.zsh` | 非 tmux：將 stdin 作為 context 讀取，請 agent（`tail -100 log \| aifix-stdin`） |
| `aifix-run -- CMD [ARG...]` | function | `dot_config/zsh/tools/04_ai_capture.zsh` | 非 tmux：執行 CMD 並 tee stdout+stderr，餵給 agent |
| `aifix-rerun [-y]` | function | `dot_config/zsh/tools/04_ai_capture.zsh` | 非 tmux：thefuck 風格地重新執行最後一個命令（除非 `-y` 否則會確認；副作用警告） |
| `aiblock` | function | `dot_config/zsh/tools/04_ai_capture.zsh` | 啟動 `scripts/aiblock.py` TUI：從歷史挑選命令、編輯 prompt、挑選動作（print / copy / 生成新 agent 視窗）。透過 `uv run --script` 解析依賴 |

---

## Claude Code

> 專案區域 (project-local) 的 Claude Code 設定輔助。僅在 merge 路徑（目標檔案已存在時）需要 `jq`。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `claude-plans-here [-f] [-y]` | function | `dot_config/shell/10_aliases.sh` | 建構/更新 `./.claude/settings.json`，使 Claude Code 的 `/plan` 檔案落在 `./.claude/plans/`（在 repo 內）。同時 `mkdir -p .claude/plans/` 並提供匯入「孤兒」(orphan) plans 的選項 —— 也就是先前寫在全域 `~/.claude/plans/` 中、屬於本 cwd 或 git-root 的 plans。偵測會解析 `~/.claude/projects/<encoded-path>/*.jsonl` 中的權威寫入/結果欄位（`Write`/`Edit`/`MultiEdit` 路徑、`toolUseResult.filePath`、`ExitPlanMode.planFilePath`），不採計聊天提及。`-f` 自動同意 settings 合併提示；`-y` 自動同意孤兒複製提示。`~/.claude/plans/` 中的原始檔案會保留 |

---

## Copilot agent gateway

> 用 **GitHub Copilot** served 的模型驅動 Claude Code 與 Codex，透過只安裝一次、版本釘選的 [copilot-api 維護 fork](https://github.com/caozhiyuan/copilot-api)。Claude Code 有 entitlement 時優先 Claude，否則建立 Sol/Terra/Luna 角色 profile；Codex 優先 native Responses OpenAI model。完整指南、**ToS / rate-limit 風險**與設定分層：[docs/tools/copilot-claude-proxy.md](../tools/copilot-claude-proxy.md)。首次需執行 `copilot-proxy auth`；launcher 不碰 committed project settings 或 chezmoi-managed user settings。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `copilot-proxy [start\|stop\|status\|stats\|events\|limiter\|logs\|quota\|bench\|update\|doctor\|…]` | function | `dot_config/shell/43_copilot_proxy.sh` | 管理並量測釘選 proxy。預設 `:4142` shim 把不含內容的 timing 寫入獨立 90 天 SQLite DB，並使用自適應 4→8 並行範圍；`limiter status/set/reset` 可不中斷 stream 即時調整，export `COPILOT_SHIM_MIN/MAX` 才會跨 restart 保留。`logs -f` / `logs shim -f` 可跨 rotation follow。`stats/events --json` 可離線使用，並區分 client cancel 與 upstream failure。`doctor` 會指出目前 fork 丟棄 Codex fast `service_tier`。`bench` 有安全上限但消耗真實 quota。completion：`61_copilot_proxy_completion.{zsh,bash}`。 |
| `claude-copilot [--no-specstory] [args...]` | function | `dot_config/shell/43_copilot_proxy.sh` | 一次性走 proxy 的 Claude Code session，**零檔案寫入**：自動啟動 proxy，per-process 注入完整 role-aware `ANTHROPIC_*` env。既有 `copilot-here` local pin 會蓋過這層。specstory passthrough 會保留設定的 `claude_cmd`；下次直接跑 `claude` 即還原。 |
| `codex-copilot [--no-specstory] [args...]` / `codex-copilot-once` | function | `dot_config/shell/43_copilot_proxy.sh` | 零持久化的 Codex launcher，走本機 Responses gateway。自動啟動 proxy/shim；明確 `-m` 優先，否則即時排序 OpenAI/Codex → Claude → Gemini。預設整合 SpecStory 並保留 project/user `codex_cmd`；兩個名稱都不改 Codex config。 |
| `copilot-run <cmd...>` | function | `dot_config/shell/43_copilot_proxy.sh` | 泛用積木：自動啟動代理，然後帶著代理 env 執行 *任意* 指令（例如 `copilot-run specstory run claude`、`copilot-run claude --resume`） |
| `copilot-here [on\|off\|status]` | function | `dot_config/shell/43_copilot_proxy.sh` | 專案級持續開關，透過 **gitignored** 的 `./.claude/settings.local.json`（覆蓋會 commit 的專案設定，所以 `plansDirectory` 完全不受影響）。`on` 用 jq 合併代理 env 區塊並確保 git 忽略該檔（`.git/info/exclude`）；`off` 只移除那些 key（保留其他內容，檔案清空才刪除）；`status` 顯示釘選狀態 + 模型，代理沒跑時警告。需要 `jq` |
| `copilot-model [<id>\|-l\|-c\|--auto]` | function | `dot_config/shell/43_copilot_proxy.sh` | 切換 main 並產生完整 Claude Code role profile。`--auto` 要求 live `/v1/models`：Claude 優先，否則 Sol > Terra > GPT-5.5 > GPT-5.4 > GPT-5.3 Codex > Luna > mini > Gemini。OpenAI 映射 Main/Fable/Opus=Sol、Sonnet=Terra、Haiku/background=Luna；`[1m]` 由 context metadata 決定。Local pin 寫全部角色，global state 仍只存一行 main。`-c` 顯示完整 profile。 |
| `copilot-raycast [status\|generate [--dry-run] [--all]\|diff\|probe [MODEL]\|doctor\|edit]` | function | `dot_config/shell/45_copilot_raycast.sh` | 從即時的代理 (proxy) 模型清單產生 Raycast 的 AI **Custom Providers** 設定檔（`~/.config/raycast/ai/providers.yaml`），讓每個 Copilot 模型都出現在 Quick AI / AI Chat / AI Commands。每個 model id 都經過**零額度探針 (zero-quota probe)** 過濾——帶 `{"messages":[]}` 打 `POST /chat/completions` 會在推論 (inference) 前就被拒絕，而錯誤訊息可區分真正可用的模型（`messages must be non-empty`）與 `/v1/models` 只是「宣稱」有提供的模型（`model_not_supported`、`unsupported_api_for_model`）；靜態 metadata 裡沒有任何欄位能預測這件事。`base_url` 沿用 `_copilot_pinned_base`（throttle shim 開著時指向 shim），但掃描本身直接打 `:4141`。寫入前會備份到 `~/.local/state/copilot-raycast/backups/`、用 `yq` 驗證後才原子性 (atomic) 搬移——格式壞掉的檔案會讓 Raycast **無聲地**丟掉*所有* custom provider。檔案裡其他 provider 會原樣保留（需要 `yq`）。`status`/`doctor` 會讀 Raycast prefs 裡的 `raycastAI_modelRouterModelInfo`，顯示 Raycast 實際載入了什麼。需要 `jq` + `curl`；`yq` 用於驗證與保留。環境變數：`COPILOT_RAYCAST_{CONFIG,ID,LABEL,SUFFIX,TEMP,JOBS,PROBE_BASE,KEEP}` |

---

## Package Managers & Runtime

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `load-nvm` | alias | `dot_config/shell/10_aliases.sh` | 將 NVM 延遲載入 (lazy-load) 到當前 session（啟動時通常會略過） |
| `bw-update-completion` | alias | `dot_config/shell/10_aliases.sh` | 重新產生快取的 Bitwarden zsh 補全檔案 |
| `brew-mirror` | function | `dot_config/shell/10_aliases.sh` | 即時切換 Homebrew 鏡像（GFW 解法）：`brew-mirror {bfsu\|ustc\|aliyun\|tuna}`。設定 bottle/API + brew.git 環境變數，並 unset `HOMEBREW_CORE_GIT_REMOTE`（同時自動 untap 殘留的 >100 MB homebrew/core clone）；無參數時印出當前 endpoints。預設基準為 **BFSU**（在 `dot_config/shell/00_exports.sh.tmpl` 中設定;2026-07 benchmark 最快）。Aliyun 的 brew.git 壞掉，所以它的 preset 會保留既有的 git remote |

---

## macOS 系統 (memory / swap / storage)

> macOS 專屬。Diagnose / reclaim / watch macOS memory pressure 與 swap accumulation —
> 即「儲存空間 > 系統資料」一夜暴增、Activity Monitor 顯示 `Swap Used: 17.59 GB` 但 Memory Pressure 還是綠的這個經典情況。
> 完整深入解說：[tools/macos-swap.zh-TW.md](../tools/macos-swap.zh-TW.md)。Pitfall 案例：[`pitfalls/macos-swap-files-never-shrink.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/macos-swap-files-never-shrink.md)。

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `mac-mem-status` | function | `dot_config/shell/55_macos_mem.sh.tmpl` | 單頁 memory + swap + storage 報告：`vm.swapusage`、`memory_pressure`、解析過的 `vm_stat`、swapfile 大小（`/System/Volumes/VM/swapfile*`）、按 compressed-aware memory 排前 10（`top -o mem`）、TM 本機快照數、彩色 verdict 行。不需 sudo。短別名：`mms`。 |
| `mac-mem-reclaim [--dry-run] [--yes] [--force] [--include LIST]` | function | `dot_config/shell/55_macos_mem.sh.tmpl` | 互動式清理。永遠安全：`sudo purge`。`--include` 加碼選項：`spotlight`（`killall mds_stores+mdworker_shared`）、`snapshots`（`tmutil thinlocalsnapshots / 5GB 4`）、`sleepimage`（刪 `/private/var/vm/sleepimage` —— 筆電不安全）、`windowserver`（`sudo killall -HUP WindowServer` —— 會把你登出）。短別名：`mmr`。 |
| `mac-mem-watch [INTERVAL_SEC]` | function | `dot_config/shell/55_macos_mem.sh.tmpl` | Live 一行一拍 tail：free / compressed / swap_used + 每秒 pageins / pageouts / swapins / swapouts。預設 5 秒。設計給 tmux 旁邊面板用。短別名：`mmw`。 |
