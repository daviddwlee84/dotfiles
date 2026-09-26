# `chezmoi apply` stops with ".bashrc has changed since chezmoi last wrote it" right after bootstrap

## Symptoms

On a host that already has a chezmoi-written `~/.bashrc`, the first apply after
the bootstrap script re-runs (fresh `run_once_` state, or a changed bootstrap
template) ends with:

```console
[INFO] Added ~/.local/bin to PATH in /Users/you/.bashrc
[SUCCESS] Bootstrap complete!
.bashrc has changed since chezmoi last wrote it (diff/overwrite/all-overwrite/skip/quit)?
```

With `--no-tty` (detached/fleet apply) this is `chezmoi: .bashrc: EOF`, exit 1.

## Cause

`run_once_before_00_bootstrap.sh.tmpl` step 7 appended
`export PATH="$HOME/.local/bin:$PATH"` to `~/.bashrc` for bash-only hosts. When
this source state also manages `~/.bashrc` (`dot_bashrc.tmpl`), the append
modifies a managed target in the same apply, so chezmoi's own write conflicts.
The managed `.bashrc` already gets `~/.local/bin` from the shared exports.

## Fix

Bootstrap now skips the append when the source directory contains
`dot_bashrc.tmpl` / `dot_bashrc`. To recover a host that already hit it:

```sh
chezmoi diff ~/.bashrc            # only the bootstrap line should differ
chezmoi apply --force ~/.bashrc
chezmoi apply
```
