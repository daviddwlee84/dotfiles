# Herdr — Rust terminal multiplexer + AI-agent orchestrator (trial)

[ogulcancelik/herdr](https://github.com/ogulcancelik/herdr) is a Rust terminal multiplexer with **built-in coding-agent awareness** (it tracks per-pane agent state: idle / working / blocked / done). It sits in the same niche as tmux/zellij but is mouse-first and agent-native. Docs: <https://herdr.dev/docs/>.

This repo ships herdr as a **trial tool that coexists with tmux** — you run `herdr` *or* `tmux`, never nested. Nothing about the existing tmux / `sesh` / `tmuxp` / workmux setup changes; herdr is purely additive so you can evaluate it without losing your daily driver.

- **Install**:
  - macOS — Homebrew (`herdr` is in homebrew-core; managed by the `dot_ansible/roles/devtools/tasks/main.yml` macOS list)
  - Linux — GitHub release **single static binary** (`herdr-linux-{x86_64,aarch64}`) into `~/.local/bin/herdr` (managed by the `# --- herdr ... ---` block in the same role). No tarball, so no unarchive step.
- **Verify**: `herdr --version` · validate config with `herdr server reload-config`
- **Upgrade**: brew on macOS; `herdr update` for the self-managed Linux binary
- **Config**: `~/.config/herdr/config.toml` — chezmoi **seed-once** (`dot_config/herdr/create_config.toml`, the `create_` prefix). herdr writes UI settings back into this file (see [Config writeback](#config-writeback-why-create_)), so chezmoi plants it on a fresh machine and then never touches it.

> **Not gated by `enableVimMode`.** That flag governs shell + tmux modal editing; herdr's copy mode (`prefix+[`) is vi-style natively regardless (`h/j/k/l`, `w/b/e`, `{`/`}`, `v`/Space to select, `y`/Enter to copy, `q`/Esc to leave), so there is nothing to gate.

---

## Model differences vs tmux

herdr's hierarchy is **Session → Workspace → Tab → Pane** (tmux is Session → Window → Pane). "Workspace" is a project-level container; a "Tab" groups panes. The CLI (`herdr session|workspace|pane|agent …`, most with `--json`) is the scripting surface that replaces `tmux switch-client` / `list-sessions` etc.

## Feasibility matrix (current tmux experience → herdr)

| Current capability | herdr story | How it's handled here |
|---|---|---|
| Catppuccin theme + light/dark | **Native** `[theme]` + `auto_switch` | Configured in `config.toml` |
| Splits / zoom / new tab+workspace / pane nav | **Native** `[keys]` actions | Rebound to tmux muscle memory |
| Session persistence (resurrect/continuum) | **Native** detach/reattach | Skipped — native |
| Mouse / right-click menus | **Native** mouse-first | Skipped — native |
| Agent status 🤖/💬/✅ (workmux, 6 files) | **Native** agent-state rollups in sidebar | Skipped — native (workmux untouched for tmux) |
| `sesh` fuzzy switch + `tmuxp` layouts | **Plugin** [herdr-plus](https://github.com/cloudmanic/herdr-plus) Projects + Quick Actions | Plugin + Projects templates |
| `tv` channel popups (`prefix+T/U/a`) | **Custom command panes** (`[[keys.command]] type="pane"`) | Key bindings + 2 herdr-aware channels |
| lazygit / scratch popups | **Custom command panes** | Key bindings |
| Seamless `Ctrl-hjkl` nvim↔pane nav | **No herdr-aware smart-splits** | **Gap** — workaround below |
| OSC133 copy-mode (`cpout`/`cpblock`) | tmux-specific | **Gap** — `cpcmd` (zsh history) still works |
| Per-window status glyphs + bookmarks ⭐📌 | **No format-string interpolation** | **Gap** — native agent dots replace the agent part |
| AI session-summary / agent-wakeup capture | re-portable against `herdr pane read` / `pane list --json` | **Deferred** — out of trial scope |

## Keybindings

Prefix is `ctrl+b` (same as tmux). Built-in actions can only be *rebound* (herdr's action set is fixed); everything else is a `[[keys.command]]` custom command. Custom commands receive `$HERDR_SOCKET_PATH`, `$HERDR_ACTIVE_PANE_ID`, `$HERDR_ACTIVE_PANE_CWD` and run from the focused pane's cwd.

| Key | Action | Type |
|---|---|---|
| `prefix + c` / `prefix + 1..9` | new tab / switch tab | built-in default |
| `prefix + h/j/k/l` | focus pane | built-in default |
| `prefix + \|` / `prefix + minus` | split side-by-side / stacked | rebound |
| `prefix + z` / `prefix + x` | zoom / close pane | built-in default |
| `prefix + w` / `prefix + g` | workspace nav / session navigator | built-in default |
| `prefix + [` | vi copy mode (`hjkl`, `w/b/e`, `{/}`, `v`, `y`) | built-in default |
| `prefix + q` | detach | built-in default |
| `prefix + ,` | rename tab | rebound (tmux muscle memory) |
| `prefix + shift + r` | reload config (`prefix + r` stays resize mode) | rebound |
| `prefix + shift + b` | new git worktree (moved off `prefix + shift + g`) | rebound |
| `prefix + G` | lazygit | command pane |
| `prefix + U` | `tv tools` (CLI launcher) | command pane |
| `prefix + T` | `tv herdr-sesh` (workspace/dir switcher) | command pane |
| `prefix + a` | `tv herdr-agent-panes` (live agent panes) | command pane |
| `prefix + f` | `tv fleet-hosts` (SSH picker) | command pane |
| `` prefix + ` `` | scratch shell | command pane |
| `prefix + O` | herdr-plus **Projects** (layout launcher) | plugin action |
| `prefix + y` | herdr-plus **Quick Actions** | plugin action |

> Uppercase letters resolve to `prefix+shift+<letter>`, which herdr reserves for built-ins (`shift+g` worktree, `shift+t` rename-tab, `shift+h/j/k/l` swap-pane). `prefix+G`/`prefix+T` are freed by the rebinds above; `herdr server reload-config` reports any remaining collisions in its `diagnostics`.

## herdr-plus plugin (sesh + tmuxp + menu analog)

[herdr-plus](https://github.com/cloudmanic/herdr-plus) adds **Projects** (declarative multi-tab/multi-pane workspace templates with a fuzzy picker — the `tmuxp`/`tmuxinator` analog) and **Quick Actions** (a fuzzy command launcher — the popup-menu analog).

**Install is automated** by the `devtools` ansible role (the `# --- herdr-plus plugin ---` block) — idempotent, runs on every `chezmoi apply`, skipped once installed. It shells out to:

```bash
herdr plugin install cloudmanic/herdr-plus   # manual fallback / what the role runs
```

`herdr plugin install` **downloads a prebuilt release binary when no Go toolchain is present**, so it works with or without Go. The one trap: if a *stale* Go is on `PATH` (e.g. an old `/usr/local/go` shadowing a newer one) herdr tries to build from source and fails (`invalid go version … must match format 1.23`) instead of falling back. The ansible task sidesteps this by prepending mise's Go (`mise which go` → its bin dir) when available; to fix it by hand, put a modern Go first: `PATH="$(dirname "$(mise which go)"):$PATH" herdr plugin install cloudmanic/herdr-plus`. (Go is mise-managed now, gated on `installExtraRuntimes`.)

Project templates are chezmoi-managed under `dot_config/herdr/plugins/config/cloudmanic.herdr-plus/projects/` → the same path under `~/.config/`. The shipped `chezmoi.toml` mirrors this repo's tmuxinator `chezmoi` session (editor/git/shell tabs). Bind `prefix+O` → Projects and `prefix+y` → Quick Actions (already in the config).

## Television integration

Most `tv` channels (`tools`, `fleet-hosts`, `mlflow`, `kill-process`, `ssh-config`) have **non-tmux-coupled actions**, so they run unchanged in a herdr command pane — just bind a key to `tv <channel>`. Only the channels whose actions call `tmux …` need herdr-aware variants. Two ship here:

- `herdr-sesh` (`dot_config/television/cable/herdr-sesh.toml`) — lists herdr sessions/workspaces + zoxide dirs; Enter dispatches `herdr session attach` / `herdr workspace focus` / `herdr workspace create --cwd` instead of `sesh connect` / `tmux switch-client`.
- `herdr-agent-panes` (`dot_config/television/cable/herdr-agent-panes.toml`) — same source as `agent-panes`, but switch/kill use `herdr pane focus` / `herdr pane close`.

The original tmux-bound `sesh` / `agent-panes` channels are left intact for coexistence.

## Agent state (replaces the 6-file workmux integration)

herdr detects agent state natively and rolls it up into the sidebar (a blocked agent marks its pane/tab/workspace). Claude Code is detected via **screen-manifest heuristics** (terminal title + OSC progress), not lifecycle hooks. If the heuristics prove insufficient, state can be pushed explicitly:

```bash
herdr pane report-agent w1:p1 --agent claude --state working
```

For the trial we rely on native detection — the tmux-side workmux 🤖/💬/✅ system (Claude/OpenCode hooks → `@workmux_status`) is untouched and only applies under tmux.

### Optional agent integrations (the onboarding "install" button)

herdr's first-run onboarding offers to **install optional agent integrations** (`herdr integration install <agent>`), so agents report state directly instead of relying on screen heuristics. Pressing *install* sets these up for every detected agent. What it writes (verified on this machine):

| Agent | What `herdr integration install` creates | Touches a repo-managed file? |
|---|---|---|
| claude | `~/.claude/hooks/herdr-agent-state.sh` **+ a hook entry in `~/.claude/settings.json`** | Yes — but the repo's hook-aware `modify_settings.json` merger **preserves** it (same as it does for CodeIsland). `chezmoi apply` is a no-op; it won't strip the herdr hook. |
| codex | `~/.codex/herdr-agent-state.sh` only | No — `~/.codex/config.toml` is untouched (identical to the chezmoi-computed target). |
| opencode | `~/.config/opencode/plugins/herdr-agent-state.js` (separate plugin) | No — only `workmux-status.ts` is managed; herdr's plugin coexists. |
| cursor | `~/.cursor/herdr-agent-state.sh` + hook | Script lives outside chezmoi; coexists. |

These integration files are **not** vendored into the repo, so they do **not** reproduce on other machines (press *install* again there, or skip onboarding). They use herdr's own socket and do not interfere with tmux/workmux (different mechanism). To remove: `herdr integration uninstall <agent>` — and for **claude**, rerun `chezmoi apply` afterwards so the merger drops the now-removed hook from `settings.json`.

### Config writeback (why `create_`)

herdr **writes UI/runtime settings back into `~/.config/herdr/config.toml`** — e.g. finishing onboarding prepends `onboarding = false`, and the in-app *settings* popups (theme / sound / toasts / pane labels) persist there on *apply*. It edits in place and keeps existing comments, but it owns the file at runtime. That is why chezmoi manages it as **`create_` (seed-once)**: a plain managed file would be clobbered on every `chezmoi apply` (re-removing `onboarding=false` → the onboarding screen reappears, and reverting any UI change). Consequence: edits to `create_config.toml` in the repo do **not** auto-propagate to a machine that already has the file — refresh it deliberately with `cp ~/.config/herdr/config.toml "$(chezmoi source-path ~/.config/herdr/config.toml)"` (then strip the runtime `onboarding`/state lines).

## Gaps (no clean herdr equivalent)

- **Seamless `Ctrl-hjkl` nvim↔pane navigation.** `vim-tmux-navigator` is tmux-coupled (the `is_vim` `ps`/`pane_tty` heuristic + the nvim plugin). herdr has no smart-splits equivalent — its pane focus is `prefix+h/j/k/l`, which won't pass through to nvim splits at the edge. Workaround: inside nvim use its own `<C-w>hjkl`. This is the biggest UX regression vs tmux.
- **OSC133 copy-mode** (`cpout` / `cpblock`, prompt-jump, last-output yank) is tmux-specific. herdr's copy mode (`prefix+[`) is vi-style but has no OSC133 prompt-boundary awareness. `cpcmd` (zsh history, multiplexer-agnostic) still works.
- **Status-bar format glyphs + bookmarks** (⭐/📌/🔖): herdr has no `#{@option}` format-string interpolation. Native agent dots cover the agent part; manual bookmarks have no analog.

> **Not a gap:** vi copy-mode itself *is* native (`prefix+[`), and per-pane agent state is detected natively — the two things I expected to be missing turned out to be built in.

## See also

- [tmux setup](tmux/README.md) · [Television (tv)](tv.md) · [sesh](sesh.md) · [workmux](workmux.md)
- [Tool managers — where tools come from](../this_repo/tool-managers.md)
