# Dotfiles Repository — Agent Contract

Cross-platform dotfiles managed by **chezmoi** (configs) + **ansible** (system deps). This file is the agent-facing contract: edit rules and cross-file invariants. User-facing intro: [README.md](README.md).

> **Headroom rule**: keep this file under ~30k chars. Push handbook content into `docs/`; keep only rules an agent must obey *without* opening another file. `AGENTS.md` and `GEMINI.md` are symlinks to this file — edit one.

## Cross-file maintenance rules

When you touch one of these surfaces, update the listed mirror in the same commit.

| Surface you change | Also update | Reference |
|---|---|---|
| Config files / ansible roles / platforms / setup steps | `README.md` (What You Get, Supported Platforms, Quick Setup) | — |
| New `docs/**/*.md` | Nav entry in `mkdocs.yml`; run `uv run mkdocs build --strict` | known anchor-drift is tracked in [`backlog/mkdocs-anchor-drift.md`](backlog/mkdocs-anchor-drift.md) — don't tighten `validation.links.not_found` until cleared |
| New tool installed by an ansible role / Brewfile / curl-installer / mise / uv / npm / cargo / gem / dotnet (or removed, or switched mechanism) | Add / update / remove the row in [`docs/this_repo/tool-managers.md`](docs/this_repo/tool-managers.md) § Tool index (A–Z). If it's a new install **mechanism** (vs new tool through an existing mechanism), also update the relevant § Per-manager catalog subsection and § Decision tree | High-churn case is just the A–Z row (one line per tool). The doc is the install-side companion to [`docs/this_repo/upgrades.md`](docs/this_repo/upgrades.md) — if the new tool has a non-trivial upgrade story, update upgrades.md too. Reverse refs from both pages auto-link back. |
| Alias / shell function in `dot_config/{shell,zsh,bash}/` | Row in [docs/shells/aliases.md](docs/shells/aliases.md) (name, type, source, scope, one-line) | [docs/this_repo/config-conventions.md](docs/this_repo/config-conventions.md) for repo-wide config conventions |
| Shell history env vars / `setopt`s / atuin filters | Tables in [docs/shells/history.md](docs/shells/history.md) | — |
| Linux GUI app in `dot_ansible/roles/gui_apps_linux/` | Inventory table in [docs/playbooks/linux-gui-apps.md](docs/playbooks/linux-gui-apps.md) (the playbook is also the decision tree — read first) | — |
| New chezmoi prompt | Edit the `PROMPTS` tuple in `scripts/init/dotfiles_init.py` (the single source of truth: key/kind/default/`prompt_text`/`comment`, plus `condition=When(...)`+`else_value` for host-gated prompts, and `BUNDLES` if applicable), then run `just gen-prompts` to regenerate `.chezmoi.toml.tmpl` + `Dockerfile`, and add the key to the README option table. Never hand-edit the generated marker regions. | `just gen-prompts -- --check` / the `dotfiles-init-gen-check` pre-commit hook fail on drift; `doctor` is a back-compat alias for `gen --check`. |
| `dot_dotfiles/bin/executable_fleet` (umbrella `fleet chezmoi <action>` namespace + top-level generic primitives `tmux`/`info`/`pueue`/`exec`/`hosts`/`edit`) / `scripts/fleet/` (`apply.py` / `tmux.py` / `info.py` / `pueue.py` / `exec.py` / `hosts.py`) / `justfile` `fleet` + `fleet-*` recipes / `dot_config/fleet/` / `dot_config/television/cable/fleet-hosts.toml` / sudo helper consumption / `dot_config/tmux/executable_tmux-session-summary.py` `--json` schema / `dot_dotfiles/bin/executable_pqsum` `json`/`ai --stdin-json` schemas / `scripts/fleet/exec.py` PATH-prelude + AIEXEC schema | [docs/this_repo/fleet-apply.md](docs/this_repo/fleet-apply.md), [docs/tools/pueue.md](docs/tools/pueue.md), [docs/tools/fleet-exec.md](docs/tools/fleet-exec.md), [docs/tools/fleet-hosts.md](docs/tools/fleet-hosts.md) | The `--json` schema emitted by `tmux-session-summary.py` and the raw-fallback parser in `scripts/fleet/tmux.py:_parse_raw` MUST stay in sync — adding a field to `Session`/`Window` dataclass means updating both. Same rule for `executable_pqsum`'s `HostSnapshot`/`GroupRec`/`TaskRec` dataclasses ↔ `scripts/fleet/pueue.py` `_run_pqsum_ai` payload — fleet pipes raw `pueue status --json` through `pqsum json --raw-stdin --host=NAME` and feeds the result to `pqsum ai --stdin-json --multi-host`, so any change to pqsum's output keys breaks fleet's AI mode silently. The PATH-augmentation prelude in `scripts/fleet/pueue.py:_REMOTE_CMD` and `scripts/fleet/exec.py:_PATH_PRELUDE` MUST stay in sync — both rely on the same chezmoi → cargo → uv → ~/bin → brew → linuxbrew order (deliberately diverges from the user's interactive shell PATH so package-manager dirs win over legacy ~/bin). |
| `dot_dotfiles/bin/executable_mlf` / `scripts/mlf/{tui,plot,list,download}.py` / `dot_config/television/cable/mlflow.toml` keybindings | Mirror single-letter mnemonics across the two UIs: the TUI `BINDINGS` letters (`b`/`y`/`p`/`d`/`j`) and the tv channel's `Ctrl+<letter>` actions are intentionally the same so muscle memory carries across `mlf` (dashboard) ↔ `tv mlflow` (picker). Change one → change the other in the same commit. | Shared helpers (`open_id`/`copy_id`/`fetch_histories`/`detect_kind`/`make_client`) live in `scripts/mlf/__init__.py` — refactor there, not in the call sites. The two UIs coexist intentionally: tv = fast picker, mlf TUI = multi-pane dashboard. |
| `dot_dotfiles/bin/executable_yth` / `scripts/yth/*.py` / `dot_config/television/cable/yth.toml` / `dot_config/{zsh/tools,bash}/53_yth_completion.*` | Mirror the `o`/`b`/`y`/`p`/`s`/`j` single-letter mnemonics between the `tv yth` channel actions and any future `yth tui`; new channel actions use `Alt+` (tmux prefix is `Ctrl+b`, so `ctrl-b` never reaches tv). | Shared helpers live in `scripts/yth/__init__.py` — refactor there. `yt-dlp` is declared in BOTH the launcher PEP723 block (self-boot) AND `python_uv_tools` (standalone binary), same dual pattern as `mlf`↔`mlflow`. Cookies (Arc/Zen) + schema + full story: [`docs/tools/yth.md`](docs/tools/yth.md). Semantic search deferred: [`backlog/yth-semantic-search.md`](backlog/yth-semantic-search.md). |
| New coding-agent artifact dir with secret risk | `DEFAULT_PATHS` in `scripts/redact_secrets.py` + `files:` regex in `redact-agent-secrets` pre-commit hook | Currently auto-scanned: `.specstory/history/`, `.claude/plans/`, `.cursor/plans/`, `.opencode/plans/` |
| Office viewing: `dot_dotfiles/bin/executable_view-office` / `dot_config/yazi/{yazi.toml,package.toml}` / `.chezmoiscripts/global/run_onchange_after_45_yazi_plugins.sh.tmpl` / `dot_config/{zsh/tools,bash}/55_view_office_completion.*` | **Contract**: `yazi.toml`'s `run = 'piper -- view-office --preview --width "$w" "$1"'` ↔ `view-office`'s `--preview`/`--width` interface — change one → change both. `markitdown` MUST keep the `[docx,xlsx,pptx]` extras in `python_uv_tools/defaults/main.yml` (bare package reads NO Office files → `MissingDependencyException`). Adding a yazi plugin = `ya pkg add …` then copy `~/.config/yazi/package.toml` into source (hash-gated run-script re-runs `ya pkg install`, which REWRITES the lockfile comment-free — keep the source lockfile comment-free, any comment → drift). doxx = homebrew-core (no tap) / Linux `.tar.xz`; LibreOffice = legacy-format fallback only. **`.xlsx` PREVIEW in yazi moved to duckdb.yazi** (see Data-file viewing row); the `view-office --preview *.xlsx` CLI (markitdown) is unchanged. | [docs/tools/office-viewers.md](docs/tools/office-viewers.md); `ya pkg` mechanism = [docs/this_repo/tool-managers.md](docs/this_repo/tool-managers.md) § 15 |
| Data-file viewing (yazi previews): `dot_config/yazi/{package.toml,init.lua,yazi.toml,keymap.toml}` + the feather/sqlite piper fallbacks in `yazi.toml` | **Contract**: `duckdb.yazi` needs ALL of — its `[[plugin.deps]]` in `package.toml` (add via `ya pkg add wylie102/duckdb` then copy the comment-free `~/.config/yazi/package.toml` back; the lockfile MUST stay comment-free — `ya pkg install` strips comments, so any comment → perpetual chezmoi drift), the **required** `require("duckdb"):setup{}` in `init.lua` (plugin no-ops without it), and `run = "duckdb"` entries in BOTH `prepend_previewers` and `prepend_preloaders` (csv/tsv/parquet/xlsx). Feather/arrow have NO DuckDB reader → piper→`vd -b -f arrow "$1" -o - --save-filetype fixed 2>/dev/null` (the `2>/dev/null` is load-bearing: piper renders any stderr as an error preview). `.sqlite`/`.sqlite3` aren't in the plugin's `extension_map` (only `.db`, which DuckDB auto-attaches) → piper→`duckdb -readonly`. `.xlsx` preview owned by duckdb.yazi (DuckDB `spatial` ext → network-on-first-use). `keymap.toml` H/L override yazi's default history nav (deliberate); yazi 26.x uses `[mgr]` not `[manager]`. `duckdb` CLI = devtools-role requirement. | [docs/tools/data-viewers.md](docs/tools/data-viewers.md); `ya pkg` mechanism = [docs/this_repo/tool-managers.md](docs/this_repo/tool-managers.md) § 15 |
| New in-house CLI in `dot_dotfiles/bin/executable_*` (or new subcommand on existing one) | Add tab completion for both shells per the decision flow in `docs/zsh/zsh-completions.md` Section F; **two files** if hand-written (`dot_config/zsh/tools/<NN>_<name>_completion.zsh` + `dot_config/bash/<NN>_<name>_completion.bash`) — keep them in sync; add row to that Section F table and to `docs/shells/aliases.md` Package Managers section if the CLI ships an `<tool>-update-completion` helper | [docs/zsh/zsh-completions.md](docs/zsh/zsh-completions.md) Section F. Existing patterns: `mi-router` (Strategy A, tyro self-gen + mtime invalidation in `dot_config/shell/47_mi_router.sh`), `fleet`/`mlf`/`pqsum`/`x` (Strategy B, hand-written eager-load in `dot_config/{zsh/tools,bash}/45-49_*_completion.*`). Dynamic candidates (host names, group names) shell out to the CLI itself — `_fleet_hosts_one` calls `fleet hosts --list`. |
| Tool inventory / in-house CLIs / `tv` channels / keymaps **surfaced to agents** (new prompt key or `executable_*` CLI) | `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` — the per-host chezmoi-templated agent-facing index (→ `~/.agents/skills/`, symlinked into `~/.claude/skills/`). Re-renders every `chezmoi apply` so freshness is automatic; only edit it to gate a section on a **new prompt key** or name a stable new CLI. | [docs/tools/agent-skills.md](docs/tools/agent-skills.md) § First-party templated skill. Keep it lean/self-discovering (pointers over enumerations). `.chezmoiignore` re-include needs single-`*` globs — a bare `**` no-ops the `!`. |
| New upstream CLI added to ansible/brew install set that ships `--completion <shell>` (or equivalent) | Add a `regen <tool> "<zsh-args>" "<bash-args>"` row to the inventory in `scripts/generate_completions.sh`; verify with `just completions-refresh`. The hook `.chezmoiscripts/global/run_after_50_generate_completions.sh.tmpl` then auto-regenerates on every `chezmoi apply` (binary-mtime check, idempotent — ~21ms when cached). | [docs/zsh/zsh-completions.md](docs/zsh/zsh-completions.md) Section A inventory + "Generating Completions After Fresh Install" section. Currently 14 tools auto-generated: chezmoi/mise/uv/just/starship/gh/docker/rg/fd/bat/delta/zellij/pueue/opencode. NOT auto-generated (handled elsewhere): sesh/tv/worktrunk (shell-startup mtime check), bw/marimo/thefuck/try-cli (cached eval), mi-router (its own startup script + tyro `#compdef` rewrite), fleet/mlf/pqsum/x (hand-written). |
| Keybinding (`Ctrl+`/`Alt+`) in any tool config | Cross-check namespace before claiming — tmux root-table `bind -n C-*` shadows inner apps; prefer `Alt+` for new actions | [docs/shells/keybindings.md](docs/shells/keybindings.md), [docs/tools/claude-code-keybindings.md](docs/tools/claude-code-keybindings.md), [docs/this_repo/vim-mode.md](docs/this_repo/vim-mode.md) |
| AI agent autodetect order or `AICAP_*_MODEL` defaults | Edit **only** [`dot_config/shell/04_ai_agents.sh`](dot_config/shell/04_ai_agents.sh) — the SSOT. Both shells source it; the **four** Python consumers (`dot_config/tmux/executable_tmux-session-summary.py`, `scripts/aiblock.py`, `dot_dotfiles/bin/executable_pqsum`, `scripts/fleet/exec.py`) regex-parse the same file for cron / tmux-popup contexts where env isn't inherited. Each agent's `-m`/`--model` flag is conditional on its env var being non-empty so a retired model ID falls through to the CLI's own default. When adding a NEW agent, update: SSOT (one new `AICAP_<AGENT>_MODEL` line), `04_ai_capture.sh:_aiagent_invoke` case, **all four** Python `AGENT_CONFIG` dicts. **Four consumers = pain threshold reached** — the extraction TODO (`scripts/aisum/__init__.py`) is now blocking ergonomics; next AI-tooling change should land that refactor before adding more callsites. | — |
| chezmoi-apply reload hint: `.chezmoiscripts/global/run_after_99_signal_reload.sh.tmpl` (touches sentinel) ↔ `dot_config/shell/99_chezmoi_reload.sh` (reads sentinel + zsh/bash hook registration + `cas`/`cau` wrappers) | Row in [docs/shells/aliases.md](docs/shells/aliases.md) "Dotfiles management" section for `cas`/`cau` | The sentinel path `~/.cache/chezmoi/last-apply` is hard-coded in **two** places — the run-script that touches it and the shared backend that reads it. Keep both in sync when relocating (e.g. switching to `$XDG_STATE_HOME`). Hook registration is in the shared backend (NOT `dot_config/{zsh,bash}/99_*`) because bash's `$BASH_CONFIG_DIR` loads before `$XDG_CONFIG_HOME/shell` (oh-my-bash `plugins=()` prereq, see `dot_bashrc.tmpl:94` vs `:114`), so a per-shell hook file in `dot_config/bash/` would run before the backend function exists. Opt out: `export CHEZMOI_RELOAD_HINT=0`. |
| `app-*` helpers — `dot_config/shell/54_macos_apps.sh.tmpl` (macOS) ↔ `dot_config/shell/56_linux_apps.sh.tmpl` (Linux) ↔ `dot_config/television/cable/mac-apps.toml.tmpl` ↔ `dot_config/television/cable/linux-apps.toml.tmpl` | Both shell helpers MUST expose the SAME public verb names (`appquit` / `applaunch` / `appactivate` / `apprestart` / `apprunning` / `applist` / `appresponsive`) so users get cross-platform muscle memory. Backends diverge by necessity (Apple Events vs `gtk-launch` + `pkill -TERM` + optional GNOME `window-calls` ext). Adding a new verb to one side: decide whether it can also be implemented on the other; if not, document the gap in `backlog/linux-desktop-app-control.md` "Open follow-ups". Both `tv` channel files MUST share Alt-key bindings where the verb exists on both sides — **Alt+H is mac-only by design** (Linux can't hide windows without compositor IPC; the Alt+H slot stays free on `tv linux-apps`). Per-app overrides for Linux AppImage/Snap/Flatpak runtime paths live in `~/.config/shell/linux-apps.conf` (not auto-stubbed, matches `.shellrc.secrets` rule) — never auto-generate this file from the helper. | [docs/playbooks/linux-gui-apps.md](docs/playbooks/linux-gui-apps.md) "Controlling installed apps from the shell" section; [pitfalls/linux-app-control-appimage-runtime-path.md](pitfalls/linux-app-control-appimage-runtime-path.md), [pitfalls/linux-app-control-gapplication-zero-coverage.md](pitfalls/linux-app-control-gapplication-zero-coverage.md). Empirical baseline: `gapplication list-apps` returns only ~13 GNOME-core apps on Ubuntu 24.04 Wayland — third-party Electron/AppImage/Snap/Flatpak coverage is **zero**, so don't reach for `gapplication action … quit` as the primary mechanism. |
| Docker `registry-mirrors` list in `dot_config/docker/modify_daemon.json.tmpl` (canonical) | Full list + per-mirror notes in [docs/tools/containers.md](docs/tools/containers.md) + `.zh-TW` (Strategy A JSON block + bullets), and the coverage-matrix Docker row + § Security and trust model in [docs/tools/mirrors.md](docs/tools/mirrors.md) + `.zh-TW` | When dropping/adding a mirror, state the **security** reason, not just speed: a pull-through mirror resolves `tag→digest` and Docker Content Trust is off by default, so a dead/third-party mirror domain risks lapsing → re-registration into a malicious pull-through cache. Curated high-reputation set only; `azk8s`/`dockerproxy` removed 2026-07 for this. |

**Repo-root files that stay OUT of MkDocs nav** (`README.md`, `CLAUDE.md` / `AGENTS.md` / `GEMINI.md`, `TODO.md`, `backlog/`, `pitfalls/`, `NOTES.md`): referenced via absolute GitHub URLs from [`docs/for-maintainers.md`](docs/for-maintainers.md), never copied via `pymdownx.snippets`.

**Three-tier file placement** for new shell helpers:

| Tier | Dir | When |
|---|---|---|
| Shared | `dot_config/shell/` | POSIX subset, both shells source. `$ZSH_VERSION`/`$BASH_VERSION` source-time dispatch is OK; ZLE widgets / `compdef` / `bindkey` / `setopt` / `read -q` / `${m:t}` / glob qualifiers are NOT (bash would error on source). |
| Zsh-only | `dot_config/zsh/` | ZLE widgets, `compdef`, `bindkey`, `setopt`, zsh-vi-mode hooks. |
| Bash-only | `dot_config/bash/` | `bind -x` / `ble-bind`, OMB plugin arrays, bash-specific `shopt`s. |

When porting a zsh-only helper to bash via ble.sh, extract the shell-agnostic backend into `dot_config/shell/` and keep each shell's widget binding in its own dir.

### Workmux status icon integration spans 6 files

Touching the `🤖`/`💬`/`✅` per-tmux-window status mechanism requires keeping these 6 surfaces in sync (full story: [docs/tools/workmux.md](docs/tools/workmux.md); pitfall: [pitfalls/workmux-status-leak.md](pitfalls/workmux-status-leak.md)):

1. `dot_ansible/roles/devtools/tasks/main.yml` — binary install (brew tap on macOS; GitHub release `.tar.gz` on Linux)
2. `dot_config/workmux/config.yaml` — `status_format: false` is load-bearing
3. `dot_config/tmux/theme.catppuccin.conf` — `#{?@workmux_status, #{@workmux_status},}` appended to `@catppuccin_window_text` and `@catppuccin_window_current_text`
4. `dot_claude/modify_settings.json` — `Stop`/`SubagentStop`/`UserPromptSubmit`/`Notification` hooks calling `workmux set-window-status` (hook-aware merger preserves CodeIsland entries)
5. `dot_config/opencode/plugins/workmux-status.ts` + `dot_config/opencode/modify_package.json`
6. `dot_config/shell/60_tmux_status.sh` — generic POSIX `tmux_status_set/get/clear/clear_all/list/run` for non-agent producers

**Hard rules**: never run `workmux setup` on a managed machine (would write parallel hook entries); never flip `status_format: true` (fights catppuccin's window-text override); never drop the `command -v workmux >/dev/null 2>&1 && … || true` guard in Claude hooks (spams errors on fresh boxes); never drop explicit `set-window-status done` from `Stop`/`SubagentStop` (upstream only ever sets `working`, never clears — that's the by-design leak documented in the pitfall). `wt` (worktrunk, `37_worktrunk.zsh`) and `wm` (workmux, `38_workmux.zsh`) stay distinct — different config formats, killer features, helper files.

### Long-term backlog + past pitfalls → use the `project-knowledge-harness` skill

This repo uses the `project-knowledge-harness` agent skill (restored on every `chezmoi apply` via `.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl`; see [docs/tools/agent-skills.md](docs/tools/agent-skills.md)). **Load the skill** for the template, disambiguation table, and upgrade path.

**Fallback rules** so this section still binds when the skill cannot be loaded:

- Three repo-root surfaces, all chezmoi-ignored, all NOT auto-redacted: [`TODO.md`](TODO.md) (priority/effort tags `P1`/`P2`/`P3`/`P?` × `S`/`M`/`L`/`XL`), [`backlog/`](backlog/README.md) (research/design notes for `P?` / `[L]` / `[XL]` / multi-option), [`pitfalls/`](pitfalls/README.md) (debugged traps — **title by symptom, not root cause**, verbatim error messages, never paraphrase).
- Capture triggers — future work: "maybe later", "nice to have", "工程量太大需要再評估", "先記下來". Pitfalls: >~15 min debugging, not googleable, non-obvious fix, silent failure.
- Do **not** spawn `ROADMAP.md` / `IDEAS.md` / `LESSONS.md` / `TROUBLESHOOTING.md`. Three surfaces, always.
- A pitfall *graduates* to a Hard invariant below when it (a) recurs across machines, (b) silently corrupts state, or (c) has a non-obvious workaround. Link back to `pitfalls/<slug>.md`.

## Chezmoi templating conventions

**Hard rule**: before adding `{{ if eq .profile … }}`, ask if the predicate is auto-detectable. If yes, use `.chezmoi.os` / `.chezmoi.arch` / `.chezmoi.hostname`. `.profile` is for user-role choices only. Values are limited to `macos`, `ubuntu_desktop`, `ubuntu_server` — do **not** introduce new values for OS/arch facts (historical `macos_intel` profile was removed for exactly this reason).

**Hard rule — prefer XDG paths.** When a tool supports both a `$HOME`-root dotfile and an XDG path (`~/.config/<tool>/…`), manage the XDG copy (`dot_config/<tool>/…`) to keep `$HOME` tidy; only use a root dotfile when the tool can't read XDG. For tools that error when *both* paths exist (e.g. AeroSpace), also remove the legacy root file via a gated `.chezmoiremove` entry. Full rule + lookup-order caveats: [docs/this_repo/config-conventions.md → A1](docs/this_repo/config-conventions.md).

| Predicate | Use |
|---|---|
| Any macOS | `eq .chezmoi.os "darwin"` |
| Any Linux | `eq .chezmoi.os "linux"` |
| Apple Silicon | `eq .chezmoi.arch "arm64"` (in darwin scope) or `and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "arm64")` |
| Intel Mac | `and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "amd64")` |
| Desktop vs headless | `.profile` — `ubuntu_desktop` / `ubuntu_server` |

Decision table, before/after examples, `macos_intel` migration: [docs/tools/chezmoi-templating.md](docs/tools/chezmoi-templating.md).

## Hard repo invariants

### Validate app configs with the app, not just syntax

Template rendering / YAML / TOML / JSON syntax is not enough. If the app exposes a config check, parser, dry-run, or debug command, run it against the rendered config before declaring done (e.g. `codex debug …` for `~/.codex/config.toml`; `tmux source-file` / `display-menu` smoke for tmux; `mkdocs build --strict` for docs; for Ansible run the narrowest practical play/tag/check-mode or container smoke — `--syntax-check` alone is a first pass). If a validator cannot be run, say so explicitly in the final report and name the missing command/host/credential.

### `primaryShell` choice gates `chsh` only — both shells always deploy

`primaryShell` (`zsh` | `bash`, default `zsh`) **only** governs which login shell `chsh` switches to. Both `~/.zshrc`, `~/.bashrc`, `~/.config/{shell,zsh,bash}/` deploy everywhere — users routinely drop into the other shell ad-hoc.

**Hard rules**:

- Do **not** add `{{ if eq .primaryShell … }}` gates around `dot_zshrc.tmpl`, `dot_bashrc.tmpl`, or `dot_config/{shell,zsh,bash}/**`.
- Do **not** gate the zsh / bash ansible roles' **package install** task on `primary_shell` — only `chsh` is gated. macOS bash 5.x brew install + `/etc/shells` whitelist are gated on `primary_shell == "bash"` (zsh-primary mac users skip the brew formula).
- Do **not** rely on `$SHELL` — it reflects `/etc/passwd`, lags `chsh` until next login. Use `$ZSH_VERSION` / `$BASH_VERSION`.

ble.sh + oh-my-bash 12-step init order in `dot_bashrc.tmpl` is load-bearing: `ble.sh --attach=none` MUST source before bash-preexec/starship; `ble-attach` MUST be the last call before secrets/adhoc; OMB's `autosuggestions` / `syntax-highlighting` / `history-substring-search` plugins MUST be excluded (ble.sh provides natives; double-init causes flicker). Full breakdown: [docs/shells/bash.md](docs/shells/bash.md).

### Three-tier user-local override layer

User overrides live in **six** untracked files: shared POSIX (`~/.shellrc.adhoc`, `~/.shellrc.secrets`) and per-shell (`~/.zshrc.adhoc`, `~/.bashrc.adhoc`, `~/.config/zsh/secrets.zsh`, `~/.config/bash/secrets.sh`). All six in `.chezmoiignore.tmpl`. Default target: shared. Drop to per-shell only when shell-specific syntax is required.

**Load order** in both `dot_zshrc.tmpl` and `dot_bashrc.tmpl`:

```
managed modules → shared secrets → per-shell secrets → shared adhoc → per-shell adhoc
```

Secrets before adhoc (so adhoc can read secret vars); shared before per-shell (per-shell wins on conflict).

**Hard rules**: never add the shared files to chezmoi management; never auto-stub the `*.secrets` files (empty secrets footgun); the shared adhoc stub heredoc lives in BOTH `dot_zshrc.tmpl` AND `dot_bashrc.tmpl` (first shell to run wins; second sees the file and skips) — keep both heredoc bodies in sync. Full matrix: [docs/shells/adhoc-and-secrets.md](docs/shells/adhoc-and-secrets.md).

### `enableVimMode` gates shell + tmux vim, NOT Neovim or editors

`enableVimMode` (bool, default `true`) gates **shell modal editing + tmux vim navigation only**. Neovim and every editor config (VSCode/Cursor/Antigravity/Codex/OpenCode/Cursor-CLI) are **never** affected. Full catalog of the 7 gated templated files + 2 first-seed files (`marimo.toml`, btop's `btop.conf`): [docs/this_repo/vim-mode.md](docs/this_repo/vim-mode.md).

**Hard rules**:

- Do **not** gate anything under `dot_config/nvim/` — Neovim is inherently vim by design.
- Do **not** gate editor configs (`.chezmoitemplates/editor/`, `dot_codex/modify_config.toml.tmpl`, `dot_config/opencode/modify_*.json.tmpl`, `dot_cursor/modify_cli-config.json`) — the flag's semantic is shells + tmux only. Editors want vim → install the editor's vim extension.
- Do **not** broaden the gate to `bindkey -M viins`/`vicmd` calls inside `dot_config/zsh/tools/*.zsh` — harmless no-ops without zsh-vi-mode loaded.
- The `minimal` bundle in `scripts/init/dotfiles_init.py` forces `enableVimMode = False` (CI/Docker). Don't change without explicit user request.
- New vim-touched file → follow the "Yes, gate it" / "No, leave it alone" flow in `docs/this_repo/vim-mode.md` → "For maintainers", and add it to the catalog table in that same page.

### Install vs upgrade is split on purpose

`chezmoi apply` + ansible is **install-only** (`state: present`, `creates:`). Explicit upgrade path: [`scripts/upgrade_tools.sh`](scripts/upgrade_tools.sh) via `just upgrade-*`. `scripts/**` is in `.chezmoiignore.tmpl`, so the upgrade script runs from the repo, never deployed.

**Hard rules**:

- Do **not** rewrite ansible roles to `state: latest`.
- Do **not** add `apt upgrade` / system package bumps to default scope.
- **Minimum-version exception**: a role MAY auto-upgrade a single tool inside `chezmoi apply` when it legitimately needs a newer version (e.g. `python_uv_tools` needs `uv >= 0.8.5` for `--with-executables-from`). MUST detect install style (brew vs curl/standalone) and dispatch — never blindly `uv self update` (no-op on brew uv) or `brew upgrade uv` (errors if not a brew formula). Dispatch helper is mirrored in `scripts/upgrade_tools.sh::cat_uv()` and `dot_ansible/roles/python_uv_tools/tasks/main.yml`. See [docs/this_repo/uv-bootstrap.md](docs/this_repo/uv-bootstrap.md), [pitfalls/uv-self-update-homebrew-noop.md](pitfalls/uv-self-update-homebrew-noop.md), [pitfalls/ansible-when-regex-replace-backslash-strip.md](pitfalls/ansible-when-regex-replace-backslash-strip.md).
- **`with_executables_from:` entries MUST also declare `extra_binaries:`** in `dot_ansible/roles/python_uv_tools/defaults/main.yml`. Without it the install guard short-circuits on hosts where the primary binary already exists, and entry-point shims are never written (silent missing `jupyter` / `jupyter-notebook` despite `jupyter-lab` present). Audit: `yq '.python_uv_tools[] | select(.with_executables_from) | select(.extra_binaries == null) | .name' …` MUST print nothing. See [pitfalls/uv-tool-install-creates-guard-misses-executables-from.md](pitfalls/uv-tool-install-creates-guard-misses-executables-from.md).
- New upgrade category: [docs/this_repo/upgrades.md → Adding a new category](docs/this_repo/upgrades.md). For a tool already managed by brew/uv/npm/cargo/dotnet/gem/mise: do nothing — generic `upgrade` picks it up.

### Sudo session is shared across all run-scripts

All three `run_*` scripts share one sudo session via `scripts/lib/sudo_shared.sh` — user prompted once at `chezmoi apply` start, reused silently downstream.

**Hard rules**:

- Do **not** re-implement `sudo -k` / `sudo -v` / TTY-read logic. Call the shared helper.
- Do **not** run `sudo -k` (invalidates the cache for the whole flow).
- Do **not** register a `trap … EXIT` that removes state (next run-script needs it).
- Do **not** read the password into a shell variable. Always `sudo -S <file`.
- Do **not** replace `_sudo_spawn_watchdog`'s `setsid`/`nohup` fallback with bare `setsid` — macOS lacks `setsid(1)` in base, the backgrounded failure is silent (redirected to `/dev/null`), and every run-script then re-prompts because `_sudo_state_valid`'s `kill -0` probe finds a dead PID. See [`pitfalls/sudo-shared-setsid-macos.md`](pitfalls/sudo-shared-setsid-macos.md).

**Adding a new sudo surface in a run-script**:

1. `{{ include "scripts/lib/sudo_shared.sh" }}` near the top of the template.
2. Set the `NEED_SUDO` template flag.
3. Call `sudo_session_init "yourlabel"`; branch on return code + `sudo_session_skip_reason`.
4. Privileged commands via `sudo_run …` or `-e @$CHEZMOI_ANSIBLE_BECOME_FILE` for ansible.

**Non-interactive password injection** (used by `scripts/fleet/apply.py` over SSH): `sudo_session_init` adopts `CHEZMOI_SUDO_PASSWORD_FILE` (a 0600 file) instead of prompting on `/dev/tty`. **Never** read `CHEZMOI_SUDO_PASSWORD_FILE` directly — always go through `sudo_session_init`. Full API + state + cleanup model: [docs/this_repo/sudo-session.md](docs/this_repo/sudo-session.md).

### fleet-apply counter-intuitive defaults

Full docs: [`docs/this_repo/fleet-apply.md`](docs/this_repo/fleet-apply.md). Load-bearing invariants:

- **`drift` ≠ `failed`**. When chezmoi can't prompt to overwrite a hand-edited file (no PTY over SSH), the host shows yellow ⚠ `drift` with paths listed — but it does **not** count toward exit code. Don't auto-"fix" drift unless asked. Resolution: hand-fix the remote, or `--force` to let template win.
- **`fleet-apply-file PATH` skips `run_*` scripts** (uses `chezmoi apply --exclude=scripts`). Ansible / Brewfile changes will NOT execute — use full `fleet-apply` for ansible iterations.
- **`--branch BRANCH` is no-op on local hosts** (the local source dir IS the user's editor working tree). Local hosts log warn and run against working tree as-is. The flag also forces mode to `apply`.
- **Install-only by design** (inherits the previous invariant). `just upgrade-*` must run on each host; fleet-apply does NOT broadcast upgrades.
- **Process substitution + sentinel are load-bearing**: `> >(tee -a $log) 2>&1 & _cz_pid=$!; wait $_cz_pid; _rc=$?; echo $_rc > $sentinel`. `--status` / `--tail` / `--watch` + SIGHUP trap depend on `$_cz_pid` pointing to chezmoi, not tee. Don't change to a pipeline.
- **Conservative drift classifier**: `_classify_drift()` only downgrades stderr lines matching the exact `chezmoi: <path>: could not open a new TTY: open /dev/tty:` fingerprint. Anything unrecognised stays `failed`. Don't broaden without explicit user request — silent downgrades hide real errors.
- **`fleet-status` ≠ `fleet-apply-status`** — easy to confuse:
  - `just fleet-status` → **pre-flight readiness probe** (states: `up-to-date`, `behind`, `ahead`, `dirty`, `drift`, `ready-to-update`, `busy`, `init-in-progress`, `toml-mismatch`, `not-init`, `no-source`, `no-chezmoi`, `unreachable`). Run **before** `fleet-apply`. Always exits 0; use `--readiness-json | jq` for scripted gates. `fleet-status-quick` skips remote `git fetch`.
  - `just fleet-apply-status` → **process-liveness probe** of `~/.cache/fleet-apply/<host>.{pid,sentinel,log}`. Run **during/after**. Pairs with `fleet-apply-tail` / `fleet-apply-watch` / `fleet-apply-kill`.
  - `toml-mismatch` catches a remote's `chezmoi.toml` missing prompt keys that current `.chezmoi.toml.tmpl` requires, via static `_PROMPT_KEY_RE` comparison — `chezmoi dump-config` cannot be used (would re-evaluate the very template we're inspecting).
  - `fleet-edit` + `fleet-status` are forgiving (auto-seed / exit 0 with hint); `fleet-apply` keeps strict exit-2 on missing inventory. Don't unify.

### `modify_` and `create_` prefix semantics

- **`modify_`** files are executable scripts: chezmoi pipes current target contents to stdin, expects new contents on stdout. Used for `~/.claude/settings.json` (jq overlay), editor `settings.json` (VSCode/Cursor/Antigravity), agent CLI configs (`~/.cursor/cli-config.json`, `~/.config/opencode/opencode.json`, `~/.codex/config.toml`), `~/.config/herdr/config.toml` (tomlkit overlay — managed tables enforced, herdr's runtime writeback preserved), and `~/.gitconfig` (preserves `[credential "<URL>"]` blocks injected by `gh auth setup-git` so the gh-managed absolute path to the local `gh` binary — different on Intel mac / Apple Silicon / Linuxbrew — survives `chezmoi apply`). **Never** `chezmoi add` a `modify_` target — it would overwrite the script with the live file.
- **`create_`** files seed once; chezmoi never touches contents after. Used for `~/.config/nvim/lazy-lock.json` and editor `keybindings.json`. Refresh baseline by copying directly: `cp <target> "$(chezmoi source-path <target>)"`. `chezmoi add` strips the prefix; `chezmoi re-add` silently skips.

Case studies + presence-gating in `.chezmoiignore.tmpl`: [docs/tools/chezmoi-prefixes.md](docs/tools/chezmoi-prefixes.md). Three agent CLI overlays (incl. the Claude hook-aware merger that coexists with [CodeIsland](https://github.com/wxtsky/CodeIsland)'s auto-installed hook entries without ping-ponging): [docs/tools/agent-overlays.md](docs/tools/agent-overlays.md).

### Tmux popup menu: ≥ 3.3 required + must fit terminal height

The popup menu (bound to `prefix + Space` and `prefix + e`) is **generated** by `~/.config/tmux/menu.sh`, not inline in `keybindings.conf`. Two unrelated tmux quirks force this:

1. **Position clamping (tmux ≥ 3.3)**: `display-menu -x R -y P` is silently suppressed on tmux 3.2a (Ubuntu 22.04 apt) when it would place the menu past the terminal edge. tmux 3.3+ clamps. `devtools` role auto-upgrades on Debian/Ubuntu (Linuxbrew first, else [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage) extracted to `~/.local/share/tmux-appimage/` with a `~/.local/bin/tmux` shim). Run `tmux kill-server` once after — running servers keep the old binary in memory.
2. **Menu-too-tall silent failure (all versions)**: `display-menu` does **not** paginate. Taller than terminal → entire popup suppressed, no error, nothing in `tmux show-messages`. `man tmux`: _"If the menu is too large to fit on the terminal, it is not displayed."_ Misdiagnosed for hours as a CSI-u keysym bug after a 50-row flat menu started failing on smaller heights.

**Hard rules**:

- **Top menu cap ≈ 14 rows**. Generator reads `#{client_height}` and tier-trims; retest at heights 14 / 22 / 60 when changing tiers. Push lower-frequency items into category submenus.
- **Submenus = separate scripts**, each `exec tmux display-menu …`. Quoting context resets per script.
- **Complex commands** (anything with `{`, `}`, `;`, backticks, nested fzf binds) MUST live in their own script. tmux's parser treats `{}` / `;` as command-block delimiters even inside `'…'` inside `"…"`, silently aborting parse.
- **Test by shrinking the terminal vertically**. Full-height verification does not catch the height-fit failure.

See `pitfalls/tmux-display-menu-silent-fail.md` (red herrings included) and `pitfalls/yazi-tmux-popup-crash.md`.

### Key tmux settings for coding agents

Non-obvious settings other tools depend on; do not remove without checking:

- `extended-keys on` + `terminal-features 'xterm*:extkeys'` — forwards Shift+Enter, Ctrl+Enter, Ctrl+/, Ctrl+digit to inner apps (Claude Code, Neovim, …). **Never use `always`** — re-encodes EVERY `Ctrl+letter` as CSI-u including the LF (Ctrl+J) embedded in pasted multi-line text → ble.sh inserts `^[[106;5u` literally instead of newline. See `pitfalls/tmux-extended-keys-always-paste.md`.
- `escape-time 0` — eliminates ESC delay for Neovim.
- `set-clipboard on` + `terminal-features …:clipboard` (for `xterm*`, `ghostty*`, `alacritty*`) — OSC 52 over SSH without terminfo `Ms`. Paired with SSH-conditional `vim.g.clipboard = vim.ui.clipboard.osc52` in `dot_config/nvim/lua/config/options.lua`. See [docs/tools/tmux/README.md → OSC 52 Clipboard](docs/tools/tmux/README.md).
- `allow-passthrough on` — OSC passthrough for terminal images.
- macOS terminals must send Option as Meta/Esc+ for `M-` keybindings (theme switching, layouts, fine resize). Ghostty/cmux: `macos-option-as-alt = left` in `dot_config/ghostty/config`. See [docs/tools/ghostty.md](docs/tools/ghostty.md).

Full tmux config breakdown / theme switching / keybindings / troubleshooting: [docs/tools/tmux/](docs/tools/tmux/).

### Zellij `default_mode "locked"`

`dot_config/zellij/config.kdl` uses `default_mode "locked"` so all keys pass through to inner apps by default. `Ctrl+G` to unlock Zellij commands. First Zellij launch (no existing config): select the "Unlock-First (non-colliding)" keybinding preset.
