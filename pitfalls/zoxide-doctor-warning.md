# zoxide prints "detected a possible configuration issue" warning on every shell / script invocation

**Symptoms** (grep this section): `zoxide: detected a possible configuration issue.`, `Please ensure that zoxide is initialized right at the end of your shell configuration file (usually ~/.zshrc).`, `Disable this message by setting _ZO_DOCTOR=0.`, coding-agent bash tool output mixes the warning with unrelated `Exit code 2` from a build script, every other line of `chezmoi apply` stderr is the same 6-line zoxide warning, agents start prefixing `_ZO_DOCTOR=0 chezmoi apply ...` defensively in every command.

**First seen**: 2026-04 (recurring across many SpecStory sessions; ~140 `_ZO_DOCTOR=0` workaround prefixes accumulated in `.specstory/history/` before being root-caused)
**Affects**: zoxide ≥ 0.9 (when the doctor heuristic was added) on any host running this repo's `dot_config/shell/20_zoxide.sh`. Both zsh and bash. Fires more often inside coding-agent bash tools because they spawn fresh interactive-ish shells per command.
**Status**: fixed — `export _ZO_DOCTOR=0` added to `dot_config/shell/20_zoxide.sh` immediately after `zoxide init`.

## Symptom

Coding-agent shell tool returns:

```text
Bash(cd /some/path && mkdir -p /tmp/foo && ./scripts/build.sh)
  ⎿  Error: Exit code 2
     zoxide: detected a possible configuration issue.
     Please ensure that zoxide is initialized right at the end of your shell configuration file (usually ~/.zshrc).

     If the issue persists, consider filing an issue at:
     https://github.com/ajeetdsouza/zoxide/issues

     Disable this message by setting _ZO_DOCTOR=0.

     scripts/build.sh: line 62: syntax error near unexpected token `<'
```

Two unrelated things conflated:

1. The 6-line zoxide warning is printed to stderr by `__zoxide_hook` on every prompt.
2. The actual `Exit code 2` is from the inner build script's bash syntax error.

The agent (and human reader) sees them as one block and assumes zoxide caused the failure. It didn't — but the warning's presence in every command's stderr makes it noise on every other diagnostic.

## Root cause

`zoxide init zsh|bash` registers a hook (`__zoxide_hook`) and includes a doctor check that fires on every prompt:

- **zsh** version checks `precmd_functions[-1] == __zoxide_hook`
- **bash** version checks the tail of `PROMPT_COMMAND`

If anything else is registered AFTER zoxide, the warning fires.

This repo deliberately registers hooks after zoxide:

| Shell | Loaded after `20_zoxide.sh` | Adds hook? |
|---|---|---|
| zsh | `dot_config/zsh/tools/02_shell_integration.zsh` (`add-zsh-hook precmd _osc133_precmd`) | yes — appends to `precmd_functions` |
| bash | `dot_bashrc.tmpl` step 8: `eval "$(atuin init bash --disable-up-arrow)"` | yes — extends `PROMPT_COMMAND` |
| bash | `dot_bashrc.tmpl` step 10: `ble-attach` | yes — installs ble.sh's own DEBUG/RETURN trap chain |

The reasons each one MUST come after zoxide:

- **OSC 133** must run after starship so `add-zsh-hook precmd` chain order lands `_osc133_precmd` after `prompt_starship_precmd`. Otherwise OSC 133's PROMPT-wrap step has no rendered prompt to wrap.
- **atuin** must run after ble.sh has been sourced (`--attach=none --noattach`) but before `ble-attach`, otherwise atuin's `__atuin_history` fights ble.sh's `_ble_*` history layer.
- **ble-attach** must be the very last hook installer in bashrc — that's a hard ble.sh requirement (documented at <https://github.com/akinomyoga/ble.sh/wiki/>).

So the load order is correct *for our architecture*; zoxide's heuristic just doesn't know about it.

The functional impact of the "wrong" order is **zero**: `__zoxide_hook` only writes the current `$PWD` into the frecency DB on each prompt, and that write happens regardless of whether the hook is first, middle, or last in the chain.

## Workaround

Set `_ZO_DOCTOR=0` immediately next to the zoxide init in the shared shell layer:

```sh
# dot_config/shell/20_zoxide.sh
export _ZO_RESOLVE_SYMLINKS=1
export _ZO_DOCTOR=0  # see pitfalls/zoxide-doctor-warning.md
if [ -n "$ZSH_VERSION" ]; then
    eval "$(zoxide init zsh)"
elif [ -n "$BASH_VERSION" ]; then
    eval "$(zoxide init bash)"
fi
alias cd="z"
```

After `chezmoi apply` (or `source ~/.zshrc` / `source ~/.bashrc`), the warning stops appearing in every prompt. Existing agent sessions need a new shell to pick it up; coding-agent bash tools that spawn fresh shells per command pick it up immediately.

`zoxide` itself is unaffected. `z <query>`, `zi`, frecency tracking — all behave identically before and after.

## Prevention

If a future addition to the load chain has its own doctor-style "must be last" check, prefer **disabling the heuristic** over re-architecting the load order. The order in `dot_zshrc.tmpl` and `dot_bashrc.tmpl` is load-bearing for several non-negotiable reasons (ble.sh attach order, OSC 133 wrapping starship's prompt, atuin needing ble.sh as a peer, etc.).

Things to NOT do, and why:

- **Don't** move zoxide init to the very end of `~/.zshrc` / `~/.bashrc` — breaks the `dot_config/shell/*.sh` shared-tier convention (the whole point is one file works in both shells, sourced from the same loader callsite). Also still wouldn't help: `~/.shellrc.adhoc` / `~/.zshrc.adhoc` / `~/.bashrc.adhoc` may register their own precmd hooks and there's no way to guarantee user adhoc files don't.
- **Don't** monkey-patch `precmd_functions` to push `__zoxide_hook` to the end — fragile, breaks again the moment another tool re-orders.
- **Don't** ask agents to prefix every command with `_ZO_DOCTOR=0` — that's the symptom, not the fix. Past sessions accumulated ~140 such prefixes in `.specstory/history/` before this was root-caused.

If you ever need to actually re-enable the doctor (e.g. to debug whether zoxide's frecency tracking has stopped working): `_ZO_DOCTOR=1 zsh` for one session.

## Related

- [`dot_config/shell/20_zoxide.sh`](../dot_config/shell/20_zoxide.sh) — the fix lives here, next to the init
- [`dot_config/zsh/tools/02_shell_integration.zsh`](../dot_config/zsh/tools/02_shell_integration.zsh) — OSC 133 hook that's the proximate cause on zsh side
- [`dot_bashrc.tmpl`](../dot_bashrc.tmpl) — load-bearing 12-step init order on bash side; see [`docs/shells/bash.md`](../docs/shells/bash.md) for the rationale
- [zoxide#723 — "Disable doctor message"](https://github.com/ajeetdsouza/zoxide/issues/723) — upstream tracking issue for the heuristic's false positives
- Sibling pitfall: [`zsh-osc133-precmd-printf-a-not-stored.md`](zsh-osc133-precmd-printf-a-not-stored.md) — same `_osc133_precmd` hook, different failure mode
