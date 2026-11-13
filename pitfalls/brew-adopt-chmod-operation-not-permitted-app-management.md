# `brew install --cask --adopt` fails: `chmod: Unable to change file mode … Operation not permitted`

**Symptoms** (grep this section):

- `brew install --cask --adopt <cask>` prints `==> Adopting existing App at '/Applications/<App>.app'`, asks for `Password:`, then fails:

  ```console
  chmod: Unable to change file mode on /Applications/Herdr.app/Contents/_CodeSignature/CodeResources: Operation not permitted
  ==> Purging files for version 0.1.15 of Cask herdr-app
  Error: herdr-app: Failure while executing; `/usr/bin/sudo -E -- chmod -R a+rX,go-w /Applications/Herdr.app` exited with 1. Here's the output:
  chmod: Unable to change file mode on /Applications/Herdr.app/Contents/_CodeSignature/CodeResources: Operation not permitted
  ```

- It fails even with the correct sudo password. Without a TTY (agent shells, fleet-apply), the run aborts at the sudo prompt instead.

**First seen**: 2026-11-13, macOS Apple Silicon maintainer host, adopting `herdr-app` 0.1.15 (installed by the vendor installer). The host also had `_CodeSignature/CodeResources` at mode `0600`.
**Affects**: macOS 13+ hosts adopting an app signed by another developer from a terminal that lacks the App Management permission
**Status**: worked around (grant the permission once per terminal app)

## Root cause

After it accepts the existing app, `--adopt` runs a post-move step that
normalizes permissions with `sudo chmod -R a+rX,go-w <app>`. Here
`_CodeSignature/CodeResources` was `0600`, so chmod had a real change to make.

macOS 13 added App Management protection: a process may modify another
developer's app bundle only if the responsible app (the terminal running
`brew`) has **System Settings → Privacy & Security → App Management**. The
check applies to root too, so `sudo` does not help.

## Fix

1. Turn on **System Settings → Privacy & Security → App Management** for the terminal
   app that runs brew (here: Ghostty).
2. Restart that terminal.
3. Re-run the same command:

```sh
brew install --cask --adopt herdr-app termius wispr-flow clash-verge-rev
```

Verified: after granting Ghostty the permission, the same command adopted all four casks.

The failed attempt left the app and its code signature intact
(`codesign --verify --deep --strict` passed; `diff -rq` against a backup was
clean), and it wrote no Caskroom record. Retrying is safe.

## Related

- [`brew-bundle-redownloads-manually-installed-cask.md`](brew-bundle-redownloads-manually-installed-cask.md): the opt-in adopt pre-flight and its other trade-offs (version-strict, password storm).
- [`brew-uninstall-herdr-gpui-deletes-official-herdr-app.md`](brew-uninstall-herdr-gpui-deletes-official-herdr-app.md): the migration where this was first hit.
