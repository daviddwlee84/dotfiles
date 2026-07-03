# Plan: `source-rc` / `reload` — re-source the current shell's rc in place

## Context

After `chezmoi apply` (or `cau`), long-lived shell sessions don't see new aliases/
functions until they re-source their rc. Today that means the user manually types
`source ~/.zshrc` or `source ~/.bashrc` — having to remember which entry-point file
their current shell uses, knowledge others may not have. The post-apply reload *hint*
in `dot_config/shell/99_chezmoi_reload.sh` already prints this suggestion, but there
is no single command that just does it.

Goal: a tiny, self-documenting, cross-shell command `source-rc` that auto-detects the
running interpreter and re-sources the correct rc **in place** (keeps cwd, history,
session state) — the lightweight counterpart to the existing `exec`-based `cas`/`cau`.
Also unify the short `reload` alias, which today exists **only in bash**
(`dot_config/bash/10_aliases.bash:12`, `alias reload='. ~/.bashrc'`) with no zsh
equivalent — make it cross-shell as a short alias for `source-rc`.

Decision (confirmed with user): **`source-rc` + unify `reload`**; semantics = in-place
`source` (not `exec`).

## Design notes / constraints

- **Shared tier**: lives in `dot_config/shell/10_aliases.sh` (sourced by both shells
  via `load_modular_dir`), next to sibling utilities `run-for` / `bindings` /
  `ghostty-ssh-terminfo`. No new numbered file (matches repo convention). No completion
  files needed (plain function/alias, not an `executable_*` CLI).
- **`function` keyword is mandatory, not `name()`**: `source-rc`'s job is to re-source,
  which re-parses `10_aliases.sh` on every call. The `function source-rc { … }` form is
  immune to the `ALIAS_FUNC_DEF` re-source `parse error near \`()'` documented in
  `pitfalls/zsh-parse-error-on-resource-after-bw-completion-aliased-name.md` (same reason
  the `*-update-completion` helpers in this file already use it). `function` keyword is
  fine here because only zsh/bash ever source this file (never dash).
- **Inline the shell dispatch — do NOT reuse `_chezmoi_reload_current_shell`**: that
  helper lives in `99_chezmoi_reload.sh`, which (a) loads *after* `10_aliases.sh` and
  (b) early-returns entirely when `CHEZMOI_RELOAD_HINT=0`, so depending on it would make
  `source-rc` break under that opt-out. The dispatch is 3 lines; inline it.
- **Detect via `$ZSH_VERSION`/`$BASH_VERSION`, never `$SHELL`** (repo convention — `$SHELL`
  lags `chsh` until next login).
- **Parity with manual `source ~/.zshrc`**: re-sourcing re-runs starship/mise/atuin/motd
  etc. and inherits the same zsh re-source caveats. This is identical to what the user
  does by hand today; `exec zsh -l` / `cas` remain the heavier "guaranteed-clean" path.
- **Indentation is TAB** in `10_aliases.sh` — match it exactly.

## Changes

### 1. `dot_config/shell/10_aliases.sh` (add function + alias)

Add a new section (near the `run-for` / `bindings` utility cluster, e.g. after the
`run-for` block ~line 91). Use TAB indentation:

```sh
# --- Reload shell config (source-rc / reload) ------------------------------
# Re-source the CURRENT shell's rc entry point in place, so a running session
# picks up new aliases/functions after `chezmoi apply` — without exec'ing a
# fresh login shell (that heavier path is `cas`/`cau` in 99_chezmoi_reload.sh).
# Dispatches on the live interpreter ($ZSH_VERSION/$BASH_VERSION), not $SHELL.
# `function` keyword (not `name()`) is deliberate: this re-parses 10_aliases.sh
# on every call, so it must be immune to the ALIAS_FUNC_DEF re-source parse
# error — see pitfalls/zsh-parse-error-on-resource-after-bw-completion-aliased-name.md.
function source-rc {
	if [ -n "${ZSH_VERSION:-}" ]; then
		_rc="$HOME/.zshrc"
	elif [ -n "${BASH_VERSION:-}" ]; then
		_rc="$HOME/.bashrc"
	else
		printf 'source-rc: unsupported shell (need zsh or bash)\n' >&2
		return 1
	fi
	if [ ! -f "$_rc" ]; then
		printf 'source-rc: %s not found (run chezmoi apply first?)\n' "$_rc" >&2
		unset _rc
		return 1
	fi
	printf 'source-rc: reloading %s\n' "$_rc"
	# shellcheck source=/dev/null
	. "$_rc"
	unset _rc
}
alias reload='source-rc'
```

Notes: re-sourcing only *redefines* `source-rc` (no recursion — it's never re-called).
`reload` as an alias is re-source-safe (no function-name collision).

### 2. `dot_config/bash/10_aliases.bash` (remove now-shared bash-only `reload`)

Replace lines 11–12 (`# Re-source bashrc… / alias reload='. ~/.bashrc'`) with a pointer
comment. The shared `dot_config/shell/10_aliases.sh` loads *after* this file for bash
(`load_modular_dir "$BASH_CONFIG_DIR" bash` at `dot_bashrc.tmpl:94` runs before the shared
`$XDG_CONFIG_HOME/shell` layer at :114), so the shared `alias reload='source-rc'` wins —
removing the bash-only line just avoids a confusing double definition:

```sh
# `reload` (re-source the current shell's rc) is now cross-shell — defined once
# in dot_config/shell/10_aliases.sh as `alias reload='source-rc'`, which loads
# after this file for bash, so the shared definition wins. See `source-rc` there.
```

### 3. `docs/shells/aliases.md` (mandatory mirror — CLAUDE.md rule)

Add two rows to the **Shell Utilities** section (`## Shell Utilities`, ~line 717), same
4-col table (`Command | Type | Source File | Description`):

```
| `source-rc` | function | `dot_config/shell/10_aliases.sh` | Re-source the current shell's rc (`~/.zshrc` or `~/.bashrc`, auto-detected via `$ZSH_VERSION`/`$BASH_VERSION`) in place — pick up new aliases/functions after `chezmoi apply` without a fresh login shell (lighter than `cas`/`cau`). |
| `reload` | alias | `dot_config/shell/10_aliases.sh` | Short alias for `source-rc`. Now cross-shell (was bash-only `. ~/.bashrc`). |
```

Also `grep -n 'reload' docs/shells/aliases.md`: if an existing bash-only `reload` row
exists elsewhere, update/relocate it to point at the new shared source (avoid a stale
`. ~/.bashrc` entry).

### 4. `docs/shells/aliases.zh-TW.md` (translated mirror)

Add the equivalent two rows to the matching Shell Utilities section, translated to match
the file's existing style. Same `grep` check for a stale `reload` row.

### (Optional, offer at implementation) `dot_config/shell/99_chezmoi_reload.sh`

Directly serves the user's discoverability motivation: update the post-apply hint
(lines 63–67) to name `source-rc` as the lightweight option, e.g.
`… run source-rc (or exec <sh> -l) to reload`. Small, but touches a load-bearing file —
will confirm before doing it; not part of the core change.

## Verification

1. **Syntax** (file is non-templated, source == target):
   - `zsh -n dot_config/shell/10_aliases.sh`
   - `bash -n dot_config/shell/10_aliases.sh`
   - `bash -n dot_config/bash/10_aliases.bash`
2. **Deploy**: `chezmoi diff` then `chezmoi apply` (or test against the source file
   directly in a scratch shell).
3. **Functional, zsh** — open a fresh `zsh`, then:
   - add a throwaway alias to `~/.zshrc.adhoc` (e.g. `alias _srtest=echo`), run `source-rc`,
     confirm it prints `reloading ~/.zshrc`, exits 0, and `alias _srtest` now resolves.
   - run `reload` and confirm identical behavior.
   - run `source-rc` twice in the same session and confirm **no** `parse error near \`()'`.
4. **Functional, bash** — repeat in a fresh `bash` with `~/.bashrc.adhoc`; confirm it
   re-sources `~/.bashrc` and that `reload` resolves to `source-rc` (`type reload`).
5. **Edge branches**: confirm the missing-rc message path (`_rc` guard) and the
   unsupported-shell path read correctly (reason/inspect; the else branch only reachable
   outside zsh/bash, which never source this file).
6. **Docs**: `uv run mkdocs build --strict` passes.
7. **Lint**: run repo pre-commit on the changed files (`pre-commit run --files
   dot_config/shell/10_aliases.sh dot_config/bash/10_aliases.bash docs/shells/aliases.md
   docs/shells/aliases.zh-TW.md`) — expect shfmt/formatting + any redaction hooks to pass.
