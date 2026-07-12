# Backlog Research

Long-form research, design notes, and paused troubleshooting for items listed in
[`../TODO.md`](../TODO.md). One file per topic, named with a slug that matches
the TODO entry.

## Why this exists

`TODO.md` is the **index** — short titles with priority/effort tags. This folder
is the **knowledge base** — the actual investigation, options considered,
benchmarks, error messages, and decisions that informed the TODO entry. The goal
is **resume-friendliness**: when you (or an agent) come back to an item three
months later, the doc here lets you pick up in 5 minutes instead of re-running
30 minutes of investigation.

This folder is `chezmoi`-ignored (see `.chezmoiignore.tmpl` → `backlog/**`) — it
is repo metadata for maintainers, not user-facing config to deploy.

## When to add a doc here

Add a `backlog/<slug>.md` file when **any** of these apply:

- The TODO item carries a `P?` tag (it requires evaluation; record what was tried)
- You did meaningful troubleshooting but didn't ship a fix (capture the trace
  before it evaporates)
- Multiple options were considered (record the trade-offs, not just the winner)
- An external blocker exists (waiting on upstream release, host availability)
- The implementation is `[L]` or `[XL]` (architectural; needs design before code)

`[S]` items rarely need a doc unless there's surprising context.

## When NOT to add a doc here

- Item is `[S]` and obvious (e.g., "change a TOML key") — just put the file path
  in the TODO entry
- Already covered by a `docs/this_repo/*.md` or `docs/tools/*.md` page
  (cross-link instead, that's user-facing reference)
- Speculation only ("would be cool to...") with no investigation — keep it as a
  one-liner in `TODO.md` first; promote to a doc when you actually look into it

## File template

```markdown
# <Topic title>

**Status**: P? / P1 / P2 / P3 / blocked / deferred / superseded
**Effort**: S / M / L / XL
**Related**: `TODO.md` · code paths · related docs

## Context

Why this surfaced. Trigger (conversation, bug, new tool, recurring annoyance).
Date helps — "2026-04, came up while reviewing starship prompt".

## Investigation

What's already been tried / read / measured. **This is the section that saves
future-you time.** Be specific:

- Commands run + relevant output
- Docs/issue/SO links read
- Benchmark numbers
- Error messages copy-pasted in full (not paraphrased)

## Options considered

| Option | Pros | Cons |
|---|---|---|
| A. … | … | … |
| B. … | … | … |

## Current blocker / open questions

Why this is still on the backlog. One of:

- Waiting on upstream X (link)
- Need host/data Y to verify
- Trade-offs unclear, need user preference
- Effort estimate exceeds current budget

## Decision (if any)

`2026-04 deferred — waiting for X release` or
`2026-04 chose option B because …`

Dates matter. A 6-month-old "decided to use mise" needs re-validation.

## References

Issues, PRs, SO links, related discussions.
```

## Index

Add new entries here as you create them. Keep alphabetical.

| Slug | Status | TODO entry |
|---|---|---|
| [`agent-delayed-run-scheduler`](agent-delayed-run-scheduler.md) | P? research captured | "Agent delayed-run scheduler for non-quota work" |
| [`agent-quota-auto-loop`](agent-quota-auto-loop.md) | P? deferred | "Agent quota auto-continue loop" |
| [`agent-quota-warmup-at-time`](agent-quota-warmup-at-time.md) | P? research captured | "Agent quota warmup at scheduled time" |
| [`agent-session-dashboard-tui`](agent-session-dashboard-tui.md) | P? design backlog | "Native agent-session dashboard TUI" |
| [`ai-capture-non-tmux-output`](ai-capture-non-tmux-output.md) | P2 deferred / P3 rejected | "aicapture: non-tmux output capture (Tier 2 tee / Tier 3 script/PTY)" |
| [`ansible-env-proxy-var-case-sensitivity`](ansible-env-proxy-var-case-sensitivity.md) | P2 ready | "ansible env-var lookup: handle `HTTPS_PROXY` (uppercase) hosts" |
| [`chezmoi-diff-pager-agent`](chezmoi-diff-pager-agent.md) | P? deferred | "chezmoi diff pager: TTY-aware delta fallback" |
| [`copilot-proxy-supervisor`](copilot-proxy-supervisor.md) | P? deferred 2026-07 | "copilot-proxy: replace nohup start with a real supervisor (launchd/systemd/pueue)" |
| [`mkdocs-anchor-drift`](mkdocs-anchor-drift.md) | P3 ready | "mkdocs site: ~20 stale in-page anchor links to clean up before re-enabling strict `anchors: warn`" |
| [`chezmoiscripts-namespace-refactor`](chezmoiscripts-namespace-refactor.md) | P2 ready | "Migrate run_onchange scripts into .chezmoiscripts/{global,repo}/" |
| [`fish-shell-evaluation`](fish-shell-evaluation.md) | P? declined 2026-05 | "Add `fish` as a third primaryShell choice" |
| [`just-ansible-tags-python-interpreter`](just-ansible-tags-python-interpreter.md) | P2 ready | "`just ansible-tags` / `ansible-base` / etc.: auto-detect uv-managed Python on CentOS 7" |
| [`linux-desktop-app-control`](linux-desktop-app-control.md) | P? deferred 2026-05 | "Linux Desktop app control equivalent of `54_macos_apps.sh`" |
| [`rtk-evaluation`](rtk-evaluation.md) | P? declined 2026-05 | "rtk-ai/rtk evaluation" |
| [`specstory-opencode-support`](specstory-opencode-support.md) | P? deferred | "specstory: enable opencode auto-wrap when upstream lands" |
| [`starship-context-modules`](starship-context-modules.md) | P1 ready | "Starship status-aware modules" |
| [`tmux2k-tuning`](tmux2k-tuning.md) | P1 ready | "tmux2k bandwidth bug" + "tmux2k theme alignment" |
| [`tmux-window-status-indicators`](tmux-window-status-indicators.md) | P? deferred | "tmux window status indicators (running / idle / error)" |
| [`tui-testing-harness`](tui-testing-harness.md) | P3 direction decided, deferred | "TUI E2E testing harness — Textual Pilot for `mlf` (+ pexpect/pyte)" |
| [`tv-agent-sessions-richer-preview`](tv-agent-sessions-richer-preview.md) | Done (batch 1) / P? deferred (Cursor) | "tv agent-sessions richer preview + SpecStory linkage" |
| [`mise-runtime-gating`](mise-runtime-gating.md) | P2 ready | "Gate mise runtimes (rust/dotnet/bun/ruby) + fix .NET-SDK contract bug" |
| [`lean-bundle-init-ux`](lean-bundle-init-ux.md) | P? needs design | "Lean no-brainer bundles + init-CLI UX + decision-tree SSOT" |
| [`cloud-vm-provision-combo`](cloud-vm-provision-combo.md) | P? idea | "Cloud-VM (az) provision + dotfiles bootstrap combo (fleet?)" |
| [`opencodebox-wrapper`](opencodebox-wrapper.md) | P? deferred | "opencodebox wrapper for the containerized opencode image" |
| [`yth-semantic-search`](yth-semantic-search.md) | P? deferred | "yth semantic subtitle search" |
