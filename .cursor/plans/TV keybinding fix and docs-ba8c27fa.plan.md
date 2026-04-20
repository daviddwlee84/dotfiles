<!-- ba8c27fa-cf2e-4152-92a1-9d350276bcf0 -->
---
todos:
  - id: "commit"
    content: "Git commit the 3 modified files (pueue.toml, channels.toml, tv.md)"
    status: pending
  - id: "remap-tv-keys"
    content: "Remap or remove conflicting ctrl-h/j/k/l in TV config (approach TBD based on user answer)"
    status: pending
  - id: "claude-md-rule"
    content: "Add Maintaining Keyboard Shortcuts section to CLAUDE.md with cross-check checklist"
    status: pending
  - id: "update-tv-docs"
    content: "Add keybinding conflict notes to docs/tools/tv.md"
    status: pending
isProject: false
---
# TV Keybinding Fix, Commit, and Conflict Documentation

## 1. Git commit current changes

Commit the 3 modified files from the previous session's pueue channel work:
- `dot_config/television/cable/pueue.toml` -- switched actions from ctrl- to alt- keybindings, improved follow action for groups
- `dot_config/television/cable/channels.toml` -- bat-based syntax highlighting for preview
- `docs/tools/tv.md` -- updated documentation for alt- keybindings

Commit message style follows existing pattern (e.g. `ca95198 Add tv channel for Pueue`).

## 2. Remap TV global keybindings to avoid tmux conflicts

TV's `~/.config/television/config.toml` has 4 `ctrl-` keybindings that conflict with tmux's `vim-tmux-navigator` root-table bindings (`C-h/j/k/l` for pane navigation in `dot_config/tmux/keybindings.conf:127-130`).

**Proposed remappings** (pending user input on whether to chezmoi-manage):

| Original | Action | Remap | Rationale |
|----------|--------|-------|-----------|
| `ctrl-j` | `select_next_entry` | Remove | `down` and `ctrl-n` already do this |
| `ctrl-k` | `select_prev_entry` | Remove | `up` and `ctrl-p` already do this |
| `ctrl-h` | `toggle_help` | `f1` | Standard help key, no conflicts |
| `ctrl-l` | `toggle_layout` | `alt-;` or similar | Needs a non-conflicting key |

**Option A**: Add `dot_config/television/config.toml` to chezmoi (full file, ~255 lines). This makes remaps reproducible across machines but requires occasional sync with TV upstream defaults.

**Option B**: Just document the manual fix in `docs/tools/tv.md` and CLAUDE.md. Lighter but not portable.

## 3. Add keyboard shortcut conflict rule to CLAUDE.md

Add a new `## Maintaining Keyboard Shortcuts` section (near the existing "Maintaining" sections at the top) to `CLAUDE.md`:

**Content**: When adding or modifying keybindings in any tool config (`tmux`, `television`, `zellij`, `neovim`, `ghostty`, etc.), cross-check against known conflict surfaces:

- **tmux root-table bindings**: `dot_config/tmux/keybindings.conf` (`bind-key -n` lines, especially `C-h/j/k/l` from vim-tmux-navigator, `C-1..9` for window switching)
- **Television global keybindings**: `~/.config/television/config.toml` `[keybindings]` section (or chezmoi source if managed)
- **Television channel keybindings**: `dot_config/television/cable/*.toml` `[keybindings]` sections
- **Zellij**: `dot_config/zellij/config.kdl` (default_mode "locked" mitigates most conflicts)
- **Terminal emitter (Ghostty)**: `dot_config/ghostty/config` (`macos-option-as-alt` setting affects `Alt+` key availability)

Key conflict zones to watch:
- `Ctrl+H/J/K/L` -- tmux vim-tmux-navigator vs TV defaults
- `Ctrl+S/F/R` -- TV built-in cycling/reload
- `Alt+*` -- used by TV pueue channel actions; requires terminal to send Option as Meta

## 4. Update docs/tools/tv.md

Add a "Known Keybinding Conflicts" or "Keybinding Conflicts with tmux" section documenting the `ctrl-h/j/k/l` issue and the workaround/fix.
