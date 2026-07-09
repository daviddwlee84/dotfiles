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
