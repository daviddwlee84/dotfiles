# auditd framework (Level 3)

`auditd` is the userspace component of the **Linux Auditing System**. It
receives audit events from the kernel and writes them to disk for later
querying with `ausearch` and summarisation with `aureport`. Rules are
loaded with `auditctl` (live) or persisted in `/etc/audit/rules.d/*.rules`
(survives reboot via `augenrules`).

This is the right tool when you need:

- Coverage of commands run inside a `sudo bash` / `su -` shell.
- A record that watches **specific files** (sudoers, sshd_config, /etc/passwd, secrets).
- Audit of identity changes (`setuid`, `setgid`, `setresuid`).
- Compliance-grade events (CIS, PCI-DSS, STIG profiles all build on auditd).
- Rules that are loaded *before* the incident and (optionally) immutable
  until the next reboot.

It is **not** the right tool for casual "who ran my script?" curiosity.
The volume of events from execve logging on a busy box is significant.

## Install

The optional `auditd` ansible role in this repo handles install + a
baseline rule set on Linux profiles. See
[docs/playbooks/auditd.md](../playbooks/auditd.md). To opt in:

```bash
chezmoi init --force                 # answer "yes" to "Install auditd?"
# or, if already initialized:
chezmoi execute-template '{{ promptBoolOnce . "installAuditd" "" false }}'
chezmoi apply
```

Manual install (without the role):

```bash
# Debian / Ubuntu
sudo apt-get install -y auditd audispd-plugins
sudo systemctl enable --now auditd

# RHEL / CentOS / Rocky / Alma
sudo dnf install -y audit
sudo systemctl enable --now auditd
```

Note the package name split: Debian → `auditd`, RHEL → `audit` (the
service is `auditd` on both).

## The four core commands

| Command | What it does |
|---|---|
| `auditctl` | Show / load / delete rules in the running kernel |
| `ausearch` | Query the on-disk audit log (`/var/log/audit/audit.log`) by event id, key, time, user, syscall, pid, etc. |
| `aureport` | Summary reports: auth events, executables, file accesses, anomalies |
| `augenrules` | Concatenate `/etc/audit/rules.d/*.rules` and load via `auditctl -R` (run by the auditd service unit) |

## Baseline rules shipped by this repo

The ansible role drops `/etc/audit/rules.d/00-baseline.rules` covering:

- **Identity changes**: watches `/etc/passwd`, `/etc/group`,
  `/etc/shadow`, `/etc/gshadow`. Key `identity`.
- **Sudoers**: watches `/etc/sudoers` and `/etc/sudoers.d/`. Key
  `sudoers`.
- **SSH config**: watches `/etc/ssh/sshd_config`. Key `sshd_config`.
- **Audit config**: watches `/etc/audit/` itself. Key `audit_config`.
- **Privileged command exec**: logs every `execve` of a setuid/setgid
  binary. Key `privileged`.
- **Time changes**: `adjtimex`, `settimeofday`, `clock_settime`. Key
  `time-change`.
- **Failures**: failed file opens (EACCES / EPERM) on production
  directories. Key `access-denied`.

Optional (commented out by default; uncomment in
`/etc/audit/rules.d/10-execve.rules` if you want it):

- **All execve syscalls** (very high volume). Key `execve-all`.

The role does **not** flip on `-e 2` (immutable until reboot) by default
because that breaks ad-hoc rule editing during initial tuning. Toggle
via the role variable `auditd_immutable: true` once you're confident.

## Common queries

```bash
# Live rules
sudo auditctl -l

# All events for the "sudoers" watch key
sudo ausearch -k sudoers --interpret

# Did anyone touch /etc/passwd today?
sudo ausearch -f /etc/passwd --start today --interpret

# Every execve of a setuid binary in the last 24h
sudo ausearch -k privileged --start '24h ago' --interpret

# Authentication events summary
sudo aureport -au -i

# Executable summary (what binaries were run)
sudo aureport -x -i | head -30

# Anomaly events (suspicious patterns auditd flagged)
sudo aureport --anomaly -i

# Per-event detail by audit event id
sudo ausearch -a 12345 -i

# Daily summary
sudo aureport --start today --summary -i
```

## Caveats and operational concerns

- **Execve logging volume**: enabling per-syscall execve rules can
  produce gigabytes per day on a busy host. Plan disk + log rotation
  (`/etc/audit/auditd.conf` → `max_log_file`, `num_logs`,
  `space_left_action`).
- **Sensitive command lines**: execve records include argv. A user
  running `mysql -p secret123` writes `secret123` into
  `/var/log/audit/audit.log` (root-readable, but still on disk). Be
  mindful when shipping audit logs offsite.
- **Disk-full behaviour**: `space_left_action` and
  `disk_full_action` decide what auditd does when its log volume
  fills up. Defaults vary by distro; the strictest setting is
  `halt`, which **panics the kernel** on disk-full to preserve audit
  integrity. Pick the trade-off deliberately.
- **Rule ordering matters**: `auditctl` evaluates rules in order and
  short-circuits on first match (`-A always,exit` vs `-A
  never,exit`). Test new rules in non-immutable mode first.
- **Performance**: each enabled syscall rule adds a check per matching
  syscall. On 10k-syscall/s workloads this is measurable. Profile
  before deploying broad rules to performance-sensitive boxes.
- **Remote forwarding**: for forensic-grade chain of custody, ship
  `/var/log/audit/` to a write-once remote (Wazuh, Splunk,
  audit-remote → another auditd). Local logs are root-mutable in
  principle (immutable bit slows but doesn't prevent a determined
  root attacker).
- **macOS has no auditd**: macOS retired BSM (`audit(4)`) in Sonoma.
  The current macOS audit framework is **Endpoint Security**
  (`eslogger(1)` for ad-hoc queries, EDR products for production).
  Out of scope for this repo's helpers.

## How this repo helps

- **Ansible role**: `dot_ansible/roles/auditd/` (opt-in via
  `installAuditd` chezmoi prompt). Installs auditd, drops the baseline
  rule set, enables the service. See
  [docs/playbooks/auditd.md](../playbooks/auditd.md).
- **Shell helpers** (in `dot_config/shell/45_audit.sh.tmpl`):
  - `audit-execve <pattern>` — `ausearch -sc execve -x <pattern> -i`
  - `audit-file <path>` — `ausearch -f <path> -i`
  - `audit-summary [--start <when>]` — chained `aureport` summaries
  - `audit-rules-show` — `auditctl -l` + persisted rules diff
- **Television channel**: `tv audit-events` (Linux only) — fuzzy-browse
  `aureport` summary rows, preview shows the underlying ausearch event
  with `-i` interpretation. `Enter` opens the full event in `lnav`.

See [Helpers in this repo](helpers.md) for the full table.

## See also

- [sudo auditing](sudo-audit.md) — Level 1 starting point; auditd
  picks up where sudo logs end
- [Process accounting](process-accounting.md) — lighter-weight
  alternative when auditd is overkill
- [Atuin vs audit](atuin-vs-audit.md) — why personal shell history
  doesn't substitute for any of this
