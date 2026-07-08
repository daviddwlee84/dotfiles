# GitHub CLI (`gh`) auth

[`gh`](https://cli.github.com/) is the official GitHub CLI. This repo installs it via the `devtools` ansible role and uses it for issue/PR workflows, the `gh-dash` extension, and (most importantly for this page) **as the credential helper for `git push`/`git fetch` over HTTPS**.

Two things on this page:

1. How to authenticate `gh` so HTTPS git operations work without typing a token.
2. **How this repo's chezmoi-managed `~/.gitconfig` coexists with `gh auth setup-git`** — important if you're new to the dotfiles, because there's a non-obvious modify_ script involved.

## Quick auth

```bash
# Interactive: pick https + "Login with a web browser"
gh auth login

# When asked "Authenticate Git with your GitHub credentials?", answer Yes.
# That runs `gh auth setup-git` for you, which writes the credential helper
# into ~/.gitconfig (see next section).
```

To verify:

```bash
gh auth status                  # token scopes + which account
git config --get-all credential."https://github.com".helper
# Expected:
#   (empty line)
#   !/opt/homebrew/bin/gh auth git-credential   ← path varies per machine
```

To re-run just the git-credential setup without re-logging in:

```bash
gh auth setup-git
```

To remove:

```bash
gh auth logout                  # clears token + helper
```

## How `gh auth setup-git` interacts with chezmoi

`gh auth setup-git` writes two sections into `~/.gitconfig`:

```gitconfig
[credential "https://github.com"]
	helper =
	helper = !/opt/homebrew/bin/gh auth git-credential
[credential "https://gist.github.com"]
	helper =
	helper = !/opt/homebrew/bin/gh auth git-credential
```

Two non-obvious things about that block:

1. **The empty `helper =` line is intentional**, not a bug. It resets any inherited helper (e.g. macOS Keychain's `osxkeychain`) for `github.com` so `gh` is the only authority. Without it, the OS keychain helper would race with `gh` and you'd see "Bad credentials" errors after rotating tokens.
2. **The path to `gh` is absolute and machine-specific**:
   - Apple Silicon homebrew: `/opt/homebrew/bin/gh`
   - Intel mac homebrew: `/usr/local/bin/gh`
   - Linuxbrew: `/home/linuxbrew/.linuxbrew/bin/gh`
   - apt / dnf / official `.deb`: `/usr/bin/gh`

The path is hard-coded by `gh` at the moment you run `gh auth setup-git` on that machine. There is no portable form (it intentionally bypasses `PATH` so `git` doesn't pick up a different `gh` binary later).

### Why a plain `~/.gitconfig` template would break this

If `~/.gitconfig` were a normal chezmoi template, every `chezmoi apply` would overwrite the entire file — including the `[credential "..."]` blocks that `gh` just wrote. The next `git push` would either:

- Fail with no helper → re-prompt for credentials interactively, or
- Ping-pong: you'd run `gh auth setup-git` again, and the next `chezmoi apply` would clobber it again.

This is exactly the "out-of-band tool rewrites a managed file" problem that chezmoi's `modify_` prefix exists to solve.

### What this repo actually does

`~/.gitconfig` is managed by [`modify_dot_gitconfig.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/modify_dot_gitconfig.tmpl), a `modify_`-prefixed bash script that runs on every `chezmoi apply`. The script:

1. Reads the current `~/.gitconfig` from stdin (chezmoi's `modify_` contract).
2. Emits the chezmoi-managed baseline — `[user]`, `[http]`, `[filter "lfs"]`, `[init]`, `[core]`, optional `[delta]` blocks, and `[include] path = ~/.gitconfig.local`.
3. Re-emits any `[credential "<URL>"]` sections found in the live file **verbatim**, including the gh-injected absolute path.

Net effect: you can run `gh auth setup-git` once per machine, and `chezmoi apply` will preserve the helper forever after — no ping-pong, no per-machine template branching, no need to commit machine-specific paths.

The `modify_` prefix is documented at [chezmoi prefixes](chezmoi-prefixes.md). The case study for this specific file is mentioned in the same place.

## Three places per-machine git config can live

| Place | Managed by | When to use |
|---|---|---|
| chezmoi baseline (`modify_dot_gitconfig.tmpl`) | This repo | Settings shared across all your machines (`user.email`, `init.defaultBranch`, `core.pager = delta`, …). Edit the template and `chezmoi apply`. |
| `[credential "<URL>"]` in `~/.gitconfig` | `gh auth setup-git` | HTTPS auth via gh. Run `gh auth login` once per machine; chezmoi preserves it. **Don't hand-edit these blocks** — let gh own them. |
| `~/.gitconfig.local` | You, by hand | Per-machine overrides chezmoi can't predict: `http.proxy`, `safe.directory`, work-account email overrides, `[includeIf "gitdir:..."]` for separate identities, `[url "..."]` rewrites for a corporate mirror, etc. Loaded via `[include]` from the baseline. Git-ignored by chezmoi. |

The three layers compose left-to-right (later wins for the same key), which mirrors the `~/.zshrc` → `~/.zshrc.local` → `~/.zshrc.adhoc` pattern used elsewhere in this repo.

## What is NOT preserved by the modify_ script

The awk filter inside `modify_dot_gitconfig.tmpl` matches **only** `^[credential "<URL>"]` (with a quoted URL scope). Anything else in the live `~/.gitconfig` is replaced by the baseline on the next apply. In particular:

- A bare `[credential]` (no URL scope) is **not** preserved.
- `[user]`, `[core]`, `[alias]`, etc. that you hand-edited into `~/.gitconfig` are **silently overwritten**. Use `~/.gitconfig.local` for those.
- `[credential.helper]` style flat keys (no section header) are **not** preserved. Stick to the URL-scoped section form, which is what `gh auth setup-git` writes.

If you need to preserve another section type (e.g. `[includeIf "gitdir:~/work/"]` written by some other tool), the awk rule is the single place to extend — see the script for the pattern.

## Troubleshooting

**`fatal: could not read Username for 'https://github.com': terminal prompts disabled`** in CI / non-interactive shell after `chezmoi apply`:

- Check the credential block survived: `git config --get-all credential."https://github.com".helper` should show two lines (empty + `!.../gh auth git-credential`).
- If the second line is missing, `gh auth setup-git` was never run on this machine. Run `gh auth login` (or `gh auth setup-git` if a token is already stored).
- If both lines were there but git still prompts, `gh` itself may be unauthenticated: `gh auth status` should print a green check, not "not logged in".

**`gh auth status` prints token but `git push` still prompts**:

- The absolute path in the helper line points to a `gh` binary that no longer exists (you migrated mac → mac via Migration Assistant, or rebuilt Linuxbrew). Re-run `gh auth setup-git` to refresh the path; chezmoi will preserve the new one.

**`chezmoi diff ~/.gitconfig` shows churn after every `gh` operation**:

- Expected to be empty. If it isn't, the awk filter probably doesn't recognise the section header gh wrote (older or newer `gh` versions might use a different scope URL). Open the live file and the rendered output side by side: `chezmoi cat ~/.gitconfig | diff - ~/.gitconfig`. If the diff is in a `[credential "<URL>"]` block, the script has a bug — file an issue.

## Finding & cloning your repos

`gh repo list` is non-interactive and stops at 30 rows. To fuzzy-browse **all** your repos by name + description — preview the README, then clone / open / copy — this repo ships a picker in two twinned surfaces:

- **`ghrepo`** (shell function, `dot_config/shell/41_github.sh`) — fzf over `gh repo list --limit 4000` with a `gh repo view` README preview:
  - `Enter` → clone into `${GHREPO_ROOT:-$PWD}/<repo>` and **`cd` into it**
  - `Alt-O` → open on github.com · `Ctrl-Y` → copy the repo URL
- **`tv github-repos`** (Television channel) — same browse / open / copy. A tv action can't `cd` your shell (subprocess), so `Alt+C` clones into the launch cwd without cd; use `ghrepo` for the clone-and-work flow.

GitLab has the exact twins — **`glrepo`** + **`tv gitlab-repos`** (via `glab repo list --mine`). Self-hosted GitLab: `export GITLAB_HOST=git.example.com`.

Set `GHREPO_ROOT` / `GLREPO_ROOT` to clone into a fixed repo root instead of the current dir — handy for pairing with [try-cli](https://github.com/tobi/try)'s graduate flow (`TRY_PROJECTS`). See also [tv.md → github-repos / gitlab-repos channels](tv.md#github-repos--gitlab-repos-channels).

## Related

- [chezmoi prefixes](chezmoi-prefixes.md) — `modify_` / `create_` / `_remove` semantics in this repo
- [Agent overlays](agent-overlays.md) — the same modify_ pattern applied to Claude / OpenCode / Codex / Cursor configs
- [git diff workflow](git_diff_workflow.md) — how this repo uses `gh pr diff`, delta, `gh-dash`, etc.
