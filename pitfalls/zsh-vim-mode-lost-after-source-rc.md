# zsh vim mode (viins keymap) silently reverts to emacs after `source-rc` / `reload` / `source ~/.zshrc`

**Symptoms** (grep this section):

- After running `source-rc` (or its alias `reload`, or a manual
  `source ~/.zshrc`) in an already-running interactive **zsh**, vi modal
  editing is gone: no `[NORMAL]`/`[INSERT]` mode, `Esc` + `hjkl` / `dd` /
  `cw` do nothing, cursor shape no longer changes.
- A fresh `zsh -l` / new terminal tab / `exec zsh` / `cas` is fine — only
  in-place re-sourcing loses it.
- `bindkey -lL main` prints `bindkey -A emacs main` after the reload
  (was `bindkey -A viins main` before).
- `echo $ZVM_INIT_DONE` prints `true` but the keymap is emacs — the
  giveaway that zsh-vi-mode thinks it is initialized while OMZ has
  reset the keymap out from under it.
- Only affects hosts with `enableVimMode = true` (the `zsh-vi-mode` OMZ
  plugin loaded). `enableVimMode = false` machines never had vi keymaps
  to lose.

## Root cause

Two independent behaviors combine:

1. **oh-my-zsh resets the keymap on every source.**
   `~/.oh-my-zsh/lib/key-bindings.zsh:19` runs an unconditional
   `bindkey -e`. On first shell startup this also runs, but the deferred
   `zvm_init` (below) later overrides `main` to `viins`. On a *re-source*
   it runs again and wins.

2. **zsh-vi-mode refuses to re-init on re-source.**
   The plugin guards its own file with
   `command -v 'zvm_version' >/dev/null && return` at the top. So on
   re-source the plugin body is skipped: `ZVM_INIT_DONE=false` is **not**
   re-run (stays `true`), and `precmd_functions+=(zvm_init)` is **not**
   re-added. Even the `zvm_init` still sitting in `precmd_functions` from
   the first load early-returns because of the `if $ZVM_INIT_DONE; then
   return; fi` guard at the top of `zvm_init`.

Net effect: OMZ sets `bindkey -e`, and nothing ever flips it back to
`viins`. Vim mode is lost until a fresh shell (`exec zsh` / `cas`).

This is *not* a bug in `source-rc` re-sourcing "less" than a fresh shell —
re-sourcing runs everything, but plugins with once-only init guards
(zsh-vi-mode here) legitimately no-op on the second pass, and OMZ's
keymap reset has no such guard.

## Fix

`source-rc` (in `dot_config/shell/10_aliases.sh`) force-reinitializes
zsh-vi-mode in place after re-sourcing:

```sh
if [ -n "${ZSH_VERSION:-}" ] && command -v zvm_init >/dev/null 2>&1; then
	ZVM_INIT_DONE=false
	zvm_init
fi
```

Resetting `ZVM_INIT_DONE=false` defeats `zvm_init`'s own guard so the
call runs a full re-init (`bindkey -v` + vi keymaps), and because
`zvm_init` invokes the user `zvm_after_init` hook, the fzf / atuin /
aisuggest / keys-picker rebinds (defined in `dot_zshrc.tmpl`) are
replayed too. It is a no-op when `enableVimMode = false` or the plugin
is absent (`zvm_init` undefined), and the `[ -n "$ZSH_VERSION" ]` guard
keeps bash out of the zsh-only branch (the file is shared POSIX).

## How to verify

```
zsh -i -c '
  zvm_init                      # simulate first prompt
  source ~/.zshrc >/dev/null 2>&1
  bindkey -lL main              # BEFORE fix: bindkey -A emacs main
  ZVM_INIT_DONE=false; zvm_init
  bindkey -lL main              # AFTER fix:  bindkey -A viins main
'
```

## Related

- [[zsh-parse-error-on-resource-after-bw-completion-aliased-name]] — a
  *different* re-source-only zsh trap in the same `source-rc` path.
- The heavier guaranteed-clean reload is `cas` / `cau`
  (`dot_config/shell/99_chezmoi_reload.sh`), which `exec`s a fresh login
  shell instead of re-sourcing.
