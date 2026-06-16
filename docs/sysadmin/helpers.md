# Helpers in this repo

Reference for the audit-related helpers that this dotfiles repo ships.
All are documented one level up in the [section README](README.md);
this page is the dense lookup table.

## Shell functions

Defined in
[`dot_config/shell/45_audit.sh.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/45_audit.sh.tmpl).
POSIX-shaped so both zsh and bash get them. Source-time shell detection
handles the few zsh-only convenience bits.

| Function | What it answers | Wraps | Needs sudo? | Platforms |
|---|---|---|---|---|
| `audit-sessions [user]` | Who logged in? when? from where? | `last -F -i` + `lastlog` (Linux) + `who -a` | No (sudo only for `lastb`) | macOS + Linux |
| `audit-failed-logins` | Failed login attempts | `lastb -F -i` | Yes | Linux |
| `audit-sudo [user]` | Who used sudo and what top-level command? | `journalctl _COMM=sudo` (systemd) or `grep sudo /var/log/auth.log\|/var/log/secure` | Often yes | Linux (best on systemd) |
| `audit-execve <pattern>` | Did anyone exec `<pattern>`? | `ausearch -sc execve -x <pattern> -i` | Yes | Linux + auditd |
| `audit-file <path>` | Who touched this file? | `ausearch -f <path> -i` | Yes (also requires watch rule) | Linux + auditd |
| `audit-summary [--start <when>]` | Daily security summary | `aureport --summary -i` + `aureport -au -i` + `aureport -x -i` | Yes | Linux + auditd |
| `audit-rules-show` | Currently loaded vs persisted rules | `auditctl -l` + `cat /etc/audit/rules.d/*.rules` | Yes | Linux + auditd |

### User-inventory helpers

Backing data sources differ macOS (`dscl`) vs Linux (`getent`); the
helpers are templated to use the right one per host.

| Function | What it answers | Wraps | Needs sudo? | Platforms |
|---|---|---|---|---|
| `user-list [--login]` | Which user accounts exist on this box? | `getent passwd` (Linux) / `dscl . -list /Users` (macOS) | No | macOS + Linux |
| `user-info <user>` | Full identity dump for one user (id, groups, passwd, last login, sudo events, SSH key count) | composite | Some sections need sudo | macOS + Linux |
| `user-groups <user>` | Which groups is this user in? | `id -Gn <user>` sorted | No | macOS + Linux |
| `group-members <group>` | Who is in this group? | `getent group` (Linux) / `dscl . -read /Groups/<g>` (macOS) | No | macOS + Linux |
| `user-sudoers` | Who can sudo? (sudo/wheel/admin members + `/etc/sudoers.d/`) | composite | Yes (reads `/etc/sudoers`) | macOS + Linux |
| `user-ssh-keys [user]` | Who has authorized_keys, with fingerprint + comment? | scans `~/.ssh/authorized_keys`; `ssh-keygen -lf -` for fingerprint | Yes for other users' files | macOS + Linux |
| `user-recent-changes [--days N]` | Recent edits to passwd/shadow/sudoers (auditd) | `ausearch -k identity` + `-k sudoers` | Yes | Linux + auditd |

### Firewall + scheduled-job helpers

| Function | What it answers | Wraps | Needs sudo? | Platforms |
|---|---|---|---|---|
| `fw-rules` | Active firewall rules across all backends | `nft list ruleset` / `iptables -S` / `ufw status` / `firewall-cmd --list-all` (Linux); `pfctl -s rules` + ALF (macOS) | Yes | macOS + Linux |
| `fw-listening` | Bound TCP+UDP sockets with owning process | `ss -tlnp` / `ss -ulnp` (Linux); `lsof -nP -iTCP -sTCP:LISTEN` fallback | Yes for full process info | macOS + Linux |
| `fw-conn [--all]` | Established TCP connections (or all states with --all) | `ss -tnp state established` | Yes for process info | macOS + Linux |
| `fw-port <port>` | Who is using `<port>`? (LISTEN + ESTABLISHED + `/etc/services`) | `ss` / `lsof` filtered to port | Yes | macOS + Linux |
| `cron-list [--user U \| --system \| --timers]` | All scheduled jobs: user crontabs + system cron + systemd timers + at + launchd | composite | Sometimes (other users' crontabs) | macOS + Linux |

### Live monitor + morning summary

| Function | What it answers | Sudo? |
|---|---|---|
| `audit-watch [--auth\|--audit\|--all] [--no-color]` | Live colorized stream of security-relevant events (sshd / sudo / su / auditd) with RED/YELLOW/CYAN risk highlighting | Yes (TTY-driven, one prompt) |
| `health-check [--quick\|--full] [--since W] [--no-color]` | Unified morning summary: host / disk / failed services / OOM kills / failed logins / sudo events / listeners / audit summary; ends with verdict line | Yes (graceful per-section degrade) |

### Disk + filesystem

| Function | What it answers | Sudo? |
|---|---|---|
| `disk-usage` | Per-mount usage with color-coded thresholds (>=70% yellow, >=90% red) | No |
| `disk-largest [path] [--top N]` | Largest immediate children of `<path>` (default `$HOME`); auto-elevates for root-owned paths | Sometimes |
| `disk-inodes` | Inode usage per mount (catches "no space left" with apparent free space) | No |
| `mount-info` | Active mounts with options + `/etc/fstab` contents | No |
| `disk-watch [mount]` | Live `watch -n 1` of `df -h <mount>` + largest files | No |

### Hardware

Physical-server hardware health (Linux only; installed by the `homelab_tools`
role, chezmoi prompt `installHomelabTools`). Full guide:
[hardware.md](hardware.md).

| Function | What it answers | Wraps | Sudo? |
|---|---|---|---|
| `hw-status [--no-color]` | One-screen sweep: fans + temps + RAID + per-disk SMART + SEL errors | composite (ipmitool / storcli / smartctl) | Yes (per-section degrade) |
| `hw-fans` | Chassis fan RPM (BMC plane); `ns`/No-Reading = empty slot | `ipmitool sdr type fan` | Yes |
| `hw-temps` | Temperatures: BMC + on-board chips | `ipmitool sdr type temperature` + `sensors` | Yes (BMC part) |
| `hw-sensors` | Full lm-sensors dump | `sensors` | No |
| `hw-raid` | MegaRAID status, VD/PD, ROC temp, enclosure sensors | `storcli show` + `/cALL` + `/cALL/eALL show all` | Yes |
| `hw-smart [dev]` | Per-disk SMART health (no arg) or full `-a` report (with dev); NVMe via `nvme smart-log` | `smartctl -H` / `smartctl -a` | Yes |
| `hw-disks` | Synonym for `hw-smart` no-arg sweep | `smartctl -H` per disk | Yes |
| `hw-sel [--all]` | BMC System Event Log (PSU / ECC / thermal faults) | `ipmitool sel info` + `sel elist` | Yes |

### Package install history

| Function | What it answers | Sudo? |
|---|---|---|
| `pkg-recent [--days N]` | Recently installed/upgraded/removed packages (apt / dnf / pacman / brew / npm-g / pip --user) | dnf needs sudo; others read user-readable logs |

## Sudo and shell-function gotcha

These are shell **functions**, not executables. `sudo audit-foo` will
fail with `command not found` because sudo spawns a fresh process that
doesn't inherit your shell's functions.

The helpers handle this transparently when **you** invoke them:

1. They try `sudo -n` first (free if your sudo cache is warm or you
   have NOPASSWD).
2. If that fails and you're on a TTY, they call `sudo -v` once, then
   `sudo <underlying-command>`.
3. If you're not on a TTY (cron, pipe), they print:
   `audit: needs root. Run \`sudo -v\` once in this shell first, then
   re-run this helper.`

So the working pattern in any awkward shell setup is:

```bash
sudo -v                # warm the cache once per terminal
audit-failed-logins    # works
audit-summary          # works (cache still warm)
```

All helpers accept `--help` for usage and exit 0 (so piping into `head`
doesn't cause SIGPIPE noise).

### Sudo elevation model

When a helper needs root (e.g., `/var/log/secure` is mode 0640 root:adm),
the helper:

1. Tests whether the underlying source is readable as the current user.
2. If readable → runs without elevation.
3. If not readable AND running on an interactive TTY AND not already root
   → calls `sudo -v` once (single TTY prompt), then runs the underlying
   command via `sudo`.
4. If not on a TTY (e.g., invoked from a cron / pipeline) → exits 1 with
   a clear stderr hint.

Within the sudo cache window (default ~5 min, controlled by
`Defaults timestamp_timeout` in sudoers), subsequent helper invocations
run silently. This piggybacks on plain sudo's own credential cache; the
helpers do **not** integrate with this repo's
[`scripts/lib/sudo_shared.sh`](../this_repo/sudo-session.md) helper —
that helper is run-script-scoped and not deployed to `~/`.

## Television channels

Defined under
[`dot_config/television/cable/`](https://github.com/daviddwlee84/dotfiles/tree/main/dot_config/television/cable).
Launch via `tv <name>` from anywhere or via the `Alt+T` tools picker.

**Quick launcher**: `tv sysadmin` opens a meta-channel listing the
sysadmin channels below — saves scrolling past 30 productivity channels
when triaging. Includes adjacent channels useful in the same workflow:
**`services`** (full systemd/launchd browser with log preview + lifecycle
actions; complement to the failure-focused `services-health`) and
**`logs`** (general-purpose log browser with tailspin/lnav). Enter on a
row opens that channel; preview shows the underlying TOML config.

| Channel | Sources (cycle with `Ctrl+S`) | Preview (cycle with `Ctrl+F`) | Enter | Platforms |
|---|---|---|---|---|
| `tv sessions` | 1) `last -F -i`  2) `lastlog` (Linux)  3) `journalctl _COMM=sshd -n 2000` (systemd)  4) `who -a` | Per-user detail: `id <u>`, `lastlog -u <u>`, recent sshd events | Drill-down: `journalctl _COMM=sshd \| grep <user>` in `lnav` | macOS + Linux |
| `tv sudo-history` | 1) `journalctl _COMM=sudo -n 2000`  2) `grep -E 'sudo(\\\|:)' /var/log/auth.log /var/log/secure`  3) `sudoreplay -l` (when configured) | Event metadata; for sudoreplay rows: session info | sudoreplay row → `sudoreplay <id>`; otherwise lnav on event | Linux only |
| `tv audit-events` | 1) `aureport --summary -i`  2) `ausearch -k <baseline-key> --interpret -ts recent` for keys identity / privileged / sudoers / sshd_config  3) `aureport -au -i` and `aureport -x -i` | `ausearch -i -a <eventid>` for the selected row | Full event in `lnav`; `Alt+E` opens `/etc/audit/rules.d/` in `$EDITOR` | Linux + auditd |
| `tv users` | 1) all passwd entries  2) login-capable users (real shell)  3) groups + members  4) sudoers (sudo/wheel/admin + `sudoers.d/`)  5) authorized_keys per home (with fingerprint + comment) | Per-user identity dump: id, groups, passwd, last login, sudo events, SSH key count | Drill-down: full identity report in `lnav`; `Alt+G` show groups; `Alt+E` `visudo` | macOS + Linux |
| `tv firewall` | 1) firewall rules (nft / iptables / ufw / firewalld / pf / ALF)  2) listening TCP+UDP  3) established TCP  4) default policies / zones | Per-row: resolve port to service, walk owning-process parent tree | Drill: full rule context + `lsof -p` in `lnav`; `Alt+E` edit firewall config; `Alt+R` reload rules | macOS + Linux |
| `tv scheduled-jobs` | 1) user crontabs  2) system cron (`/etc/crontab` + `cron.d/` + `cron.{hourly,daily,...}/`)  3) systemd timers (system + user)  4) at jobs  5) anacron (Linux) / launchd plists (macOS) | Per-row: decode schedule, show triggered unit, `systemctl status` for timers | Drill: `systemctl cat` + last 30 logs in `lnav`; `Alt+E` edit crontab/unit; `Alt+T` tail relevant log | macOS + Linux |
| `tv disk` | 1) `df -hT` per-mount  2) `df -hi` inodes  3) largest dirs at depth 1 under `/var /home /tmp /opt /srv`  4) active mounts with options  5) largest files >100M | Path-aware: `du -h --max-depth=1` for dirs, `ls -lh` + `file` for files | `Enter` opens dir in yazi / file in less; `Alt+E` edits `/etc/fstab`; `Alt+T` tails `dmesg -wT` | macOS + Linux |
| `tv services-health` | 1) failed units (Linux) / errored launchctl (macOS)  2) high-restart units (NRestarts > 3)  3) recent OOM kills (Linux)  4) all running services  5) recent error-level crashes | `systemctl status` + last 10 logs (Linux); `launchctl list` detail (macOS) | `Enter` opens journalctl in lnav; `Alt+R` restart (confirms); `Alt+S` stop (confirms); `Alt+E` `systemctl edit --full` | macOS + Linux |

Common bindings shared with this repo's other channels:

- `Ctrl+S` — cycle source
- `Ctrl+F` — cycle preview
- `Ctrl+Y` — copy current row to clipboard (OSC 52 over SSH)
- `Alt+T` — tail-follow the underlying log live with `tspin`
- `Alt+E` — edit relevant config in `$EDITOR`

## Cross-file maintenance

Per the repo's [AGENTS.md "Custom aliases & shell functions"
rule](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md), each
function above also has a row in
[`docs/shells/aliases.md`](../shells/aliases.md). When you add or rename
an `audit-*` helper, update both this page **and** that table.

## What this repo deliberately does NOT ship

- **No tmux popup-menu entry for audit helpers.** The top menu has a
  ~14-row cap (per [tmux invariant](../this_repo/architecture.md)); the
  audit channels are reachable via the existing `Alt+T` tools picker
  and direct `tv <name>` invocation. If you want a dedicated menu, the
  natural home is a new submenu `~/.config/tmux/menu-audit.sh` rather
  than the top menu.
- **No `sudoreplay` install / sudoers edit.** The sudo I/O capture is a
  policy decision (it stores keystrokes including TTY-typed passwords).
  Documented in [sudo-audit.md](sudo-audit.md) but not auto-configured.
- **No remote log shipping setup** (rsyslog → SIEM, audit-remote, vector
  pipelines). Out of scope for a dotfiles repo; the
  [`auditd.md`](auditd.md) "Caveats" section explains why.
- **No EDR install** (Falco, Tetragon, Wazuh agent). Same reason.
- **No `acct` / `psacct` automation.** See
  [process-accounting.md](process-accounting.md) for the manual install
  recipe; the answers it gives are largely a subset of what auditd
  provides better.
