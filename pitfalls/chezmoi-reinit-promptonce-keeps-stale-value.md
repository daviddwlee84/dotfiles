# `chezmoi init --promptBool/String/Choice` silently keeps the OLD value on re-init

**Symptoms** (grep this section): re-running `chezmoi init` / `dotfiles_init.py` on an already-configured machine doesn't change a setting; `installX` flag stays `true` after passing `--promptBool "...=false"`; `~/.config/chezmoi/chezmoi.toml` `[data]` value never updates; `chezmoi data` still shows the stale value after a re-apply
**First seen**: 2026-06
**Affects**: chezmoi v2.69.x (all versions using `prompt*Once`); any `.chezmoi.$FORMAT.tmpl` driven by `promptBoolOnce` / `promptStringOnce` / `promptChoiceOnce`
**Status**: fixed in this repo (`init` re-init branch + `reconfigure` subcommand both pass `--prompt`)

## Symptom

You re-run the init wrapper (or bare `chezmoi init`) on a machine that already
has `~/.config/chezmoi/chezmoi.toml`, passing an override flag to flip a
setting, but the value never changes. Verbatim reproduction (read-only, no
state mutated):

```console
$ chezmoi data | grep installLlmTools
  "installLlmTools": true,

$ printf '{{ promptBoolOnce . "installLlmTools" "P" false }}' \
    | chezmoi execute-template --init --promptBool "P=false"
true        # ← the stored `true` wins; the --promptBool flag is IGNORED
```

It looks like the flag should pre-answer the prompt, but the answer never
takes — and there's no error, so it's easy to conclude "chezmoi is broken" or
to start hand-editing `chezmoi.toml`.

## Root cause

`promptBoolOnce map path prompt [default]` returns `map.path` **if it already
exists**, and only falls through to `promptBool` when it doesn't. On re-init,
`.` (the map) is the existing config's `[data]`, so the key exists and the
function short-circuits — it never consults the `--promptBool` pairs at all.

`--promptBool` / `--promptString` / `--promptChoice` only populate the
underlying `promptBool` lookup, which the `-Once` variant skips. So the flags
are dead weight on re-init unless something forces the prompt to actually fire.

That "something" is the `chezmoi init --prompt` flag:

> `--prompt` — Force `prompt*Once` template functions to prompt.

With `--prompt`, every `-Once` call re-fires; the `--promptX` flags then
satisfy them non-interactively and the new values are written.

```console
$ chezmoi init --apply --prompt --promptBool "...=false" …
            # now the flag wins and [data] is rewritten
```

(`chezmoi init --force` overwrites the config FILE but does not by itself force
the `-Once` calls to re-prompt — `--prompt` is the correct knob.)

## Workaround

Always pass `--prompt` together with a COMPLETE set of `--promptX` flags (one
per applicable prompt — `--prompt` re-fires all of them, so any prompt without
a matching flag falls back to interactive). In this repo, use the tooling that
already does this:

```bash
just reconfigure                                   # interactive, seeded from current values
just reconfigure -- --set installLlmTools=false --yes   # non-interactive single key
czcfg --set noRoot=true --yes                      # shell wrapper
```

## Prevention

`scripts/init/dotfiles_init.py`:

- `build_chezmoi_argv(..., prompt=...)` injects `--prompt`.
- `run_init` passes `prompt=pf.source_exists` (re-init only — a fresh init has
  no stored values, so it must NOT force-prompt or it would re-ask everything).
- `run_reconfigure` always passes `prompt=True` and seeds answers from
  `read_current_config()` so untouched options keep their live values.

Do not "fix" a stuck setting by editing `~/.config/chezmoi/chezmoi.toml` by
hand — that bypasses chezmoi's type validation and re-init semantics.

## Related

- `scripts/init/README.md` → "Re-init semantics" (the empirical test above).
- `pitfalls/chezmoi-init-prompt-flag-mismatch.md` — sibling trap: flags matched
  by prompt TEXT (not key) and type-strict; a wrong text/type is silently
  ignored even on a fresh init.
- chezmoi docs: [`promptBoolOnce`](https://chezmoi.io/reference/templates/init-functions/promptBoolOnce/),
  [`init --prompt`](https://chezmoi.io/reference/commands/init/).
