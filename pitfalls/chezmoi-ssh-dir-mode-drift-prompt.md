# `chezmoi apply` hangs asking `.ssh has changed since chezmoi last wrote it?`

**Symptoms** (grep this section):
- `chezmoi apply` / `chezmoi update --apply` stops and prompts, blocking forever
  on a non-interactive/background run:
  ```
  .ssh has changed since chezmoi last wrote it. Overwrite? [y/n/a/q/...]
  ```
- `chezmoi status` shows `MM .ssh` even though you never edited `~/.ssh`.
- A second, unrelated `chezmoi` invocation elsewhere then fails with
  `chezmoi: timeout obtaining persistent state lock, is another instance of
  chezmoi running?` — because the stuck prompt above still holds the lock on
  `~/.config/chezmoi/chezmoistate.boltdb`.
- `stat -f '%Sp' ~/.ssh` shows `drwx------` (0700) — the *correct*, tight mode.

**First seen**: 2026-09-15
**Affects**: any host where the source tree used a bare `dot_ssh` (chezmoi wants
`~/.ssh` = 0755) while ssh itself or `dev ssh` keeps `~/.ssh` at 0700.
**Status**: fixed 2026-09-15 — source dir renamed `dot_ssh` → `private_dot_ssh`.

## Root cause

The source directory was `dot_ssh` with **no `private_` prefix**, so chezmoi's
desired mode for `~/.ssh` is the default directory mode `0755`. But OpenSSH
requires `~/.ssh` to be `0700`, and `dev ssh init` / normal ssh use keep it there.

So on every apply chezmoi sees: desired `0755`, actual `0700` → the dir is
"modified" → it wants to widen it back to `0755`. Because the target was changed
since chezmoi last wrote it, `chezmoi apply` raises the "has changed since chezmoi
last wrote it" confirmation. On a TTY it blocks waiting for an answer (and answering
`y` would actually **weaken** `~/.ssh` to `0755`); `chezmoi status` reports `MM`.
The blocked process keeps the boltdb persistent-state lock, so every other chezmoi
command on the box times out.

Reproduced in isolation: a bare `dot_ssh` applies `~/.ssh` at 0755; `chmod 700`
then `chezmoi status` → `MM .ssh`, and the next `apply` hangs on the prompt.
`private_dot_ssh` applies 0700, matches, and stays clean.

## Fix

Rename the source directory so chezmoi owns `~/.ssh` at 0700:

```console
$ git mv dot_ssh private_dot_ssh   # child prefixes (create_private_*, private_config.d) unchanged
```

`private_` + `dot_` = target `~/.ssh` at mode 0700, which equals what ssh and
`dev ssh` want, so desired == actual and there is nothing to apply. The child
entries were already `create_private_*` (0600 seeds) and `private_config.d`
(0700), so only the top dir's mode was wrong.

## Manual recovery on a wedged host

1. Clear the stuck prompt (do **not** answer `y` — that widens `~/.ssh` to 0755):
   at the blocked terminal press `n` then `Enter`, or `Ctrl-C`. That releases the
   boltdb lock.
2. Pull the fixed source and re-apply:
   ```console
   $ chezmoi update --apply     # or: cau
   ```
   With `private_dot_ssh`, desired 0700 == actual 0700 → no prompt, no drift.

If a stale `0755` is still recorded in the persistent state and it prompts once
more after the fix, answering `y` is now safe (it just rewrites `~/.ssh` to
0700 == current) and every later apply is clean.

## Generalisable

**Any directory chezmoi manages inherits the default 0755 unless you prefix it
`private_`; for a dir a companion tool or the app itself keeps at 0700
(`~/.ssh`, `~/.gnupg`, `~/.aws`), that mismatch is a permanent drift that
surfaces as the "has changed since chezmoi last wrote it" prompt and, worse, a
lock that wedges every other chezmoi run.** Match chezmoi's desired mode to the
mode the security-sensitive tool enforces, not the other way around. Bonus: tests
that shell out to `chezmoi apply` must pass their own `--persistent-state`, or one
stuck interactive apply blocks the whole suite via the shared boltdb lock.

## See also

- [`tsnet-ssh-block`](../tests/unit/tsnet_ssh_block.bats) and `ssh_grouped_seed.bats` — the SSH seed/Include-order invariants
