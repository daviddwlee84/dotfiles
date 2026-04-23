# `local path=""` inside a zsh function silently breaks all external commands

**Symptoms** (grep this section):
- `zsh: command not found: <anything>` only when called from inside a specific shell function
- The same command works fine at the interactive prompt
- `which <cmd>` from the prompt prints the absolute path
- `hash -r` / `rehash` does NOT fix it
- Function-local `path` / `cdpath` / `manpath` / `fpath` variable in the offending function

**First seen**: 2026-04
**Affects**: zsh (all versions); any function declaring `local path` (lowercase)
**Status**: fixed in `dot_config/zsh/tools/22_sesh.zsh` (renamed local var to `target`)

## Symptom

```
❯ shere
zsh: command not found: sesh

❯ which sesh
/opt/homebrew/bin/sesh

❯ sesh
Sesh is a smart terminal session manager ...   # works fine

❯ hash -r
❯ shere
zsh: command not found: sesh                    # still broken

❯ rehash
❯ shere
zsh: command not found: sesh                    # still broken
```

`shere` is `alias shere='sesh-here'`; `sesh-here` is a function defined in
`dot_config/zsh/tools/22_sesh.zsh`. The function's *only* external command is
`sesh`, which exists, is in `PATH`, and runs fine outside the function. The
hash-clear ritual does nothing because the hash isn't the problem.

## Root cause

In zsh, the lowercase array variables `path`, `cdpath`, `manpath`, `fpath` are
**tied to** their uppercase scalar siblings (`PATH`, `CDPATH`, `MANPATH`,
`FPATH`) via `typeset -T`. Modifying one modifies the other — they are the
same storage in two views.

When a zsh function does:

```zsh
function foo() {
    local path=""
    ...
}
```

…this creates a **function-local** `path` shadowing the global one, and
because `path` is tied to `PATH`, the function-local `PATH` is now `""` for
the duration of the function. Every external command lookup inside the
function fails with `command not found`, regardless of `hash`, `rehash`,
or what `which` says at the prompt (which sees the *global* PATH).

`which` and `hash -r` mislead because they operate at the interactive shell
level, not inside the function's local scope.

The original buggy code:

```zsh
function sesh-here() {
    local cmd="" path=""              # ← path="" empties PATH inside the function
    ...
    path="${path:-$PWD}"              # ← restores `path` to $PWD, not /opt/homebrew/bin
    sesh connect "$path"              # ← `sesh` not findable, $PWD ≠ a bin dir
}
```

`sesh-root` in the same file uses `local root` and was unaffected — same bug
shape, different variable name, no collision.

zsh manual reference: `man zshparam` → "PARAMETERS USED BY THE SHELL" lists
`path`, `cdpath`, `manpath`, `fpath` (and a few others) as the tied arrays.
`man zshbuiltins` → `typeset -T` documents the tying mechanism.

## Workaround

**Rename the local variable.** Any name that isn't a tied-array name works:

```zsh
function sesh-here() {
    local cmd="" target=""            # was: local cmd="" path=""
    ...
    target="${target:-$PWD}"
    sesh connect "$target"
}
```

If you genuinely need a local variable called `path` (e.g. interop with a
template that expects that name), force a fresh untied scalar with `typeset`:

```zsh
typeset path=""                       # untied function-local scalar
# but PATH is still globally inherited; safer to just rename
```

…but renaming is the cleaner fix because the tied-array trap is invisible at
the call site.

## Prevention

**Never use these names as `local` variables in zsh functions:**

| Tied lowercase array | Tied uppercase scalar |
|---|---|
| `path` | `PATH` |
| `cdpath` | `CDPATH` |
| `manpath` | `MANPATH` |
| `fpath` | `FPATH` |
| `mailpath` | `MAILPATH` |
| `module_path` | `MODULE_PATH` |
| `psvar` | (no scalar; still array-special) |
| `watch` | `WATCH` |

Add a comment to any zsh function that takes a path-like argument and uses a
`local` for it, explaining why the variable is NOT named `path`:

```zsh
# NOTE: do NOT use a local variable named `path` — in zsh `path` is tied to
# `PATH`, so `local path=""` empties PATH inside this function.
local target=""
```

When debugging "works at prompt, fails inside function" symptoms, before
chasing PATH / hash / shell init order, **grep the function for `local path`
/ `local cdpath` / `local fpath` / `local manpath`**. It's a 5-second check
that rules out the highest-likelihood cause.

This trap is **not serious enough to graduate to `AGENTS.md`** (only zsh
function authors hit it; rare; one-line fix once diagnosed). Keep it as a
pitfall.

## Related

- [`docs/zsh/aliases.md`](../docs/zsh/aliases.md) — registry of aliases /
  functions including `shere` → `sesh-here`
- `dot_config/zsh/tools/22_sesh.zsh` — fixed call site
- `man zshparam` (PARAMETERS USED BY THE SHELL) — official list of tied arrays
- Adjacent gotcha: bash does NOT tie `path` to `PATH`, so this code would
  work in bash. Cross-shell zsh→bash ports are a likely vector for
  *introducing* this bug, not just hitting it.
