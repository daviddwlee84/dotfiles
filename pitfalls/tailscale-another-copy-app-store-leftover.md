# "Another Tailscale copy was found on this Mac" + DNS unavailable

**Symptoms** (grep this section):
- Tailscale debug → System Configuration Inspector: `System Configuration Issue Found` / `A software conflict and/or installation error on your Mac has been detected` / `Another Tailscale copy was found on this Mac.` / `Another copy of Tailscale was found at this path: /Applications/Tailscale.localized/Tailscale.app` / `onlyOneCopyExplainer`
- `Current Issues` → `DNS Unavailable` / `Tailscale can't reach the configured DNS servers` / `Code: dns-forward-failing`
- `mdfind -name "Tailscale.app"` returns **two** paths: `/Applications/Tailscale.app` **and** `/Applications/Tailscale.localized/Tailscale.app`
- macsys menu-bar app keeps flagging the conflict even after quitting/reopening
- (related, second trap) `brew upgrade --cask tailscale-app` prints `Removing files: /usr/local/bin/tailscale` and re-creates it; a later `brew upgrade tailscale` / `brew link tailscale` warns `Target /usr/local/bin/tailscale already exists` — the **formula and cask fight over `/usr/local/bin/tailscale`**

**First seen**: 2026-07
**Affects**: macOS. (1) The `.localized` leftover bites any host that installed Tailscale from the Mac App Store **before** this repo migrated `mas "Tailscale"` → `cask "tailscale-app"` (May 2026). (2) The formula/cask CLI-path conflict bites any host that had **both** `cask "tailscale-app"` and the standalone `brew "tailscale"` formula installed.
**Status**: fixed — delete the leftover; use the **cask only** (no `tailscale` formula on macOS)

## Symptom

Two independent Tailscale `.app` bundles coexist. The **running** one is the
macsys standalone build (installed by `cask "tailscale-app"`); the **idle** one
is the old sandboxed App Store build, sitting in a `.localized` wrapper folder:

```
$ mdfind -name "Tailscale.app"
/Applications/Tailscale.localized/Tailscale.app
/Applications/Tailscale.app

$ for p in /Applications/Tailscale.app /Applications/Tailscale.localized/Tailscale.app; do
    echo "$p → $(defaults read "$p/Contents/Info.plist" CFBundleIdentifier)  $(defaults read "$p/Contents/Info.plist" CFBundleShortVersionString)"
  done
/Applications/Tailscale.app                       → io.tailscale.ipn.macsys  1.98.8   # cask, RUNNING, system extension
/Applications/Tailscale.localized/Tailscale.app   → io.tailscale.ipn.macos   1.98.8   # App Store leftover, idle
```

The `dns-forward-failing` / DNS Unavailable banner tends to ride along with the
conflict (two IPN clients confusing the network-extension / DNS proxy state).

## Root cause

Two collisions, both stemming from **install-only** package management:

### 1. App Store `.app` leftover (the "Another copy" warning)

Two Tailscale variants exist for macOS, with *different bundle IDs and signing
chains* — macOS treats them as separate apps:

- `io.tailscale.ipn.**macsys**` — standalone build, Developer ID-signed
  (`Developer ID Application: Tailscale Inc. (W5364U7YZB)`), runs a **system
  extension** as the daemon. This is what `cask "tailscale-app"` installs.
- `io.tailscale.ipn.**macos**` — sandboxed **Mac App Store** build, re-signed by
  Apple (`Apple Mac OS Application Signing`). Installed into a
  `/Applications/Tailscale.localized/` wrapper folder.

This repo migrated `mas` → `cask` in May 2026 (Tailscale was delisted from the
Mac App Store — `mas` install now fails with `No apps found in the App Store for
ADAM ID 1475387142`; see `dot_config/homebrew/Brewfile.darwin.tmpl`). `chezmoi
apply` is **install-only** and does not uninstall the previously `mas`-installed
copy, so it lingers. The macsys installer takes `/Applications/Tailscale.app`
and shoves the old copy aside into `.localized/`, producing the warning.

(`_MASReceipt` exists in **both** bundles, so it is *not* a reliable
discriminator — use `CFBundleIdentifier` `macsys` vs `macos`, or the `codesign
-dv --verbose=4` Authority line, to tell them apart.)

### 2. `tailscale` formula vs `tailscale-app` cask fight over the CLI path

The `tailscale-app` **cask/pkg already installs the CLI** at
`/usr/local/bin/tailscale` — a tiny root-owned shell wrapper into the app:

```
$ cat /usr/local/bin/tailscale
#!/bin/sh
/Applications/Tailscale.app/Contents/MacOS/tailscale "$@"
```

So the separate standalone **`brew "tailscale"` formula is redundant** on a
GUI-app host. Worse, both the formula (via its `/usr/local/bin/tailscale`
symlink into the Cellar) and the cask (via the pkg wrapper) target the **same
path** — whoever installs/upgrades last wins, so `brew upgrade tailscale` and
`brew upgrade --cask tailscale-app` clobber each other. The formula also ships a
`/usr/local/bin/tailscaled` the app's system extension already provides — a
daemon that must **never** run on macOS. Same shape as
[`ollama-brew-link-fails-cask-shadows-formula`](ollama-brew-link-fails-cask-shadows-formula.md).

## Workaround

**Delete the idle App Store leftover** (root-owned → needs `sudo`). The running
macsys cask app and your tailnet login are untouched:

```bash
sudo rm -rf /Applications/Tailscale.localized
```

The "Another Tailscale copy" warning clears once the second `.app` is gone.
Optionally purge the stale sandbox container:

```bash
rm -rf ~/Library/Containers/io.tailscale.ipn.macos ~/Library/Group\ Containers/*.io.tailscale.ipn.macos 2>/dev/null || true
```

**Drop the redundant formula** so nothing fights the cask over the CLI path. The
cask's `/usr/local/bin/tailscale` wrapper is a pkg file, not brew-managed, so
`brew uninstall` leaves it in place — the CLI keeps working:

```bash
brew uninstall tailscale                 # removes the formula + its stray tailscaled symlink
tailscale version                        # still 1.98.8 via the cask wrapper
```

Keep the cask current (`auto_updates`, but a running server may need a nudge):

```bash
HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask tailscale-app   # sudo + may re-approve the system extension
```

## Prevention

- **Cask only on macOS. No `tailscale` formula.** The repo's shared
  `dot_config/homebrew/Brewfile.tmpl` carries an explicit "deliberately no
  `brew \"tailscale\"`" note in the darwin block — do not re-add it. The GUI app
  (`cask "tailscale-app"`, Brewfile.darwin) *is* the daemon **and** the CLI.
- **NEVER `brew services start tailscale` on macOS.** Homebrew's own post-install
  caveat suggests it, but the app's system extension is the daemon; a second
  `tailscaled` conflicts.
- **Prefer Standalone (cask) over App Store** — see `docs/tools/Tailscale.md`
  ("Standalone > App Store"). Do **not** re-add a `mas "Tailscale"` entry (it's
  delisted anyway).
- Fresh installs don't hit either trap (no App Store copy, no formula). These
  only bite hosts that predate the `mas → cask` migration or that once had the
  formula installed alongside the cask.

## Related

- `docs/tools/Tailscale.md` — install preference (Standalone > App Store) + this cleanup
- `dot_config/homebrew/Brewfile.darwin.tmpl` — `cask "tailscale-app"` + delisted-`mas` note
- `dot_config/homebrew/Brewfile.tmpl` — darwin block's "deliberately no formula" note
- `docs/this_repo/tool-managers.md` — A–Z row for `tailscale-app`
- [`ollama-brew-link-fails-cask-shadows-formula`](ollama-brew-link-fails-cask-shadows-formula.md) — same formula-vs-cask path fight
- [`macfuse-too-old-unsupported-macos-version-rclone-mount`](macfuse-too-old-unsupported-macos-version-rclone-mount.md) — another `auto_updates` cask that `brew upgrade` won't move
