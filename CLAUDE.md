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

### Custom aliases & shell functions → `docs/zsh/aliases.md`

When adding/modifying/removing a custom alias or shell function in any `dot_config/zsh/` file, update [`docs/zsh/aliases.md`](docs/zsh/aliases.md): one row per entry with command name, type (`alias` or `function`), source file (relative to repo root), and a one-line description.

### Dockerfile

When adding new chezmoi prompts in `.chezmoi.toml.tmpl`, also update `Dockerfile`:

1. Add corresponding `ARG CHEZMOI_*` build argument.
2. Add `--promptBool` or `--promptString` flag to the `chezmoi init` command.

This keeps Docker testing in sync with all configuration options.

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
| tmux (root-table) | `dot_config/tmux/keybindings.conf` | `C-h/j/k/l` (vim-tmux-navigator), `C-1..9` (window switch) |
| Television (global) | `dot_config/television/config.toml` | `Ctrl+S/F/R/Y/T/X/O` (built-in actions) |
| Television (channels) | `dot_config/television/cable/*.toml` | Per-channel `[keybindings]` overrides global |
| Zellij | `dot_config/zellij/config.kdl` | Mitigated by `default_mode "locked"` |
| Ghostty | `dot_config/ghostty/config` | `macos-option-as-alt` affects `Alt+` availability |

Known conflict zones: `Ctrl+H/J/K/L` (tmux vim-tmux-navigator; removed in TV global), `Ctrl+S/F/R` (TV built-in cycling/reload — avoid in channel actions), `Alt+*` (safe namespace for channel-specific actions; requires terminal to send Option as Meta).

**Resolution precedence**: tmux root-table bindings intercept keys before they reach the inner application. Inside tmux, any `bind-key -n C-*` shadows the same `ctrl-*` in TV. Prefer `Alt+` for custom actions.

### Long-term backlog + past pitfalls → use the `project-knowledge-harness` skill

This repo uses the `project-knowledge-harness` agent skill (managed via
`~/.agents/.skill-lock.json` → restored by
`run_onchange_after_40_install_global_skills.sh.tmpl` on every `chezmoi apply`;
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

### Tmux ≥ 3.3 required for popup menu

The `prefix + Enter` popup uses `display-menu -x R -y P`; tmux 3.2a places the menu past the terminal edge and silently suppresses it, while 3.3+ clamps the position. (`prefix + Space` was the historical key, moved to `Enter` due to a tmux 3.6a + `extended-keys=always` + `csi-u` flake — see [docs/tools/tmux/keybindings.md → Popup Menu](docs/tools/tmux/keybindings.md#popup-menu-prefix--enter); upstream tmux/tmux#4959, #4984.) The Ansible `devtools` role detects old tmux on Debian/Ubuntu and upgrades automatically (Linuxbrew when present, otherwise user-level [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage) extracted to `~/.local/share/tmux-appimage/` with a shim at `~/.local/bin/tmux`). After the upgrade, run `tmux kill-server` once — running servers keep the old binary in memory.

### Key tmux settings for coding agents

These are non-obvious settings that other tools depend on; do not remove without checking:

- `extended-keys always` + `terminal-features 'xterm*:extkeys'` — forwards Shift+Enter, Ctrl+Enter through tmux to inner apps (Claude Code, Neovim, etc.)
- `escape-time 0` — eliminates ESC delay for Neovim
- `set-clipboard on` + `terminal-features …:clipboard` (for `xterm*`, `ghostty*`, `alacritty*`) — OSC 52 over SSH without terminfo `Ms`. Paired with SSH-conditional `vim.g.clipboard = vim.ui.clipboard.osc52` in `dot_config/nvim/lua/config/options.lua`. See [docs/tools/tmux/README.md](docs/tools/tmux/README.md) → "OSC 52 Clipboard".
- `allow-passthrough on` — OSC passthrough for terminal images
- macOS terminals must send Option as Meta/Esc+ for `M-` keybindings (theme switching, layouts, fine resize). Ghostty/cmux: `macos-option-as-alt = left` (managed in `dot_config/ghostty/config`). See [docs/tools/ghostty.md](docs/tools/ghostty.md).

Full tmux config breakdown, theme switching, keybindings table, troubleshooting: [docs/tools/tmux/](docs/tools/tmux/).

### Zellij `default_mode "locked"`

`dot_config/zellij/config.kdl` uses `default_mode "locked"` so all keys pass through to inner applications by default. Press `Ctrl+G` to unlock Zellij commands. This prevents key conflicts with coding agents and vim-style applications. On first Zellij launch (without existing config), select the "Unlock-First (non-colliding)" keybinding preset.
