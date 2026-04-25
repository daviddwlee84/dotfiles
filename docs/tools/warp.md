# Warp Terminal

> AI-native terminal. This page is mostly about **how Warp updates itself on each platform** — and why one of the steps it pastes into your prompt looks suspicious.

## How this repo installs Warp

| Platform | Source | Where it's wired | Upgrade path |
|---|---|---|---|
| macOS | Homebrew cask `warp` | [`dot_config/homebrew/Brewfile.darwin.tmpl`](../../dot_config/homebrew/Brewfile.darwin.tmpl) | `just upgrade-brew` (cask `--greedy`) |
| Ubuntu / Debian | Warp's own apt repo (`https://releases.warp.dev/linux/deb stable main`) | Manual install once; the repo file at `/etc/apt/sources.list.d/warpdotdev.list` is dropped by Warp's `.deb` postinst | `just upgrade-warp` (apt `--only-upgrade`) — see [§ How `cat_warp` works](#how-cat_warp-works) |
| Other Linux | Not managed | — | — |

Both flows are picked up by `just upgrade-all`. The Linux path replaces the on-disk binary but does **not** restart the running Warp process — you must quit + relaunch Warp to load the new version. Why it can't auto-restart: see [§ The Ubuntu in-app update flow](#the-ubuntu-in-app-update-flow).

## The Ubuntu in-app update flow

When the Warp UI says "Update available", it injects the following command **into your active terminal prompt** and waits for you to press Enter:

```bash
sudo apt update && sudo apt install warp-terminal && warp_finish_update <token>
```

The token (e.g. `AgStYNT`) is freshly generated per update and is not reusable.

### What each step does

#### 1. `sudo apt update`

Refreshes apt indexes. The interesting one is Warp's own repo:

```text
deb [arch=amd64 signed-by=/usr/share/keyrings/warpdotdev.gpg] \
  https://releases.warp.dev/linux/deb stable main
```

dropped under `/etc/apt/sources.list.d/warpdotdev.list` by the original `.deb` postinst.

#### 2. `sudo apt install warp-terminal`

Because the package is already installed, this is **effectively** `apt install --only-upgrade warp-terminal` — apt resolves the candidate, sees a newer version is available, and upgrades. The new binary lands under `/opt/warpdotdev/warp-terminal/`. The currently-running Warp **process is not affected yet** — it's still executing the old in-memory binary image.

#### 3. `warp_finish_update <token>` — the non-obvious step

This is the part that confuses people. `warp_finish_update` is **not** a system binary, not in any apt package, and not on `$PATH` outside an active Warp session. It's a shell function (or wrapper) that Warp **injects into your shell environment** when it spawns the session — a privilege Warp has because it is the terminal hosting your shell.

What it does:

1. Resolves the unix-socket / IPC channel back to the Warp daemon process that's still running.
2. Sends the token as a handshake. The token must match the one Warp generated when it pasted the command, otherwise the call is rejected.
3. The daemon validates the token, confirms `apt` finished cleanly (the `&&` chain guarantees this — if `apt install` returned non-zero, `warp_finish_update` never runs), and then triggers its own restart, loading the freshly-installed binary from `/opt/warpdotdev/warp-terminal/`.

The reason this dance exists at all: on Linux, replacing the on-disk binary doesn't replace the running process. Without the IPC handshake, you'd have to manually `pkill warp-terminal` (losing all your tabs / panes / agent context) before the new version is actually loaded. The token flow turns it into a graceful restart.

### Why Warp can paste into your prompt

Warp is the terminal emulator, so it controls the input buffer of the PTY it allocated for your shell. From the shell's perspective the keystrokes look indistinguishable from you typing them. This is the same mechanism that powers Warp's "AI suggestion → editable command" UX. There's no `expect` / `send` / privileged escalation — it's just terminal-local I/O.

## The macOS flow (for contrast)

On macOS Warp is a `.app` bundle under `/Applications/Warp.app`. The Sparkle-style updater downloads a new `Warp.dmg` from `https://releases.warp.dev/stable/v<version>/Warp.dmg`, mounts it, swaps the bundle, and re-launches. There's no `warp_finish_update` step because:

- The OS-level "running app vs on-disk app" semantics differ on macOS — Cocoa apps can be hot-swapped via the standard updater hand-off helper without an IPC handshake.
- Cask installs go through Homebrew's `brew upgrade --cask --greedy` (covered by [`upgrade-brew`](../this_repo/upgrades.md#category-matrix)), so when this repo is in use the in-app updater is largely redundant.

## How `cat_warp` works

The `warp` category in [`scripts/upgrade_tools.sh`](../../scripts/upgrade_tools.sh) does the **apt half** of the in-app flow — but never `warp_finish_update`, which is unusable from outside a live Warp session (the token is per-session and the function isn't on `$PATH`):

```bash
sudo apt-get update \
  && sudo apt-get install --only-upgrade -y warp-terminal
```

Operational details:

- **Linux only.** On macOS the category short-circuits with `SKIPPED` because `cask "warp"` + `brew upgrade --cask --greedy` (covered by `cat_brew`) already moves it.
- **Skipped when `warp-terminal` is absent.** Returns `77` so the upgrade summary marks it as SKIPPED, not FAILED — machines that don't run Warp aren't penalised.
- **Sudo session reuse.** Calls `sudo_session_init "upgrade-warp"` so it shares the cached ticket from earlier categories (notably `cat_brew` on macOS, or any earlier sudo-using step). When sudo is `non-interactive` and not passwordless, the category skips itself rather than hanging — see [the sudo-session invariant](../this_repo/sudo-session.md).
- **Restart is on the user.** apt successfully replacing `/opt/warpdotdev/warp-terminal/...` does **not** swap the running process's in-memory binary. The category logs an `[INFO]` reminder; you have to quit + relaunch Warp before the new version is active.
- **Repo signature drift.** Warp rotates its signing key occasionally; if `apt update` errors with `NO_PUBKEY`, fetch the fresh key from `https://app.warp.dev/download` and re-import to `/usr/share/keyrings/warpdotdev.gpg`. We don't pre-pin the key in this repo.

Run isolated:

```bash
just upgrade-warp           # this category only
just upgrade-all            # included in the standard chain (between flatpak and agents)
just upgrade-dry-run        # see what it would run
```

## See also

- [`docs/this_repo/upgrades.md`](../this_repo/upgrades.md) — how the explicit upgrade flow is structured; the install-vs-upgrade rule that keeps apt out of the default scope.
- [`docs/this_repo/sudo-session.md`](../this_repo/sudo-session.md) — the shared sudo helper any future `cat_warp` would use.
- [`docs/this_repo/instant-llm-fix-prior-art.md`](../this_repo/instant-llm-fix-prior-art.md) — design-space comparison of Warp's AI features against this repo's `aifix` / `aiblock` flow.
