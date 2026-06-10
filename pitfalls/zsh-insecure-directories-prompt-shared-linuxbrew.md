# New zsh blocks on "Ignore insecure directories and continue [y] or abort compinit [n]?" on shared-Linuxbrew boxes

**Symptoms** (grep this section): `zsh compinit: insecure directories and files, run compaudit for list.`, `Ignore insecure directories and files and continue [y] or abort compinit [n]?`, `[oh-my-zsh] Insecure completion-dependent directories detected:`, `[oh-my-zsh] For safety, we will not load completions from these directories until`, `compaudit | xargs chmod g-w,o-w` (suggested by oh-my-zsh but does NOT fix it), every **nested** zsh (tmux pane, `zsh` from an existing shell) prompts; fresh SSH login shells are clean.

**First seen**: 2026-06-10 on `ta-stg` (Ubuntu 22.04, multi-user box where `/home/linuxbrew/.linuxbrew` was installed by user `taa`, current user `daweilee`)
**Affects**: Ubuntu + oh-my-zsh + a Linuxbrew prefix owned by ANOTHER user. Only nested shells (inherited environment), not fresh logins.
**Status**: fixed — `skip_global_compinit=1` in `dot_zshenv.tmpl` + conditional `ZSH_DISABLE_COMPFIX=true` in `dot_zshrc.tmpl`.

## Symptom

Opening a new zsh from inside an existing shell (tmux split, `zsh` at a prompt)
blocks on an interactive y/n prompt, then prints a warning wall:

```text
zsh compinit: insecure directories and files, run compaudit for list.
Ignore insecure directories and files and continue [y] or abort compinit [n]? y
[oh-my-zsh] Insecure completion-dependent directories detected:
drwxr-xr-x 3 taa taa 4096 Apr 15 15:56 /home/linuxbrew/.linuxbrew/share/zsh
drwxr-xr-x 2 taa taa 4096 May  8 00:51 /home/linuxbrew/.linuxbrew/share/zsh/site-functions
...
[oh-my-zsh]     compaudit | xargs chmod g-w,o-w
```

## Root cause — three things compound

1. **compaudit flags OWNERSHIP, not just permissions.** The listed dirs are
   already `755` (no group/other write), so oh-my-zsh's suggested
   `compaudit | xargs chmod g-w,o-w` is a no-op. compaudit requires dirs to be
   owned by **root or the current user** — a Linuxbrew prefix installed by a
   different user on a shared box can never pass for everyone, and
   `chown`-ing it away would break the owner's `brew upgrade`.

2. **Only nested shells see the dirs at compinit time.** This repo runs
   `brew shellenv` in the modular layer (`dot_config/shell/00_exports.sh.tmpl`)
   AFTER oh-my-zsh's compinit, so fresh login shells audit a clean fpath.
   But `brew shellenv` **exports `FPATH`**, so any child zsh inherits the
   linuxbrew site-functions before its own compinit runs — that's why only
   "create new zsh" (nested) sessions prompt.

3. **Two separate compinit calls, two separate failure modes.** The blocking
   y/n prompt is NOT oh-my-zsh (omz uses `compinit -i` = skip silently +
   warning). It comes from stock Ubuntu `/etc/zsh/zshrc:111-112`, which runs a
   bare `compinit` (default `_i_fail=ask` → interactive prompt) before
   `~/.zshrc` ever loads. Located via `zsh -x -i -c exit 2>trace`.

## Fix (shipped)

- **`dot_zshenv.tmpl`**: `skip_global_compinit=1` (Linux-gated). This is the
  escape hatch documented inside `/etc/zsh/zshrc` itself; `~/.zshenv` is the
  only user file sourced before `/etc/zsh/zshrc`. Kills the blocking prompt
  and removes a duplicate compinit from startup (omz runs its own).
- **`dot_zshrc.tmpl`** (before oh-my-zsh is sourced, Linux-gated):
  ```zsh
  if [[ -e /home/linuxbrew/.linuxbrew/bin/brew && ! -O /home/linuxbrew/.linuxbrew ]]; then
      ZSH_DISABLE_COMPFIX=true
  fi
  ```
  Runtime-conditional on "brew prefix exists AND is not owned by me" — the
  shared prefix is trusted (same team installed it), so omz runs `compinit -u`
  and actually LOADS brew's completions in nested shells instead of refusing
  them. Single-user installs (prefix owned by me, or no linuxbrew) keep the
  full audit.

## Why this is NOT an ad-hoc hack

The fix may look like "just silence the warning", but it is the standard
client-side counterpart of Homebrew's own multi-user story:

1. **Server-side vs client-side are orthogonal.** The recommended multi-user
   Linuxbrew architecture (dedicated `linuxbrew` owner, prefix `755`, single
   maintainer doing `brew install`/`upgrade`, Brewfile for audit trail)
   governs WHO may write the prefix. It says nothing about how non-owner
   users' shells should treat it — that is exactly what this dotfiles fix
   covers. We don't admin the shared boxes we SSH into, so the server layer
   is out of scope for this repo anyway.
2. **Even the "correct" architecture still fails compaudit.** compaudit
   accepts only root- or current-user-owned dirs. A prefix owned by a
   dedicated `linuxbrew` user is, from every other user's perspective, still
   "another non-root user" — identical to the `taa`-owned prefix that
   triggered this pitfall. So every non-owner user needs `compinit -u`
   (i.e. `ZSH_DISABLE_COMPFIX=true`) regardless of how well the server is
   managed. There is no server-side configuration that makes compaudit pass
   for everyone without breaking `brew upgrade` for the owner.
3. **Homebrew itself calls shared installs unsupported.** The
   [Support Tiers](https://docs.brew.sh/Support-Tiers) doc lists "multiple
   users share the same installation" as unsupported, and
   [Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux) fixes the
   prefix at `/home/linuxbrew/.linuxbrew` (required for bottles) — which is
   why hardcoding that path in the `dot_zshrc.tmpl` condition is fine.
4. **The recommended setup widens the trigger, not narrows it.** Best
   practice on such boxes is a global `/etc/profile.d/linuxbrew.sh` running
   `eval "$(brew shellenv)"` — which exports `FPATH` to ALL login shells, so
   the current "nested shells only" symptom would become "every shell". The
   client-side fix becomes more necessary under the proper architecture, not
   less.
5. **The surgical alternative was considered and rejected.** Stripping the
   non-owned brew dirs from `fpath` before compinit would keep the full audit
   but drop completions for everything brew installs (rg, fd, gh, ...). On a
   team box where the shared prefix is trusted, that trade is strictly worse.

## Things that do NOT fix it

- `compaudit | xargs chmod g-w,o-w` — perms already clean; failure is ownership.
- `chown -R $USER /home/linuxbrew/.linuxbrew/share/zsh` — breaks the owning
  user's `brew upgrade` (brew writes new completion symlinks as that user).
- Unconditional `ZSH_DISABLE_COMPFIX=true` — silences omz but NOT the blocking
  `/etc/zsh/zshrc` prompt (that compinit runs before `~/.zshrc`), and drops
  the audit on single-user machines where it costs nothing.

## Related

- [`dot_zshenv.tmpl`](../dot_zshenv.tmpl), [`dot_zshrc.tmpl`](../dot_zshrc.tmpl) — both halves of the fix
- [`dot_config/shell/00_exports.sh.tmpl`](../dot_config/shell/00_exports.sh.tmpl) — the Linux `brew shellenv` callsite whose exported `FPATH` leaks into nested shells
- `docs/zsh/zsh-completions.md` — compinit/fpath architecture ("compinit runs once inside oh-my-zsh.sh" — now true on Ubuntu too, since the global compinit is skipped)
- [Homebrew Support Tiers](https://docs.brew.sh/Support-Tiers) — shared multi-user installations are officially unsupported
- [Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux) — `/home/linuxbrew/.linuxbrew` is the fixed default prefix (required for bottles)
