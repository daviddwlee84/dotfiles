# tmux-appimage aborts with "missing or unsuitable terminal: xterm-256color"

**Symptoms** (grep this section): `tmux` / `tmux attach` / `tmux new` exits with `missing or unsuitable terminal: xterm-256color`; `tmux ls` works fine; `/bin/tmux` (system apt tmux) works fine; `~/.local/bin/tmux -V` prints version OK; `infocmp xterm-256color` from the host shell works; `$TERM` is the normal `xterm-256color`; `strace -f -e openat ~/.local/share/tmux-appimage/squashfs-root/usr/bin/tmux new-session …` shows **zero** `openat` calls touching any `terminfo` path.
**First seen**: 2026-05
**Affects**: [`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage) extracted via `--appimage-extract` to `~/.local/share/tmux-appimage/squashfs-root/`, on hosts where Linuxbrew tmux is unavailable (Ubuntu 22.04 jammy without `brew`). Triggered by the `devtools` ansible role's tmux-appimage fallback path; see [docs/tools/tmux/README.md](../docs/tools/tmux/README.md) → "Why ≥ 3.3" and the apt-too-old upgrade story.
**Status**: fixed in [`dot_ansible/roles/devtools/tasks/main.yml`](../dot_ansible/roles/devtools/tasks/main.yml) — wrapper at `~/.local/bin/tmux` now exports `TERMINFO_DIRS` to the system terminfo paths before `exec`-ing the bundled tmux binary.

## Symptom

```text
$ tmux
missing or unsuitable terminal: xterm-256color

$ /bin/tmux ls
0: 12 windows (created Mon Dec  1 15:51:03 2025)
…

$ which tmux
/home/ldw/.local/bin/tmux

$ ~/.local/bin/tmux ls           # this works too — confusing
…
$ ~/.local/bin/tmux              # this fails
missing or unsuitable terminal: xterm-256color
```

The misleading partial success happens because **only the tmux *client* /
attach codepath needs terminfo** to set up the on-screen renderer for the
current `$TERM`. Pure server commands (`ls`, `new-session -d`, `kill-server`)
never touch terminfo — they succeed even when terminfo lookup is broken.

So the symptom matrix is:

| Command | Needs terminfo? | What you see |
|---|---|---|
| `tmux ls` | No | Works |
| `tmux new-session -d -s X` | No | Works |
| `tmux kill-session -t X` | No | Works |
| `tmux` / `tmux attach` / `tmux new` | **Yes** | `missing or unsuitable terminal: xterm-256color` |

## Root cause

[`nelsonenzo/tmux-appimage`](https://github.com/nelsonenzo/tmux-appimage)
ships a self-contained AppImage with bundled `libevent` and `libncurses`.
The bundled `libncurses.so.6` was compiled with a hardcoded terminfo
search path that points inside the original AppImage FUSE mount
(`/tmp/.mount_*/usr/share/terminfo`). Once you extract the AppImage with
`--appimage-extract` and run the inner binary directly (which we do, to
avoid needing FUSE on servers), that compile-time path no longer exists.

Worse, ncurses does **not** fall back to the standard `/etc/terminfo`,
`/lib/terminfo`, `/usr/share/terminfo` paths in this configuration —
strace confirms zero `openat` calls touching any terminfo path:

```text
$ script -q -c "strace -f -e openat -o /tmp/t.log \\
    ~/.local/share/tmux-appimage/squashfs-root/usr/bin/tmux new-session -d -s _p" /dev/null
missing or unsuitable terminal: xterm-256color
$ grep -iE "terminfo|/x/" /tmp/t.log
$    # ← empty: terminfo lookup never even started
```

This is a long-standing ncurses behaviour — when the search path is
configured at build time and the build target's path doesn't resolve, it
short-circuits rather than walking the standard fallbacks.

## Fix

Set `TERMINFO_DIRS` in the wrapper that the role installs at
`~/.local/bin/tmux`. Once `TERMINFO_DIRS` is in the environment, ncurses
walks it explicitly and finds `xterm-256color` in the system path.

The wrapper now reads:

```bash
#!/bin/bash
# Wrapper around tmux-appimage extracted at ~/.local/share/tmux-appimage.
appimage_root="$HOME/.local/share/tmux-appimage/squashfs-root"
export TERMINFO_DIRS="${TERMINFO_DIRS:-/etc/terminfo:/lib/terminfo:/usr/share/terminfo}:$appimage_root/usr/share/terminfo"
exec "$appimage_root/usr/bin/tmux" "$@"
```

Two design choices:

1. **System paths first, bundled last.** The bundled `terminfo/` is
   complete (includes `xterm-256color`, `tmux-256color`, etc.) but lags
   the host's. Prefer the host's so e.g. a newer `kitty` / `ghostty`
   terminfo on the user's machine wins over the AppImage's older copy.
2. **`${TERMINFO_DIRS:-…}` not bare assignment.** Respects any value the
   user already set in their shell profile (e.g. someone shipping their
   own terminfo dir in `~/.terminfo`).

Verify after applying:

```bash
chmod +x ~/.local/bin/tmux
~/.local/bin/tmux new-session -d -s _verify
script -q -c "~/.local/bin/tmux attach -t _verify" /dev/null   # should not error
~/.local/bin/tmux kill-session -t _verify
```

## Why `infocmp xterm-256color` from the host shell worked

Because the host's `infocmp` is the **system ncurses**, which has the
correct compile-time search path (`/lib/terminfo`, `/etc/terminfo`,
`/usr/share/terminfo`). The breakage is specific to the AppImage's
**bundled** ncurses inside `squashfs-root/usr/lib/`. Different binary,
different compile-time terminfo path.

## Why `/bin/tmux` worked

Because that's the apt-installed system tmux, also linked against the
system ncurses. The version is just too old (3.2a on jammy) for some of
this repo's keybindings — that's exactly why we install tmux-appimage on
top of it via the `devtools` role.

## Generalising — other AppImage-extracted tools

Any tool that:

1. Bundles its own ncurses (or another lib that hardcodes a data-dir
   path at build time), and
2. Was distributed as an AppImage, then extracted with
   `--appimage-extract` and called directly,

can hit the same class of failure. Symptoms vary: terminfo for
ncurses-bundling tools; `gconv` data ("conversion ... not supported")
for tools that bundle their own glibc fragments; `LC_*` failures for
tools bundling locale archives. The general fix is to search the
bundled `share/` directory tree for the data the tool needs, then point
the relevant env var at the system equivalent.

## See also

- [`docs/tools/tmux/README.md`](../docs/tools/tmux/README.md) → "Why ≥ 3.3"
  for the apt-too-old context that forces the tmux-appimage detour.
- [`dot_ansible/roles/devtools/tasks/main.yml`](../dot_ansible/roles/devtools/tasks/main.yml)
  → tmux-appimage block (search for "Upgrade tmux via tmux-appimage").
