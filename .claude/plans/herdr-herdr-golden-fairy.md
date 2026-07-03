# Plan: `hvibe` / `hcode` — herdr equivalents of `svibe` / `scode` (+ which-key & usage findings)

## Context

Today the repo has rich **tmux** helpers for spinning up a whole coding session in one motion — `svibe` (N agent panes + lazygit + nvim) and `scode` (nvim ‖ one agent + btop), both in `dot_config/shell/22_sesh.sh`. herdr (the trial tmux-alternative) has **no shell helper at all**: to start work you `cd` into a project, manually `herdr workspace create`, then open each agent CLI / lazygit / nvim by hand. The user wants the same "open the whole pack" one-liner under herdr.

Research (herdr v0.7.1, installed) confirmed this is fully buildable on herdr's native CLI, and that svibe's *pure* logic (specstory-wrap, on-exit-wrap, git-root, agent-CLI detection, auto-N width math) is reusable verbatim — only the `tmux …` calls get swapped for `herdr …` calls. Two side questions were also answered:

- **which-key**: herdr already ships it — `prefix+?` opens a dynamic "all active bindings" overlay (`help` action). Nothing to build; document it.
- **CodexBar-style usage**: herdr has **no** native usage display; a plugin (`jerryfane/herdr-codex-usage-kit`) covers **Codex-only**. Per user decision we will **not install** it now and instead **backlog** a DIY driver (using herdr's `pane report-metadata --custom-status` hook) that could show Claude+Codex parity later.

**User decisions:** build **both** `hvibe` and `hcode`; default layout = **one `agents` tab + side-by-side splits** (svibe parity) with a `--tab-per-agent` opt-in; **backlog** the usage driver. User flagged one thing to verify: *with multiple agents in a single tab, does herdr's bottom-left agent panel show one entry or several?* — if it collapses to one, that's the argument for `--tab-per-agent`.

## What to build

### 1. New shell backend: `dot_config/shell/24_herdr.sh` (shared tier)

Plain functions + aliases only (no ZLE/compdef/bindkey/setopt) → belongs in the **shared** `dot_config/shell/` tier, both shells source it. Loads after `22_sesh.sh` (numeric prefix), so the reused `_sesh_*` helpers exist. Header comment documents the cross-file dependency.

**Reused verbatim from `22_sesh.sh` (all pure, tmux-free):**
- `_sesh_git_root` (57–59), `_sesh_sanitize` (63–65)
- `_sesh_wrap_agent "$agent" "$mode"` (101–124) — specstory wrapping (`claude|codex|cursor|droid|gemini` → `specstory run X`; `opencode`/unknown → raw)
- `_sesh_on_exit_wrap "$inner" "$mode" "$label"` (139–164) — `shell|kill|restart` post-exit behavior; emits a plain shell string, multiplexer-agnostic
- agent-CLI detection idiom (`command -v "$a"`) and the advisory provider list

Only the tmux-specific pieces are replaced: `_sesh_attach_or_switch` / `_sesh_ensure_session` and inline `tmux new-session/split-window/select-layout/new-window` → herdr CLI calls.

**Guard:** both functions start with `command -v herdr >/dev/null 2>&1 || { echo "…: herdr not installed" >&2; return 1; }` so they degrade cleanly on hosts without herdr (it's a trial tool, not everywhere).

#### `herdr-vibe` / `hvibe` — multi-agent pack

Mirror svibe's arg parsing: `-p|--path`, `--on-exit shell|kill|restart`, `--agents CSV` (heterogeneous; list length = pane count), positional `[N] [CLI]` (homogeneous), `--min-width` + auto-N width math (`N = clamp(term_width/min_width, 1, 12)` when N omitted), `--no-specstory`/`--specstory`, `--no-attach` (→ herdr `--no-focus`), `-h|--help`. **New flag:** `--tab-per-agent` (splits mode is default).

Layout build (splits mode, herdr Workspace→Tab→Pane):
1. **Idempotency**: `herdr workspace list` → if a workspace already has label `vibe/<repo>`, `herdr workspace focus <id>` and return (mirrors svibe's "attach if exists"). JSON path already used in-repo: `.result.workspaces[].label` / `.workspace_id` (see `dot_config/television/cable/herdr-sesh.toml:22`).
2. `ws=$(herdr workspace create --cwd "$repo_root" --label "vibe/$repo" --no-focus | jq -r '<id path>')`.
3. First agent runs in the workspace's initial pane (rename its tab to `agents`); each remaining agent → `herdr agent start <name> --workspace "$ws" --tab "$agents_tab" --split right -- bash -lc '<wrapped cmd>'`, where `<wrapped cmd>` = `_sesh_on_exit_wrap "$(_sesh_wrap_agent …)" …`. `agent start <name>` registers the agent natively (sidebar state) while `bash -lc` preserves the specstory + on-exit wrapper. Stagger launches with `HVIBE_LAUNCH_STAGGER` (default 0.25s — same opencode-WAL rationale as svibe).
4. `git` tab: `herdr tab create --workspace "$ws" --cwd "$repo_root" --label git` → capture its pane id → `herdr pane run <pane> '<lazygit on-exit-wrapped>'` (fallback `git status; exec $SHELL` if lazygit absent, as svibe does).
5. `edit` tab: same with `nvim`.
6. Focus `agents` tab unless `--no-attach`.

`--tab-per-agent` variant: skip step 3's splits; instead one `herdr tab create --label <agent>` per agent (each its own sidebar state dot), git + edit tabs as above.

#### `herdr-code` / `hcode` — single-agent layout

Mirror scode (263–384): workspace `coding-agent/<repo>`, one `editor` tab = nvim (left ~75%) ‖ wrapped agent (right ~25%) via `herdr pane split --direction right --ratio …` then `herdr pane resize`, plus a `monitor` tab running `btop`→`htop`→`top` fallback. Flags: `-a|--agent`/positional, `--on-exit`, `--no-specstory`, `--no-attach`, `-h`. Same git-repo gate, same idempotent label check, same reused helpers.

**Git gate:** mirror svibe/scode exactly — resolve `_sesh_git_root`; if not a repo, refuse with the same hint. (Relaxing to a `$PWD` fallback is a one-line change if wanted later.)

**Aliases** (in `24_herdr.sh`): `alias hvibe='herdr-vibe'`, `alias hcode='herdr-code'`.

**No tab-completions** — like svibe/scode (which ship none); the CLAUDE.md completion rule fires only for `bin/executable_*` CLIs, not shell functions.

### 2. Backlog: DIY herdr usage-status driver

New `backlog/herdr-usage-status-driver.md` (project-knowledge-harness convention) + one-line `TODO.md` index row (`[?/M]`). Capture: herdr has no native usage bar; the hook is `herdr pane report-metadata <pane> --source ID --custom-status "…" --ttl-ms N` (renders text next to an agent in the sidebar). Reference implementations: `jerryfane/herdr-codex-usage-kit` (Codex, reads `~/.codex/sessions` rate_limits — same local data as CodexBar's Codex provider, no API) and `Davidcreador/herdr-token-dashboard`. Note the gap: no plugin covers Claude/ChatGPT quota; a background timer script could push `"Claude 62% • Codex 78%5h"` for parity, optionally sourcing CodexBar's own cached data. Also note CodexBar (`steipete/CodexBar`, brew cask `codexbar`) stays the macOS menu-bar multi-provider view meanwhile.

### 3. Docs: `docs/tools/herdr.md`

- **Keybindings table**: add `prefix + ?` → "keybinds help overlay — lists every active binding (herdr's native which-key equivalent; manually invoked, not an auto-timeout hint)". Confirm `create_config.toml` doesn't rebind `?`.
- **New "Session helpers (`hvibe` / `hcode`)" section**: document both, note they're the herdr analogs of `svibe`/`scode`, reuse the same specstory/on-exit/git-root logic, and the `--tab-per-agent` toggle + why it exists (sidebar agent-panel behavior).
- **Agent-state / usage note**: one line that herdr has no native usage display and pointer to `backlog/herdr-usage-status-driver.md`.
- Editing an existing nav'd doc → **no `mkdocs.yml` change**; still run `mkdocs build --strict`.

### Cross-file mirrors (per CLAUDE.md)
- `docs/shells/aliases.md`: add two rows after the sesh block (467–468) for `herdr-vibe`/`hvibe` and `herdr-code`/`hcode` (name, type, source `dot_config/shell/24_herdr.sh`, one-line).
- No `tool-managers.md`/ansible change (nothing installed). No keybindings.md change (no new Ctrl/Alt binding). SKILL.md.tmpl: optional — only if svibe/scode are already surfaced there; keep lean.

## Files to create / modify
- **Create** `dot_config/shell/24_herdr.sh` (functions + aliases)
- **Create** `backlog/herdr-usage-status-driver.md`; add row to `TODO.md`
- **Edit** `docs/tools/herdr.md` (which-key row + helpers section + usage note)
- **Edit** `docs/shells/aliases.md` (two rows)

## Verification (herdr is installed — run live at implementation)
1. **Syntax**: `bash -n` and `zsh -n` on `24_herdr.sh`; source in both shells, confirm `hvibe`/`hcode` defined, aliases resolve.
2. **hvibe end-to-end** in a scratch git repo: `hvibe 2 --no-attach`, then `herdr workspace list --json` + `herdr pane list --json` to confirm a `vibe/<repo>` workspace with an `agents` tab (2 panes) + `git` + `edit` tabs. **Then answer the user's open question**: inspect the bottom-left agent panel / `herdr agent list --json` to see whether 2 same-tab agents show as **one entry or several** — record the finding in `docs/tools/herdr.md` and decide whether `--tab-per-agent` should be the recommended default. Clean up with `herdr workspace close <id>`.
3. **Confirm CLI return shapes** actually used: exact jq key from `workspace create` (`.result.workspace.workspace_id` vs `.result.workspaces[]`), and that `agent start` / `tab create` / `pane run` accept the targeting used. Adjust extraction if reality differs.
4. **hcode**: `hcode --no-attach` in a repo → verify `coding-agent/<repo>` workspace, `editor` tab (nvim ‖ agent, ~75/25), `monitor` tab; clean up.
5. **specstory + on-exit**: confirm an agent pane runs `specstory run claude` and that quitting it drops to a shell with the re-run hint (default `--on-exit shell`), not a dead/closed pane.
6. **which-key**: in a herdr session press `prefix+?`, confirm the overlay lists bindings and isn't shadowed by `create_config.toml`.
7. **Docs**: `uv run mkdocs build --strict` passes; run pre-commit hooks touching the changed files.
