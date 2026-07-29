# Tailscale

- [Download | Tailscale](https://tailscale.com/download/mac)
  - [tailscale-app — Homebrew Formulae](https://formulae.brew.sh/cask/tailscale-app) - Desktop App (Standalone)
    - [Tailscale Packages - stable track](https://pkgs.tailscale.com/stable/#macos)
  - [tailscale — Homebrew Formulae](https://formulae.brew.sh/formula/tailscale) - CLI
  - [Tailscale App - App Store](https://apps.apple.com/ca/app/tailscale/id1475387142)

> Standalone > App Store

## How this repo installs it (macOS)

- **GUI app + daemon** → `cask "tailscale-app"` in [`Brewfile.darwin`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/homebrew/Brewfile.darwin.tmpl) — the **macsys standalone** build (`io.tailscale.ipn.macsys`), whose **system extension** is the daemon. Previously `mas "Tailscale"`, but Tailscale was **delisted from the Mac App Store**, so `mas` install now fails; the cask is the supported path.
- **CLI on PATH** → **also from the cask**, not a separate formula: the pkg installs `/usr/local/bin/tailscale`, a shell wrapper into the app bundle (`exec /Applications/Tailscale.app/Contents/MacOS/tailscale "$@"`). Do **not** also install the standalone `brew "tailscale"` formula — it's redundant and fights the cask over that same path on every upgrade (ollama-style link conflict) while shipping a `tailscaled` the app already runs.
- **Never** `brew services start tailscale` on macOS: the app's system extension already *is* the daemon; a second `tailscaled` would conflict.

### "Another Tailscale copy was found on this Mac"

If the debug panel reports a conflict at `/Applications/Tailscale.localized/Tailscale.app` (often alongside `DNS Unavailable` / `dns-forward-failing`), that's the **old App Store build left behind** by the `mas → cask` migration (`chezmoi apply` is install-only and won't remove it). Fix:

```bash
sudo rm -rf /Applications/Tailscale.localized   # deletes only the idle App Store copy
```

Full detection + root cause: [`pitfalls/tailscale-another-copy-app-store-leftover.md`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/tailscale-another-copy-app-store-leftover.md).

## How this repo installs it (Linux)

Optional role, gated on **`installTailscale`** (its own prompt — deliberately not
folded into `installNetworkingTools`, a read-only diagnostics bundle, nor into
`installTunnelTools`, which is about exposing localhost to the *public* internet).

`dot_ansible/roles/networking_tools`, tag `tailscale`: the official
`pkgs.tailscale.com` apt repo via `deb822_repository` on Debian/Ubuntu/Raspbian,
the yum repo on the RedHat family, guarded by a `tailscale version` probe so it is
install-only. Derivatives whose codename is not an upstream suite (Mint, Pop!_OS)
are skipped with a pointer at the official installer, which does that mapping
itself.

The apt cache refresh is **scoped to the Tailscale source only**
(`-o Dir::Etc::sourcelist=sources.list.d/tailscale.sources`). An unscoped
`apt-get update` re-fetches every third-party source on the box; one flaky sibling
would then leave the just-added Tailscale repo unindexed. (The Steam block in
`gui_apps_linux` already names tailscale as one of those flaky sources.)

**Two steps ansible deliberately does not take** — both interactive and/or
sudo-requiring, and both printed at the end of the run:

```bash
sudo tailscale up                      # browser login, joins the tailnet
sudo tailscale set --operator=$USER    # lets `tsnet serve` run without sudo
```

## Driving it: the `tsnet` CLI

[`tsnet`](tsnet.md) wraps the two workflows this repo needs — turning the tailnet
device list into `~/.ssh/config` entries, and exposing a local service over
tailnet HTTPS (`tailscale serve`) for anything that hard-requires an `https://`
origin. Picker twin: `tv tailnet`. Start with `tsnet doctor`.
