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

## FAQ

### Why isn't `/etc/audit/rules.d/` managed by chezmoi (e.g. via `create_`)?

Three reasons it can't:

1. **Path is hard-coded in auditd**. `auditd.service` runs `augenrules
   --load`, which only reads `/etc/audit/rules.d/*.rules`. User paths
   (`~/.config/audit/...`) are invisible to the daemon. Unlike user-space
   tools (tmux, nvim) that pick their own config path, audit is a kernel
   subsystem with a fixed system path.
2. **Files must be `root:root` mode 0640**. chezmoi runs as the user; it
   physically cannot write to `/etc/`. `create_` doesn't fix this — it's
   a chezmoi *deployment semantic* (seed once), not a privilege
   escalation. The target must be inside the chezmoi-managed home.
3. **Audit rules are system-wide**. The kernel has one rule set,
   affecting every user. The "per-user dotfile" model doesn't apply.

This repo's split is:

| Tool | Scope | Privilege | Examples |
|---|---|---|---|
| chezmoi | user-space (`~/.config/`, `~/.zshrc`) | user | shell aliases, tmux config |
| ansible | system-wide (`/etc/`, `apt install`, systemd) | root via `become: true` | auditd rules, Docker daemon config, `/etc/shells` |

The `auditd` role is in the same category as `docker` (installs daemon
+ writes `/etc/docker/daemon.json` + adds user to docker group) and
`bash` (brew-installs bash 5.x + edits `/etc/shells` + `chsh`). All
three are install-once + idempotent (the install-vs-upgrade split in
[`docs/this_repo/upgrades.md`](../this_repo/upgrades.md) keeps
`chezmoi apply` from re-bumping them every run), which matches the
"one-time setup" intuition — just executed by ansible-with-sudo
instead of a chezmoi prefix.

### Can I edit rule files by hand on a host?

Yes, but `chezmoi apply` will overwrite them on the next run because
the role uses `ansible.builtin.copy` (force-replace semantics). For
host-specific tweaks, prefer:

- A new `/etc/audit/rules.d/50-local.rules` file (any filename outside
  the role's managed set: `00-baseline`, `05-privileged`,
  `10-execve`, `99-finalize`). The role won't touch other filenames.
- Or override the role variables (`auditd_log_all_execve`,
  `auditd_immutable`, etc.) per host via the standard ansible
  override path documented in
  [`docs/this_repo/ansible_customization.md`](../this_repo/ansible_customization.md).

### How do I see what's actually loaded right now?

```bash
audit-rules-show     # this repo's helper
# or:
sudo auditctl -l
```

If `auditctl -l` shows `No rules` after `chezmoi apply`, check
`journalctl -u auditd` — the role drops files but augenrules can
fail silently if a syntax error sneaks in. The handler also runs
`augenrules --load` so any failure shows up in the apply log.

### Why is my host showing zero events under a key?

Three usual causes:

1. **Rule wasn't loaded** — `audit-rules-show` to confirm.
2. **Watch path doesn't exist on this host** — auditctl silently skips
   `-w /missing/path` rules.
3. **`auditd` service not running** — `systemctl is-active auditd`.

## See also

- [sudo auditing](sudo-audit.md) — Level 1 starting point; auditd
  picks up where sudo logs end
- [Process accounting](process-accounting.md) — lighter-weight
  alternative when auditd is overkill
- [Atuin vs audit](atuin-vs-audit.md) — why personal shell history
  doesn't substitute for any of this
