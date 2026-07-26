# `[bat warning]: Unknown theme 'tokyonight_night'` on every bat/delta call, forever

**Symptoms** (grep this section): `[bat warning]: Unknown theme 'tokyonight_night', using default.` printed on EVERY `bat` invocation and every `git diff` / `git show` render (delta embeds bat); the warning line leaks into fzf / `tv` / yazi previews that shell out to bat; `bat --list-themes | grep tokyonight` prints nothing; `ls "$(bat --cache-dir)"` says `No such file or directory`; `~/.config/bat/themes/tokyonight_night.tmTheme` **is** present and chezmoi-managed; repeated `chezmoi apply` runs never fix it and print nothing about bat.
**First seen**: 2026-07
**Affects**: any host where `~/.cache/bat` was cleared or invalidated after the first successful apply — i.e. all of them, eventually.
**Status**: fixed (run-script converted from `run_onchange_after_` to a self-healing `run_after_`, plus a shell-side guard).

## Symptom

```console
$ git diff
[bat warning]: Unknown theme 'tokyonight_night', using default.
...

$ bat --list-themes | grep -i tokyo
$ ls "$(bat --cache-dir)"
ls: /Users/david/.cache/bat: No such file or directory

$ ls ~/.config/bat/themes/
tokyonight_night.tmTheme          # the source IS there

$ chezmoi apply                   # …and this never fixes it
```

The confusing part is that everything chezmoi owns looks correct. `chezmoi status`
is clean, the `.tmTheme` file is deployed, `BAT_THEME` is exported — and the warning
still fires on every single command that renders a diff.

Note the warning only appears on the **highlighting** path: with color off
(`bat file.md | cat`, or a non-tty without `--color=always`) bat never looks the
theme up, so a quick check can look deceptively healthy. Reproduce it with:

```sh
BAT_THEME=tokyonight_night bat --color=always --style=plain --language=md <<< '# hi'
```

## Root cause

Two independent things have to be true for a custom bat theme to work, and only
one of them is under chezmoi's control:

| Thing | Owner | Lives in |
|---|---|---|
| `tokyonight_night.tmTheme` source | chezmoi (`dot_config/bat/themes/`) | `~/.config/bat/themes/` |
| the **compiled** theme cache | `bat cache --build` | `~/.cache/bat/{themes,syntaxes}.bin` |

bat does *not* read `.tmTheme` files at runtime. It only reads the bincode cache,
which must be regenerated with `bat cache --build`.

The rebuild used to live in `run_onchange_after_25_bat_theme.sh.tmpl`, hash-gated
on the content of the `.tmTheme` file:

```sh
# bat theme: {{ include "dot_config/bat/themes/tokyonight_night.tmTheme" | sha256sum }}
```

That gate is wrong, because **the cache gets destroyed by events that never touch
the theme file**, so the hash never changes and the script never re-runs:

- `bat cache --clear` — the documented recovery for
  [`git-delta-empty-stdin-huge-allocation`](git-delta-empty-stdin-huge-allocation.md)
- the *same script's own* delta health check, which clears the cache when the
  installed bat/delta pair is incompatible — a guaranteed one-way trip under the
  old gate: cleared once, never rebuilt, even after the host got a compatible
  bat/delta later
- wiping `~/.cache`, or restoring/syncing a `$HOME` that excludes it
- upgrading `bat`: the cache is bincode keyed to the writing bat version
  (`~/.cache/bat/metadata.yaml` → `bat_version:`), so the new binary ignores a
  cache written by the old one

Once in that state, the only escape was to know to run `bat cache --build` by
hand. `chezmoi apply` — the thing you'd naturally reach for — was a no-op.

## Workaround

Immediate, on any host:

```sh
bat cache --build
bat --list-themes | grep -qx tokyonight_night && echo ok
```

## Prevention

Two fixes, both in this repo:

1. **`.chezmoiscripts/global/run_after_25_bat_theme.sh.tmpl`** (renamed from
   `run_onchange_after_25_…`) now runs on **every** apply and decides for itself
   whether a rebuild is needed. State outside chezmoi's control cannot be
   hash-gated on state inside it. Its fast path is 3 `bat` invocations + 2 stats
   (~150 ms) and rebuilds only when any of these fail:
   - `~/.cache/bat/themes.bin` exists
   - `metadata.yaml` records the *currently installed* bat version
   - `themes.bin` is not older than the `.tmTheme` source

   When the delta health check does clear the cache, the script writes a
   `bat=<ver> delta=<ver>` stamp to `~/.cache/chezmoi/bat-cache-delta-incompatible`
   so it doesn't rebuild-then-clear on every apply forever. Upgrading either tool
   changes the key and the pair is retried automatically.

2. **`dot_config/shell/25_bat.sh`** only exports `BAT_THEME` when the compiled
   cache *and* the `.tmTheme` file are both present. On a host that legitimately
   has no cache (fresh box before first apply, or a delta-incompatible pair), bat
   silently falls back to its own default instead of warning on every invocation.
   The pitfall above says "that warning is preferable to the crash" — it is, but
   not exporting the variable is better than both.

**Generalisable rule**: a `run_onchange_` hash is only valid when the *effect* of
the script lives somewhere chezmoi tracks. If the script's product is a cache, a
compiled artifact, or anything else outside the target-state tree, use `run_after_`
plus an explicit freshness check. Same reasoning as
`run_after_50_generate_completions.sh.tmpl` (binary-mtime check for tools that
upgrade between applies).

## Related

- [`git-delta-empty-stdin-huge-allocation.md`](git-delta-empty-stdin-huge-allocation.md)
  — the crash whose recovery (`bat cache --clear`) is one way to land here
- [`docs/tools/git_diff_workflow.md`](../docs/tools/git_diff_workflow.md) — the
  delta / diffnav / gh-dash stack that consumes the theme
- `.chezmoiscripts/global/run_after_50_generate_completions.sh.tmpl` — same
  "`run_after_` + explicit freshness check" shape, for the same class of reason
