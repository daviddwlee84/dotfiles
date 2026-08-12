# Claude Code desktop notifications silently stop — apprise exits 1 with no output

**Symptoms** (grep this section): every Claude Code `Stop` / `Notification` hook produces no
banner at all, with nothing in any log; `apprise --tag desktop --title t --body b` prints
**nothing** and exits `1`; `apprise -vvv …` says
`WARNING - DBus Notification is currently disabled on this system.` and
`WARNING - Failed to load Apprise configuration from file:///home/<user>/.config/apprise/custom.yaml`;
`/usr/bin/notify-send` works fine by hand; `python3 -c 'import dbus'` succeeds on the *system*
python; `uv tool list` shows `apprise vX.Y.Z`.

**First seen**: 2026-08
**Affects**: Linux hosts where apprise is installed as a **uv tool** (`~/.local/bin/apprise` →
`~/.local/share/uv/tools/apprise/bin/python`). Same failure shape on any isolated venv
(pipx, `python -m venv`). Seen with apprise 1.9.7 and 1.12.0.
**Status**: fixed — apprise reinstalled with `--with dbus-python`, and `notify.sh` now degrades
instead of swallowing the failure.

## Symptom

Two independent bugs stacked, and *both* were invisible at default verbosity:

```console
$ apprise --tag desktop --title t --body b
$ echo $?
1
```

No stdout, no stderr. apprise only prints WARNINGs at `-vvv`:

```console
$ apprise -vvv --tag desktop --title t --body b 2>&1 | grep -i "custom.yaml\|disabled"
WARNING - Failed to load Apprise configuration from file:///home/<user>/.config/apprise/custom.yaml?encoding=utf-8&cache=no
WARNING - DBus Notification is currently disabled on this system.
```

And the hook ended in `apprise … 2>/dev/null || true`, so the exit-1 was discarded: **every
notification since the uv-tool install had been a no-op**, with no trace anywhere.

## Root cause

**1. `dbus://` disables itself in the uv-tool venv.**
`apprise/plugins/dbus.py` sets `NOTIFY_DBUS_SUPPORT_ENABLED = False` and swallows the
`ImportError` when `dbus` / `dbus.mainloop.glib` can't be imported. uv tools live in their own
venv with **no** access to `/usr/lib/python3/dist-packages`, so the distro's `python3-dbus`
package is invisible to apprise no matter how well it works for the system python. A disabled
plugin makes `Apprise.notify()` return `False` → CLI exit 1, and the *reason* is only ever
logged at WARNING level, which the CLI hides unless you pass `-vvv`.

**2. "Failed to load Apprise configuration" does NOT mean malformed YAML.**
`ConfigBase.servers()` (`apprise/config/base.py`) emits that warning for **any** config that
resolves to **zero services** — the message is a misnomer for "empty". `custom.yaml` shipped with
`urls: []` plus commented examples, which parses perfectly (`yaml.safe_load` →
`{'version': 1, 'urls': []}`) but yields zero servers, so `apprise.yaml`'s `include: custom.yaml`
warned on every single run. Chasing it as a YAML syntax error is a dead end.

## Workaround

```bash
# 1. Give the uv-tool venv its own dbus-python (a source build; needs
#    libdbus-1-dev + libglib2.0-dev + python3-dev + pkg-config. meson/ninja are
#    pulled from PyPI by the build backend, no apt needed for those).
uv tool install --force apprise --with dbus-python

# 2. Verify — must be exit 0, and "Sent DBus notification." in the verbose log.
apprise --tag desktop --title verify --body ok; echo $?
apprise -vvv --tag desktop --title t --body b 2>&1 | grep -i "disabled"

# 3. Keep custom.yaml non-empty (it ships with a local-only syslog:// entry).
```

## Prevention

- `dot_claude/hooks/executable_notify.sh.tmpl` is now a three-rung ladder —
  **apprise → `notify-send`/`terminal-notifier` → append to
  `${XDG_STATE_HOME:-$HOME/.local/state}/claude/notify.log`**. Never reduce it back to
  `apprise … || true`: a notifier that fails closed *and* silently is indistinguishable from a
  working one, which is how this went unnoticed.
- `dot_config/apprise/create_custom.yaml` must keep at least one active URL. It is a `create_`
  target, so editing the source does **not** update hosts that already have the file — fix those
  by hand (`install -m 0644 <source> ~/.config/apprise/custom.yaml`).
- **Not yet fixed in ansible**: `dot_ansible/roles/python_uv_tools/defaults/main.yml`'s `apprise`
  entry has no `with: [dbus-python]`, so a fresh Linux provision reproduces bug #1. It can't just
  be added — the role applies `with:` on every OS and `dbus-python` does not build on macOS, and
  the install task's `creates:`-style guard skips reinstall when `~/.local/bin/apprise` already
  exists (same class of trap as
  [`uv-tool-install-creates-guard-misses-executables-from`](uv-tool-install-creates-guard-misses-executables-from.md)).
  A per-tool OS gate is needed first. The notify.sh fallback bounds the damage meanwhile.

## Related

- [`docs/tools/agent-sounds.md`](../docs/tools/agent-sounds.md) — the `agentSounds` prompt and the
  `notify.sh` hook wiring in `dot_claude/modify_settings.json.tmpl`
- [`uv-tool-install-creates-guard-misses-executables-from`](uv-tool-install-creates-guard-misses-executables-from.md)
  — the sibling "uv tool already installed, so the changed install flags never take effect" trap
- [`backlog/audit-monitor-with-apprise.md`](../backlog/audit-monitor-with-apprise.md) — the queued
  apprise routing work; it inherits this venv-isolation constraint for every backend needing a
  compiled dependency
