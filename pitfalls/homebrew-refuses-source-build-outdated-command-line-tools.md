# `chezmoi apply` dies half-way: `Error: Your Command Line Tools are too outdated.` / `Error: No developer tools installed.`

**Symptoms** (grep this section):

- `chezmoi apply` ends with a partial ansible recap and a non-zero exit:
  ```
  localhost                  : ok=74   changed=9    unreachable=0    failed=1    skipped=665  rescued=0    ignored=1
  chezmoi: .chezmoiscripts/global/20_ansible_roles.sh: exit status 2
  ```
  The **failed task is not named in the summary** — only "Changed tasks" and
  "Slow tasks" are listed. The failing task is usually
  `coding_agents : Install peon-ping (macOS)` (it appears under *Slow tasks*
  but NOT under *Changed tasks*).
- Any `brew install` / `brew upgrade` of a **source-built** formula fails with
  one of:
  ```
  Error: Your Command Line Tools are too outdated.

  Update them from Software Update in System Settings.

  If that doesn't show you any updates, run:
    sudo rm -rf /Library/Developer/CommandLineTools
    sudo xcode-select --install
  ...
  You should download the Command Line Tools for Xcode 26.3.
  ```
  ```
  Error: No developer tools installed.

  Install the Command Line Tools:
    xcode-select --install
  ```
- Bottled formulae keep installing fine, so the machine looks healthy until a
  source-only formula (`peon-ping`, `specstory` upgrade, …) is reached.
- `xcode-select -p` →
  `xcode-select: error: Unable to get active developer directory. Use `sudo xcode-select --switch path/to/Xcode.app` to set one`
- `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` reports a version whose
  major is **behind the macOS major** (e.g. `version: 16.4.0.0.1.1747106510` on
  macOS 26.6.2).
- **Cascade**: roles ordered *after* the failing one in
  `dot_ansible/playbooks/macos.yml` never run at all, so unrelated things go
  stale/unconfigured in the same apply — e.g. `teamookla/speedtest` stays
  `Untrusted`, `networking_tools` packages stay missing, `iac_tools` /
  `python_uv_tools` / `js_cli_tools` are skipped entirely. Chasing those
  symptoms first is a **red herring**; they all disappear once the play stops
  aborting.

**First seen**: 2026-09 (Hanrus-Mac-mini, macOS 26.6.2, Homebrew 6.x, CLT 16.4)
**Affects**: any macOS host carried across a macOS major upgrade; Homebrew any
version that enforces a CLT minimum (all recent ones)
**Status**: fixed in repo — `homebrew` role now fails fast with a pre-flight
check (`homebrew_require_clt`, default `true`)

## Symptom

```
$ brew install peon-ping
==> Fetching downloads for: peon-ping
✔︎ Formula peon-ping (2.37.0)
==> Installing peon-ping from peonping/tap
Error: No developer tools installed.
```

Reproduction:

1. Install macOS N-1, let Homebrew's `install.sh` install the Command Line
   Tools for you.
2. Upgrade the machine to macOS N (e.g. 15 → 26). **CLT is not upgraded.**
3. `chezmoi apply` → dies at the first source-built formula, ~12 minutes in.

## Root cause

Homebrew requires the Command Line Tools to be **at or above a minimum version
tied to the running macOS**, and refuses to run *any* source build below it.
Two distinct states produce two distinct errors:

| State | Error | `xcode-select -p` |
|---|---|---|
| CLT absent | `Error: No developer tools installed.` | fails |
| CLT present but stale | `Error: Your Command Line Tools are too outdated.` | succeeds |

The trap is that **nothing refreshes CLT**:

- Homebrew's `install.sh` runs `softwareupdate -i` for CLT only when it is
  **absent**. On an upgraded machine CLT is present-but-stale, so the installer
  is a no-op.
- macOS's own Software Update does not push CLT updates as regular system
  updates; they sit in `softwareupdate --list` as separately-labelled items.
- This repo is **install-only by design** (see `AGENTS.md` → "Install vs upgrade
  is split on purpose"), so no ansible role touched CLT either.

The second half of the trap is the **blast radius**. `Install peon-ping (macOS)`
has no `ignore_errors`, so ansible aborts the play at that task and every role
after `coding_agents` in `dot_ansible/playbooks/macos.yml` silently never runs.
The recap's `ok=74 … skipped=665` looks like a normal heavily-gated run, which
hides the truncation.

Also note the interactive dead end in the error text itself: running
`sudo rm -rf /Library/Developer/CommandLineTools` **before** the
`xcode-select --install` succeeds leaves the machine with *no* developer tools
at all — the state flips from "too outdated" to "none installed", which is
strictly worse.

## Workaround

Headless (preferred — no GUI click, needs sudo):

```sh
sudo softwareupdate --install "$(softwareupdate --list 2>&1 \
  | sed -n 's/^ *\* Label: \(Command Line Tools.*\)$/\1/p' | tail -1)" --verbose
```

GUI (no sudo, but requires clicking the "Install" dialog — the dialog can open
**behind** other windows and the command returns immediately, so it looks like
nothing happened):

```sh
xcode-select --install
# bring the dialog to the front if you can't find it:
osascript -e 'tell application "System Events" to set frontmost of \
  (first process whose name contains "Install Command Line") to true'
```

Verify, then re-run:

```sh
xcode-select -p                 # -> /Library/Developer/CommandLineTools
pkgutil --pkg-info=com.apple.pkg.CLTools_Executables | grep version
chezmoi apply
```

## Prevention

`dot_ansible/roles/homebrew/tasks/main.yml` now runs a **pre-flight check**
before anything else in the play (the `homebrew` role is first in both
playbooks). It fails in ~1 s with the exact remediation commands instead of
~12 min into the apply on an unrelated formula:

- absent CLT (`xcode-select -p` non-zero) → fail
- stale CLT (CLT major `<` macOS major) → fail

The freshness heuristic is `CLT major >= macOS major`: Apple has shipped
CLT/Xcode majors at or above the macOS major for every release this repo
supports (macOS 14 → Xcode 15, 15 → 16, 26 → 26), so it never false-positives
on a supported host.

Escape hatch (bottle-only installs still work without current CLT):

```sh
ansible-playbook … -e homebrew_require_clt=false
```

The major version is extracted with `awk` + `${ver%%.*}` in the registering
shell task and compared via `set_fact`-free integer `when:` clauses — **never**
`regex_replace` inside `when:`, see
[`ansible-when-regex-replace-backslash-strip.md`](ansible-when-regex-replace-backslash-strip.md).

## Related

- Sibling pitfalls:
  [`homebrew-6-refuses-untrusted-tap-formula.md`](homebrew-6-refuses-untrusted-tap-formula.md)
  (the *other* reason a `brew install` aborts mid-play — same blast radius),
  [`ansible-homebrew-expecting-value-line-1-column-1.md`](ansible-homebrew-expecting-value-line-1-column-1.md)
- `AGENTS.md` → "Install vs upgrade is split on purpose" (why nothing
  auto-upgraded CLT)
- Homebrew tap trust docs: <https://docs.brew.sh/Tap-Trust>
