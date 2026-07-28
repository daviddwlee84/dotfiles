# User rename fallout — absolute `$HOME` paths that survive `usermod -l`

Renaming a Unix account is cheap; **every absolute path already written into a
config, symlink, or virtualenv is not**. `usermod -l newname -d /home/newname -m`
moves the directory and rewrites `/etc/passwd`, but nothing rewrites the
thousands of `/home/oldname/...` strings that tools baked into their own state.

Worked example: `taa` → `davidl` on `ta-stg` (uid **2000 unchanged**, home moved
to `/home/davidl`). Because the uid never changed, file *ownership* stayed
correct everywhere — which is exactly why the damage was invisible for months
and then surfaced as unrelated-looking failures.

!!! note "This is not the same as deleting an account"
    A deletion orphans **uid/gid** (files show a bare number, see
    [Shared storage permissions](shared-storage-permissions.md)). A rename keeps
    ownership intact and breaks **paths** instead. The two need completely
    different remedies; don't reach for `chown -R`.

## Why it stays hidden

Nothing fails at rename time. Each breakage waits for the next time that
specific tool is invoked, so failures arrive weeks apart and look unrelated:

- `dongwu-tick not on PATH` — three scheduled units died at once, days later,
  because the CLI was a symlink into the old home
  ([pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/)).
- `InvalidManifestError: /home/taa/.cache/pre-commit/... is not a file` —
  every `git commit` in a hook-enabled repo blocked.
- A dangling `~/.local/bin/nvim` is silently *skipped* by PATH lookup, so
  `nvim` quietly resolved to an older `/snap/bin/nvim` instead.

The last one is the nastiest pattern: a broken symlink on `PATH` does not error,
it just falls through to whatever is next.

## Impact inventory

Counts from the `ta-stg` audit (2026-07-28). Reproduce with the commands in
[Finding everything](#finding-everything).

### Tier 1 — functionally broken

| Surface | Count | How it shows up |
|---|---:|---|
| uv tools (`cmake`, `litellm`, `specify-cli`) | 3 | `uv tool list` → `warning: Tool X environment not found` |
| Python venvs (`~/.venv`, two project `.venv`, `intel-mkl`) | 4 | `.venv/bin/python` dangles → `no such file or directory` |
| `~/.local/bin` shims into the old home | 11 | silently skipped on PATH, shadowed by system copies |
| `fnm` aliases (`default`, `lts-latest`) | 2 | node version resolution |
| `mise` (`installs/rust`, tracked/trusted configs) | 3 | rust toolchain + config trust |
| `nvim` treesitter query dirs | 3 | missing `ecma` / `html_tags` / `jsx` queries |
| generated zsh completions (`_reyee`, `_mi-router`, `_mi-dhcp-bind`) | 3 | old interpreter path baked in |
| `wakatime-cli` | 1 | |

### Tier 2 — works today, wrong path (fix before it bites)

| Surface | Count | Note |
|---|---:|---|
| systemd `*.target.wants/` enable symlinks | 7 | **Still functional** — systemd resolves `.wants/` by unit *name* and finds the real file in the same search path. `is-enabled` reports `enabled`. Only the stored target is wrong. |
| `~/.codex/config.toml` `[projects."/home/taa/..."]` keys | 2 | chezmoi-managed (`dot_codex/modify_config.toml.tmpl`) — fix at source |
| tracked script comment (`Tardis-Downloader/scripts/daily_sync.sh`) | 1 | example crontab line in a committed file |

### Tier 3 — regenerable cache, just purge

| Surface | Count |
|---|---:|
| `~/.cache/uv/archive-v0` wheel links | 626 |
| bun install cache | 156 |
| `~/.codex/tmp/{arg0,path}` scratch dirs | 11 |

### Tier 4 — historical, leave alone

Transcripts and logs are a *record of what happened*; rewriting them would be
falsifying history, and nothing reads them as paths.

- `.specstory/history/*.md` — 28 files tracked across four repos
- shell histories, `opencode`/`marimo`/`nvim` state, `.netrwhist`
- `pitfalls/*.md` in this repo that quote old paths as examples

## Finding everything

```bash
# 1. Broken symlinks (the big one) — grouped by where they point
find "$HOME" -xtype l -printf '%l\n' 2>/dev/null | grep /home/OLDNAME \
  | sed 's|^/home/OLDNAME/||; s|\(^[^/]*/[^/]*/[^/]*\).*|\1|' | sort | uniq -c | sort -rn

# 2. Virtualenvs pinned to the old interpreter
find "$HOME" -name pyvenv.cfg -not -path '*/.cache/uv/*' \
  -exec grep -l /home/OLDNAME {} +

# 3. uv tools — uv reports this itself
uv tool list        # look for "environment not found"

# 4. Config / state (rg respects .gitignore; --hidden needed for dotdirs)
rg -l --hidden /home/OLDNAME "$HOME/.config" "$HOME/.local/state" "$HOME/.local/share"

# 5. systemd enable symlinks
ls -la "$HOME"/.config/systemd/user/*.target.wants/

# 6. Tracked files in your repos
for r in ~/David/*/; do git -C "$r" grep -l /home/OLDNAME 2>/dev/null; done
```

## Remediation runbook

Order matters: purge caches first (removes ~90% of the noise so the real
findings are visible), then rebuild, then relink.

```bash
# --- Tier 3: caches. Nothing of value is lost. ---
# `uv cache prune` takes an exclusive lock on ~/.cache/uv and does NOT wait
# politely: it errors out after 300s if any other uv process is alive. A long
# scheduled job (here `dongwu-tick index`, 2h+ over a 4M-row manifest) blocks it
# indefinitely — run this when nothing else uses uv, or raise the timeout.
UV_LOCK_TIMEOUT=1200 uv cache prune
rm -rf ~/.bun/install/cache ~/.cache/.bun/install ~/.codex/tmp/arg0 ~/.codex/tmp/path

# --- Tier 1: uv tools. uv's own suggested fix. ---
uv tool install cmake --reinstall
uv tool install litellm --reinstall
uv tool install specify-cli --reinstall
uv tool list                       # expect: no warnings

# --- Tier 1: virtualenvs. Recreate, never hand-edit pyvenv.cfg ---
# (editing `home =` leaves bin/python still dangling)
#
# Verify the recreate path works BEFORE deleting anything. A venv whose
# interpreter dangles is already dead weight, but `uv sync` still needs a
# pyproject.toml next to it — and a documented "home uv workspace" may not
# actually exist on this host. Removing first and discovering that after is
# how you turn a broken venv into a missing one.
for p in ~/David/dongwu-tick-downloader ~/David/Tardis-Downloader; do
  [ -f "$p/pyproject.toml" ] || { echo "skip $p: no pyproject.toml"; continue; }
  rm -rf "$p/.venv" && uv sync --directory "$p"
done

# --- Tier 1: hand-made symlinks. Repoint, target already exists locally ---
for l in nvim cursor-agent agent jlpm; do
  t="$(readlink ~/.local/bin/$l 2>/dev/null)" || continue
  case "$t" in /home/OLDNAME/*) ln -sfn "${t/\/home\/OLDNAME//home/$USER}" ~/.local/bin/$l ;; esac
done

# --- Tier 1: generated completions — regenerate, don't patch ---
reyee-update-completion; mi-router-update-completion; mi-dhcp-bind-update-completion

# --- Tier 2: systemd. `reenable` rewrites the .wants/ symlinks correctly ---
systemctl --user reenable offlineanalysis-eod.timer dongwu-tick-{daily,index,sweep,health}.timer
systemctl --user reenable docker.service pueued.service dongwu-tick-index.path
systemctl --user daemon-reload
```

Verify the whole thing converged:

```bash
find "$HOME" -xtype l 2>/dev/null | grep -c /home/OLDNAME   # want: 0
uv tool list 2>&1 | grep -c warning                         # want: 0
raid-perm-check units                                       # unrelated, but same audit habit
```

## Prevention

- **Never symlink into another account's `$HOME`.** Cross-home links survive
  indefinitely and then break all at once. Install per-user (`uv tool install`)
  or to a shared account-independent prefix (`/usr/local/bin`).
- Prefer `$HOME` / `~` over absolute paths in anything you write by hand. The
  breakage above is almost entirely in *tool-generated* state, where you have no
  say — which is why the audit above exists.
- After any rename, run the [Finding everything](#finding-everything) sweep the
  same day, while you still remember the old name.
- `systemctl --user reenable` (not `enable --force`) is the supported way to
  rewrite stale enable symlinks; it removes the old one first.

## Related

- [Shared storage permissions](shared-storage-permissions.md) — the *deletion*
  counterpart (orphaned uid/gid) and `raid-perm-check`
- [Scheduled jobs](scheduled-jobs.md) — the units affected here
