---
name: git-ops tv channel
overview: 新增一個 `git-ops` television channel，把 VSCode 原生 Source Control + GitLens 選單的 60-80 條 Git 操作（含 amend、undo last commit、signed-off、rebase、worktrees、cherry-pick 等）整理成單一 markdown 表格當 source of truth，提供 fuzzy 搜尋、貼到 shell buffer（Enter）、複製指令（Ctrl+Y）、直接執行（Ctrl+E）三種動作。
todos:
  - id: source-md
    content: 新增 dot_config/docs/tools/git-ops.md：依 GitLens 選單分節的 ~70 條 markdown 表格（Menu | Command | Description | Notes）
    status: completed
  - id: channel-toml
    content: 新增 dot_config/television/cable/git-ops.toml：awk 解析 md、以 │ 對齊輸出、綁定 Ctrl+Y（copy）和 Ctrl+E（confirm+exec）
    status: completed
  - id: zle-widget
    content: 更新 dot_config/zsh/tools/12_television.zsh：新增 _tv_gitops widget 和 Alt+I 綁定，從 │ 前的 command 欄插到 LBUFFER
    status: completed
  - id: docs-update
    content: 更新 docs/tools/tv.md：在 ansible 和 pueue 之間新增 git-ops 章節，包含 keybinding 表和使用範例
    status: completed
  - id: verify
    content: 驗證：chezmoi apply、tv list-channels、模糊搜尋 amend、Alt+I 貼到 prompt、Ctrl+Y 到 pbpaste
    status: completed
  - id: todo-1776760606335-148xohmr4
    content: 驗證 keyboard shortcuts 不會conflict (e.g. tmux, ...)
    status: completed
  - id: todo-1776760630465-s4tyw0boq
    content: git commit (with specstory story chat history)
    status: completed
isProject: false
---

# git-ops tv channel

## 設計總覽

三層 single-source-of-truth 架構，完全沿用 `tools` + `aliases` channel 的既有模式：

```mermaid
flowchart LR
  md[dot_config/docs/tools/git-ops.md<br/>markdown table]
  toml[dot_config/television/cable/git-ops.toml<br/>channel config]
  zle[dot_config/zsh/tools/12_television.zsh<br/>ZLE widget _tv_gitops]

  md -->|awk -F'|' at runtime| toml
  toml -->|tv git-ops| user1[standalone: Enter=print, Ctrl+Y=copy, Ctrl+E=exec]
  toml -->|tv git-ops --inline| zle
  zle -->|Alt+I| user2[zsh: pastes command into LBUFFER]
```

## 檔案變更

### 1. 新增 `dot_config/docs/tools/git-ops.md`（source of truth，~70 行條目）

Markdown 表格，欄位固定為 `Menu | Command | Description | Notes`，依照 GitLens 選單結構分節。Notes 欄用來標註 `destructive`（amend after push、`reset --hard`、`push --force`）。範例節錄：

```markdown
## Commit

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Commit | `git commit` | Open editor to commit staged | |
| Commit Staged | `git commit -m ` | Commit staged with inline message | |
| Commit All | `git commit -a` | Stage tracked + commit | |
| Commit (Amend) | `git commit --amend` | Amend last commit, reopen editor | destructive |
| Commit Staged (Amend) | `git commit --amend --no-edit` | Amend, keep original message | destructive |
| Commit All (Amend) | `git commit -a --amend --no-edit` | Re-amend with all tracked changes | destructive |
| Commit (Signed Off) | `git commit -s` | Add Signed-off-by trailer | |
| Undo Last Commit | `git reset --soft HEAD~1` | Undo, keep changes staged | |
| Undo Last Commit (keep worktree) | `git reset --mixed HEAD~1` | Undo, unstage changes | |
| Undo Last Commit (discard) | `git reset --hard HEAD~1` | Undo AND discard changes | destructive |
| Abort Rebase | `git rebase --abort` | Cancel in-progress rebase | |
```

分節會對應圖裡那個 GitLens 選單：Pull/Push/Clone/Fetch、Commit、Changes、Branch、Remote、Stash、Tags、Worktrees、Rebase/Cherry-pick/Merge、Log/Graph/Show、Diff/Blame、Submodule、Config。

### 2. 新增 `dot_config/television/cable/git-ops.toml`

Awk 從 md 抽出 4 欄，輸出以 `│` 分隔（和 `channels.toml` 現有視覺一致），第一欄放 command 方便 ZLE widget 用 `${output%%│*}` 取出：

```toml
[metadata]
name = "git-ops"
description = "VSCode + GitLens Git operations: search, paste, copy, or exec"

[source]
command = """
awk -F'|' '/^[[:space:]]*\\|[[:space:]]*`/ {
  label=$2; cmd=$3; desc=$4; notes=$5
  for (i in a) a[i]=""
  gsub(/^ *| *$/, "", label); gsub(/^ *| *$/, "", desc); gsub(/^ *| *$/, "", notes)
  gsub(/^ *`|` *$/, "", cmd); gsub(/^ *| *$/, "", cmd)
  tag = (notes ~ /destructive/) ? "⚠" : " "
  printf "%-48s │ %s %-34s │ %s\\n", cmd, tag, label, desc
}' ~/.config/docs/tools/git-ops.md
"""

[preview]
command = """
label='{split:│:1}'
label="${label## }"; label="${label#⚠ }"; label="${label%% *}"
grep -B1 -A1 "^| *${label}" ~/.config/docs/tools/git-ops.md | bat -l md --plain --color=always 2>/dev/null
"""

[keybindings]
ctrl-y = "actions:copy"
ctrl-e = "actions:exec"

[actions.copy]
description = "Copy command to clipboard"
command = """
cmd='{split:│:0}'; cmd="${cmd% *}"
if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$cmd" | pbcopy
elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$cmd" | wl-copy
elif command -v xclip >/dev/null 2>&1; then printf '%s' "$cmd" | xclip -selection clipboard
fi
"""
mode = "fork"

[actions.exec]
description = "Execute command directly"
command = """
cmd='{split:│:0}'; cmd="${cmd% *}"
printf 'Run: %s\\n[y/N]: ' "$cmd"; read -r ans
[ "$ans" = "y" ] && eval "$cmd"
"""
mode = "execute"
```

不覆寫 `enter` → 沿用 TV 預設「印出選取列並退出」，由 ZLE widget 吃掉 stdout 取 command 欄。

### 3. 更新 [`dot_config/zsh/tools/12_television.zsh`](dot_config/zsh/tools/12_television.zsh)

在第 72–89 行既有的 widget 區塊加入 `_tv_gitops` 和 `Alt+I` 綁定：

```bash
_tv_gitops() {
  emulate -L zsh
  zle -I
  local output cmd
  output=$(tv git-ops --no-status-bar --inline < /dev/tty)
  zle reset-prompt
  if [[ -n $output ]]; then
    cmd="${output%%│*}"
    cmd="${cmd%"${cmd##*[! ]}"}"
    LBUFFER+="$cmd"
  fi
}
zle -N tv-gitops _tv_gitops
bindkey '\ei' tv-gitops   # Alt+I = insert git operation
```

`Alt+I` 在現有綁定（Alt+R/P/G/E/A）裡沒衝突。

### 4. 更新 [`docs/tools/tv.md`](docs/tools/tv.md)

在 `ansible` 和 `pueue` 之間插入新的 `### git-ops channel` 一節，說明：

- 來源：`~/.config/docs/tools/git-ops.md`（md 表格是唯一來源，改 md 即改 channel）
- 兩種開啟方式：`tv git-ops`（standalone）/ `Alt+I`（zsh 內貼到 buffer）
- Keybinding 表：`Enter` / `Ctrl+Y` / `Ctrl+E` / `Ctrl+/`
- 標註 `⚠ destructive` 條目的意義

## 驗證步驟

1. `chezmoi apply` 部署三個檔案
2. `tv list-channels | grep git-ops` 確認註冊成功
3. `tv git-ops`、輸入 `amend` 應該看到三條 Commit (Amend) 變體
4. 新開 zsh session，按 `Alt+I`，選 `Undo Last Commit`，確認 `git reset --soft HEAD~1` 被貼到 prompt
5. 選一條按 `Ctrl+Y`，`pbpaste` 驗證剪貼簿內容

## 不做的事

- 不做 chezmoi templating（git 指令跨平台一致，不需 `.tmpl`）
- 不做 community `git-log` / `git-branch` / `git-stash` channel 的重新包裝（那些是針對 live repo 資料的動態 channel，本 channel 是「靜態指令查表」，角色不同、不衝突）
- 不整合 lazygit / git-graph —— 那些已經是 TUI，這個 channel 專門解決「指令記不住 + 要複製字串」的問題
