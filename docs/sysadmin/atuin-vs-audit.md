# Atuin vs audit

[Atuin](../tools/atuin.md) is a great personal shell-history tool. It is
**not** a server audit log. This page exists to make that distinction
explicit, because the question "can I use Atuin to see what users on my
server did?" comes up regularly.

## Why Atuin is not an audit log

Atuin is **user-space convenience data**. Each shell user owns their own
Atuin database (`~/.local/share/atuin/history.db`) and config
(`~/.config/atuin/config.toml`). They can:

- Disable history capture entirely (`AUTO_SYNC=false`, `update_check =
  false`, comment out the shell hook).
- Filter commands out of history (`history_filter` and `cwd_filter`
  in `config.toml` — this repo's own [`atuin/config.toml`](../tools/atuin.md)
  excludes secret-prone paths like `~/.ssh/`).
- Delete entries (`atuin search --delete`).
- Edit the SQLite DB directly with `sqlite3`.
- Not install Atuin in the first place — bash / zsh built-in history
  works without it.

If sync is enabled, Atuin uploads **end-to-end encrypted** history to the
sync server. The server operator should not be able to inspect users'
command history because the encryption key never leaves the user's
machine. That's a privacy feature, but it also means the sync server
cannot serve as an audit oracle either.

A privileged administrator on the local machine can read other users'
shell history files and Atuin databases — but that just gives you what
the user *chose to record*. It is not tamper-resistant evidence of what
they actually ran.

## Traditional shell history is even less reliable

If Atuin isn't trustworthy, plain `~/.bash_history` / `~/.zsh_history` is
worse. Users can:

- Change `HISTFILE` (`HISTFILE=/dev/null`).
- Disable persistence (`set +o history`, `unset HISTFILE`).
- Filter (`HISTIGNORE='*secret*'`, `HISTCONTROL=ignorespace`).
- Skip saving via leading-space prefix (with `ignorespace`).
- `history -d <n>` to delete specific entries.
- `history -c && exit` to wipe in-memory before write.
- Edit the file with `vim` between sessions.

History files can also be **incomplete by accident**: multi-session race
conditions, delayed flush on shell exit, file truncation on disk-full,
NFS-related corruption. None of this is malicious — it just means
"the command isn't in the history file" doesn't prove "the command
wasn't run."

This repo's [`docs/shells/history.md`](../shells/history.md) documents
the bash/zsh/atuin history layering in this dotfiles repo specifically;
that page is the right starting point if you want to *understand* the
history stack, not audit it.

## What you should use instead

| Question | Right tool | Where to read |
|---|---|---|
| "Who logged in?" | `last`, journal, auth.log/secure | [Sessions and login](sessions.md) |
| "Who used sudo?" | `journalctl _COMM=sudo`, sudoreplay | [sudo auditing](sudo-audit.md) |
| "Did anyone run `<binary>`?" | `lastcomm`, auditd execve rules | [Process accounting](process-accounting.md) / [auditd](auditd.md) |
| "Was `<file>` modified?" | auditd watch rules | [auditd](auditd.md) |
| "What did the root shell run?" | auditd execve rules, sudoreplay | [auditd](auditd.md) / [sudo auditing](sudo-audit.md) |
| "Compliance / forensics" | auditd + remote log shipping + EDR | (out of scope) |
| "My own command recall" | atuin | [tools/atuin.md](../tools/atuin.md) |

## Full comparison table

| Source | What it can answer | Reliability for audit | Notes |
|---|---|---|---|
| `~/.bash_history`, `~/.zsh_history` | Some commands typed in an interactive shell | **Low** | User-controlled, incomplete, easy to disable or edit |
| Atuin local DB | User's Atuin-captured shell history with metadata | **Low** for audit; medium for personal recall | Better search/context than plain history, but still user-space and not tamper-proof |
| Atuin sync server | Encrypted sync blobs | **Not useful** for command inspection | Server operator should not see plaintext history (E2E encrypted) |
| `last` / `lastlog` / `who` | Login session boundaries | **High** for sessions | Tells you sessions, not commands |
| sudo logs (journal / auth.log / secure) | Who ran sudo and what top-level command was invoked | **Medium** | Does not capture commands inside a root shell |
| `sudoreplay` (when configured) | Full TTY recording of sudo sessions | **High** for what was typed/seen | Disk-heavy; captures any password typed at TTY |
| `acct` / `psacct` / `lastcomm` | Process execution summary | **Medium** | Coarse-grained, no full argv, must be enabled |
| `auditd` | Policy-driven kernel audit events | **High** if preconfigured correctly | Best standard Linux answer for audit/compliance |
| EDR / eBPF / SIEM agents (Falco, Tetragon, Sysdig, Wazuh, vendor) | Centralized security telemetry across a fleet | **High**, depends on product/config | Better for fleet-scale; outside dotfiles scope |
| Offsite log forwarder (audit-remote, syslog-ng → write-once store) | Tamper-resistant chain of custody | **High** if storage is genuinely write-once | Required for forensic-grade evidence |

## TL;DR

Atuin is for *you* to find *your* commands faster. It is not a
surveillance tool, not an audit log, and not an evidence source. If
you need any of those, configure auditd (or an EDR) **before** the
incident, and ship logs off-host read-only.

For the full audit-source tour, start at the [section
README](README.md).
