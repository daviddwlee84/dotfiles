# Custom Aliases & Shell Functions

Quick reference for custom aliases and shell functions defined in this dotfiles repo.

> **Maintenance rule** (mirrored in `CLAUDE.md`): whenever you add, modify, or remove a custom alias or shell function, update this table — include the type (`alias` or `function`), source file (relative to repo root), and a one-line description.

---

## Table of Contents

- [Editor](#editor)
- [File Listing](#file-listing)
- [Navigation](#navigation)
- [Git](#git)
- [Tools Picker](#tools-picker)
- [Session Management](#session-management)
- [GitHub / GitLab](#github--gitlab)
- [AI Usage Tracking](#ai-usage-tracking)
- [Task Queue](#task-queue)
- [Networking](#networking)
- [Log Viewers](#log-viewers)
- [Shell Utilities](#shell-utilities)
- [Package Managers & Runtime](#package-managers--runtime)

---

## Editor

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `v` | alias | `dot_config/zsh/10_aliases.zsh` | Open Neovim (`nvim`) |

---

## File Listing

> Provided by `eza` (modern `ls` replacement). Only active when `eza` is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ls` | alias | `dot_config/zsh/tools/26_eza.zsh` | Compact listing with icons, colors, git status |
| `la` | alias | `dot_config/zsh/tools/26_eza.zsh` | Long listing including hidden files, sorted dirs-first |
| `ll` | alias | `dot_config/zsh/tools/26_eza.zsh` | Long listing, sorted dirs-first (no hidden files) |
| `lt` | alias | `dot_config/zsh/tools/26_eza.zsh` | Tree view, 2 levels deep |
| `llt` | alias | `dot_config/zsh/tools/26_eza.zsh` | Long tree view, 3 levels deep |

---

## Navigation

> `cd` is only replaced when `zoxide` is installed.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cd` | alias | `dot_config/zsh/tools/20_zoxide.zsh` | Smart `cd` via zoxide (`z`) with frecency-based matching |

---

## Git

### Custom (this repo)

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `gcam-amend` | function | `dot_config/zsh/10_aliases.zsh` | `git commit --amend -m "<msg>"` (replace message) |
| `gundo` | function | `dot_config/zsh/10_aliases.zsh` | Undo last commit → back to staged; prints undone commit message |
| `lg` | alias | `dot_config/zsh/tools/37_lazygit.zsh` | Open lazygit TUI |

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

---

## Session Management

> Requires `sesh` + `tmux`. `tsesh` also requires the `try-cli` Ruby gem.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `sesh-sessions` | function | `dot_config/zsh/tools/22_sesh.zsh` | fzf popup picker for all sesh sessions (also bound to `Alt+S`) |
| `sesh-here` / `shere` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | Lightweight: bare shell session at `$PWD` (no nvim, no project layout). Pass args/`-c CMD` to override |
| `sesh-root` / `sroot` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | Connect sesh to current git root (falls back to `$PWD`); honors sesh.toml wildcards/default |
| `sesh-code` / `scode` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | Repo-scoped coding-agent layout: nvim 75% \| `specstory run [agent]` 25%, plus btop window. Session named `coding-agent/<repo>` (collision-safe). Refuses outside git repos |
| `sesh-vibe` / `svibe` | function / alias | `dot_config/zsh/tools/22_sesh.zsh` | Parametric multi-agent layout: `svibe [N_AGENTS] [AGENT_CLI]` (default `4 claude`). N tiled agent panes + lazygit window + nvim window. Session named `vibe/<repo>`. Refuses outside git repos |
| `try-sesh` / `tsesh` | function / alias | `dot_config/zsh/tools/32_try.zsh` | Open a `try` ephemeral workspace and immediately connect via sesh |

---

## GitHub / GitLab

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `ghget` | function | `dot_config/zsh/tools/41_github.zsh` | Download a subdirectory from a GitHub tree URL |
| `glcreate` | function | `dot_config/zsh/tools/42_gitlab.zsh` | Create a private GitLab repo under a group, set origin, and push |
| `glcreate-ai` | function | `dot_config/zsh/tools/42_gitlab.zsh` | Same as `glcreate` but uses an AI agent to auto-generate the description |

---

## AI Usage Tracking

> `cbu`/`cbc`/`cbca` require `codexbar`. `ccusage` requires `bun`.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cbu` | alias | `dot_config/zsh/tools/40_codexbar.zsh` | Claude Code CLI usage stats (`codexbar usage --provider claude --source cli`) |
| `cbc` | alias | `dot_config/zsh/tools/40_codexbar.zsh` | Claude Code cost breakdown (`codexbar cost --provider claude`) |
| `cbca` | alias | `dot_config/zsh/tools/40_codexbar.zsh` | Cost breakdown across all providers (`codexbar cost`) |
| `ccusage` | alias | `dot_config/zsh/tools/07_bunx_cli.zsh` | Claude Code usage tracker via `bunx ccusage` |

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
| `ports` | alias | `dot_config/zsh/tools/50_networking.zsh` | List all listening ports (`lsof -i -P -n \| grep LISTEN`) |
| `myip` | alias | `dot_config/zsh/tools/50_networking.zsh` | Show public IP address |
| `localip` | alias | `dot_config/zsh/tools/50_networking.zsh` | Show local IP address (platform-aware) |
| `pingsweep` | function | `dot_config/zsh/tools/50_networking.zsh` | Ping sweep local `/24` subnet via `nmap -sn` *(requires nmap)* |
| `arpscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | ARP scan local network (`sudo arp-scan -l`) *(requires arp-scan)* |
| `dns` | alias | `dot_config/zsh/tools/50_networking.zsh` | DNS lookup via doggo (DoH/DoT/DoQ) *(requires doggo)* |
| `bw-net` | alias | `dot_config/zsh/tools/50_networking.zsh` | Live bandwidth monitor (`sudo bandwhich`) *(requires bandwhich)* |
| `portscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | Fast port scanner via rustscan *(requires rustscan)* |
| `lanscan` | alias | `dot_config/zsh/tools/50_networking.zsh` | Run full LAN device + port scan into `~/.cache/tv/` (feeds `tv lan-devices`) |
| `tv-lan` | alias | `dot_config/zsh/tools/50_networking.zsh` | Open the `lan-devices` Television channel |

### Proxy helpers

> Portable loopback-proxy helpers. Honors `$LOCAL_PROXY_URL` (+ optional `$LOCAL_PROXY_SOCKS_URL` for split Clash `socks-port:` configs); otherwise prefers an active Clash config (`mixed-port:` or `port:`/`socks-port:` from `~/.config/clash/config.yaml` or `~/Library/Application Support/clash/config.yaml`) before falling back to probing ports 7890/7891/1087/8118/8080 with `nc -z -w1`. Detection is cached per shell; `proxy-off` and `proxy-refresh` clear that cache before the next lookup. Set `$LOCAL_PROXY_AUTO_ACTIVATE=1` to auto-export env vars on shell startup. Full guide: [docs/tools/web-reader.md](../tools/web-reader.md). See also: [docs/tools/containers.md](../tools/containers.md) for how `$LOCAL_PROXY_URL` feeds the chezmoi-managed `~/.docker/config.json` `proxies.default` block.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `withproxy` | function | `dot_config/zsh/tools/50_networking.zsh` | Run a single command with proxy env vars exported to the child only (e.g. `withproxy curl ...`) |
| `try_direct_then_proxy` | function | `dot_config/zsh/tools/50_networking.zsh` | Run a command direct; on failure, retry via `withproxy`. Used as the default for reader functions. |
| `proxy-on` | function | `dot_config/zsh/tools/50_networking.zsh` | Export `http_proxy`/`https_proxy`/`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` in the current shell |
| `proxy-off` | function | `dot_config/zsh/tools/50_networking.zsh` | Unset all proxy env vars in the current shell |
| `proxy-status` | function | `dot_config/zsh/tools/50_networking.zsh` | Report state: **active** (exported), **available** (detected), or **unavailable** |
| `proxy-refresh` | function | `dot_config/zsh/tools/50_networking.zsh` | Clear cached detection, re-probe, print status (use after toggling your proxy) |

### Web reader

> Render web pages as markdown in the terminal. All functions use `try_direct_then_proxy` so non-GFW'd URLs pay zero proxy overhead. Pick the extractor by function name. Full guide: [docs/tools/web-reader.md](../tools/web-reader.md).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `readurl` | function | `dot_config/zsh/tools/55_web_reader.zsh` | Read article via jina.ai Reader + glow (remote, zero local deps beyond glow) |
| `readlocal` | function | `dot_config/zsh/tools/55_web_reader.zsh` | Read article via trafilatura + glow (local, offline) *(requires `trafilatura`)* |
| `readnode` | function | `dot_config/zsh/tools/55_web_reader.zsh` | Read article via readability-cli (`readable`) + glow (Mozilla Readability) *(requires `readable`)* |
| `readraw` | function | `dot_config/zsh/tools/55_web_reader.zsh` | Render full page: `curl | pandoc -f html -t gfm | glow -` (no article extraction) *(requires `pandoc`)* |

---

## Log Viewers

> Thin wrappers around `tailspin` (`tspin`) and `ccze` for coloring arbitrary log files. Full guide: [docs/tools/log-tools.md](../tools/log-tools.md).

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `catl` | function | `dot_config/zsh/tools/29_log_tools.zsh` | Colorful `cat` for logs via `tspin --print` (stdout mode; pipes cleanly) *(requires tspin)* |
| `lessl` | function | `dot_config/zsh/tools/29_log_tools.zsh` | `ccze -A \| less -RSFX` pager for logs with ANSI colors *(requires ccze)* |
| `logtail` | function | `dot_config/zsh/tools/29_log_tools.zsh` | `tail -f` with live tailspin highlighting (prefers `tspin --follow`, falls back to `tail -F \| tspin --print`) |
| `svclog` | function | `dot_config/zsh/tools/29_log_tools.zsh` | Cross-platform service log follower — `journalctl -fu` on Linux, `tail -F StdoutPath` / `log stream --predicate` on macOS, piped through tailspin. Accepts `--user` for user-scope. Usage: `svclog [--user] <service>`. See [services.md](../tools/services.md) |
| `svcstat` | function | `dot_config/zsh/tools/29_log_tools.zsh` | Cross-platform service status — `systemctl status` on Linux, `launchctl print DOMAIN/LABEL` on macOS. Accepts `--user`. Usage: `svcstat [--user] <service>` |

---

## Shell Utilities

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `zsh-profile` | alias | `dot_config/zsh/10_aliases.zsh` | Profile zsh startup time (`ZSH_PROF=1 zsh -i -c exit`) |
| `ghostty-ssh-terminfo` | function | `dot_config/zsh/10_aliases.zsh` | Install `xterm-ghostty` terminfo on a remote host over SSH (unprivileged) |
| `tldrf` | function | `dot_config/zsh/tools/28_tldr.zsh` | `tldr` with language fallback: zh_TW → zh → en *(requires tldr)* |

---

## Package Managers & Runtime

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `load-nvm` | alias | `dot_config/zsh/10_aliases.zsh` | Lazy-load NVM into current session (normally skipped at startup) |
| `bw-update-completion` | alias | `dot_config/zsh/10_aliases.zsh` | Regenerate cached Bitwarden zsh completion file |
