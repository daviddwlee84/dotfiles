<!-- 7a5ab1aa-f3ae-4ce3-b3a0-417522cb0edc -->
---
todos:
  - id: "fix-extended-keys"
    content: "Add extended-keys always + terminal-features extkeys to dot_tmux.conf to fix Shift+Enter for coding agents"
    status: pending
  - id: "modern-settings"
    content: "Add modern tmux settings: escape-time 0, true color, OSC 52, focus-events, base-index 1, allow-passthrough"
    status: pending
  - id: "tmux-which-key"
    content: "Add tmux-which-key TPM plugin + ensure coreutils is in macOS brew list for compatibility"
    status: pending
  - id: "vim-navigation"
    content: "Add vim-style pane navigation bindings (hjkl)"
    status: pending
  - id: "zellij-config"
    content: "Create minimal zellij config.kdl addressing key conflict issues"
    status: pending
  - id: "update-docs"
    content: "Update README.md and CLAUDE.md with tmux keybinding documentation"
    status: pending
isProject: false
---
# Tmux & Zellij Modern Best Practices Plan

## Problem Analysis

Your tmux 3.6a config is missing several modern settings that cause:
1. **Shift+Enter eaten** -- tmux doesn't forward kitty keyboard protocol sequences (e.g. `\x1b[13;2u`) to inner panes. Claude Code, OpenCode, etc. need these.
2. **No discoverability** -- no way to discover available keybindings without memorization.
3. **Missing modern defaults** -- no escape-time, no true color, no clipboard (OSC 52), no focus-events.
4. **Zellij has the same issue** -- default keybindings collide with inner applications.

## Recommendation Summary

### 1. Fix Coding Agent Key Conflicts (Critical)

Add to `dot_tmux.conf`:

```tmux
set -g extended-keys always
set -as terminal-features 'xterm*:extkeys'
```

- `extended-keys always` forces tmux to forward modifier key sequences unconditionally (not just when the inner app requests them).
- This fixes Shift+Enter, Ctrl+Enter, and other modified keys needed by Claude Code, Neovim, etc.

Your Alacritty already sends `\u001b[13;2u` for Shift+Enter (line 11 in `alacritty.toml`), so this completes the chain: Alacritty -> tmux (passthrough) -> Claude Code.

### 2. Modern tmux Settings

```tmux
set -sg escape-time 0          # No ESC delay (critical for Neovim)
set -g history-limit 50000     # Larger scrollback
set -g focus-events on         # Vim autoread compatibility
set -g base-index 1            # 1-indexed windows (ergonomic)
setw -g pane-base-index 1      # 1-indexed panes
set -g renumber-windows on     # Renumber on close
set -as terminal-features ",xterm-256color:RGB"  # True color
set -g set-clipboard on        # OSC 52 clipboard (works over SSH)
set -g allow-passthrough on    # OSC passthrough for images, etc.
```

### 3. Which-Key Plugin (Recommended: tmux-which-key)

**tmux-which-key** is the best choice because:
- Closest to which-key.nvim experience (popup + mnemonic keys)
- Works with TPM (you already use it)
- YAML configuration is easy to maintain via chezmoi
- `Ctrl+Space` root trigger or `prefix + Space`
- No conflict with your current sesh bindings (prefix + T/L/9)
- **Note**: Requires `coreutils` on macOS (you already have Homebrew)

Add to TPM plugins:
```tmux
set -g @plugin 'alexwforsythe/tmux-which-key'
```

The default config includes menus for: Windows, Panes, Sessions, Layouts, Client, Plugins. You can customize via `config.yaml`.

**tmux-menus** (480 stars) is a decent alternative if you want pre-built menus out of the box, but tmux-which-key's popup-with-nested-menus pattern is more aligned with the which-key.nvim experience you want.

### 4. Prefix Key Decision

Three options:

- **Keep `Ctrl+B` (default)** -- no conflicts, but less ergonomic
- **Change to `Ctrl+A`** -- most popular alternative, home row, but conflicts with readline "go to beginning of line" (`Ctrl+A` in shell)
- **Keep `Ctrl+B` + use tmux-which-key via `Ctrl+Space`** -- best of both worlds: prefix stays default, but most actions go through the which-key popup. No readline conflict.

**Recommendation**: Keep `Ctrl+B` as prefix, use `Ctrl+Space` (tmux-which-key root binding) as the primary interaction method. This avoids all conflicts and gives you the which-key.nvim experience.

**Caveat**: If you use Ctrl+Space for Input Method switching (e.g. McBopomofo/RIME), you'll need to change the tmux-which-key root binding. Since you have input_method support, consider changing it to e.g. `Ctrl+\` or disabling the root binding and just using `prefix + Space`.

### 5. Vim-Style Pane Navigation

```tmux
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
```

Or use tmux-which-key's built-in pane submenu (p -> h/j/k/l).

### 6. Zellij Configuration

Create `dot_config/zellij/config.kdl` with:

```kdl
keybinds {
    unbind "Ctrl h"  // free up for coding agents
}
theme "default"
simplified_ui true
// Use unlock-first preset to avoid key collisions
```

The **unlock-first (non-colliding) preset** (Zellij 0.41+) is the solution: all Zellij actions require `Ctrl+G` first to "unlock", then the mode key. This prevents Zellij from eating any keys in normal mode.

However, Zellij's unlock-first preset must be selected interactively on first run (no config file option yet). The alternative is manually rebinding all conflicting keys in `config.kdl`.

**Pragmatic recommendation**: Since you use both tmux and zellij, and tmux is your primary multiplexer (you have sesh, tmuxp, TPM), focus the effort on tmux. For zellij, just add a minimal config that reminds users to select unlock-first preset on first launch.

## Files to Change

- **`dot_tmux.conf`** -- Add modern settings, extended-keys, tmux-which-key plugin, vim nav, OSC 52 clipboard
- **`dot_config/zellij/config.kdl`** (new) -- Minimal zellij config with key conflict notes
- **`dot_ansible/roles/devtools/tasks/main.yml`** -- Add `coreutils` to macOS brew list (needed for tmux-which-key on macOS)
- **`run_onchange_after_20_ansible_roles.sh.tmpl`** -- Update hash if devtools role changes
- **`README.md`** / **`CLAUDE.md`** -- Document tmux keybinding setup

## Questions Before Proceeding

1. Do you use `Ctrl+Space` for input method switching? If yes, we'll use `prefix + Space` only for tmux-which-key (disable root `Ctrl+Space` binding).
2. Do you want to change the prefix from `Ctrl+B` to `Ctrl+A`, or keep `Ctrl+B`?
3. For zellij, should we create a full `config.kdl` with manually rebound keys, or just a minimal one with documentation?
