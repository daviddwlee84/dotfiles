# sudo auditing (Level 1)

This layer answers:

- Who used `sudo`?
- What top-level command did they invoke?
- Did `sudo` authenticate, or fail?
- (With `log_input,log_output` enabled) what did they actually type once
  they got a root shell?

## What sudo logs by default

Every `sudo` invocation writes a syslog event with at least:

- The invoking user (`USER=...`)
- The target user (`TARGET=...`, usually `root`)
- The TTY
- The CWD at time of invocation
- The command line that was passed to `sudo`
- Whether authentication succeeded or failed

Where it lands depends on the distro:

| Distro | Sink | Query |
|---|---|---|
| Debian / Ubuntu (systemd) | journal + `/var/log/auth.log` | `sudo journalctl _COMM=sudo` or `sudo grep sudo /var/log/auth.log` |
| RHEL / CentOS / Rocky / Alma | journal + `/var/log/secure` | `sudo journalctl _COMM=sudo` or `sudo grep sudo /var/log/secure` |
| macOS | unified log | `log show --predicate 'process == "sudo"' --last 1d` |

## The "sudo bash" problem

This is the load-bearing limitation:

```bash
sudo vim /etc/ssh/sshd_config       # <- logged: full command line
sudo bash                            # <- logged: "bash"
sudo su -                            # <- logged: "su -"
sudo -i                              # <- logged: "-i"
```

Once the user has a root shell, **everything they type inside that shell
is invisible to the sudo log**. The shell's own history file might catch
it, but root's `~/.bash_history` is editable by root, so it's not
trustworthy as evidence.

To close this gap you need either:

1. **`sudoreplay`** — see below. Captures keystroke + output of the root
   session.
2. **auditd execve rules** — see [auditd framework](auditd.md). Captures
   every `execve()` syscall including those inside the root shell.
3. **Disallow shell escalation** — restrict the sudoers policy so users
   can only run a curated whitelist (`Cmnd_Alias`), no `bash` / `su` /
   editor escape hatches. Aggressive but bulletproof.

## sudoreplay (when it works)

`sudoreplay` records the **terminal session** (stdin + stdout + timing)
of every sudo invocation that matches a `log_input` / `log_output`
sudoers rule. To enable globally:

```sudoers
# /etc/sudoers.d/00-logging  (use `sudo visudo -f`)
Defaults log_input, log_output
Defaults iolog_dir=/var/log/sudo-io
```

After enabling, sudo writes to `/var/log/sudo-io/<user>/<seq>/`. List
sessions:

```bash
sudo sudoreplay -l
sudo sudoreplay -l user=alice
```

Replay one:

```bash
sudo sudoreplay <session-id>
```

Caveats:

- Captures everything, **including passwords typed at TTY** if the user
  ran `passwd`, `mysql -p`, etc. You're now storing those in
  `/var/log/sudo-io/`. Restrict access (default mode `0700` is good)
  and consider whether you really want this on a host that handles
  secrets at the keyboard.
- Disk usage grows fast for interactive root sessions.
- Does not survive `sudo bash` → `su otheruser` (the second hop bypasses
  sudo entirely). For full coverage you still need auditd.

## Common queries

```bash
# All sudo events today (systemd)
sudo journalctl _COMM=sudo --since today

# Sudo events by user, last 7 days
sudo journalctl _COMM=sudo --since '7 days ago' | grep ' alice : '

# Failed sudo attempts (auth failure or NOT in sudoers)
sudo journalctl _COMM=sudo | grep -E 'FAILED|NOT in sudoers'

# Same on non-systemd Debian
sudo grep sudo /var/log/auth.log /var/log/auth.log.1

# Same on RHEL
sudo grep sudo /var/log/secure /var/log/secure-*

# List replayable sessions (only if log_input enabled)
sudo sudoreplay -l
```

## How this repo helps

- **Shell helper**: `audit-sudo [user]` — wraps the journal /
  auth.log / secure query and auto-detects the right sink. Defined in
  `dot_config/shell/45_audit.sh.tmpl`.
- **Television channel**: `tv sudo-history` (Linux only) — fuzzy-browse
  sudo events. Source cycles include journalctl, plain `auth.log` /
  `secure` grep, and `sudoreplay -l` rows when available. Preview of a
  sudoreplay row shows the session metadata; `Enter` invokes
  `sudoreplay <id>`.
- Both helpers elevate via `sudo -v` when the underlying sink is
  root-only. The TTY prompt is a one-time per-shell prompt; subsequent
  helper invocations within the sudo cache window run silently.

## See also

- [Process accounting](process-accounting.md) — alternative coarse exec
  log that *does* see commands inside `sudo bash` (but with no full argv)
- [auditd framework](auditd.md) — the only general-purpose answer to
  "what did the root shell run?"
