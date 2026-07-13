# Port `try` (try-cli) to bash

**Status**: deferred (P2, low priority — bash used less on managed hosts)
**Effort**: S
**Related**: `TODO.md` P2 (B-class zsh→shared migration) · `dot_config/zsh/tools/32_try.zsh` · `dot_config/zsh/10_aliases.zsh` (`try-update-completion`) · target `dot_config/shell/` · docs `docs/shells/aliases.md` (+ `.zh-TW`), `docs/zsh/zsh-completions.md`

## Context

2026-07-13 — user asked "是不是也在 bash 能使用 try?". Confirmed technically
feasible and de-risked (see Investigation), but deferred because bash is the
non-primary shell on these hosts. Today `try` only loads in zsh: its config
lives in `dot_config/zsh/tools/32_try.zsh`, which only zsh sources per the
three-tier rule — bash never gets the `try()` function.

## Investigation

**The one open question in the old TODO note is now answered: `try.rb init`
output is pure POSIX and bash-safe.** Verified against **try-cli 1.7.1** at
`.../gems/try-cli-1.7.1/try.rb`:

- `cmd_init!` (lines 1003–1026) emits only two variants — `bash_or_zsh_script`
  and `fish_script`. **bash and zsh receive the *identical* script.**
- Shell selection is `fish?` (lines 1198–1205): `$SHELL` first, else parent
  process name. Only `fish` diverges; everything non-fish gets the bash/zsh
  form.
- That form contains **no `bindkey` / ZLE / zsh-ism** — just a POSIX function:

  ```sh
  try() {
    local out
    out=$(/usr/bin/env ruby '.../try.rb' exec --path '.../src/tries' "$@" 2>/dev/tty)
    if [ $? -eq 0 ]; then
      eval "$out"
    else
      echo "$out"
    fi
  }
  ```

Conclusion: **one cache serves both shells, no `[ -n "$ZSH_VERSION" ]` gate
needed.** (Re-verify the fish-vs-bash/zsh split still holds if try-cli is
upgraded past 1.7.1.)

The only real blockers are three zsh-only string modifiers in `32_try.zsh`:

| zsh (won't parse in bash) | POSIX replacement |
|---|---|
| `${TRY_PATH:A}` (resolve abs path) | `cd "$TRY_PATH" 2>/dev/null && pwd` |
| `${TRY_PATH:h}` (dirname) | `dirname "$TRY_PATH"` |
| `${_try_cache:h}` (dirname) | `dirname "$_try_cache"` |

`try-sesh` / `tsesh` are already portable. `[[ … -nt … ]]` is fine (both bash
and zsh support it, and shared files run only in those two).

`try-update-completion` (`dot_config/zsh/10_aliases.zsh:24`) is also zsh-only
(`${_cache:h}` + `function name {}`) and must move too, or bash users can't
refresh the cache after a gem-only upgrade.

## Migration recipe (when picked up)

1. `dot_config/zsh/tools/32_try.zsh` → `dot_config/shell/32_try.sh`; swap the 3
   modifiers above for their POSIX forms.
2. Extract the ruby-locate + `ruby try.rb init > cache` regen into one shared
   helper called by **both** the startup mtime-check path and
   `try-update-completion` (kills the duplicated locate snippet across the two
   current files).
3. Move `try-update-completion` into the shared layer, POSIX-ified.
4. Docs: flip scope `zsh` → `both` for the `try*`/`tsesh` rows in
   `docs/shells/aliases.md` + `.zh-TW`; update `docs/zsh/zsh-completions.md`
   cached-eval rows; tick the `32_try.zsh` sub-item in `TODO.md`.
5. Verify: `bash -i -c 'type try try-sesh; try-update-completion'`.

## Options considered

| Decision point | Options | Lean |
|---|---|---|
| Cache path | keep `~/.cache/zsh/try_init.zsh` (misleading — no longer zsh-only, lives in zsh dir) vs rename to shell-neutral `~/.cache/shell/try_init.sh` | rename; old file is orphaned harmlessly and auto-regens |
| fish edge case | user with `$SHELL=fish` running bash/zsh interactively would cache the fish function | ignore — already true of the current zsh setup, unrealistic here |

## Decision

2026-07-13 — **deferred**. Feasibility confirmed, no unknowns remain; parked as
low-priority because bash is secondary. Pick up alongside the rest of the
B-class zsh→shared migration (`TODO.md` P2).
