# Yazi inside tmux `display-popup` crashes the tmux server

**Symptoms** (grep this section): `Terminal response timeout: The request sent
by Yazi didn't receive a correct response`, `[server exited unexpectedly]`,
tmux server dies and **all sessions on that socket are lost** when you launch
yazi from a `display-popup -E` binding.
**First seen**: 2026-04, yazi 0.4.x in Ghostty + tmux 3.5a on macOS
**Affects**: any `bind-key … display-popup -E "yazi"` binding; same setup
launched in a regular tmux pane / window works fine.
**Status**: documented workaround (use `new-window` instead of `display-popup`);
upstream tracking at <https://yazi-rs.github.io/docs/faq#trt>.
This repo no longer ships a yazi tmux binding (use `yazi` from a regular
shell), but the pitfall is kept here so future-you doesn't waste time
re-discovering it if you ever try to add a yazi popup binding back.

## Symptom

Bind yazi to a popup, e.g.:

```tmux
bind-key e display-popup -E -w 90% -h 90% -d '#{pane_current_path}' \
  -T ' yazi ' "yazi"
```

Press `prefix + e`. Yazi opens, then within a few seconds prints:

```
Terminal response timeout: The request sent by Yazi didn't receive a correct response.
Please check your terminal environment as per: https://yazi-rs.github.io/docs/faq#trt
[server exited unexpectedly]
```

The popup closes. The **entire tmux server** is gone — `tmux ls` reports no
sessions, every other window/pane on that socket is dead. `tmux-resurrect` /
`tmux-continuum` can restore session names + window layouts on the next
`prefix + Ctrl-r`, but in-flight shell state (running `git rebase -i`, an
unsaved nvim buffer, a long-running command) is lost.

## Root cause

Yazi probes the host terminal at startup with CSI / DA1 / DSR queries to
detect supported image protocols (Kitty graphics, Sixel, iTerm2 inline
images). It expects a reply on stdin within a short timeout (default ~1s).

Inside `display-popup -E`, tmux opens a new client tied to the popup; the
input/output routing for terminal-capability replies does **not** mirror a
normal pane's plumbing. The reply either never reaches yazi or arrives
malformed. When yazi's timeout fires it `panic!`s, and because the popup's
PTY master is owned by the tmux server process, the panic propagates as a
fatal terminal error that takes the **server** down rather than just the
popup client.

Why it works in a normal pane: the pane's PTY is a regular tmux child; the
DA1/DSR cycle goes terminal → outer ghostty → tmux server → pane PTY → yazi
and back, which yazi handles correctly. The popup short-circuits that path.

Related upstream:

- yazi FAQ "trt" entry: <https://yazi-rs.github.io/docs/faq#trt>
- yazi discussion #1306 (terminal probe in tmux popups):
  <https://github.com/sxyazi/yazi/discussions/1306>
- tmux changelog around `display-popup` PTY handling (no fix yet)

## Workaround

**Don't run yazi inside `display-popup`.** Use `new-window` so yazi gets a
real pane:

```tmux
# Lowercase 'e' (uppercase E is select-layout -E).
bind-key e new-window -c '#{pane_current_path}' -n yazi "yazi"
```

Trade-off: not floating, takes a window slot. Mitigations:

- `prefix + z` zooms the yazi window full-screen (close to the popup feel).
- `set -g renumber-windows on` (already on in `common.conf`) keeps window
  indices contiguous when you close yazi.
- Quit yazi with `q` returns to the previous window automatically because
  the new window's only pane exits.

Other tools that probe terminal capabilities (e.g. `bat`, `glow`, `lazygit`,
`btop`) do **not** trigger this — they either skip image-probe entirely or
handle the timeout gracefully. Only yazi (and possibly future TUI image
viewers) needs this special-case.

## Prevention

When adding a `bind-key … display-popup -E "<tool>"` binding, smoke-test the
tool inside the popup for at least a minute and watch for `Terminal response
timeout`-style errors. If the tool sends terminal capability probes (image
protocol detection, OSC 11 background-color, etc.) consider using
`new-window` or a regular split instead.

Repo bindings checked safe in popup as of 2026-04: `lazygit`, `tv sesh`,
`tv tools`, `sesh picker -i`, sesh+fzf pickers. Bindings checked unsafe:
`yazi` (this doc).
