# OSC 52 Clipboard Sync — Optimization Plan

## Context

The user wants remote-SSH Neovim `yank` to land in the **local (client) machine's** system clipboard, so copied text can be pasted into other apps outside Vim. Current repo state:

| Layer | Status |
|-------|--------|
| tmux (`dot_config/tmux/common.conf:79,82`) | ✅ `set -g set-clipboard on`, `set -g allow-passthrough on` |
| tmux `terminal-features` | ⚠️ Only `RGB` + `extkeys` declared — no explicit `clipboard` feature |
| Ghostty (`dot_config/ghostty/config`) | ⚠️ Relies on defaults (`clipboard-write = allow`, `clipboard-read = ask`) |
| Alacritty (`dot_config/alacritty/alacritty.toml`) | ✅ Native OSC 52 support, no special config needed |
| **Neovim** (`dot_config/nvim/lua/config/options.lua`) | ❌ **Empty** — no `clipboard` / `g.clipboard` set; LazyVim defaults to local `pbcopy`/`xclip` which break over SSH |
| zsh | No clipboard hooks (not needed) |

**Root cause of the pain point**: the tmux side is already correct, but Neovim itself never routes its `+` register through OSC 52 when running on a remote host. Over SSH, the default provider tries to call `pbcopy`/`xclip` on the **remote** box, so yanks vanish from the local clipboard's perspective.

**Minor correction to the external advice pasted by the user**:
- `vim.g.clipboard = "osc52"` (string form) is **not** a stable Neovim API. The canonical form is the explicit table using `require("vim.ui.clipboard.osc52")` — supported since Neovim 0.10, matches the repo's `>= 0.11.2` requirement.
- `set -s set-clipboard external` is wrong scope: `set-clipboard` is a session option (`-g`), not a server option (`-s`). Current `set -g set-clipboard on` is already fine — no change needed there.
- In tmux 3.2+, the clean way to signal OSC 52 support is `terminal-features …:clipboard`, not an `Ms=` `terminal-overrides` override.

**Intended outcome**: yank inside remote Neovim (with or without tmux) puts text into the local macOS/Linux clipboard, pasteable into any app.

---

## Changes

### 1. Neovim — add OSC 52 clipboard provider (primary fix)

**File**: `dot_config/nvim/lua/config/options.lua`

Replace the empty file body with:

```lua
-- Options are automatically loaded before lazy.nvim startup
-- Default options: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua

-- System clipboard integration
vim.opt.clipboard = "unnamedplus"

-- Over SSH, route the + and * registers through OSC 52 so yanks reach
-- the LOCAL terminal's clipboard (pbcopy/xclip on the remote are useless here).
-- Locally (no SSH), keep LazyVim's default provider (pbcopy on macOS, etc.)
-- which also supports paste.
if vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
end
```

**Why SSH-conditional instead of always-on**: OSC 52 *paste* is poorly supported by many terminals (Ghostty prompts, Alacritty doesn't read at all). Keeping the local provider for local sessions preserves normal paste behaviour; forcing OSC 52 only when needed.

### 2. tmux — declare the `clipboard` terminal feature (defensive)

**File**: `dot_config/tmux/common.conf` (near line 70, next to the existing `terminal-features`)

Add one line after line 70:

```tmux
set -as terminal-features ",xterm-256color:clipboard"
set -as terminal-features ",ghostty*:clipboard"
set -as terminal-features ",alacritty*:clipboard"
```

**Why**: tmux 3.2+ enables OSC 52 only if it believes the outer terminal supports it. For most modern terminals it auto-detects, but explicit declarations make the behaviour independent of the shipped terminfo on a given host. `set -g set-clipboard on` on line 79 stays as-is.

### 3. Ghostty — pin the clipboard policy explicitly (optional but recommended)

**File**: `dot_config/ghostty/config`

Append:

```conf
# OSC 52 clipboard policy
# - write: allow inner apps (Neovim via OSC 52) to set the system clipboard
# - read: keep the default "ask" (safer — apps can't silently exfiltrate)
clipboard-write = allow
clipboard-read = ask
```

Both values match current defaults, but making them explicit prevents surprises if Ghostty upstream changes defaults, and serves as self-documentation.

### 4. Documentation updates

- **`docs/tools/tmux/README.md`** — extend the existing "OSC 52 clipboard and OSC passthrough enabled" note with a short troubleshooting sub-section: how to verify with `tmux info | grep -E 'Ms|clipboard'`, and reminder that `tmux kill-server` is needed for config changes to a running server.
- **`CLAUDE.md`** → Tmux Configuration → "Key Settings for Coding Agents" — extend the `set-clipboard on` line to mention the Neovim-side pairing.
- **`README.md`** — under "What You Get > Config Files", add a one-liner mentioning OSC 52 remote-clipboard behaviour (per the repo rule about keeping README.md in sync).

### 5. (Deferred — not doing now)

`dot_config/tmux/keybindings.conf` has `prefix + y / Y / C-y` that call `pbcopy/xclip/xsel` directly (lines 79–110). These also break over SSH (they shell out on the remote host). A cleaner fix would be to route them through `load-buffer -b … ; paste-buffer` relying on `set-clipboard on` to emit OSC 52. **Not in scope for this plan** — the user's explicit pain point is Neovim yank, and changing those bindings risks regressing local behaviour. Flagged here for a possible follow-up.

---

## Critical files

| File | Change |
|------|--------|
| `dot_config/nvim/lua/config/options.lua` | **Primary** — add `unnamedplus` + SSH-conditional `vim.g.clipboard` |
| `dot_config/tmux/common.conf` | Add `terminal-features :clipboard` for common terminals |
| `dot_config/ghostty/config` | Pin `clipboard-write`/`clipboard-read` explicitly |
| `docs/tools/tmux/README.md` | Troubleshooting sub-section |
| `CLAUDE.md` | One-line note under tmux Key Settings |
| `README.md` | One-liner under Config Files |

No new plugins, no new ansible roles, no chezmoi templates touched.

---

## Verification

After `chezmoi apply`, on **local macOS** first (baseline):

1. `nvim /tmp/test.txt` → type a line → `yy` → switch to another app (browser) → `Cmd+V` → should paste. Confirms local provider still works (outside SSH, we did not change anything).

Then, on a **remote Linux box over SSH** (reproduces the user's pain point):

2. **Without tmux**: `ssh remote-box`, `nvim /tmp/x`, type + `yy`, then `Cmd+V` into a local macOS app → should paste.
3. **With tmux on the remote**: `ssh remote-box -t tmux new -A`, `nvim /tmp/x`, type + `yy`, `Cmd+V` locally → should paste.
4. Run on the remote:

   ```bash
   tmux info | grep -Ei 'ms|clipboard'
   echo "$TERM"
   ```

   Expect a `clipboard: true` / `Ms: \E]52;...` entry (not `[missing]`).
5. `:checkhealth provider.clipboard` inside Neovim on the remote — expect it to report the OSC 52 provider as active.

**Regression checks**:

- Local Neovim paste (`"+p`) should still work (we only override `g.clipboard` when `SSH_CONNECTION`/`SSH_TTY` is set).
- tmux copy-mode `y` → still copies to local clipboard (already worked; no change there).

---

## Non-goals

- No change to `set-clipboard` value (stays `on`).
- No new OSC 52 plugin (`ojroques/nvim-osc52`) — Neovim's builtin `vim.ui.clipboard.osc52` covers it.
- No tmux session-sharing / read-only-attach work (discussed in the pasted conversation but orthogonal to the yank problem).
- No changes to `prefix + y / Y / C-y` pane-capture bindings (deferred, see §5).
