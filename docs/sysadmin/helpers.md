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

| Channel | Sources (cycle with `Ctrl+S`) | Preview (cycle with `Ctrl+F`) | Enter | Platforms |
|---|---|---|---|---|
| `tv sessions` | 1) `last -F -i`  2) `lastlog` (Linux)  3) `journalctl _COMM=sshd -n 2000` (systemd)  4) `who -a` | Per-user detail: `id <u>`, `lastlog -u <u>`, recent sshd events | Drill-down: `journalctl _COMM=sshd \| grep <user>` in `lnav` | macOS + Linux |
| `tv sudo-history` | 1) `journalctl _COMM=sudo -n 2000`  2) `grep -E 'sudo(\\\|:)' /var/log/auth.log /var/log/secure`  3) `sudoreplay -l` (when configured) | Event metadata; for sudoreplay rows: session info | sudoreplay row → `sudoreplay <id>`; otherwise lnav on event | Linux only |
| `tv audit-events` | 1) `aureport --summary -i`  2) `ausearch -k <baseline-key> --interpret -ts recent` for keys identity / privileged / sudoers / sshd_config  3) `aureport -au -i` and `aureport -x -i` | `ausearch -i -a <eventid>` for the selected row | Full event in `lnav`; `Alt+E` opens `/etc/audit/rules.d/` in `$EDITOR` | Linux + auditd |
| `tv users` | 1) all passwd entries  2) login-capable users (real shell)  3) groups + members  4) sudoers (sudo/wheel/admin + `sudoers.d/`)  5) authorized_keys per home (with fingerprint + comment) | Per-user identity dump: id, groups, passwd, last login, sudo events, SSH key count | Drill-down: full identity report in `lnav`; `Alt+G` show groups; `Alt+E` `visudo` | macOS + Linux |
| `tv firewall` | 1) firewall rules (nft / iptables / ufw / firewalld / pf / ALF)  2) listening TCP+UDP  3) established TCP  4) default policies / zones | Per-row: resolve port to service, walk owning-process parent tree | Drill: full rule context + `lsof -p` in `lnav`; `Alt+E` edit firewall config; `Alt+R` reload rules | macOS + Linux |
| `tv scheduled-jobs` | 1) user crontabs  2) system cron (`/etc/crontab` + `cron.d/` + `cron.{hourly,daily,...}/`)  3) systemd timers (system + user)  4) at jobs  5) anacron (Linux) / launchd plists (macOS) | Per-row: decode schedule, show triggered unit, `systemctl status` for timers | Drill: `systemctl cat` + last 30 logs in `lnav`; `Alt+E` edit crontab/unit; `Alt+T` tail relevant log | macOS + Linux |

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
