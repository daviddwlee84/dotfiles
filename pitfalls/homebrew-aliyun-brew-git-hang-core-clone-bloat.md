# `brew update` / `brew upgrade` hangs 60s+ then does nothing (Aliyun `brew.git`); or `brew` disk usage balloons to ~1 GB

**Symptoms** (grep this section):

- Any `brew` command that auto-updates (`brew update`, `brew upgrade <x>`,
  `brew install <x>`) prints `HOMEBREW_BREW_GIT_REMOTE set: using
  https://mirrors.aliyun.com/homebrew/brew.git as the Homebrew/brew Git remote.`
  then **hangs indefinitely** (Ctrl-C / `^C` to escape); no progress, no error
- `brew upgrade specstoryai/tap/specstory` (or any tap upgrade) never completes;
  the shell tool / terminal times out at 60s / 120s
- Workaround that "works": `unset HOMEBREW_BREW_GIT_REMOTE` (falls back to
  GitHub `Homebrew/brew`, which streams fine) — you find yourself doing this
  before every `brew upgrade`
- `git ls-remote https://mirrors.aliyun.com/homebrew/brew.git HEAD` returns
  **instantly** (so the mirror *looks* up), but
  `git fetch https://mirrors.aliyun.com/homebrew/brew.git` **stalls / times out**
- Separately: `brew update` was fast, then became slow again; `du -sh "$(brew
  --repo homebrew/core)/.git"` shows **~1 GB** (was ~8 KB); `brew tap-info
  homebrew/core` shows `(18 files, 1GB)` instead of a tiny stub

**First seen**: 2026-07 on `Da-Weis-Mac-mini` (macOS arm64, China network,
`useChineseMirror=true`). SpecStory 1.13.0 → 2.0.0 upgrade surfaced it.
**Affects**: any host with `HOMEBREW_BREW_GIT_REMOTE` pointing at Aliyun
(`mirrors.aliyun.com/homebrew/brew.git`), and — separately — any host with
`HOMEBREW_CORE_GIT_REMOTE` **set** at all under Homebrew 4.x+ (API mode).
**Status**: fixed — baseline switched Aliyun → **BFSU** and
`HOMEBREW_CORE_GIT_REMOTE` dropped entirely, in
`dot_config/shell/00_exports.sh.tmpl` + `run_once_before_00_bootstrap.sh.tmpl` +
`.chezmoiscripts/global/run_onchange_after_20_ansible_roles.sh.tmpl`, and the
`brew-mirror` helper (`dot_config/shell/10_aliases.sh`).

## Symptom

```console
$ specstory run          # (or: brew upgrade specstoryai/tap/specstory)
# ... "Update Available 2.0.0" ...
$ brew upgrade specstoryai/tap/specstory
HOMEBREW_BREW_GIT_REMOTE set: using https://mirrors.aliyun.com/homebrew/brew.git as the Homebrew/brew Git remote.
^C     # hangs forever — brew auto-runs `brew update` first, which fetches brew.git

# The tell: ref advertisement is instant, packfile fetch stalls
$ git ls-remote https://mirrors.aliyun.com/homebrew/brew.git HEAD
2b3683ac...  HEAD                    # returns in 0.3s

$ git -C /opt/homebrew fetch --dry-run origin
# ... hangs, killed at 60s ...
```

Two independent problems compound here:

1. **Aliyun's `brew.git` git smart-HTTP hangs** on the actual fetch.
2. **`HOMEBREW_CORE_GIT_REMOTE` being set** silently converts homebrew/core
   from the API stub into a full ~1 GB git clone on the next `brew update`.

## Root cause

### 1. Aliyun `brew.git` upload-pack is broken

`git ls-remote` only triggers the cheap **ref advertisement** (`GET
/info/refs?service=git-upload-pack`). The real fetch runs
**`git-upload-pack`** to negotiate and stream a packfile
(`POST /git-upload-pack`) — and *that* stalls on Aliyun's mirror. So every
health check (`ls-remote`, curl HEAD) passes while every actual `brew update`
freezes. Benchmarked 2026-07 (shallow `git fetch --depth=1` on `brew.git`, CN
network, back-to-back):

| Mirror | `brew.git` fetch | bottle/API throughput |
|---|---|---|
| **BFSU** (`mirrors.bfsu.edu.cn/git/homebrew/brew.git`) | **OK 1.1s** | **31 MB/s** |
| USTC (`mirrors.ustc.edu.cn/brew.git`) | OK 1.0s | 11 MB/s |
| Aliyun (`mirrors.aliyun.com/homebrew/brew.git`) | **FAIL/hang** | 17 MB/s |
| TUNA (`mirrors.tuna.tsinghua.edu.cn/git/homebrew/brew.git`) | **timeout 45s** | 6 MB/s |

Aliyun's **bottle/API** domain (`homebrew-bottles`, `homebrew-bottles/api`) is
fine — it's plain HTTP file serving, not git. Only the git endpoint is broken.
TUNA is the old baseline this repo moved away from precisely because of
`brew.git` queueing ("Waiting in queue"); the benchmark confirms it's still slow.

### 2. `HOMEBREW_CORE_GIT_REMOTE` forces a 1 GB clone in API mode

Homebrew 4.0+ defaults to the **JSON API** (`HOMEBREW_API_DOMAIN`) as the source
of truth for formulae; `homebrew/core` stays a ~8 KB stub and is never fully
cloned. **But if `HOMEBREW_CORE_GIT_REMOTE` is exported, `brew update` honors it
and does a full `git fetch` of homebrew-core** — converting the stub into a
~1 GB clone (slow fetch every update + disk bloat) for zero benefit. USTC
[dropped its `homebrew-core.git` mirror in 2026-06](https://mirrors.ustc.edu.cn/help/homebrew-core.git.html)
for exactly this reason ("由于 Brew 4.0 版本后默认使用元数据 JSON API…").

The old config set `HOMEBREW_CORE_GIT_REMOTE` on all four mirror presets — a
latent trap that only bites once `brew update` actually runs it.

## Workaround

Immediate (one-off session):

```bash
# Switch to a working mirror (BFSU fastest; USTC solid fallback)
brew-mirror bfsu          # sets bottle/API + brew.git, unsets CORE_GIT_REMOTE,
                          # auto-untaps a stray >100 MB homebrew/core clone
brew update               # now completes in ~10s

# If you don't have the helper (fresh shell), do it by hand:
export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.bfsu.edu.cn/git/homebrew/brew.git"
export HOMEBREW_API_DOMAIN="https://mirrors.bfsu.edu.cn/homebrew-bottles/api"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.bfsu.edu.cn/homebrew-bottles"
unset HOMEBREW_CORE_GIT_REMOTE
git -C "$(brew --repo)" remote set-url origin "$HOMEBREW_BREW_GIT_REMOTE"
```

If homebrew/core already bloated to ~1 GB, slim it back to API mode:

```bash
du -sh "$(brew --repo homebrew/core)/.git"   # confirm ~1 GB
brew untap homebrew/core                      # formulae still resolve via the API
```

If a single tap upgrade is what you need and `brew update` keeps hanging, you can
bypass the auto-update + slow test step entirely (this is how the SpecStory 2.0.0
upgrade was completed — download works fine standalone, only git-fetch hangs):

```bash
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 \
  brew reinstall --formula <tap>/<formula>
```

## Prevention

- **Baseline is BFSU**, set in three layers (interactive shell + 2 bootstrap
  scripts). Do NOT revert to Aliyun for the *git* remote — its `brew.git`
  upload-pack hangs. Aliyun bottles are fine if you ever want them.
- **Never export `HOMEBREW_CORE_GIT_REMOTE`.** Homebrew 4.x uses the JSON API;
  setting it forces a 1 GB clone. The `brew-mirror` helper actively `unset`s it
  and untaps any stray >100 MB clone. This trap is easy to reintroduce by
  copy-pasting a mirror's "四个 HOMEBREW_* 变量" snippet — resist it.
- A mirror's `git ls-remote` / curl HEAD returning fast does **not** prove it
  works. Test the real operation: `git fetch --depth=1 <brew.git-url> HEAD`.
- Switch mirrors with `brew-mirror {bfsu|ustc|aliyun|tuna}`, not by hand-editing
  env vars — it keeps the brew.git clone origin, the env vars, and the
  core-untap guard consistent.

## Related

- [`docs/tools/mirrors.md`](../docs/tools/mirrors.md) → "brew update … hangs for
  60s+" + "brew disk usage ballooned" troubleshooting (benchmark table lives
  here too)
- [`docs/tools/infrastructure-as-code.md`](../docs/tools/infrastructure-as-code.md)
  → Homebrew mirror setup
- [`pitfalls/brew-cask-slow-github-release-assets.md`](brew-cask-slow-github-release-assets.md)
  — different root (Azure blob CDN for cask DMGs, not git) but same family
  (GFW + Homebrew downloads slow); mirrors do NOT help *that* one
- [`pitfalls/homebrew-6-refuses-untrusted-tap-formula.md`](homebrew-6-refuses-untrusted-tap-formula.md)
  — the `brew trust <tap>` gate you also hit during the same SpecStory upgrade
- [`pitfalls/tuna-nodejs-mirror-aggressive-gc.md`](tuna-nodejs-mirror-aggressive-gc.md)
  — another "this specific mirror is subtly broken, pick a different one" case
- USTC dropping homebrew-core.git (2026-06):
  https://mirrors.ustc.edu.cn/help/homebrew-core.git.html
