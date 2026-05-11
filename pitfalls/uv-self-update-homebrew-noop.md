# `uv self update` is a silent no-op when uv is Homebrew-installed

**Symptoms** (grep this section):

- `just upgrade-tools uv` (or `scripts/upgrade_tools.sh uv`) prints "uv is
  already on version vX.Y.Z" but `uv --version` is months out of date and
  doesn't move:
  ```
  $ uv --version
  uv 0.10.2 (Homebrew 2026-02-10)
  $ just upgrade-tools uv
  [INFO] Updating uv itself
  + uv self update
  warning: self-update is disabled for this build of uv
  $ uv --version
  uv 0.10.2 (Homebrew 2026-02-10)   ← unchanged
  ```
- Or, the actual error from a brew-installed uv is one of (varies by uv
  version):
  ```
  warning: self-update is disabled for this build of uv
  error: self-update is not available for this installation of uv
  error: uv was installed via Homebrew; use `brew upgrade uv` instead
  ```
- A subsequent `chezmoi apply` then fails the
  `python_uv_tools` role's "Fail if uv is too old after auto-upgrade
  attempt" task because the auto-upgrade dispatched to the wrong channel.
- Mixed-fleet symptom: the same `just upgrade-tools uv` works fine on the
  Linux box (curl-installed uv self-updates cleanly) and silently
  no-ops on the Mac (Homebrew uv).
- `uv --version` includes the literal substring `(Homebrew YYYY-MM-DD)`
  whereas curl-installer uv prints `(<commit-sha> <date> <triple>)`.
  That's the cheapest distinguishing signal.

**First seen**: 2026-05 across the user's three-machine fleet (Hanrus
Mac mini with curl-installed uv 0.7.4, "Other Mac" with Homebrew
uv 0.10.2, Ubuntu with curl-installed uv 0.7.18). The Homebrew Mac was
silently stale because `cat_uv()` in `scripts/upgrade_tools.sh`
demoted the brew failure to a warning and never fell back to
`brew upgrade uv`.
**Affects**: any host where uv was installed via `brew install uv`
(macOS Homebrew or Linuxbrew) and the user expects `uv self update` /
`just upgrade-tools uv` to keep it current.
**Status**: fixed in
`scripts/upgrade_tools.sh::cat_uv()` and mirrored in
`dot_ansible/roles/python_uv_tools/tasks/main.yml` (see
`docs/this_repo/uv-bootstrap.md` for the dispatch matrix).

## Why uv refuses to self-update on brew

Astral builds two flavours of the `uv` binary:

| Flavour | Where it ships from | `self update` allowed? |
|---|---|---|
| Standalone (curl `astral.sh/uv/install.sh`) | Astral's GitHub releases, drops to `~/.local/bin/uv` | **Yes** |
| Distribution-managed (Homebrew, Linuxbrew, Arch, Conda, etc.) | The distro's package manager owns the binary path | **No** — refuses with `self-update disabled` |

The reasoning is that the package manager owns the version (so it can
roll the whole formula's bottle, dependencies, and signing) and uv
self-replacing the binary would break that contract. This is documented
at <https://docs.astral.sh/uv/getting-started/installation/#standalone-installer>
and similar caveats live in `uv self update --help`.

This repo never invokes `brew install uv` itself — the bootstrap path
in `run_once_before_00_bootstrap.sh.tmpl` always uses the curl
installer. But users frequently run `brew install uv` manually
(it's a Homebrew core formula and a popular install method), and once
they do, the curl-installer guard `command -v uv` short-circuits, so the
brew-managed binary stays.

## How this repo handles the dispatch (now)

Two surfaces need to do the same dispatch and now share a helper
function `_uv_install_style` (bash version in `scripts/upgrade_tools.sh`,
ansible version inlined in
`dot_ansible/roles/python_uv_tools/tasks/main.yml`):

```sh
_uv_install_style() {
  local p; p="$(command -v uv)"
  case "$p" in
    */homebrew/*|*/Cellar/*|*/linuxbrew/*) echo brew ;;
    /usr/local/bin/uv)
      # Intel-mac brew shares /usr/local/bin with curl installer — ask brew
      brew list --formula uv >/dev/null 2>&1 && echo brew || echo curl ;;
    "$HOME"/.local/bin/uv|"$HOME"/.cargo/bin/uv) echo curl ;;
    *)
      brew list --formula uv >/dev/null 2>&1 && echo brew || echo curl ;;
  esac
}
```

Then:

| Detected style | Upgrade command |
|---|---|
| `brew` | `brew upgrade uv` (or `community.general.homebrew name=uv state=latest` in ansible) |
| `curl` | `uv self update` |

The `python_uv_tools` ansible role runs the dispatch automatically when
the host's uv is below the role's minimum (`0.8.5` for the
`--with-executables-from` flag — see
[`docs/this_repo/uv-bootstrap.md`](../docs/this_repo/uv-bootstrap.md)),
so a plain `chezmoi apply` is sufficient on most hosts. `just
upgrade-tools uv` does the same dispatch for the explicit refresh path.

## Workarounds for older versions of this repo (or other repos)

If you're on a version of `cat_uv()` that pre-dates the dispatch fix,
the manual sequence is:

```sh
# macOS Homebrew or Linuxbrew
brew upgrade uv

# curl/standalone
uv self update

# When unsure, the cheapest test:
case "$(command -v uv)" in
  */homebrew/*|*/Cellar/*|*/linuxbrew/*) brew upgrade uv ;;
  *) uv self update ;;
esac
```

## Why we don't unify on `brew install uv` for macOS

It would simplify the upgrade story (always `brew upgrade uv`), but:

1. Bootstrap on a fresh Mac would now require Homebrew first — the curl
   installer needs nothing but `curl`, which makes the chicken-and-egg
   cycle for the rest of `bootstrap.sh` (which uses `uv tool install
   ansible-core`) much faster.
2. CentOS / RHEL / non-brew Linux fleets would still need the curl path,
   so we'd have two install styles regardless.
3. Homebrew uv lags Astral's stable release by a few days to a week
   (formula maintainer cycle); some flags ship in standalone uv first
   (e.g. `--with-executables-from` was on standalone uv 0.8.5 a few
   days before the brew formula bumped).

So we keep both styles supported and dispatch at upgrade time.

## Related

- [`docs/this_repo/uv-bootstrap.md`](../docs/this_repo/uv-bootstrap.md) —
  full bootstrap + upgrade matrix per platform.
- [`docs/this_repo/upgrades.md`](../docs/this_repo/upgrades.md) —
  install-vs-upgrade split rationale; uv is one of the categories
  `cat_uv()` handles.
- [`pitfalls/ansible-when-regex-replace-backslash-strip.md`](ansible-when-regex-replace-backslash-strip.md)
  — companion pitfall from the same debugging session (the version
  assertion that gates the auto-upgrade dispatch had its own bug).
