# `bootstrap.sh` via `curl | bash` hangs silently after "reattaching to /dev/tty"

**Symptoms** (grep this section): `[bootstrap HH:MM:SS] stdin is a pipe — reattaching to /dev/tty for interactive prompts` is the **last** line of output; no `fetching + running ${SCRIPT_URL}` log; no `chezmoi`/`questionary` prompts; the curl-piped bootstrap hangs forever (or until Ctrl+C); reproduces only on **fresh users** / certain hosts (works on others)
**First seen**: 2026-06 (reported by `daweilee@ta-stg`)
**Affects**: `bootstrap.sh` ≤ commit `3648ce0` when invoked as `curl -fsSL .../bootstrap.sh | bash` from a fresh user account that has a real `/dev/tty`
**Status**: fixed — `exec </dev/tty` removed mid-script; `/dev/tty` now redirected only on the final `exec uv run`

## Symptom

Fresh user runs the documented one-liner from [`README.md`](../README.md):

```bash
curl -fsSL https://raw.githubusercontent.com/daviddwlee84/dotfiles/main/bootstrap.sh | bash
```

Output stops dead at this line and never resumes (timestamps from a real
report, ~4 minutes between uv install start and hang):

```
[bootstrap 14:42:07] starting (ref=main, raw=https://raw.githubusercontent.com/daviddwlee84/dotfiles)
[bootstrap 14:42:07] PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
[bootstrap 14:42:07] TTY: stdin=no, /dev/tty=readable
[bootstrap 14:42:07] uv not found — installing from https://astral.sh/uv/install.sh
...
[bootstrap 14:46:11] uv installed: /home/daweilee/.local/bin/uv
[bootstrap 14:46:11] stdin is a pipe — reattaching to /dev/tty for interactive prompts
                                                                                       ← hangs here
```

Critical detail: the `fetching + running ${SCRIPT_URL}` log line that the
script emits **right after** the reattach block never appears. Whatever is
hanging, it's hanging **before** that `log` call gets executed.

The hang is not in `uv run` — `uv run` never starts. There's no
`dotfiles_init.py`, no `questionary` prompt, no `chezmoi` child process.
`pgrep -af bootstrap|uv|chezmoi` shows only the parent `bash`.

## Root cause

`bootstrap.sh` (pre-fix) had this block in the middle of the script:

```bash
if [ ! -t 0 ] && [ -r /dev/tty ]; then
    log "stdin is a pipe — reattaching to /dev/tty for interactive prompts"
    exec </dev/tty                              # ← THE BUG
fi

# --- 3. run ------------------------------------------------------------------
log "fetching + running ${SCRIPT_URL}"          # ← never reached
log "(first run resolves PEP 723 deps...)"
exec uv run "${UV_RUN_FLAGS[@]}" --script "$SCRIPT_URL" "$@"
```

In `curl ... | bash`, **bash reads its own script body from fd 0** (the
curl pipe). When `exec </dev/tty` runs, it repoints bash's fd 0 from the
curl pipe to `/dev/tty`. Bash then tries to read the next line of the
script — but fd 0 is now the user's keyboard, which is empty.
`read(0, ...)` blocks. Forever.

That's why the hang happens **after** the reattach `log` line (which was
already read into bash's input buffer and executed) but **before** the
`log "fetching + running"` line (which was never read).

This is a documented chicken-and-egg of `curl | bash` interactive scripts:

> "we probably have undefined behaviour here, unless it is specified in
> what chunks bash reads its commands."
> — [SO #20149101](https://stackoverflow.com/questions/20149101/how-to-read-user-input-when-script-is-piped-to-shell)

The reason it *appeared* to work before is exactly that — undefined
behaviour. Bash sometimes prefetches multiple buffers, especially with
small scripts on certain glibc / kernel / pipe-buffer combinations, in
which case the entire script is already in bash's internal buffer before
`exec </dev/tty` repoints fd 0. On the host where this was first reported
(`ta-stg`, fresh non-root user, slow network → kernel may have served the
pipe in smaller chunks), the script bytes after the reattach block had
not yet been read, and bash then tried to read them from `/dev/tty`.

### Reproducer

Inside a real pty (so `/dev/tty` exists), simulate `curl | bash` with `cat |
bash` and a 3-second timeout:

```bash
cat > /tmp/repro_hang.sh <<'EOF'
set -euo pipefail
echo "[$(date +%S.%N)] line 1: before exec redirect"
echo "[$(date +%S.%N)] tty: stdin=$([ -t 0 ] && echo yes || echo no), /dev/tty=$([ -r /dev/tty ] && echo readable || echo no)"
exec </dev/tty
echo "[$(date +%S.%N)] line 3: after exec redirect"
EOF

script -qc 'timeout 3 bash -c "cat /tmp/repro_hang.sh | bash"; echo "[exit=$?]"' /dev/null
```

Output (hang reliably reproduced):

```
[NN.NNN] line 1: before exec redirect
[NN.NNN] tty: stdin=no, /dev/tty=readable
[exit=124]                                       ← timeout killed bash; line 3 never printed
```

`line 3` never appears even though it's only 4 lines after the `exec` —
bash blocks on `read(/dev/tty)` waiting for the next command byte.

## Fix

Don't redirect bash's own fd 0. Hand `/dev/tty` to the **child** process
of the final `exec`:

```bash
NEED_TTY_REDIRECT=0
if [ ! -t 0 ] && [ -r /dev/tty ]; then
    log "stdin is a pipe — will attach /dev/tty as uv run's stdin (not bash's)"
    NEED_TTY_REDIRECT=1
fi

log "fetching + running ${SCRIPT_URL}"
if [ "$NEED_TTY_REDIRECT" = "1" ]; then
    exec uv run "${UV_RUN_FLAGS[@]}" --script "$SCRIPT_URL" "$@" </dev/tty
else
    exec uv run "${UV_RUN_FLAGS[@]}" --script "$SCRIPT_URL" "$@"
fi
```

Key insight: `exec command < file` redirects **the new process's** stdin
to `file`, not the current shell's. Bash's own fd 0 stays on the curl
pipe long enough for bash to finish reading the rest of the script, then
the `exec` replaces bash entirely (so there's no "after exec" to read).
The replaced process (`uv run`) sees `/dev/tty` as fd 0, exactly what
`questionary` needs.

Verified with the same reproducer pattern — all lines print, child sees
`stdin tty? yes`, exit 0 in milliseconds.

## Prevention

- **Never** `exec </dev/tty` (with no command) in a script that might run
  under `curl | bash`. Either (a) attach `/dev/tty` to the final `exec
  cmd </dev/tty`, or (b) use `read foo </dev/tty` per-call to avoid
  touching bash's own stdin.
- Prefer `bash <(curl -fsSL …)` (process substitution) over
  `curl … | bash` when designing new bootstrap scripts — bash reads the
  script via the substituted fd, fd 0 is left on the original tty, no
  reattach gymnastics needed. The README still recommends `curl … | bash`
  because process substitution doesn't work in dash / older POSIX shells
  and "what to run on a stock fresh box" must work in `sh -c`.

## Related

- [`bootstrap.sh`](../bootstrap.sh) — the fixed version.
- [`docs/this_repo/bootstrap.md`](../docs/this_repo/bootstrap.md) — user
  docs; "Skipping bootstrap.sh entirely" section already recommends
  `just bootstrap-local` precisely to avoid this whole class of bug.
- [`pitfalls/bootstrap-no-tty-sudo-prompt-skipped.md`](bootstrap-no-tty-sudo-prompt-skipped.md)
  — sister pitfall in the same area but a different mechanism (`/dev/tty`
  open fails for AD users without `pam_systemd` session, not because bash
  redirected its own fd 0).
- [SO #6561072](https://stackoverflow.com/questions/6561072/why-wont-bash-wait-for-read-when-used-with-curl)
  — canonical answer with the per-command `< /dev/tty` and bash-wide
  `exec 0</dev/tty` patterns; both have the same fd 0 hazard for piped
  bash.
- [SO #20149101](https://stackoverflow.com/questions/20149101/how-to-read-user-input-when-script-is-piped-to-shell)
  — explains the "undefined behaviour" of bash's stdin chunking, which
  is why this bug appeared to work for months before biting on a fresh
  user.
