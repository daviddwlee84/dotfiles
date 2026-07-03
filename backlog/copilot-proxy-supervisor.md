# copilot-proxy: replace `nohup` start with a real supervisor (launchd / systemd / pueue)

**Status**: P? — evaluation captured, deferred (user wants a plan, not a build)
**Effort**: M
**Related**: [`dot_config/shell/43_copilot_proxy.sh`](../dot_config/shell/43_copilot_proxy.sh) (`copilot-proxy start`, lines ~146-157) · [`dot_dotfiles/bin/executable_agent-warmup`](../dot_dotfiles/bin/executable_agent-warmup) (launchd/systemd `install` precedent) · [backlog/agent-quota-warmup-at-time.md](agent-quota-warmup-at-time.md) · [docs/tools/copilot-claude-proxy.md](../docs/tools/copilot-claude-proxy.md) · [pitfalls/agent-warmup-scheduled-run-hangs-or-blank-under-daemon.md](../pitfalls/agent-warmup-scheduled-run-hangs-or-blank-under-daemon.md)

## Context

2026-07-03, while debugging Claude Code `API error · Retrying …` / `500 fetch failed`
loops on the Copilot proxy. Two separate questions surfaced; **this doc is only the
second one (how the proxy is started/supervised).** The first — the actual API
errors — is a **60 s upstream timeout**, NOT a proxy-process problem (see the
"⚠ scope" note below so future-me doesn't conflate them).

Today `copilot-proxy start` (`43_copilot_proxy.sh`) launches the fork
(`@jeffreycao/copilot-api@1.13.14`) via **`nohup bunx … &`**, tracks the PID in
`$TMPDIR/copilot-api-$PORT.pid`, and tees stdout+stderr to a single
`$TMPDIR/copilot-api-$PORT.log` (viewable with `copilot-proxy logs [N]`). It works,
but the user asked whether there's a "better start with queryable logs — systemd/
launchd? surely not nohup?". It is, in fact, nohup.

**⚠ scope**: the observed failures (11× HTTP 500, all clustered at 60-62 s) are the
*upstream* path cutting long Opus/1M generations. The `copilot-api` **process never
crashed**. So a supervisor's auto-restart (`KeepAlive`/`Restart=always`) would
**not** have prevented those API errors. This migration buys: survives-crash,
start-at-login, stable log path, log rotation — not timeout resilience. Don't sell
it as a fix for the 500s.

**Root cause of the 500s — FOUND + FIXED (2026-07-03), separate from this backlog.**
The 60 s cap was **nginx's default `proxy_read_timeout` (60 s)** on the WebSocket
`location` block of the personal V2Ray node the Copilot traffic tunnels through
(Clash rule `DOMAIN-KEYWORD,github → PROXY` → Azure-JP V2Ray VM). Long Opus/1M
generations that idle >60 s upstream got the WS reaped → `other side closed` →
copilot-api returns 500 → Claude Code retry loop. Fixed by adding
`proxy_read_timeout 3600s` / `proxy_send_timeout 3600s` to that block. Repo +
write-up live in the *separate* `~/Documents/Program/DockerCompose-V2Ray` project:
`server/templates/nginx/v2ray.conf.tmpl` + `ansible/roles/vpn/templates/nginx/v2ray.conf.j2`,
pitfall `pitfalls/long-connections-drop-at-60s-other-side-closed.md`. (That box was
also on the legacy static-conf layout, so the fix was hand-applied on the VPS +
committed to templates for the eventual IaC migration.) **This supervisor backlog
remains purely about start/supervise ergonomics — the API-error thread is closed.**

## Investigation

Current start path (`43_copilot_proxy.sh`):

```sh
# lines ~71-72 — ephemeral $TMPDIR paths (wiped on reboot, differ per launchd session)
_copilot_logfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-api-$(_copilot_port).log"; }
_copilot_pidfile() { printf '%s' "${TMPDIR:-/tmp}/copilot-api-$(_copilot_port).pid"; }

# lines ~146-157 — the nohup start (fork branch)
nohup bunx "$pkg" start --port "$port" >"$logf" 2>&1 &
printf '%s\n' "$!" >"$pidf"
```

Gaps vs a supervisor:

1. **No auto-restart** — if the process dies, it stays dead until a manual
   `copilot-proxy start`. (Low real-world value here — see ⚠ scope; upstream 500s
   don't kill the process. Value is for genuine crashes / OOM / node upgrades.)
2. **No start-at-login** — every reboot / fresh shell must re-run `start`.
3. **Log lives in `$TMPDIR`** — wiped on reboot, and launchd hands processes a
   *different* per-session `$TMPDIR`, so the path isn't stable/predictable.
4. **No log rotation** — single unbounded file (116 KB in this session; fine for
   now, but grows forever).

Precedent already in the repo — **`agent-warmup` (`dot_dotfiles/bin/executable_agent-warmup`)
solved exactly this daemon-bootstrap shape**:

- macOS: writes `~/Library/LaunchAgents/<label>.plist` (`StandardOutPath`,
  `RunAtLoad`), loads via `launchctl bootout` + `bootstrap gui/$uid` (fallback
  `launchctl load -w`). See `_launchd_path()` / `_install_launchd()` (~lines 447-486).
- Linux: writes `~/.config/systemd/user/<unit>.{service,timer}`, verifies with
  `systemd-analyze verify` (~lines 494-526).
- Carries a `_PATH_PRELUDE` (mirrors `scripts/fleet/exec.py`) so the minimal env
  launchd/systemd hand the process still finds `bunx`/`tmux`/`launchctl` — **this is
  the key gotcha for us too**: `bunx` comes from mise (`07_bunx_cli.sh`), which is
  NOT on launchd's default PATH.

Difference from agent-warmup: it schedules a **one-shot timer** (`RunAtLoad: False`
+ `StartCalendarInterval` / systemd `.timer`). copilot-api is a **persistent
daemon**, so we want `KeepAlive: true` + `RunAtLoad: true` (macOS) and a plain
`.service` with `Restart=always` + `WantedBy=default.target` (systemd, **no timer**).

Also live on this host: `~/Library/LaunchAgents/homebrew.mxcl.pueue.plist` —
**`pueued` is already launchd-supervised via `brew services`**, so the pueue option
below has near-zero daemon-bootstrap cost.

## Options considered

| Option | Pros | Cons |
|---|---|---|
| **A. launchd LaunchAgent (macOS) + systemd --user (Linux)**, generated at runtime by a `copilot-proxy install` subcommand — reuse agent-warmup's `_install_launchd`/`_install_systemd` + `_PATH_PRELUDE` | Native, `RunAtLoad`+`KeepAlive`/`Restart=always`, stable `StandardOutPath` log, cross-platform, proven pattern in this repo | Must solve mise/`bunx` PATH in the minimal daemon env; log rotation still manual (`newsyslog`/`logrotate` or size-cap in wrapper); plist/unit is runtime-generated (not chezmoi-managed → not in git) |
| **B. systemd --user only** | Cleanest logs (`journalctl --user -u copilot-api -f`), built-in rotation, `Restart=always` | Linux-only; this proxy is macOS-primary (personal Copilot sub) → would still need launchd for the main host. Really just the Linux half of A. |
| **C. pueue task** (`pueue add -- bunx … start`) | `pueued` already launchd-supervised (zero new daemon); fits existing `fleet pueue`/`pqsum` tooling; `pueue log -f` for logs; survives shell exit | Not a service supervisor: no crash auto-restart by default, no start-at-login semantics for the *task* (only the daemon persists); a `pueue reset`/`clean` could nuke it; semantically a job-queue, not a daemon |
| **D. keep nohup, just harden** (stable log path under `$XDG_STATE_HOME`, size-cap rotation, optional cron liveness re-`start`) | Smallest change; no new moving parts | Reinvents a worse supervisor; still no login-start; cron-poll restart is hacky |

## Current blocker / open questions

- **Is it worth it at all?** Given ⚠ scope (the real pain is upstream 500s, not
  crashes), the concrete wins are login-start + stable/rotated logs. Decide whether
  that clears the M-effort bar, or whether option D (just move the log to
  `$XDG_STATE_HOME` + size-cap) is enough.
- **PATH in the daemon env**: confirm the mise-shim resolution for `bunx` under
  launchd. Cleanest is to resolve the absolute `bunx` (or `bun x`) path at install
  time and bake it into the plist `ProgramArguments`, rather than relying on a login
  shell. Cross-check `_PATH_PRELUDE` (chezmoi→cargo→uv→~/bin→brew→linuxbrew order).
- **Auth precondition**: `start` today refuses without
  `~/.local/share/copilot-api/github_token`. A `KeepAlive` daemon that boots at
  login before auth would crash-loop → need `KeepAlive` with a `SuccessfulExit`/
  throttle guard, or gate `RunAtLoad` on the token file existing.
- **Interaction with `copilot-proxy start/stop/restart`**: the shell verbs must
  detect the launchd/systemd unit and delegate (`launchctl kickstart -k` /
  `systemctl --user restart`) instead of spawning a second nohup instance. Keep
  `logs` working against the new `StandardOutPath`.
- **Cross-file sync (per AGENTS.md)** when built: `docs/tools/copilot-claude-proxy.md`
  (+`.zh-TW`), `docs/shells/aliases.md` row if a new `install`/`uninstall` verb is
  added, and completion files for `copilot-proxy` if the subcommand list changes.

## Decision (if any)

`2026-07-03 deferred — captured as backlog per user request ("先出個backlog計劃").`
Leaning **Option A** (reuse agent-warmup's launchd/systemd install pattern, adapted
from timer → persistent `KeepAlive`/`Restart=always` daemon) **if** built, because it
is the only cross-platform native answer and the code pattern already exists in the
repo. But **spike the "is it worth it" question first** — the failures that triggered
this are upstream, not process crashes, so the ROI is login-start + log hygiene only.

## References

- Fork: <https://github.com/caozhiyuan/copilot-api> (npm `@jeffreycao/copilot-api`)
- agent-warmup launchd/systemd install: `dot_dotfiles/bin/executable_agent-warmup`
  `_install_launchd` / `_install_systemd` / `_PATH_PRELUDE`
- launchd `KeepAlive` semantics: `man launchd.plist` (SuccessfulExit / Crashed throttle)
- systemd user service: `Restart=always`, `WantedBy=default.target`, `loginctl enable-linger`
  for boot-before-login persistence
