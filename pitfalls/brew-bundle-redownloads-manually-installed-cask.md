# `brew bundle` re-downloads & fails on cask whose `.app` is already in `/Applications/`

**Symptoms** (grep this section):

- `brew bundle --file=~/.config/homebrew/Brewfile.darwin` prints `Fetching <cask>` for an app the user has already installed (e.g. by dragging the `.app` into `/Applications/` from a vendor DMG)
- Logs include `A `brew fetch warp cursor ... discord ... ` process has already locked
  /Users/<u>/Library/Caches/Homebrew/downloads/<sha>--<File>.dmg.incomplete. Please wait for it to finish or terminate it to continue.` for many casks at once
- ``brew bundle` failed! Failed to fetch warp, cursor, visual-studio-code, claude, chatgpt, ...` at the end of the run
- Same Brewfile applies cleanly on the **source** mac where the user `brew install --cask`'d things, but breaks on a **second** mac where many `.app`s were dragged in manually before `chezmoi apply` was first run
- `brew list --cask <name>` exits non-zero even though `/Applications/<Name>.app` exists
- `chezmoi apply` succeeds at the chezmoi level but `[WARN] Some packages in macOS packages from Brewfile.darwin still failed after 2 attempts (continuing...)` appears in the log

**First seen**: 2026-05 on `Hanrus-Mac-mini` (mac-mini with many `.app`s pre-dragged into `/Applications/`, then `chezmoi update --init` from a different machine's `Brewfile.darwin`)
**Affects**: any macOS host where casks declared in `~/.config/homebrew/Brewfile.darwin` have `.app` artifacts already present in `/Applications/` but no corresponding entry in `/opt/homebrew/Caskroom/<name>/.metadata/`
**Status**: fixed in `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` via an `--adopt` pre-flight pass (lines 111-165). Upstream feature added in [Homebrew/brew#14033](https://github.com/Homebrew/brew/pull/14033) closing [#14006](https://github.com/Homebrew/brew/issues/14006) — `brew install --cask --adopt` "adopts" an existing artifact in-place without downloading.

## Symptom

```console
$ chezmoi apply
...
[INFO] Installing macOS packages from Brewfile.darwin...
Fetching warp, cursor, visual-studio-code, claude, chatgpt, antigravity, codex-app, codeisland, ollama-app, ...
Fetching: warp, cursor, visual-studio-code, claude, ...
✘ Cask warp (0.2026.05.06.15.42.stable_04)
Error: A `brew fetch warp cursor visual-studio-code claude chatgpt ...` process has already locked /Users/<u>/Library/Caches/Homebrew/downloads/d7b851c68d6ffb0fc9008aa6d18ccb31feff009339ae656932de009c7057b1a3--Warp.dmg.incomplete.
Please wait for it to finish or terminate it to continue.
✘ Cask cursor (3.3.30,...)
Error: A `brew fetch ...` process has already locked /Users/<u>/Library/Caches/Homebrew/downloads/7bf557fd...--Cursor-darwin-arm64.zip.incomplete.
Please wait for it to finish or terminate it to continue.
... (many more)
`brew bundle` failed! Failed to fetch warp, cursor, visual-studio-code, claude, chatgpt, ...
[INFO] Retrying macOS packages from Brewfile.darwin (attempt 2/2, only missing items)...
... (retry hits identical .incomplete locks)
[WARN] Some packages in macOS packages from Brewfile.darwin still failed after 2 attempts (continuing...)
```

```console
$ ls /Applications/Discord.app                 # the app IS already there
/Applications/Discord.app
$ brew list --cask discord                     # but brew doesn't know about it
Error: Cask 'discord' is not installed.
$ ls /opt/homebrew/Caskroom/discord/.metadata/ # no metadata directory
ls: /opt/homebrew/Caskroom/discord/.metadata/: No such file or directory
```

## Root cause

Two cascading issues:

1. **Drag-installed `.app` is invisible to Homebrew.** `brew bundle` checks `Caskroom/<name>/.metadata/<version>/` to decide "already installed." A `.app` you copied manually into `/Applications/` has no Caskroom entry, so brew thinks it's missing and queues it for download. There's no auto-detection of pre-existing `.app`s in `/Applications/` — by design, because brew can't safely assume the version matches what its cask definition expects.
2. **Parallel-fetch lockfile contention.** When `brew bundle` schedules a re-download of many large casks at once, `brew fetch` runs them in parallel and each download claims `~/Library/Caches/Homebrew/downloads/<sha>--<file>.incomplete` plus a sibling lockfile. If any prior `brew fetch` was interrupted (Ctrl-C, terminated, previous failed `chezmoi apply`), the stale `.incomplete*` files cause every fresh attempt to error out instantly with `process has already locked …`. The bundle's own retry loop then hits the same stale locks on attempt 2 and gives up.

The two failure modes are independent but co-occur: (1) makes brew try to re-download apps you already have, and (2) makes that re-download cascade into many parallel locked-file errors at once.

## Workaround

The repo's `chezmoi apply` now does this automatically. **If you need to do it manually** (one-off, or on a host that hasn't applied the latest `run_onchange_after_30_brew_bundle.sh.tmpl` yet):

```bash
# 1. Clear stale lockfiles from any interrupted prior fetch
rm -f ~/Library/Caches/Homebrew/downloads/*.incomplete*

# 2. Adopt every cask whose .app is in /Applications/ but isn't tracked by brew
brew bundle list --casks --file=~/.config/homebrew/Brewfile.darwin | while IFS= read -r cask; do
    brew list --cask "$cask" &>/dev/null && continue   # already tracked
    brew install --cask --adopt "$cask" 2>/dev/null && echo "adopted: $cask"
done

# 3. Re-run brew bundle without auto-update noise
HOMEBREW_NO_AUTO_UPDATE=1 brew bundle --file=~/.config/homebrew/Brewfile.darwin --no-upgrade
```

`brew install --cask --adopt <name>` writes the missing `Caskroom/<name>/.metadata/<version>/...` records pointing at the existing `/Applications/<Name>.app` — **no download happens** — so subsequent `brew bundle` runs see the cask as "already installed" and skip it.

`--adopt` exits non-zero (silently in the script) when the cask's expected `.app` isn't in `/Applications/` at all; that's expected — the regular `brew bundle` pass will then install it normally.

## Prevention

- `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` now runs an `adopt_existing_casks` pre-flight before `brew bundle` on macOS (lines 121-165). It enumerates casks via `brew bundle list --casks --file=…`, skips ones brew already tracks, and runs `brew install --cask --adopt <name>` on the rest.
- Between bundle retry attempts the script calls `clear_brew_download_locks` to wipe any `.incomplete*` files left over from a previous interrupted fetch (lines 174-182).
- The script exports `HOMEBREW_NO_AUTO_UPDATE=1` + `HOMEBREW_NO_INSTALL_UPGRADE=1` so `brew bundle` doesn't trigger the implicit `brew update` that can transiently fail on Aliyun mirror sync lag (`Unable to find <sha> under https://mirrors.aliyun.com/homebrew/brew.git`). Upgrades go through `just upgrade-*`, per `AGENTS.md → "Install vs upgrade is split on purpose"`.
- When adding a new cask to `dot_config/homebrew/Brewfile.darwin.tmpl`, don't pre-emptively delete any existing `/Applications/<Name>.app` — the adopt pre-flight handles it on next apply.

## Related

- [`pitfalls/brew-cask-slow-github-release-assets.md`](brew-cask-slow-github-release-assets.md) — different root cause (Azure CDN slowness on CN networks) but overlapping observable shape (brew downloads slowly / fails). The adopt pre-flight helps here too, because it skips the download entirely when the `.app` is already present.
- [`pitfalls/ngrok-cask-download-flaky.md`](ngrok-cask-download-flaky.md) — another "brew cask download fails" pitfall.
- [`docs/this_repo/upgrades.md`](../docs/this_repo/upgrades.md) — adopt fires during `chezmoi apply` (install path), not `just upgrade-*` (upgrade path).
- [`.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl`](../.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl) — where the fix lives.
- Upstream: [Homebrew/brew#14006](https://github.com/Homebrew/brew/issues/14006) (feature request), [Homebrew/brew#14033](https://github.com/Homebrew/brew/pull/14033) (PR adding `--adopt`).
- `AGENTS.md → "Install vs upgrade is split on purpose"` — explains why we don't `brew upgrade` during apply.
