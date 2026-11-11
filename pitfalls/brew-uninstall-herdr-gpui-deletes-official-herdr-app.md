# `brew uninstall herdr-gpui` would delete the official Herdr App

**Symptoms** (grep this section): two apps both want `/Applications/Herdr.app`. The old Herdr UI (`penso/tap/herdr-gpui`, bundle ID `so.pen.herdr-gpui`) was renamed by hand to `HerdrUI.app` to make room for the official Herdr App (`dev.herdr.app`). `brew list --cask --versions herdr-gpui` still shows `herdr-gpui 20261028.1` while `/Applications/Herdr.app` reports `dev.herdr.app`. Uninstalling the old cask, or upgrading it, targets the **official** app.
**First seen**: 2026-11-12, macOS Apple Silicon maintainer host, after the official Herdr App (2026-10-29) arrived next to Herdr UI
**Affects**: any Mac that installed Herdr UI through `penso/tap/herdr-gpui` before the Sheprd rename and then installed the official Herdr App
**Status**: worked around: the Brewfile skips Sheprd while the legacy Caskroom entry exists, and docs give a safe migration

## Root cause

Homebrew records a cask's artifacts by path, not bundle ID. The legacy cask's
`app` stanza targets `/Applications/Herdr.app` (upstream even kept
`app "Sheprd.app", target: "Herdr.app"` after the rename so in-place upgrades
work). Renaming the bundle by hand does not update brew's record, so
`brew uninstall --cask herdr-gpui` (and `brew upgrade`, which replaces the
target) acts on whatever now sits at `/Applications/Herdr.app`: the official
app. `--zap` would also remove Sheprd's retained settings, sign-ins and paired
machines, which still live under the unchanged `so.pen.herdr-gpui` identity.

## Fix

Drop only brew's stale record. Then install the renamed cask, which installs to
`/Applications/Sheprd.app` and no longer collides:

```sh
ls "$(brew --caskroom)/herdr-gpui"        # metadata only: confirm before removing
rm -rf "$(brew --caskroom)/herdr-gpui"
brew untap penso/tap                       # once nothing else uses it
brew install sheprd-labs/tap/sheprd        # same bundle ID → state carries over
# launch Sheprd, confirm machines/settings, then trash the hand-renamed HerdrUI.app
brew install --cask --adopt herdr-app      # optional: let brew own the official app
```

Never use `brew uninstall` or `--zap` on the legacy cask after a manual rename.
See `docs/tools/herdr.md` § Migrating from Herdr UI on macOS.
