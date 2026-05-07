# tmux `extended-keys always` corrupts ble.sh paste with `^[[106;5u`

## Symptom

Paste a multi-line snippet (e.g. a few diagnostic commands) into a bash
shell running under tmux + ble.sh. Instead of the expected:

```bash
uname -r
ldd --version
gcc --version
```

…the prompt buffer shows everything mashed together with `^[[106;5u`
between each line:

```
> uname -r^[[106;5uldd --version^[[106;5ugcc --version^[[106;5upython3 --version^[[106;5ufree -h^[[106;5ulsblk^[[106;5unvidia-smi^[[106;5unumactl --hardware
uname: invalid option -- '['
ry 'uname --help' for more information.
bash: 5uldd: command not found...
bash: 5ugcc: command not found...
bash: 5upython3: command not found...
bash: 5ufree: command not found...
bash: 5ulsblkommand not found...
bash: 5unvidia-smiommand not found...
bash: 5unumactl: command not found...
[ble: exit 127]
```

Each newline in the pasted content shows up as the literal escape
sequence `^[[106;5u` (CSI 106;5 u — "Ctrl+J encoded as CSI-u"). bash
then runs the whole thing as one mangled command line.

## Root cause

This repo's tmux config used to set:

```tmux
set -s extended-keys always
```

`always` mode forces tmux to re-encode **every** modifier+key combo as
CSI-u sequences, including ones that already have legacy encodings.
The relevant ones for paste:

| Key | Legacy encoding | CSI-u re-encoding under `always` |
|-----|----------------|----------------------------------|
| `Ctrl+J` | `\n` (LF, 0x0A) | `ESC [ 106 ; 5 u` |
| `Ctrl+M` | `\r` (CR, 0x0D) | `ESC [ 109 ; 5 u` |
| `Ctrl+I` | `\t` (TAB, 0x09) | `ESC [ 105 ; 5 u` |
| `Ctrl+@` | `\0` (NUL) | `ESC [ 64 ; 5 u` |

When the user pastes multi-line text, **the terminal sends the embedded
`\n` characters as Ctrl+J keystrokes**. tmux's `extended-keys always`
catches those and rewrites each one to `ESC[106;5u`. The bracketed-paste
markers (`ESC[200~ ... ESC[201~`) wrap the whole thing, but the
**inner** content is now a string of mixed visible characters and
CSI-u escapes — not the raw `\n` bytes ble.sh's paste handler expects.

ble.sh's bracketed-paste handler stuffs the content into the line
buffer **as-is**, so the user sees the literal `^[[106;5u` text.

The same issue would affect zsh-vi-mode and any other shell with a
bracketed-paste handler that doesn't normalize CSI-u back to legacy
encodings before insertion.

## Fix

Change tmux to `on` instead of `always`:

```tmux
set -s extended-keys on
```

`on` mode emits CSI-u **only** for keys that have no legacy encoding
(Shift+Enter, Ctrl+Enter, Ctrl+/, Ctrl+digit, Ctrl+Shift+letter).
Standard `Ctrl+letter` keys including `Ctrl+J` keep their legacy
single-byte encoding. Paste content stays as raw `\n` and goes into
the buffer correctly.

The TUIs that needed `extended-keys` in the first place (Claude Code,
Neovim, etc.) only ever needed it for the no-legacy-encoding keys
(Shift+Enter, Ctrl+Enter, Ctrl+/), so they continue to work under `on`.

## Verification

After applying the fix:

```bash
tmux source-file ~/.tmux.conf   # or open new tmux session
```

Paste a multi-line snippet. Each line should appear on its own line in
the buffer. ble.sh's vi-mode multi-line submit (`Ctrl+Enter` /
`Alt+Enter`, see `dot_config/bash/04_blesh.bash`) is unaffected.

Edge cases that still work under `on`:

- `Ctrl+Enter` in Claude Code → still gets CSI-u (no legacy encoding for
  that combo)
- `Shift+Enter` in Neovim → CSI-u
- `Ctrl+1..9` for tmux quick window switching → CSI-u (Ctrl+digit has no
  legacy encoding)
- `Ctrl+/` in Neovim (comment toggle) → CSI-u (legacy is `Ctrl+_`,
  which most TUIs don't decode)
- `Ctrl+H/J/K/L` for vim-tmux-navigator → legacy encoding (Ctrl+letter
  has clear ASCII bytes 0x08/0x0A/0x0B/0x0C), still works fine

## Why we didn't catch this earlier

`extended-keys always` was committed back when the repo's primary shell
was zsh, and zsh's bracketed-paste handler **does** normalize CSI-u
sequences back to their literal characters before buffer insertion (zsh
5.9+). The bug only surfaces when:

1. Primary shell is bash (`primaryShell=bash` in chezmoi prompt) **or**
   ad-hoc bash use is common
2. ble.sh is loaded (provides bracketed-paste support, but doesn't
   normalize CSI-u → legacy on paste insertion)
3. tmux's `extended-keys` is `always` (re-encodes paste-internal
   newlines)

The combination wasn't tested until a CentOS 7 corporate-server bring-up
where the user lived in bash + ble.sh for the bootstrap dance.

## Related

- [`dot_config/tmux/common.conf`](../dot_config/tmux/common.conf) —
  the one-line fix.
- [`CLAUDE.md`](../CLAUDE.md) "Key tmux settings for coding agents" —
  hard invariant updated to call out the `on` vs `always` distinction.
- [`dot_config/bash/04_blesh.bash`](../dot_config/bash/04_blesh.bash) —
  ble.sh + Ctrl+Enter / Alt+Enter accept-line bindings for multi-line
  submit (separate concern from this paste-corruption issue).
- [`pitfalls/tmux-display-menu-silent-fail.md`](tmux-display-menu-silent-fail.md) —
  unrelated CSI-u / extended-keys red herring (display-menu silent
  failure was misdiagnosed as a CSI-u issue for hours).
- tmux man page: `man tmux` → `extended-keys` (default behaviour and
  the difference between `on` / `always`).
