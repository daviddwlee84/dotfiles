# gh-dash: Herdr hotkeys + view-specific launch configs + usage doc

## Context

Answers to the user's questions (from investigation):

- **Installed?** Yes. `devtools` role runs `gh extension install dlvhdr/gh-dash` (`dot_ansible/roles/devtools/tasks/main.yml:1291-1320`, gated on `gh` + `gh auth status`). Local: v4.26.0. Catalog entry already exists (`dot_config/docs/tools/tool-catalog.toml:912`).
- **Config managed?** Yes, but minimal: `dot_config/gh-dash/config.yml` only sets `pager.diff: diffnav` (documented in `docs/tools/git_diff_workflow.md`).
- **Discussions?** No. v4.26 has exactly three views: PRs → Issues → Notifications (cycled with `s`). Discussions only show up as *notification* rows (via `reason:` filters), and `o` opens them in the browser. There's no Discussions list, search, or reply in gh-dash.
- **No CLI flag to pick the start view.** Only `defaults.view: prs|issues|notifications` in config. v4.26 supports `include:` (confirmed: `yaml:"include,omitempty"` in the binary), so thin per-view configs can reuse the global config.
- **Herdr key namespace:** `prefix+P` = built-in `rename_pane` (`prefix+shift+p`), so it can't be used. `prefix+alt+p/i/n` are free in both the herdr 0.9.5 defaults and our template. Prefix-free `Alt+P/I` are skipped because the shell uses them for tv channels (`docs/shells/keybindings.md:27`).

Outcome: one keystroke opens gh-dash in PRs, Issues, or Notifications, scoped to the focused pane's repo (smart filtering), plus a bilingual cheat-sheet doc.

## Changes

### 1. Per-view gh-dash configs (`dot_config/gh-dash/`)
- Keep `config.yml` as the SSOT (add a header comment only, and optionally a `notificationsSections` default, e.g. `Unread` = `is:unread`, `Participating` = `reason:participating`).
- New `issues.yml`:
  ```yaml
  include: [./config.yml]
  defaults:
    view: issues
  ```
- New `notifications.yml`: same, with `view: notifications`.
- Caveat to document: `--config` takes precedence over a repo-local `.gh-dash.yml`. Plain `gh dash` (the PR key) still honours the repo-local file.

### 2. Herdr keybinds (`.chezmoitemplates/herdr/config.toml`, next to the lazygit block ~L140-154)
Use `type = "pane"` like lazygit: popups are session-modal, so a dashboard left open would block tab switching (per the existing comment).
```toml
[[keys.command]]
key = "prefix+alt+p"
type = "pane"
command = "gh dash"
description = "gh-dash: pull requests (temporary pane)"

[[keys.command]]
key = "prefix+alt+i"
type = "pane"
command = "gh dash --config ~/.config/gh-dash/issues.yml"
description = "gh-dash: issues (temporary pane)"

[[keys.command]]
key = "prefix+alt+n"
type = "pane"
command = "gh dash --config ~/.config/gh-dash/notifications.yml"
description = "gh-dash: notifications (temporary pane)"
```
The pane runs in the focused pane's cwd, so gh-dash's smart filtering scopes it to the current repo (`t` toggles that off).

### 3. New doc `docs/tools/gh-dash.md` + `docs/tools/gh-dash.zh-TW.md`
Sections:
- Launching: `gh dash`, the three Herdr keys, and the per-view configs.
- Views: `s` cycles PRs → Issues → Notifications.
- Navigation: `j/k`, `g/G`, `h/l` sections, `p`/`P` preview, `ctrl+d/u`, `?` help, `q` quit.
- Searching: `/` edits the section's GitHub search query (not saved), with query examples (`is:open review-requested:@me`, `repo:o/r label:bug`, `author:@me`). Also `t` smart filtering, `r`/`R` refresh, and `ctrl+s` section mode (`n` new, `x` remove).
- Per-view action tables:
  - PR: `v d C c m w W a L x X u [ ]`
  - Issue: `a A L c C x X`
  - Notification: `enter esc D alt+d m M u b S`
  - Common: `o y Y`
- Discussions limitation and workarounds: notifications + `o`; `gh browse -- discussions`.
- Config layout and `include` semantics, with a link to gh-dash.dev.

Mirrors:
- `mkdocs.yml` nav entry next to `git diff workflow` (~L343).
- Link from `git_diff_workflow{,.zh-TW}.md` and `gh-cli{,.zh-TW}.md` "See also".

### 4. Cross-file mirrors
- `docs/tools/herdr.md` (+ `.zh-TW` if it has the keybinding table): add the three keys to § Keybindings.
- `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` L211: add "`prefix+Alt+p/i/n` gh-dash PRs/issues/notifications pane" to the herdr summary.
- `README.md` L231: mention the per-view configs.

## Verification
- `chezmoi diff` / `chezmoi apply` for `~/.config/gh-dash/*` and `~/.config/herdr/config.toml`.
- `herdr config check` against the rendered config, then `herdr server reload-config` and confirm no key-collision diagnostics.
- `gh dash --config ~/.config/gh-dash/issues.yml` and the `notifications.yml` variant open on the right view and still use the diffnav pager (`include` merged). Smoke test in a tmux/Herdr pane, then quit.
- In Herdr, press each of `prefix+Alt+p/i/n` inside a repo pane and confirm the temporary pane closes on `q`.
- `just docs-build` for the new doc and nav entry.
- `bats tests/unit/herdr_*.bats` to check that nothing regressed in the herdr config tests.
