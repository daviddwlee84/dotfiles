# ble.sh prints `{ _ble_edit_exec_gexec__save_lastarg "$@"; } 4>&1 5>&2 &>/dev/null` after every command

**Symptoms** (grep this section):
- `{ _ble_edit_exec_gexec__save_lastarg "$@"; } 4>&1 5>&2 &>/dev/null` printed
  after every prompt, before the next starship prompt repaints
- The command you typed is *also* echoed on its own line right after the
  prompt, before the command's actual stdout (looks like the command is
  running twice)
- Symptom **disappears in a fresh terminal**; persists across multiple
  `Ctrl+L` clears within the same session
- No `+` prefix on the leaked lines (so it's NOT `set -x` — see Root cause)
- Affects bash + ble.sh; zsh is unaffected even if the same trigger fires

**First seen**: 2026-05 on `idc-server104` (RHEL 7-era host, bash 4.2.46(2),
ble.sh 0.4.0-devel) after pasting a multi-line snippet into the prompt.

**Affects**: any bash + ble.sh session where `set -v` (verbose) gets enabled
mid-session. Not version-specific — bash 4.2, 5.x both reproduce; ble.sh
all current versions.

**Status**: workaround documented; **not** a ble.sh bug — `set -v` is
architecturally incompatible with ble.sh's eval-based command dispatch.

## Symptom

Verbatim from idc-server104 (yczhang@idc-server104, 2026-05):

```
yczhang in 🌐 idc-server104 in chezmoi on  main via  v2.7.5
❯ bash --version
bash --version
GNU bash, version 4.2.46(2)-release (x86_64-redhat-linux-gnu)
Copyright (C) 2011 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>

This is free software; you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
{ _ble_edit_exec_gexec__save_lastarg "$@"; } 4>&1 5>&2 &>/dev/null

yczhang in 🌐 idc-server104 in chezmoi on  main via  v2.7.5
❯ chezmoi update --apply --init
chezmoi update --apply --init
fatal: unable to access 'https://github.com/daviddwlee84/dotfiles.git/': Encountered end of file
chezmoi: git: exit status 1
{ _ble_edit_exec_gexec__save_lastarg "$@"; } 4>&1 5>&2 &>/dev/null
[ble: exit 1]
```

Note three giveaways:

1. `bash --version` appears twice — once as the typed input under the
   starship `❯` prompt, once on a line by itself before the actual output.
2. The internal `_ble_edit_exec_gexec__save_lastarg` line appears after
   *every* command, regardless of success / failure / shell builtin /
   external binary.
3. No `+` prefix → this is `set -v`, not `set -x`.

## Root cause

ble.sh executes user commands not by direct invocation but by building a
multi-line eval string and feeding it to `eval`:

```
<user's typed command>
{ _ble_edit_exec_gexec__save_lastarg "$@"; } 4>&1 5>&2 &>/dev/null
```

The second line is ble.sh's internal hook that captures `$_` (last-arg
expansion) and restores its own fd 4 / fd 5 redirection stack. Source:
[`lib/core-edit.sh`](https://github.com/akinomyoga/ble.sh) — `function
ble/builtin/edit/.gexec-prepare` and `_ble_edit_exec_gexec__save_lastarg`.

When `set -v` (verbose) is on, bash echoes **every line of shell input as
the parser reads it**. `eval`'s argument counts as input. So bash echoes
**both** lines of the eval string before executing them — producing the
doubled command echo *and* the gexec-wrapper line on every prompt.

`set -v` is also why opening a new terminal "fixes" it: a new bash starts
without that flag (assuming the trigger doesn't fire again immediately).

### Why `set -v` is fundamentally incompatible with ble.sh

ble.sh has no way to suppress verbose echo of its own internal eval string
without disabling `set -v` entirely — and disabling it would surprise users
who explicitly want verbose mode for debugging.

This is **not** the same as `set -x` (xtrace). With `set -x`:
- bash prints `+ <command>` *just before execution* (PS4 prefix)
- ble.sh's internal commands DO get xtraced too, but the `+` prefix and
  the PS4 expansion make them visually distinct
- xtrace output goes to fd 2 (stderr); verbose output goes to fd 2 too,
  but without any prefix

So `set -x` produces a related but distinguishable leak (every internal
ble.sh function gets `+ ble/widget/...` traced). The user-visible noise
is even worse, but the `+` prefix makes the cause obvious.

## Workaround

### In-session recovery (no new terminal needed)

```bash
set +v
```

Optionally also clear xtrace (cheap and idempotent):

```bash
set +v +x
```

That's it. The wrapper line stops appearing on the next prompt.

### Find the trigger

```bash
# Confirm verbose / xtrace state
set -o | grep -E 'verbose|xtrace'

# Inherited from environment?
echo "SHELLOPTS=$SHELLOPTS"
echo "BASH_ENV=$BASH_ENV"
```

If `SHELLOPTS=verbose` is in the environment, a parent process (or an
exported assignment in `/etc/profile` / `/etc/profile.d/*.sh`) is the
source — it gets inherited by every child shell. Fix the assignment or
`unset SHELLOPTS` in the offending location.

If `SHELLOPTS` is empty, the flag was flipped *in-session*. Common
triggers:

1. **Pasting a snippet that contained `set -v` without a paired `set +v`**
   — most common cause. The snippet may have been a partial paste, or the
   user's screen got truncated mid-paste.
2. **Sourcing a buggy script** — `source ./debug-helper.sh` where the
   script enabled verbose for its own diagnostics but didn't restore on
   exit.
3. **Typo** — `set -v` instead of intended `setopt -v` (zsh) or `bind -v`
   (readline); or pressing `Enter` on a half-typed `set -vx` command.
4. **Old `~/.bashrc.d/*` or `/etc/bashrc` audit hook** — some corporate
   RHEL deployments enable verbose for shell audit logging. Persists
   across new terminals; not the cause if the symptom only appears
   mid-session.

## Prevention

No managed-config change is needed because:

- Adding `set +v +x` to `dot_bashrc.tmpl` would mask user intent (someone
  who genuinely wants verbose mode for one debug session would have it
  silently disabled on next shell start).
- The flag is session-state, not config-state — it gets reset on every
  new shell, so the trap is self-limiting.
- The recovery (`set +v`) is one keystroke once you know the cause.

Knowing the symptom is the prevention. This file exists so the next time
you see `_ble_edit_exec_gexec__save_lastarg` printed in your prompt, you
spend 5 seconds running `set +v` instead of 30 minutes hunting the
gexec internals.

## Related

- [`dot_bashrc.tmpl`](../dot_bashrc.tmpl) — ble.sh init order. The
  `--attach=none` + late `ble-attach` dance is unrelated to this trap;
  the verbose-leak hits regardless of init order.
- [`dot_config/bash/04_blesh.bash.tmpl`](../dot_config/bash/04_blesh.bash.tmpl) —
  bleopt tweaks. No knob here mitigates the leak.
- [`pitfalls/tmux-extended-keys-always-paste.md`](tmux-extended-keys-always-paste.md) —
  sister pitfall about another ble.sh paste-mode trap (CSI-u `^[[106;5u`
  literals appearing in pasted content).
- ble.sh source: `function _ble_edit_exec_gexec__save_lastarg` in
  [`lib/core-edit.sh`](https://github.com/akinomyoga/ble.sh/blob/master/lib/core-edit.sh)
  — the internal hook whose name appears in the leaked output.
- bash man page: `set -v` ("Print shell input lines as they are read.")
  — note "as they are read", not "as they are executed". `eval`'s
  argument counts as input.
