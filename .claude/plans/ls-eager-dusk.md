# Plan: eza `auto` + chezmoi-apply reload hint + brew-bundle cask adopt pitfall

## Context

Three related ergonomic fixes asked together:

1. **eza alias change**. Current `26_eza.sh` hard-codes `--icons=always --color=always`, so `ls | grep foo` produces ANSI + icon-glyph soup. Flipping every alias to `--icons=auto --color=auto` makes eza auto-disable colour/icons when stdout isn't a TTY — pipes become clean and interactive output is unchanged.

2. **Post-`chezmoi apply` reload UX**. After `chezmoi apply` rewrites shell files (`~/.zshrc`, `~/.bashrc`, `~/.config/{shell,zsh,bash}/*`), the user has to remember to `source ~/.zshrc` or open a new shell. Chezmoi runs as a child process and physically cannot source into the parent — but the shell itself can detect, on its next prompt, that an apply happened after the shell was born, and remind the user. The user selected: **precmd-style hint** + a **`cas` wrapper** (`chezmoi apply` then `exec $SHELL -l`) for the proactive case.

3. **Brewfile cask `--adopt` pitfall doc**. A previous chat already landed the `--adopt` pre-flight + lock cleanup + `HOMEBREW_NO_AUTO_UPDATE` changes in `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` (verified: lines 111-225). What's missing is a `pitfalls/` entry so the next time someone hits "brew bundle re-downloads a cask whose .app is already in `/Applications/`" they can grep their way to the answer instead of re-debugging. User pointed at upstream refs: [Homebrew/brew#14006](https://github.com/Homebrew/brew/issues/14006), [Homebrew/brew#14033](https://github.com/Homebrew/brew/pull/14033).

---

## Task A — eza aliases: `always` → `auto`

### File: `dot_config/shell/26_eza.sh`

Replace `--icons=always --color=always` with `--icons=auto --color=auto` on all 5 alias lines (12, 15, 16, 17, 18). Also rewrite the explanatory comment block (lines 7-11) so it states *why* `auto` is preferred:

```
# Options:
#   --icons=auto   - Show icons on TTY; disabled when piped (so `ls | grep` is clean)
#   --color=auto   - Colors on TTY; disabled when piped
#   --group-directories-first - Keep directories grouped together
# Interactive use looks identical; pipes get plain output automatically.
# To force colours through a pager: `ls --color=always | less -R`.
```

### File: `docs/shells/aliases.md` (rows 51-55)

Rephrase each "Description" cell so it no longer claims icons/colors are unconditional. Suggested wording:

| Command | Description |
|---|---|
| `ls` | Compact listing; icons + colors on TTY, plain when piped |
| `la` | Long listing including hidden files, dirs-first; icons/colors auto |
| `ll` | Long listing, dirs-first (no hidden); icons/colors auto |
| `lt` | Tree view, 2 levels deep; icons/colors auto |
| `llt` | Long tree view, 3 levels deep; icons/colors auto |

No other files reference these aliases functionally. The `.cursor/plans/...sesh setup...` file's `--color=always` is an fzf preview command (intentional) and is left alone.

---

## Task B — chezmoi-apply reload hint + `cas`/`cau` wrappers

**Design constraint**: `chezmoi apply` runs as a child process and cannot source into the parent. So the implementation is two-pronged:

- **Sentinel file** touched by a chezmoi `run_after_*` script every apply (a chezmoi-side action).
- **precmd hook** in the shell that compares the sentinel's mtime to the shell's birth time and prints a one-shot hint when the sentinel is newer.
- **`cas`/`cau` wrappers** for the proactive case: user types `cas` instead of `chezmoi apply`, and the function `exec`s a fresh login shell after the apply succeeds.

This combination handles every realistic scenario:

| Invocation | How user is told to reload |
|---|---|
| User types `cas` (apply + reload) | Fresh shell is `exec`'d automatically |
| User types `chezmoi apply` in shell X | Shell X's next prompt prints the hint |
| User runs `just chezmoi-apply` (subshell) | Outer interactive shell's next prompt prints the hint |
| Different terminal session was open | That terminal's next prompt prints the hint |
| `fleet-apply` runs apply on a remote | Doesn't apply — fleet-apply is remote; hint is local-only by design |

### File (new): `.chezmoiscripts/global/run_after_99_signal_reload.sh.tmpl`

```bash
#!/bin/bash
# Touch a sentinel after every `chezmoi apply` so shells started before the
# apply can notice on their next prompt and remind the user to reload.
# Loaded by dot_config/shell/99_chezmoi_reload.sh / dot_config/{zsh,bash}/*.

set -e

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi"
mkdir -p "$cache_dir"
touch "$cache_dir/last-apply"
```

- Lives in `.chezmoiscripts/global/` like its sibling `run_onchange_after_*` scripts.
- Uses `run_after_99_…` (not `run_onchange_`) so it fires every apply — that's the signal we want.
- No template logic; bash-only, so the `.tmpl` extension is technically unnecessary, but the global dir convention uses `.tmpl`.

### File (new): `dot_config/shell/99_chezmoi_reload.sh`

```bash
# 99_chezmoi_reload.sh - post-`chezmoi apply` reload hint (shared zsh/bash backend)
#
# Pattern:
#   - `run_after_99_signal_reload.sh.tmpl` touches ~/.cache/chezmoi/last-apply
#     after every `chezmoi apply`.
#   - At shell init we create a per-shell birth marker.
#   - precmd / PROMPT_COMMAND hooks (registered in dot_config/{zsh,bash}/)
#     call `_chezmoi_reload_check` on every prompt.
#   - The check fires AT MOST ONCE per shell session (PID-keyed temp file).
#
# Opt out:
#   export CHEZMOI_RELOAD_HINT=0    # in ~/.shellrc.adhoc or shell rc

[[ "${CHEZMOI_RELOAD_HINT:-1}" = "0" ]] && return 0

_CZ_RELOAD_SENTINEL="${XDG_CACHE_HOME:-$HOME/.cache}/chezmoi/last-apply"
_CZ_RELOAD_BIRTH="$(command mktemp "${TMPDIR:-/tmp}/.cz_birth.XXXXXX" 2>/dev/null)" || _CZ_RELOAD_BIRTH=""
export _CZ_RELOAD_SENTINEL _CZ_RELOAD_BIRTH

# Cleanup birth marker on shell exit (best-effort).
_chezmoi_reload_cleanup() {
    [[ -n "$_CZ_RELOAD_BIRTH" && -f "$_CZ_RELOAD_BIRTH" ]] && rm -f "$_CZ_RELOAD_BIRTH"
}
trap _chezmoi_reload_cleanup EXIT

# Idempotent: fires once per session. Caller (precmd / PROMPT_COMMAND) is
# expected to hot-path return when _CZ_RELOAD_SHOWN is set.
_chezmoi_reload_check() {
    [[ -n "$_CZ_RELOAD_SHOWN" ]] && return 0
    [[ -f "$_CZ_RELOAD_SENTINEL" ]] || return 0
    [[ -n "$_CZ_RELOAD_BIRTH" && -f "$_CZ_RELOAD_BIRTH" ]] || return 0
    [[ "$_CZ_RELOAD_SENTINEL" -nt "$_CZ_RELOAD_BIRTH" ]] || return 0

    _CZ_RELOAD_SHOWN=1
    # Plain printf — works in both shells. Tput-coloured if a TTY.
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        local y c r
        y="$(tput setaf 3 2>/dev/null)"; c="$(tput setaf 6 2>/dev/null)"; r="$(tput sgr0 2>/dev/null)"
        printf '%sℹ%s chezmoi applied changes — run %sexec %s -l%s or %ssource %s%s to reload\n' \
            "$y" "$r" "$c" "$(basename "${SHELL:-zsh}")" "$r" "$c" \
            "${ZSH_VERSION:+~/.zshrc}${BASH_VERSION:+~/.bashrc}" "$r"
    else
        printf 'ℹ chezmoi applied changes — run `exec %s -l` or `source ~/.%src` to reload\n' \
            "$(basename "${SHELL:-zsh}")" "$(basename "${SHELL:-zsh}")"
    fi
}

# Proactive wrappers — run instead of `chezmoi apply` when you want to reload
# immediately on success. Args are forwarded.
cas() {
    chezmoi apply "$@" && exec "${SHELL:-/bin/zsh}" -l
}
cau() {
    chezmoi update "$@" && exec "${SHELL:-/bin/zsh}" -l
}
```

Notes:

- Lives in `dot_config/shell/` (POSIX subset). No ZLE / `setopt` / `compdef` — both shells can source.
- Uses `[[ ... -nt ... ]]` which is bash/zsh-portable (POSIX `test` doesn't have `-nt`, but the file declares it's bash/zsh shared via the dir convention).
- The hint is suppressed per-session via `_CZ_RELOAD_SHOWN`. Cleanup of the birth file uses `trap … EXIT` — leaks a tiny `.cz_birth.*` in `$TMPDIR` if the shell SIGKILLs, but that's harmless and the directory is cleared periodically by the OS.
- `cas`/`cau` use `exec "${SHELL:-/bin/zsh}" -l` so the wrapper preserves env, working dir, history pinning — and avoids a stale `bash` chosen by `$0` in odd cases.

### File (new): `dot_config/zsh/tools/99_chezmoi_reload.zsh`

```zsh
# 99_chezmoi_reload.zsh — register zsh precmd hook for the reload hint
# Backend (function definitions, opt-out env var) lives in
# dot_config/shell/99_chezmoi_reload.sh.

[[ "${CHEZMOI_RELOAD_HINT:-1}" = "0" ]] && return 0

# Backend may not have loaded if user opted out via CHEZMOI_RELOAD_HINT=0
# before the shared file ran. Hard-require the function before hooking.
typeset -f _chezmoi_reload_check >/dev/null || return 0

autoload -U add-zsh-hook
add-zsh-hook precmd _chezmoi_reload_check
```

### File (new): `dot_config/bash/99_chezmoi_reload.bash`

```bash
# 99_chezmoi_reload.bash — register bash hook for the reload hint
# Backend lives in dot_config/shell/99_chezmoi_reload.sh.
#
# We prefer ble.sh's blehook (typed, doesn't fight PROMPT_COMMAND chains) when
# ble.sh is attached. Fall back to PROMPT_COMMAND append for bare bash / OMB.

[[ "${CHEZMOI_RELOAD_HINT:-1}" = "0" ]] && return 0
declare -F _chezmoi_reload_check >/dev/null || return 0

if [[ -n "${BLE_VERSION:-}" ]] && declare -f blehook >/dev/null 2>&1; then
    blehook PRECMD+=_chezmoi_reload_check
else
    case "$PROMPT_COMMAND" in
        *_chezmoi_reload_check*) : ;;
        *) PROMPT_COMMAND="_chezmoi_reload_check${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
    esac
fi
```

### File: `docs/shells/aliases.md`

Add a new section (or rows in the existing "File Listing" / a new "Chezmoi" section) for `cas` / `cau`. Since `cs` isn't a great name and we already have `chezmoi-apply` recipes, a new "Dotfiles" section at the bottom makes sense:

```markdown
## Dotfiles management

> Functions for chezmoi operations that benefit from an automatic shell reload.

| Command | Type | Source File | Description |
|---------|------|-------------|-------------|
| `cas` | function | `dot_config/shell/99_chezmoi_reload.sh` | `chezmoi apply $@` then `exec $SHELL -l` on success |
| `cau` | function | `dot_config/shell/99_chezmoi_reload.sh` | `chezmoi update $@` then `exec $SHELL -l` on success |
```

(If a `Dotfiles` / `Chezmoi` section already exists, append rows there instead.)

### File: `CLAUDE.md` — cross-file maintenance table

Add a new row under "Cross-file maintenance rules" so future agents know the moving parts:

```markdown
| `dot_config/shell/99_chezmoi_reload.sh` / `dot_config/zsh/tools/99_chezmoi_reload.zsh` / `dot_config/bash/99_chezmoi_reload.bash` / `.chezmoiscripts/global/run_after_99_signal_reload.sh.tmpl` | Row in [docs/shells/aliases.md](docs/shells/aliases.md) ("Dotfiles management") for `cas`/`cau` | The sentinel path (`~/.cache/chezmoi/last-apply`) is hard-coded in two places — the run-script that touches it and the shared backend that reads it. Keep them in sync. Opt out with `export CHEZMOI_RELOAD_HINT=0`. |
```

### Verification

```bash
# 1. Render + apply
chezmoi diff
chezmoi apply

# 2. Sentinel exists and is fresh
ls -la ~/.cache/chezmoi/last-apply

# 3. Open a NEW shell BEFORE running apply, run apply in shell A, return to shell B and press Enter
#    Expect: shell B prints "ℹ chezmoi applied changes — run `exec zsh -l` or `source ~/.zshrc`..."

# 4. Press Enter again in shell B — no repeat (one-shot suppression works)

# 5. cas wrapper
cas        # should run chezmoi apply, then exec a fresh login shell

# 6. Opt-out
CHEZMOI_RELOAD_HINT=0 zsh -i -c 'true'    # no hint should appear

# 7. ls pipe works clean after eza change
ls | head -5    # plain output, no ANSI/icons
```

---

## Task C — Brewfile cask adopt pitfall doc

The script-side change is already landed and verified at `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl:111-225`:
- `HOMEBREW_NO_AUTO_UPDATE=1` / `HOMEBREW_NO_INSTALL_UPGRADE=1` exports.
- `adopt_existing_casks()` pre-flight pass (macOS only) — calls `brew install --cask --adopt` for casks not yet tracked by brew.
- `clear_brew_download_locks()` between retry attempts.

What remains: a `pitfalls/` doc + index row.

### File (new): `pitfalls/brew-bundle-redownloads-manually-installed-cask.md`

Symptom-first per `pitfalls/README.md` template. Key sections:

- **Title**: `brew bundle re-downloads & fails on cask whose .app is already in /Applications/`
- **Symptoms** (grep-friendly, verbatim):
  - `brew bundle` output `Fetching <cask>` for an app the user already has installed.
  - `A `brew fetch <…>` process has already locked …/downloads/<hash>--<file>.incomplete` errors (concurrent fetch contention triggered by the redundant re-download).
  - `Error: Cask '<x>' is already installed.` only AFTER a long download.
  - Same `chezmoi apply` succeeds on the host that originally installed the cask via brew, but loops on a second mac where the user dragged the `.app` in manually.
- **First seen**: 2026-05 on `Hanrus-Mac-mini` (mac-mini with apps pre-installed via direct `.app` drag, then `chezmoi apply` from a different machine's `Brewfile.darwin`).
- **Affects**: any macOS host where `~/.config/homebrew/Brewfile.darwin` declares casks whose `.app` is already present in `/Applications/` but absent from `/opt/homebrew/Caskroom/`.
- **Status**: fixed in `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` via the `adopt_existing_casks` pre-flight (lines 111-165). Upstream feature documented at [Homebrew/brew#14006](https://github.com/Homebrew/brew/issues/14006) (request) and [Homebrew/brew#14033](https://github.com/Homebrew/brew/pull/14033) (the PR that added `--adopt`).
- **Root cause**: `brew bundle` only knows about casks tracked in `Caskroom`. A `.app` dragged manually has no `Caskroom/<name>/.metadata/...` so brew treats it as missing and tries to re-download. With many casks this also triggers brew's parallel-fetch lockfile contention (the `.incomplete` errors).
- **Workaround for users without the script fix**:
  ```bash
  brew bundle list --casks --file=~/.config/homebrew/Brewfile.darwin | while read -r cask; do
    brew list --cask "$cask" &>/dev/null && continue
    brew install --cask --adopt "$cask" 2>/dev/null && echo "adopted: $cask"
  done
  ```
- **Prevention**: the script now runs an adopt pre-flight on every apply. New casks added to `Brewfile.darwin.tmpl` will adopt automatically on first apply on hosts where they exist as manual installs.
- **Related**:
  - [`pitfalls/brew-cask-slow-github-release-assets.md`](brew-cask-slow-github-release-assets.md) — different root (CDN) but same observable "brew is downloading slowly / failing" shape; adopt pre-flight helps because it skips downloads entirely.
  - [`pitfalls/ngrok-cask-download-flaky.md`](ngrok-cask-download-flaky.md).
  - [`docs/this_repo/upgrades.md`](../docs/this_repo/upgrades.md) — adopt happens during `chezmoi apply`, not `just upgrade-*`.
  - Homebrew [#14006](https://github.com/Homebrew/brew/issues/14006), [#14033](https://github.com/Homebrew/brew/pull/14033).

### File: `pitfalls/README.md` — index

Insert a new alphabetical row in the table (around line 103-104, between `brew-cask-slow-…` and `centos7-…`):

```markdown
| [`brew-bundle-redownloads-manually-installed-cask`](brew-bundle-redownloads-manually-installed-cask.md) | `brew bundle` re-downloads cask for `.app` already in `/Applications/`; chains into `process has already locked .incomplete` parallel-fetch errors | fixed (adopt pre-flight in `run_onchange_after_30_brew_bundle.sh.tmpl`) |
```

### Verification

```bash
# On a host with a manually-installed app (e.g. Discord dragged to /Applications/ but not via brew):
ls /Applications/Discord.app             # exists
brew list --cask discord                 # exits 1 (not tracked)

# Run a fresh apply
chezmoi apply

# Expect log lines like:
#   [INFO] Adopt pre-flight: scanning Brewfile.darwin for manually-installed casks...
#   [INFO]   adopted: discord
#   [INFO] Adopt pre-flight: 1 newly adopted, N already tracked, M not present, 0 failed

# After:
brew list --cask discord                 # now exits 0
ls ~/Library/Caches/Homebrew/downloads/*Discord*.incomplete*  # nothing
```

### Out of scope (deliberately)

- The Aliyun mirror `Unable to find <sha> under …/brew.git` symptom is a separate transient-mirror issue. The `HOMEBREW_NO_AUTO_UPDATE=1` export already silences the implicit `brew update` that would trigger it during apply. If it recurs noisily we can add a second pitfall, but not in this change.
- No update to `dot_config/homebrew/Brewfile.darwin.tmpl` — the list of casks isn't the problem.

---

## Files changed in this plan (summary)

**New files**:
- `.chezmoiscripts/global/run_after_99_signal_reload.sh.tmpl`
- `dot_config/shell/99_chezmoi_reload.sh`
- `dot_config/zsh/tools/99_chezmoi_reload.zsh`
- `dot_config/bash/99_chezmoi_reload.bash`
- `pitfalls/brew-bundle-redownloads-manually-installed-cask.md`

**Modified files**:
- `dot_config/shell/26_eza.sh` (5 alias lines + comment block)
- `docs/shells/aliases.md` (5 rows under File Listing + new Dotfiles section)
- `CLAUDE.md` (one new row in the cross-file maintenance table)
- `pitfalls/README.md` (one new row in the index)

**Already-landed (no action)**:
- `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` (adopt pre-flight verified at lines 111-225)

## End-to-end verification

```bash
# 1. Render + diff to sanity-check templates
chezmoi diff

# 2. Apply
chezmoi apply

# 3. eza pipe is clean
ls | head -3                          # no ANSI / no icons

# 4. Reload hint flow (see Task B Verification)

# 5. Brewfile adopt flow (see Task C Verification)

# 6. mkdocs nav doesn't drift (we added a row to the docs index but no new pages)
uv run mkdocs build --strict
```
