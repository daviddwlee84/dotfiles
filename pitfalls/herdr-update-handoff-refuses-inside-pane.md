# `update failed: run herdr update outside herdr after detaching from the session`

**Symptoms** (grep this section):
- `herdr update` / `herdr update --handoff` exits non-zero immediately, before
  downloading anything:

  ```console
  $ herdr update --handoff
  update failed: run `herdr update` outside herdr after detaching from the session
  ```

- No version check runs, no `checking stable channel for updates...` line — it
  fails before contacting the network
- The same command works fine seconds later from a different terminal
- `herdr --version` is stale relative to upstream and nothing you run inside
  herdr can fix it

**First seen**: 2026-07 (herdr 0.7.1 → 0.7.5, Linux self-managed binary)
**Affects**: any `herdr update` invoked from a shell that is itself a herdr pane
— including from a coding agent's shell tool, which is the easy way to hit it
**Status**: upstream behaviour and correct; `just upgrade-herdr` now detects the
condition and skips with instructions instead of failing

## Root cause

`--handoff` replaces the running herdr **server** with the new binary while
keeping pane processes alive. The shell you typed the command into is a child of
a pane owned by that very server, so herdr refuses rather than pull the rug out
from under its own caller. It fails closed on purpose — the alternative is a
half-migrated session.

Detection is the ambient `HERDR_ENV` (herdr also injects `HERDR_PANE_ID`,
`HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_SOCKET_PATH`). Confirm where you
are before blaming the updater:

```sh
env | grep '^HERDR_' | sed 's/=.*//'      # non-empty ⇒ you are inside a pane
```

**This is the trap for agents specifically.** A coding agent running in a herdr
pane cannot upgrade herdr on your behalf, no matter how it shells out — the
guard is on the environment, not the invocation. The agent has to hand the
command back to you.

## Fix

Detach, upgrade, reattach:

```sh
# 1. Detach from herdr — prefix+q. Client close != session loss: workspaces,
#    tabs, panes and every process in them keep running.
# 2. From the plain terminal you land in:
herdr update --handoff
# 3. Reattach:
herdr
```

Expected output of step 2:

```
checking stable channel for updates...
running herdr targets:
  default: server v0.7.1 (handoff supported)
  update: 0.7.5
downloading 0.7.5...
installed 0.7.5
asking session default to hand off live panes to the updated server...
live handoff complete for session default; pane processes should still be running.
installed herdr integrations need updating; run herdr integration install opencode.
session default was replaced; reconnect clients with `herdr`.
```

`handoff supported` in that output is the thing to look for. Without it (or on a
Homebrew/mise/Nix install, where upstream disables `herdr update` entirely) the
only path is a server restart, which **kills every pane process** — see
[`herdr-brew-upgrade-strands-running-server`](herdr-brew-upgrade-strands-running-server.md).

**The handoff really is non-disruptive.** Verified 2026-07 with a Claude Code
session running in a pane across a 0.7.1 → 0.7.5 upgrade: the session continued
without interruption, and `herdr status` afterwards showed client and server
both 0.7.5 on protocol 17, `compatible: yes`, `restart_needed: no`.

## Two things to do afterwards

1. **Reinstall stale integrations.** The updater names only the first one; ask
   for the full list:

   ```sh
   herdr integration status | grep outdated
   herdr integration install opencode      # repeat per outdated agent
   ```

   These files live outside chezmoi's tree, so no `chezmoi apply` will fix them.

2. **Re-validate the config.** A herdr upgrade can *resolve* config errors as
   well as cause them — a `[[keys.command]]` using a newer `type` is rejected by
   an older binary, and the rejection takes the **whole** keys block with it:

   ```console
   $ herdr server reload-config     # before the upgrade
   {"result":{"diagnostics":["invalid keybinding config: unknown variant `popup`,
    expected one of `shell`, `pane`, `plugin_action`\nin `command.type`\n;
    keeping current keys settings"],"status":"partial",...}}

   $ herdr server reload-config     # after
   {"result":{"diagnostics":[],"status":"applied","type":"config_reload"}}
   ```

   `status: "partial"` + `keeping current keys settings` means you are running on
   whatever the server had in memory; a server restart would have dropped every
   binding. Treat a non-empty `diagnostics` as a version mismatch between config
   and binary, not as a config typo.

## Why this bites this repo in particular

The Linux install task gates on `herdr --version` returning non-zero — *is it
installed*, not *is it current* — so `chezmoi apply` never upgrades herdr, by
design ([install-vs-upgrade split](../docs/this_repo/upgrades.md)). herdr was
also absent from `scripts/upgrade_tools.sh` entirely until 2026-07, so nothing
in `just upgrade-*` covered it either and this box sat four releases behind
until a config change (a `type = "popup"` binding) started failing against the
old binary. `appsrc herdr` reporting `Manual / drag-in (heuristic)` is the same
fact surfacing from the other side: no package manager owns the binary.

## Related

- [`herdr-brew-upgrade-strands-running-server`](herdr-brew-upgrade-strands-running-server.md)
  — the macOS half: no handoff available at all, and what survives a restart
- [`docs/tools/herdr.md`](../docs/tools/herdr.md) — install / upgrade / config-overlay model
- [`docs/this_repo/upgrades.md`](../docs/this_repo/upgrades.md) — why install and upgrade are split
