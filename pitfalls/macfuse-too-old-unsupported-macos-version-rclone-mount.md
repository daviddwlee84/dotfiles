# macFUSE "Unsupported macOS Version" — `rclone mount` won't mount after a macOS upgrade

**Symptoms** (grep this section):
- macFUSE dialog: **"Unsupported macOS Version — The installed version of macFUSE
  is too old for the operating system. Please upgrade your macFUSE installation
  to one that is compatible with the currently running version of macOS."**
- Fires on boot, on `rclone mount …`, or whenever any FUSE filesystem tries to load
- `rclone mount` fails / hangs even though `rclone mount --help` works and the
  remote is configured correctly
- `brew info --cask macfuse` shows a **newer** version than what's actually on disk

**First seen**: 2026-06 (Mac mini, macOS 26.2, macFUSE 4.10.2 installed)
**Affects**: macOS major upgrades (here macOS 26 "Tahoe") with a macFUSE 4.x kext/system-extension still installed; cask version 5.x required
**Status**: by design (kext version-locked to macOS major); manual upgrade documented — **not** managed by this repo

## Symptom

After upgrading to macOS 26.2, the macFUSE "Unsupported macOS Version" dialog
appears and `rclone mount` silently fails. The trap is that **rclone looks
innocent** — both the Homebrew rclone and the official build have the `mount`
subcommand compiled in (verify: `rclone mount --help` → exits 0), so the binary
is not the problem. macFUSE is the runtime dependency, and it's too old.

The confusing part — `brew` *reports* the right version but it isn't installed:

```
$ brew info --cask macfuse
==> macfuse (macFUSE): 5.2.0 (auto_updates)      # <-- what the cask points to
Installed
/opt/homebrew/Caskroom/macfuse/4.10.2 (15.4MB)   # <-- what's actually on disk
  Installed on 2025-08-01 ...
```

`brew upgrade` does **not** fix it: the cask is `auto_updates`, so Homebrew
defers version management to the app — but macFUSE is a system extension that
can't silently self-update; it needs a reinstall + reboot + GUI approval.

## Root cause

macFUSE ships a kernel/system extension that is **version-locked to the macOS
major version**. macFUSE 4.x is not loadable on macOS 26 — macOS 26 needs
macFUSE 5.x. The old extension stays installed across the OS upgrade and macOS
rejects it at load time, hence the dialog. rclone (brew or official) is unaffected;
it just can't get a working FUSE layer to mount onto.

## Workaround

```bash
brew reinstall --cask macfuse          # pulls the current 5.x pkg
# reboot
# System Settings ▸ Privacy & Security ▸ allow the blocked system extension
#   (team "Benjamin Fleischer") ▸ enter password
# reboot again if macOS prompts
rclone mount myremote: ~/mnt/myremote --vfs-cache-mode full --daemon   # now works
```

## Prevention

- After **any macOS major upgrade**, `brew reinstall --cask macfuse` before
  relying on `rclone mount` / any FUSE filesystem.
- This is **not** automated in this repo: macFUSE needs a reboot + GUI security
  approval, which violates the install-only philosophy (and ansible can't click
  the Privacy & Security toggle). Documented in
  [`docs/this_repo/tool-managers.md`](../docs/this_repo/tool-managers.md) and
  [`docs/infra/shared-storage.md`](../docs/infra/shared-storage.md).

### Aside: rclone binary sprawl is harmless here

The same machine had three rclone binaries on `PATH`
(`~/.local/bin/rclone` official, `/opt/homebrew/bin/rclone` brew,
`/usr/local/bin/rclone` a stray root-owned manual install). All support `mount`;
none was the cause. Optional tidy-up: keep one (brew's is fine — modern Homebrew
rclone ≥ 1.73 is built with `cmount`/macFUSE support) and remove the others.

## Related

- [`docs/infra/shared-storage.md`](../docs/infra/shared-storage.md) → rclone mount section
- [`docs/this_repo/tool-managers.md`](../docs/this_repo/tool-managers.md) → rclone row
- Sibling: [`brew-bundle-redownloads-manually-installed-cask`](brew-bundle-redownloads-manually-installed-cask.md)
