# Headless `claude -p` warmup does not start the 5-hour subscription window

**Symptoms** (grep this section): a scheduled `claude -p 'Reply: hi'` "warmup"
job runs cleanly (exit 0, a reply in the log) but the Claude Pro/Max **5-hour
usage window never starts** — `/usage` in interactive Claude Code still shows no
active session window at the warmup time; the window only begins later when you
actually start typing interactively; metered **Agent SDK credit** is consumed
instead of subscription usage; "warmup at 06:00" has no effect on when your
interactive window resets.
**First seen**: 2026-06-20 (designing `agent-warmup`)
**Affects**: any automation that assumes headless `claude -p` / Agent SDK runs
count toward the interactive subscription 5-hour window
**Status**: by design (Anthropic billing change) — `agent-warmup` works around it
by driving an interactive TUI instead

## Symptom

The "obvious" warmup — run a tiny prompt headlessly from launchd/cron/pueue so
the 5-hour window is already running before you start work:

```bash
cd ~/.cache/agent-warmup && claude -p 'Reply exactly: hi'
```

…succeeds but does **nothing** to the interactive window. You burn metered API
credit and the window still starts whenever you first type interactively.

## Root cause

As of **2026-06-15**, Anthropic split billing:

- **Interactive** Claude.ai chat and **interactive terminal Claude Code** stay on
  the subscription and advance the rolling **5-hour window**.
- **Non-interactive** usage — the **Agent SDK**, the **headless `claude`
  command** (`claude -p`), Claude Code **GitHub Actions**, and third-party agents
  authenticating with your subscription — now draws from a **separate monthly
  metered credit pool** (~$20 Pro / $100 Max5x / $200 Max20x, API rates, no
  rollover).

Anthropic's framing: *"if a human presses enter, you stay on your subscription;
if a robot presses enter while you're away, that usage moves to the new metered
credit."* The 5-hour window is **only** moved by interactive usage.

Compounding trap: `--bare` (the clean way to skip `CLAUDE.md`) explicitly does
**not** read the subscription OAuth token — it forces `ANTHROPIC_API_KEY`. So
`claude --bare -p …` is doubly wrong for warmup (API billing, never subscription).

## Fix / workaround

To move the window you must drive a **genuine interactive Claude Code session**.
`agent-warmup run` (see [docs/tools/agent-warmup.md](../docs/tools/agent-warmup.md))
does this:

- spawn a detached tmux session (`tmux -L agent-warmup`) running interactive
  `claude` in an isolated cwd;
- `unset ANTHROPIC_API_KEY` so it uses subscription auth (do **not** use
  `--bare`);
- `tmux send-keys` a tiny prompt + Enter.

## Verify

The interactive-via-tmux classification is **not documented** — confirm it
empirically near a reset boundary before trusting recurring scheduling:

```bash
agent-warmup verify   # run --verify --keep: sends /usage, keeps the session
tmux -L agent-warmup attach -t warmup-<ts>   # eyeball the /usage panel
```

Check whether a new 5-hour session window started. If it did **not**, the
tmux-driven session is also being classified as non-interactive — stop and
rethink (there may be no automatable way to warm the window).

**Preliminary finding (2026-06-20):** a live `verify` run reported as a *Claude
Max* account, `/usage` attributed the usage to the **"Current session"** (5-hour
window) bucket, and the metered **"Usage credits" pool was off** — strong
evidence the tmux interactive session counts as subscription usage, not metered
Agent SDK credit. NOT yet proven: the **cold start** (that run joined an
already-active window, so it has not been shown to *start* a fresh window). The
open check is to run `verify` when no window is active.

## References

- Billing split explainer: <https://www.pravinkumar.co/blog/claude-june-15-billing-change-explained-2026>
- [docs/tools/agent-warmup.md](../docs/tools/agent-warmup.md)
- [backlog/agent-quota-warmup-at-time.md](../backlog/agent-quota-warmup-at-time.md)
- Related stale-HUD trap: [claude-hud-usage-statusline-stale.md](claude-hud-usage-statusline-stale.md)
