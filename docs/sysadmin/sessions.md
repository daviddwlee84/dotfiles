# Sessions and login (Level 0)

This layer answers:

- Who logged in?
- From where (IP, tty)?
- When did they log in / out?
- Did they use SSH or local tty?
- Did they `su` or `sudo -i` into another identity?

## Data sources

| Source | Where | What it has | Platform |
|---|---|---|---|
| `last` | Reads `/var/log/wtmp` (binary) | Login/logout pairs, durations, source IP, tty | macOS + Linux |
| `lastlog` | Reads `/var/log/lastlog` | Last login per UID | Linux |
| `who -a` | Reads `/var/run/utmp` | Currently-logged-in sessions | macOS + Linux |
| `journalctl _COMM=sshd` | systemd journal | Per-connection sshd events (auth attempts, accepted/failed, key fingerprints, channel open/close) | Linux + systemd |
| `/var/log/auth.log` | Plain text, rotated by logrotate | sshd, sudo, login, cron auth | Debian / Ubuntu / Raspberry Pi OS |
| `/var/log/secure` | Plain text, rotated by logrotate | Same scope as auth.log | RHEL / CentOS / Rocky / Alma / Fedora |
| `/var/log/btmp` | Binary, read with `lastb` | **Failed** login attempts | Linux |

**Distro split**: Debian-family writes to `/var/log/auth.log`; RHEL-family
writes to `/var/log/secure`. On systemd hosts both are usually mirrored
into the journal — querying the journal works on both, querying the file
needs distro detection.

The systemd journal is structured: entries carry metadata (`_PID`,
`_UID`, `_COMM`, `_SYSTEMD_UNIT`, etc.) and the journal files are
protected against tampering by ordinary users (Red Hat docs). Use the
`_FIELD=value` filter syntax for precise queries.

## Common queries

```bash
# All logins this week (most recent first)
last -F -i | head -50

# Failed login attempts (Linux)
sudo lastb -F -i | head -50

# Currently-logged-in users
who -a

# Last login of every account that ever logged in (Linux)
lastlog | awk 'NR==1 || $2 != "**Never"'

# All sshd events for one user, last 24h (systemd)
sudo journalctl _COMM=sshd --since '24h ago' | grep " <user> "

# Auth log tail (Debian/Ubuntu)
sudo tail -F /var/log/auth.log

# Auth log tail (RHEL/CentOS)
sudo tail -F /var/log/secure
```

## Caveats

- `last` reports **session boundaries**, not commands. A 6-hour session
  could mean active typing or an idle SSH connection.
- `wtmp` rotates (logrotate moves it to `wtmp.1`, `wtmp.2.gz`, …). For
  history older than the current rotation window: `last -f
  /var/log/wtmp.1`.
- A user with root can edit / wipe `/var/log/wtmp` and the journal. The
  journal is structured to make this *harder* (cryptographic seals via
  `journalctl --setup-keys` / `--verify`) but not impossible without
  offsite log shipping.
- `who` reflects current state from `utmp`, which can be inconsistent
  if a session crashed without writing a logout record.

## How this repo helps

- **Shell helper**: `audit-sessions [user]` — wraps `last -F -i` +
  `lastlog` + currently-active sessions. Defined in
  `dot_config/shell/45_audit.sh.tmpl` (POSIX, both zsh and bash).
- **Television channel**: `tv sessions` — fuzzy-browse rows from `last`,
  `lastlog`, `journalctl _COMM=sshd`, and `who -a`. Preview pane shows
  per-user details. Source cycles via `Ctrl+S`.
- See [Helpers in this repo](helpers.md) for the full table.

## See also

- [sudo auditing](sudo-audit.md) — what users did *after* logging in
- [auditd framework](auditd.md) — `aureport -au` for kernel-level
  authentication summary
- [shells/history.md](../shells/history.md) — why `~/.bash_history` /
  `~/.zsh_history` should not be confused with login records
