# Detached transcript capture — stop wrapping the agent in `specstory run`

**Status**: design note, nothing implemented
**Trigger**: [`pitfalls/specstory-run-parent-grows-to-multi-gigabyte-rss.md`](../pitfalls/specstory-run-parent-grows-to-multi-gigabyte-rss.md)
**Tracked in**: `TODO.md` → P? / L

## Problem

Every agent pane runs `specstory run <agent>`, which is the agent's **parent**, not
a sidecar. One watcher + autosave runtime per pane, each growing with the transcript,
each unkillable without orphaning the agent it wraps. Measured: `1.20 GB` RSS for a
single `specstory run claude`, with Activity Monitor footprints of `8.09 GB` /
`6.64 GB` / `821.6 MB` across three panes.

Today's only lever is `--no-specstory`, which buys the memory back by giving up the
transcript entirely.

## Shape of the fix

Run the agent bare; capture afterwards from its native history.

```text
now                                  proposed
────────────────────────────────     ────────────────────────────────
specstory run claude                 claude
  ├── watcher      (resident)          │
  ├── autosave     (resident)          ▼  native JSONL
  └── claude                         ~/.claude/projects/**

        lifecycle coupled                    session ends
        memory coupled                            │
                                                  ▼
                                        specstory sync -s <session-id>
                                                  │
                                                  ▼
                                        .specstory/history/*.md
```

Properties worth having: the syncer can be killed at any time without touching a
live agent; the memory peak happens once, after the session, instead of being
resident throughout; and a crashed syncer can simply be re-run.

## What has to be answered first

1. **Session id plumbing.** `specstory sync -s <uuid>` needs the agent's session id.
   Nothing in this repo currently obtains it. Claude Code and Codex both write
   native history, but the id has to be discovered (newest file under the project's
   history dir? an env var the agent exports? a `SessionStart` hook?) and it has to
   survive `--resume` and `/clear`. **This is the blocking unknown** — do not start
   the wrapper refactor before it is settled.
2. **Where the sync fires.** `_sesh_on_exit_wrap` (`dot_config/shell/22_sesh.sh:144`)
   already special-cases `specstory run *` and injects `DEV_AGENT_RUN_ID`; it is the
   natural hook point. Note its `restart` mode (`:168`) loops forever — a sync must
   not be re-run per restart iteration, or it re-materialises the same transcript
   repeatedly.
3. **Coverage of the non-shell emitters.** `specstory run` is also spelled in
   `dot_config/yazi/yazi.toml` (4 openers), `dot_config/tmuxp/*.yaml`,
   `dot_config/tmuxinator/*.yml`, `dot_config/zellij/layouts/*.kdl`, and the Windows
   `profile.d/25_herdr.ps1`. A mode that only covers `_sesh_wrap_agent` leaves most
   of them behind.
4. **Cloud sync semantics.** `specstory run` syncs to SpecStory Cloud as it goes;
   a post-hoc `sync` presumably does too, but the failure mode when the machine
   sleeps between session end and sync is unknown.
5. **`specstory sync` is used nowhere in this repo today.** The only references are
   in `dotfiles-windows/.agents/skills/agent-history-hygiene/` (docs + a probe
   script). The `coding_agents` ansible role installs the binary and nothing more.
   So this is genuinely new surface, not a re-wiring.

## Options considered

| Option | Memory | Transcript | Risk |
|---|---|---|---|
| Status quo (`specstory run` per pane) | one resident runtime per pane | live | none, but the memory is the problem |
| `--no-specstory` (available today) | none | **lost** | none |
| Bare agent + `sync -s` on exit | one peak, after the fact | complete, if the id is right | session-id discovery unproven; loses live cloud sync |
| Bare agents + one shared `specstory watch` | one runtime total | live | `watch` semantics vs. our per-project `.specstory/` layout unverified; it also leaks the cloud auth token into its command line (see the `agent-history-hygiene` skill's `specstory-native-redaction.md`) |

The third is the intended direction; the fourth is worth a spike if session-id
discovery turns out to be unreliable.

## Cross-repo

The code lands in `dotfiles/` (the POSIX wrappers are where `specstory run` is
emitted). `dotfiles-windows/TODO.md` carries a one-line pointer only — per the
superproject rule, one backlog doc, not two.

## Related

- [`pitfalls/specstory-run-parent-grows-to-multi-gigabyte-rss.md`](../pitfalls/specstory-run-parent-grows-to-multi-gigabyte-rss.md)
- [`pitfalls/specstory-run-default-agent-drift.md`](../pitfalls/specstory-run-default-agent-drift.md) — why the provider is always named explicitly
- [`backlog/specstory-opencode-support.md`](specstory-opencode-support.md) — the other reason `_sesh_wrap_agent` has a pass-through arm
- [`docs/tools/specstory-internals.md`](../docs/tools/specstory-internals.md)
