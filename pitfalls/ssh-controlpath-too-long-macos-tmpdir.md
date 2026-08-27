# `ControlPath too long ('…' >= 104 bytes)` — and everything it breaks silently

**Symptoms** (grep this section):

```
ControlPath too long ('/var/folders/dq/zbxks7r975j049mj8jk19wtw0000gp/T//ssh-setup.L5o3Cy/03d4906e…' >= 104 bytes)
```

More often you never see that line at all. What you see instead, from
`ssh-setup-remote`, is a cascade of misleading messages:

```
Probing zr-windows ...
Could not identify the remote OS.
Is zr-windows a Windows (OpenSSH sshd) machine? [y/N] y

> ssh zr-windows (PowerShell: append to ~/.ssh/authorized_keys)
Key install on zr-windows produced no output — verify manually.
Setup for zr-windows failed.
```

…and the wizard never asks about `~/.ssh/config`, because the failed install
aborted the remaining steps.

**First seen**: 2026-08-27, on macOS, setting up a ProxyJump chain
(`zr` via `zr-windows`).
**Affects**: anything that builds a `ControlPath` under `$TMPDIR` on macOS —
`ssh-setup-remote` before the bounded-path fix, and hand-written
`ssh -o ControlPath="$TMPDIR/..."` invocations.
**Status**: fixed in `dot_config/shell/96_ssh_setup.sh`. The socket directory
is now chosen from `/tmp` → `$TMPDIR` → `~/.ssh`, and only accepted if it
leaves the expanded path inside the limit; if none fits, multiplexing is
skipped with a note rather than breaking every connection.

## Root cause

A `ControlPath` becomes the `sun_path` of a `sockaddr_un`, which is **104
bytes on macOS/BSD** (108 on Linux) *including* the terminating NUL. Two
things eat that budget fast:

| Piece | Bytes |
|---|---|
| `$TMPDIR` on macOS — `/var/folders/<2>/<26>/T/` | ~49 |
| `%C` (the connection hash) | 40 |

So the natural-looking `"$TMPDIR/ssh-setup.XXXXXX/%C"` measures **107 bytes**
and `ssh` refuses it. Critically it refuses *before opening a socket*, exiting
**255** — the same code as "host unreachable".

That is why the failure looked like a remote-OS problem: every probe in the
wizard redirected stderr to `/dev/null`, so an rc-255 transport failure
arrived as empty stdout, which the code read as "the remote said nothing".
Only `ssh-copy-id`, which does not hide stderr, ever showed the real message.

Two lessons, both now encoded in `tests/unit/ssh_setup.bats`:

1. **Bound the ControlPath and assert it.** `%C` is a fixed 40 characters, so
   the check is arithmetic, not luck.
2. **Never send ssh's stderr to `/dev/null`.** Distinguish rc 255 (ssh itself
   failed — say why) from any other rc (the remote ran something and it
   failed). Conflating them turns a one-line diagnosis into a wild goose chase.

## Workaround (any version)

```bash
export SSH_SETUP_NO_MUX=1     # skip multiplexing entirely
# or, for hand-rolled ssh:
ssh -o ControlPath=/tmp/cm-%C ...
```

Check any candidate before trusting it:

```bash
python3 - <<'PY'
p = "/tmp/cm-" + "0"*40
print(len(p), "OK" if len(p) < 104 else "TOO LONG")
PY
```

## Related

- `pitfalls/ssh-copy-id-failed-to-open-id-file-no-such-file.md` — the other
  half of the same wizard's failure story.
- `docs/tutorials/setup_ssh_key_on_remote.md` → Troubleshooting.
