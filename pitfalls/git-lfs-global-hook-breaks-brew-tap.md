# `brew tap` / `brew bundle` clone dies: git-lfs hook `exit 2` via global `core.hooksPath`

<!-- Symptom = a brew tap's git clone fails ("git-lfs was not found on your
     path", clone "exited with 2") and a cask in that tap goes "unavailable";
     root cause = a stock git-lfs hook in the GLOBAL core.hooksPath exits 2 under
     Homebrew's stripped superenv PATH. Grep terms: "git-lfs was not found on
     your path", "exited with 2", "Tapping ... has failed", "core.hookspath",
     "Cask is unavailable", "post-checkout". -->

**Symptoms** (grep this section):

- `chezmoi apply` / `brew bundle` fails to tap a third-party tap on macOS:
  ```
  Tapping wxtsky/tap
  ==> Tapping wxtsky/tap
  Cloning into '/usr/local/Homebrew/Library/Taps/wxtsky/homebrew-tap'...

  This repository is configured for Git LFS but 'git-lfs' was not found on your path. If you no longer wish to use Git LFS, remove this hook by deleting the 'post-checkout' file in the hooks directory (set by 'core.hookspath'; usually '.git/hooks').

  Error: Failure while executing; `git clone https://github.com/wxtsky/homebrew-tap /usr/local/Homebrew/Library/Taps/wxtsky/homebrew-tap --origin=origin --template= --config core.fsmonitor=false` exited with 2.
  Tapping wxtsky/tap has failed!
  ```
- A cask that lives in the failed tap then reports unavailable — a **cascade**,
  not an independent failure:
  ```
  Installing codeisland
  Warning: Cask 'codeisland' is unavailable: No Cask with this name exists.
  ==> Searching for similarly named casks...
  ==> Casks
  codeql
  Installing codeisland has failed!
  ```
  ```
  `brew bundle` failed! 2 Brewfile dependencies failed to install
  ```
- `git-lfs` **is** actually installed — `command -v git-lfs` →
  `/usr/local/bin/git-lfs`, `brew list --versions git-lfs` → `git-lfs 3.7.1`.
  So "not found on your path" is misleading: it is found in an interactive
  shell, just not inside the hook's execution environment.
- The error is reproducible by checking out **any** repo under a stripped PATH:
  ```
  $ env -i PATH=/usr/bin:/bin HOME="$HOME" sh ~/.config/git/hooks/post-checkout 0 0 1
  This repository is configured for Git LFS but 'git-lfs' was not found on your path. ...
  $ echo $?
  2
  ```
- Only a **fresh** tap trips it. Taps already on disk
  (`hashicorp/tap`, `teamookla/speedtest`, `dlvhdr/formulae`, `raine/workmux`)
  install fine because no `git clone` (hence no `post-checkout` hook) runs.

**First seen**: 2026-06 on `Hanrus-MacBook-Pro` (Intel, macOS 26.3.1) during
`chezmoi apply` → `brew bundle` of `Brewfile.darwin`, tapping `wxtsky/tap` for
the `codeisland` cask for the first time.
**Affects**: any macOS host where (a) `~/.gitconfig` sets a **global**
`core.hooksPath` (this repo points it at `~/.config/git/hooks` so the managed
global `pre-commit` hook runs everywhere), AND (b) `git lfs install` has written
its stock hooks into that same dir. Both Intel (`/usr/local/bin`) and Apple
Silicon (`/opt/homebrew/bin`) — Homebrew's clone superenv excludes both from the
hook's PATH in some contexts.
**Status**: fixed — the four git-lfs hooks are now chezmoi-managed
(`dot_config/git/hooks/executable_{post-checkout,post-commit,post-merge,pre-push}`)
and made PATH-robust + non-fatal.

## Root cause

Two independent facts collide:

1. **The hooks dir is global.** `modify_dot_gitconfig.tmpl` sets
   `core.hooksPath = ~/.config/git/hooks` so the repo's managed `pre-commit`
   hook (gitleaks / `pre-commit`) applies to *every* repo. A consequence: every
   `git clone` / `git checkout` — including the ones Homebrew runs to tap a
   formula/cask repo — fires the hooks in that dir.
2. **`git lfs install` dropped its stock hooks there.** Those hooks are *not*
   defensive. The stock `post-checkout` is:
   ```sh
   #!/bin/sh
   command -v git-lfs >/dev/null 2>&1 || { printf >&2 "\n%s\n\n" "This repository is configured for Git LFS but 'git-lfs' was not found on your path. ..."; exit 2; }
   git lfs post-checkout "$@"
   ```
   When `git-lfs` is not on PATH it prints the message and **`exit 2`**.

Homebrew clones taps in its **superenv** — a sanitized environment whose PATH
does **not** include `/usr/local/bin` (or `/opt/homebrew/bin`). Inside that
clone, `command -v git-lfs` fails → the hook `exit 2`s → `git clone` exits 2 →
`brew tap` fails → the cask in that tap is "unavailable" (the cascade).

Contrast with the repo's own `pre-commit` hook, which is deliberately lenient
(`command -v pre-commit >/dev/null 2>&1 || skip`, `command -v gitleaks || skip`).
The git-lfs hooks were the only un-lenient co-tenants in the global dir.

## Workaround

**The durable fix (already in the repo):** the four git-lfs hooks are now
managed and made (1) PATH-robust and (2) non-fatal — mirroring the lenient
`pre-commit` hook:

```sh
#!/usr/bin/env sh
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin"; export PATH
command -v git-lfs >/dev/null 2>&1 || exit 0   # was: exit 2 (+ scary message)
git lfs post-checkout "$@"
```

- Augmenting PATH makes git-lfs visible even inside Homebrew's stripped clone
  env, so LFS still works.
- `exit 0` (not `2`) on a genuinely-absent git-lfs means a missing optional tool
  can never abort an unrelated clone/checkout again.

Apply + verify the actual failing operation (not just syntax):

```sh
chezmoi apply ~/.config/git/hooks/post-checkout ~/.config/git/hooks/post-commit \
              ~/.config/git/hooks/post-merge   ~/.config/git/hooks/pre-push
brew tap wxtsky/tap          # -> Tapped 1 cask ...   (rc 0)
brew install --cask codeisland
```

**Manual unblock without the managed fix** (one-off): either install git-lfs so
the stock hook is satisfied, or temporarily bypass the hooks for the tap:

```sh
git -c core.hooksPath=/dev/null clone <tap-url>   # or: brew tap ... after `git lfs uninstall`
```

Do **not** "fix" this by deleting the global `core.hooksPath` — that silently
disables the managed gitleaks/`pre-commit` security hook on every repo.

## Prevention

- **A hook in a *global* `core.hooksPath` must be defensive.** It runs for every
  repo, including tooling clones (Homebrew taps, IDE clones, CI). Any
  `command -v <tool> || exit <nonzero>` in such a hook is a landmine — make it
  `|| exit 0` (skip), exactly like the managed `pre-commit` hook does.
- **Don't assume the hook's PATH equals your shell's PATH.** Homebrew's superenv,
  cron, `git` subprocesses, and GUI apps all run with reduced PATHs. Hooks that
  need a brew-installed binary should prepend the brew prefixes themselves.
- When you adopt a *global* hooks dir, audit what else writes into it.
  `git lfs install` will silently add four hooks there; treat them as files you
  now own and must keep lenient.
- A failed `brew tap` makes every cask/formula in that tap report
  "unavailable / No Cask with this name exists" — chase the **tap** error first,
  not the cask name.

## Related

- The cask this unblocked: [`codeisland-auto-approves-permissionrequest.md`](codeisland-auto-approves-permissionrequest.md)
  — same app (CodeIsland), a different gotcha once it's installed.
- Sibling "`chezmoi apply` dies in a Homebrew step" traps:
  [`homebrew-6-refuses-untrusted-tap-formula.md`](homebrew-6-refuses-untrusted-tap-formula.md)
  (untrusted-tap gate) and
  [`ollama-brew-link-fails-cask-shadows-formula.md`](ollama-brew-link-fails-cask-shadows-formula.md)
  (cask shim vs formula link collision).
- Source of the fix: `dot_config/git/hooks/executable_{post-checkout,post-commit,post-merge,pre-push}`
  (managed git-lfs hooks); the global hooks dir is set by `modify_dot_gitconfig.tmpl`
  (`core.hooksPath`) and shared with the managed `dot_config/git/hooks/executable_pre-commit.tmpl`.
