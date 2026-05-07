# Dotfiles Repository — Agent Contract

Cross-platform dotfiles managed by **chezmoi** (configs) + **ansible** (system deps). This file is the agent-facing contract: maintenance rules, hard invariants, and pointers to docs. User-facing intro is in [README.md](README.md).

> **Headroom rule**: keep this file under ~30k chars. Push handbook content into `docs/`; keep only edit rules and cross-file invariants here.

## Cross-file maintenance rules

When you change one of these surfaces, update the listed mirror file in the same commit. These are the rules most often forgotten.

### README.md

When adding/modifying configurations, update [README.md](README.md):

- **New config files** → "What You Get > Config Files" section
- **New ansible roles/tools** → "What You Get > Tools" section
- **New platforms** → "Supported Platforms" table
- **Changed setup steps** → "Quick Setup" section

Keep README.md concise and user-focused. Technical details belong here or in `docs/`.

### `docs/` + MkDocs site → `mkdocs.yml` nav

`docs/` is published to **<https://daviddwlee84.github.io/dotfiles/>** via a MkDocs Material site (auto-deployed by [`.github/workflows/docs.yml`](.github/workflows/docs.yml) on push-to-main when `docs/**`, `mkdocs.yml`, `pyproject.toml`, or `uv.lock` changes). Source of truth remains the `.md` files in the repo; the site is a renderer.

Any time you **add a new `docs/**/*.md` file**:

1. Add a nav entry in [`mkdocs.yml`](mkdocs.yml) under the matching top-level section (Tools / Zsh / Neovim / This Repo / Infrastructure / Tutorials / Input methods / Misc). Alphabetical within a section unless there's a narrative order.
2. Cross-link from related pages if applicable (e.g., a new `docs/tools/foo.md` probably wants a mention in `docs/tools/tmux/README.md` or `docs/tools/sesh.md` if relevant).
3. Run `uv run mkdocs build --strict` locally to catch broken links / stale anchors. If you're adding *external*-relative links (to `dot_config/…`, `pitfalls/…`, `backlog/…`), the `validation.links.not_found: info` config tolerates them — that's intentional, don't tighten it without cleaning up the ~20 known anchor-drift cases tracked in [`backlog/mkdocs-anchor-drift.md`](backlog/mkdocs-anchor-drift.md) first.

The `.claude/skills/mkdocs-site-bootstrap/scripts/add-docs-page.sh` helper can create a new page + insert the nav entry in one shot, but hand-editing `mkdocs.yml` is also fine as long as strict build passes.

**What does NOT belong in `docs/`** (stays at repo root, NOT in MkDocs nav):

| Surface | Why |
|---|---|
| `README.md` | Canonical GitHub landing page; `docs/index.md` links to it (no duplication, no snippet copy) |
| `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` | Agent-operational contract; `docs/for-maintainers.md` references it |
| `TODO.md`, `backlog/`, `pitfalls/` | Dynamic maintainer surfaces; `docs/for-maintainers.md` references them via absolute GitHub URLs (reference, not copy) |
| `NOTES.md` | User's personal WIP notes |

All four categories are **referenced** from [`docs/for-maintainers.md`](docs/for-maintainers.md) via absolute GitHub URLs — do not add them to `mkdocs.yml` nav or include them via `pymdownx.snippets`. The "reference yes, copy no" rule avoids drift between the site and the live repo root.

### Custom aliases & shell functions → `docs/shells/aliases.md`

When adding/modifying/removing a custom alias or shell function in any `dot_config/zsh/`, `dot_config/bash/`, or `dot_config/shell/` file, update [`docs/shells/aliases.md`](docs/shells/aliases.md): one row per entry with command name, type (`alias` or `function`), source file (relative to repo root), shell scope (`zsh`/`bash`/`both`), and a one-line description.

**Place new helpers in the right tier:**

- `dot_config/shell/*.sh` (or `*.sh.tmpl`) — POSIX-portable env / PATH / aliases / functions usable by **both** zsh and bash. Source-time shell detection via `$ZSH_VERSION` / `$BASH_VERSION` is OK; zsh-only constructs (ZLE widgets, `read -q`, `${m:t}`, glob qualifiers, `setopt`, `compdef`) are NOT — keep them out so bash doesn't error on source.
- `dot_config/zsh/*.zsh` (or `tools/*.zsh`) — zsh-only. ZLE widgets (aisuggest, tools_picker, television, sesh-sessions), `compdef`-driven completions, anything calling `bindkey`, `zsh-vi-mode` hooks.
- `dot_config/bash/*.bash` — bash-only. `bind -x` / `ble-bind`-driven keybindings, oh-my-bash plugin / completion / alias arrays, bash-specific `shopt`s.

When porting a zsh-only helper to bash via ble.sh's `ble-bind`, prefer extracting the shell-agnostic backend (the function that produces the shell command string) into `dot_config/shell/` and keeping each shell's widget binding in its own dir.

For broader context on the conventions this repo uses (XDG vs `.d/` drop-ins vs hybrid loaders, override layers via `*.local` / `*.adhoc` / skel files, chezmoi prefixes, login vs interactive shell loading) see [`docs/this_repo/config-conventions.md`](docs/this_repo/config-conventions.md). New contributors / agents adding non-shell config files should skim that page first to know which convention applies.

### `gui_apps_linux` ansible role → `docs/playbooks/linux-gui-apps.md`

When adding/modifying/removing a Linux GUI app in [`dot_ansible/roles/gui_apps_linux/tasks/main.yml`](dot_ansible/roles/gui_apps_linux/tasks/main.yml), update the **Inventory** table in [`docs/playbooks/linux-gui-apps.md`](docs/playbooks/linux-gui-apps.md). The playbook is the single source of truth for the per-app mechanism / auto-update story, and is the first thing a maintainer (or agent) should read before adding a new app — it contains the `.deb` / Snap / Flatpak / AppImage decision tree and the concrete copy-paste patterns. Read it first; update it in the same commit.

### Dockerfile + dotfiles_init wrapper

When adding new chezmoi prompts in `.chezmoi.toml.tmpl`, three files must be updated in the same commit:

1. `Dockerfile` — add `ARG CHEZMOI_*` build argument, add `--promptBool` / `--promptString` flag to `chezmoi init`.
2. `scripts/init/dotfiles_init.py` — add a matching entry to the `PROMPTS` tuple (key, kind, group, label, desc, default).
3. (If the prompt should be part of any named bundle) `BUNDLES` dict in the same file.

Verify parity with: `uv run --script scripts/init/dotfiles_init.py doctor`. The subcommand greps `.chezmoi.toml.tmpl` + `Dockerfile` and compares against the embedded `PROMPTS`; non-zero exit means drift.

### Agent artifact redaction

SpecStory transcripts and coding-agent plan files commonly paste shell output, config snippets, or `.env` values that may contain secrets. Four directories are auto-scanned/redacted:

| Prefix | Source |
|--------|--------|
| `.specstory/history/` | SpecStory chat transcripts |
| `.claude/plans/` | Claude Code plan files |
| `.cursor/plans/` | Cursor plan files |
| `.opencode/plans/` | OpenCode plan files |

Tooling: `scripts/redact_secrets.py` (gitleaks + `PRIVATE KEY` pattern), `just check-secrets` / `just redact-secrets` / `just add-and-redact`. Pre-commit hook `redact-agent-secrets` runs `--fix` before `gitleaks-system`; if it rewrites a file, stage and retry.

When introducing a new coding-agent artifact directory that could contain secrets, add its prefix to `DEFAULT_PATHS` in `scripts/redact_secrets.py` **and** the `files:` regex of the `redact-agent-secrets` pre-commit hook.

### Keyboard shortcuts (cross-tool conflict check)

When adding/modifying keybindings in any tool config, cross-check against other tools — multiple tools share the terminal's key namespace, especially `Ctrl+` and `Alt+`.

| Tool | Config file | Conflict risk |
|------|-------------|---------------|
| tmux (root-table) | `dot_config/tmux/keybindings.conf` | `C-h/j/k/l` (vim-tmux-navigator), `C-1..9` (window switch); `prefix + a` (live agent panes picker — `tv agent-panes`, see [docs/tools/agent-panes-discovery.md](docs/tools/agent-panes-discovery.md)) |
| Television (global) | `dot_config/television/config.toml` | `Ctrl+S/F/R/Y/T/X/O` (built-in actions) |
| Television (channels) | `dot_config/television/cable/*.toml` | Per-channel `[keybindings]` overrides global |
| Zellij | `dot_config/zellij/config.kdl` | Mitigated by `default_mode "locked"` |
| Ghostty | `dot_config/ghostty/config` | `macos-option-as-alt` affects `Alt+` availability |
| zsh ZLE widgets | `dot_config/zsh/tools/{11_tools_picker,12_television,22_sesh,05_aisuggest}.zsh` | `Alt+T/R/P/G/E/A/I/S` (pickers), `Alt+;` (aisuggest, configurable via `AISUGGEST_KEY`); rebound from `zvm_after_init` in `dot_zshrc.tmpl` to survive zsh-vi-mode's keybind wipe |
| bash + ble.sh | `dot_config/bash/04_blesh.bash` + `~/.bashrc.adhoc` | ble.sh provides zsh-style autosuggest / syntax-highlight / vi-mode but NO ZLE-widget ports yet — aisuggest / tools_picker / television / sesh widgets are zsh-only on bash. CLI fallbacks work (`tv <channel>`, `sesh-connect`, `aisuggest "<text>"`). Custom `ble-bind` calls go in `~/.bashrc.adhoc` (sourced AFTER `ble-attach`). atuin's `--disable-up-arrow` is mandatory because ble.sh owns up-arrow for history navigation |
| Claude Code (TUI) | `dot_claude/modify_keybindings.json` (overlay) + `~/.claude/keybindings.json` (live); see [docs/tools/claude-code-keybindings.md](docs/tools/claude-code-keybindings.md) | `Ctrl+R` (history:search — collides with atuin / zsh-history-substring at the prompt outside Claude), `Ctrl+T` (toggleTodos — Television's `Ctrl+T` is shadowed when Claude has focus), `Ctrl+G` (chat:externalEditor), `Ctrl+S` (chat:stash), `Shift+Tab` (chat:cycleMode — only known mode-switch action, no jump-to-plan) |

Known conflict zones: `Ctrl+H/J/K/L` (tmux vim-tmux-navigator; removed in TV global), `Ctrl+S/F/R` (TV built-in cycling/reload — avoid in channel actions), `Alt+*` (safe namespace for channel-specific actions; requires terminal to send Option as Meta). Free Alt slots in this repo: `Alt+/`, `Alt+\`, and most letters not listed above (B/D/F/H/J/K/L/M/N/O/Q/U/V/W/X/Y/Z) — but check `dot_config/zsh/tools/*.zsh` first before claiming a new one.

**Resolution precedence**: tmux root-table bindings intercept keys before they reach the inner application. Inside tmux, any `bind-key -n C-*` shadows the same `ctrl-*` in TV. Prefer `Alt+` for custom actions.

### Long-term backlog + past pitfalls → use the `project-knowledge-harness` skill

This repo uses the `project-knowledge-harness` agent skill (managed via
`~/.agents/.skill-lock.json` → restored by
`.chezmoiscripts/global/run_onchange_after_40_install_global_skills.sh.tmpl` on every `chezmoi apply`;
see [docs/tools/agent-skills.md](docs/tools/agent-skills.md)). **Load the skill**
for the full template, disambiguation table, and upgrade path.

**Fallback (if the skill cannot be loaded)** — minimum viable rules so this
section still constrains agents who can't see the skill:

- Three repo-root surfaces, all `chezmoi`-ignored, all NOT auto-redacted:
  [`TODO.md`](TODO.md) (priority/effort tags `P1`/`P2`/`P3`/`P?` × `S`/`M`/`L`/`XL`),
  [`backlog/`](backlog/README.md) (research/design notes; needed for `P?` /
  `[L]` / `[XL]` / multi-option entries), [`pitfalls/`](pitfalls/README.md)
  (debugged traps, **titled by symptom not root cause**, verbatim error
  messages — never paraphrase).
- Triggers to capture future work: "maybe later", "nice to have", "if I'm
  interested", "工程量太大需要再評估", "先記下來".
- Triggers to capture pitfalls: >~15 min debugging, not googleable,
  non-obvious fix, silent failure mode.
- Do **not** spawn `ROADMAP.md` / `IDEAS.md` / `LESSONS.md` /
  `TROUBLESHOOTING.md` — three surfaces, always.
- A pitfall *graduates* to a Hard invariant in this file when it (a) recurs
  across machines, (b) silently corrupts state, or (c) has a non-obvious
  workaround. Link from the new invariant back to `pitfalls/<slug>.md`.

### fleet-apply (`scripts/fleet_apply.py` + `dot_config/fleet/`)

Touching any of these surfaces requires updating [`docs/this_repo/fleet-apply.md`](docs/this_repo/fleet-apply.md) in the same commit:

- `scripts/fleet_apply.py` — CLI flags, mode semantics, sudo helper integration, log/sentinel paths
- `justfile` `fleet-*` recipes — name, args, doc-comment
- `dot_config/fleet/create_private_machines.toml.tmpl` — schema (`local`, `chezmoi_path`, `no_root_machine`, `password.source`, etc.)
- Any change to `scripts/lib/sudo_shared.sh` that affects how `CHEZMOI_SUDO_PASSWORD_FILE` is consumed (also see "Sudo session" invariant below)

`README.md` only needs an update if the user-facing `## Multi-host apply` block changes (top-level recipe names, exit-code semantics).

## Chezmoi templating conventions

**Hard rule**: before adding a `{{ if eq .profile ... }}` branch, ask if the predicate is auto-detectable. If yes, use `.chezmoi.os` / `.chezmoi.arch` / `.chezmoi.hostname` instead. `.profile` exists only for user-role choices chezmoi cannot infer (server vs desktop).

| Predicate | Use |
|---|---|
| Any macOS (Apple Silicon or Intel) | `eq .chezmoi.os "darwin"` |
| Any Linux | `eq .chezmoi.os "linux"` |
| Apple Silicon only | `eq .chezmoi.arch "arm64"` (inside darwin-scoped files) or `and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "arm64")` |
| Intel Mac only | `and (eq .chezmoi.os "darwin") (eq .chezmoi.arch "amd64")` |
| Desktop vs headless (user role) | `.profile` — `ubuntu_desktop` / `ubuntu_server`; macOS side covered by `eq .chezmoi.os "darwin"` |

Profile values are intentionally limited to `macos`, `ubuntu_desktop`, `ubuntu_server`. **Do not** introduce new profile values for OS/arch facts (the historical `macos_intel` profile was removed for exactly this reason).

Full decision table, before/after examples, and the `macos_intel` migration snippet: [docs/tools/chezmoi-templating.md](docs/tools/chezmoi-templating.md).

## Hard repo invariants

### `primaryShell` choice gates `chsh` only — both shells always deploy

The `primaryShell` chezmoi prompt (`zsh` | `bash`, default `zsh`, see [`.chezmoi.toml.tmpl`](.chezmoi.toml.tmpl)) **only governs which shell `chsh` switches to as the login shell**. Both `~/.zshrc` and `~/.bashrc` (plus `~/.config/zsh/`, `~/.config/bash/`, `~/.config/shell/`) deploy on every host regardless of choice. This is intentional: users routinely drop into the other shell ad-hoc (`bash` for a quirky script, `zsh` for `.zshrc` debugging on a bash-primary box), and having both work is cheap.

**Hard rules**:

- Do **not** add `{{ if eq .primaryShell "zsh" }}` / `{{ if eq .primaryShell "bash" }}` gates around `dot_zshrc.tmpl`, `dot_bashrc.tmpl`, or any `dot_config/{shell,zsh,bash}/**` file. The other shell needs to keep working.
- Do **not** gate the zsh / bash ansible roles' **package install** task on `primary_shell`. Both shells' packages install everywhere; only the **chsh** task is gated. Reason: even on bash-primary mac, `zsh` ad-hoc must work — and vice versa.
- Do **not** rely on `$SHELL` to detect the running shell — it reflects the login shell from `/etc/passwd`, which can disagree with the actual interactive shell after `chsh` until next login. Use `$ZSH_VERSION` / `$BASH_VERSION` instead (source-time detection in shared `dot_config/shell/*.sh.tmpl` files).
- macOS bash 5.x install (via the `bash` ansible role's `community.general.homebrew: name=bash`) and `/etc/shells` whitelist are gated on `primary_shell == "bash"` — zsh-primary mac users get zero extra brew formula. The same gate covers the `chsh` to brew bash.

**Three-tier file placement** when adding a shell helper (see "Custom aliases & shell functions" rule above for the cross-file update obligation):

| Tier | Dir | When |
|---|---|---|
| Shared | `dot_config/shell/` | POSIX subset; both shells source. Use `$ZSH_VERSION` / `$BASH_VERSION` for source-time dispatch when needed. |
| Zsh-only | `dot_config/zsh/` | ZLE widgets, `compdef`, `bindkey`, `setopt`, `read -q`, `${m:t}`, glob qualifiers. |
| Bash-only | `dot_config/bash/` | `bind -x` / `ble-bind`, OMB plugin arrays, bash-specific `shopt`s. |

ble.sh + oh-my-bash on bash side: see [docs/shells/bash.md](docs/shells/bash.md) for the load-bearing 12-step init order in `dot_bashrc.tmpl`. Key invariants — `ble.sh --attach=none` MUST source before bash-preexec/starship; `ble-attach` MUST be the last call before secrets/adhoc; OMB's `autosuggestions` / `syntax-highlighting` / `history-substring-search` plugins MUST be excluded (ble.sh provides better natives, double-init causes flicker).

### Install vs upgrade is split on purpose

`chezmoi apply` (+ ansible phase) is deliberately **install-only**: roles use `state: present` / `creates:` so re-applying never silently bumps every tool. The explicit upgrade path lives in [`scripts/upgrade_tools.sh`](scripts/upgrade_tools.sh), exposed via `just upgrade-*` recipes.

- **Do not** rewrite ansible roles to `state: latest`.
- **Do not** add `apt upgrade` / system package bumps to default scope.
- `scripts/**` is in `.chezmoiignore.tmpl`, so `upgrade_tools.sh` is never deployed; it runs from the repo directly.
- Adding a new upgrade category: see [docs/this_repo/upgrades.md](docs/this_repo/upgrades.md) → "Adding a new category". For a tool already managed by an existing package manager (brew/uv/npm/cargo/dotnet/gem/mise) you do nothing — generic `upgrade` picks it up.

Full per-category matrix, sample output, and troubleshooting: [docs/this_repo/upgrades.md](docs/this_repo/upgrades.md). The short version is also mirrored in `README.md`.

### Sudo session is shared across all run-scripts

All three `run_*` scripts share one sudo session via `scripts/lib/sudo_shared.sh`. The user is prompted **once** at the start of `chezmoi apply` and downstream scripts reuse the cached credential silently.

**Hard rules** when touching run-scripts:

- Do **not** re-implement `sudo -k` / `sudo -v` / TTY-read logic. Call the shared helper.
- Do **not** run `sudo -k` (invalidates the shared cache for the whole flow).
- Do **not** register a `trap … EXIT` that removes state (next run-script needs it).
- Do **not** read the password into a shell variable. Always pipe via `sudo -S <file`.
- Do **not** replace `_sudo_spawn_watchdog`'s `setsid`/`nohup` fallback with bare `setsid`. macOS has `setsid(2)` as a libc call but no `setsid(1)` CLI in base, and the backgrounded failure is silent (redirected to `/dev/null`) — every run-script then re-prompts because `_sudo_state_valid`'s `kill -0` probe finds a dead PID. See [`pitfalls/sudo-shared-setsid-macos.md`](pitfalls/sudo-shared-setsid-macos.md).

Adding a new sudo surface in a run-script:

1. `{{ include "scripts/lib/sudo_shared.sh" }}` near the top of the template.
2. Set the `NEED_SUDO` template flag (mirror existing run-scripts).
3. Call `sudo_session_init "yourlabel"`; branch on return code + `sudo_session_skip_reason`.
4. Run privileged commands via `sudo_run …` (simple cases) or pass `-e @$CHEZMOI_ANSIBLE_BECOME_FILE` to ansible.

Full helper API, runtime state, cleanup model: [docs/this_repo/sudo-session.md](docs/this_repo/sudo-session.md).

**Non-interactive password injection** (used by `scripts/fleet_apply.py` over
SSH): `sudo_session_init` adopts `CHEZMOI_SUDO_PASSWORD_FILE` (a 0600 file
path) instead of prompting on `/dev/tty`. The helper validates with `sudo -S
-v -p ''` and writes into the same shared state dir, so downstream
run-scripts see the cached state and never re-prompt. Do **not** read
`CHEZMOI_SUDO_PASSWORD_FILE` from your run-script directly — always go
through `sudo_session_init`. See [docs/this_repo/sudo-session.md](docs/this_repo/sudo-session.md)
→ "Non-interactive password injection" and [docs/this_repo/fleet-apply.md](docs/this_repo/fleet-apply.md)
for the orchestrator side.

### fleet-apply semantics (counter-intuitive defaults)

A few `just fleet-apply*` behaviours WILL trip up agents who don't know them. Full docs in [`docs/this_repo/fleet-apply.md`](docs/this_repo/fleet-apply.md); the load-bearing invariants:

- **`drift` ≠ `failed`**. When chezmoi can't prompt to overwrite a hand-edited file (no PTY over SSH), the host is shown as yellow ⚠ `drift` in the live table and the per-file paths are listed, but it does **not** count toward the exit code. Don't "fix" drift hosts unless the user asks. Resolution: hand-fix the remote, or `--force` to let the template win.
- **`fleet-apply-file PATH` skips `run_*` scripts**. Uses `chezmoi apply --exclude=scripts <PATH>` after an explicit `git pull`. Means ansible / Brewfile changes will NOT execute. If you edit `dot_ansible/...` and test with `fleet-apply-file`, the change won't apply — use full `fleet-apply` for ansible iterations. Same applies to Brewfile.
- **`--branch BRANCH` is no-op on local hosts**. The local source dir IS the user's editor working tree; switching it would be hostile. Local hosts log a warning and run against the working tree as-is. The flag also forces mode to `apply` (since `chezmoi update` would re-pull main and undo the checkout).
- **Install-only by design**. fleet-apply inherits the [Install vs upgrade is split](#install-vs-upgrade-is-split-on-purpose) invariant: it never silently bumps tools. The explicit upgrade path is `just upgrade-*` which must be run on each host (fleet-apply does NOT broadcast upgrades).
- **Process substitution + sentinel are load-bearing**. `> >(tee -a $log) 2>&1 & _cz_pid=$!; wait $_cz_pid; _rc=$?; echo $_rc > $sentinel` is the contract that `--status` / `--tail` / `--watch` rely on. Don't change to a pipeline (`| tee`) — the wrapper's SIGHUP trap depends on `$_cz_pid` pointing to chezmoi, not tee. See [docs/this_repo/fleet-apply.md → Killing orphans, checking status, re-attaching](docs/this_repo/fleet-apply.md#killing-orphans-checking-status-re-attaching).
- **Conservative drift classifier**. `_classify_drift()` only downgrades stderr lines matching the exact `chezmoi: <path>: could not open a new TTY: open /dev/tty:` fingerprint. Any unrecognised stderr line keeps `failed` state. Don't broaden the regex without explicit user request — silent downgrades hide real errors.

### `modify_` and `create_` prefix semantics

Two chezmoi source prefixes tame files that would otherwise churn on every apply:

- **`modify_`** files are executable scripts: chezmoi pipes current target contents into stdin, expects new contents on stdout. Used for `~/.claude/settings.json` (jq overlay), the editor `settings.json` files (VSCode/Cursor/Antigravity), and the coding-agent CLI configs (`~/.cursor/cli-config.json`, `~/.config/opencode/opencode.json`, `~/.codex/config.toml`). Do **not** `chezmoi add` a `modify_` target — it would overwrite your script with the live file.
- **`create_`** files seed once, then chezmoi never touches the contents. Used for `~/.config/nvim/lazy-lock.json` and editor `keybindings.json`. To refresh a `create_` baseline, copy the live file directly into the source path: `cp <target> "$(chezmoi source-path <target>)"`. Neither `chezmoi add` (strips the prefix) nor `chezmoi re-add` (silently skips) is correct.

Full case studies (`dot_claude/modify_settings.json`, `.chezmoitemplates/editor/*`, `dot_config/nvim/create_lazy-lock.json`, `dot_codex/modify_config.toml`), failure modes, presence-gating in `.chezmoiignore.tmpl`: [docs/tools/chezmoi-prefixes.md → Case studies in this repo](docs/tools/chezmoi-prefixes.md#case-studies-in-this-repo). For the three coding-agent CLI overlays specifically, the deep-dive lives at [docs/tools/agent-overlays.md](docs/tools/agent-overlays.md) (overlay key rationale, what's intentionally NOT managed and why, OpenCode legacy `config.json` migration, Codex `[projects]`/`[marketplaces.*]` round-trip, **and the Claude hook-aware merger that lets our overlay coexist with [CodeIsland](https://github.com/wxtsky/CodeIsland)'s auto-installed hook entries on macOS** without ping-ponging on every apply).

### Tmux ≥ 3.3 required for popup menu, and menu must fit terminal height

The popup menu is bound to **both** `prefix + Space` and `prefix + e` (alias) and is **generated by `~/.config/tmux/menu.sh`**, not defined inline in `keybindings.conf`. Two unrelated tmux quirks force this:

1. **Position clamping (tmux ≥ 3.3 required)**: `display-menu -x R -y P` places the menu past the terminal edge on tmux 3.2a (Ubuntu 22.04 apt) and silently suppresses it. tmux 3.3+ clamps the position. The Ansible `devtools` role detects old tmux on Debian/Ubuntu and upgrades automatically (Linuxbrew when present, otherwise user-level [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage) extracted to `~/.local/share/tmux-appimage/` with a shim at `~/.local/bin/tmux`). After the upgrade, run `tmux kill-server` once — running servers keep the old binary in memory.
2. **Menu-too-tall silent failure (all tmux versions)**: `display-menu` does **not** paginate. If the menu is taller than the terminal (after status bar + `-y` anchor offset), the entire popup is suppressed with no error, no log entry, nothing in `tmux show-messages`. `man tmux`: _"If the menu is too large to fit on the terminal, it is not displayed."_ This was misdiagnosed for hours as a `csi-u` / `extended-keys` keysym encoding bug after a 50-row flat menu started failing on smaller terminal heights — the keys (`Space` then `Enter` then `e`) were all bound correctly the whole time.

Hard rules when touching the popup menu:

- **Top menu cap is ~14 rows.** Adding a 15th row will start failing on smaller heights (mobile SSH, half-screen splits). Push lower-frequency items into the appropriate submenu in `~/.config/tmux/menu-<category>.sh` instead.
- **Submenus are separate scripts**, each `exec tmux display-menu …`. Quoting context resets per script — keeps the inline `\"` / `{` / `}` / `;` quoting disasters out of `keybindings.conf`.
- **Complex commands** (anything with `{`, `}`, `;`, backticks, or nested fzf binds) must live in their own script (`~/.config/tmux/sesh-picker.sh`, `sesh-windows.sh`, etc.), not inline in a menu row. tmux's parser treats `{` `}` `;` as command-block delimiters / separators even inside `'…'` inside `"…"`, silently aborting parse.
- **Test by shrinking the terminal vertically.** Verifying on a full-height window does not catch the height-fit failure. The top menu generator reads `#{client_height}` and tier-trims; if you change the tiers, retest at heights 14 / 22 / 60.

See `pitfalls/tmux-display-menu-silent-fail.md` for the full debugging story (red herrings included). Adjacent pitfall: `pitfalls/yazi-tmux-popup-crash.md`.

### Key tmux settings for coding agents

These are non-obvious settings that other tools depend on; do not remove without checking:

- `extended-keys on` + `terminal-features 'xterm*:extkeys'` — forwards Shift+Enter, Ctrl+Enter, Ctrl+/, Ctrl+digit through tmux to inner apps (Claude Code, Neovim, etc.). **Do NOT use `always`** — that re-encodes EVERY `Ctrl+letter` as CSI-u including the LF/`\n` (Ctrl+J) embedded in pasted multi-line text, which ble.sh then inserts as literal `^[[106;5u` instead of as a newline. See `pitfalls/tmux-extended-keys-always-paste.md`.
- `escape-time 0` — eliminates ESC delay for Neovim
- `set-clipboard on` + `terminal-features …:clipboard` (for `xterm*`, `ghostty*`, `alacritty*`) — OSC 52 over SSH without terminfo `Ms`. Paired with SSH-conditional `vim.g.clipboard = vim.ui.clipboard.osc52` in `dot_config/nvim/lua/config/options.lua`. See [docs/tools/tmux/README.md](docs/tools/tmux/README.md) → "OSC 52 Clipboard".
- `allow-passthrough on` — OSC passthrough for terminal images
- macOS terminals must send Option as Meta/Esc+ for `M-` keybindings (theme switching, layouts, fine resize). Ghostty/cmux: `macos-option-as-alt = left` (managed in `dot_config/ghostty/config`). See [docs/tools/ghostty.md](docs/tools/ghostty.md).

Full tmux config breakdown, theme switching, keybindings table, troubleshooting: [docs/tools/tmux/](docs/tools/tmux/).

### Zellij `default_mode "locked"`

`dot_config/zellij/config.kdl` uses `default_mode "locked"` so all keys pass through to inner applications by default. Press `Ctrl+G` to unlock Zellij commands. This prevents key conflicts with coding agents and vim-style applications. On first Zellij launch (without existing config), select the "Unlock-First (non-colliding)" keybinding preset.
