# Plan: Trial herdr alongside tmux — recreate the tmux/tv/sesh/agent/vim experience

## Context

You want to **try** [herdr](https://github.com/ogulcancelik/herdr) (a Rust terminal-multiplexer + AI-agent orchestrator) and see how much of this repo's deep tmux experience can be reproduced — keybindings, Television (`tv`) channels, `sesh`, the coding-agent integration, and the vim-mode × nvim experience.

**Decisions (from you):**
- **Coexist** with tmux — herdr is installed and configured *alongside* tmux. `tmux`, `sesh`, `tmuxp`, the 6-file workmux status system, OSC133 copy-mode, etc. are **left untouched**. You run `herdr` to try it; `tmux` works exactly as today.
- **chezmoi-managed** config, installed **the same way as tmux/zellij** (ansible `devtools` role), **not** mise. Rationale: mise here is reserved for language runtimes; every CLI multiplexer/tool (`tmux`/`zellij`/`sesh`/`workmux`/`television`) is a brew/GitHub-release install in `dot_ansible/roles/devtools/tasks/main.yml`.
- **Skip reimplementing anything herdr already does natively** — lean on built-ins/plugins first; only hand-build what has no native analog.

### Feasibility summary (herdr vs current tmux setup)

| Current capability | herdr story | Action |
|---|---|---|
| Catppuccin theme + light/dark | **Native** (`[theme] name="catppuccin"`, `auto_switch`) | Configure, don't port |
| Splits / zoom / new tab+workspace / pane nav | **Native** built-in `[keys]` actions | Rebind keys |
| Session persistence (resurrect/continuum) | **Native** detach/reattach | Skip the port |
| Mouse / right-click menus | **Native** mouse-first | Skip the tmux menu scripts |
| Agent status 🤖/💬/✅ (workmux, 6 files) | **Native** agent-state rollups (idle/working/blocked/done) in sidebar | Skip the port; optionally push explicit state later |
| `sesh` fuzzy switch + `tmuxp`/`tmuxinator` layouts | **Plugin** `herdr-plus` = Projects (declarative multi-pane templates + fuzzy picker) + Quick Actions + worktree auto-layout | Install plugin + config |
| `tv` channel popups (`prefix+T/U/a`, menu entries) | **Custom command panes** (`[[keys.command]] type="pane"`) | Build bindings + 2 herdr-aware channels |
| lazygit / scratch / floax popups | **Custom command panes** | Build bindings |
| popup menu (`prefix+Space`, 8 submenus) | herdr-plus Quick Actions (fuzzy launcher) ≈ menu | Use plugin; optional fzf/gum menu later |
| **Seamless Ctrl-hjkl nvim↔pane nav** (vim-tmux-navigator) | **No herdr-aware smart-splits** | **GAP** — document + workaround |
| **OSC133 copy-mode** (`cpout`/`cpblock`, prompt-jump, last-output yank) | tmux-specific; herdr has `prefix+[` selection only | **GAP** — `cpcmd` (zsh history) still works |
| **vi copy-mode bindings** (v/V/y) | `prefix+[` selection; vi bindings undocumented | **VERIFY**, likely partial |
| Per-window status glyphs + bookmarks ⭐📌 | **No format-string / `#{@option}` interpolation** | **GAP** — native agent dots replace agent part; bookmarks have no analog |
| AI session-summary / agent-wakeup capture (Python, heavy `tmux capture-pane`) | Re-portable against `herdr pane read` / `pane list --json` / `agent list` | **Defer** — out of trial scope |

## What gets built

### 1. Install — ansible `devtools` role (mirror zellij/workmux)
In `dot_ansible/roles/devtools/tasks/main.yml`:
- **macOS**: add `herdr` to the Brewfile/`brew` tool list (line ~75 block, alongside `tmux`/`zellij`). Confirm formula/tap during impl (`brew install herdr` is documented; verify it resolves, else add the upstream tap).
- **Linux**: brew-if-present, else download the GitHub-release static binary (`herdr-linux-x86_64` / `herdr-linux-aarch64`) to `~/.local/bin/herdr` + `chmod +x` — same shape as the existing workmux Linux release task and tmux-appimage fallback. herdr is a single static binary, so no unarchive (sidesteps the macOS BSD-tar `.tar.gz` pitfall in memory).
- Upgrade path: `herdr update` for the release-binary install; brew handles the macOS side. Note in `scripts/upgrade_tools.sh` only if it needs a non-generic step (brew is already covered generically).

### 2. Config — `dot_config/herdr/config.toml.tmpl` (new, chezmoi-managed)
Mirrors `dot_config/zellij/config.kdl`'s management style. Templated for catppuccin + the keybindings. Sections:
- `[theme]` → `name = "catppuccin"`, `auto_switch = true`, light/dark names.
- `[keys]` → rebind herdr's built-in actions to match muscle memory **where herdr allows** (its action set is fixed — we rebind existing actions, we do not invent new built-ins): split, zoom, new tab/workspace, rename, reload, goto, resize_mode. `[keys.indexed]` for `1..9` tab/workspace switch.
- `[[keys.command]]` custom panes (the high-value recreations):
  - `prefix+G` → `type="pane"` `lazygit`
  - `` ` `` / `prefix+\`` → scratch shell pane
  - `prefix+U` → `type="pane"` `tv tools` (channel is NOT tmux-coupled — runs as-is)
  - `prefix+T` → `type="pane"` `tv herdr-sesh` (herdr-aware variant, see §4)
  - `prefix+a` → `type="pane"` `tv herdr-agent-panes` (herdr-aware variant)
  - `prefix+H` (or a free key) → fleet-hosts / mlflow `tv` popups (channels are not tmux-coupled — as-is)
- `[ui]` mouse + sidebar; `[terminal]` shell defaults.
- **Keybinding namespace**: herdr is the *outer* layer when launched (you run herdr OR tmux, not nested), so no tmux-root-table collision — but keep `Alt+` for additions and cross-check herdr defaults. NOT gated by `enableVimMode` (herdr has no vi copy-mode to gate; document this).

### 3. herdr-plus plugin — Projects + Quick Actions (replaces sesh+tmuxp+menu)
- Install: `herdr plugin install cloudmanic/herdr-plus` (wire into the same chezmoi run-script style that restores other tooling, or document as a one-liner in the herdr doc + ansible `creates:` guard).
- Bind `prefix+O` → `cloudmanic.herdr-plus.projects`, `prefix+Space` (or `prefix+y`) → `cloudmanic.herdr-plus.quick-actions`.
- Author **Projects** templates mirroring `coding-agent.yaml` / `project.yaml` layouts (nvim 75% | specstory 25%; editor/shell/git tabs) under herdr-plus's `projects/` config dir, chezmoi-managed.

### 4. Two herdr-aware `tv` channels (the only tv porting needed)
Most channels (`tools`, `fleet-hosts`, `mlflow`, `kill-process`, `ssh-config`) have **non-tmux-coupled actions** → run unchanged in a herdr pane. Only the tmux-coupled ones need variants:
- `dot_config/television/cable/herdr-sesh.toml` — same source as `sesh`, but Enter action calls `herdr session attach` / `herdr workspace focus` instead of `tmux switch-client`.
- `dot_config/television/cable/herdr-agent-panes.toml` — same source as `agent-panes` (`agent-sessions.py panes`), but switch/kill actions use `herdr pane focus` / `herdr pane close` instead of `tmux select-pane`/`kill-pane`.
- These are **additive** — original tmux channels stay intact for coexistence.

### 5. Skipped (herdr native — per your instruction)
- workmux 6-file status port → rely on herdr's native agent-state sidebar. (Optional later: `herdr pane report-agent --state` from the existing Claude hooks for authoritative state.)
- resurrect/continuum port → herdr native persistence.
- tmux right-click menu scripts → herdr native mouse menus.

### 6. Documented gaps (no native analog; defer, don't fake)
- **Seamless Ctrl-hjkl nvim↔pane nav**: vim-tmux-navigator is tmux-coupled (the `is_vim` `ps`/`pane_tty` heuristic + nvim plugin). Workaround in herdr: bind `Ctrl-hjkl` to `pane focus --direction` (loses pass-through-to-nvim-at-edge; inside nvim use its own `<C-w>hjkl`). Note this is the biggest UX regression vs tmux.
- **OSC133 copy-mode** (`cpout`/`cpblock`, prompt jumps, last-output yank): tmux-only. `cpcmd` (zsh history, multiplexer-agnostic) still works.
- **Status-bar format glyphs + bookmarks** (⭐/📌/🔖): no `#{@option}` interpolation in herdr. Native agent dots cover the agent part; bookmarks have no analog.
- **vi copy-mode bindings**: verify what `prefix+[` supports during impl.

### 7. Repo housekeeping (CLAUDE.md cross-file rules)
- `docs/this_repo/tool-managers.md` § Tool index (A–Z): add a `herdr` row (install mechanism = ansible/brew + GitHub-release). Add to upgrades.md only if non-generic.
- `README.md`: add herdr to **What You Get** (note: trial, coexists with tmux).
- New `docs/tools/herdr.md`: the feasibility matrix above + keybinding map + the documented gaps + plugin/Projects setup. Add nav entry to `mkdocs.yml`.
- Optional: name `herdr` CLI in `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` once stable; add shell completions to `scripts/generate_completions.sh` if herdr ships `--completion`.

## Critical files
- `dot_ansible/roles/devtools/tasks/main.yml` — install (model after the zellij/workmux blocks, ~line 75 macOS list + a Linux release task).
- `dot_config/herdr/config.toml.tmpl` — **new**, the heart of the recreation.
- herdr-plus Projects templates (chezmoi-managed, under the plugin config dir).
- `dot_config/television/cable/herdr-sesh.toml`, `herdr-agent-panes.toml` — **new** herdr-aware channel variants.
- `docs/tools/herdr.md` + `mkdocs.yml` + `docs/this_repo/tool-managers.md` + `README.md`.
- Reuse as-is (do not modify): `~/.config/television/agent-sessions.py`, existing `tv` channel sources, `dot_config/sesh/*`, all tmux config.

## Verification (per "validate with the app, not just syntax")
1. `chezmoi execute-template < dot_config/herdr/config.toml.tmpl` (or `chezmoi cat ~/.config/herdr/config.toml`) renders valid TOML on this host.
2. `chezmoi apply` installs herdr; `herdr status` / `herdr --version` succeeds; `herdr server reload-config` accepts the config (its built-in validation).
3. Launch `herdr`: verify theme, splits/zoom/tab keys, `prefix+G` lazygit pane, `prefix+U` `tv tools`, `prefix+T` herdr-sesh switches a session via the herdr CLI, herdr-plus `prefix+O` Projects spins up the coding-agent layout, and the native agent-state dots light up when a Claude/opencode pane is working.
4. Confirm the documented gaps behave as described (Ctrl-hjkl moves herdr panes; copy `prefix+[`).
5. `uv run mkdocs build --strict` passes with the new `docs/tools/herdr.md` nav entry.
6. tmux untouched: `tmux` still launches with all existing keybindings/channels.
