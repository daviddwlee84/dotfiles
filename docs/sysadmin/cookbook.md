# Cookbook: scenario-based audit recipes

Hands-on, scenario-first walkthroughs for the helpers and TV channels in
this repo. Each recipe answers a concrete question ("did someone log in
from a new IP?") with the exact commands to run, in order, and what to
look for in the output.

For the conceptual layering, see the [section README](README.md). For
the dense helper reference, see [helpers.md](helpers.md).

## Recipe index

- [1. Who's logged into this server right now?](#1-whos-logged-into-this-server-right-now)
- [2. Did anyone log in from a new IP this week?](#2-did-anyone-log-in-from-a-new-ip-this-week)
- [3. Brute-force / password-spray check](#3-brute-force--password-spray-check)
- [4. Did a user use sudo today, and for what?](#4-did-a-user-use-sudo-today-and-for-what)
- [5. "I suspect someone ran `nmap` from this box" — Level 2 / Level 3](#5-i-suspect-someone-ran-nmap-from-this-box--level-2--level-3)
- [6. Was `/etc/sudoers` modified? When? By whom?](#6-was-etcsudoers-modified-when-by-whom)
- [7. After-action: a user reports their account was compromised](#7-after-action-a-user-reports-their-account-was-compromised)
- [8. Daily 5-minute health check (cron-friendly)](#8-daily-5-minute-health-check-cron-friendly)
- [9. "What did the root shell do?" — beyond sudo logs](#9-what-did-the-root-shell-do--beyond-sudo-logs)
- [10. Quickly silence a noisy audit rule without losing the rest](#10-quickly-silence-a-noisy-audit-rule-without-losing-the-rest)
- [11. Audit local user inventory](#11-audit-local-user-inventory)

---

## 1. Who's logged into this server right now?

**Tool**: `audit-sessions`, no sudo, no auditd.

```bash
audit-sessions
```

Read the third block (`== who -a ==`). Each row is a live session:

```
alice    pts/0   2024-05-08 09:21 (10.0.0.42)
bob      pts/1   2024-05-08 09:45 (10.0.0.99)
```

**Red flags**:
- A user you don't recognise.
- A `pts/N` from a public IP (your sshd should usually only see internal
  / VPN ranges).
- Multiple `pts/N` for the same user (might be legitimate tmux usage —
  cross-check `tmux ls` if it's *your* account).

If something looks off, jump to recipe #7.

---

## 2. Did anyone log in from a new IP this week?

**Tools**: `audit-sessions` for the human eyeball pass; or `tv sessions`
for an interactive view.

```bash
audit-sessions | head -100 | awk '{print $1, $3}' | sort -u
```

This dumps `user IP` pairs from the recent `last` output. Compare
against your "known IP" list (your VPN range, your home IP, CI runner
IPs).

**Or interactively**:

```bash
tv sessions
# then type the username, see all their recent logins, scroll to inspect IPs
```

If you see an unexpected IP, jump to recipe #7.

---

## 3. Brute-force / password-spray check

**Tool**: `audit-failed-logins` (Linux only, sudo). Reads `/var/log/btmp`
via `lastb`.

```bash
audit-failed-logins | head -100
```

Group by IP to spot pattern:

```bash
sudo lastb -F -i | awk 'NR>1 && $3 ~ /[0-9]/ {print $3}' | sort | uniq -c | sort -rn | head -20
```

Output is `count IP`. Anything above ~50/day from one IP is worth
firewall-blocking. Cross-check with your sshd config — if you've
already disabled password auth (`PasswordAuthentication no`), failed
attempts here are noise; the real story is in
`journalctl _COMM=sshd | grep -i 'invalid\|preauth'`.


---

## 4. Did a user use sudo today, and for what?

**Tool**: `audit-sudo`. Works on systemd hosts via journalctl; falls
back to `auth.log`/`secure` grep elsewhere.

```bash
audit-sudo alice
```

Output rows look like:

```
May 08 10:14:22 host sudo[12345]: alice : TTY=pts/0 ; PWD=/home/alice ; USER=root ; COMMAND=/usr/bin/apt update
May 08 10:14:55 host sudo[12399]: alice : TTY=pts/0 ; PWD=/home/alice ; USER=root ; COMMAND=/bin/bash
```

**Read it as**: `<time> <host> sudo[PID]: <user> : TTY=<tty> ; PWD=<cwd> ; USER=<target> ; COMMAND=<argv0+args>`.

**The `/bin/bash` line is the warning sign** — once `alice` got an
interactive root shell, the sudo log stops capturing what she did.
Jump to recipe #9 for the auditd-based answer.

Filter to failed attempts only:

```bash
audit-sudo alice | grep -E 'FAILED|NOT in sudoers|incorrect password'
```

---

## 5. "I suspect someone ran `nmap` from this box" — Level 2 / Level 3

**Level 2 (process accounting, must be enabled in advance)**:

```bash
sudo lastcomm nmap | head -20
```

Shows `command flags user tty seconds start-time`. No argv (so you don't
see *what* they scanned), but proves it ran.

**Level 3 (auditd, this repo's `audit-execve`)**:

```bash
audit-execve nmap
```

Each event includes:
- `pid=NNNN` and `ppid=MMMM` — chain back via `audit-execve` on the
  parent to see what spawned it.
- `auid=N` — the *original* login UID (survives `sudo` / `su`).
  Translate with `id <auid>` to find who really started the chain.
- Full argv if `10-execve.rules` is enabled (see role variable
  `auditd_log_all_execve`); without it, only the binary path is
  recorded by the privileged-binary rule (which doesn't include
  `nmap` by default — extend `05-privileged.rules` if you want it).

**To add `nmap` to the privileged rule set on one host**:

```bash
echo '-a always,exit -F path=/usr/bin/nmap -F perm=x -F auid>=1000 -F auid!=unset -k privileged' \
  | sudo tee /etc/audit/rules.d/50-local.rules
sudo augenrules --load
audit-rules-show | grep nmap
```

The `50-local.rules` filename is outside the auditd role's managed set
(`00-baseline`, `05-privileged`, `10-execve`, `99-finalize`), so
`chezmoi apply` won't overwrite it.

---

## 6. Was `/etc/sudoers` modified? When? By whom?

**Tool**: `audit-file` (requires the baseline `sudoers` watch rule that
this repo's auditd role drops by default).

```bash
audit-file /etc/sudoers
audit-file /etc/sudoers.d/
```

Each event shows:
- `type=PATH name=/etc/sudoers` — the watched object.
- `type=SYSCALL ... auid=1000 uid=0` — `auid` is the original login UID
  (the human), `uid` is what they were running as (root after `sudo`).
- `comm=` and `exe=` — the program that did the modification (`vim`,
  `visudo`, `sed`, `cp` ...).

**Cross-check with sudo log** to find the wrapping `sudo` invocation:

```bash
audit-sudo | grep -i 'visudo\|sudoers'
```

Together they tell you: *Alice ran `sudo visudo` at 10:14, which then
wrote to /etc/sudoers at 10:15*.

---

## 7. After-action: a user reports their account was compromised

You're on the host, the user just told you "I think someone got into
my account". Run these in order, top to bottom, *before* you do
anything destructive (don't `kill` sessions or reset the password yet
— you'll lose evidence).

### 7a. Snapshot live state (5 seconds, zero context lost)

```bash
who -a > /tmp/forensics-who.txt
ps -eo user,pid,ppid,tty,etime,cmd | head -200 > /tmp/forensics-ps.txt
ss -tnp 2>/dev/null > /tmp/forensics-ss.txt   # active TCP, with PID
sudo iptables -S > /tmp/forensics-iptables.txt 2>/dev/null
date -u > /tmp/forensics-time.txt
```

### 7b. Scope the login window

```bash
audit-sessions <user> | head -50
```

Identify the suspicious session: unusual IP, off-hours time, long idle
session that "wasn't you".

### 7c. What did they sudo?

```bash
audit-sudo <user> | head -100
```

Note any `sudo bash` / `sudo -i` / `sudo su -` — those are escalation
points; everything *after* that line is invisible to sudo log. Mark
the time.

### 7d. What did they exec? (auditd only)

For the time window after the suspicious sudo escalation:

```bash
sudo ausearch --start '<YYYY-MM-DD HH:MM:SS>' --end '<YYYY-MM-DD HH:MM:SS>' \
  -sc execve -i | head -200
```

Without `auditd_log_all_execve`, you'll only see execs of binaries in
`05-privileged.rules`. With it on, you see everything — slow to read
but complete.

### 7e. What did they touch?

```bash
audit-file /home/<user>/.ssh/
audit-file /etc/passwd
audit-file /etc/shadow
audit-file /etc/sudoers
```

Look for `EXECVE` events of `useradd`, `usermod`, `passwd`, `chsh` —
these create persistence.

### 7f. SSH key tampering (the classic post-compromise move)

```bash
sudo ls -la /home/<user>/.ssh/
sudo cat /home/<user>/.ssh/authorized_keys
# Anything you don't recognise = an attacker's persistence key.

# Find ALL authorized_keys files on the box (root-managed users too):
sudo find / -name 'authorized_keys' 2>/dev/null -exec ls -la {} \;
```

### 7g. Now you can act

- Lock the account: `sudo passwd -l <user>`
- Kill all their sessions: `sudo pkill -KILL -u <user>`
- Rotate their SSH key (move the legit `authorized_keys` aside, write
  a fresh one).
- Save `/tmp/forensics-*.txt` somewhere off-host before you reboot.

If this is a regulated environment, **stop here and call your IR team**
— anything else risks breaking chain of custody.

---

## 8. Daily 5-minute health check (cron-friendly)

A fast morning check: anything weird overnight?

```bash
#!/bin/sh
# /usr/local/bin/audit-morning-check.sh — run via cron @ 08:00
set -eu

echo "== Sessions in the last 24h =="
last -F -i --since '24 hours ago' 2>/dev/null | head -20

echo
echo "== Failed login attempts in the last 24h =="
sudo lastb -F -i 2>/dev/null | awk '$0 !~ /^$/' | head -20

echo
echo "== Sudo events in the last 24h =="
sudo journalctl _COMM=sudo --since '24 hours ago' --no-pager | tail -20

echo
echo "== Audit summary =="
sudo aureport --start '24 hours ago' --summary -i 2>/dev/null
```

Add to crontab and pipe to email / Slack:

```cron
0 8 * * *  /usr/local/bin/audit-morning-check.sh 2>&1 | mail -s "Audit @ $(hostname)" you@example.com
```

The `audit-*` shell helpers themselves require an interactive TTY for
the sudo prompt, so for cron use the raw `sudo journalctl` /
`sudo aureport` calls (or configure passwordless sudo for those
specific commands via a `sudoers.d/` snippet).

---

## 9. "What did the root shell do?" — beyond sudo logs

You see `sudo bash` in `audit-sudo` output. The sudo log goes dark.
What now?

**Option A — auditd execve (default if `auditd_log_all_execve: true`)**:

```bash
# Find the bash session
sudo ausearch -k execve-all -p <pid-of-bash> -i

# Or by parent PID — find children of the root bash
sudo ausearch -k execve-all --start '<time>' -i | grep -A2 "ppid=<bash-pid>"
```

Without `execve-all`, you'll only see execs that match
`05-privileged.rules` (su, passwd, mount, etc.).

**Option B — sudoreplay (only if `Defaults log_input,log_output` was
set in sudoers BEFORE the incident)**:

```bash
sudo sudoreplay -l user=<user>
sudo sudoreplay <session-id>
```

Replays the entire TTY: every keystroke they typed, everything they
saw. Watch out — this includes passwords typed at TTY (they shouldn't
have, but they often do).

**Option C — process accounting**:

```bash
sudo lastcomm | grep -B2 -A2 ' bash '
```

Coarse but no-prep-needed if `acct`/`psacct` is installed. Won't show
argv.

**Option D — too late**:

If none of A/B/C was set up before the incident, the answer is
**unknowable** from this host. This is exactly why
[`atuin-vs-audit.md`](atuin-vs-audit.md) tells you to set up audit
*before* the incident.

---

## 10. Quickly silence a noisy audit rule without losing the rest

Scenario: `auditd_log_all_execve: true` is producing 5 GB / day; you
need to keep the baseline rules but kill the execve flood, *now*,
without `chezmoi apply` round-trip.

```bash
# 1. List loaded rules and find the offender
sudo auditctl -l | grep execve

# 2. Delete just the execve rules from the running kernel
sudo auditctl -d always,exit -F arch=b64 -S execve,execveat -k execve-all
sudo auditctl -d always,exit -F arch=b32 -S execve,execveat -k execve-all

# 3. Verify
audit-rules-show | grep execve   # should be empty
```

This is a runtime-only change — at next reboot (or next
`augenrules --load`), the rule comes back if the file is still there.
For a permanent fix, flip the role variable and re-apply:

```bash
# In ~/.config/dotfiles/ansible.local.yml or via -e:
auditd_log_all_execve: false
chezmoi apply --force
```

The role's `Remove full execve rules when not opted in` task will
delete `/etc/audit/rules.d/10-execve.rules` and the handler will
reload.

If you're under `auditd_immutable: true` (i.e. `-e 2` is loaded), step
2 will fail with `Operation not permitted`. You're locked until next
reboot. Plan immutability flips with this in mind.

---

## See also

- [Helpers in this repo](helpers.md) — dense reference table for the
  tools used above
- [auditd framework](auditd.md) — concept + FAQ (incl. "why isn't
  `/etc/audit/rules.d/` managed by chezmoi")
- [sudo auditing](sudo-audit.md) — Level 1 deep-dive, `sudoreplay`
  setup
- [Atuin vs audit](atuin-vs-audit.md) — why personal shell history
  doesn't substitute for any of this

---

## 11. Audit local user inventory

You inherited a server. You want to know: **who exists, who can log in,
who can sudo, who has SSH keys**, before you trust anything else.

### 11a. Quick CLI sweep (90 seconds)

```bash
user-list --login          # who has a real shell?
user-sudoers               # who can sudo? (groups + sudoers.d/)
user-ssh-keys              # who has authorized_keys, with fingerprint?
```

Read in this order: `--login` shows the *capability* surface, `sudoers`
shows the *privilege* surface, `ssh-keys` shows the *remote-access*
surface. A user appearing in all three is a full-power principal — make
sure you recognise every one.

### 11b. Drill into a specific user

```bash
user-info alice
```

One screen with id, groups, passwd entry, last 5 logins, last 5 sudo
events, and authorized_keys count. Good first stop when something
looks off.

### 11c. Interactive browse with `tv users`

```bash
tv users
```

`Ctrl+S` cycles 5 sources: passwd → login-capable → groups → sudoers →
SSH keys. Preview shows per-user detail. `Enter` opens a full identity
report in `lnav`. `Alt+G` shows just the user's group list. `Alt+E`
opens `visudo`.

### 11d. Recent identity changes (auditd only)

```bash
user-recent-changes --days 30
```

Shows `ausearch -k identity` and `-k sudoers` events from the last 30
days. Requires the baseline rule set this repo's `auditd` role
installs. Catches: new accounts (`useradd`), shell changes (`chsh`),
sudoers grants, password changes.

### 11e. Red flags to look for

| Pattern | What it might mean |
|---|---|
| User with uid 0 other than `root` | Backdoor account (uid=0 grants root regardless of name) |
| Login-capable user you don't recognise | Forgotten / unauthorised account |
| `authorized_keys` containing comments like `<unknown>@<unknown>` or no comment at all | Key dropped in by someone who didn't bother to label it |
| `NOPASSWD: ALL` in `/etc/sudoers.d/` for a non-system user | Permanent passwordless root — usually a foot-gun or a backdoor |
| User home outside `/home/` (e.g. `/tmp/x`) | Created by an attacker dodging quota / monitoring |
| `nologin`-shelled user with active SSH keys | Common attacker move — the user can't `ssh` interactively but can still execute via `ssh user@host '<cmd>'` if `ForceCommand` isn't set |
