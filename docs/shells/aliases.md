# Custom Aliases & Shell Functions

Quick reference for custom aliases and shell functions defined in this dotfiles repo. Available in zsh, bash, or both — the source file path tells you which:

- `dot_config/shell/*.sh` — POSIX layer, sourced by **both** `~/.zshrc` and `~/.bashrc`.
- `dot_config/zsh/*.zsh` (or `tools/*.zsh`) — **zsh-only**.
- `dot_config/bash/*.bash` — **bash-only**.

> **Maintenance rule** (mirrored in `CLAUDE.md`): whenever you add, modify, or remove a custom alias or shell function in `dot_config/{shell,zsh,bash}/`, update this table — include the type (`alias` or `function`), source file (relative to repo root), and a one-line description. Place new helpers in the right tier per the [CLAUDE.md three-tier rule](../../CLAUDE.md#custom-aliases--shell-functions--docsshellsaliasesmd).

---

## Table of Contents

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
- [Data Viewers](#data-viewers)
- [macOS apps](#macos-apps)
- [Media / AV](#media--av)
- [Clipboard History](#clipboard-history)
- [Shell Utilities](#shell-utilities)
- [Tmux Integration](#tmux-integration)
- [AI Capture](#ai-capture)
- [AI Run](#ai-run)
- [Claude Code](#claude-code)
- [Package Managers & Runtime](#package-managers--runtime)

---

## Editor

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `v` | alias | `dot_config/shell/10_aliases.sh` | Open Neovim (`nvim`) |

---

## File Listing

> Provided by `eza` (modern `ls` replacement). Only active when `eza` is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ls` | alias | `dot_config/shell/26_eza.sh` | Compact listing; icons + colors on TTY, plain when piped |
| `la` | alias | `dot_config/shell/26_eza.sh` | Long listing including hidden files, dirs-first; icons/colors auto |
| `ll` | alias | `dot_config/shell/26_eza.sh` | Long listing, dirs-first (no hidden files); icons/colors auto |
| `lt` | alias | `dot_config/shell/26_eza.sh` | Tree view, 2 levels deep; icons/colors auto |
| `llt` | alias | `dot_config/shell/26_eza.sh` | Long tree view, 3 levels deep; icons/colors auto |

---

## Navigation

> `cd` is only replaced when `zoxide` is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cd` | alias | `dot_config/shell/20_zoxide.sh` | Smart `cd` via zoxide (`z`) with frecency-based matching |

---

## Git

### Custom (this repo)

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `gcam-amend` | function | `dot_config/shell/10_aliases.sh` | `git commit --amend -m "<msg>"` (replace message) |
| `gundo` | function | `dot_config/shell/10_aliases.sh` | Undo last commit → back to staged; prints undone commit message |
| `lg` | alias | `dot_config/shell/37_lazygit.sh` | Open lazygit TUI |

### oh-my-zsh git plugin

> Source: [oh-my-zsh git plugin](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/git). These are loaded automatically when the `git` plugin is enabled. Do **not** redefine these in custom configs.

<details>
<summary>Functions</summary>

| Command | Description |
|---------|-------------|
| `git_main_branch` | Detect default branch (`main`, `master`, `trunk`, etc.) |
| `git_develop_branch` | Detect develop branch (`dev`, `devel`, `develop`, etc.) |
| `grename <old> <new>` | Rename branch locally and on origin |
| `gunwipall` | Recursively unwip all recent `--wip--` commits |
| `work_in_progress` | Print "WIP!!" if last commit is a WIP |
| `gccd` | `git clone` then `cd` into the cloned directory |
| `gdv` | `git diff -w` piped to `view` |
| `gdnolock` | `git diff` excluding lock files |
| `ggu` | `git pull --rebase origin <current-branch>` |
| `ggl` | `git pull origin <current-branch>` |
| `ggp` | `git push origin <current-branch>` |
| `ggf` | `git push --force origin <current-branch>` |
| `ggfl` | `git push --force-with-lease origin <current-branch>` |
| `ggpnp` | Pull then push origin |
| `gbda` | Delete merged branches (except main/develop) |
| `gbds` | Delete squash-merged branches |

</details>

<details>
<summary>Aliases — Basic</summary>

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
<summary>Aliases — Add & Apply</summary>

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
<summary>Aliases — Branch</summary>

| Command | Command Expanded |
|---------|-----------------|
| `gb` | `git branch` |
| `gba` | `git branch --all` |
| `gbd` | `git branch --delete` |
| `gbD` | `git branch --delete --force` |
| `gbm` | `git branch --move` |
| `gbnm` | `git branch --no-merged` |
| `gbr` | `git branch --remote` |
| `gbg` | Show branches with gone upstream |
| `gbgd` | Delete branches with gone upstream |
| `gbgD` | Force-delete branches with gone upstream |
| `ggsup` | `git branch --set-upstream-to=origin/<current>` |

</details>

<details>
<summary>Aliases — Checkout & Switch</summary>

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
<summary>Aliases — Commit</summary>

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
<summary>Aliases — Diff</summary>

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
<summary>Aliases — Fetch & Pull</summary>

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
<summary>Aliases — Push</summary>

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
<summary>Aliases — Rebase</summary>

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
<summary>Aliases — Reset & Restore</summary>

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
<summary>Aliases — Log</summary>

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
| `glol` | `git log --graph --pretty` (short format with author + relative date) |
| `glols` | Same as `glol` with `--stat` |
| `glola` | Same as `glol` with `--all` |
| `glod` | Same as `glol` with absolute date |
| `glods` | Same as `glod` with `--date=short` |
| `glp` | `git log --pretty=<format>` |

</details>

<details>
<summary>Aliases — Merge</summary>

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
<summary>Aliases — Cherry-pick, Revert, Blame</summary>

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
<summary>Aliases — Remote</summary>

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
<summary>Aliases — Stash</summary>

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
<summary>Aliases — Tag, Worktree, Submodule, Bisect & Others</summary>

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
| `gdct` | `git describe --tags` (latest tag) |
| `gfg` | `git ls-files \| grep` |
| `gignored` | List ignored files |
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
| `gke` | `gitk --all` (including reflogs) |
| `gsd` | `git svn dcommit` |
| `gsr` | `git svn rebase` |
| `gwip` | Stage all + WIP commit (skip CI) |
| `gunwip` | Undo last WIP commit |

</details>

---

## Tools Picker

> Requires `fzf`. Data file (`~/.config/docs/tools/cli-tools.md`) must be deployed via `chezmoi apply`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `tools-picker` | function | `dot_config/zsh/tools/11_tools_picker.zsh` | fzf picker for installed CLI tools; Enter pastes invocation to buffer, Ctrl+E executes (bound to `Alt+T`) |
| `tv tools` | tv channel | `dot_config/television/cable/tools.toml` | Television picker for CLI tools; Enter executes, Ctrl+T shows tldrf page |
| `tv aliases` | tv channel | `dot_config/television/cable/aliases.toml` | Television picker for all runtime aliases & functions; Enter executes, Ctrl+Y copies name (bound to `Alt+A`) |
| `tv files` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television file picker (bound to `Alt+P`) |
| `tv history` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television shell history search (bound to `Alt+R`) |
| `tv git-log` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television git log browser (bound to `Alt+G`) |
| `tv env` | tv ZLE | `dot_config/zsh/tools/12_television.zsh` | Television environment variables picker (bound to `Alt+E`) |
| `tv ssh-config` | tv channel | `dot_config/television/cable/ssh-config.toml` | SSH host picker with `Include config.d/*` support; Enter connects |
| `tv ports` | tv channel | `dot_config/television/cable/ports.toml` | Listening ports picker with PID; Ctrl+K kills, Ctrl+D force kills |
| `tv kill-process` | tv channel | `dot_config/television/cable/kill-process.toml` | Raycast-style process killer: fuzzy search by name, CPU/MEM stats |
| `tv mac-apps` | tv channel | `dot_config/television/cable/mac-apps.toml.tmpl` | **macOS-only.** GUI app picker; Enter = activate (front), Alt+Q = graceful Quit, Alt+R = restart, Alt+H = hide, Alt+K = SIGKILL, Alt+I = info pager, Alt+P = responsiveness probe. Reuses `dot_config/shell/54_macos_apps.sh` helpers. |
| `tv linux-apps` | tv channel | `dot_config/television/cable/linux-apps.toml.tmpl` | **Linux + `ubuntu_desktop` profile only.** GUI app picker; Enter = activate (gtk-launch / GNOME `window-calls` ext if installed), Alt+Q = SIGTERM via pkill pattern, Alt+R = restart, Alt+K = SIGKILL, Alt+I = info pager, Alt+P = MPRIS responsiveness probe. **No Alt+H** — Linux can't hide windows without compositor IPC. Reuses `dot_config/shell/56_linux_apps.sh` helpers; user overrides in `~/.config/shell/linux-apps.conf`. |

---

## Session Management

> `sesh-*` requires `sesh` + `tmux`; `tsesh` also requires the `try-cli` Ruby gem. `mrun` / `tmrun` / `zjrun` only need tmux or zellij (whichever backend is selected) — no sesh dependency.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `sesh-sessions` | function | `dot_config/shell/22_sesh.sh` (zsh widget: `dot_config/zsh/tools/22_sesh.zsh`; bash ble.sh binding: `dot_config/bash/06_sesh.bash.tmpl`) | fzf popup picker for all sesh sessions (also bound to `Alt+S` in both shells) |
| `sesh-here` / `shere` | function / alias | `dot_config/shell/22_sesh.sh` | Lightweight: bare shell session at `$PWD` (no nvim, no project layout). Pass args/`-c CMD` to override |
| `sesh-root` / `sroot` | function / alias | `dot_config/shell/22_sesh.sh` | Connect sesh to current git root (falls back to `$PWD`); honors sesh.toml wildcards/default |
| `sesh-code` / `scode` | function / alias | `dot_config/shell/22_sesh.sh` | Repo-scoped coding-agent layout: nvim 75% \| `specstory run [agent]` 25%, plus btop window. Session named `coding-agent/<repo>` (collision-safe). Refuses outside git repos. Flags: `--on-exit shell\|kill\|restart`, `--no-specstory` |
| `sesh-vibe` / `svibe` | function / alias | `dot_config/shell/22_sesh.sh` | Parametric multi-agent layout: `svibe [N] [CLI]` (homogeneous) or `svibe --agents claude,codex,opencode,…` (heterogeneous). N tiled agent panes + lazygit window + nvim window. Session named `vibe/<repo>`. Same `--on-exit` / `--no-specstory` flags as scode. Requires bash 4+ when invoked from bash |
| `try-sesh` / `tsesh` | function / alias | `dot_config/zsh/tools/32_try.zsh` | Open a `try` ephemeral workspace and immediately connect via sesh |
| `mrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | Fire-and-forget: detached tmux/zellij session running CMD at `$PWD`, returns immediately. `mrun [-b tmux\|zellij] [-n NAME] [-d DIR] [-f] [--on-exit shell\|kill\|restart] [-k] [--] CMD [ARGS...]`. Default `--on-exit shell` keeps the session alive after CMD exits (drops to login shell, re-run via history-Up); `-k` restores fire-and-forget kill semantics. Backend default tmux (override via `$MRUN_BACKEND`). Soft-warns on TUI commands. Prints attach hint to stderr |
| `tmrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | `mrun -b tmux`. Detached tmux session running CMD; attach with `tmux attach -t NAME` |
| `zjrun` | function | `dot_config/zsh/tools/23_mrun.zsh` | `mrun -b zellij`. Generates ephemeral KDL under `$TMPDIR/mrun-layout-*` (with `default_tab_template` so the standard tab-bar / status-bar plugins are restored), spawns detached zellij session; attach with `zellij attach NAME` |

---

## Worktree Management

> Requires `worktrunk` (`wt`) and/or `workmux` (`wm`). `wtcd` also requires `jq` + `fzf`.
>
> Worktrunk's own aliases (`wt sw`, `wt ls`, `wt rm`, `wt cc`, `wt oc`) are defined in `dot_config/worktrunk/config.toml`, not in zsh — they work from any shell and from the interactive picker.
>
> Workmux (`wm`) is a separate tool that coexists with worktrunk; it's the source of the 🤖/💬/✅ icons in the tmux window list. See [docs/tools/workmux.md](../tools/workmux.md) for the wt-vs-wm split.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `wt` | function | `dot_config/shell/37_worktrunk.sh` | Wrapper around the `wt` binary that captures `cd`/`exec` directives so `wt switch` actually changes the parent shell's `$PWD` (eval'd from `wt config shell init zsh`) |
| `wtcd` | function | `dot_config/shell/37_worktrunk.sh` | fzf-tmux picker over `wt list --format=json` paths; `cd`s into the chosen worktree WITHOUT switching tmux/sesh session — useful for peeking at sibling worktrees |
| `wm` | alias | `dot_config/shell/38_workmux.sh` | Short alias for `workmux` (defined only on macOS — Linux ansible install creates a `wm` symlink in `~/.local/bin`). See [docs/tools/workmux.md](../tools/workmux.md) |
| `wmsb` | alias | `dot_config/shell/38_workmux.sh` | `workmux sidebar` — toggle the always-visible agent status panel; also enables 10s pane-silence interrupted-agent detection |
| `wmclear` | function | `dot_config/shell/38_workmux.sh` | Manual reset for stuck `@workmux_status` markers. `wmclear` clears current window; `wmclear N` clears window N; `wmclear --all` nukes every marker in current session. Workaround for the upstream sticky `working` (🤖) state |
| `tmux_status_set` | function | `dot_config/shell/60_tmux_status.sh` | Generic per-window tmux badge: `tmux_status_set my_build 🔨 [target]` writes `@my_build_status`. POSIX, sourced by both zsh + bash. See [workmux.md → Reusing the per-window status mechanism](../tools/workmux.md#reusing-the-per-window-status-mechanism-without-workmux) |
| `tmux_status_get` | function | `dot_config/shell/60_tmux_status.sh` | Read back a `@<name>_status` marker (empty + nonzero exit if unset) |
| `tmux_status_clear` | function | `dot_config/shell/60_tmux_status.sh` | Unset a marker on current or `target` window |
| `tmux_status_clear_all` | function | `dot_config/shell/60_tmux_status.sh` | Walk every window in every session, unset `@<name>_status` |
| `tmux_status_list` | function | `dot_config/shell/60_tmux_status.sh` | Audit all `@*_status` user-vars across all windows |
| `tmux_status_run` | function | `dot_config/shell/60_tmux_status.sh` | Wrap a command with `working`/`ok`/`fail` badge transitions, traps Ctrl+C: `tmux_status_run my_build 🔨 ✅ ❌ -- npm run build` |

---

## GitHub / GitLab

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ghget` | function | `dot_config/shell/41_github.sh` | Download a subdirectory from a GitHub tree URL |
| `glcreate` | function | `dot_config/shell/42_gitlab.sh` | Create a private GitLab repo under a group, set origin, and push |
| `glcreate-ai` | function | `dot_config/shell/42_gitlab.sh` | Same as `glcreate` but uses an AI agent to auto-generate the description |

---

## AI Usage Tracking

> `cbu`/`cbc`/`cbca` require `codexbar`. `ccusage` requires `bun`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cbu` | alias | `dot_config/shell/40_codexbar.sh` | Claude Code CLI usage stats (`codexbar usage --provider claude --source cli`) |
| `cbc` | alias | `dot_config/shell/40_codexbar.sh` | Claude Code cost breakdown (`codexbar cost --provider claude`) |
| `cbca` | alias | `dot_config/shell/40_codexbar.sh` | Cost breakdown across all providers (`codexbar cost`) |
| `ccusage` | alias | `dot_config/shell/07_bunx_cli.sh` | Claude Code usage tracker via `bunx ccusage` |

---

## Task Queue

> Requires `pueue` and `jq`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `pqsum` | function | `dot_config/zsh/tools/36_pueue.zsh` | Summarize pueue queue status: overall progress, ETA, per-group breakdown |

---

## Networking

> Conditional aliases — only defined when the corresponding tool is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ports` | alias | `dot_config/shell/50_networking.sh` | List all listening ports (`lsof -i -P -n \| grep LISTEN`) |
| `myip` | alias | `dot_config/shell/50_networking.sh` | Show public IP address |
| `localip` | alias | `dot_config/shell/50_networking.sh` | Show local IP address (platform-aware) |
| `pingsweep` | function | `dot_config/shell/50_networking.sh` | Ping sweep local `/24` subnet via `nmap -sn` *(requires nmap)* |
| `arpscan` | alias | `dot_config/shell/50_networking.sh` | ARP scan local network (`sudo arp-scan -l`) *(requires arp-scan)* |
| `dns` | alias | `dot_config/shell/50_networking.sh` | DNS lookup via doggo (DoH/DoT/DoQ) *(requires doggo)* |
| `bw-net` | alias | `dot_config/shell/50_networking.sh` | Live bandwidth monitor (`sudo bandwhich`) *(requires bandwhich)* |
| `portscan` | alias | `dot_config/shell/50_networking.sh` | Fast port scanner via rustscan *(requires rustscan)* |
| `lanscan` | alias | `dot_config/shell/50_networking.sh` | Run full LAN device + port scan into `~/.cache/tv/` (feeds `tv lan-devices`) |
| `tv-lan` | alias | `dot_config/shell/50_networking.sh` | Open the `lan-devices` Television channel |

### Proxy helpers

> Portable loopback-proxy helpers. Honors `$LOCAL_PROXY_URL` (+ optional `$LOCAL_PROXY_SOCKS_URL` for split Clash `socks-port:` configs); otherwise prefers an active Clash config (`mixed-port:` or `port:`/`socks-port:` from `~/.config/clash/config.yaml` or `~/Library/Application Support/clash/config.yaml`) before falling back to probing ports 7890/7891/1087/8118/8080 with `nc -z -w1`. Detection is cached per shell; `proxy-off` and `proxy-refresh` clear that cache before the next lookup. Set `$LOCAL_PROXY_AUTO_ACTIVATE=1` to auto-export env vars on shell startup. Full guide: [docs/tools/web-reader.md](../tools/web-reader.md). See also: [docs/tools/containers.md](../tools/containers.md) for how `$LOCAL_PROXY_URL` feeds the chezmoi-managed `~/.docker/config.json` `proxies.default` block.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `withproxy` | function | `dot_config/shell/50_networking.sh` | Run a single command with proxy env vars exported to the child only (e.g. `withproxy curl ...`) |
| `try_direct_then_proxy` | function | `dot_config/shell/50_networking.sh` | Run a command direct; on failure, retry via `withproxy`. Used as the default for reader functions. |
| `proxy-on` | function | `dot_config/shell/50_networking.sh` | Export `http_proxy`/`https_proxy`/`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` in the current shell |
| `proxy-off` | function | `dot_config/shell/50_networking.sh` | Unset all proxy env vars in the current shell |
| `proxy-status` | function | `dot_config/shell/50_networking.sh` | Report state: **active** (exported), **available** (detected), or **unavailable** |
| `proxy-test` | function | `dot_config/shell/50_networking.sh` | Test detected proxy egress with `curl https://www.google.com/generate_204` (HTTP, not ICMP ping) |
| `proxy-refresh` | function | `dot_config/shell/50_networking.sh` | Clear cached detection, re-probe, print status (use after toggling your proxy) |

### Web reader

> Render web pages as markdown in the terminal. All functions use `try_direct_then_proxy` so non-GFW'd URLs pay zero proxy overhead. Pick the extractor by function name. Full guide: [docs/tools/web-reader.md](../tools/web-reader.md).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `readurl` | function | `dot_config/shell/55_web_reader.sh` | Read article via jina.ai Reader + glow (remote, zero local deps beyond glow) |
| `readlocal` | function | `dot_config/shell/55_web_reader.sh` | Read article via trafilatura + glow (local, offline) *(requires `trafilatura`)* |
| `readnode` | function | `dot_config/shell/55_web_reader.sh` | Read article via readability-cli (`readable`) + glow (Mozilla Readability) *(requires `readable`)* |
| `readraw` | function | `dot_config/shell/55_web_reader.sh` | Render full page: `curl | pandoc -f html -t gfm | glow -` (no article extraction) *(requires `pandoc`)* |

---

## Log Viewers

> Thin wrappers around `tailspin` (`tspin`) and `ccze` for coloring arbitrary log files. Full guide: [docs/tools/log-tools.md](../tools/log-tools.md).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `catl` | function | `dot_config/shell/29_log_tools.sh` | Colorful `cat` for logs via `tspin --print` (stdout mode; pipes cleanly) *(requires tspin)* |
| `lessl` | function | `dot_config/shell/29_log_tools.sh` | `ccze -A \| less -RSFX` pager for logs with ANSI colors *(requires ccze)* |
| `logtail` | function | `dot_config/shell/29_log_tools.sh` | `tail -f` with live tailspin highlighting (prefers `tspin --follow`, falls back to `tail -F \| tspin --print`) |
| `svclog` | function | `dot_config/shell/29_log_tools.sh` | Cross-platform service log follower — `journalctl -fu` on Linux, `tail -F StdoutPath` / `log stream --predicate` on macOS, piped through tailspin. Accepts `--user` for user-scope. Usage: `svclog [--user] <service>`. See [services.md](../tools/services.md) |
| `svcstat` | function | `dot_config/shell/29_log_tools.sh` | Cross-platform service status — `systemctl status` on Linux, `launchctl print DOMAIN/LABEL` on macOS. Accepts `--user`. Usage: `svcstat [--user] <service>` |

---

## Data Viewers

> VisiData ([`visidata.org`](https://www.visidata.org/)) — terminal spreadsheet for tabular data (CSV/TSV/JSON/parquet/feather/arrow/xlsx/sqlite). Defaults are already vim-flavored (h/j/k/l, gg/G, /? search). Companion rc at `~/.visidatarc` (chezmoi-managed via [`dot_visidatarc.tmpl`](../../dot_visidatarc.tmpl)) carries the feather/StringDtype workaround and `enableVimMode`-gated key rebinds — see [vim-mode.md → VisiData](../this_repo/vim-mode.md#visidata).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `vd-arrow` | alias | `dot_config/shell/10_aliases.sh` | `visidata -f arrow` — force the pure-pyarrow ArrowSheet loader. Escape hatch for `.feather` / `.arrow` files where the default PandasSheet path crashes on pandas `StringDtype` columns (`ValueError: Could not convert ... to NumPy dtype`). Full diagnosis: [pitfalls/visidata-feather-stringdtype-numpy-dtype.md](../../pitfalls/visidata-feather-stringdtype-numpy-dtype.md) |
| `vd-ro` | alias | `dot_config/shell/10_aliases.sh` | `visidata --readonly` — open in read-only mode so a stray `g Ctrl+S` cannot overwrite the source. `--readonly` is an optalias for `--overwrite=n` (`visidata/modify.py:11`); in-memory edits are still allowed but the save path fails. Pair with `vd-arrow` (e.g. `visidata --readonly -f arrow file.feather`) when both protections are wanted. See [vim-mode.md → VisiData → Data safety](../this_repo/vim-mode.md#data-safety-read-only-mode) |

---

## System admin / audit

> Wrappers around `last` / `lastlog` / `journalctl` / `ausearch` / `aureport` for "who did what on this server" queries. Full guide: [docs/sysadmin/](../sysadmin/README.md). Helpers reference table: [docs/sysadmin/helpers.md](../sysadmin/helpers.md).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `audit-sessions [user]` | function | `dot_config/shell/45_audit.sh.tmpl` | Recent login sessions: `last -F -i` + `lastlog` (Linux) + `who -a`. No sudo needed. |
| `audit-failed-logins` | function | `dot_config/shell/45_audit.sh.tmpl` | Failed login attempts via `lastb -F -i` (Linux btmp). Requires sudo. |
| `audit-sudo [user]` | function | `dot_config/shell/45_audit.sh.tmpl` | Sudo events via `journalctl _COMM=sudo` (systemd) or `grep sudo /var/log/{auth.log,secure}`. Auto-elevates via `sudo -v`. |
| `audit-execve <pattern>` | function | `dot_config/shell/45_audit.sh.tmpl` | `ausearch -sc execve -x <pattern> -i` — did anyone exec `<pattern>`? Requires auditd + execve rule. |
| `audit-file <path>` | function | `dot_config/shell/45_audit.sh.tmpl` | `ausearch -f <path> -i` — who touched this file? Requires auditd + watch rule. |
| `audit-summary [--start <when>]` | function | `dot_config/shell/45_audit.sh.tmpl` | Chained `aureport --summary` + `-au` + `-x` (top 20). Default `--start today`. |
| `audit-rules-show` | function | `dot_config/shell/45_audit.sh.tmpl` | `auditctl -l` (loaded) + `cat /etc/audit/rules.d/*.rules` (persisted). |
| `user-list [--login]` | function | `dot_config/shell/45_audit.sh.tmpl` | List local users via `getent passwd` (Linux) or `dscl . -list /Users` (macOS). `--login` filters to non-nologin shells. |
| `user-info <user>` | function | `dot_config/shell/45_audit.sh.tmpl` | Full identity dump: id, groups, passwd entry, last login, sudo events (Linux), authorized_keys count. |
| `user-groups <user>` | function | `dot_config/shell/45_audit.sh.tmpl` | All groups a user belongs to (`id -Gn` sorted). |
| `group-members <group>` | function | `dot_config/shell/45_audit.sh.tmpl` | All members of a group (`getent group` / `dscl`). |
| `user-sudoers` | function | `dot_config/shell/45_audit.sh.tmpl` | Who can sudo: members of sudo/wheel/admin groups + user-bearing lines from `/etc/sudoers` and `/etc/sudoers.d/`. |
| `user-ssh-keys [user]` | function | `dot_config/shell/45_audit.sh.tmpl` | List `authorized_keys` entries (`<user> <fingerprint> <comment>`); scans all home dirs if no user. |
| `user-recent-changes [--days N]` | function | `dot_config/shell/45_audit.sh.tmpl` | Recent `/etc/passwd` `/etc/shadow` `/etc/sudoers` writes via `ausearch -k identity` + `-k sudoers`. |
| `fw-rules` | function | `dot_config/shell/45_audit.sh.tmpl` | Active firewall rules across all backends: nft, iptables, ufw, firewalld (Linux); pf + Application Firewall (macOS). |
| `fw-listening` | function | `dot_config/shell/45_audit.sh.tmpl` | Bound TCP+UDP sockets with owning process. Prefers `ss -tlnp` / `ss -ulnp`; falls back to `lsof`. |
| `fw-conn [--all]` | function | `dot_config/shell/45_audit.sh.tmpl` | Established TCP connections; `--all` includes all states. |
| `fw-port <port>` | function | `dot_config/shell/45_audit.sh.tmpl` | Find process bound to / connected via `<port>`. Useful for "port already in use" debugging. |
| `cron-list [--user U \| --system \| --timers]` | function | `dot_config/shell/45_audit.sh.tmpl` | Inventory all scheduled jobs: user crontabs + system cron + systemd timers + at + launchd. Filters narrow scope. |
| `audit-watch [--auth\|--audit\|--all]` | function | `dot_config/shell/45_audit.sh.tmpl` | Live colorized monitor of security-relevant events. RED = high-severity (passwd/shadow edits, root login, sudoers changes), YELLOW = medium (sudo, failed auth), CYAN = low. Auto-disables color when not on TTY. |
| `health-check [--quick\|--full]` | function | `dot_config/shell/45_audit.sh.tmpl` | Unified morning summary: hostname / uptime / disk (color-coded) / failed services / OOM kills / failed logins / sudo events / non-loopback listeners / audit summary; ends with verdict line. Cron-friendly. |
| `disk-usage` | function | `dot_config/shell/45_audit.sh.tmpl` | Per-mount usage with color thresholds (>=70% yellow, >=90% red). |
| `disk-largest [path] [--top N]` | function | `dot_config/shell/45_audit.sh.tmpl` | Largest depth-1 children of `<path>`; auto-sudo for root-owned paths. |
| `disk-inodes` | function | `dot_config/shell/45_audit.sh.tmpl` | Inode usage per mount (catches "no space" with apparent free space). |
| `mount-info` | function | `dot_config/shell/45_audit.sh.tmpl` | Active mounts with options + `/etc/fstab` definitions. |
| `disk-watch [mount]` | function | `dot_config/shell/45_audit.sh.tmpl` | Live `watch -n 1` of `df -h <mount>` + largest files. |
| `pkg-recent [--days N]` | function | `dot_config/shell/45_audit.sh.tmpl` | Recently installed/upgraded/removed packages across apt / dnf / pacman / brew / npm-g / pip --user. |
| `mac-mem-status` | function | `dot_config/shell/55_macos_mem.sh.tmpl` | **macOS-only.** Single-screen memory + swap + storage report: `vm.swapusage`, `memory_pressure`, parsed `vm_stat`, swapfile sizes (`/System/Volumes/VM/swapfile*`), top 10 by compressed-aware memory (`top -o mem`), TM local snapshot count, color-coded verdict. No sudo. See [tools/macos-swap.md](../tools/macos-swap.md). Short alias: `mms`. |
| `mac-mem-reclaim [--dry-run] [--yes] [--force] [--include LIST]` | function | `dot_config/shell/55_macos_mem.sh.tmpl` | **macOS-only.** Interactive cleanup. Always-safe: `sudo purge`. Opt-in via `--include`: `spotlight` (`killall mds_stores+mdworker_shared`), `snapshots` (`tmutil thinlocalsnapshots / 5GB 4`), `sleepimage` (delete `/private/var/vm/sleepimage` — laptop-unsafe), `windowserver` (`sudo killall -HUP WindowServer` — logs you out). Short alias: `mmr`. |
| `mac-mem-watch [INTERVAL_SEC]` | function | `dot_config/shell/55_macos_mem.sh.tmpl` | **macOS-only.** Live one-line-per-tick tail: free/compressed/swap_used + pageins/pageouts/swapins/swapouts per second. Default 5s. Designed for tmux side panes. Short alias: `mmw`. |

---

## macOS apps

> Graceful GUI app control via `osascript` + Apple Events. Prefer over `killall` for apps with state (OrbStack, Docker Desktop, Slack, etc.) — `quit` sends ⌘Q-equivalent, letting the app tear down cleanly. App NAME is the AppleScript name (e.g. `OrbStack`, `Google Chrome`), not bundle ID; passed via `osascript argv` so spaces/quotes are safe.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `appquit <AppName>` | function | `dot_config/shell/54_macos_apps.sh.tmpl` (macOS), `dot_config/shell/56_linux_apps.sh.tmpl` (Linux) | **Cross-platform.** macOS: Quit Apple Event (graceful, equivalent to ⌘Q). Linux: `pkill -TERM -f <pattern>` resolved from `~/.config/shell/linux-apps.conf` overrides or auto-derived from `.desktop` scan; Electron + Firefox honour SIGTERM as graceful quit. |
| `applaunch <AppName>` | function | same as above | **Cross-platform.** macOS: launch in background (no focus steal). Linux: `gtk-launch <desktop-id>` via `setsid -f`. App-defined startup behaviour applies. |
| `appactivate <AppName>` | function | same as above | **Cross-platform.** macOS: launch + bring to front. Linux: D-Bus call to GNOME `window-calls` extension if installed (best fidelity), otherwise falls back to `applaunch` (single-instance apps re-focus). |
| `apprestart <AppName>` | function | same as above | **Cross-platform.** `appquit` + poll until process gone (≤15s) + `applaunch`. On Linux, launches the app even if it wasn't running (mirrors macOS silent-quit semantics). |
| `apprunning <AppName>` | function | same as above | **Cross-platform.** Silent predicate; exit 0 if running, 1 otherwise. Linux backend: `pgrep -f <pattern>`. |
| `applist [--pids\|--all]` | function | same as above | **Cross-platform.** Default: names of running apps the helper recognises. `--pids` adds `<pid>\t<name>` (used by `tv {mac,linux}-apps`). macOS lists foreground GUI apps via System Events; Linux enumerates registered overrides + auto-derived from `.desktop` scan filtered to running processes. Linux `--all` shows non-running entries too. |
| `appresponsive <AppName> [TIMEOUT_SEC]` | function | same as above | **Cross-platform, divergent fidelity.** macOS: best-effort "Not Responding" via timed-out Apple Event. Linux: only meaningful for apps registered with `--mpris=NAME` (Spotify, mpv, VLC); for Electron/Firefox/most apps it degrades to `apprunning` with a stderr note — no public Linux API analog to macOS Apple Events. |
| `linux_app_register NAME [OPTS]` | function | `dot_config/shell/56_linux_apps.sh.tmpl` | **Linux-only.** Register an app for the Linux `app-*` helpers — `--desktop=ID --pkill=REGEX --wm-class=CLASS [--mpris=NAME]`. Typical call site: `~/.config/shell/linux-apps.conf` (sourced at shell startup, never auto-stubbed). Override file matters for AppImage / Snap / Flatpak where auto-derivation can't resolve the runtime binary path — see `pitfalls/linux-app-control-appimage-runtime-path.md`. `linux_app_register --list` prints the current registry. |

---

## Media / AV

> Powered by `ffmpeg` (video / audio) and `ImageMagick` (image). Loaded when any media tool is on `$PATH` — typically via `installMediaTools=true`. Each function self-checks for its specific dep. See [docs/tools/ffmpeg.md](../tools/ffmpeg.md) and [docs/tools/imagemagick.md](../tools/imagemagick.md) for the underlying tools.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `compress-video <input>` | function | `dot_config/shell/29_media.sh` | x264 CRF 28 re-encode → `<name>_compressed.mp4` (smaller; tweak CRF for quality) |
| `extract-audio <input>` | function | `dot_config/shell/29_media.sh` | Strip video, copy audio stream → `<name>.m4a` (no re-encode) |
| `to-wav16k <input>` | function | `dot_config/shell/29_media.sh` | Resample to 16 kHz mono WAV → `<name>_16k.wav` (Whisper / faster-whisper input) |
| `compress-image <input> [<mb>=1]` | function | `dot_config/shell/29_media.sh` | Re-encode to JPEG under target MB → `<name>_<mb>mb.jpg`; uses ImageMagick `-define jpeg:extent=NMB` (single-shot, no manual quality search). Alpha flattened to white. |
| `resize-image <input> <width_px>` | function | `dot_config/shell/29_media.sh` | Resize so width = `<width_px>`, preserves aspect → `<name>_<width>w.<ext>`; output keeps source format |
| `media-pick` | function | `dot_config/shell/29_media.sh` | Interactive launcher: [gum](../tools/gum.md) `file` picker → action chooser → (optional) param input. Wires every helper above; only loaded when `gum` is on `$PATH`. |

---

## Clipboard History

> Hybrid backend: **Maccy** on macOS (queries plaintext SQLite at `~/Library/Application Support/Maccy/Storage.sqlite`), **CopyQ** on Linux (uses the shipped `copyq` CLI). Autodetected at call time; override with `CLIP_BACKEND=copyq|maccy`. No-op with install hint on hosts without either tool (e.g. `ubuntu_server`). See [docs/tools/clipboard.md → Clipboard history](../tools/clipboard.md#clipboard-history-cb--cbl--cbe) for the why + threat-model notes.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cbl [N]` | function | `dot_config/shell/56_clipboard_history.sh` | List recent N clipboard items (default 20), tab-separated `<idx>\t<first-line>` |
| `cb` | function | `dot_config/shell/56_clipboard_history.sh` | fzf picker over `cbl 100` → copy selection to system clipboard |
| `cbe` | function | `dot_config/shell/56_clipboard_history.sh` | fzf picker → open selection in `$EDITOR` → write edited text back to clipboard |

---

## Shell Utilities

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `zsh-profile` | alias | `dot_config/zsh/10_aliases.zsh` | Profile zsh startup time (`ZSH_PROF=1 zsh -i -c exit`) |
| `bindings` | function | `dot_config/shell/10_aliases.sh` | View zsh keybindings cheatsheet (data source: `~/.config/docs/shells/keybindings.md`); pairs with the `Alt+/` ZLE picker — see [keybindings.md](keybindings.md) |
| `ghostty-ssh-terminfo` | function | `dot_config/shell/10_aliases.sh` | Install `xterm-ghostty` terminfo on a remote host over SSH (unprivileged) |
| `tldrf` | function | `dot_config/shell/28_tldr.sh` | `tldr` with language fallback: zh_TW → zh → en *(requires tldr)* |

---

## Tmux Integration

> Requires tmux + OSC 133 markers in the pane's scrollback (emitted by [`02_shell_integration.zsh`](../../dot_config/zsh/tools/02_shell_integration.zsh) — if missing, run `exec zsh` to reload). All three functions print to stdout (pipe-friendly: `cpout | grep ERROR`) AND copy to the system clipboard via tmux's OSC 52 bridge. Shell-level counterparts of the `prefix + M-y` / `M-i` tmux bindings — see [docs/tools/tmux/README.md → OSC 133](../tools/tmux/README.md#osc-133-command-boundary-navigation-warp-style).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cpout [N]` | function | `dot_config/zsh/tools/03_tmux_capture.zsh` | Print + copy the **Nth-latest command's output** (default N=1). Accepts positional integer for lookback |
| `cpcmd [N]` | function | `dot_config/zsh/tools/03_tmux_capture.zsh` | Print + copy the **Nth-latest command's input line** (default N=1). Reads zsh history so works outside tmux too |
| `cpblock [N]` | function | `dot_config/zsh/tools/03_tmux_capture.zsh` | Print + copy the **Nth-latest command's full block** (prompt + input + output). Default N=1 |
| `tsum [-d\|--shallow] [-r] [-i] [--sort closability] [--only TIER] [--dry-run]` | function | `dot_config/shell/61_tmux_summary.sh` | AI-summarize every tmux session — one-glance "what is this session", with closability tiers (🟢 safe / 🟡 check / 🔴 keep). Reuses the AI Capture agent fallback (claude / opencode / codex / cursor-agent); 10-min cached in `$XDG_CACHE_HOME/tmux-session-summary/`. `-d` includes the visible area of each session's active pane (20-100 lines, self-capture skipped); set `TSUM_DEEP_DEFAULT=1` in `~/.shellrc.adhoc` to make `-d` implicit (override with `--shallow`). `--sort closability` orders keep → check → safe (default: alphabetical); `--only {safe,check,keep}` filters to one tier. `-r` bypasses cache; `-i` opens fzf picker that switches client on Enter (also reachable via tmux `prefix + Space → Sessions → AI session summary`); `--dry-run` prints the prompt without calling the LLM. **On hosts with multiple tmux binaries** (apt + appimage, brew + system) export `TSUM_TMUX_BIN=/path/to/tmux` so tsum talks to the right server. |

---

## AI Capture

> One-shot pipeline: capture a past block (via `cpblock N`) and pass it to a coding-agent CLI (opencode / claude / codex / agyc / cursor-agent) in non-interactive / advisory mode. Agent auto-detected in `$AICAP_AGENT_PRIORITY` order; override with `-a AGENT`. Prompt override via `-p PROMPT`. Agent reply goes to stdout (pipe-friendly: `aifix | tee /tmp/advice.md`), status line to stderr.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `aifix [N] [-a AGENT] [-p PROMPT]` | function | `dot_config/shell/04_ai_capture.sh` | Capture Nth block (tmux), ask agent to diagnose + suggest a fix |
| `aiexplain [N] [-a AGENT] [-p PROMPT]` | function | `dot_config/shell/04_ai_capture.sh` | Capture Nth block (tmux), ask agent to explain what happened |
| `aifix-stdin [-a AGENT] [-p PROMPT]` | function | `dot_config/shell/04_ai_capture.sh` | Non-tmux: read stdin as context, ask agent (`tail -100 log \| aifix-stdin`) |
| `aifix-run -- CMD [ARG...]` | function | `dot_config/shell/04_ai_capture.sh` | Non-tmux: run CMD with stdout+stderr teed, feed to agent |
| `aifix-rerun [-y]` | function | `dot_config/shell/04_ai_capture.sh` | Non-tmux: thefuck-style re-execute last command (confirms unless `-y`; side-effect warning) |
| `aiblock` | function | `dot_config/shell/04_ai_capture.sh` | Launch the `scripts/aiblock.py` TUI: pick command(s) from history, edit prompt, pick action (print / copy / spawn new agent window). Deps resolved via `uv run --script` |

---

## AI Run

> Quick "run one prompt through a coding agent" wrappers — fresh prompt, streams the reply straight back. Mnemonic mirrors the agent-session tags in `dot_config/television/cable/agent-sessions.toml` (`[oc]`/`[cc]`/`[cx]`/`[cu]`/`[ag]`), so muscle memory carries between `tv agent-sessions` (browse old) and these (start new). Extra flags pass through to the underlying CLI: `ccr -c 'continue'` → `claude -p --model haiku -c 'continue'` resumes the last session. Differs from [AI Capture](#ai-capture) which is capture-and-diagnose, not arbitrary-prompt.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ocr [opencode flags] <prompt>` | function | `dot_config/shell/05_ai_run.sh` | `opencode run -m $AICAP_OPENCODE_MODEL "<prompt>"` — agent tag `[oc]` |
| `ccr [claude flags] <prompt>` | function | `dot_config/shell/05_ai_run.sh` | `claude -p --model $AICAP_CLAUDE_MODEL "<prompt>"` — agent tag `[cc]` |
| `cxr [codex flags] <prompt>` | function | `dot_config/shell/05_ai_run.sh` | `codex exec -m $AICAP_CODEX_MODEL "<prompt>"` — agent tag `[cx]` |
| `cur [cursor-agent flags] <prompt>` | function | `dot_config/shell/05_ai_run.sh` | `cursor-agent -p --model $AICAP_CURSOR_MODEL "<prompt>"` — agent tag `[cu]` |
| `agr [agy flags] <prompt>` | function | `dot_config/shell/05_ai_run.sh` | `agyc -p "<prompt>"` — Antigravity CLI; agent tag `[ag]`. `agyc` is a collision-free symlink → `~/.local/bin/agy` (the IDE squats bare `agy`); no `--model` flag (model is account-side) |
| `antigravity-cli` / `agy-ide` | alias | `dot_config/shell/05_ai_run.sh` | `antigravity-cli` → the Antigravity CLI (`agyc`); `agy-ide` → the Antigravity IDE editor launcher (defined only where the IDE is installed) |
| `olr <prompt>` | function | `dot_config/shell/05_ai_run.sh` | `ollama run $AICAP_OLLAMA_MODEL "<prompt>"` — shell-only sugar (not an AICAP agent; flag pass-through disabled because ollama puts model positionally) |
| `air [-a AGENT] [-m MODEL] [--] <prompt>` | function | `dot_config/shell/05_ai_run.sh` | Auto-detect via `$AICAP_AGENT_PRIORITY` (or honor `$AICAP_AGENT` / `-a`), dispatch to one of the wrappers above. `-m MODEL` overrides `AICAP_<AGENT>_MODEL` for this call only (subshell-scoped). `-a http` reaches the OpenAI-compat path (OpenRouter / local Ollama). `air -h` prints current env snapshot |

---

## Claude Code

> Project-local Claude Code config helpers. Requires `jq` only for the merge path (when the target file already exists).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `claude-plans-here [-f] [-y]` | function | `dot_config/shell/10_aliases.sh` | Scaffold/update `./.claude/settings.json` so Claude Code's `/plan` files land in `./.claude/plans/` (in-repo). Also `mkdir -p .claude/plans/` and offers to import "orphan" plans previously written under the global `~/.claude/plans/` that belong to this cwd or git-root (detected by scanning `~/.claude/projects/<encoded-path>/*.jsonl` for `Write`/`Edit` `tool_use` entries — only authoritative writes, not chat mentions). `-f` auto-yes the settings merge prompt; `-y` auto-yes the orphan copy prompt. Originals in `~/.claude/plans/` are kept |

---

## Package Managers & Runtime

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `load-nvm` | alias | `dot_config/shell/10_aliases.sh` | Lazy-load NVM into current session (normally skipped at startup) |
| `bw-update-completion` | function | `dot_config/shell/10_aliases.sh` | Regenerate cached Bitwarden completion (per-shell `${XDG_CACHE_HOME}/{zsh,bash}/bw_completion.*`) |
| `marimo-update-completion` | function | `dot_config/shell/10_aliases.sh` | Regenerate cached marimo completion (per-shell `${XDG_CACHE_HOME}/{zsh,bash}/marimo_completion.*`); auto-invalidates on `marimo` binary mtime change in `dot_config/shell/29_marimo.sh` |
| `thefuck-update-completion` | function | `dot_config/shell/10_aliases.sh` | Regenerate cached thefuck alias (per-shell `${XDG_CACHE_HOME}/{zsh,bash}/thefuck_alias.*`); auto-invalidates on `thefuck` binary mtime change in `dot_config/shell/27_thefuck.sh` |
| `try-update-completion` | function | `dot_config/zsh/10_aliases.zsh` | **zsh-only.** Regenerate cached try-cli init (`${XDG_CACHE_HOME}/zsh/try_init.zsh`); auto-invalidates on `ruby` binary mtime change in `dot_config/zsh/tools/32_try.zsh` |
| `mi-router-update-completion` | function | `dot_config/shell/10_aliases.sh` | Regenerate lazy-autoload completion for `mi-router` via tyro `--tyro-write-completion` (zsh: `~/.zfunc/_mi-router`; bash: `${XDG_DATA_HOME}/bash-completion/completions/mi-router`); auto-invalidates on binary mtime change in `dot_config/shell/47_mi_router.sh`. See [docs/zsh/zsh-completions.md](../zsh/zsh-completions.md) Section F. |
| `brew-mirror` | function | `dot_config/shell/10_aliases.sh` | Switch Homebrew mirror on-the-fly (GFW workaround): `brew-mirror {aliyun\|ustc\|bfsu\|tuna}`. Updates env vars + rewrites existing clone origins; no-arg prints current endpoints. Default baseline is Aliyun (set in `dot_config/shell/00_exports.sh.tmpl`) |
| `conda` | function (lazy) | `dot_config/zsh/tools/04_conda_mamba.zsh` | First call lazy-inits any of miniforge3 / miniconda3 / anaconda3 (autodetects `~/miniforge3` etc.) then re-execs with given args. Saves ~200ms shell startup vs eager init. |
| `mamba` | function (lazy) | `dot_config/zsh/tools/04_conda_mamba.zsh` | Same lazy init as `conda` — picks up `etc/profile.d/mamba.sh` from full distro install. |
| `micromamba` | function (lazy) | `dot_config/zsh/tools/04_conda_mamba.zsh` | Lazy-init for the single-binary mamba (`~/.local/bin/micromamba`). Resolves `$MAMBA_ROOT_PREFIX` from env or autodetects `~/.local/share/mamba` / `~/micromamba`. Coexists with full-distro conda — both hooks evaluated if both present. Common on noRoot / EL7 / glibc-old hosts where conda-forge is the modern-toolchain escape hatch — see `docs/infra/linux-toolchain-baseline.md`. |

---

## Dotfiles management

> Wrappers + reload hint around `chezmoi apply` / `chezmoi update`. The hint fires once per shell session when an apply happened after the shell was born; opt out with `export CHEZMOI_RELOAD_HINT=0`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cas [ARGS…]` | function | `dot_config/shell/99_chezmoi_reload.sh` | `chezmoi apply $@` then `exec $current_shell -l` on success. Use instead of `chezmoi apply` when you want the new rc to take effect immediately in *this* terminal |
| `cau [ARGS…]` | function | `dot_config/shell/99_chezmoi_reload.sh` | Same as `cas` but for `chezmoi update` (pull + apply) |
| reload hint | precmd hook | `dot_config/shell/99_chezmoi_reload.sh` | After `chezmoi apply` (any invocation: bare `chezmoi apply`, `just chezmoi-apply`, `fleet-apply` local), each pre-existing shell shows `ℹ chezmoi applied changes — run exec $SHELL -l or source ~/.zshrc to reload` on its next prompt. Once per session. Sentinel: `~/.cache/chezmoi/last-apply` (touched by `.chezmoiscripts/global/run_after_99_signal_reload.sh.tmpl`) |
