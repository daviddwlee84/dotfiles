# Dotfiles Repository — Agent Contract

Cross-platform dotfiles managed by **chezmoi** (configs) + **ansible** (system deps). This file is the agent-facing contract: edit rules and cross-file invariants. User-facing intro: [README.md](README.md).

> **Headroom rule**: keep this file under ~30k chars. Push handbook content into `docs/`; keep only rules an agent must obey *without* opening another file. `AGENTS.md` and `GEMINI.md` are symlinks to this file — edit one.

## Cross-file maintenance rules

When you touch one of these surfaces, update the listed mirror in the same commit.

| Surface you change | Also update | Reference |
|---|---|---|
| Config files / ansible roles / platforms / setup steps | `README.md` (What You Get, Supported Platforms, Quick Setup) | — |
| Console logging in any shell script | **Never re-hand-roll `info`/`warn`/`success`/`error` + a colour block** — `scripts/lib/log_shared.sh` is the SSOT for 13 consumers. run-scripts `{{ include }}` it (they render to a temp path) and MUST set `LOG_STREAM=stdout` first, or fleet-apply's local-host `_classify_drift()` demotes their stderr from `drift` to `failed`; `scripts/*.sh` `source` it; `$HOME`-deployed files can't use it (`scripts/**` is chezmoi-ignored). Editing it rehashes every `run_onchange_after_*` that inlines it → full ansible + brew re-run everywhere, so batch edits. New consumer → add it to the wiring guard in `tests/unit/log_shared.bats`. | [shell-logging](docs/this_repo/shell-logging.md) — API, config vars, and the `set -e`/`set -u`/`IFS`/top-level-`return` traps |
| New `docs/**/*.md` | Nav entry in `mkdocs.yml`; run `uv run mkdocs build --strict` | known anchor-drift is tracked in [`backlog/mkdocs-anchor-drift.md`](backlog/mkdocs-anchor-drift.md) — don't tighten `validation.links.not_found` until cleared |
| New tool installed by any mechanism (ansible role / Brewfile / curl-installer / mise / uv / npm / cargo / gem / dotnet), or removed, or switched | Add / update / remove its row in [`docs/this_repo/tool-managers.md`](docs/this_repo/tool-managers.md) § Tool index (A–Z) — one line, the high-churn case. A new install **mechanism** (as opposed to a new tool through an existing one) additionally needs its § Per-manager catalog subsection and the § Decision tree. | Install-side companion to [upgrades.md](docs/this_repo/upgrades.md) — update that too if the tool has a non-trivial upgrade story. |
| Alias / shell function in `dot_config/{shell,zsh,bash}/` | Row in [aliases.md](docs/shells/aliases.md) (name, type, source, scope, one-line) | [config-conventions.md](docs/this_repo/config-conventions.md) for repo-wide config conventions |
| Shell history env vars / `setopt`s / atuin filters | Tables in [history.md](docs/shells/history.md) | — |
| Linux GUI app in `dot_ansible/roles/gui_apps_linux/` | Inventory table in [linux-gui-apps.md](docs/playbooks/linux-gui-apps.md) — the playbook is also the decision tree, read it first | — |
| New chezmoi prompt | Edit the `PROMPTS` tuple in `scripts/init/dotfiles_init.py` — the SSOT (key/kind/default/`prompt_text`/`comment`, plus `condition=When(...)`+`else_value` for host-gated prompts, and `BUNDLES` where relevant). Then `just gen-prompts` to regenerate `.chezmoi.toml.tmpl` + `Dockerfile`, and add the key to the README option table. **Never hand-edit the generated marker regions.** | `just gen-prompts --check` and the `dotfiles-init-gen-check` pre-commit hook fail on drift |
| `dot_dotfiles/bin/executable_fleet` / `scripts/fleet/*.py` / `justfile` `fleet-*` recipes / `dot_config/fleet/` / `dot_config/television/cable/fleet-hosts.toml` | Three schema pairs break **silently** when only one side changes: `tmux-session-summary.py --json` ↔ `scripts/fleet/tmux.py:_parse_raw`; `executable_pqsum`'s `HostSnapshot`/`GroupRec`/`TaskRec` ↔ `scripts/fleet/pueue.py:_run_pqsum_ai` payload (fleet pipes `pueue status --json` → `pqsum json --raw-stdin` → `pqsum ai --stdin-json`); `scripts/fleet/pueue.py:_REMOTE_CMD` ↔ `scripts/fleet/exec.py:_PATH_PRELUDE`. | [fleet-apply](docs/this_repo/fleet-apply.md), [pueue](docs/tools/pueue.md), [fleet-exec](docs/tools/fleet-exec.md), [fleet-hosts](docs/tools/fleet-hosts.md) |
| **Paired TUI + `tv` channel CLIs** — `mlf` (`scripts/mlf/`, `cable/mlflow.toml`), `yth` (`scripts/yth/`, `cable/yth.toml`), `appsrc` (single-file launcher, `cable/appsrc*.toml`), each with `dot_config/{zsh/tools,bash}/*_completion.*` | All three share one convention: the TUI's single-letter `BINDINGS` and the tv channel's `<mod>+<letter>` actions are deliberately the **same letters** — change one → change both, same commit. Read the letters from the launcher's `BINDINGS` and the channel `.toml`, never from here; they drift. New channel actions prefer `Alt+` — tmux's prefix is `Ctrl+b`, so `ctrl-b` never reaches tv. Shared helpers live in `scripts/<tool>/__init__.py` — **except `appsrc`**, deliberately one self-contained launcher. `appsrc scan --tsv`'s column order (`name·source·path·kind·package[·size]`) is the pickers' wire format — reorder → fix every `{split:\t:N}`. `yt-dlp[default]` is declared in all THREE of `yth`'s PEP723 header, `ytmv`'s PEP723 header, and `python_uv_tools` (the extra supplies matched `yt-dlp-ejs`). | [yth](docs/tools/yth.md) · [appsrc](docs/tools/appsrc.md) § Maintaining it · deferred: [`backlog/yth-semantic-search.md`](backlog/yth-semantic-search.md) |
| `ytmv` — `dot_dotfiles/bin/executable_ytmv` / `scripts/ytmv/*.py` / `dot_config/{zsh/tools,bash}/60_ytmv_completion.*` | Four silent breakages: **cookies are `yth`'s** (`cookie_options()` imports `scripts.yth.cookie_opts`); **public YouTube needs EJS + Node 22+** (`yt-dlp[default]` on all three install surfaces above, and every embedded `YoutubeDL` call merges `scripts.yth.yt_dlp_runtime_opts()` — never restore `no_warnings=True`); **`--burn-subs` needs `ffmpeg-full`** in `media_tools` (plain brew `ffmpeg` 8.x has no libass — keg-only, stays inside the `installMediaTools` gate); **`PROFILES` is the profile-name SSOT**, read by completions via `ytmv doctor --list-profiles`. `raw-big5`/`raw-gbk` write cp950/gbk bytes in latin-1-declared ID3 frames **on purpose** — don't "fix" it; use cp950/gbk, never bare big5/gb2312. No `tv` channel by design. | [ytmv](docs/tools/ytmv.md) — profiles, bisect table, lyrics chain |
| New coding-agent artifact dir with secret risk | `DEFAULT_PATHS` in `scripts/redact_secrets.py` + `files:` regex in `redact-agent-secrets` pre-commit hook | Currently auto-scanned: `.specstory/history/`, `.claude/plans/`, `.cursor/plans/`, `.opencode/plans/` |
| Office viewing: `dot_dotfiles/bin/executable_view-office` / `executable_view-ebook` / `dot_config/yazi/{yazi.toml,package.toml}` / `.chezmoiscripts/global/run_after_45_yazi_plugins.sh.tmpl` / `dot_config/{zsh/tools,bash}/5{5,6}_view_*_completion.*` | `yazi.toml`'s `piper -- view-office --preview --width …` ↔ `view-office`'s flag interface — change one → change both. `markitdown` MUST keep its `[docx,xlsx,pptx]` extras in `python_uv_tools/defaults/main.yml` (bare package reads NO Office files). Source `package.toml` stays **comment-free** (`ya pkg install` rewrites it stripped → perpetual drift). | [office-viewers](docs/tools/office-viewers.md) — incl. § The `ya pkg` plugin mechanism (add-a-plugin recipe, `ya` CLI requirement); [yazi-previews](docs/tools/yazi-previews.md) (Kindle/calibre) |
| Data-file viewing: `dot_config/yazi/{package.toml,init.lua,yazi.toml,keymap.toml}` | `duckdb.yazi` needs ALL THREE or it silently no-ops: `[[plugin.deps]]` in `package.toml`, `require("duckdb"):setup{}` in `init.lua`, and `run = "duckdb"` in BOTH `prepend_previewers` and `prepend_preloaders`. **Any yazi plugin also needs the `ya` CLI** (`ya --version` diagnoses); keep the `pcall` around `init.lua`'s `require` or a missing `ya` becomes a fatal startup error blaming the wrong thing. yazi 26.x uses `[mgr]`, not `[manager]`. | [data-viewers](docs/tools/data-viewers.md) — piper fallbacks, xlsx `spatial` fetch, H/L keymap override; [pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md](pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md) |
| Yazi preview coverage: `dot_ansible/roles/devtools/tasks/main.yml` (`chafa`/`poppler`/`sevenzip`/`resvg`/`glow`) + `dot_config/yazi/yazi.toml` piper rules; ffmpeg/ImageMagick in `dot_ansible/roles/media_tools/`; chafa shim `dot_dotfiles/bin/executable_chafa` | A **tool-install** contract — yazi shells out at runtime, its built-in previewers aren't wired in `yazi.toml`. `chafa` is the shared display step for *every* image-derived preview → missing = `failed to spawn chafa` across png/pdf/video/HEIC at once. Baseline always-install: `chafa`+`poppler`+`sevenzip`+`resvg`; ffmpeg+ImageMagick stay gated behind `installMediaTools` — do **not** promote them. **Never drop the `--probe off` chafa shim** (OSC reply leaks into yazi's input under tmux; yazi #3680 WONTFIX). Every piper rule needs `2>/dev/null` — piper renders any stderr as an error preview. | [yazi-previews](docs/tools/yazi-previews.md) — per-format rules, Markdown/glow `CLICOLOR_FORCE`, ImageMagick-v6 caveat |
| bat theme: `dot_config/bat/themes/tokyonight_night.tmTheme` ↔ `.chezmoiscripts/global/run_after_25_bat_theme.sh.tmpl` ↔ `dot_config/shell/25_bat.sh` | bat reads only the bincode cache in `~/.cache/bat`, which lives OUTSIDE chezmoi's tree — keep the script `run_after_` with its own freshness check; do **not** regress to `run_onchange_` on the theme file (the cache is wiped by events that never touch it, and the hash then pins the broken state forever). `25_bat.sh` exports `BAT_THEME` only when the cache exists. Delta health check stays on the rendering path (`printf '' \| delta …`), never `delta --version`. **Generalisable**: `run_onchange_` is valid only when the script's *product* lives in chezmoi's tree; caches need `run_after_` + freshness check. | [pitfalls/bat-theme-cache-cleared-never-rebuilt.md](pitfalls/bat-theme-cache-cleared-never-rebuilt.md), [pitfalls/git-delta-empty-stdin-huge-allocation.md](pitfalls/git-delta-empty-stdin-huge-allocation.md) |
| New in-house CLI in `dot_dotfiles/bin/executable_*` (or new subcommand) | Add tab completion for **both** shells per the decision flow in [docs/zsh/zsh-completions.md](docs/zsh/zsh-completions.md) § F; hand-written = two files (`dot_config/zsh/tools/<NN>_<name>_completion.zsh` + `dot_config/bash/<NN>_<name>_completion.bash`) kept in sync. Add a row to that § F table, and to [docs/shells/aliases.md](docs/shells/aliases.md) if it ships an `<tool>-update-completion` helper. | § F also records the two existing strategies + the dynamic-candidate pattern. **SSH-config parsing now has three implementations** — `96_ssh_setup.sh:_ssh_cfg_py` (surgical block editor), `cable/ssh-config.toml`'s awk (display lister), `executable_tsnet` (managed-block owner + include-reachability); kept honest by a cross-implementation agreement test in `tests/unit/tsnet_ssh_block.bats`, not shared code |
| Tool inventory / in-house CLIs / `tv` channels / keymaps **surfaced to agents** | `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` — **only the `{{ dig … }}` substitutions re-render on apply; the prose does NOT.** A new `dot_dotfiles/bin/executable_*`, tool family, or prompt key stays invisible to every agent until you hand-add it here (an audit found 5 CLIs, all of `herdr`, and `agentSounds` missing). Keep it lean — the `ls dot_dotfiles/bin/` escape hatch is a fallback, not a substitute. | [docs/tools/agent-skills.md](docs/tools/agent-skills.md) § First-party templated skill — incl. the `.chezmoiignore` single-`*` re-include trap |
| New upstream CLI that ships `--completion <shell>` | Add a `regen <tool> "<zsh-args>" "<bash-args>"` row to `scripts/generate_completions.sh`; repo-backed launchers may additionally pin a canonical runner + Git revision freshness path. Verify with `just completions-refresh`. `run_after_50_generate_completions.sh.tmpl` then regenerates on every apply (mtime check, ~21ms cached). | [docs/zsh/zsh-completions.md](docs/zsh/zsh-completions.md) § A — current 18-tool inventory + what's deliberately handled elsewhere |
| Keybinding (`Ctrl+`/`Alt+`) in any tool config | Cross-check namespace before claiming — tmux root-table `bind -n C-*` shadows inner apps; prefer `Alt+` for new actions | [docs/shells/keybindings.md](docs/shells/keybindings.md), [docs/tools/claude-code-keybindings.md](docs/tools/claude-code-keybindings.md), [docs/this_repo/vim-mode.md](docs/this_repo/vim-mode.md) |
| AI agent autodetect order or `AICAP_*_MODEL` defaults | Edit **only** [`dot_config/shell/04_ai_agents.sh`](dot_config/shell/04_ai_agents.sh) — the SSOT. Four Python consumers regex-parse that same file for cron / tmux-popup contexts where env isn't inherited, so a **new agent** means six edits, not one. | [docs/tools/aicapture.md](docs/tools/aicapture.md) § Maintaining the agent list — names all four consumers + the queued `scripts/aisum/` extraction |
| chezmoi-apply reload hint: `.chezmoiscripts/global/run_after_99_signal_reload.sh.tmpl` ↔ `dot_config/shell/99_chezmoi_reload.sh` | The sentinel path `~/.cache/chezmoi/last-apply` is hard-coded in **both** files — keep them in sync when relocating. Hook registration must stay in the shared backend, NOT `dot_config/{zsh,bash}/99_*`: bash loads `$BASH_CONFIG_DIR` before `$XDG_CONFIG_HOME/shell` (oh-my-bash prereq, `dot_bashrc.tmpl:94` vs `:114`), so a per-shell file would run before the backend function exists. Opt out: `CHEZMOI_RELOAD_HINT=0`. | Row in [docs/shells/aliases.md](docs/shells/aliases.md) "Dotfiles management" for `cas`/`cau` |
| `app-*` helpers — `dot_config/shell/5{4,6}_{macos,linux}_apps.sh.tmpl` ↔ `dot_config/television/cable/{mac,linux}-apps.toml.tmpl` | Both shell helpers MUST expose the SAME public verbs (`appquit`/`applaunch`/`appactivate`/`apprestart`/`apprunning`/`applist`/`appresponsive`) — backends diverge, names don't. Both tv channels share Alt-keys where the verb exists on both sides; **Alt+H is mac-only by design** (no Linux window-hide without compositor IPC) — leave that slot free. Never auto-generate `~/.config/shell/linux-apps.conf` (same rule as `.shellrc.secrets`). New verb on one side only → record the gap in `backlog/linux-desktop-app-control.md`. | [docs/playbooks/linux-gui-apps.md](docs/playbooks/linux-gui-apps.md) — incl. why `gapplication` is *not* the mechanism (~13 apps covered on Ubuntu 24.04, zero third-party) |
| Docker `registry-mirrors` in `dot_config/docker/modify_daemon.json.tmpl` (canonical) | Mirror the list + per-mirror notes into [containers.md](docs/tools/containers.md) and the coverage matrix + § Security and trust model in [mirrors.md](docs/tools/mirrors.md) — **both plus their `.zh-TW`**. When dropping/adding, state the **security** reason, not just speed: mirrors resolve `tag→digest` and Content Trust is off by default, so a lapsed third-party domain can be re-registered into a malicious pull-through cache. Curated high-reputation set only. | — |

**Repo-root files that stay OUT of MkDocs nav** (`README.md`, `CLAUDE.md` / `AGENTS.md` / `GEMINI.md`, `TODO.md`, `backlog/`, `pitfalls/`, `NOTES.md`): referenced via absolute GitHub URLs from [`docs/for-maintainers.md`](docs/for-maintainers.md), never copied via `pymdownx.snippets`.

**Three-tier file placement** for new shell helpers:

| Tier | Dir | When |
|---|---|---|
| Shared | `dot_config/shell/` | POSIX subset, both shells source. `$ZSH_VERSION`/`$BASH_VERSION` source-time dispatch is OK; ZLE widgets / `compdef` / `bindkey` / `setopt` / `read -q` / `${m:t}` / glob qualifiers are NOT (bash would error on source). |
| Zsh-only | `dot_config/zsh/` | ZLE widgets, `compdef`, `bindkey`, `setopt`, zsh-vi-mode hooks. |
| Bash-only | `dot_config/bash/` | `bind -x` / `ble-bind`, OMB plugin arrays, bash-specific `shopt`s. |

When porting a zsh-only helper to bash via ble.sh, extract the shell-agnostic backend into `dot_config/shell/` and keep each shell's widget binding in its own dir.

### Workmux status icon integration spans 6 files

The `🤖`/`💬`/`✅` per-tmux-window status mechanism spans **6 surfaces that must move together** — devtools install, `dot_config/workmux/config.yaml`, `dot_config/tmux/theme.catppuccin.conf`, `dot_claude/modify_settings.json.tmpl` hooks, `dot_config/opencode/plugins/workmux-status.ts` (+ its `modify_package.json`), and `dot_config/shell/60_tmux_status.sh`'s producers API. Exact contents: [workmux.md](docs/tools/workmux.md) § Status icon mechanics; why it leaks: [workmux-status-leak.md](pitfalls/workmux-status-leak.md).

**Hard rules**: never run `workmux setup` on a managed machine (writes parallel hook entries); never flip `status_format: true` (fights catppuccin's window-text override); never drop the `command -v workmux >/dev/null 2>&1 && … || true` guard in Claude hooks (spams errors on fresh boxes); never drop explicit `set-window-status done` from `Stop`/`SubagentStop` (upstream only ever sets `working`, never clears). The workmux hook entries are **unconditional** — the `agentSounds` prompt gates only the notify.sh / peon-ping entries in the same file. `wt` (worktrunk) and `wm` (workmux) stay distinct tools.

### Long-term backlog + past pitfalls → use the `project-knowledge-harness` skill

This repo uses the `project-knowledge-harness` agent skill (restored on every `chezmoi apply`; see [agent-skills.md](docs/tools/agent-skills.md)). **Load the skill** for the template and disambiguation table.

**Fallback rules**, so this still binds when the skill can't be loaded:

- Three repo-root surfaces, all chezmoi-ignored, all NOT auto-redacted: [`TODO.md`](TODO.md) (tags `P1`/`P2`/`P3`/`P?` × `S`/`M`/`L`/`XL`), [`backlog/`](backlog/README.md) (notes for `P?` / `[L]` / `[XL]` / multi-option), [`pitfalls/`](pitfalls/README.md) (debugged traps — **title by symptom, not root cause**, verbatim error messages, never paraphrase).
- Capture triggers — future work: "maybe later", "nice to have", "工程量太大需要再評估", "先記下來". Pitfalls: >~15 min debugging, not googleable, non-obvious fix, silent failure.
- Do **not** spawn `ROADMAP.md` / `IDEAS.md` / `LESSONS.md` / `TROUBLESHOOTING.md`. Three surfaces, always.
- A pitfall *graduates* to a Hard invariant below when it recurs across machines, silently corrupts state, or has a non-obvious workaround. Link back to `pitfalls/<slug>.md`.

## Chezmoi templating conventions

**Hard rule**: before adding `{{ if eq .profile … }}`, ask whether the predicate is auto-detectable. If yes, use `.chezmoi.os` (`darwin`/`linux`) / `.chezmoi.arch` (`arm64`/`amd64`) / `.chezmoi.hostname`. `.profile` is for **user-role choices only**, and its values are limited to `macos`, `ubuntu_desktop`, `ubuntu_server` — do **not** introduce new values for OS/arch facts. `.profile` is still the right knob for desktop-vs-headless.

**Hard rule — prefer XDG paths.** When a tool supports both a `$HOME`-root dotfile and an XDG path (`~/.config/<tool>/…`), manage the XDG copy (`dot_config/<tool>/…`) to keep `$HOME` tidy; only use a root dotfile when the tool can't read XDG. For tools that error when *both* paths exist (e.g. AeroSpace), also remove the legacy root file via a gated `.chezmoiremove` entry. Full rule + lookup-order caveats: [docs/this_repo/config-conventions.md → A1](docs/this_repo/config-conventions.md).

Predicate table, examples, the `macos_intel` migration: [chezmoi-templating.md](docs/tools/chezmoi-templating.md).

## Hard repo invariants

### Validate app configs with the app, not just syntax

YAML / TOML / JSON syntax and template rendering are not enough. If the app exposes a config check, parser, dry-run, or debug command, run it against the rendered config before declaring done (`codex debug …` for `~/.codex/config.toml`; `tmux source-file` / `display-menu` smoke; `mkdocs build --strict` for docs; for Ansible the narrowest practical play/tag/check-mode or container smoke — `--syntax-check` alone is only a first pass). If a validator cannot be run, say so explicitly in the final report and name the missing command/host/credential.

### `primaryShell` choice gates `chsh` only — both shells always deploy

`primaryShell` (`zsh` | `bash`, default `zsh`) **only** governs which login shell `chsh` switches to. Both `~/.zshrc`, `~/.bashrc`, `~/.config/{shell,zsh,bash}/` deploy everywhere — users routinely drop into the other shell ad-hoc.

**Hard rules**:

- Do **not** add `{{ if eq .primaryShell … }}` gates around `dot_zshrc.tmpl`, `dot_bashrc.tmpl`, or `dot_config/{shell,zsh,bash}/**`.
- Do **not** gate the zsh / bash ansible roles' **package install** task on `primary_shell` — only `chsh` is gated. macOS bash 5.x brew install + `/etc/shells` whitelist are gated on `primary_shell == "bash"` (zsh-primary mac users skip the brew formula).
- Do **not** rely on `$SHELL` — it reflects `/etc/passwd`, lags `chsh` until next login. Use `$ZSH_VERSION` / `$BASH_VERSION`.

The ble.sh + oh-my-bash 12-step init order in `dot_bashrc.tmpl` is load-bearing: `ble.sh --attach=none` MUST source before bash-preexec/starship; `ble-attach` MUST be last before secrets/adhoc; OMB's `autosuggestions`/`syntax-highlighting`/`history-substring-search` MUST be excluded (double-init flicker). [bash.md](docs/shells/bash.md).

### Three-tier user-local override layer

User overrides live in **six** untracked files, all in `.chezmoiignore.tmpl`: shared POSIX (`~/.shellrc.adhoc`, `~/.shellrc.secrets`) and per-shell (`~/.zshrc.adhoc`, `~/.bashrc.adhoc`, `~/.config/zsh/secrets.zsh`, `~/.config/bash/secrets.sh`). Default target: shared; drop to per-shell only when shell-specific syntax is required.

**Load order** in both `dot_zshrc.tmpl` and `dot_bashrc.tmpl` — `managed modules → shared secrets → per-shell secrets → shared adhoc → per-shell adhoc`. Secrets before adhoc (so adhoc can read secret vars); shared before per-shell (per-shell wins on conflict).

**Hard rules**: never add the shared files to chezmoi management; never auto-stub the `*.secrets` files (empty secrets footgun); the shared adhoc stub heredoc lives in BOTH `dot_zshrc.tmpl` AND `dot_bashrc.tmpl` (first shell to run wins; second sees the file and skips) — keep both heredoc bodies in sync. Full matrix: [adhoc-and-secrets.md](docs/shells/adhoc-and-secrets.md).

### `enableVimMode` gates shell + tmux vim, NOT Neovim or editors

`enableVimMode` (bool, default `true`) gates **shell modal editing + tmux vim navigation only**. Neovim and every editor config (VSCode/Cursor/Antigravity/Codex/OpenCode/Cursor-CLI) are **never** affected. Full catalog of the 7 gated templates + 2 first-seed files: [vim-mode.md](docs/this_repo/vim-mode.md).

**Hard rules**:

- Do **not** gate anything under `dot_config/nvim/` — Neovim is inherently vim by design.
- Do **not** gate editor configs (`.chezmoitemplates/editor/`, `dot_codex/`, `dot_config/opencode/`, `dot_cursor/`) — the flag's semantic is shells + tmux only. Editors want vim → install the editor's vim extension.
- Do **not** broaden the gate to `bindkey -M viins`/`vicmd` calls inside `dot_config/zsh/tools/*.zsh` — harmless no-ops without zsh-vi-mode loaded.
- The `minimal` bundle forces `enableVimMode = False` (CI/Docker). Don't change without an explicit request.
- New vim-touched file → follow the gate-it-or-not flow in [vim-mode.md](docs/this_repo/vim-mode.md) → "For maintainers", and add it to the catalog table there.

### Install vs upgrade is split on purpose

`chezmoi apply` + ansible is **install-only** (`state: present`, `creates:`). Explicit upgrade path: [`scripts/upgrade_tools.sh`](scripts/upgrade_tools.sh) via `just upgrade-*`. `scripts/**` is in `.chezmoiignore.tmpl`, so the upgrade script runs from the repo, never deployed.

**Hard rules**:

- Do **not** rewrite ansible roles to `state: latest`.
- Do **not** add `apt upgrade` / system package bumps to default scope.
- **Minimum-version exception**: a role MAY auto-upgrade a *single* tool inside `chezmoi apply` when it genuinely needs a newer one (`python_uv_tools` needs `uv >= 0.8.5`). It MUST detect the install style and dispatch — never blindly `uv self update` (silent no-op on brew uv) or `brew upgrade uv` (errors when it isn't a formula). The dispatch helper is mirrored in `scripts/upgrade_tools.sh::cat_uv()` and the role. See [uv-bootstrap](docs/this_repo/uv-bootstrap.md), [uv-self-update-homebrew-noop.md](pitfalls/uv-self-update-homebrew-noop.md), [ansible-when-regex-replace-backslash-strip.md](pitfalls/ansible-when-regex-replace-backslash-strip.md).
- **`with_executables_from:` entries MUST also declare `extra_binaries:`** in `dot_ansible/roles/python_uv_tools/defaults/main.yml`, or the install guard short-circuits and entry-point shims are never written (silently missing `jupyter` despite `jupyter-lab` present). Audit command: [uv-tool-install-creates-guard-misses-executables-from.md](pitfalls/uv-tool-install-creates-guard-misses-executables-from.md).
- New upgrade category: [upgrades.md](docs/this_repo/upgrades.md) § Adding a new category. Tool already managed by brew/uv/npm/cargo/dotnet/gem/mise → do nothing, generic `upgrade` picks it up.
- **Probe `brew` by output, never exit status** — `[[ -n "$(brew --prefix 2>/dev/null)" ]]`. A stub `brew` passes `command -v brew` and returns 0 with empty output for *every* subcommand: `brew bundle` silently installs nothing and `community.general.homebrew` dies on `Expecting value: line 1 column 1 (char 0)`. [ansible-homebrew-expecting-value-line-1-column-1.md](pitfalls/ansible-homebrew-expecting-value-line-1-column-1.md)

### Sudo session is shared across all run-scripts

All three `run_*` scripts share one sudo session via `scripts/lib/sudo_shared.sh` — user prompted once at `chezmoi apply` start, reused silently downstream.

**Hard rules**:

- Do **not** re-implement `sudo -k` / `sudo -v` / TTY-read logic. Call the shared helper.
- Do **not** run `sudo -k` (invalidates the cache for the whole flow).
- Do **not** register a `trap … EXIT` that removes state (next run-script needs it).
- Do **not** read the password into a shell variable. Always `sudo -S <file`.
- Do **not** replace `_sudo_spawn_watchdog`'s `setsid`/`nohup` fallback with bare `setsid` — macOS lacks `setsid(1)` in base, the backgrounded failure is silent (redirected to `/dev/null`), and every run-script then re-prompts because `_sudo_state_valid`'s `kill -0` probe finds a dead PID. See [`pitfalls/sudo-shared-setsid-macos.md`](pitfalls/sudo-shared-setsid-macos.md).

**Adding a new sudo surface in a run-script**: `{{ include "scripts/lib/sudo_shared.sh" }}` near the top → set the `NEED_SUDO` template flag → `sudo_session_init "yourlabel"` and branch on its return code + `sudo_session_skip_reason` → run privileged commands via `sudo_run …` (or `-e @$CHEZMOI_ANSIBLE_BECOME_FILE` for ansible).

For **non-interactive** injection (`scripts/fleet/apply.py` over SSH), `sudo_session_init` adopts `CHEZMOI_SUDO_PASSWORD_FILE` (0600) instead of prompting on `/dev/tty` — **never** read that variable directly, always go through the helper. Full API + state + cleanup model: [sudo-session.md](docs/this_repo/sudo-session.md).

### fleet-apply counter-intuitive defaults

Full docs: [`docs/this_repo/fleet-apply.md`](docs/this_repo/fleet-apply.md). Load-bearing invariants:

- **`drift` ≠ `failed`**. When chezmoi can't prompt to overwrite a hand-edited file (no PTY over SSH), the host shows yellow ⚠ `drift` with paths listed — it does **not** count toward exit code. Don't auto-"fix" drift unless asked; hand-fix the remote, or `--force` to let the template win.
- **`fleet-apply-file PATH` skips `run_*` scripts** (`chezmoi apply --exclude=scripts`), so ansible / Brewfile changes will NOT execute — use full `fleet-apply` for those.
- **`--branch BRANCH` is a no-op on local hosts** (the local source dir IS your editor working tree): they warn and run against the working tree as-is. The flag also forces mode to `apply`.
- **Install-only by design.** `just upgrade-*` must run on each host; fleet-apply does NOT broadcast upgrades.
- **Process substitution + sentinel are load-bearing**: `> >(tee -a $log) 2>&1 & _cz_pid=$!; wait $_cz_pid; _rc=$?; echo $_rc > $sentinel`. `--status` / `--tail` / `--watch` + SIGHUP trap depend on `$_cz_pid` pointing to chezmoi, not tee. Don't change to a pipeline.
- **Conservative drift classifier**: `_classify_drift()` only downgrades stderr lines matching the exact `chezmoi: <path>: could not open a new TTY: open /dev/tty:` fingerprint; anything unrecognised stays `failed`. Don't broaden without an explicit request — silent downgrades hide real errors.
- **`fleet-status` ≠ `fleet-apply-status`** — easy to confuse. `just fleet-status` is the **pre-flight readiness probe** (13 states; always exits 0 — use `--readiness-json | jq` for scripted gates; `fleet-status-quick` skips the remote `git fetch`). `just fleet-apply-status` is a **process-liveness probe** of `~/.cache/fleet-apply/<host>.{pid,sentinel,log}`, run during/after, pairing with `fleet-apply-tail`/`-watch`/`-kill`. State meanings incl. `toml-mismatch`: [fleet-apply.md](docs/this_repo/fleet-apply.md).
- **`fleet-edit` + `fleet-status` are forgiving** (auto-seed / exit 0 with a hint); `fleet-apply` keeps strict exit-2 on missing inventory. Don't unify.

### `modify_` and `create_` prefix semantics

- **`modify_`** files are executable scripts: chezmoi pipes the current target contents to stdin and expects the new contents on stdout. Used wherever a *foreign writer* also owns part of the file — `~/.claude/settings.json`, editor `settings.json`, the agent CLI configs, `~/.config/herdr/config.toml`, `~/.gitconfig` (preserves the `[credential]` blocks `gh auth setup-git` injects). **Never** `chezmoi add` a `modify_` target — it overwrites the script with the live file.
- **`create_`** files seed once; chezmoi never touches the contents after (`~/.config/nvim/lazy-lock.json`, editor `keybindings.json`). Refresh the baseline by copying directly: `cp <target> "$(chezmoi source-path <target>)"` — `chezmoi add` strips the prefix and `chezmoi re-add` silently skips.

Per-file case studies + presence-gating in `.chezmoiignore.tmpl`: [chezmoi-prefixes.md](docs/tools/chezmoi-prefixes.md). The three agent CLI overlays, incl. the Claude hook merger that coexists with [CodeIsland](https://github.com/wxtsky/CodeIsland) without ping-ponging: [agent-overlays.md](docs/tools/agent-overlays.md).

### Tmux popup menu: ≥ 3.3 required + must fit terminal height

The popup menu (`prefix + Space` / `prefix + e`) is **generated** by `~/.config/tmux/menu.sh`, not inline in `keybindings.conf`. Two tmux quirks force that: `display-menu -x R -y P` is silently suppressed on tmux 3.2a (Ubuntu 22.04 apt) instead of clamped — the `devtools` role auto-upgrades Debian/Ubuntu past it — and `display-menu` does **not** paginate, so a menu taller than the terminal is suppressed entirely, with no error anywhere.

**Hard rules**:

- **Top menu cap ≈ 14 rows**. Generator reads `#{client_height}` and tier-trims; retest at heights 14 / 22 / 60 when changing tiers. Push lower-frequency items into category submenus.
- **Submenus = separate scripts**, each `exec tmux display-menu …`. Quoting context resets per script.
- **Complex commands** (anything with `{`, `}`, `;`, backticks, nested fzf binds) MUST live in their own script. tmux's parser treats `{}` / `;` as command-block delimiters even inside `'…'` inside `"…"`, silently aborting parse.
- **Test by shrinking the terminal vertically**. Full-height verification does not catch the height-fit failure.

Full story incl. the red herrings: `pitfalls/tmux-display-menu-silent-fail.md`, `pitfalls/yazi-tmux-popup-crash.md`.

### Key tmux settings for coding agents

Non-obvious settings other tools depend on; do not remove without checking:

- `extended-keys on` + `terminal-features 'xterm*:extkeys'` — forwards Shift+Enter, Ctrl+Enter, Ctrl+/, Ctrl+digit to inner apps. **Never use `always`** — re-encodes EVERY `Ctrl+letter` as CSI-u including the LF (Ctrl+J) embedded in pasted multi-line text → ble.sh inserts `^[[106;5u` literally instead of newline. See `pitfalls/tmux-extended-keys-always-paste.md`.
- `escape-time 0` — eliminates ESC delay for Neovim.
- `set-clipboard on` + `terminal-features …:clipboard` (for `xterm*`, `ghostty*`, `alacritty*`) — OSC 52 over SSH without terminfo `Ms`. Paired with SSH-conditional `vim.g.clipboard = vim.ui.clipboard.osc52` in `dot_config/nvim/lua/config/options.lua`. See [docs/tools/tmux/README.md → OSC 52 Clipboard](docs/tools/tmux/README.md).
- `allow-passthrough on` — OSC passthrough for terminal images.
- macOS terminals must send Option as Meta/Esc+ for `M-` keybindings (theme switching, layouts, fine resize). Ghostty/cmux: `macos-option-as-alt = left` in `dot_config/ghostty/config`. See [ghostty.md](docs/tools/ghostty.md).

Full breakdown / themes / keybindings / troubleshooting: [](docs/tools/tmux/).

### Zellij `default_mode "locked"`

`dot_config/zellij/config.kdl` sets `default_mode "locked"` on purpose — all keys pass through to inner apps, `Ctrl+G` unlocks Zellij's own. Do **not** change it. Fresh box → pick the "Unlock-First (non-colliding)" preset. [keyboard-shortcuts.md](docs/keyboard-shortcuts.md)
