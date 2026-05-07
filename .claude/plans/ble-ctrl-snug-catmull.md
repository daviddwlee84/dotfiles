# Plan: Fix ble.sh multiline submit and Ctrl+C discard

## Context

Two usability issues reported with ble.sh in bash vi-mode:

1. **Ctrl+Enter doesn't submit multi-line commands** — The binding `C-RET → accept-line` exists in `vi_imap`/`vi_nmap`, but multi-line pastes stay stuck. The most likely cause: the terminal or tmux is not forwarding the CSI-u sequence `\e[13;5u` to ble.sh in a way it decodes to the named keysym `C-RET`. Since `accept-line` *bypasses* the multiline check (submits unconditionally), the logic is correct — the key just isn't arriving.

2. **Ctrl+C in vi-mode shows `:q` prompt** — ble.sh default bindings (line 6388 of `keymap.vi.sh`): insert-mode C-c calls `vi_imap/normal-mode-without-insert-leave` (enters normal mode); normal-mode C-c (line 4754) calls `vi-command/cancel` which displays the vim-style `:q` dialog. The user wants normal-mode C-c to discard the buffer and return a fresh prompt (bash/zsh muscle memory).

## Critical files

- `dot_config/bash/04_blesh.bash` — the only file to edit
- `~/.local/share/blesh/lib/keymap.vi.sh` — ble.sh source reference (read-only, no edit)

## Implementation

### Change 1 — Multiline submit: add S-RET + raw CSI-u fallbacks

Keep the existing `C-RET` bindings. Add:
- **`S-RET` (Shift+Enter)** bindings — the user asked whether this is better. Ghostty + tmux `extended-keys on` forwards `\e[13;2u`; it is generally more reliably emitted than `\e[13;5u` by terminal emulators.
- **Raw escape sequence fallbacks** — `$'\e[13;5u'` (C-RET in CSI-u) and `$'\e[13;2u'` (S-RET in CSI-u). These match even if ble.sh's named-keysym decoder doesn't map the sequence to `C-RET`/`S-RET`.

Widget stays `accept-line` (not `accept-single-line-or-newline` — that would *insert* a newline in multiline mode, which is the opposite of what we want).

Replace the existing multiline-submit block (lines 26–50) with:

```bash
# === Multi-line submit: Ctrl+Enter / Shift+Enter ===
#
# In ble.sh vi-mode, plain RET in multiline buffers inserts a newline
# (safe default). We want Ctrl+Enter OR Shift+Enter to always submit.
# accept-line bypasses the single-line check — correct for an explicit
# "submit now" key.
#
# Key encoding path:
#   Terminal emits CSI-u: \e[13;5u (C-RET) or \e[13;2u (S-RET)
#   tmux forwards via extended-keys on + terminal-features xterm*:extkeys
#   ble.sh decodes to named keysym C-RET / S-RET
#
# We bind both the named keysyms (-f flag) AND the raw escape sequences
# as belt-and-suspenders in case the decoder chain drops a link.
#
# Ctrl+Enter / Shift+Enter collisions: none on this stack.
# tmux C-j (vim-tmux-navigator) eats plain C-j; C-RET and S-RET use
# distinct CSI-u codes that tmux forwards intact.
ble-bind -m vi_imap -f 'C-RET' accept-line
ble-bind -m vi_nmap -f 'C-RET' accept-line
ble-bind -m vi_imap -f 'S-RET' accept-line
ble-bind -m vi_nmap -f 'S-RET' accept-line
# Raw CSI-u fallbacks (belt and suspenders)
ble-bind -m vi_imap $'\e[13;5u' accept-line  # C-RET raw
ble-bind -m vi_nmap $'\e[13;5u' accept-line
ble-bind -m vi_imap $'\e[13;2u' accept-line  # S-RET raw
ble-bind -m vi_nmap $'\e[13;2u' accept-line
```

Remove the `M-RET` fallback lines (49–50) — Alt+Enter is only needed for terminals that can't emit CSI-u at all; S-RET raw covers that use-case better and doesn't risk colliding with future Alt-key widgets.

### Change 2 — Ctrl+C in both vi maps: discard like zsh

Desired behaviour (matches zsh insert-mode C-c):
- Typed text stays visible in the terminal scroll buffer (can copy it)
- `^C` marker appears on the line
- A fresh prompt is shown immediately
- **No normal-mode transition** — Escape still handles that

ble.sh default bindings being overridden:
- `vi_imap C-c` → `vi_imap/normal-mode-without-insert-leave` (enters normal mode) — override to `discard-line`
- `vi_nmap C-c` → `vi-command/cancel` (shows `:q` dialog) — override to `discard-line`

Add a new section after the mouse-nop block:

```bash
# === Ctrl+C: discard buffer (zsh / bash muscle memory) ===
#
# ble.sh vi-mode defaults:
#   vi_imap C-c → enter normal mode (vi behaviour)
#   vi_nmap C-c → vi-command/cancel (:q prompt)
#
# Desired: match zsh insert-mode C-c — cancel the line, keep old text
# visible in the scroll buffer (can still copy it), show a fresh prompt.
# Escape still transitions insert → normal mode as expected by vi muscle
# memory; C-c is now unconditionally "cancel and new prompt" from either
# mode.
ble-bind -m vi_imap -f 'C-c' discard-line
ble-bind -m vi_nmap -f 'C-c' discard-line
```

## Verification

After `chezmoi apply` and opening a fresh bash session:

1. **Multiline Shift+Enter**: paste or type a multi-line block (use `<RET>` between lines in insert mode), then press Shift+Enter → command submits.
2. **Multiline Ctrl+Enter**: same test; should also submit if terminal forwards CSI-u.
3. **Single-line Enter**: plain Enter still submits (unchanged widget).
4. **C-c from insert mode**: type something, press C-c → old text visible above, fresh prompt (no mode transition).
5. **C-c from normal mode** (entered via Escape): press Escape then C-c → same cancel behaviour.
6. **Escape still works for normal mode**: press Escape while typing → enters normal mode as usual.
7. **Confirm bindings active**: `ble-bind -P | grep -E 'RET|C-c'` in a live bash session.
