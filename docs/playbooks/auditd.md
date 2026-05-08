# auditd ansible role (opt-in)

The `dot_ansible/roles/auditd/` role installs and configures the Linux
Audit framework on supported Linux profiles. It is **opt-in** via the
`installAuditd` chezmoi prompt (default `false`); macOS hosts skip the
role unconditionally (no auditd on macOS).

For the conceptual background — what auditd is, how to query it, what
it covers that sudo logs don't — see
[docs/sysadmin/auditd.md](../sysadmin/auditd.md).

## Opt in

```bash
chezmoi init --force          # answer "yes" to "Install Linux audit framework"
chezmoi apply
```

Or set the prompt non-interactively:

```bash
chezmoi execute-template '{{ promptBoolOnce . "installAuditd" "" true }}' >/dev/null
chezmoi apply
```

The `server-linux` bundle in `scripts/init/dotfiles_init.py` already
ticks `installAuditd: True`, so `dotfiles_init.py --bundle server-linux`
gets it for free.

## What gets installed

| Distro | Package(s) | Service |
|---|---|---|
| Debian / Ubuntu | `auditd`, `audispd-plugins` | `auditd.service` |
| RHEL / CentOS / Rocky / Alma | `audit` | `auditd.service` |

## What gets dropped into `/etc/audit/rules.d/`

| File | Source | Purpose |
|---|---|---|
| `00-baseline.rules` | `roles/auditd/files/00-baseline.rules` | Identity / sudoers / sshd_config / audit_config / time-change / access-denied watch rules |
| `05-privileged.rules` | `roles/auditd/files/05-privileged.rules` | Per-binary execve rules for `sudo`, `su`, `passwd`, `chsh`, `mount`, `usermod`, etc. |
| `10-execve.rules` (opt-in) | `roles/auditd/files/10-execve.rules` | **All** execve syscalls. Only when `auditd_log_all_execve: true` |
| `99-finalize.rules` (opt-in) | generated inline | `-e 2` immutability lock. Only when `auditd_immutable: true` |

After dropping a file, the role triggers `augenrules --load` via a
handler so changes take effect without a reboot (unless you've already
opted into immutability).

## What gets tuned in `/etc/audit/auditd.conf`

| Knob | Default | Why |
|---|---|---|
| `max_log_file` | `50` (MB) | Rotate at 50 MB to keep `audit.log` greppable |
| `num_logs` | `8` | Keep ~400 MB of history |
| `space_left` | `200` (MB) | Warn when `/var/log/audit/` has < 200 MB free |
| `space_left_action` | `syslog` | Don't halt the box on space-low (safer default) |
| `disk_full_action` | `syslog` | Same; the strictest setting (`halt`) panics the kernel |

All five are tunable via role variables — see
`dot_ansible/roles/auditd/defaults/main.yml`.

## Role variables

```yaml
auditd_immutable: false             # set true to add `-e 2` finalize rule
auditd_log_all_execve: false        # set true for full execve syscall logging
auditd_max_log_file_mb: 50
auditd_num_logs: 8
auditd_space_left_mb: 200
auditd_space_left_action: "syslog"  # syslog | email | exec | suspend | single | halt
auditd_disk_full_action: "syslog"
```

To override per host, drop a file under
`~/.config/dotfiles/ansible.local.yml` (this repo's standard ansible
override path — see [docs/this_repo/ansible_customization.md](../this_repo/ansible_customization.md))
or pass on the ansible CLI:

```bash
ansible-playbook -e auditd_log_all_execve=true ...
```

## Validation

After `chezmoi apply` succeeds:

```bash
# Service is active
systemctl is-active auditd

# Rules are loaded
sudo auditctl -l | head

# Baseline rule keys are queryable
sudo ausearch -k sudoers --start '5 minutes ago' -i || echo '(no events yet)'

# Use this repo's helpers (see docs/sysadmin/helpers.md)
audit-rules-show
audit-summary
```

## Caveats

- **Re-running with `auditd_immutable: true` once locked**: subsequent
  rule edits won't load until you reboot. The role still drops the new
  rule files, so the change persists across reboot — but the running
  kernel keeps the previous rule set. Plan immutability flips
  carefully.
- **Disk usage**: Even without `auditd_log_all_execve`, the baseline
  rule set on a busy multi-user host can produce 100+ MB / day in
  `/var/log/audit/`. Monitor `/var/log/audit/audit.log` size and tune
  `max_log_file` / `num_logs` upward if you need longer retention.
- **Combined with sudo I/O capture**: this role does **not** modify
  sudoers. To get full TTY recording of root sessions, separately add
  `Defaults log_input, log_output` via `visudo` (see
  [docs/sysadmin/sudo-audit.md](../sysadmin/sudo-audit.md) — the
  `sudoreplay` section explains the trade-offs, including that you'll
  capture any TTY-typed passwords).
- **Container / WSL hosts**: auditd needs `CAP_AUDIT_WRITE` and a
  kernel with `CONFIG_AUDIT=y`. WSL 2 kernels usually have it; rootless
  containers usually don't. Role's `Skip auditd role on non-Linux`
  guard does NOT detect "Linux but auditd-incompatible" — install will
  succeed but the service may fail to start. Check
  `journalctl -u auditd` if so.
- **macOS / FreeBSD**: not supported. The role's first task ends play on
  non-Linux. macOS uses Endpoint Security (`eslogger(1)` / EDR); see the
  ceiling discussion in
  [docs/sysadmin/atuin-vs-audit.md](../sysadmin/atuin-vs-audit.md).

## See also

- [docs/sysadmin/auditd.md](../sysadmin/auditd.md) — concept + query
  reference
- [docs/sysadmin/helpers.md](../sysadmin/helpers.md) — `audit-*` shell
  helpers and `tv audit-events` channel that consume the rules this
  role installs
- [docs/this_repo/ansible_customization.md](../this_repo/ansible_customization.md)
  — how to override role variables per host
