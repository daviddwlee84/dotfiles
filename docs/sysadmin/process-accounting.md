# Process accounting (Level 2)

This layer answers:

- Did anyone exec `<binary>` on this host?
- Roughly when, by which user, on which tty?
- How much CPU / IO did each process burn (for billing-style summaries)?

It sits **between** sudo logs (top-level invocations only) and auditd
(everything, with full context). Process accounting is older, simpler,
and lighter — but it has known gaps that make auditd the right answer
for forensics.

## Tooling

| Command | Source | What it shows |
|---|---|---|
| `lastcomm` | `/var/log/account/pacct` (binary) | Per-process line: command, flags, user, tty, runtime |
| `sa` | Same file | Aggregate summary by command or user |
| `accton on \| off \| <file>` | Toggle | Start/stop accounting; switch output file |
| `dump-acct <file>` | (psacct only) | Dump binary file as text |

## Install + enable

```bash
# Debian / Ubuntu / Raspberry Pi OS
sudo apt-get install -y acct
sudo systemctl enable --now acct.service

# RHEL / CentOS / Rocky / Alma
sudo dnf install -y psacct
sudo systemctl enable --now psacct.service

# macOS (BSD-style)
sudo accton /var/account/acct
# Read with: sudo lastcomm
```

Once enabled, the kernel writes one record per terminating process to
`/var/log/account/pacct` (Linux) or `/var/account/acct` (BSD/macOS).

## Common queries

```bash
# All processes today
sudo lastcomm | head -50

# Did anyone run `nmap`?
sudo lastcomm nmap

# What did user alice run?
sudo lastcomm --user alice | head -50

# What ran on tty pts/3?
sudo lastcomm --tty pts/3 | head -50

# Aggregate: which commands consumed CPU?
sudo sa | head -20

# Per-user summary
sudo sa -m | head -20

# Reset counters / switch file
sudo accton off
sudo mv /var/log/account/pacct /var/log/account/pacct.$(date +%F)
sudo accton on
```

## Known limitations

- **No full argv**: `lastcomm` shows the *command name* (basename of
  argv[0]), not the full argument vector. `lastcomm wget` tells you
  someone ran wget, not which URL. Forensic value is limited.
- **Truncation**: command names are truncated (typically 16 chars on
  Linux per the `comm` field).
- **Short-lived processes flood the log**: a busy build or shell-loop
  host produces thousands of records per minute. Plan rotation
  (`logrotate`) or you fill `/var/log`.
- **Records on exit, not start**: `lastcomm` lists processes that have
  *terminated*. Long-running daemons don't appear until they die.
- **Trivially defeated by static linking / renaming binaries**: a
  determined user copies `bash` to `/tmp/innocent` and runs that.
  auditd-based execve logging captures the inode, mitigating this.
- **No file-access tracking**: process accounting tells you who ran
  `cat`, not what file they catted.

## When to prefer process accounting over auditd

- Lightweight introspection on a host where auditd isn't viable
  (resource-constrained embedded, distros without `audit` package).
- "Who ran `<expensive command>` and burned CPU?" billing-style
  questions. `sa -u` is purpose-built.
- Quick "did this binary ever run on this box?" sanity checks where you
  don't care about argv.

For everything else, jump straight to [auditd](auditd.md).

## How this repo helps

This repo does **not** ship a dedicated process-accounting helper or
TV channel — `lastcomm <name>` is already terse, and the gaps above
make it a poor primary tool. The `audit-execve` helper in
`dot_config/shell/45_audit.sh.tmpl` wraps the auditd equivalent and is
strictly more useful when auditd is enabled.

If you want process accounting on a host, install it manually with the
distro commands above. The optional `auditd` ansible role
([docs/playbooks/auditd.md](../playbooks/auditd.md)) does **not** install
`acct`/`psacct` — they answer different questions.
