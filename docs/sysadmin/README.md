# System admin: who did what on this server?

This section answers a question that comes up every time a Linux box gets
shared across more than one human (or one human + a coding agent): **who
ran what, when, from where, and is the record actually trustworthy?**

Short answer: shell history is **not** an audit log. Atuin is **not** an
audit log. They are user-space convenience tools, owned and editable by the
user whose commands they record. For real auditing you need a separate
data source designed for the purpose, ideally configured *before* the
incident you want to investigate.

This section is a layered tour of the data sources that *are* designed for
the purpose, plus the helpers and Television channels this repo ships to
make the routine queries low-friction.

## The four levels

| Level | Question it answers | Tools | Reliability |
|---|---|---|---|
| **0. Sessions / login** | Who logged in? from where? when? did they `su`? | `last`, `lastlog`, `who`, `journalctl _COMM=sshd`, `/var/log/auth.log`, `/var/log/secure` | High — kernel + sshd write these |
| **1. sudo / privilege** | Who escalated? what top-level command did they run? | `journalctl _COMM=sudo`, `grep sudo /var/log/{auth,secure}*`, `sudoreplay` | Medium — captures the `sudo` line, not what happens *inside* `sudo bash` |
| **2. Process accounting** | Did anyone exec `<binary>`? | `acct` / `psacct`, `lastcomm`, `sa` | Medium — coarse, no full argv, must be enabled |
| **3. Audit framework** | Policy-driven kernel events: execve, file watches, identity, sudoers edits | `auditd`, `auditctl`, `ausearch`, `aureport` | High — if rules were configured *before* the event |

Beyond Level 3 sit fleet-grade telemetry products (Falco, Tetragon,
Sysdig, Wazuh, vendor EDRs). Those are out of scope for a personal
dotfiles repo, but the comparison table on
[Atuin vs audit](atuin-vs-audit.md) lists them so you know where the
ceiling is.

## Pages in this section

- [Sessions and login](sessions.md) — Level 0
- [sudo auditing](sudo-audit.md) — Level 1
- [Process accounting](process-accounting.md) — Level 2
- [auditd framework](auditd.md) — Level 3
- [Atuin vs audit](atuin-vs-audit.md) — why personal shell history is not
  the right tool, with the full comparison table
- [**Cookbook (scenario recipes)**](cookbook.md) — hands-on walkthroughs:
  "did anyone log in from a new IP?", "user reports compromise — what
  now?", "silence a noisy rule without re-applying", and 7 more
- [Helpers in this repo](helpers.md) — `audit-*` shell functions and
  `tv sessions` / `tv sudo-history` / `tv audit-events` Television
  channels that wrap the queries on this page

## Decision flow

```text
"Who logged into this box?"             →  audit-sessions   (Level 0)
"Did <user> use sudo today?"            →  audit-sudo       (Level 1)
"Did anyone run /usr/bin/<x>?"          →  audit-execve     (Level 3, needs rule set in advance)
"Was /etc/<file> modified?"             →  audit-file       (Level 3, needs watch rule)
"Compliance / forensic incident"        →  auditd + offsite log shipping
"My own command history for recall"     →  atuin            (NOT audit)
```

## What this section is not

- Not a guide to *evading* audit logs.
- Not a forensic incident-response playbook (those need offsite log
  shipping, chain-of-custody, and tooling outside dotfiles scope).
- Not a SIEM design doc.

For compliance or forensic-grade auditing, configure auditd or another
host-level audit agent **before** the incident, ship logs off-host
read-only, and treat user-space history (bash / zsh / atuin) as
convenience data only.
