# herdr usage-status driver — CodexBar-analog AI quota in the herdr sidebar

**Status**: P? — researched, not spiked yet (deliberately deferred 2026-07)
**Effort**: M (DIY driver, Codex+Claude) / S (just install the Codex-only plugin)
**Related**: [docs/tools/herdr.md](../docs/tools/herdr.md), `dot_config/shell/24_herdr.sh` (`hvibe`/`hcode`), `dot_config/shell/40_codexbar` (existing CodexBar shell aliases `cbu`/`cbc`/`cbca`), [steipete/CodexBar](https://github.com/steipete/CodexBar) (brew cask `codexbar`, already installed)

## Context

herdr's sidebar shows per-pane agent **state** (idle / working / blocked) natively but has **no usage / quota / token display** — confirmed against `herdr --default-config` (v0.7.1): no `statusline` / `status_bar` / `usage` / `quota` / `widget` keys; `[ui]` only exposes `sidebar_*_width`. The user already runs **CodexBar** (macOS menu bar, multi-provider: Codex + Claude + ChatGPT + …) as the usage view, wired into the shell via `40_codexbar` (`cbu`/`cbc`/`cbca`). The question was whether the same "% used" info can live **inside herdr** next to the agents.

Decision at research time: **keep CodexBar as the primary usage view; do not install a herdr plugin now.** Backlog a DIY driver for when the user lives in herdr full-time and wants Claude+Codex quota in the sidebar without alt-tabbing to the menu bar.

## The hook (verified)

herdr can render arbitrary status TEXT next to a pane/agent in the sidebar via the metadata API:

```
herdr pane report-metadata <pane_id> --source <id> --token usage="Claude 62% • Codex 78%5h" --ttl-ms <n>
```

`--token` + `--ttl-ms` (auto-expiry) is exactly the driver surface — a background timer computes the string and pushes it per pane. No core change required, but see the render note below.

> **✅ The contention blocker is GONE (herdr 0.7.4, verified 2026-07-26).** This note previously warned that `custom_status` was a **single value per pane**, so this driver and the review-pending flag (`hmark` / `prefix+m` / `tv herdr-review`, `--source review`) would fight over one visible label. herdr 0.7.4 replaced `--custom-status` with a **namespaced token map** (up to 32 tokens per pane, names `^[A-Za-z0-9_-]{1,32}$`), so a `usage` token and the `review` token now coexist cleanly. No interaction decision needed.
>
> **New requirement in its place:** a token renders **only** where a sidebar row layout names it. The review flag already pins `[ui.sidebar.agents] rows` in `.chezmoitemplates/herdr/config.toml` with `"$review"`; this driver must append `"$usage"` to that same layout (one shared block — don't add a second). See [`pitfalls/herdr-0.7.4-drops-custom-status.md`](../pitfalls/herdr-0.7.4-drops-custom-status.md).

## Prior art (herdr plugins)

- **[jerryfane/herdr-codex-usage-kit](https://github.com/jerryfane/herdr-codex-usage-kit)** — closest analog to CodexBar's *Codex* provider. Reads local Codex JSONL at `$CODEX_HOME/sessions` (default `~/.codex/sessions`), finds the newest `rate_limits` event, publishes a compact `"78%5h 64%wk"` label into the agents sidebar via a background service, plus a `codex-usage-watch` refreshing pane. **Same on-disk source CodexBar uses for Codex; no OpenAI API call.** Codex-ONLY.
- **[Davidcreador/herdr-token-dashboard](https://github.com/Davidcreador/herdr-token-dashboard)** — per-agent token/cost TUI pane (Pi session JSONL + OpenCode server API). Token/cost, not subscription quota.
- **Gap**: no herdr plugin covers **Claude / ChatGPT** subscription quota. CodexBar gets those from OAuth/cookies/CLI, which nothing in the herdr ecosystem mirrors.

## Options when this is picked up

- **A — install the Codex-only plugin** (Effort S): add `herdr plugin install jerryfane/herdr-codex-usage-kit` to the `# --- herdr-plus plugin ---` block pattern in `dot_ansible/roles/devtools/tasks/main.yml` (idempotent, mirrors how `cloudmanic/herdr-plus` is installed). Gets Codex quota in the sidebar. Update `docs/this_repo/tool-managers.md` A–Z + `docs/tools/herdr.md`. **Leaves Claude/ChatGPT uncovered.**
- **B — DIY driver** (Effort M): a small background loop (shell or uv script) that computes `"Claude X% • Codex Y%"` and calls `herdr pane report-metadata … --token usage=…` for each agent pane. Data sources, cheapest first:
  1. Reuse **CodexBar's own cached data** — CodexBar reads `~/.codex` (rate_limits) and `~/.claude`; if it caches to `~/.config/codexbar/` or similar, read that instead of re-deriving. (Verify what CodexBar persists; it's a mix of local files + OAuth/cookies/Keychain.)
  2. Codex: read `~/.codex/sessions` rate_limits directly (same as the plugin).
  3. Claude: `~/.claude` usage files if present; else scrape the Claude CLI. Hardest part; may not be cleanly file-derivable.
  - Wire the loop as a herdr `[[keys.command]]` `type="shell"` (detached) entry in `.chezmoitemplates/herdr/config.toml`, or a pueue/launchd timer. Keep the per-pane `--source` stable so labels update in place.

## Open questions

- What exactly does CodexBar persist to disk (so B.1 is viable vs re-deriving)? Inspect `~/.config/codexbar/` and `~/.codexbar/`.
- Per-pane vs per-workspace: push one rolled-up label per workspace, or per agent pane? `report-metadata` is per-pane, so per-agent is natural but noisier.
- Is this worth it while CodexBar's menu bar already shows everything? Trigger to build: user reports actually living in herdr and wanting to drop the menu-bar glance.
