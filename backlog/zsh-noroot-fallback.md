# User-level `zsh` install for noRoot RedHat-family boxes

**Status**: P? evaluation needed (depends on real-world use pattern of the target box)
**Effort**: M (single path) → L (cross-distro + reversible + idempotent ansible role)
**Related**: `pitfalls/centos7-noroot.md` ("Required preconditions" lists `command -v zsh` as a hard prerequisite) · `dot_ansible/roles/zsh/tasks/main.yml` (currently apt/yum-only under `[sudo]`) · `TODO.md` "[L] devtools role: broaden remaining user-level fallbacks to RedHat" (sibling broadening, but devtools tasks all have curl-tarball releases — zsh doesn't, which is why this needs its own write-up)

## Context

Surfaced by `just docker-test-rocky9` (commit `403421b` onwards). On the
honest-baseline 4/8-passing run, every one of the 4 failing smoke tests
(#2, #3, #6, #8) traces to a single missing binary: **zsh**. The `zsh`
ansible role only installs via `apt` / `yum` under `[sudo]`; on
`noRoot=true` RedHat-family boxes there is no fallback, so the dotfiles
deploy a `~/.zshrc` pointing at a binary the user can't actually run.

This is consistent with `pitfalls/centos7-noroot.md`'s "Required
preconditions" — that doc explicitly says the box must already have
`zsh` installed system-wide (i.e. ask the admin to `yum install zsh`)
before `chezmoi apply` makes sense. The open question is whether we
want to lift that precondition by adding a user-level fallback, or
keep it as a hard precondition and document it more loudly.

## Investigation — three install paths considered

Two reviews (Claude + ChatGPT) compared the same three paths but
ranked them differently. After cross-referencing both, **conda-forge
is the strongest first choice on a no-sudo CentOS 7 box**, with mise
as second and manual source build as last resort.

### A. Miniforge + conda-forge `zsh` (recommended primary)

```bash
mkdir -p "$HOME/.local/bin"
curl -L -o /tmp/Miniforge3-Linux-$(uname -m).sh \
  "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh"
bash /tmp/Miniforge3-Linux-$(uname -m).sh -b -p "$HOME/miniforge3"
"$HOME/miniforge3/bin/conda" install -y -n base -c conda-forge zsh
cat > "$HOME/.local/bin/zsh" <<'EOF'
#!/usr/bin/env bash
exec "$HOME/miniforge3/bin/zsh" "$@"
EOF
chmod +x "$HOME/.local/bin/zsh"
```

**Why first:**

- Miniforge official release table targets `glibc >= 2.17` for
  `linux-64` — exact fit for CentOS 7.
- `conda-forge` ships pre-built `zsh` for `linux-64`, `linux-aarch64`,
  `linux-ppc64le` — no `ncurses-devel` needed (the corporate-box
  killer for path A below).
- Miniforge is **conda-forge-only** by default, no Anaconda commercial-
  terms registration. `-b -p $HOME/miniforge3` is non-interactive and
  prefix-isolated; doesn't touch system Python or shell init.

**Wrapper script vs symlink:** ChatGPT's call, and correct. `conda`
binaries can have rpath / runtime-prefix expectations that a plain
symlink resolves differently than a wrapper does. The two-line bash
wrapper short-circuits any `readlink`-via-`argv0` weirdness and
costs nothing.

**Caveats:**

- `~/miniforge3` is roughly 400 MB. Disk-budget the box.
- If the user already has Anaconda or an existing conda install,
  there's a config-collision risk (`~/.condarc`). The role should
  detect existing conda and bail / coordinate rather than overwrite.
- Some clusters frown on per-user conda installs for policy reasons
  (storage quotas, license tracking). Worth a "verify with admin"
  note in the role's doc-string.

### B. `mise install zsh@latest`

```bash
mise install zsh@latest && mise use -g zsh@latest
```

asdf-zsh under the hood → `./configure && make && make install` to
`~/.local/share/mise/installs/zsh/<ver>/bin/zsh` with a shim at
`~/.local/share/mise/shims/zsh`.

**Why second, not first:** zsh's `INSTALL` doc explicitly requires
`ncurses.h` in the include path — corporate / DC CentOS 7 boxes
routinely lack `ncurses-devel`. When the build dies with
`fatal error: curses.h: No such file or directory`, mise's error
surface looks like "plugin failed" rather than "missing system
header" and people waste an hour on the wrong layer.

If `ncurses-devel` *is* present, this is the cleanest answer:
mise stays the single version-manager surface, no extra Miniforge
to maintain. So worth probing as a fast path before falling back
to A:

```bash
if command -v mise &>/dev/null && [ -f /usr/include/curses.h -o -f /usr/include/ncurses.h ]; then
    mise install zsh@latest && mise use -g zsh@latest
elif ! command -v zsh &>/dev/null; then
    # fall through to Miniforge path
fi
```

Also worth checking `mise registry | grep -E '^zsh\b'` first — don't
hard-assume mise's plugin registry currently lists zsh.

### C. Manual `ncurses` + `zsh` source build (last resort)

Pull `ncurses` source → configure with `--prefix=$HOME/.local` →
build → re-do for `zsh` with `CPPFLAGS=-I$HOME/.local/include
LDFLAGS=-L$HOME/.local/lib`. ~30 min on a small box. Only worth it
if both A and B are blocked (e.g. corporate proxy blocks
`anaconda.org` AND mise registry can't reach upstream zsh tarball).

## Auxiliary problem — `chsh` blocked on noRoot, need bash auto-exec

Both reviews agree: `/etc/shells` is root-only on CentOS 7, and
default `chsh` rejects shells not listed there, so `chsh -s
~/.local/bin/zsh` fails on the corporate box. Workaround is to
auto-exec zsh from bash on interactive login.

ChatGPT's tighter version of the snippet (which I'd ship) — goes in
**`~/.bash_profile`** (login-shell only), NOT `~/.bashrc` (sourced
by every interactive sub-shell, would get reentrant exec storms in
nested bash debug shells, `script -c bash`, etc.):

```bash
# BEGIN managed-by-chezmoi: auto-launch user-installed zsh
# Reasons:
#   - chsh -s ~/.local/bin/zsh is blocked (/etc/shells not writable on noRoot boxes)
#   - We still want SSH/login → zsh transparently
# Escape hatch: NO_AUTO_ZSH=1 ssh user@host
case "$-" in
  *i*)
    if [ "${NO_AUTO_ZSH:-0}" != "1" ] \
        && [ -z "${ZSH_VERSION:-}" ] \
        && [ -x "$HOME/.local/bin/zsh" ]; then
        exec "$HOME/.local/bin/zsh" -l
    fi
    ;;
esac
# END managed-by-chezmoi
```

**Four-guard structure** is load-bearing:

| Guard | Why |
|---|---|
| `*i*` interactive | non-interactive `ssh host 'cmd'`, `scp`, `rsync`, cron must NOT exec zsh |
| `-z $ZSH_VERSION` | already-zsh shells skip the exec (idempotent) |
| `-x $HOME/.local/bin/zsh` | bail gracefully if zsh install was deleted |
| `NO_AUTO_ZSH != 1` | per-session escape hatch for debugging |

`BEGIN/END managed-by-chezmoi` markers let an ansible task use a
regex-bounded replace for idempotent re-apply (no risk of duplicating
the block on every `chezmoi apply`).

## Decision points before implementing

1. **Which path becomes the role's default?** Probably A (conda-forge
   primary) with B (mise) as a probe-first fast-path when ncurses
   headers exist.
2. **Should this role even fire by default?** ChatGPT's hedge is
   real: "如果只是偶爾跑 job，bash 留著最省事". For an
   occasional-SSH job-runner box, `bash + starship + fzf` is fine
   and doesn't carry the `~/miniforge3` 400 MB cost. Lean toward
   **opt-in** via a new chezmoi prompt (`installUserZsh = false`
   default) rather than auto-firing on `centos_server` profile.
3. **Where does the bash auto-exec block live?** Either:
   - In a new `dot_bash_profile.tmpl` deployed by chezmoi (composable
     with other login-time bash), gated on `installUserZsh && noRoot`.
   - Or in the new `zsh` ansible role's user-level branch (consistent
     with how the role currently writes other config).

   The chezmoi-template path is cleaner — no ansible state in user's
   shell init.
4. **Cross-distro?** This write-up assumes RedHat-family. Debian
   noRoot doesn't typically need it (zsh is in the default repos
   and `apt install` is the documented expected path). Ubuntu Server
   for hand-built / appliance systems might be a future concern.
5. **Reversibility / rollback?** The role should:
   - Ship a `just zsh-noroot-uninstall` (or similar) recipe that
     removes the bash-profile block (regex-strip BEGIN/END markers),
     deletes `~/.local/bin/zsh`, and prints a one-liner for
     `rm -rf ~/miniforge3` (don't auto-delete Miniforge — user might
     have other conda envs there).

## Open questions

- Is the corporate `yzhang-idc-server104` box the only target? If
  yes, this is over-engineered relative to the value — just `yum
  install zsh` via the admin once and update `pitfalls/centos7-
  noroot.md` to make the precondition louder. Implement the role
  only when a second noRoot RedHat box surfaces.
- Does the Linuxbrew install path on a Rocky 9 noRoot box (`brew
  install zsh`) work? If so, that's a sneaky 4th option for boxes
  with modern enough git that Linuxbrew isn't blocked. Worth a 5-min
  experiment before committing to A as primary.

## References

- Miniforge releases (glibc-2.17 target): https://github.com/conda-forge/miniforge/releases
- conda-forge zsh package: https://anaconda.org/conda-forge/zsh
- mise asdf-zsh plugin (asdf-vm/asdf-zsh): https://github.com/asdf-community/asdf-zsh
- zsh `INSTALL` doc, ncurses requirement: https://zsh.sourceforge.io/Doc/Release/zsh_toc.html
- This conversation's source analyses (Claude + ChatGPT side-by-side):
  `.specstory/history/2026-05-06_13-52-50Z-centos-docker.md`
- Sibling pitfall this would lift one precondition from:
  `pitfalls/centos7-noroot.md` "Required preconditions on a noRoot CentOS box"
