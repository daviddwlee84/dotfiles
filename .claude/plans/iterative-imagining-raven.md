# Plan: Interactive CLI Tools Reference (Docs + fzf/TV Picker)

## Context

The repo installs many CLI tools across 18 ansible roles but there's no single reference showing what's available and how to invoke each one. The user wants both a human-readable cheatsheet and an interactive picker (fzf / TV) where selecting a tool pastes its invocation to the shell buffer (safe) or executes it directly (Ctrl+E for TUI apps).

---

## Files to Create / Modify

| File | Action | Deployed to |
|------|--------|-------------|
| `dot_config/docs/tools/cli-tools.md` | **Create** — source-of-truth cheatsheet | `~/.config/docs/tools/cli-tools.md` |
| `dot_config/television/cable/tools.toml` | **Create** — TV cable channel | `~/.config/television/cable/tools.toml` |
| `dot_config/zsh/tools/11_tools_picker.zsh` | **Create** — fzf ZLE widget | `~/.config/zsh/tools/11_tools_picker.zsh` |
| `dot_config/tmux/keybindings.conf` | **Edit** — add `prefix + U` and popup menu entry | deployed |
| `docs/tools/tv.md` | **Edit** — document the new `tools` channel | repo-only |

---

## Architecture: Single Source of Truth

`dot_config/docs/tools/cli-tools.md` is the **only file to maintain**. Both TV and fzf parse it at runtime via `awk`. Format: markdown tables with 4 columns:

```
| Command | Invocation | Description | Notes |
```

- **Command**: bare binary name (`` `rg` ``)
- **Invocation**: what to paste/run — bare binary for TUI tools (`btop`), binary + trailing space for tools needing args (`rg `)
- **Description**: ≤60 char one-liner
- **Notes**: notable flags, aliases defined in this repo

The `awk` parse regex matches rows starting with `| \`` to skip headers/separators.

---

## 1. `dot_config/docs/tools/cli-tools.md`

Organized into 8 categorized sections (matching ansible roles):
- **File & Search**: rg, fd, bat, eza, fzf, yazi
- **Git & Diff**: lazygit, delta, diffnav, git-graph, gh
- **Sessions & Multiplexing**: tmux, sesh, zellij
- **Navigation**: zoxide (z), tv, direnv
- **Process & System**: btop, htop, pueue
- **Dev Tools**: jq, just, glow, tldr, thefuck, duckdb, taplo, pre-commit, gitleaks
- **Networking**: doggo, httpie (http), gping, trippy, bandwhich, nmap, rustscan, speedtest
- **AI / Coding Agents**: claude, opencode, gemini, ollama

**Invocation tier convention** (so picker stays safe):
- Pure TUI (no args): `btop`, `lazygit`, `yazi` → bare binary in Invocation column
- Needs args: `rg `, `fd `, `http ` → trailing space in Invocation column (cursor lands after space)
- Needs sudo: use alias where possible (e.g., `bandwhich` alias); avoid `sudo X` in invocations

---

## 2. `dot_config/television/cable/tools.toml`

```toml
[metadata]
name = "tools"
description = "CLI tools quick-launch"
requirements = ["awk"]

[source]
command = """
awk -F'|' '/^[[:space:]]*\\|[[:space:]]*`/ {
  inv=$3; sub(/^[[:space:]]*`/,"",inv); sub(/`[[:space:]]*$/,"",inv)
  desc=$4; sub(/^[[:space:]]+/,"",desc); sub(/[[:space:]]+$/,"",desc)
  printf "%-22s  %s\\n", inv, desc
}' ~/.config/docs/tools/cli-tools.md
"""

[preview]
command = """
tool=$(printf '%s' '{...}' | awk '{print $1}' | sed 's/ *$//')
if command -v tldr >/dev/null 2>&1; then
  tldr "$tool" 2>/dev/null || "$tool" --help 2>&1 | head -40
else
  "$tool" --help 2>&1 | head -40
fi
"""

[keybindings]
enter = "actions:paste"
ctrl-e = "actions:exec"

[actions.paste]
description = "Paste invocation to shell buffer (requires Enter)"
command = "printf '%s' '{...}' | awk '{$1=$1; print $1}'"
mode = "insert"

[actions.exec]
description = "Execute directly (safe TUI tools: btop, lazygit, etc.)"
command = "$(printf '%s' '{...}' | awk '{print $1}')"
mode = "execute"
```

**Note on `mode = "insert"`**: This is TV's mechanism for writing text to the calling shell's input buffer without executing. Requires television >= 0.9. The fzf ZLE widget is the reliable fallback.

---

## 3. `dot_config/zsh/tools/11_tools_picker.zsh`

Named `11_` to load after `10_fzf.zsh` (depends on fzf being configured). Uses the **ZLE `LBUFFER` pattern** (same as sesh widget in `22_sesh.zsh`) so selection pastes to shell buffer without executing.

```zsh
_TOOLS_DOC="${HOME}/.config/docs/tools/cli-tools.md"
[[ -f "$_TOOLS_DOC" ]] && command -v fzf &>/dev/null || return 0

_tools_list() {
    awk -F'|' '/^[[:space:]]*\|[[:space:]]*`/ {
      inv=$3; sub(/^[[:space:]]*`/,"",inv); sub(/`[[:space:]]*$/,"",inv)
      desc=$4; sub(/^[[:space:]]+/,"",desc); sub(/[[:space:]]+$/,"",desc)
      printf "%-22s  %s\n", inv, desc
    }' "$_TOOLS_DOC"
}

tools-picker() {
    local selected
    selected=$(
        _tools_list | fzf \
            --border \
            --prompt ' tools  ' \
            --header 'Enter: paste to buffer  Ctrl+E: execute now  Ctrl+/: preview' \
            --delimiter '  ' \
            --preview 'tool=$(echo {1} | awk "{print \$1}" | sed "s/ *$//"); (command -v tldr >/dev/null && tldr "$tool" 2>/dev/null) || "$tool" --help 2>&1 | head -40' \
            --preview-window 'right:55%:wrap' \
            --bind 'ctrl-e:execute(eval $(echo {1} | awk "{print \$1}"))+abort' \
            --bind 'ctrl-/:toggle-preview'
    ) || return

    local invocation
    invocation=$(printf '%s' "$selected" | awk '{print $1}')
    LBUFFER="${LBUFFER}${invocation}"
    zle reset-prompt
    zle redisplay
}
zle -N tools-picker

# Alt+T (mnemonic: Tools). Alt+C=fzf-cd, Alt+T=tools, free slot.
bindkey -M emacs '\et' tools-picker
bindkey -M viins '\et' tools-picker
bindkey -M vicmd '\et' tools-picker
```

---

## 4. `dot_config/tmux/keybindings.conf` edits

**After the `bind-key "O"` line** (in the Sesh section), add:
```tmux
# prefix + U: CLI tools picker via television
bind-key "U" display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' CLI Tools (tv) ' "tv tools"
```

**In the Popup Menu** (`bind-key Space display-menu ...`), after the `"Sesh windows"` line, add:
```
"CLI Tools picker" U "display-popup -E -w 80% -h 70% -d '#{pane_current_path}' -T ' CLI Tools (tv) ' 'tv tools'" \
```

`prefix + U` is currently unbound at the top level (confirmed). `U` in the Space popup is already used for TPM Update — the new entry will conflict; use a different popup letter like `b` (Browse).

---

## 5. `docs/tools/tv.md` edit

Add under `## Custom Channels`:
```markdown
### `tools` channel
Parses `~/.config/docs/tools/cli-tools.md` at runtime (deployed via chezmoi from `dot_config/docs/tools/`).
Open with `tv tools` or `prefix + U` in tmux.
- **Enter**: paste invocation to shell buffer (safe — you still press Enter to run)
- **Ctrl+E**: execute directly (for safe TUI tools like `btop`, `lazygit`)
- **Preview**: tldr page or `--help` output
```

---

## Verification

```bash
chezmoi apply   # deploys ~/.config/docs/tools/cli-tools.md, TV channel, zsh file

# Test TV channel
tv tools        # should show formatted list with preview

# Test fzf widget
# In a new zsh session, press Alt+T — picker opens, Enter pastes invocation

# Test tmux binding
# In tmux: prefix + U  →  tv tools popup appears
```
