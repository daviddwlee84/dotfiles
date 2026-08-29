# `x copy` / Neovim yank land on the wrong clipboard inside herdr (or any multiplexer that strips `SSH_*`)

**Symptoms** (grep this section):

- Working on a remote box **inside herdr** (or zellij, mosh, VS Code / Cursor
  Remote-SSH). `abspath | x copy`, `cref`, `printf x | x copy` all report
  success but **nothing** reaches the clipboard of the machine you're typing
  on. `x paste` on the remote *does* show the text — it went to the remote's
  clipboard.
- Neovim `yy` / `"+y` over the same session also doesn't reach your local
  clipboard (same root cause).
- `echo "$SSH_CONNECTION | $SSH_TTY | $SSH_CLIENT"` in the pane is **all
  empty**, yet `echo "$WAYLAND_DISPLAY $DISPLAY"` is set
  (e.g. `wayland-0 :0`).
- A raw OSC 52 write **does** work:
  `printf '\033]52;c;%s\033\\' "$(printf hi | base64)" > /dev/tty` lands on
  the local clipboard. So the terminal chain is fine — only `x` / nvim pick
  the wrong backend.

**First seen**: 2026-08
**Affects**: `dot_dotfiles/bin/executable_x` and
`dot_config/nvim/lua/config/options.lua` before the `prefer_osc52` /
`HERDR_ENV` gate.
**Status**: fixed — both send OSC 52 writes inside herdr/zellij and honour an
`X_CLIPBOARD` override; Neovim keeps the read side local to its own registers.

## Root cause

Two independent bugs compounding:

1. **Backend chosen by `$WAYLAND_DISPLAY`/`$DISPLAY` presence, with no
   "am I remote?" check.** `x`'s `copy_backend()` and nvim's `options.lua`
   both did this. nvim gated its OSC 52 override on `SSH_CONNECTION` /
   `SSH_TTY`; `x` had no SSH awareness at all.

2. **The herdr server is a persistent daemon and freezes its pane
   environment.** Every shell in a herdr pane inherits the env that existed
   when the *server* first started — a graphical login → `WAYLAND_DISPLAY`,
   `DISPLAY`, `XDG_SESSION_TYPE=wayland`. It never refreshes `SSH_CONNECTION`
   on a new client attach the way `tmux` does via `update-environment`. So a
   herdr pane over SSH looks *exactly* like a local Wayland terminal:
   `$WAYLAND_DISPLAY` set, `$SSH_*` empty. `x` / nvim pick `wl-copy` and
   write the **remote** compositor's clipboard. mosh (which deliberately
   unsets `SSH_*`) and older VS Code Remote-SSH hit the same shape.

   The herdr pane's **TTY**, however, always proxies to the real client
   (local or remote) — so OSC 52 is the correct channel regardless.

## Workaround / fix

`dot_dotfiles/bin/executable_x`:

- `prefer_osc52()` — true under `SSH_*`, `HERDR_ENV`, or `ZELLIJ`. Used
  instead of the old `is_ssh` gate: try `osc52_copy` first, fall through to
  `wl-copy`/`xclip`/`xsel` only if `/dev/tty` won't open.
- `osc52_copy()` opens `/dev/tty` for real (`{ : >/dev/tty; }`) before
  `base64` consumes stdin, so the fallback still has input.
- `X_CLIPBOARD` env var forces one backend, bypassing autodetect:
  `osc52 | wl-copy | xclip | xsel | pbcopy | clip.exe`. Honoured by `x copy`
  and `x paste`; `x copy-file` refuses under `osc52` / `prefer_osc52`.
- `copy_file_backend()` refuses over SSH/herdr (OSC 52 is text-only).

`dot_config/nvim/lua/config/options.lua`: copy-only OSC 52 now activates on
`SSH_CONNECTION` / `SSH_TTY` / `SSH_CLIENT` / `HERDR_ENV` / `ZELLIJ`, or
`X_CLIPBOARD=osc52`; `X_CLIPBOARD=<local tool>` opts back out. Normal `p`
uses Neovim's unnamed register and never queries the terminal clipboard. Keep
the selection predicate in sync with `prefer_osc52`, but not the paste path —
see [`nvim-p-waits-for-osc52-response-in-herdr.md`](nvim-p-waits-for-osc52-response-in-herdr.md).

**For a box you always reach through a multiplexer that hides `SSH_*`**
(and it isn't herdr/zellij — e.g. plain mosh), put this in
`~/.shellrc.adhoc` on that box:

```sh
export X_CLIPBOARD=osc52
```

If `x copy` / yank *still* doesn't reach the local clipboard after this, the
blocker is downstream: the **local** terminal doesn't forward OSC 52, or a
stale **local** tmux server (`tmux kill-server`). Confirm with the raw
`printf '\033]52;c;…'` test above.

## Related

- [`docs/tools/clipboard.md`](../docs/tools/clipboard.md) § Shell CLI — `x`
  and § Editor — Neovim (the `prefer_osc52` predicate + `X_CLIPBOARD` knob).
- [`docs/tools/herdr.md`](../docs/tools/herdr.md) § env vars — `HERDR_ENV=1`
  is the "am I in herdr?" signal; the frozen-env behaviour.
- [`lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md`](lazygit-ctrl-o-no-clipboard-utilities-nvim-yank-silent.md)
  — the clipboard-CLI install that surfaced this (before it, `x` fell
  through to OSC 52 by accident because there was no `wl-copy` to pick).
- [`nvim-p-waits-for-osc52-response-in-herdr.md`](nvim-p-waits-for-osc52-response-in-herdr.md)
  — why the Neovim half must use OSC 52 for writes only.
