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
**Status**: **partially mitigated** in `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl`. The stale-lockfile half (`clear_brew_download_locks` + retry pass) is permanently on. The `--adopt` pre-flight half is **opt-in** via `CHEZMOI_BREW_ADOPT_PREFLIGHT=1` — see "Why `--adopt` is opt-in" below. Upstream `--adopt` was added in [Homebrew/brew#14033](https://github.com/Homebrew/brew/pull/14033) closing [#14006](https://github.com/Homebrew/brew/issues/14006).

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

## Why `--adopt` is opt-in (the field-tested findings)

The first implementation of the adopt pre-flight ran unconditionally. Real-world testing on `Hanrus-Mac-mini` (22 casks in `Brewfile.darwin`, ~half drag-installed) revealed four reasons `--adopt` isn't the clean win the upstream PR description suggests:

1. **`--adopt` does NOT fast-fail on a missing artifact.** brew's cask installer always runs `fetch_artifacts` (download) BEFORE `install_artifacts` (where the `--adopt` branch decides adopt-or-error). So `brew install --cask --adopt cursor` when `/Applications/Cursor.app` doesn't exist will still download `Cursor-darwin-arm64.zip` (~150MB from cursor.com CDN, painfully slow on CN networks) and only THEN raise `Error: It seems there is no installed App at '/Applications/Cursor.app' to adopt`. Our script now filesystem-prefilters by `/Applications/*.app` presence to avoid this — but that only catches the "missing" case, not the "present-but-mismatched" case below.

2. **`--adopt` is byte-exact strict.** brew compares the downloaded artifact's SHA256 against `/Applications/<App>.app`. If your manually-installed version is anything other than the *exact* current brew-formula version, brew raises an error and falls back to a full install (downloads, then overwrites). In one real-world apply, only **8 of 19** filtered casks actually adopted; the other 11 hit version mismatch (user had v3.3.30 of Cursor, brew expected v3.3.32, etc.) and re-downloaded anyway. Net win on first apply: ~36%.

3. **Password storm.** Each `brew install --cask --adopt` invocation internally shells out to `sudo /usr/sbin/installer` (pkg-based casks) or `sudo xattr` (quarantine bit removal) or similar. Our `sudo_session_warm_cache` warms the TTY timestamp once, but brew's internal sudo invocations don't always reuse it — they may `sudo -k` first or use a different timestamp_type. Observed: one `Password:` prompt per pkg-based cask, with multi-second gaps where the user must babysit the terminal.

4. **Mac App Store conflicts.** Casks whose vendor also ships via the App Store (e.g. `tailscale-app`) pop up an interactive *"Mac App Store Install Detected"* dialog mid-apply when brew runs the cask's pkg installer. The opt-in version detects this via `mas list` and skips those casks, but you'd never know to look for it otherwise.

Combined, the unconditional pre-flight cost the user ~15 minutes of password-babysitting and re-downloads to save ~3 minutes of bundle-install work. Hence: opt-in.

## When opting in IS worthwhile

`export CHEZMOI_BREW_ADOPT_PREFLIGHT=1` in `~/.shellrc.adhoc` if:

- You're setting up a new mac.
- You have just `chezmoi init`'d from a source machine and are about to first-apply.
- Most apps you've manually dragged into `/Applications/` happen to be the current brew-formula versions (rare in practice — vendor auto-updaters drift the .app forward faster than Brewfile gets refreshed).
- You can tolerate sitting at the terminal to feed `Password:` prompts.

Otherwise, leave it off. `brew bundle`'s normal download path is slower one-time but doesn't require babysitting, and once a cask is brew-tracked subsequent applies are fast.

## Workaround (manual, no script)

If you want to run adopt manually without enabling the env var:

```bash
# 1. Clear stale lockfiles from any interrupted prior fetch
rm -f ~/Library/Caches/Homebrew/downloads/*.incomplete*

# 2. Try adopting (slow + interactive — expect password prompts)
HOMEBREW_NO_AUTO_UPDATE=1 brew bundle list --casks --file=~/.config/homebrew/Brewfile.darwin | while IFS= read -r cask; do
    short="${cask##*/}"
    [[ -d /opt/homebrew/Caskroom/$short ]] && continue   # already tracked
    # Pre-filter: only try if /Applications/ has a likely match
    /bin/ls -1 /Applications | grep -iqE "^${short//-/[ -]?}.*\.app$" || continue
    brew install --cask --adopt "$cask" 2>&1 | head -2
done

# 3. Re-run brew bundle
HOMEBREW_NO_AUTO_UPDATE=1 brew bundle --file=~/.config/homebrew/Brewfile.darwin --no-upgrade
```

## Prevention

- `.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl` exports `HOMEBREW_NO_AUTO_UPDATE=1` + `HOMEBREW_NO_INSTALL_UPGRADE=1` to avoid the implicit `brew update` that can transiently fail on Aliyun mirror sync lag (`Unable to find <sha> under https://mirrors.aliyun.com/homebrew/brew.git`). Upgrades go through `just upgrade-*`, per `CLAUDE.md → "Install vs upgrade is split on purpose"`.
- The bundle retry loop calls `clear_brew_download_locks` between attempts to wipe any `*.incomplete*` files left over from a previous interrupted fetch. This is permanently on (not opt-in) — it's pure win, no downsides.
- The `adopt_existing_casks` pre-flight runs only when `CHEZMOI_BREW_ADOPT_PREFLIGHT=1` is set (see "Why opt-in" above). When enabled it also: (a) filesystem-pre-filters casks by `/Applications/*.app` presence so non-existent .apps don't trigger a download, (b) checks `mas list` to skip App Store conflicts, (c) captures brew's first stderr line on failure so you can see *why* an adopt failed.
- When adding a new cask to `dot_config/homebrew/Brewfile.darwin.tmpl`, don't pre-emptively delete any existing `/Applications/<Name>.app` — even if adopt won't help (version mismatch), the cask will install correctly on first apply.

## Related

- [`pitfalls/brew-cask-slow-github-release-assets.md`](brew-cask-slow-github-release-assets.md) — different root cause (Azure CDN slowness on CN networks) but overlapping observable shape (brew downloads slowly / fails). The adopt pre-flight helps here too, because it skips the download entirely when the `.app` is already present.
- [`pitfalls/ngrok-cask-download-flaky.md`](ngrok-cask-download-flaky.md) — another "brew cask download fails" pitfall.
- [`docs/this_repo/upgrades.md`](../docs/this_repo/upgrades.md) — adopt fires during `chezmoi apply` (install path), not `just upgrade-*` (upgrade path).
- [`.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl`](../.chezmoiscripts/global/run_onchange_after_30_brew_bundle.sh.tmpl) — where the fix lives.
- Upstream: [Homebrew/brew#14006](https://github.com/Homebrew/brew/issues/14006) (feature request), [Homebrew/brew#14033](https://github.com/Homebrew/brew/pull/14033) (PR adding `--adopt`).
- `AGENTS.md → "Install vs upgrade is split on purpose"` — explains why we don't `brew upgrade` during apply.
