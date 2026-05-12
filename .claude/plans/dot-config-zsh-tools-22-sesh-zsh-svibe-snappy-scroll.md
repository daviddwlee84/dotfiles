# Port `22_sesh.zsh` to shared shell layer + audit `dot_config/zsh/tools/`

## Context

`dot_config/zsh/tools/22_sesh.zsh` (664 lines) defines five user-facing commands:

| Cmd | Alias | What |
|---|---|---|
| `sesh-sessions` | Alt+S | ZLE picker (fzf-tmux) over `sesh list` |
| `sesh-here` | `shere` | plain shell session at `$PWD` |
| `sesh-root` | `sroot` | shell session at git root |
| `sesh-code` | `scode` | repo-scoped `coding-agent/<repo>` layout (nvim + agent + btop) |
| `sesh-vibe` | `svibe` | parametric multi-agent vibe layout (N panes + lazygit + nvim) |

The Explore audit showed that ~95% of this file is plain shell logic. Only the **picker widget** (`sesh-sessions`, `zle -N`, `bindkey`) and the zsh-completion regeneration block are genuinely zsh-only. All other functions trip a small, mechanical list of zsh-isms: `print -r --`, `${=var}` word-splitting flag, 1-indexed array access (`${arr[1]}`), `${#arr}` array-length syntax, and one `local -A`.

Per CLAUDE.md's three-tier file placement rule and the documented pattern ("extract the shell-agnostic backend into `dot_config/shell/` and keep each shell's widget binding in its own dir"), the right shape is:

- shared backend in `dot_config/shell/22_sesh.sh`
- zsh ZLE wrapper in `dot_config/zsh/tools/22_sesh.zsh` (slim)
- bash ble.sh wrapper in `dot_config/bash/06_sesh.bash`

User decisions:
- **Bash 4+ baseline** for shared layer (keep `local -A`; bash 3.2 mac users running `svibe` ad-hoc will see runtime errors but no source-time breakage — acceptable).
- **Stage 1 = sesh** (this PR). **Full audit** with subsequent stages identified.
- **Alt+S ble.sh binding** included in Stage 1.

---

## Stage 1 (this PR): `22_sesh.zsh` split

### Files

**NEW** `dot_config/shell/22_sesh.sh` — backend (~600 lines, sourced by both shells):

- Guard: `command -v sesh >/dev/null 2>&1 || return 0` at top
- All `_sesh_*` helpers: `_sesh_git_root`, `_sesh_sanitize`, `_sesh_attach_or_switch`, `_sesh_ensure_session`, `_sesh_wrap_agent`, `_sesh_on_exit_wrap`
- User-facing functions: `sesh-here`, `sesh-root`, `sesh-code`, `sesh-vibe`
- The 4 aliases: `shere`, `sroot`, `scode`, `svibe`
- `sesh-sessions` (the picker function body) — **moved here** so bash can call it too; the `zle reset-prompt` line is removed (it's a no-op-ish in ZLE-widget context anyway; both shells redraw on widget exit)

**MODIFIED** `dot_config/zsh/tools/22_sesh.zsh` — slim ZLE wrapper (~25 lines):

- Keep the `~/.zfunc/_sesh` completion-regeneration block (zsh-specific path)
- `zle -N sesh-sessions`
- 3× `bindkey -M {emacs,viins,vicmd} '\es' sesh-sessions`

**NEW** `dot_config/bash/06_sesh.bash` — ble.sh wrapper (~10 lines):

```bash
# Bash Alt+S → sesh picker via ble.sh
# Backend (sesh-sessions function) lives in dot_config/shell/22_sesh.sh
command -v sesh >/dev/null 2>&1 || return 0
type ble-bind &>/dev/null || return 0   # only if ble.sh attached
ble-bind -m emacs   -x 'M-s' 'sesh-sessions'
ble-bind -m vi_imap -x 'M-s' 'sesh-sessions'
ble-bind -m vi_nmap -x 'M-s' 'sesh-sessions'
```
(Exact `ble-bind` syntax: cross-reference existing patterns in `dot_config/bash/04_blesh.bash.tmpl` and `dot_config/bash/05_vi_mode.bash.tmpl` during implementation.)

### Mechanical portability fixes (applied as we copy into `dot_config/shell/22_sesh.sh`)

1. **`print -r --` → `printf '%s\n'`** — 7 occurrences (lines 55, 98, 104, 107, 112, 143, 147, 152 of current file).
2. **`${=agents_csv}` (current line 508)** → `IFS=',' read -ra agents <<< "$agents_csv"` (works in zsh and bash 4+).
3. **`${#agents}` → `${#agents[@]}`** — zsh accepts both; bash needs `[@]`.
4. **1-indexed array access** — current code uses `${agents[1]}`, `agents[$j]`, etc. Rewrite to iterate without index access where possible:
   ```sh
   first_agent="${agents[0]}"   # bash-style; zsh with KSH_ARRAYS — see below
   for a in "${agents[@]}"; do … done
   ```
   For zsh+bash dual compatibility, gate the indexing with `setopt KSH_ARRAYS` locally in zsh:
   ```sh
   if [ -n "$ZSH_VERSION" ]; then
       emulate -L sh -o KSH_ARRAYS
   fi
   ```
   (alternative: just use the `${arr[@]}` iteration pattern throughout; index access is only needed for `agents[1]` first-pane setup and the `for j` trim loop — both rewritable).
5. **`local -A seen` (current line 571)** — keep as-is (bash 4+ supports `local -A`).
6. **`unset -f _vibe_agent_cmd` (current line 633)** — works in both shells; keep.

### Removed from sesh-sessions function body

- `zle reset-prompt > /dev/null 2>&1 || true` — drop. ZLE/ble.sh both redraw on widget exit; the line was always defensive (the `|| true`).

### Cross-file updates

- **`docs/shells/aliases.md`** — verify the row(s) for `shere`/`sroot`/`scode`/`svibe`/`sesh-sessions`. If the table has a "source" column listing `dot_config/zsh/tools/22_sesh.zsh`, update to `dot_config/shell/22_sesh.sh` (+ note the zsh shim).
- **CLAUDE.md** — no edit needed. The existing three-tier rule already covers this case; we're following it, not changing it.

### Verification

1. `chezmoi diff` — confirm new shared file + slim zsh file + new bash file.
2. `chezmoi apply --dry-run` — no template errors.
3. **zsh check** (in a git repo dir):
   - `source ~/.zshrc` → `svibe --help` prints help; Alt+S launches picker.
   - `svibe --no-attach 2 claude` → `tmux ls` shows `vibe/<repo>` session with 2 agent panes.
4. **bash check** (run `bash` in a tmux pane):
   - `source ~/.bashrc` → `svibe --help` works; `scode --help` works; `shere`, `sroot` work.
   - Alt+S triggers picker (assumes ble.sh attached — which is the configured default per `dot_config/bash/04_blesh.bash.tmpl`).
5. **Cross-shell same-session attach**: `svibe` in zsh, then from another pane `bash`, run `svibe` → should attach existing `vibe/<repo>` session, not duplicate.
6. Run `bash --noprofile --norc` then `source ~/.bashrc` cold to confirm no errors at source time on bash 5.x.

---

## Stage 2 (next PR): quick-win mechanical ports

Pure `print -r` → `printf` + `setopt` guard. Audit-confirmed shared-OK with trivial fixes:

| File | Fixes |
|---|---|
| `50_networking.zsh` | `print -r` → `printf` only. |
| `41_github.zsh` | wrap `setopt localoptions pipefail` in `[ -n "$ZSH_VERSION" ] && setopt …`; `print -r` → `printf`. |
| `42_gitlab.zsh` | same as 41_github. |

Verification: each file as `dot_config/shell/<num>_<name>.sh`; bash-source check; functional smoke per command.

---

## Stage 3 (later PR): files needing closer per-file audit

These were flagged as "shared-OK" in the audit but the report didn't fully enumerate constructs — needs a careful read before porting:

- `28_tldr.zsh`
- `35_yazi.zsh`
- `37_worktrunk.zsh`
- `38_lazyvim.zsh`
- `38_workmux.zsh`
- `55_web_reader.zsh`
- `94_ssh_agent.zsh` (uses `typeset -a` — bash-compatible, but verify)
- `02_shell_integration.zsh` (uses `add-zsh-hook` — needs guard)
- `29_log_tools.zsh`
- `90_completions.zsh`
- `95_bitwarden.zsh`

---

## Stage 4 (lower priority): files with non-trivial zsh-isms

- `29_media.zsh` — `${var:r}` / `${var:e}` modifiers → `${var%.*}` / `${var##*.}` (mechanical but per-line).
- `32_try.zsh` — `${TRY_PATH:h}` → `$(dirname "$TRY_PATH")` (one line).
- `96_ssh_setup.zsh` — `setopt` guard, glob qualifier `*(N)` → `shopt -s nullglob` + dispatch, `${key_path:t}` → `${key_path##*/}`, `print` → `printf`, `unfunction` → `unset -f`.
- `04_ai_capture.zsh` — `${=AICAP_AGENT_PRIORITY}` → IFS-driven splitting, multiple `print -r`, 1-indexed array access in spinner. Bigger refactor; this file is also tied to the AI-agent SSOT pattern in `dot_config/shell/04_ai_agents.sh` (CLAUDE.md), so split point needs care.

---

## Out of scope — must stay zsh-only

| File | Why |
|---|---|
| `22_sesh.zsh` (slim) | `zle -N`, `bindkey`, `~/.zfunc/_sesh` completion regen are zsh-specific. |
| `03_tmux_capture.zsh` | ZLE `BUFFER`/`POSTDISPLAY` (ZLE state variables). |
| `05_aisuggest.zsh` | Heavy ZLE widgets. **Already tracked in TODO.md P3** for ble.sh port (canonical pattern). |
| `11_tools_picker.zsh`, `12_television.zsh`, `13_keys_picker.zsh` | `zle -N` widgets, `zle reset-prompt`, `zle redisplay`, `zle -I`. |
| `23_mrun.zsh` | `${(q)var}` zsh quote-flag has no clean bash equivalent — would need restructured command construction. Skip unless we have a strong reason. |
| `36_pueue.zsh` | (Audit was inconclusive; verify in Stage 3 whether it's really zsh-only.) |

---

## Critical files for Stage 1 implementation

- `dot_config/zsh/tools/22_sesh.zsh` — current source (split target)
- `dot_config/shell/22_sesh.sh` — NEW (created)
- `dot_config/bash/06_sesh.bash` — NEW (created)
- `dot_zshrc.tmpl` — verify load order (shared `*.sh` before zsh `tools/*.zsh`); no change expected
- `dot_bashrc.tmpl` — same; no change expected
- `dot_config/bash/04_blesh.bash.tmpl` — reference for `ble-bind` syntax
- `dot_config/bash/05_vi_mode.bash.tmpl` — reference for `ble-bind -m vi_imap -x …`
- `docs/shells/aliases.md` — update source path for sesh entries (per CLAUDE.md cross-file rule)

---

## Risk notes

- **`emulate -L sh` inside shared functions** changes zsh array indexing to 0-based and disables a few zsh niceties for the function's scope only — safer than global `setopt KSH_ARRAYS`. Prefer that over `[ -n "$ZSH_VERSION" ] && setopt …` for sesh-vibe's index-heavy loops.
- **`local -A seen` is bash 4+ only**. macOS zsh-primary users on system bash 3.2 calling `svibe` will see `local: -A: invalid option`. Function definition still parses (bash defers body validation). Accepted per the user's "Bash 4+ baseline" decision; document this in a top-of-file comment in `dot_config/shell/22_sesh.sh`.
- **ble.sh attachment is not guaranteed at the time `dot_config/bash/06_sesh.bash` is sourced.** ble.sh attaches via `ble-attach` near the end of `dot_bashrc.tmpl` (per CLAUDE.md). The `06_sesh.bash` file runs under `load_modular_dir`, which probably runs *before* `ble-attach`. Two options:
  - `type ble-bind &>/dev/null || return 0` short-circuit (drops the binding silently if ble.sh not loaded yet — needs verification that ble-bind is defined at source time, not only after attach)
  - move `ble-bind` calls into the `_ble_load_hook` mechanism that fires post-attach (check `dot_config/bash/04_blesh.bash.tmpl` for the pattern)

  Likely the second is the right approach; finalize during implementation by reading `04_blesh.bash.tmpl`.
