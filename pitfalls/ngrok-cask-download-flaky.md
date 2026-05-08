# `brew install --cask ngrok`: `curl: (52) Empty reply from server` from `bin.ngrok.com`

## Symptom

Ansible `networking_tools` role, ngrok install task, observed mid-day on a
darwin-amd64 box with otherwise healthy networking (Homebrew updated fine,
cloudflared installed fine in the same play, all other casks succeeded):

```
[90] TASK · [networking_tools : Install ngrok via Homebrew]
[ERROR]: Task failed: Module failed: ✔︎ API Source ngrok.rb
✘ Cask ngrok (3.39.1,c7rqf3Jyky7,a)
Error: Download failed on Cask 'ngrok' with message:
  Download failed: https://bin.ngrok.com/a/c7rqf3Jyky7/ngrok-v3-3.39.1-darwin-amd64.zip
  curl: (52) Empty reply from server
```

The task ran for ~1m39s before the error (likely retried internally by
Homebrew before giving up). The exact same URL responded HTTP 200 with the
full 12 MB payload when retried by hand a few minutes later.

## Root cause

`bin.ngrok.com` is fronted by Heroku (visible in `report-to` /
`reporting-endpoints` headers). HTTP 52 ("empty reply from server") on
Heroku-fronted endpoints is almost always a transient condition: dyno
restart, router instance failover, edge instance recycling. It is not
correlated with our network position (worked from Taiwan, failed minutes
earlier from the same IP). It is also not specific to the cask version —
the URL embeds a per-build token (`c7rqf3Jyky7`) but the same token kept
working across the failure.

This is a property of ngrok's CDN choice, not Homebrew, not our config, not
chezmoi.

## Fix

Two-pronged in `dot_ansible/roles/networking_tools/tasks/main.yml`:

1. **Pre-check**: skip the brew install when `which ngrok` already finds the
   binary. Re-applies don't pay the network cost (or risk the flake) for an
   already-installed tool. The Homebrew module is already idempotent at the
   formula level, but `community.general.homebrew` still launches `brew` and
   has been observed to re-attempt the download in some upgrade-eligible
   states.
2. **Retry loop**: wrap the install in `until / retries: 3 / delay: 15` so
   transient HTTP 52 from a single CDN edge instance can be retried twice
   more (typically clears in 15-30s). Final-failure path remains the
   existing `rescue:` block that warns and continues — we never want a
   half-fleet ngrok outage to fail an entire `chezmoi apply`.

```yaml
- name: Install ngrok via Homebrew (with retries for flaky bin.ngrok.com CDN)
  when: ngrok_present_macos.rc != 0
  community.general.homebrew:
    name: ngrok
    state: present
  register: ngrok_brew_install
  until: ngrok_brew_install is succeeded
  retries: 3
  delay: 15
```

## Don't do

- Don't switch the install to a manual `unzip` from `bin.ngrok.com` — same
  CDN, same failure surface. The one-prefix-deeper URL
  `https://dl.equinox.io/ngrok/ngrok-v3/stable/archive` (which ngrok's own
  install docs use) is also Heroku-fronted.
- Don't add a generic `wait_for: host=bin.ngrok.com` pre-check — it would
  TCP-connect successfully even when the HTTP layer is returning 52s.
- Don't fail the play. ngrok is genuinely optional (gated by the
  `installTunnelTools` chezmoi prompt). User can `brew install --cask ngrok`
  later when the CDN is happy.

## Verification

After the rescue path fires, the warning message has the right shape and
the apply continues:

```
ngrok macOS installation failed after 3 retries — skipping. Re-run
`brew install --cask ngrok` later.
```

Manual recovery on the affected host once the CDN recovers:

```bash
brew install --cask ngrok
# or, if the cask is half-installed:
brew uninstall --cask --force ngrok && brew install --cask ngrok
```

## Related

- [`dot_ansible/roles/networking_tools/tasks/main.yml`](../dot_ansible/roles/networking_tools/tasks/main.yml) — the patched task block
- [`docs/tools/tunnels.md`](../docs/tools/tunnels.md) — ngrok / cloudflared user-facing docs
