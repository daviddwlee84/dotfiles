# Scheduled jobs (cron / systemd timers / at / launchd)

Anything that runs on a schedule has two consequences:

1. **Capacity** — it competes for CPU/IO at its scheduled time.
2. **Persistence** — it's the *most common* place attackers hide
   "run my reverse shell every 10 minutes" payloads, because it
   survives reboots without touching `/etc/sudoers` or installing a
   service.

This page covers the inventory: who scheduled what, when does it run,
what does it execute.

## Schedule mechanisms (multi-source reality)

| Mechanism | Where | Scope | Linux | macOS |
|---|---|---|---|---|
| **User crontab** | `crontab -l -u <user>` | Per-user | ✓ | ✓ (deprecated; users encouraged to use launchd) |
| **System crontab** | `/etc/crontab` | Root-owned, central | ✓ | ✓ (less common) |
| **Drop-in cron** | `/etc/cron.d/*` | Package-installed jobs | ✓ | rare |
| **Periodic dirs** | `/etc/cron.{hourly,daily,weekly,monthly}/` | Scripts run by cron at fixed cadence | ✓ | similar via `/etc/periodic/` |
| **anacron** | `/etc/anacrontab` | Catches up on missed runs (laptops) | ✓ | — |
| **systemd timers** | `*.timer` units, `systemctl list-timers` | System or user; preferred over cron on systemd hosts | ✓ | — |
| **at jobs** | `atq`, `at -c <jobid>` | One-shot scheduled commands | ✓ | ✓ |
| **launchd** | `/Library/Launch{Daemons,Agents}/`, `~/Library/LaunchAgents/` | macOS native scheduler + service manager | — | ✓ |

A persistence-aware scan must touch **all** of these. Checking only
`crontab -l` misses ~80% of the surface on a modern Linux box.

## Helpers in this repo

| Function | What it answers |
|---|---|
| `cron-list` | Inventory: all user crontabs + system cron + systemd timers + launchd plists + at jobs |
| `cron-list --user U` | Just U's crontab |
| `cron-list --system` | `/etc/crontab` + `/etc/cron.d/` + `cron.{hourly,...}/` |
| `cron-list --timers` | systemd timers (system + user scope) |

`tv scheduled-jobs` cycles 5 sources via `Ctrl+S`: user crontabs →
system cron → systemd timers → at jobs → anacron (Linux) /
launchd plists (macOS). Preview decodes the schedule, shows the
triggered unit, and (for systemd timers) `systemctl status` of both
the timer and the activated service.

Bound under the channel name `scheduled-jobs` to avoid
genericness — `tv cron` would falsely imply only crontab content.

## Common queries

```bash
# Full inventory
cron-list

# Only what a specific user scheduled
cron-list --user alice

# Only systemd timers (most relevant on modern hosts)
cron-list --timers

# Interactive browse with drill-into-unit
tv scheduled-jobs
```

## Persistence detection cookbook

### "Did anything new appear in the last week?"

If `installAuditd` is on, watch the schedule directories with custom rules:

```bash
# Add to /etc/audit/rules.d/50-local.rules:
-w /etc/cron.d/    -p wa -k cron
-w /etc/crontab    -p wa -k cron
-w /etc/cron.daily/ -p wa -k cron
-w /etc/cron.hourly/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron
-w /etc/systemd/system/ -p wa -k systemd-units
sudo augenrules --load

# Then:
audit-file /etc/cron.d/
audit-file /etc/systemd/system/
```

Without auditd, fall back to mtime:

```bash
find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/systemd/system /var/spool/cron \
  -newer /tmp/last-checked 2>/dev/null
touch /tmp/last-checked   # for next run
```

### "What user crontabs exist that shouldn't?"

```bash
cron-list | grep -A1 '^--- '   # user header lines + first command
```

Cross-check against `user-list --login`. A non-login user with a
crontab is suspicious unless explicitly part of a service (e.g.
`backup` user with a daily job).

### "What's the most disruptive job at 3am?"

```bash
# systemd timers showing next-run
systemctl list-timers --all | sort -k1,3
# Then look at what unit it activates
systemctl cat <unit>.service
```

### "Is anything calling out to the network?"

Combine schedule inventory with `fw-conn` at the right time:

```bash
# Schedule inventory tells you when
cron-list

# At that time, see who's connecting where
fw-conn --all
```

## Caveats

- **`crontab -l -u <other-user>` needs root**. Helpers fall back to
  `sudo -n` once and skip if denied.
- **`/var/spool/cron/crontabs/` is the underlying file location**
  on most distros. `crontab -l` reads it; manual edits to that file
  bypass cron's safety checks (don't do it).
- **systemd timer drift**: `OnBootSec=` / `OnUnitActiveSec=` units
  can drift by minutes. `OnCalendar=` is wall-clock-anchored.
- **launchd `KeepAlive` plists are not scheduled** — they're respawn
  policies, not timers. They show up in our channel because they're
  in the same plist directories, but they run on conditions
  (file change, network state) not time.
- **`atq` shows job IDs not commands**. Use `at -c <jobid>` (or
  `Enter` in the channel) to see the actual script.

## See also

- [Sessions and login](sessions.md) — sometimes a "scheduled" job
  is just an attacker re-logging in via a long-lived SSH session
- [Firewall](firewall.md) — schedule + active connections together
  reveal "this job calls home at 3am"
- [auditd](auditd.md) — extending the baseline rule set to watch
  cron / systemd dirs is in scope; the role doesn't ship that watch
  by default to avoid noise
- [Helpers in this repo](helpers.md)
