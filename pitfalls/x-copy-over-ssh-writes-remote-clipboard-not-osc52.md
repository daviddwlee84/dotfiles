# `x copy` over SSH puts nothing on the local clipboard (writes the remote box's clipboard instead of OSC 52)

**Symptoms** (grep this section):

- SSH'd into a Linux desktop; `abspath | x copy`, `cref`, `printf x | x copy`
  all report success but **nothing** appears on the clipboard of the machine
  you're typing on.
- No error. `x paste` on the remote *does* show the text — it went to the
  remote's clipboard.
- Neovim yank over the same SSH session works fine (it lands locally via
  OSC 52), so it looks like an `x`-only bug.
- `echo "$WAYLAND_DISPLAY $DISPLAY"` in the SSH shell is **non-empty**
  (e.g. `wayland-1 :0`) even though you did not `ssh -X`.

**First seen**: 2026-08
**Affects**: `dot_dotfiles/bin/executable_x` before the SSH gate; any host
where you are logged in graphically (niri / GNOME) *and* SSH into the same
user account.
**Status**: fixed — `x` sends OSC 52 first when `SSH_CONNECTION` /
`SSH_TTY` / `SSH_CLIENT` is set.

## Root cause

`x`'s `copy_backend()` chose a backend purely by "is `$WAYLAND_DISPLAY` /
`$DISPLAY` set and is `wl-copy` / `xclip` installed?" — with **no SSH
check**. Neovim's `options.lua` gates on `SSH_CONNECTION || SSH_TTY`; `x`
did not.

`WAYLAND_DISPLAY` / `DISPLAY` leak into an SSH shell whenever the same user
has a graphical session: the compositor runs
`systemctl --user import-environment` /
`dbus-update-activation-environment`, `loginctl enable-linger` keeps the
user manager alive, and `pam_systemd` hands the SSH session a slice of that
environment. So `x copy` found `wl-copy` + a live `$WAYLAND_DISPLAY` and
wrote to the **remote** compositor's clipboard.

Installing `wl-clipboard` (see
[`lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md`](lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md))
made this *more* likely to bite, because before that there was no `wl-copy`
to pick and `x` fell through to OSC 52 by accident.

## Workaround / fix

Fixed in `executable_x`:

- `is_ssh()` helper (`SSH_CONNECTION` / `SSH_TTY` / `SSH_CLIENT`).
- `copy_backend()`: under SSH, try `osc52_copy` **first**; fall through to
  `wl-copy` / `xclip` / `xsel` only if `/dev/tty` can't be opened (no-PTY
  `ssh`, or a deliberate `ssh -X` wanting the remote X clipboard).
- `osc52_copy()` now does `{ : >/dev/tty; } 2>/dev/null || return 1` instead
  of `[[ -w /dev/tty ]]` — a detached context can have a `/dev/tty` node
  whose `open(2)` returns `ENXIO`; the old test passed and then `base64`
  consumed stdin before the write failed, starving the fallback.
- `copy_file_backend()`: refuses over SSH (a file object can't cross OSC 52).

Manual, pre-fix: `unset WAYLAND_DISPLAY DISPLAY; abspath | x copy`.

If `x copy` over SSH *still* doesn't reach the local clipboard after the fix,
the problem is downstream: the **local** terminal doesn't forward OSC 52, or
a **local** tmux server started before `set-clipboard on` was applied
(`tmux kill-server` and reattach). See [`clipboard.md`](../docs/tools/clipboard.md).

## Related

- [`docs/tools/clipboard.md`](../docs/tools/clipboard.md) § Shell CLI — `x`
  (the SSH ordering note + failure-modes table).
- `dot_config/nvim/lua/config/options.lua` — the `SSH_CONNECTION` gate `x`
  now mirrors.
- [`lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md`](lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md)
  — the clipboard-CLI install that surfaced this.
