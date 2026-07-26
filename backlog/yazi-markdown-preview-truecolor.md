# yazi Markdown preview: getting glow's native 256-colour output

**Status**: shipped a working 16-colour fix; the 256-colour upgrade is deferred.
**TODO tag**: `[S]` under `P3`.
**Ships today**: `dot_config/yazi/yazi.toml` → `{ url = "*.md", run = 'piper -- CLICOLOR_FORCE=1 glow -w "$w" -s "$t" "$1" 2>/dev/null || cat "$1"' }`

## Context

yazi previews `.md` through `piper.yazi` → `glow`. piper spawns the child with
`stdout(Command.PIPED)` — a pipe, never a pty. glow renders via
glamour → lipgloss → **termenv**, and termenv chooses its colour profile by
probing stdout:

| stdout | termenv profile | glow emits |
|---|---|---|
| pipe, no override | `Ascii` | `ESC[;;1m` — attributes only, **every colour component stripped** |
| pipe + `CLICOLOR_FORCE=1` | `ANSI` (16 colours) | `ESC[37m`, `ESC[93;104;1m` |
| real pty | `ANSI256` | `ESC[38;5;252m`, `ESC[38;5;228;48;5;63;1m` |

That first row is the "formatted but monochrome" bug: structure renders (bold and
reverse survive) while the colour looks broken. `CLICOLOR_FORCE=1` fixes it — and
is what upstream [`glow.yazi`](https://github.com/Reledia/glow.yazi) sets too.

## What was measured

Forcing termenv out of an `Ascii` detection lands on plain **ANSI-16**, never 256.
No environment tweak moves it — all of these produced byte-identical 16-colour output
on glow 2.1.1 / macOS:

```sh
CLICOLOR_FORCE=1
CLICOLOR_FORCE=1 COLORTERM=truecolor
CLICOLOR_FORCE=1 TERM=xterm-256color COLORTERM=truecolor
CLICOLOR_FORCE=1 FORCE_COLOR=3 COLORTERM=truecolor
FORCE_COLOR=3                      # no effect at all — not a termenv variable
```

Only a real pty reaches 256-colour (confirmed with `python3 -c 'import pty; pty.spawn([...])'`).

## Options for 256-colour

1. **`script(1)` wrapper** — the portable-ish pty allocator. Blocked on syntax
   divergence: BSD/macOS is `script -q /dev/null cmd args…`, util-linux wants
   `script -qec "cmd args…" /dev/null`. Encoding an OS switch inside a yazi
   previewer string (already single-quoted and containing `"$1"`) is nasty, and pty
   output carries `\r\n` so it needs a `| tr -d '\r'` that must not swallow piper's
   stderr contract.
2. **In-house `view-markdown` launcher** doing the pty allocation in Python. Clean,
   but per the repo contract a new `dot_dotfiles/bin/executable_*` drags in two
   completion files, a `docs/zsh/zsh-completions.md` § F row and an aliases row —
   a lot of surface for a colour-depth nicety.
3. **Custom glamour style JSON** (`glow -s /path/to/style.json`) — does **not**
   help. Quantisation happens after style resolution, so a hand-tuned palette gets
   flattened to the same 16 colours.

## Why deferred

ANSI-16 is not obviously worse in this repo's setup: those 16 slots come from the
terminal's own palette, so the preview tracks the active Ghostty/tmux theme instead
of glow's hardcoded 256-colour ramp. The remaining gap is a subtle gradient
difference on headings and code spans. Revisit if glow ever grows a
`--color-profile` flag (which would collapse this to a one-token change), or if
option 2 becomes cheap because a `view-markdown` CLI is wanted for other reasons.

## Related

- [`docs/tools/yazi-previews.md` § Markdown](../docs/tools/yazi-previews.md) — the shipped behaviour
- `dot_config/yazi/yazi.toml` `[plugin] prepend_previewers` — the rules themselves
- termenv's profile logic: `EnvColorProfile()` → forced-out-of-`Ascii` returns `ANSI`
