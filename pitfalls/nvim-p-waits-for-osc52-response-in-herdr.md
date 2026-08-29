# Neovim `p` waits for `Waiting for OSC 52 response from the terminal` inside Herdr

**Symptoms** (grep this section): `Waiting for OSC 52 response from the terminal. Press Ctrl-C to interrupt...`; `Timed out waiting for a clipboard response from the terminal`; ordinary Neovim `p` pauses for one to ten seconds; local development inside Herdr feels laggy after enabling cross-machine yank.
**First seen**: 2026-08
**Affects**: Neovim 0.10+ with `clipboard=unnamedplus` and a full `vim.ui.clipboard.osc52` provider inside Herdr (also possible in other multiplexers/terminals that forward OSC 52 writes but not query responses).
**Status**: fixed — remote/multiplexer Neovim uses copy-only OSC 52; normal paste stays on editor registers.

## Symptom

Inside a Herdr pane, yank reaches the attached machine's clipboard, but a
normal paste can display:

```text
Waiting for OSC 52 response from the terminal. Press Ctrl-C to interrupt...
```

If left alone, Neovim can later report:

```text
Timed out waiting for a clipboard response from the terminal
```

Reproduction before the fix:

1. Set `vim.opt.clipboard = "unnamedplus"`.
2. Configure both `osc52.copy()` and `osc52.paste()` as `vim.g.clipboard`.
3. Start Neovim in Herdr and press `p`.
4. Neovim waits one second, prints the first message, then waits up to nine
   more seconds for a response Herdr does not forward.

## Root cause

OSC 52 writes and reads are asymmetric. A write is a one-way escape sequence
that Herdr can forward to the attached terminal. A read sends `OSC 52 ; ?` and
requires the outer terminal's response to travel back through every layer into
Neovim. Herdr supports the write path but not this duplex clipboard-query path
([upstream discussion #579](https://github.com/ogulcancelik/herdr/discussions/579),
[#1425](https://github.com/ogulcancelik/herdr/discussions/1425)).

Commit `51a95ce` correctly selected OSC 52 inside Herdr so cross-machine yanks
would stop hitting a stale server-side `pbcopy`/`wl-copy`. It also installed
`osc52.paste()` while leaving `clipboard=unnamedplus`, however, so ordinary
`p` became an OSC 52 clipboard read. Neovim's bundled provider waits one second
before showing the message, then another nine seconds before timing out.

## Workaround / fix

`dot_config/nvim/lua/config/options.lua` now splits the two directions:

- Direct local sessions retain native `clipboard=unnamedplus`.
- SSH/Herdr/Zellij set `clipboard` empty so ordinary `p` uses Neovim's unnamed
  register.
- `TextYankPost` sends yanks (not deletes/changes) to `+` through OSC 52.
- The custom `+`/`*` paste functions only replay content copied earlier by the
  same Neovim process. They never call `vim.ui.clipboard.osc52.paste()`.
- Paste external clipboard text with the terminal's native `Cmd+V` /
  `Ctrl+Shift+V` path.

Temporary local-only escape hatch on the pre-fix config:

```sh
X_CLIPBOARD=pbcopy nvim
```

That restores native macOS paste but is not a cross-machine fix: after attaching
remotely to the same long-lived Herdr pane, `pbcopy` targets the server again.

## Prevention

- Never combine `clipboard=unnamedplus` with `osc52.paste()` in a pane whose
  attached client can change or whose multiplexer lacks clipboard-query
  forwarding.
- Keep `tests/unit/nvim_clipboard.bats`: it stubs `osc52.paste()` to fail if the
  provider ever wires it back in, and verifies that normal `p` stays internal.
- Keep the warning comment beside the provider selection in `options.lua`.

This remains a pitfall rather than a new `AGENTS.md` invariant because the
contract is already above its headroom target; the executable regression test
is the stronger enforcement surface here.

## Related

- [`docs/tools/clipboard.md`](../docs/tools/clipboard.md) — current clipboard
  behaviour and verification.
- [`x-copy-over-ssh-writes-remote-clipboard-not-osc52.md`](x-copy-over-ssh-writes-remote-clipboard-not-osc52.md)
  — the frozen Herdr environment problem that motivated `51a95ce`.
- [`docs/tools/herdr.md`](../docs/tools/herdr.md) — pane environment and remote
  attach model.
