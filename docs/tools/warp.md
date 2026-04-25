# Warp Terminal

> AI-native terminal. This page is mostly about **how Warp updates itself on each platform** — and why one of the steps it pastes into your prompt looks suspicious.

## How this repo installs Warp

| Platform | Source | Where it's wired |
|---|---|---|
| macOS | Homebrew cask `warp` | [`dot_config/homebrew/Brewfile.darwin.tmpl`](../../dot_config/homebrew/Brewfile.darwin.tmpl) |
| Ubuntu / Debian | Warp's own apt repo (`https://releases.warp.dev/linux/deb stable main`) | Manual install once; the repo file at `/etc/apt/sources.list.d/warpdotdev.list` is dropped by Warp's `.deb` postinst |
| Other Linux | Not managed | — |

Warp is **not** in [`scripts/upgrade_tools.sh`](../../scripts/upgrade_tools.sh) — it self-updates from the GUI on both platforms (see below). If you want it under `just upgrade-*`, see [§ Adding Warp to upgrade_tools.sh](#adding-warp-to-upgrade_toolssh).

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

## Adding Warp to `upgrade_tools.sh`

If you want Linux Warp to be moved by `just upgrade-*`, the **safe** version of step 2 above is what to wire in — *not* `warp_finish_update`, which only works inside a live Warp session and would be `command not found` from a generic shell:

```bash
# inside a future cat_warp() or appended to an apt-tools category
if [[ "$(uname -s)" == "Linux" ]] \
  && command -v warp-terminal >/dev/null 2>&1; then
  info "Upgrading warp-terminal (Linux apt repo)"
  _run sudo apt update || any_fail=1
  _run sudo apt install --only-upgrade -y warp-terminal || any_fail=1
fi
```

Caveats if you do this:

- **Restart is on the user.** Without the in-app token, the running Warp process keeps the old binary in memory. The user has to fully quit and relaunch Warp before the new version is active. (Mention this in the `info` line.)
- **Sudo session is shared.** Use the existing [`scripts/lib/sudo_shared.sh`](../../scripts/lib/sudo_shared.sh) helper (`sudo_session_init "upgrade-warp"`) so the user isn't re-prompted; see [the sudo-session invariant](../this_repo/sudo-session.md).
- **Don't add `apt upgrade` for unrelated packages.** That violates the [install-vs-upgrade scope rule](../this_repo/upgrades.md#things-intentionally-excluded). Pin the apt operation to `--only-upgrade warp-terminal` (or whatever package list you actually intend).
- **Repo signature drift.** Warp rotates its signing key occasionally; if `apt update` errors with `NO_PUBKEY`, fetch the fresh key from `https://app.warp.dev/download` and re-import to `/usr/share/keyrings/warpdotdev.gpg`. We don't pre-pin the key in this repo.

A new `cat_warp` category (rather than appending to `cat_agents`) would be appropriate if Warp ever ships a CLI installer or `warp-terminal --self-update` flag — until then it's a one-off `apt`-only step that doesn't justify its own category.

## See also

- [`docs/this_repo/upgrades.md`](../this_repo/upgrades.md) — how the explicit upgrade flow is structured; the install-vs-upgrade rule that keeps apt out of the default scope.
- [`docs/this_repo/sudo-session.md`](../this_repo/sudo-session.md) — the shared sudo helper any future `cat_warp` would use.
- [`docs/this_repo/instant-llm-fix-prior-art.md`](../this_repo/instant-llm-fix-prior-art.md) — design-space comparison of Warp's AI features against this repo's `aifix` / `aiblock` flow.
