# fzf Quick Reference

[fzf](https://github.com/junegunn/fzf) — command-line fuzzy finder.

Config source: `dot_config/zsh/tools/10_fzf.zsh`

---

## Shell Keybindings

| Key | Action | Preview |
|-----|--------|---------|
| `Ctrl+T` | Insert fuzzy-matched file path at cursor | `bat` syntax highlight (500 lines) |
| `Ctrl+R` | Fuzzy search command history | — |
| `Alt+C` | Fuzzy-match directory and `cd` into it | `eza --tree` (200 lines) |

---

## Environment Variables

```bash
# Base options applied to all fzf invocations
FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border"

# Use fd instead of find (respects .gitignore, faster)
FZF_DEFAULT_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"

# Ctrl+T: file picker
FZF_CTRL_T_COMMAND="fd --hidden --strip-cwd-prefix --exclude .git"
FZF_CTRL_T_OPTS="--preview 'bat -n --color=always --line-range :500 {}'"

# Alt+C: directory picker
FZF_ALT_C_COMMAND="fd --type=d --hidden --strip-cwd-prefix --exclude .git"
FZF_ALT_C_OPTS="--preview 'eza --tree --color=always {} | head -200'"
```

---

## Tab Completion Preview (`_fzf_comprun`)

When using fzf-powered tab completion, preview varies by command:

| Command | Preview |
|---------|---------|
| `cd` | `eza --tree --color=always` (fallback: `tree -C`) |
| `export`, `unset` | `echo ${<var>}` — shows current variable value |
| `ssh` | `dig <host>` — DNS lookup |
| *(default)* | `bat -n --color=always --line-range :500` |

---

## fzf-tmux Integration

The `sesh-sessions` widget (bound to `Alt+S`) uses `fzf-tmux -p 80%,70%` to open a
floating popup inside tmux. See `docs/tools/sesh.md` for session picker keybindings.

---

## Tips

- **Fuzzy syntax**: space-separated tokens are AND'd; `!` negates; `^` anchors start; `$` anchors end
  - Example: `^foo bar !baz$` — starts with "foo", contains "bar", does not end with "baz"
- **Multi-select**: pass `--multi` (or `-m`) to enable `Tab`/`Shift+Tab` for multi-selection
- **Preview toggle**: `Ctrl+/` toggles the preview pane (built-in default)
