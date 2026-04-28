# `mrun` / `tmrun` / `zjrun` autoname repeats every call (zsh `$RANDOM` frozen in `$(…)` subshells)

**Symptoms** (grep this section):
- Two or more back-to-back `mrun` / `tmrun` / `zjrun` calls without `-n NAME`
  produce the *same* auto-derived session name. Concrete trace:
  ```
  ❯ zjrun -- 'echo "hi \"there\"" && echo $HOME'
  mrun[zellij]: started 'run-chezmoi-2966'. Attach: zellij attach run-chezmoi-2966
  ❯ zjrun 'echo "hi \"there\"" && echo $HOME'
  mrun[zellij]: started 'run-chezmoi-2966'. Attach: zellij attach run-chezmoi-2966   # ← same!
  ❯ tmrun 'echo "hi \"there\"" && echo $HOME'
  mrun: tmux session 'run-chezmoi-2966' already exists. Use -f to replace, or pick a different -n NAME.
  ```
- The exact suffix differs per zsh-shell instance (e.g. `2966`, `5371`,
  `7a59`, `79dd` — whatever the first `$RANDOM` happens to land on for
  *that* shell), but it never changes within a single shell.
- Cross-backend collision: a stale `tmux` session from an earlier
  `tmrun` blocks a fresh `zjrun -n run-chezmoi-2966` of the same name and
  vice versa, because both backends share the same auto-name namespace.
- Independent test confirms the underlying zsh behavior:
  ```
  $ zsh -c 'echo "$(echo $RANDOM) $(echo $RANDOM) $(echo $RANDOM)"'
  10733 10733 10733     # ← three command-substitution subshells, identical seed
  $ zsh -c 'echo "$RANDOM $RANDOM $RANDOM"'
  17910 9366 591        # ← parent-shell reads, advance correctly
  ```

**First seen**: 2026-04-28 on `Da-Weis-Mac-mini` (zsh 5.9, macOS 26.2 arm64).
First `tmrun` / `zjrun` testing session after the helpers landed in
`dot_config/zsh/tools/23_mrun.zsh`.
**Affects**: any zsh function that derives a unique-ish identifier via
`name=$(some_helper)` where `some_helper` reads `$RANDOM` internally.
**Status**: fixed in `dot_config/zsh/tools/23_mrun.zsh` (read `$RANDOM` into
a parent-shell local *before* the `$(…)` boundary; pass the seed as an arg).

## Symptom

Direct, reproducible failure path:

```zsh
$ zsh
$ source dot_config/zsh/tools/23_mrun.zsh
$ cd /tmp
$ tmrun -- "sleep 60"
mrun[tmux]: started 'run-tmp-79dd'. Attach: tmux switch-client -t run-tmp-79dd
$ tmrun -- "sleep 60"
mrun: tmux session 'run-tmp-79dd' already exists. Use -f to replace, or pick a different -n NAME.
$ tmrun -- "sleep 60"
mrun: tmux session 'run-tmp-79dd' already exists. …
```

Second through Nth call collide on the *same* random suffix. The user
either has to type `-n NAME` every invocation (defeating the auto-name
purpose) or pass `-f` (which kills the still-running first session — wrong
semantics for fire-and-forget).

## Root cause

`_mrun_default_name` was originally invoked as:

```zsh
function _mrun_default_name() {
    local base
    base=$(_mrun_sanitize "$(basename "$PWD")")
    printf 'run-%s-%04x' "$base" $((RANDOM % 65536))
}
…
[[ -z "$name" ]] && name=$(_mrun_default_name)   # ← $(…) subshell
```

`name=$(_mrun_default_name)` is **command substitution**, which forks a
subshell. Inside that subshell, `$((RANDOM % 65536))` reads `$RANDOM` for
the first time → zsh seeds the subshell's RANDOM sequence based on the
fork-time state of the parent. The parent shell *never reads* its own
`$RANDOM` during this sequence — so its sequence index is unchanged.

On the next `mrun` call, another command-substitution subshell is forked
from the *same* parent state, gets the *same* initial seed, and produces
the *same* first random value. Repeat ad infinitum.

This is **not** the standard "subshells inherit env vars" gotcha — `$RANDOM`
is a magic parameter, and zsh's behavior here is documented:

> `RANDOM`: A pseudo-random integer between 0 and 32767. Each reference
> yields the next number in the sequence. The numbers are produced by a
> linear congruential method on each shell or subshell, as it is
> referenced.  ([zshparam(1)](https://zsh.sourceforge.io/Doc/Release/Parameters.html))

"Each shell or subshell" — each subshell has its *own* sequence, seeded
from the parent's RANDOM at fork time. If the parent never advances its
own RANDOM, every subshell starts identically.

The trap is even worse via pipelines:

```zsh
$ echo "$RANDOM $RANDOM" | cat
12845 14779
$ echo "$RANDOM $RANDOM" | cat
12845 14779   # ← parent forked off a pipeline, its RANDOM didn't advance
$ echo "$RANDOM $RANDOM"
12845 14779   # ← still stuck! pipeline left parent's RANDOM unmoved
```

This pipeline interaction is what initially derailed our debug — we
"fixed" the autoname by inlining `$((RANDOM…))` into the call site, then
"verified" via a `for … done` loop with a trailing `| grep`, which forked
the whole loop body into a subshell and produced the collided result
again. The fix only manifests when the call site is *directly* in the
parent shell's command flow, with no pipeline / `$(…)` / process
substitution wrapping it.

## Fix

In `dot_config/zsh/tools/23_mrun.zsh`, take the random read into a local
variable in the parent shell *first*, then pass the seed as `$1`:

```zsh
function _mrun_default_name() {
    # $RANDOM must be consumed in the *caller's* shell (passed as $1).
    # Reading $RANDOM inside a $(_mrun_default_name) subshell yields the same
    # value on every consecutive call because the parent's RANDOM sequence
    # never advances — the subshell forks from a frozen seed each time.
    local base seed="$1"
    base=$(_mrun_sanitize "$(basename "$PWD")")
    printf 'run-%s-%04x' "$base" "$seed"
}

…

if [[ -z "$name" ]]; then
    # Bind to a local *first* so $RANDOM is read in this shell. Inlining
    # `$((RANDOM…))` directly inside `$(_mrun_default_name …)` evaluates
    # the arithmetic inside the command-substitution subshell, where the
    # parent's RANDOM sequence never advances → identical seeds.
    local _seed=$((RANDOM % 65536))
    name=$(_mrun_default_name "$_seed")
fi
```

The `local _seed=$((RANDOM % 65536))` is a regular parameter assignment
in the parent shell — it advances the parent's RANDOM sequence. The
subsequent `$(_mrun_default_name "$_seed")` subshell receives the seed
as a fully-resolved string in `$1`; no RANDOM access happens in the
subshell.

Verified post-fix: 5 back-to-back `tmrun` calls produce 5 distinct names:

```
$ tmrun -- "sleep 60"; tmrun -- "sleep 60"; tmrun -- "sleep 60"; \
  tmrun -- "sleep 60"; tmrun -- "sleep 60"
mrun[tmux]: started 'run-tmp-7a59'. …
mrun[tmux]: started 'run-tmp-72ea'. …
mrun[tmux]: started 'run-tmp-70ae'. …
mrun[tmux]: started 'run-tmp-3077'. …
mrun[tmux]: started 'run-tmp-1050'. …
```

## Generalisation — when else this bites

Any zsh helper of shape:

```zsh
some_helper() { … $RANDOM …; }
result=$(some_helper)              # subshell: same seed every call
result=$(some_helper | post-proc)  # double subshell: still same seed
```

…will silently produce identical "random" output. The fix is always the
same: read `$RANDOM` into a parent-shell variable *before* any `$(…)` or
`|` boundary. As a rule of thumb in this repo:

- **Safe**: `local v=$RANDOM; result=$(helper "$v")`
- **Safe**: `result=${RANDOM}-${RANDOM}` (no command substitution)
- **Unsafe**: `result=$(helper)` where `helper` reads `$RANDOM` internally
- **Unsafe**: `for i in {1..N}; do something; done | tee log` if `something`
  reads `$RANDOM` — the pipeline forks the loop body into a subshell

Alternative uniqueness sources that sidestep `$RANDOM` entirely:

- `$EPOCHREALTIME` (requires `zmodload zsh/datetime` — already loaded by
  starship/p10k init in this repo) — microsecond-precision float, always
  monotonically advancing; e.g. `${EPOCHREALTIME//[.]/}` for digits-only.
- `mktemp -u "${TMPDIR:-/tmp}/foo-XXXXXX"` — heavyweight but bulletproof.
- `$$` + monotonic counter in a global var — clean for in-shell counters
  but doesn't help across separate invocations of the same shell.

For `mrun` we stuck with `$RANDOM` (passed in correctly) because 16 bits
of randomness is plenty for back-to-back session names that the user can
override with `-n NAME` if they care about a specific identifier.

## Related

- `pitfalls/sudo-shared-setsid-macos.md` — another "silently failing
  backgrounded subshell" trap in this repo. Different root cause but
  similar shape: a fork-redirected-to-`/dev/null` swallowing the failure.
- [zshparam(1) — `RANDOM`](https://zsh.sourceforge.io/Doc/Release/Parameters.html)
  — upstream documentation of the per-subshell sequence behavior.
