# Service health

A health-focused complement to the existing `tv services` channel
(which is productivity-focused). Surfaces:

- **Failed units** (`systemctl --failed`)
- **Restart-looping units** (`NRestarts > 3`)
- **Recent OOM kills** (`journalctl -k | grep -iE 'out of memory|oom-killer'`)
- **Recent error-level crashes** (`journalctl -p err`)

For the dense reference table see
[helpers.md → tv services-health](helpers.md#television-channels). For
the morning-summary command that wraps these signals into one verdict
line see `health-check` in
[helpers.md → Live monitor + morning summary](helpers.md#live-monitor--morning-summary).

## Quick uses

```bash
# Interactive
tv services-health

# CLI verdict (one line)
health-check --quick

# Full dump
health-check --full
```

`tv services-health` keybindings:

- `Enter` — open full unit logs in `lnav`
- `Alt+R` — restart unit (asks for confirmation)
- `Alt+S` — stop unit (asks for confirmation)
- `Alt+E` — `systemctl edit --full <unit>`

## Why a separate channel from `tv services`?

`tv services` (in [`dot_config/television/cable/services.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/cable/services.toml.tmpl))
lists everything for a productivity workflow ("which app's daemon
do I need to restart?"). `tv services-health` filters down to the
subset that actually indicates a problem — failed, restart-looping,
OOM-killed — to support the morning health check without scrolling
past 200 healthy services.

Both channels coexist; pick the one whose framing matches the question.

## macOS notes

- launchd's "errored" detection uses `Status != 0 AND Status != "-"`
  in `launchctl list` output. This matches services that exited
  with non-zero but doesn't catch services that should be running
  but were `bootout`'d cleanly.
- `Alt+R` on macOS uses `launchctl kickstart -k user/<uid>/<label>`
  rather than restart, because launchd doesn't have a single-step
  "restart" verb.

## See also

- [auditd framework](auditd.md) — service crashes that are
  security-relevant (sshd, sudo, audit itself) deserve audit rules
  too
- [scheduled jobs](scheduled-jobs.md) — restart loops are often
  caused by a misconfigured `Restart=always` on a unit that
  legitimately can't start
- [Cookbook recipe 12](cookbook.md#12-network-exposure--persistence-the-weekly-sweep)
