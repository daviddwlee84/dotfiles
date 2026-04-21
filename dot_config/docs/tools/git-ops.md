# Git Operations Reference

All Git commands exposed by VSCode's built-in Source Control and the GitLens
extension, organised by menu section. This is the **single source of truth** for
the `git-ops` television channel (`tv git-ops`) and the Alt+I zsh ZLE widget.

> Parser rules (keep stable or update `dot_config/television/cable/git-ops.toml`):
>
> - Column order is fixed: `Menu | Command | Alias | Description | Notes`.
> - A row is emitted to the channel iff the **Command** cell (3rd column)
>   contains a backtick-wrapped command — that's how the awk parser filters
>   out the header and separator rows.
> - The **Alias** column is shown in the TV picker so `fzf`-style search on
>   `gc!`, `gundo`, `gcam`, `gpf!`, etc. (oh-my-zsh `git` plugin + custom)
>   finds the right row. Leave blank when no stable alias exists.
> - Mark rewriting / destructive operations with the token `destructive` in
>   **Notes**; the channel renders them with a `⚠` prefix.
> - A trailing space inside backticks (e.g. `` `git commit -m ` ``) signals
>   "this command needs an argument" — Alt+I pastes it with the cursor ready.
> - Custom aliases/functions (from `dot_config/zsh/10_aliases.zsh`) are
>   prefixed with `*` in the Alias column to distinguish from oh-my-zsh ones.

---

## Status, Diff, Blame

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Status | `git status` | `gst` | Show working tree status | |
| Status (short) | `git status -sb` | `gsb` | Compact status with branch info | |
| Diff (unstaged) | `git diff` | `gd` | Show unstaged changes | |
| Diff (staged) | `git diff --staged` | `gds` | Show staged changes | |
| Diff (cached) | `git diff --cached` | `gdca` | Show cached diff (alias of --staged) | |
| Diff (HEAD) | `git diff HEAD` | | Show all changes vs last commit | |
| Diff Word-Level | `git diff --word-diff` | `gdw` | Word-level diff output | |
| Diff vs Upstream | `git diff @{upstream}` | `gdup` | Diff against upstream branch | |
| Blame File | `git blame ` | | Show per-line author/commit | needs file path |
| Blame (ignore whitespace) | `git blame -w ` | `gbl` | Blame ignoring whitespace changes | needs file path |
| Show Commit | `git show ` | `gsh` | Show a commit's diff + message | needs ref (HEAD, sha) |
| Show with Signature | `git show --pretty=short --show-signature` | `gsps` | Show commit incl. GPG signature | |
| Show File at Commit | `git show HEAD:` | | Show file contents at a ref | needs `HEAD:path` |

---

## Pull, Push, Fetch, Sync

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Pull | `git pull` | `gl` | Fetch + merge from upstream | |
| Pull (rebase) | `git pull --rebase` | `gpr` | Fetch + rebase onto upstream | |
| Pull (rebase + autostash) | `git pull --rebase --autostash` | `gpra` | Rebase pull, auto-stash dirty worktree | |
| Pull (ff-only) | `git pull --ff-only` | | Pull only if fast-forward possible | |
| Pull (current from origin) | `git pull origin <current>` | `ggu` | oh-my-zsh function, current branch | |
| Push | `git push` | `gp` | Push current branch to upstream | |
| Push (dry run) | `git push --dry-run` | `gpd` | Show what would be pushed | |
| Push (set upstream) | `git push --set-upstream origin <current>` | `gpsup` | Push and track remote branch | |
| Push (current to origin) | `git push origin <current>` | `ggp` | oh-my-zsh function, current branch | |
| Push Tags | `git push --tags` | | Push all tags | |
| Push Follow Tags | `git push --follow-tags` | | Push commits + annotated tags they reach | |
| Push All + Tags | `git push origin --all && git push origin --tags` | `gpoat` | Push all branches, then tags | |
| Force Push (safe) | `git push --force-with-lease` | `gpf` | Force push with concurrency check | destructive |
| Force Push | `git push --force` | `gpf!` | Unsafe force push | destructive |
| Fetch | `git fetch` | `gf` | Fetch from default remote | |
| Fetch All | `git fetch --all --tags --prune --jobs=10` | `gfa` | Fetch every remote, parallel, prune | |
| Fetch Origin | `git fetch origin` | `gfo` | Fetch only origin | |
| Fetch Prune | `git fetch --prune` | | Fetch and remove stale remote-tracking refs | |
| Sync (pull --rebase && push) | `git pull --rebase && git push` | `gpnp` | GitLens-style sync | |

---

## Clone, Init

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Clone | `git clone ` | | Clone a repository | needs URL |
| Clone (recurse submodules) | `git clone --recurse-submodules ` | `gcl` | Clone + init submodules | needs URL |
| Clone (shallow filtered) | `git clone --recursive --shallow-submodules --filter=blob:none ` | `gclf` | Blobless clone + shallow submodules | needs URL |
| Clone (depth=1) | `git clone --depth=1 ` | | Shallow clone, latest commit only | needs URL |
| Init | `git init` | | Initialise a new repository | |
| Init (main) | `git init -b main` | | Initialise with `main` as default branch | |

---

## Changes (Stage / Unstage / Restore)

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Stage File | `git add ` | `ga` | Stage a file | needs path |
| Stage All | `git add --all` | `gaa` | Stage all changes including deletions | |
| Stage Tracked | `git add --update` | `gau` | Stage modifications + deletions only | |
| Stage Verbose | `git add --verbose` | `gav` | Stage with verbose output | |
| Stage Interactive | `git add --patch` | `gapa` | Hunk-by-hunk staging | |
| Apply Patch | `git apply` | `gap` | Apply a patch file | |
| Apply 3-way | `git apply --3way` | `gapt` | Apply patch with 3-way merge fallback | |
| Unstage File | `git restore --staged ` | `grst` | Unstage a file, keep changes | needs path |
| Unstage All | `git restore --staged .` | | Unstage everything | |
| Restore from Source | `git restore --source ` | `grss` | Restore file from a ref | needs ref |
| Discard File | `git restore ` | `grs` | Discard unstaged changes in file | destructive |
| Discard All | `git restore .` | | Discard all unstaged changes | destructive |
| Clean Untracked (interactive) | `git clean --interactive -d` | `gclean` | Interactively remove untracked | |
| Clean Untracked (force) | `git clean -fd` | | Remove untracked files and dirs | destructive |
| Clean (dry run) | `git clean -nd` | | Preview `git clean` | |
| Pristine (reset + clean -dfx) | `git reset --hard && git clean --force -dfx` | `gpristine` | Nuke everything incl. ignored | destructive |
| Wipe (reset + clean -df) | `git reset --hard && git clean --force -df` | `gwipe` | Nuke tracked + untracked, keep ignored | destructive |

---

## Commit

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Commit | `git commit --verbose` | `gc` | Open editor to commit staged (with diff) | |
| Commit (no-edit) | `git commit --verbose --no-edit` | `gcn` | Commit without editing message | |
| Commit Staged | `git commit -m ` | `gcmsg` | Commit staged with inline message | needs message |
| Commit All | `git commit --verbose --all` | `gca` | Stage tracked + commit in editor | |
| Commit All (message) | `git commit --all -m ` | `gcam` | Stage tracked + commit with inline message | needs message |
| Commit (Amend) | `git commit --verbose --amend` | `gc!` | Amend last commit, reopen editor | destructive |
| Commit Staged (Amend) | `git commit --verbose --no-edit --amend` | `gcn!` | Amend, keep original message | destructive |
| Commit All (Amend) | `git commit --verbose --all --amend` | `gca!` | Re-amend with all tracked changes (editor) | destructive |
| Commit All (Amend, no-edit) | `git commit --verbose --all --no-edit --amend` | `gcan!` | Re-amend silently | destructive |
| Commit Amend (new message) | `git commit --amend -m ` | `*gcam-amend` | Amend, replacing the message inline | destructive, needs message |
| Commit (Signed Off) | `git commit -s` | `gcas` | Stage tracked + signed-off commit | |
| Commit Staged (Signed Off) | `git commit --signoff -m ` | `gcsm` | Signed-off inline message | needs message |
| Commit All (Signed Off) | `git commit --all --signoff -m ` | `gcasm` | Stage tracked + signed-off + message | needs message |
| Commit (GPG-sign) | `git commit --gpg-sign` | `gcs` | Commit with GPG signature | |
| Commit (GPG-sign + Signoff) | `git commit --gpg-sign --signoff` | `gcss` | GPG-signed and Signed-off-by | |
| Commit (Fixup) | `git commit --fixup=` | `gcfu` | Create fixup commit for autosquash | needs sha |
| Commit (Empty) | `git commit --allow-empty -m ` | | Empty commit (e.g. trigger CI) | needs message |
| WIP Commit (stage + commit) | `git wip` | `gwip` | Stage all + WIP commit that skips CI | |

---

## Undo, Reset, Revert

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Undo Last Commit | `git reset --soft HEAD~1` | `*gundo` | Undo commit, keep changes staged (prints msg) | |
| Undo Last WIP Commit | `git unwip` | `gunwip` | Undo the previous WIP commit | |
| Undo Last Commit (unstage) | `git reset --mixed HEAD~1` | | Undo commit, unstage but keep worktree | |
| Undo Last Commit (discard) | `git reset --hard HEAD~1` | | Undo commit AND discard changes | destructive |
| Reset | `git reset` | `grh` | Reset index from HEAD (default --mixed) | |
| Reset to Commit (soft) | `git reset --soft ` | `grhs` | Move HEAD, keep index + worktree | needs ref |
| Reset to Commit (keep) | `git reset --keep` | `grhk` | Reset but refuse if it'd lose local changes | |
| Reset to Commit (hard) | `git reset --hard ` | `grhh` | Move HEAD, wipe index + worktree | destructive |
| Reset to Origin | `git reset origin/<current> --hard` | `groh` | Hard-reset to origin/<current branch> | destructive |
| Revert Commit | `git revert ` | `grev` | Create inverse commit | needs sha |
| Revert (abort) | `git revert --abort` | `greva` | Cancel in-progress revert | |
| Revert (continue) | `git revert --continue` | `grevc` | Continue interactive revert | |
| Revert (no commit) | `git revert --no-commit ` | | Apply revert diff, keep staged | needs sha |
| Abort Rebase | `git rebase --abort` | `grba` | Cancel in-progress rebase | |
| Abort Merge | `git merge --abort` | `gma` | Cancel in-progress merge | |
| Abort Cherry-pick | `git cherry-pick --abort` | `gcpa` | Cancel in-progress cherry-pick | |
| Reflog | `git reflog` | `grf` | Local ref history for recovery | |
| Recover via Reflog | `git reset --hard HEAD@{1}` | | Jump HEAD to previous reflog entry | destructive |

---

## Branch

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Branch List | `git branch` | `gb` | List local branches | |
| Branch List (all) | `git branch --all` | `gba` | List local + remote branches | |
| Branch List (remote) | `git branch --remote` | `gbr` | List remote-tracking branches | |
| Branch List (no-merged) | `git branch --no-merged` | `gbnm` | Branches not yet merged | |
| Branch List (gone) | `git branch` (gone upstream) | `gbg` | Branches whose upstream is gone | |
| Delete Gone Branches | `git branch -d` (gone) | `gbgd` | Delete branches with gone upstream | |
| Force-delete Gone Branches | `git branch -D` (gone) | `gbgD` | Force-delete gone branches | destructive |
| Checkout | `git checkout ` | `gco` | Switch to branch/ref | needs ref |
| Checkout (with submodules) | `git checkout --recurse-submodules ` | `gcor` | Checkout and sync submodules | needs ref |
| Checkout Main | `git checkout $(git_main_branch)` | `gcm` | Jump to main/master | |
| Checkout Develop | `git checkout $(git_develop_branch)` | `gcd` | Jump to develop | |
| Switch | `git switch ` | `gsw` | Modern branch switch | needs branch |
| Switch Main | `git switch $(git_main_branch)` | `gswm` | Switch to main/master | |
| Switch Develop | `git switch $(git_develop_branch)` | `gswd` | Switch to develop | |
| Switch (detach) | `git switch --detach ` | | Switch in detached-HEAD mode | needs ref |
| New Branch (checkout -b) | `git checkout -b ` | `gcb` | Create and checkout new branch | needs name |
| New Branch (force -B) | `git checkout -B ` | `gcB` | Reset-or-create branch | needs name |
| New Branch (switch -c) | `git switch --create ` | `gswc` | Modern create + switch | needs name |
| New Branch (from ref) | `git switch -c  ` | | New branch based on ref | needs name + ref |
| Rename Branch | `git branch --move ` | `gbm` | Rename current branch | needs new name |
| Rename Branch (local+remote) | `grename old new` | `grename` | OMZ function: rename locally and on origin | |
| Delete Branch | `git branch --delete ` | `gbd` | Delete merged branch | needs name |
| Delete Branch (force) | `git branch --delete --force ` | `gbD` | Force delete unmerged branch | destructive |
| Delete Merged Branches | `git branch -d` (merged) | `gbda` | Delete all merged branches except main/develop | |
| Delete Squash-merged | `git branch -D` (squash) | `gbds` | Delete squash-merged branches | destructive |
| Delete Remote Branch | `git push origin --delete ` | `gpod` | Delete branch on remote | destructive |
| Set Upstream | `git branch --set-upstream-to=origin/<current>` | `ggsup` | Track a remote branch (current) | |

---

## Rebase, Cherry-pick, Merge

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Merge | `git merge ` | `gm` | Merge branch into current | needs branch |
| Merge (no-ff) | `git merge --no-ff ` | | Merge with explicit merge commit | needs branch |
| Merge (ff-only) | `git merge --ff-only ` | `gmff` | Refuse non-ff merge | needs branch |
| Merge (squash) | `git merge --squash ` | `gms` | Squash merge, requires follow-up commit | needs branch |
| Merge (continue) | `git merge --continue` | `gmc` | Continue in-progress merge | |
| Merge Main | `git merge origin/$(git_main_branch)` | `gmom` | Merge origin/main into current | |
| Merge Upstream Main | `git merge upstream/$(git_main_branch)` | `gmum` | Merge upstream/main into current | |
| Mergetool | `git mergetool --no-prompt` | `gmtl` | Launch configured mergetool | |
| Rebase | `git rebase ` | `grb` | Rebase current onto ref | needs ref; destructive |
| Rebase Interactive | `git rebase --interactive ` | `grbi` | Interactive rebase | needs ref; destructive |
| Rebase Interactive HEAD~5 | `git rebase -i HEAD~5` | | Interactive rebase last 5 commits | destructive |
| Rebase Autosquash | `git rebase -i --autosquash ` | | Interactive rebase + squash fixups | destructive |
| Rebase Continue | `git rebase --continue` | `grbc` | Resume rebase after resolving | |
| Rebase Skip | `git rebase --skip` | `grbs` | Skip current patch during rebase | |
| Rebase Onto | `git rebase --onto  ` | `grbo` | Rebase range onto new base | |
| Rebase onto Main | `git rebase $(git_main_branch)` | `grbm` | Rebase current onto main | destructive |
| Rebase onto Origin/Main | `git rebase origin/$(git_main_branch)` | `grbom` | Rebase onto origin/main | destructive |
| Cherry-pick | `git cherry-pick ` | `gcp` | Apply commit onto current branch | needs sha |
| Cherry-pick (continue) | `git cherry-pick --continue` | `gcpc` | Continue in-progress cherry-pick | |
| Cherry-pick (no commit) | `git cherry-pick -n ` | | Apply changes without committing | needs sha |
| Cherry-pick Range | `git cherry-pick ..` | | Apply range of commits | needs A..B |

---

## Stash

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Stash | `git stash push` | `gsta` | Stash tracked changes | |
| Stash (include untracked) | `git stash --include-untracked` | `gstu` | Stash tracked + untracked | |
| Stash (include all) | `git stash --all` | `gstall` | Stash everything, even ignored | |
| Stash with Message | `git stash push -m ` | | Named stash entry | needs message |
| Stash List | `git stash list` | `gstl` | List all stash entries | |
| Stash Show | `git stash show --patch` | `gsts` | Show latest stash diff | |
| Stash Pop | `git stash pop` | `gstp` | Apply latest stash and drop it | |
| Stash Apply | `git stash apply` | `gstaa` | Apply latest stash, keep it | |
| Stash Drop | `git stash drop` | `gstd` | Drop latest stash | destructive |
| Stash Clear | `git stash clear` | `gstc` | Drop ALL stashes | destructive |

---

## Tags

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Tag List | `git tag` | | List tags | |
| Tag List (version-sorted) | `git tag \| sort -V` | `gtv` | List tags sorted by semver | |
| Tag List (pattern) | `git tag --sort=-v:refname -n --list ` | `gtl` | Versioned list filtered by pattern | needs pattern |
| Tag Create | `git tag ` | | Create lightweight tag | needs name |
| Tag Annotated | `git tag --annotate  -m ` | `gta` | Annotated tag with message | needs name + message |
| Tag Sign | `git tag --sign  -m ` | `gts` | GPG-signed annotated tag | needs name + message |
| Tag Delete | `git tag -d ` | | Delete local tag | needs name |
| Tag Delete Remote | `git push origin --delete ` | `gpod` | Delete tag on remote (shared with branches) | needs tag; destructive |
| Tag Push | `git push origin ` | | Push a specific tag | needs tag |
| Describe Tags | `git describe --tags` | `gdct` | Name the current commit via nearest tag | |

---

## Remote

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Remote List | `git remote --verbose` | `grv` | List remotes with URLs | |
| Remote | `git remote` | `gr` | List remote names | |
| Remote Add | `git remote add  ` | `gra` | Add a new remote | needs name + URL |
| Remote Remove | `git remote remove ` | `grrm` | Remove a remote | needs name |
| Remote Rename | `git remote rename old new` | `grmv` | Rename a remote | |
| Remote Set URL | `git remote set-url origin ` | `grset` | Change remote URL | needs URL |
| Remote Update | `git remote update` | `grup` | Fetch updates from all remotes | |
| Remote Show | `git remote show origin` | | Inspect a remote | |
| Remote Prune | `git remote prune origin` | | Prune stale remote-tracking refs | |

---

## Worktrees

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Worktree | `git worktree` | `gwt` | Worktree command entry | |
| Worktree List | `git worktree list` | `gwtls` | List linked worktrees | |
| Worktree Add | `git worktree add  ` | `gwta` | Create a new worktree | needs path + ref |
| Worktree Add (new branch) | `git worktree add -b   ` | | New worktree on new branch | needs path + branch + ref |
| Worktree Move | `git worktree move  ` | `gwtmv` | Move a worktree to new path | needs src + dst |
| Worktree Remove | `git worktree remove ` | `gwtrm` | Remove a linked worktree | needs path |
| Worktree Prune | `git worktree prune` | | Clean up stale worktree metadata | |

---

## Log, Graph, Show

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Log | `git log` | | Full commit history | |
| Log Oneline | `git log --oneline --decorate` | `glo` | One line per commit with refs | |
| Log Graph | `git log --oneline --decorate --graph` | `glog` | ASCII graph of current branch | |
| Log Graph (all) | `git log --oneline --decorate --graph --all` | `gloga` | ASCII graph of all refs | |
| Log Stat | `git log --stat` | `glg` | Log with per-file change stats | |
| Log Patch | `git log --stat --patch` | `glgp` | Log with diffs | |
| Log Graph (decorated) | `git log --graph --decorate --all` | `glgga` | Graph + refs + all branches | |
| Log Pretty (short) | `git log --graph --pretty=...` | `glol` | Short log with author + relative date | |
| Log Pretty (all) | `git log --graph --pretty=... --all` | `glola` | Short log, all refs | |
| Log Pretty (date) | `git log --graph --pretty=... --date=short` | `glods` | Short log with absolute date | |
| Log Patch (wide) | `git log --patch --abbrev-commit --pretty=medium --raw` | `gwch` | Comprehensive patch log | |
| Log Me | `git log --author=@me` | | Filter to own commits | |
| Log Since | `git log --since=` | | Filter by date | needs date |
| Show Commit Graph | `git-graph --all` | | Visual branch graph (git-graph tool) | |
| Shortlog | `git shortlog --summary --numbered` | `gcount` | Contributor count | |
| LazyGit TUI | `lazygit` | `*lg` | Launch lazygit TUI | |

---

## Submodule, Bisect

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Submodule Init | `git submodule init` | `gsi` | Initialise submodule config | |
| Submodule Update | `git submodule update` | `gsu` | Sync submodule working tree | |
| Submodule Update (recursive) | `git submodule update --init --recursive` | | Init + sync all submodules | |
| Submodule Status | `git submodule status` | | Show submodule refs | |
| Submodule Sync | `git submodule sync --recursive` | | Propagate URL changes | |
| Submodule Foreach | `git submodule foreach ` | | Run command in each submodule | needs command |
| Bisect Start | `git bisect start` | `gbss` | Begin bisect session | |
| Bisect Good | `git bisect good` | `gbsg` | Mark commit as good | |
| Bisect Bad | `git bisect bad` | `gbsb` | Mark commit as bad | |
| Bisect New | `git bisect new` | `gbsn` | Mark commit as new (regression logic) | |
| Bisect Old | `git bisect old` | `gbso` | Mark commit as old | |
| Bisect Reset | `git bisect reset` | `gbsr` | End bisect session | |

---

## Config, Identity, Hooks

| Menu | Command | Alias | Description | Notes |
|------|---------|-------|-------------|-------|
| Config List | `git config --list` | `gcf` | List effective config | |
| Config List (origin) | `git config --list --show-origin` | | Config with source files | |
| Config Edit Global | `git config --global --edit` | | Open global `~/.gitconfig` | |
| Config Edit Local | `git config --edit` | | Open repo-local config | |
| Identity (local) | `git config user.email ` | | Set email for this repo | needs email |
| Identity Name (local) | `git config user.name ` | | Set name for this repo | needs name |
| Rerere Enable | `git config rerere.enabled true` | | Remember merge resolutions | |
| Hooks Path | `git config core.hooksPath .githooks` | | Point to repo-tracked hooks | |
| Help | `git help` | `ghh` | Open git help page | |
| Ignore File (assume) | `git update-index --assume-unchanged` | `gignore` | Tell git to ignore local changes | |
| Un-ignore File | `git update-index --no-assume-unchanged` | `gunignore` | Stop ignoring local changes | |
| List Ignored | List ignored files | `gignored` | Show all ignored files | |
| Repo Root (cd) | `cd "$(git rev-parse --show-toplevel)"` | `grt` | cd to repo top-level | |
