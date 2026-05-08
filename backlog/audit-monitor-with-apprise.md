# Backlog: scheduled audit monitoring with apprise

**Status**: design / not implemented. Captured 2026-05 from a user
question after `audit-summary` / `health-check` shipped.

## Problem

Helpers like `health-check`, `audit-summary`, `audit-failed-logins`,
`fw-listening` are designed for *ad-hoc* sysadmin queries. To turn
them into a real monitoring story you need three things this repo
doesn't yet have:

1. **Scheduling** — run the check at a regular cadence without a human.
2. **Diff awareness** — only alert when the answer **changes**
   (otherwise the morning email becomes noise the user filters out
   on day 3).
3. **Notification routing** — push the result to wherever the user
   actually reads alerts (Slack, Discord, Telegram, email, ntfy,
   matrix, gotify, ...). Hard-coding any one channel is a footgun.

The natural answer to (3) is **[apprise](https://github.com/caronc/apprise)**:
a single Python CLI that abstracts ~80 notification services behind
URLs (e.g. `slack://...`, `discord://...`, `tgram://...`,
`mailto://...`, `ntfy://...`). Already pip-installable; would slot
into this repo's `installPythonUvTools` ansible role with a one-line
addition to `dot_ansible/roles/python_uv_tools/tasks/main.yml`.

## Proposed shape (NOT implemented)

### A. New helper `audit-monitor`

A wrapper that:

1. Runs a check (delegated by name: `audit-monitor health` runs
   `health-check --no-color`; `audit-monitor failed-logins` runs
   `audit-failed-logins`; etc.)
2. Hashes / diffs the output against the previous run cached at
   `~/.cache/audit-monitor/<check>.last`.
3. If the output changed (or `--always`), sends via apprise to a
   per-check URL.

```bash
audit-monitor health --notify "${APPRISE_URL_OPS}"
audit-monitor failed-logins --threshold 50 --notify "${APPRISE_URL_SECURITY}"
audit-monitor disk --threshold 90 --notify "${APPRISE_URL_OPS}"
```

The `--threshold` interface is for numeric checks; non-numeric checks
fall back to "alert if the output diff is non-empty".

### B. Scheduling: pueue OR systemd timer

Two reasonable backends, user picks per host:

- **pueue** (already in this repo via `cargo`): great for ad-hoc /
  user-scope; daemon is per-user; survives reboot only if the user
  starts pueued. Good for personal workstation morning checks.
  Recipe in [`docs/tools/pueue.md`](../docs/tools/pueue.md) already
  exists.
- **systemd timer**: better for true server use. One `*.timer` +
  `*.service` per check, OnCalendar-anchored. Survives reboot,
  works without an active user session, integrates with the
  existing `tv scheduled-jobs` channel.

This repo ships an `auditd` ansible role; a sibling `audit_monitor`
role could drop:

```text
/etc/systemd/system/audit-monitor-health.timer
/etc/systemd/system/audit-monitor-health.service
/etc/systemd/system/audit-monitor-disk.timer
/etc/systemd/system/audit-monitor-disk.service
...
```

with a fresh `installAuditMonitor` chezmoi prompt (default false,
gated to Linux).

### C. Notification URL secret management

Hard problem; the *reason* this is in backlog rather than shipped.
apprise URLs contain auth secrets (`tgram://<bot-token>/<chat>`,
`slack://<token>/<channel>`, etc.). They MUST NOT land in:

- `~/.config/audit-monitor/config` (would sync to every host via dotfiles)
- env vars in `dot_zshrc` (shell history exposure)
- ansible `defaults/main.yml` (commit hazard)

Acceptable patterns in this repo's conventions (see
[`docs/this_repo/sudo-session.md`](../docs/this_repo/sudo-session.md)
and [`docs/tools/agent-overlays.md`](../docs/tools/agent-overlays.md)
for prior art):

1. **Bitwarden CLI** (already integrated; `installBitwarden=true`):
   fetch URL on each check via `bw get notes "apprise/health"`.
   Pro: secrets never on disk plaintext. Con: needs unlocked
   session, doesn't work for boot-time / unattended timers.
2. **`~/.config/audit-monitor/secrets.env` mode 0600** in
   `.chezmoiignore.tmpl` (per-host, not synced). User manually
   provisions on each host. Pro: simple, works unattended. Con:
   manual provisioning step.
3. **systemd `LoadCredentialEncrypted=`** — encrypts secrets to
   the host's TPM/sealed key. Pro: best for true server. Con:
   complex, kernel/TPM-version-dependent.

Default would be (2); document (1) for desktops and (3) for hardened
servers.

### D. Per-check trigger conditions (the actual security value)

Each check has a different "what counts as actionable" definition:

| Check | Trigger | Rationale |
|---|---|---|
| `health-check` | overall verdict goes from OK → WARN | Catches state transitions, not steady noise |
| `audit-failed-logins` | `count > 50/day` OR `count > 10 from one IP` | Brute-force pattern |
| `audit-sudo` (with `audit-watch` patterns) | any HIGH-severity match (sudoers edit, useradd, root login) | High-confidence security event |
| `disk-usage` | any mount >= 90% | Disk-full pages on-call |
| `fw-listening` | new listener that wasn't there yesterday | Persistence implant detection |
| `cron-list` | new entry that wasn't there yesterday | Same |
| `pkg-recent` | any install in the last 24h on a "no-change" host | Supply-chain trip wire |

The `--threshold` flag covers numeric ones; the diff-aware mode
covers structural ones. Both need state files in `~/.cache/audit-monitor/`.

## Out of scope (for this backlog item)

- **Real-time streaming alerts** (e.g. push the moment audit-watch
  catches a HIGH match). That's a separate "agent" daemon with very
  different lifecycle requirements; document as a follow-on backlog
  if anyone asks.
- **Aggregation across hosts** (fleet-wide monitoring dashboard).
  That's a SIEM, not a dotfile. Hand-off point: ship the apprise
  URL per host, route them to a shared channel, let the human / a
  cheap downstream rule (Slack workflow, Discord webhook into a
  dedicated channel) do correlation.
- **Acking / silencing alerts**. Apprise is fire-and-forget; it has
  no concept of acking. If you need that, you've outgrown this
  approach — go to PagerDuty / Opsgenie / similar.

## Decision criteria before promoting from backlog

Promote to TODO when at least two of these are true:

1. User runs at least one of the helpers manually 3+ days in a row
   (signal: this is real recurring work, automation pays off).
2. User has a specific incident they wish they'd caught earlier.
3. User has a target apprise channel already (Slack workspace,
   Telegram bot, etc.) and is comfortable provisioning the URL.

Until then the manual `health-check` / `audit-watch` workflow
covers ~90% of the value at 0% of the secret-management cost.

## Related

- [`docs/sysadmin/cookbook.md`](../docs/sysadmin/cookbook.md) — recipe
  8 (`audit-morning-check.sh.sh` cron pattern) is the v0 of this idea
- [`docs/tools/pueue.md`](../docs/tools/pueue.md) — scheduling backend
  candidate
- [`dot_ansible/roles/auditd/`](../dot_ansible/roles/auditd/) — pattern
  for opt-in audit-related ansible roles
- Apprise: <https://github.com/caronc/apprise>
- Apprise URL list: <https://github.com/caronc/apprise/wiki>
