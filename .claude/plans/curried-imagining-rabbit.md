# Plan: Add Project Cheatsheet + fzf/tv Quick Reference Docs

## Context

The user wants a quick-reference doc covering:
1. All CLI commands used to maintain this dotfiles project (chezmoi, ansible, just, docker, brew, pre-commit)
2. fzf keybindings and configuration quick reference
3. television (tv) channels and keybindings quick reference

The user suggested `docs/zsh/commands.md`, but since project maintenance CLIs are not zsh-specific
and fzf/tv tool docs already belong alongside other per-tool docs in `docs/tools/`, a better split is:
- `docs/cheatsheet.md` — project-level maintenance CLIs
- `docs/tools/fzf.md` — fzf quick reference
- `docs/tools/tv.md` — television quick reference

---

## Files to Create

### 1. `docs/cheatsheet.md`

Project maintenance CLI quick reference. Sections:

- **just** — `just` (list all), commonly used recipes with one-line descriptions
- **chezmoi** — `diff`, `apply`, `apply --dry-run`, `edit`, `cd`, `status`, `state delete-bucket --bucket=scriptState`; also note `just chezmoi-*` shortcuts
- **ansible** — playbook commands from `~/.ansible/`, available `--tags`, `--check`, `--skip-tags sudo`; table mirrors CLAUDE.md tag list (condensed)
- **brew bundle** — check/install per Brewfile, which files exist (`Brewfile`, `Brewfile.darwin`, `Brewfile.linux`)
- **docker** — `just docker-build/run/test/clean` etc.
- **pre-commit / gitleaks** — `just pre-commit-run-all`, `just gitleaks-scan[-history]`

### 2. `docs/tools/fzf.md`

Consistent with existing `docs/tools/*.md` style. Sections:

- **Shell keybindings** (from `10_fzf.zsh`):
  - `Ctrl+T` — fuzzy file picker (uses `fd`, previews with `bat`)
  - `Ctrl+R` — fuzzy command history
  - `Alt+C` — fuzzy directory picker + cd (previews with `eza --tree`)
- **Environment variables configured**:
  - `FZF_DEFAULT_OPTS`, `FZF_DEFAULT_COMMAND` (fd, excludes .git)
  - `FZF_CTRL_T_COMMAND/OPTS`, `FZF_ALT_C_COMMAND/OPTS`
- **Custom completion preview** (`_fzf_comprun`):
  - `cd` → eza tree, `export`/`unset` → var value, `ssh` → dig lookup, default → bat 500 lines
- **fzf-tmux integration**: used by sesh-sessions (`fzf-tmux -p 80%,70%`) — see `docs/tools/sesh.md` for session picker details

### 3. `docs/tools/tv.md`

- **What it is**: television TUI fuzzy finder (`tv` command), used for sesh session picking and general fuzzy search
- **Usage**: `tv` (interactive), `prefix + T` in tmux (sesh picker popup)
- **Custom channels** (from `dot_config/television/cable/sesh.toml`):
  - `sesh` channel — tmux sessions, configs, zoxide dirs, fd search
- **In-picker keybindings for sesh channel**:
  - `Ctrl+A` — all sessions, `Ctrl+T` — tmux only, `Ctrl+G` — configs, `Ctrl+X` — zoxide dirs, `Ctrl+F` — fd file search
  - `Enter` — connect, `Ctrl+D` — kill session + refresh
- **Preview**: `sesh preview '{selection}'`, right-aligned 55%
- **Tmux integration**: `prefix + T` opens sesh picker via television popup

---

## Files NOT Modified

- `CLAUDE.md` — no new maintenance rule needed; cheatsheet is a reference doc, not a workflow rule
- `docs/zsh/aliases.md` — unchanged

---

## Verification

After creation, verify:
1. `cat docs/cheatsheet.md` — chezmoi/ansible/docker/brew/pre-commit sections all present
2. `cat docs/tools/fzf.md` — keybindings + env vars + completion preview documented
3. `cat docs/tools/tv.md` — sesh channel keybindings + tmux integration documented
4. All three files render cleanly as markdown (tables, code blocks)
