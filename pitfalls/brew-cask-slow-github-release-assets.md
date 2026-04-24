# `brew upgrade --cask <name>` download creeps at ~25 KB/s from `release-assets.githubusercontent.com`

**Symptoms** (grep this section):

- `brew upgrade --cask super-productivity` (or any other cask whose `url` points
  at `github.com/<owner>/<repo>/releases/download/.../*.dmg`) shows sustained
  ~20–30 KB/s download speed — a ~120 MB DMG takes 60+ min
- `ps aux | grep curl` shows a long-running curl against a URL shaped like
  `https://release-assets.githubusercontent.com/github-production-release-asset/<numeric>/<uuid>?sp=r&...&jwt=eyJ...`
- Partial file accumulates at
  `~/Library/Caches/Homebrew/downloads/<sha256>--<filename>.incomplete` and
  size grows very slowly
- `HOMEBREW_BOTTLE_DOMAIN=https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles`
  and `HOMEBREW_API_DOMAIN=.../homebrew-bottles/api` are set but make **no
  difference** for cask DMGs
- Speed benchmarks of `ghproxy.net` and `ghfast.top` GitHub-proxy mirrors (10 MB
  range request, 20s timeout) show ~23–24 KB/s — within noise of direct
- Routing through Clash/mihomo HTTP proxy (`http://127.0.0.1:7890` or `:7891`)
  is also ~19 KB/s — not faster, sometimes slower

**First seen**: 2026-04 on `dwlee-mac` (macOS, China network, Clash for Windows active)
**Affects**: Any `brew upgrade --cask` / `brew install --cask` where the
upstream URL is on `github.com/.../releases/download/...` (redirects to
`release-assets.githubusercontent.com` → Azure blob
`releaseassetproduction.blob.core.windows.net`). Real-world hit on
`super-productivity` (v17.1.6 → v18.2.8 DMG, 123 MB).
**Status**: no workaround that reliably speeds things up on CN networks;
accept the slow download and background it. Documented to save future
debugging time.

## Symptom

Download progress bar (brew's built-in) barely moves. Strace-equivalent check:

```console
$ ps aux | grep -E 'curl.*release-assets' | grep -v grep
daviddwlee84 ... /usr/bin/curl ... https://release-assets.githubusercontent.com/github-production-release-asset/78243781/ee2cafb6-...?sp=r&...&jwt=eyJ0eXAi...

$ ls -la ~/Library/Caches/Homebrew/downloads/*super-productivity*.incomplete
-rw-r--r--  1 user  staff  52127025 Apr 23 23:15 <sha>--superProductivity-arm64.dmg.incomplete
# ... 10 minutes later ...
-rw-r--r--  1 user  staff  65000000 Apr 23 23:25 <sha>--superProductivity-arm64.dmg.incomplete
# ~21 KB/s
```

## Root cause

**Not** a brew / homebrew-mirror / cask-metadata issue. GitHub release binaries
are served from **Azure Blob Storage**
(`releaseassetproduction.blob.core.windows.net`) behind the
`release-assets.githubusercontent.com` hostname, with a short-lived (~3 min)
JWT-signed URL.

Three reasons the usual mirror tricks don't help:

1. **TUNA / USTC / Aliyun Homebrew mirrors** (`HOMEBREW_BOTTLE_DOMAIN`,
   `HOMEBREW_API_DOMAIN`, `HOMEBREW_BREW_GIT_REMOTE`,
   `HOMEBREW_CORE_GIT_REMOTE`) only mirror **bottles** (compiled formulae
   tarballs) and git metadata. **They do not mirror cask DMG/PKG artifacts** —
   casks always resolve to the upstream `url` in the cask definition.
2. **GitHub-proxy services** (`ghproxy.net`, `ghfast.top`, `mirror.ghproxy.com`,
   etc.) do forward `release-assets.githubusercontent.com` correctly (HEAD returns
   200 with full content-length), but they proxy through their own infra and
   end up bottlenecked on the same Azure blob path. Benchmarks here showed
   them within 10% of direct.
3. **Clash/mihomo via `http://127.0.0.1:789x`** routed as configured: in
   typical CN Clash profiles, `github.com` and `*.githubusercontent.com` are
   matched by a `DIRECT` rule (so downloads go through the local ISP anyway),
   or matched to a "proxy" group whose selected node has poor routing to
   Azure. Without swapping to a known-good outbound node, Clash doesn't help.

Separately there's a common **red-herring diagnostic path** worth calling out:

- `brew info --cask <name>` vs `brew cat --cask <name>` can show **different
  versions** when an older version is installed. `brew info` reads the live
  API (fresh), `brew cat` reads the **install-time metadata snapshot** at
  `/opt/homebrew/Caskroom/<name>/.metadata/<installed-version>/.../Casks/<name>.json`.
  Seeing the old version in `brew cat` is not a stale-mirror bug.

## Workaround

No reliable speedup. In priority order:

1. **Accept it and background the upgrade.** Brew's download supports resume
   via `.incomplete`, so killing and re-running picks up where it left off:

   ```bash
   nohup bash -c 'HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask <name>' \
     > /tmp/brew-upgrade.log 2>&1 &
   disown
   tail -f /tmp/brew-upgrade.log
   ```

2. **Manual download + pre-seed the brew cache.** If you have a faster path
   (different network, VPN, phone hotspot, friend in another country):

   ```bash
   # Find the expected cache filename (includes SHA256 prefix):
   brew fetch --cask <name> --force --retry --verbose 2>&1 | grep -E "Already downloaded|->"
   # Or reconstruct:
   URL="$(brew cat --cask <name> | jq -r .url)"
   SHA="$(brew cat --cask <name> | jq -r .sha256)"
   FN="${URL##*/}"
   # Download via fast route, then drop into brew's download cache:
   curl -fL -o "$HOME/Library/Caches/Homebrew/downloads/${SHA}--${FN}" "$URL"
   # Now re-run; brew verifies SHA256 and skips re-download:
   brew upgrade --cask <name>
   ```

3. **Switch Clash to a node with good Azure blob routing** (Japan/HK/SG nodes
   are usually faster to Azure East-Asia than US nodes). Test before kicking
   off a real download:

   ```bash
   curl -sf -o /dev/null --max-time 20 \
     -x http://127.0.0.1:7890 \
     --range 0-10485759 \
     -w 'speed_download=%{speed_download} bytes/s\n' \
     "$URL"
   ```

   If `speed_download` × 8 / 1024 gives Mbps > ~1, proceed.

## Prevention

- Don't rely on TUNA/USTC `HOMEBREW_*` env vars to speed up cask DMG
  downloads — they don't.
- Don't spend time swapping `HOMEBREW_*_DOMAIN` or re-running
  `brew update --force` hoping cask metadata is stale — the metadata is fine,
  the Azure blob path is the bottleneck.
- When diagnosing "brew is downloading the wrong version", compare
  `brew info --cask <n>` (live API) against
  `~/Library/Caches/Homebrew/api/cask/<n>.json` (fresh per-cask cache) rather
  than `brew cat --cask <n>` (install-time snapshot, pinned to installed
  version).
- For casks that are painful to re-download on slow networks, consider
  pinning via `brew pin` equivalent (casks have no native pin — omit from
  `brew upgrade` or use `brew bundle --file=<subset>.Brewfile`).

## Related

- [`pitfalls/npm-postinstall-github-releases-hang.md`](npm-postinstall-github-releases-hang.md)
  — same root (GitHub release assets over CN network) but different symptom
  (infinite hang vs slow crawl) and different tool (npm postinstall vs brew cask)
- [`docs/this_repo/upgrades.md`](../docs/this_repo/upgrades.md) — how
  `just upgrade-cask` invokes brew
- [`dot_config/homebrew/Brewfile.darwin.tmpl`](../dot_config/homebrew/Brewfile.darwin.tmpl) —
  where `cask "super-productivity"` is declared
- `AGENTS.md` → "Install vs upgrade is split on purpose" — upgrades are
  opt-in via `just upgrade-*`, so this slowness only hits when user explicitly
  asks for it (not on `chezmoi apply`)
