# Glow — terminal Markdown reader

[charmbracelet/glow](https://github.com/charmbracelet/glow) renders Markdown in the terminal with syntax highlighting and pager support. In this repo it powers the tmux cheatsheet popup and the `readurl` / `readlocal` web-reader pipeline.

- **Install**:
  - macOS — Homebrew (managed by `dot_ansible/roles/devtools/tasks/main.yml` macOS list)
  - Linux — GitHub release tarball into `~/.local/bin/glow` (managed by `dot_ansible/roles/devtools/tasks/main.yml` `# --- glow ---` block)
- **Used by**:
  - tmux popup menu cheatsheet — `prefix + Space` → `?` (see `dot_config/tmux/executable_menu.sh`)
  - Web reader pipeline — `readurl` / `readlocal` / `readnode` / `readraw` (see [Web reader](web-reader.md))
  - `aicapture` agent output rendering when stdout is markdown-shaped

---

## Daily commands

```bash
# Render a file with the pager (q to quit, j/k to scroll)
glow -p README.md

# Render a remote file
glow https://raw.githubusercontent.com/foo/bar/main/README.md

# Pipe markdown through (no pager, just rendered)
echo '# hello\n- a\n- b' | glow

# Width-constrained for narrow terminals
glow -w 80 README.md

# Choose a style explicitly
glow -s dark README.md     # dark | light | notty | <path-to-json>
```

The pager (`-p`) uses the same `bat`-style scroll keys most of the team already knows, so `glow -p file.md` is the closest equivalent to `bat README.md` for prose.

---

## Recommended aliases

This repo doesn't bind a global glow alias because the various callers (tmux cheatsheet, web reader) call it directly with the right flags. If you want a personal alias, add it to a private zsh fragment:

```bash
# ~/.config/zsh/tools/99_local.zsh (gitignored)
alias mdv='glow -p'
alias mdvw='glow -w "$(($(tput cols) - 4))" -p'
```

---

## Tips

- **TUI mode** — `glow` (no args) launches a TUI file browser for the current directory; arrow keys to navigate, `Enter` to open. Use `glow -a` to also list dotfiles.
- **Stash** — Charm offers a hosted stash for marking docs you read often. We don't use the hosted side; if you do, `glow stash add <file>` and `glow stash` to list.
- **Style files** — Glow accepts a path to a JSON style for full theming. The repo's tmux cheatsheet relies on the default dark style, which works on both Catppuccin and tmux2k tmux themes.
- **Fallback** — When `glow` isn't installed (e.g., during early bootstrap on a new machine), the tmux menu falls back to `less`. See `dot_config/tmux/executable_menu.sh` row `Cheatsheet` for the `glow … 2>/dev/null || less …` pattern.

---

## See also

- [Web reader](web-reader.md) — `readurl`, `readlocal`, `readnode`, `readraw`
- [tmux overview](tmux/README.md) — popup menu and cheatsheet
- [Gum](gum.md), [VHS](vhs.md), [Freeze](freeze.md) — the rest of the Charm CLI ecosystem in this repo
