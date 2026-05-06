# Add `primaryShell` chezmoi prompt + bash support layer

## Context

Currently this repo is **zsh-only**. `dot_zshrc.tmpl` + 44 files under `dot_config/zsh/` define the entire interactive shell experience, and `dot_ansible/roles/zsh/tasks/main.yml` unconditionally switches the user's login shell to zsh on every machine. There is **no managed `~/.bashrc`** today (only a stale comment in README.md claims one exists), so any host where zsh can't be installed (locked-down corporate servers, minimal containers, recovery shells) silently degrades to a bare distro-default bash with none of our env vars, PATH additions, or starship prompt.

**Goal**: add a `chezmoi init` prompt `primaryShell` (default `zsh`, choice `["zsh", "bash"]`) and ship a bash configuration that is **as close to the zsh experience as readline + oh-my-bash allow**, while being **safe to overlay on top of stock Ubuntu / Debian / RHEL `/etc/skel/.bashrc`** without losing distro defaults.

**Non-goals (deliberately deferred)**:
- Porting the `aisuggest` ZLE widget to bash. ble.sh **does** have an equivalent widget API (`ble-bind -x` + `_ble_edit_str` + `BLE_ATTACHED`), so the port is mechanically possible — but it's its own effort (sanitize-pipeline rewrite, debug logging redirect, key-rebind story) on top of getting ble.sh stable first. v1 ships the **CLI form** (`aisuggest "<text>"`) only; widget port goes into TODO.md as `[P3][L]`.
- Porting tv/tools_picker/sesh ZLE widgets. ble.sh's `ble-bind` could host these, but each is several hundred lines of LBUFFER manipulation. v1 gives bash users plain CLI commands (`tv <channel>`, `sesh-connect`); ZLE→ble-bind ports go into TODO.md as `[P3][M]`.

## Key design decisions (confirmed)

1. **Deploy both shells in parallel; `primaryShell` only gates login-shell switching.** Both `~/.zshrc` and `~/.bashrc` are deployed to every machine regardless of choice. The `primaryShell` value only decides which shell `dot_ansible/roles/<shell>/tasks/main.yml` runs `chsh` to. Rationale: users routinely drop into the other shell ad-hoc; having both work is cheap and avoids "I changed login shell to bash and now nothing works in this SSH session" footguns.

2. **Extract shared POSIX layer to `dot_config/shell/` (full extraction).** `00_exports.zsh.tmpl`, `02_legacy_tools.zsh`, the POSIX subset of `10_aliases.zsh`, **and** all `tool init <shell>` wrappers (starship/mise/zoxide/direnv/thefuck) move to `dot_config/shell/*.sh.tmpl`. The init wrappers detect `$BASH_VERSION` vs `$ZSH_VERSION` at source-time and pass the right flag. Both `dot_zshrc.tmpl` and `dot_bashrc.tmpl` source `~/.config/shell/*.sh` first, then their shell-specific dirs (`~/.config/zsh/` or `~/.config/bash/`). Eliminates ~600 LOC of would-be duplication.

3. **oh-my-bash + ble.sh full set (theme disabled, OMB autosuggest/syntax-highlight plugins disabled).** This is the v1 deliverable for bash UX parity:
   - **OMB** managed via `.chezmoiexternal.toml.tmpl` git clone to `~/.oh-my-bash` (mirrors the OMZ pattern in this repo). `OSH_THEME=""` so starship owns the prompt. **Critical**: OMB's own `autosuggestions`/`syntax-highlighting` plugins must be **excluded** from the `plugins=()` list — ble.sh provides better, native versions; double-init causes flicker + duplicate-completion bugs. OMB plugins kept: `git`, `sudo`, `history-substring-search`, `bashmarks` (selection mirrors zsh plugin list intent).
   - **ble.sh** managed via `.chezmoiexternal.toml.tmpl` git clone to `~/.local/share/blesh`, then a `run_onchange_after_*_install_blesh.sh.tmpl` script that runs `make -C ~/.local/share/blesh install PREFIX=$HOME/.local` once (idempotent on the artefact path). No package-manager dep on Linux, no Homebrew formula on macOS.
   - **Init order in `dot_bashrc.tmpl`** (load-bearing — getting this wrong is the #1 ble.sh footgun):
     ```
     1. early-return guard for non-interactive shells
     2. /etc/bashrc source (RHEL only)
     3. ble.sh sourced with --attach=none   ← MUST be before bash-preexec / starship
     4. shared layer + bash-specific config files (history, completion, aliases)
     5. oh-my-bash sourced (after blesh, so OMB's bash-preexec install no-ops)
     6. starship init bash (uses bash-preexec internally; ble.sh's preexec hook stack absorbs it cleanly)
     7. atuin init bash --disable-up-arrow (ble.sh handles up-arrow history; conflict-prevention)
     8. modular ~/.config/shell/*.sh + ~/.config/bash/*.sh loop
     9. ble-attach   ← MUST be the last step before secrets/.bashrc.adhoc
     10. secrets + .bashrc.adhoc
     ```
     Reference: <https://github.com/akinomyoga/ble.sh/wiki/Manual-§A1-Initialization>. The `--attach=none` + late `ble-attach` pattern is what lets us chain starship/atuin between them without stepping on ble.sh's RPROMPT / readline hooks.
   - Expected startup cost: +200-400ms on cold load (cached afterward via `~/.cache/blesh/`). Mitigations: ble.sh's `bleopt complete_auto_complete=` lazy modes if too slow on a host. Document the `BLESH_DEBUG=1` env var for users hitting issues.
   - Known conflicts to call out in the bash docs:
     - `bash-preexec` (third-party) installed in user `~/.bash-preexec.sh` ahead of ble.sh **breaks** ble.sh's own preexec stack. We don't install it; if a user dropped one in via another path, document the symptom + fix.
     - `atuin`'s up-arrow binding fights ble.sh's history navigation; mandatory `--disable-up-arrow`.
     - Some custom `bind -x` calls in user `.inputrc` get shadowed by ble-bind. Document that bash-side custom keybindings should use `ble-bind -m default_keymap -f` once ble.sh is attached.

4. **Stock-bashrc collision-safe pattern.** Our `dot_bashrc.tmpl` opens with the same early-return guard the Ubuntu skel uses, sources `/etc/bashrc` when present (RHEL families, where `/etc/bashrc` carries the protective `rm -i`/module env + Modules system init), and includes the bash-completion-v2 dynamic prefix snippet for Homebrew-on-macOS. We **don't** preserve `/etc/skel/.bashrc`'s `debian_chroot`/`PS1` (starship replaces it), `HISTSIZE=1000` (we set 10000+), or color-ls/grep aliases (we use eza/bat). We **do** preserve `shopt -s checkwinsize globstar histappend cmdhist` because they're harmless and useful.

5. **macOS bash 5.x install gated on `primaryShell == "bash"`.** OMB's plugin code requires bash 4.4+; macOS ships 3.2 (GPLv3 reluctance). The bash ansible role detects `os_family == "Darwin" && primary_shell == "bash"`, then `brew install bash` → append `/opt/homebrew/bin/bash` to `/etc/shells` (sudo, idempotent grep guard) → `chsh`. zsh-primary mac users are completely unaffected, no extra brew formula installed. ble.sh also requires bash 4.0+; same gate covers it.

6. **Bash side intentionally drops these zsh-only modules** — bash users get a documented downgrade for these, no half-port:
   - `02_shell_integration.zsh` (OSC 133 via `add-zsh-hook`) — could be `PROMPT_COMMAND`-ported but defer.
   - `05_aisuggest.zsh` widget (ZLE-only). Backend is shell-agnostic, exposed as CLI.
   - `11_tools_picker.zsh`, `12_television.zsh` ZLE widgets — replaced by plain functions (Alt-binds via `bind -x` is possible but readline UX is meaningfully worse; defer to v2 if requested).
   - `22_sesh.zsh` Alt+S widget. CLI form `sesh-connect` works.
   - `90_completions.zsh` (zsh `compdef` machinery) — bash uses bash-completion v2 instead.
   - `dot_zshrc.tmpl`'s `zvm_after_init` hook (no equivalent on bash).

## Critical files to modify / create

### Modified

| Path | Change |
|---|---|
| `.chezmoi.toml.tmpl` | Add `primaryShell = {{ promptChoiceOnce . "primaryShell" "Primary interactive shell (zsh\|bash)" (list "zsh" "bash") "zsh" \| quote }}` in the Preferences block (after `motdStyle`) |
| `Dockerfile`, `Dockerfile.centos7`, `Dockerfile.rocky9` | Add `ARG CHEZMOI_PRIMARY_SHELL=bash` (Docker default = bash, matches `useradd -s /bin/bash`) and a matching `--promptChoice "Primary interactive shell (zsh\|bash)=${CHEZMOI_PRIMARY_SHELL}"` line in the `chezmoi init` chain |
| `scripts/init/dotfiles_init.py` | Add `Prompt("primaryShell", "choice", "Preferences", "Primary interactive shell", …, default="zsh", prompt_text="Primary interactive shell (zsh\|bash)", choices=("zsh", "bash"))` to the PROMPTS tuple. The `doctor` regex scanner picks it up automatically once it's in all three places (toml + dockerfiles + python tuple) |
| `dot_ansible/roles/zsh/tasks/main.yml` | Wrap the `Change login shell to zsh` task in `when: primary_shell == "zsh"` (or move that step to a sibling role and have a top-level playbook gate). Install of the `zsh` package itself stays unconditional — we want zsh available even on bash-primary hosts so the deployed `~/.zshrc` actually works when users `zsh` ad-hoc |
| `dot_ansible/roles/bash/tasks/main.yml` | **NEW** — mirror of the zsh role with three differences: (a) bash package install gated on `primary_shell == "bash"` for macOS only (Linux always has bash from base); (b) on macOS bash branch, also append `/opt/homebrew/bin/bash` to `/etc/shells` with idempotent grep guard before `chsh`; (c) `chsh` block gated on `primary_shell == "bash"`. The OMB and ble.sh artefacts themselves are managed by `.chezmoiexternal.toml.tmpl` (clones) + `.chezmoiscripts/run_onchange_after_*_install_blesh.sh.tmpl` (`make install`), not by this ansible role |
| `.chezmoiignore.tmpl` | Add `.bashrc.adhoc` and `.config/bash/secrets.sh` exclusions (mirror of the zsh adhoc/secrets pattern, lines 73–77). No `primaryShell`-conditional gating — both shells deploy regardless |
| `.chezmoiexternal.toml.tmpl` | Add three new entries: (a) `~/.oh-my-bash` ← `https://github.com/ohmybash/oh-my-bash.git` (parallel to existing oh-my-zsh entry), (b) `~/.local/share/blesh` ← `https://github.com/akinomyoga/ble.sh.git` with `--recursive`, (c) any OMB custom plugin clones we adopt. Existing weekly refresh schedule applies |
| `.chezmoiscripts/run_onchange_after_NN_install_blesh.sh.tmpl` | **NEW** run-script that detects ble.sh source dir change (hash of `~/.local/share/blesh/HEAD`) and runs `make -C ~/.local/share/blesh install PREFIX=$HOME/.local` to regenerate `~/.local/share/blesh/ble.sh` (the runtime artefact). Idempotent. Must respect the existing sudo-shared protocol if it ever needs sudo (it doesn't — installs to `$HOME`) |
| `README.md` | Replace stale "~/.bashrc PATH is auto-appended" claim with the real story: chezmoi-managed bashrc, primary shell selectable at init, fallback path for bash-locked servers |
| `CLAUDE.md` | Add `dot_bashrc.tmpl` + `dot_config/shell/` + `dot_config/bash/` to the "Custom aliases & shell functions" cross-file rule (now both zsh and bash funcs need to land in `docs/zsh/aliases.md` — rename to `docs/shells/aliases.md`?). Add a new sub-bullet under "Hard repo invariants" documenting the parallel-deploy / `primaryShell`-gates-only-chsh rule. Update the "Keyboard shortcuts" table to note bash readline limitations vs ZLE |

### Created

| Path | Purpose |
|---|---|
| `dot_bashrc.tmpl` | Main bash entry point. ~200 LOC. The 10-step init order from Decision 3 above: early-return guard, `/etc/bashrc` source (RHEL only, presence-gated), `ble.sh --attach=none` source (presence-gated, fail-safe to plain bash), shared-layer load, bash-specific config files, OMB source (`OSH_THEME=""`, plugin list excludes autosuggestions/syntax-highlighting), starship init bash, atuin init bash with `--disable-up-arrow`, secrets, `ble-attach`, adhoc tail |
| `dot_config/bash/04_blesh.bash.tmpl` | **NEW** — ble.sh-specific tweaks that must run AFTER `ble-attach`: `bleopt complete_auto_complete=lazy`, custom `ble-bind` rebindings if any. Sourced by the modular loader; loader skips it when `[[ -z $BLE_VERSION ]]` (ble.sh not loaded, e.g., bash <4.0 minimal-mode fallback) |
| `dot_bash_profile.tmpl` | Login-shell entry on macOS bash and where `/etc/skel/.profile` doesn't already source bashrc. Sources `~/.bashrc` if `$BASH_VERSION` set |
| `dot_config/shell/00_exports.sh.tmpl` | **Moved** from `dot_config/zsh/00_exports.zsh.tmpl`. Pure POSIX env/PATH/Homebrew shellenv/GFW mirror logic, sourceable by both shells |
| `dot_config/shell/02_legacy_tools.sh` | **Moved** from `dot_config/zsh/02_legacy_tools.zsh`. Go/Bun/pnpm/Foundry/NVM/dotnet PATH |
| `dot_config/shell/10_aliases.sh` | POSIX subset of current `10_aliases.zsh`: `v="nvim"`, `glop`, `chezmoi-cd`, `gcam-amend`, `gundo`, `load-nvm`, `bw-update-completion`, `brew-mirror`, `ghostty-ssh-terminfo` (rewritten without `emulate -L zsh` / `setopt local_options`). `claude-plans-here` stays zsh-only because of `read -q` and ZLE-style prompting unless rewritten with `read -p` (judgment call — see open question below) |
| `dot_config/shell/01_starship.sh.tmpl` | `eval "$(starship init {{ if eq $shell "zsh" }}zsh{{ else }}bash{{ end }})"` — single template, dispatched by sourcing-shell detection (`$BASH_VERSION` vs `$ZSH_VERSION`) |
| `dot_config/shell/05_mise.sh`, `20_zoxide.sh`, `30_direnv.sh`, `27_thefuck.sh` | Same shell-agnostic init pattern (detect `$BASH_VERSION`/`$ZSH_VERSION`, pass right flag to tool) |
| `dot_config/bash/01_omb_plugins.bash` | Sets `plugins=(git)` etc. before sourcing `oh-my-bash.sh` |
| `dot_config/bash/02_history.bash` | Bash-specific HISTSIZE / HISTCONTROL / `shopt -s histappend cmdhist checkwinsize globstar` |
| `dot_config/bash/03_completion.bash` | bash-completion v2 with Homebrew-prefix detection (the snippet from research) |
| `dot_config/bash/05_vi_mode.bash` | `set -o vi` + `.inputrc` cross-reference |
| `dot_config/bash/10_aliases.bash` | Bash-only aliases that don't fit shared layer |
| `dot_inputrc.tmpl` | **NEW** if needed — readline config for vi-mode tweaks |
| `dot_config/zsh/10_aliases.zsh` | **Stripped** — keeps only zsh-specific functions (the ones using `emulate -L zsh` / `read -q` / ZLE), most of file moves to shared layer |
| `dot_config/zsh/00_exports.zsh.tmpl` | **Replaced** by a 1-line `[[ -r "$XDG_CONFIG_HOME/shell/00_exports.sh" ]] && source "$XDG_CONFIG_HOME/shell/00_exports.sh"` shim, OR removed entirely with `dot_zshrc.tmpl`'s `load_zsh_dir` extended to also `load_dir` from `$XDG_CONFIG_HOME/shell` first |
| `docs/shells/bash.md` | New page documenting bash bootstrap, what's missing vs zsh, ble.sh opt-in, login-shell switching footguns |
| `docs/shells/aliases.md` | Renamed from `docs/zsh/aliases.md`, now covers both shells (column for "available in: bash/zsh/both") |

### Reused / referenced (no edit, but the plan depends on them)

- `dot_zshrc.tmpl:78–94` `load_zsh_dir()` — mirror this exact pattern in `dot_bashrc.tmpl` as `load_bash_dir()`. Same `null_glob`-ish behavior via `shopt -s nullglob` (set + restore around the loop)
- `dot_config/starship.toml` — already shell-agnostic, reused as-is
- `dot_ansible/roles/zsh/tasks/main.yml:33–75` `chsh` block — the bash role copy-pastes this almost verbatim, only the `zsh_path` lookup and the `current_login_shell.endswith('/zsh')` check change
- `scripts/init/dotfiles_init.py:116–238` PROMPTS tuple structure — the `motdStyle` choice prompt is the closest existing template to copy
- `.chezmoiignore.tmpl:73–77` zsh secrets+adhoc gating — bash gets the parallel pattern

## Resolved decisions (from Phase 3 clarification)

1. **Deploy mode**: parallel deploy, `primaryShell` only gates `chsh`. Both shells always work, `.chezmoiignore.tmpl` does NOT gate `dot_bashrc.tmpl` / `dot_zshrc.tmpl` on `primaryShell`.
2. **Shared layer scope**: full extraction. ~600 LOC of churn accepted in exchange for single-source-of-truth on env/PATH/tool-init.
3. **Bash UX stack**: oh-my-bash (theme disabled, autosuggest/syntax-highlight plugins disabled) + ble.sh (full set), both managed via `.chezmoiexternal.toml.tmpl`. ble.sh init order documented in Decision 3 above.
4. **macOS bash**: install Homebrew bash 5.x + `/etc/shells` whitelist + `chsh` ONLY when `primaryShell=bash` on a macOS host. zsh-primary mac users see zero behavior change.
5. **`primaryShell` default**: `zsh` (preserves existing user behavior on `chezmoi apply`).

## Implementation-detail decisions still on the author's discretion

These don't change the shape of the plan, but worth flagging so reviewers can object:

1. **`claude-plans-here` portability**: rewrite the 4 `read -q` calls to `read -n 1 -r` + yes/no parsing (~10 lines extra), move whole function to `dot_config/shell/10_aliases.sh`. Single implementation, works in both shells.
2. **aisuggest backend extraction**: extract `_aiagent_invoke` / `_aisuggest_query` / `_aisuggest_sanitize` (the shell-agnostic pipeline) from `dot_config/zsh/tools/05_aisuggest.zsh` into `dot_config/shell/04_ai_agent.sh`. The zsh ZLE widget keeps its place; a bash CLI form `aisuggest "<text>"` is added to bash side. v2 work-item in TODO.md: port the widget to `ble-bind -x` form.
3. **OMB plugin selection**: `git`, `sudo`, `bashmarks`. **Excluded**: `autosuggestions`, `syntax-highlighting` (ble.sh covers these), `history-substring-search` (ble.sh's history-search supersedes it). Re-evaluate in v2 after dogfooding.
4. **bash-completion v2 source order**: source AFTER OMB but BEFORE ble-attach, so ble.sh's completion engine wraps it. The Homebrew-prefix detect snippet goes in `dot_config/bash/03_completion.bash`.

## Verification plan

1. **`uv run --script scripts/init/dotfiles_init.py doctor`** — must pass after editing all four parity files (toml, three Dockerfiles, python tuple). Canonical drift check (`CLAUDE.md` → "Dockerfile + dotfiles_init wrapper" rule).
2. **Fresh container test, both shells**:
   ```
   docker build --build-arg CHEZMOI_PRIMARY_SHELL=zsh -t dotfiles-zsh .
   docker run -it dotfiles-zsh         # → lands in zsh, starship prompt, all aliases
   docker build --build-arg CHEZMOI_PRIMARY_SHELL=bash -t dotfiles-bash .
   docker run -it dotfiles-bash        # → lands in bash, starship prompt, ble.sh attached
                                       #   (check: `[[ -n $BLE_VERSION ]]` is true),
                                       #   OMB git aliases work, atuin up-arrow disabled,
                                       #   no init-order error spam on startup
   ```
   Repeat for `Dockerfile.centos7` and `Dockerfile.rocky9`. RHEL test specifically validates `/etc/bashrc` source path doesn't break ble.sh init.
3. **ble.sh init-order regression test** — start a bash interactive shell with `BLESH_DEBUG=1 PS4='+$LINENO: ' bash -ix 2>/tmp/blesh-trace.log`, exit, grep the trace for: ble.sh source line precedes starship init line precedes `ble-attach` line. If order is wrong, ble.sh's preexec stack doesn't catch starship → broken prompt redraw.
4. **Existing-machine test** — `chezmoi apply` on a current zsh-primary host: existing zshrc behavior must be byte-identical (the shared layer extraction is the risk surface). Diff `env` before/after; check `echo $PATH`, `command -v starship`, `which brew` are unchanged. Verify no `dot_config/shell/` files leaked into the deployed `~/.config/zsh/` directory (they should be at `~/.config/shell/`).
5. **Cross-shell ad-hoc test** — on a bash-primary host: running `zsh` from inside bash should source `~/.zshrc`, get zsh widgets / aisuggest widget, exit cleanly. And vice versa: running `bash` from zsh should attach ble.sh and have a working starship prompt.
6. **Stock-bashrc collision smoke test** — temp Ubuntu 24.04 container, snapshot `/etc/skel/.bashrc` content. After `chezmoi apply`: verify `shopt -p` shows `checkwinsize` and `globstar` enabled (preserved from skel intent), `HISTSIZE >= 10000` (replaced), no `debian_chroot` PS1 fragment (replaced by starship). Same test on Rocky 9: verify `/etc/bashrc`'s `umask` and protective `rm -i` aliases survive.
7. **Login-shell switch verification** — after `chezmoi apply` on a fresh host with `primaryShell=bash`: `getent passwd $USER | cut -d: -f7` (Linux) or `dscl . -read /Users/$USER UserShell` (macOS) reports bash path. Fresh terminal: `echo $0` is `-bash`. Conversely, `primaryShell=zsh` on the same host re-applied: shell switches back, no leftover state.
8. **macOS `/etc/shells` whitelist** — on macOS with `primaryShell=bash`, the bash ansible role appends Homebrew bash to `/etc/shells` BEFORE running `chsh` (else `chsh` rejects the path with `non-standard shell`). Idempotency test: re-run `chezmoi apply`, `/etc/shells` should not gain duplicate entries (grep guard works).
9. **ble.sh + atuin coexistence** — verify up-arrow walks ble.sh history (not atuin's TUI), Ctrl+R opens atuin TUI, Ctrl+P/N walk ble.sh history. Test pasting multi-line commands (ble.sh's bracketed paste should not clip).
10. **Plain-bash fallback** — manually test on a host without ble.sh installed (delete `~/.local/share/blesh/ble.sh`): bashrc must NOT error, must still load shared layer + OMB + starship. The presence-gates around ble.sh source / `ble-attach` are load-bearing.
11. **README + CLAUDE.md cross-file rule audit** — manually re-read both after edits. The new bash surface needs to be findable from the same places zsh is. Confirm `docs/shells/aliases.md` rename is reflected in `mkdocs.yml` nav and CLAUDE.md's "Custom aliases & shell functions" rule.

## Out-of-scope follow-ups (write to `TODO.md` after merge)

- `[P3][L]` Port `aisuggest` ZLE widget to ble.sh `ble-bind -x` form (now the backend is shared, only the widget layer needs porting; key file ref: `dot_config/zsh/tools/05_aisuggest.zsh:324-381`). Pre-req: ble.sh widget API study, sanitize-pipeline regression test.
- `[P3][M]` Port `tools_picker` / `television` / `sesh` ZLE widgets to ble.sh `ble-bind` form. Each is ~100-200 LOC of LBUFFER manipulation. ble.sh's `_ble_edit_str` + `ble/widget/insert-string` provide the equivalent surface.
- `[P3][S]` Port `02_shell_integration.zsh` OSC 133 markers to bash `PROMPT_COMMAND` + ble.sh's preexec hook.
- `[P3][S]` Add `fish` as a third `primaryShell` choice (much further down the road; opens up oh-my-fish question and shared-layer needs `# shellcheck shell=sh` audit).
- `[P?][S]` Investigate adding pre-commit hook that fails CI when a new `dot_config/zsh/` file lands without a matching shared-or-bash counterpart (or vice versa), enforcing the "both shells stay viable" invariant programmatically.
