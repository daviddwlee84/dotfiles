# `specstory run codex` → `codex execution failed: signal: killed`, while `chezmoi apply` insists Codex is fine

**Symptoms** (grep this section):

- ```
  ERROR
  Codex CLI execution failed: codex execution failed: signal: killed.
  ```
- `codex --version` → `zsh: command not found: codex`, **or**
  `no such file or directory: /opt/homebrew/bin/codex` when invoked by
  absolute path (the two different shells report the same broken symlink
  differently — `command not found` from PATH lookup, `no such file` from
  direct exec).
- `ls -la /opt/homebrew/bin/codex` shows a symlink that *looks* fine:
  ```
  /opt/homebrew/bin/codex -> /opt/homebrew/Caskroom/codex/0.130.0/codex-aarch64-apple-darwin
  ```
  but `test -e /opt/homebrew/bin/codex` fails and
  `ls -la /opt/homebrew/Caskroom/codex/0.130.0/` is **empty**.
- `brew list --cask codex` still exits `0` and prints the `.metadata` receipt
  files.
- `chezmoi apply` reports
  `coding_agents : Verify OpenAI Codex CLI binary is available from Homebrew path (macOS)` as **`ok`**, run after run, and the install task stays skipped.
- Other agent wrappers fail the same way for the same reason — anything that
  `exec`s `codex`.

**First seen**: 2026-09 (Hanrus-Mac-mini, macOS 26.6.2, Homebrew 6.x, codex cask
0.130.0 → 0.151.0)
**Affects**: any Homebrew **cask** that ships a linked binary, on any host where
`brew cleanup` has run
**Status**: fixed in repo — `follow: true` on the stat + an explicit
`brew reinstall --cask` repair task

## Symptom

```
$ specstory run codex
   ERROR
  Codex CLI execution failed: codex execution failed: signal: killed.

$ /opt/homebrew/bin/codex --version
zsh: no such file or directory: /opt/homebrew/bin/codex

$ ls -la /opt/homebrew/Caskroom/codex/0.130.0/
# (empty)

$ brew list --cask codex
/opt/homebrew/Caskroom/codex/.metadata/INSTALL_RECEIPT.json
/opt/homebrew/Caskroom/codex/.metadata/config.json
/opt/homebrew/Caskroom/codex/.metadata/0.130.0/…/Casks/codex.json
```

Note the misleading error: `signal: killed` sounds like an OOM kill or a
Gatekeeper rejection. It is neither — the wrapper's exec of a broken symlink
surfaces as a kill signal rather than ENOENT.

## Root cause

Two independent traps that compound into "silently broken, reported healthy".

**1. `brew cleanup` prunes a stale cask version without unlinking.** When a cask
version is superseded, `brew cleanup` deletes the payload under
`Caskroom/<cask>/<version>/` but leaves both the `.metadata` **receipt** and the
`$(brew --prefix)/bin/<name>` **symlink** in place. The receipt is what
`brew list --cask codex` reports on, so the presence check passes and the
install task is skipped forever. (This repo runs `brew cleanup` from the
`homebrew` role on a 24 h window, so it happens unattended.)

**2. `ansible.builtin.stat` defaults to `follow: false`.** With `follow: false`
the module `lstat`s the path, and a **dangling symlink reports
`stat.exists: true`**. So the guard

```yaml
- ansible.builtin.stat:
    path: "{{ prefix }}/bin/codex"
  register: codex_macos_bin_stat
  failed_when: not codex_macos_bin_stat.stat.exists
```

happily validated a link pointing at nothing.

Generalisable: **`stat` + `failed_when: not …stat.exists` is not a health check
for anything that can be a symlink.** It answers "is there a directory entry
here", not "does this resolve to a usable file".

## Workaround

```sh
brew reinstall --cask codex
codex --version          # -> codex-cli 0.151.0
```

Find other casks in the same state:

```sh
for l in "$(brew --prefix)"/bin/*; do [ -e "$l" ] || echo "DANGLING: $l"; done
```

## Prevention

`dot_ansible/roles/coding_agents/tasks/main.yml` now:

- stats with `follow: true`, so a broken link is correctly "missing";
- runs `brew reinstall --cask codex` when it is missing (rather than only
  failing), because `homebrew_cask: state=present` is a **no-op** while the
  receipt is intact;
- re-stats afterwards and keeps the original hard `failed_when` for the case
  where the reinstall genuinely could not fix it.

**Convention**: when verifying a binary that Homebrew (or anything else)
provides via a symlink, use `stat: follow: true`, or test with
`ansible.builtin.command: <bin> --version` — never a bare `stat`.

## Related

- Sibling pitfall:
  [`homebrew-refuses-source-build-outdated-command-line-tools.md`](homebrew-refuses-source-build-outdated-command-line-tools.md)
  (the other reason the `coding_agents` role misreports agent health)
- `AGENTS.md` → "Install vs upgrade is split on purpose" — `brew cleanup` runs
  from the `homebrew` role, so this can appear with no user action at all
- `docs/tools/agent-overlays.md`
