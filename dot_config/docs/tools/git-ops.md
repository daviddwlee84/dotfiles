# Git Operations Reference

All Git commands exposed by VSCode's built-in Source Control and the GitLens
extension, organised by menu section. This is the **single source of truth** for
the `git-ops` television channel (`tv git-ops`) and the Alt+I zsh ZLE widget.

> Parser rules (keep stable or update `dot_config/television/cable/git-ops.toml`):
>
> - Only rows beginning with `` | ` `` are emitted to the channel.
> - Column order is fixed: `Menu | Command | Description | Notes`.
> - The **Command** cell MUST be wrapped in single backticks.
> - Mark rewriting / destructive operations with the token `destructive` in
>   **Notes**; the channel renders them with a `⚠` prefix.
> - A trailing space inside backticks (e.g. `` `git commit -m ` ``) signals
>   "this command needs an argument" — Alt+I pastes it with the cursor ready.

---

## Status, Diff, Blame

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Status | `git status` | Show working tree status | |
| Status (short) | `git status -sb` | Compact status with branch info | |
| Diff (unstaged) | `git diff` | Show unstaged changes | |
| Diff (staged) | `git diff --staged` | Show staged changes | |
| Diff (HEAD) | `git diff HEAD` | Show all changes vs last commit | |
| Diff Word-Level | `git diff --word-diff` | Word-level diff output | |
| Blame File | `git blame ` | Show per-line author/commit | needs file path |
| Blame (ignore whitespace) | `git blame -w ` | Blame ignoring whitespace changes | needs file path |
| Show Commit | `git show ` | Show a commit's diff + message | needs ref (HEAD, sha) |
| Show File at Commit | `git show HEAD:` | Show file contents at a ref | needs `HEAD:path` |

---

## Pull, Push, Fetch, Sync

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Pull | `git pull` | Fetch + merge from upstream | |
| Pull (rebase) | `git pull --rebase` | Fetch + rebase onto upstream | |
| Pull (ff-only) | `git pull --ff-only` | Pull only if fast-forward possible | |
| Push | `git push` | Push current branch to upstream | |
| Push (set upstream) | `git push -u origin HEAD` | Push and track remote branch | |
| Push Tags | `git push --tags` | Push all tags | |
| Push Follow Tags | `git push --follow-tags` | Push commits + annotated tags they reach | |
| Force Push (safe) | `git push --force-with-lease` | Force push with concurrency check | destructive |
| Force Push | `git push --force` | Unsafe force push | destructive |
| Fetch | `git fetch` | Fetch from default remote | |
| Fetch All | `git fetch --all` | Fetch from every remote | |
| Fetch Prune | `git fetch --prune` | Fetch and remove stale remote-tracking refs | |
| Sync (pull --rebase && push) | `git pull --rebase && git push` | GitLens-style sync | |

---

## Clone, Init

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Clone | `git clone ` | Clone a repository | needs URL |
| Clone (shallow) | `git clone --depth=1 ` | Shallow clone, latest commit only | needs URL |
| Init | `git init` | Initialise a new repository | |
| Init (main) | `git init -b main` | Initialise with `main` as default branch | |

---

## Changes (Stage / Unstage / Restore)

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Stage File | `git add ` | Stage a file | needs path |
| Stage All | `git add -A` | Stage all changes including deletions | |
| Stage Tracked | `git add -u` | Stage modifications + deletions only | |
| Stage Interactive | `git add -p` | Hunk-by-hunk staging | |
| Unstage File | `git restore --staged ` | Unstage a file, keep changes | needs path |
| Unstage All | `git restore --staged .` | Unstage everything | |
| Discard File | `git restore ` | Discard unstaged changes in file | destructive |
| Discard All | `git restore .` | Discard all unstaged changes | destructive |
| Clean Untracked | `git clean -fd` | Remove untracked files and dirs | destructive |
| Clean (dry run) | `git clean -nd` | Preview `git clean` | |

---

## Commit

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Commit | `git commit` | Open editor to commit staged | |
| Commit Staged | `git commit -m ` | Commit staged with inline message | needs message |
| Commit All | `git commit -a` | Stage tracked + commit in editor | |
| Commit All (message) | `git commit -am ` | Stage tracked + commit with inline message | needs message |
| Commit (Amend) | `git commit --amend` | Amend last commit, reopen editor | destructive |
| Commit Staged (Amend) | `git commit --amend --no-edit` | Amend, keep original message | destructive |
| Commit All (Amend) | `git commit -a --amend --no-edit` | Re-amend with all tracked changes | destructive |
| Commit (Signed Off) | `git commit -s` | Add Signed-off-by trailer | |
| Commit Staged (Signed Off) | `git commit -s -m ` | Signed-off inline message | needs message |
| Commit All (Signed Off) | `git commit -a -s` | Stage tracked + signed-off commit | |
| Commit (Fixup) | `git commit --fixup=` | Create fixup commit for autosquash | needs sha |
| Commit (Empty) | `git commit --allow-empty -m ` | Empty commit (e.g. trigger CI) | needs message |

---

## Undo, Reset, Revert

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Undo Last Commit | `git reset --soft HEAD~1` | Undo commit, keep changes staged | |
| Undo Last Commit (unstage) | `git reset --mixed HEAD~1` | Undo commit, unstage but keep worktree | |
| Undo Last Commit (discard) | `git reset --hard HEAD~1` | Undo commit AND discard changes | destructive |
| Reset to Commit (soft) | `git reset --soft ` | Move HEAD, keep index + worktree | needs ref |
| Reset to Commit (hard) | `git reset --hard ` | Move HEAD, wipe index + worktree | destructive |
| Revert Commit | `git revert ` | Create inverse commit | needs sha |
| Revert (no commit) | `git revert --no-commit ` | Apply revert diff, keep staged | needs sha |
| Abort Rebase | `git rebase --abort` | Cancel in-progress rebase | |
| Abort Merge | `git merge --abort` | Cancel in-progress merge | |
| Abort Cherry-pick | `git cherry-pick --abort` | Cancel in-progress cherry-pick | |
| Reflog | `git reflog` | Local ref history for recovery | |
| Recover via Reflog | `git reset --hard HEAD@{1}` | Jump HEAD to previous reflog entry | destructive |

---

## Branch

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Branch List | `git branch` | List local branches | |
| Branch List (all) | `git branch -a` | List local + remote branches | |
| Branch List (verbose) | `git branch -vv` | Local with upstream + last commit | |
| Checkout | `git checkout ` | Switch to branch/ref | needs ref |
| Switch | `git switch ` | Modern branch switch | needs branch |
| Switch (detach) | `git switch --detach ` | Switch in detached-HEAD mode | needs ref |
| New Branch | `git switch -c ` | Create and switch to new branch | needs name |
| New Branch (from ref) | `git switch -c  ` | New branch based on ref | needs name + ref |
| Rename Branch | `git branch -m ` | Rename current branch | needs new name |
| Delete Branch | `git branch -d ` | Delete merged branch | needs name |
| Delete Branch (force) | `git branch -D ` | Force delete unmerged branch | destructive |
| Delete Remote Branch | `git push origin --delete ` | Delete branch on remote | destructive |
| Set Upstream | `git branch --set-upstream-to=origin/` | Track a remote branch | needs branch |

---

## Rebase, Cherry-pick, Merge

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Merge | `git merge ` | Merge branch into current | needs branch |
| Merge (no-ff) | `git merge --no-ff ` | Merge with explicit merge commit | needs branch |
| Merge (squash) | `git merge --squash ` | Squash merge, requires follow-up commit | needs branch |
| Rebase | `git rebase ` | Rebase current onto ref | needs ref; destructive |
| Rebase Interactive | `git rebase -i HEAD~5` | Interactive rebase last N commits | destructive |
| Rebase Autosquash | `git rebase -i --autosquash ` | Interactive rebase + squash fixups | destructive |
| Rebase Continue | `git rebase --continue` | Resume rebase after resolving | |
| Rebase Skip | `git rebase --skip` | Skip current patch during rebase | |
| Cherry-pick | `git cherry-pick ` | Apply commit onto current branch | needs sha |
| Cherry-pick (no commit) | `git cherry-pick -n ` | Apply changes without committing | needs sha |
| Cherry-pick Range | `git cherry-pick ..` | Apply range of commits | needs A..B |

---

## Stash

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Stash | `git stash` | Stash tracked changes | |
| Stash (include untracked) | `git stash -u` | Stash tracked + untracked | |
| Stash (include all) | `git stash -a` | Stash everything, even ignored | |
| Stash with Message | `git stash push -m ` | Named stash entry | needs message |
| Stash List | `git stash list` | List all stash entries | |
| Stash Show | `git stash show -p` | Show latest stash diff | |
| Stash Pop | `git stash pop` | Apply latest stash and drop it | |
| Stash Apply | `git stash apply` | Apply latest stash, keep it | |
| Stash Drop | `git stash drop` | Drop latest stash | destructive |
| Stash Clear | `git stash clear` | Drop ALL stashes | destructive |

---

## Tags

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Tag List | `git tag` | List tags | |
| Tag Create | `git tag ` | Create lightweight tag | needs name |
| Tag Annotated | `git tag -a  -m ` | Annotated tag with message | needs name + message |
| Tag Sign | `git tag -s  -m ` | GPG-signed annotated tag | needs name + message |
| Tag Delete | `git tag -d ` | Delete local tag | needs name |
| Tag Delete Remote | `git push origin --delete ` | Delete tag on remote | needs tag; destructive |
| Tag Push | `git push origin ` | Push a specific tag | needs tag |

---

## Remote

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Remote List | `git remote -v` | List remotes with URLs | |
| Remote Add | `git remote add  ` | Add a new remote | needs name + URL |
| Remote Remove | `git remote remove ` | Remove a remote | needs name |
| Remote Rename | `git remote rename old new` | Rename a remote | |
| Remote Set URL | `git remote set-url origin ` | Change remote URL | needs URL |
| Remote Show | `git remote show origin` | Inspect a remote | |
| Remote Prune | `git remote prune origin` | Prune stale remote-tracking refs | |

---

## Worktrees

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Worktree List | `git worktree list` | List linked worktrees | |
| Worktree Add | `git worktree add  ` | Create a new worktree | needs path + ref |
| Worktree Add (new branch) | `git worktree add -b   ` | New worktree on new branch | needs path + branch + ref |
| Worktree Remove | `git worktree remove ` | Remove a linked worktree | needs path |
| Worktree Prune | `git worktree prune` | Clean up stale worktree metadata | |

---

## Log, Graph, Show

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Log | `git log` | Full commit history | |
| Log Oneline | `git log --oneline` | One line per commit | |
| Log Graph | `git log --oneline --graph --decorate --all` | ASCII graph of all refs | |
| Log Stat | `git log --stat` | Log with per-file change stats | |
| Log Patch | `git log -p` | Log with full diffs | |
| Log Me | `git log --author=@me` | Filter to own commits | |
| Log Since | `git log --since=` | Filter by date | needs date |
| Show Commit Graph | `git-graph --all` | Visual branch graph (git-graph tool) | |
| Shortlog | `git shortlog -sn` | Contributor count | |

---

## Submodule

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Submodule Update | `git submodule update --init --recursive` | Initialise + sync all submodules | |
| Submodule Status | `git submodule status` | Show submodule refs | |
| Submodule Sync | `git submodule sync --recursive` | Propagate URL changes | |
| Submodule Foreach | `git submodule foreach ` | Run command in each submodule | needs command |

---

## Config, Identity, Hooks

| Menu | Command | Description | Notes |
|------|---------|-------------|-------|
| Config List | `git config --list --show-origin` | Effective config with source files | |
| Config Edit Global | `git config --global --edit` | Open global `~/.gitconfig` | |
| Config Edit Local | `git config --edit` | Open repo-local config | |
| Identity (local) | `git config user.email ` | Set email for this repo | needs email |
| Identity Name (local) | `git config user.name ` | Set name for this repo | needs name |
| Rerere Enable | `git config rerere.enabled true` | Remember merge resolutions | |
| Hooks Path | `git config core.hooksPath .githooks` | Point to repo-tracked hooks | |
