# tmux `Ctrl+1`..`Ctrl+9` dead in iSH, and `Ctrl+2` fires the wrong binding

**Symptoms** (grep this section): `Ctrl+1` / `C-1` window switching does nothing in tmux inside iSH on iOS; `Ctrl+2` unexpectedly toggles the last pane or triggers a `C-Space` binding; `Ctrl+6` behaves like `C-^`; Shift+Enter does nothing in Claude Code; mouse wheel / touch scroll never enters tmux copy-mode; no error message anywhere
**First seen**: 2026-07
**Affects**: tmux inside iSH (iOS), any build incl. 812, with this repo's `dot_config/tmux/common.conf.tmpl`
**Status**: workaround documented (hand-trim `~/.tmux.conf` on the device). Upstream hterm marks the sequence "Won't support". Not reproduced on-device by us; derived from iSH sources + upstream issues.

## Symptom

Run tmux inside iSH with this repo's config and the digit bindings are gone:

- `Ctrl+1` … `Ctrl+9` (quick window switching) do **nothing at all**.
- `Ctrl+2` and `Ctrl+6` *do* something — but the wrong thing. They arrive as
  legacy `C-Space` (0x00) and `C-^` (0x1E), so they fire whatever else is bound
  to those keys.
- `Shift+Enter` in Claude Code inserts nothing (no newline, no submit).
- Mouse wheel and two-finger scroll never enter copy-mode, despite
  `set -g mouse on`.

Nothing is logged. `tmux show -s extended-keys` reports `on`, and
`tmux display -p '#{client_termname}'` reports `xterm-256color`, so everything
*looks* correct.

## Root cause

Two independent false-positive capability reports.

**1. `TERM` lies, so the feature match succeeds.** iSH hardcodes
`TERM=xterm-256color`. This repo's config
([`dot_config/tmux/common.conf.tmpl`](../dot_config/tmux/common.conf.tmpl))
says:

```tmux
set -s extended-keys on
if-shell 'tmux -V | grep -qE "tmux ([3-9]\.[5-9]|[3-9]\.[1-9][0-9]|[4-9]\.)"' \
  'set -s extended-keys-format csi-u'
set -as terminal-features 'xterm*:extkeys'
```

`xterm*` matches, so tmux believes the outer terminal speaks extended keys and
emits the enable sequence `CSI > 4 ; 1 m`. iSH's terminal is hterm-derived, and
hterm's upstream documentation marks `CSI > Pm m` as **"Won't support"**. The
enable is swallowed silently; tmux never learns it failed.

**2. iSH has no CSI-u path at all.** Grepping the iSH tree for CSI-u /
modifyOtherKeys / kitty-keyboard returns zero hits. Key encoding is done
natively via an enumerated `UIKeyCommand` table: `Ctrl+letter` becomes a legacy
`toupper(ch) ^ 0x40` control byte, `Alt+key` becomes an ESC prefix, `Shift+key`
just uppercases. `controlKeys` contains only the digits `2` and `6`.

So:

| Key | Needs | What iSH sends | Result |
|---|---|---|---|
| `Ctrl+1`, `3`..`5`, `7`..`9` | CSI-u (no legacy encoding) | nothing | binding dead |
| `Ctrl+2` | CSI-u | legacy `C-Space` 0x00 | **fires the `C-Space` binding** |
| `Ctrl+6` | CSI-u | legacy `C-^` 0x1E | **fires the `C-^` binding** |
| `Shift+Enter` | CSI-u `ESC[13;2u` | plain CR | indistinguishable from Enter |

The mouse failure is separate and unrelated to keys: iSH overrides hterm's
touch handler, so scroll events never reach the tty at all (ish-app/ish#2537,
#2375, #2708 — no fix).

**Why this is worse than an unsupported feature.** `Ctrl+2` and `Ctrl+6` not
failing silently is the trap. A dead key gets reported as "doesn't work"; a key
that quietly triggers *a different action* gets reported as "tmux is haunted".

## Workaround

Do not deploy this repo's tmux config to iSH. Hand-write a minimal
`~/.tmux.conf` **on the device**:

```tmux
# iSH: TERM lies about extended-keys support. Leaving these on breaks
# Ctrl+digit and makes Ctrl+2 / Ctrl+6 fire the wrong bindings.
set -s extended-keys off
# (and do NOT set terminal-features '...:extkeys')

# Ctrl+digit cannot be delivered at all here — use the prefix form.
# prefix + 1..9 works normally; no bind lines needed.

# Touch/scroll events never reach the tty; leaving mouse on only makes
# copy-mode harder to drive by keyboard.
setw -g mouse off

# This one DOES work — keep it.
set -g set-clipboard on
```

Then use `prefix + 1..9` for window switching and `Ctrl+J` instead of
`Shift+Enter` in Claude Code (`Ctrl+J` is LF and needs no CSI-u anywhere).

## Prevention

**Generalisable rule: `terminal-features` matching on `TERM` is a capability
*claim*, not a probe.** Any terminal that hardcodes a well-known `TERM` while
implementing a subset will produce this class of bug. When adding a
`terminal-features` entry, prefer naming the specific terminal
(`ghostty*`, `alacritty*`) over broad `xterm*` globs where practical.

Do not "fix" this by switching to `extended-keys always` — that has its own,
worse failure mode; see
[`pitfalls/tmux-extended-keys-always-paste.md`](tmux-extended-keys-always-paste.md).

The repo-level decision is to **not** support iSH as a deployment target at
all; the ios-terminals playbook records why, and the bootstrap script for iSH
deliberately does not install this repo's tmux config.

## Related

- [`docs/playbooks/ios-terminals.md`](../docs/playbooks/ios-terminals.md) — why
  this repo is not deployed to iSH, and the SSH-client comparison (client-side
  CSI-u support is the deciding column)
- [`pitfalls/tmux-extended-keys-always-paste.md`](tmux-extended-keys-always-paste.md)
  — the `on` vs `always` distinction, and why `always` is not the answer
- [`pitfalls/ish-illegal-instruction-despite-sse2.md`](ish-illegal-instruction-despite-sse2.md)
  — the other iSH false-positive capability report
- [`CLAUDE.md`](../CLAUDE.md) "Key tmux settings for coding agents"
- Upstream: ish-app/ish#2537, #2375, #2708 (mouse); hterm control-sequence docs
  (`CSI > Pm m` → "Won't support")
