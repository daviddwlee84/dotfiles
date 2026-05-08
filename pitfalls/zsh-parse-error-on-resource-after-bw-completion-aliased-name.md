# `parse error near \`()'` when re-sourcing `~/.zshrc` after a tool's completion script registered an alias matching one of our function names

**Symptoms** (grep this section):

- Re-sourcing `~/.zshrc` (NOT first source — works fine on shell startup)
  fails with:
  ```
  ❯ source ~/.zshrc
  /home/<user>/.config/shell/10_aliases.sh:66: defining function based on alias `bw-update-completion'
  /home/<user>/.config/shell/10_aliases.sh:66: parse error near `()'
  ```
- Line number points at a perfectly normal POSIX function definition
  (`name() { ... }`) that has been in the repo unchanged for months and
  still works in fresh shells.
- A fresh `zsh -l` / new terminal tab is fine. Only `source ~/.zshrc`
  inside an already-running interactive shell triggers it.
- `bash` does not reproduce — bash silently allows function-and-alias
  with the same name.
- Removing the function definition makes the error vanish (red herring —
  the function is fine).

## Root cause

zsh option `ALIAS_FUNC_DEF` is **off by default** since 5.8. With it off,
zsh refuses to parse `name() { ... }` (POSIX function syntax) if `name`
is currently registered as an alias — and it errors with the `parse
error near \`()'` cited above. The `function name { ... }` ksh-style
syntax is **immune** because `function` is a reserved word that
suppresses alias expansion of the immediately following name.

The latent collision in this repo:

1. `dot_config/shell/10_aliases.sh` defines a function
   `bw-update-completion` to refresh the cached `bw` (Bitwarden CLI)
   shell completion file.
2. `dot_config/zsh/tools/95_bitwarden.zsh` later sources
   `~/.cache/zsh/bw_completion.zsh` if present.
3. Newer `bw` versions (post April 2025-ish) emit an
   `alias bw-update-completion=...` line inside that completion script
   — older versions did not.
4. After `bw completion --shell zsh` is regenerated against a newer bw
   binary, sourcing the cache file installs the alias **after** the
   function was already defined.
5. **First** `~/.zshrc` source: function defined first, alias added
   later — both coexist, alias wins at command lookup but no parse
   error happens (the function definition was already parsed).
6. **Second** `source ~/.zshrc` in the same interactive shell:
   `10_aliases.sh` is re-parsed; this time the alias already exists at
   parse time → `defining function based on alias` → `parse error`.

The same trap applies to **any** function in `dot_config/shell/*.sh`
whose name a tool's completion script (or plugin) might later create as
an alias. The function name does not have to match `bw-*` or
`*-completion` — generic names are vulnerable too.

## Fix

Use the `function` keyword for any function whose name is even
plausibly aliasable by a tool's completion script:

```sh
# ❌ Vulnerable — POSIX form, alias-checked at parse time in zsh
bw-update-completion() {
  ...
}

# ✅ Safe — `function` keyword bypasses alias expansion of the name
function bw-update-completion {
  ...
}
```

Both forms work in bash and zsh. The `function name { … }` form (no
`()`) is preferred over `function name() { … }` — the latter still
involves a `()` token that older POSIX-strict linters dislike, though
zsh/bash both accept it.

This repo's actual fix: `dot_config/shell/10_aliases.sh:66` —
`bw-update-completion()` → `function bw-update-completion`.

## Workaround in current shell

If you hit the error and don't want to restart the shell:

```sh
unalias bw-update-completion 2>/dev/null
source ~/.zshrc
```

Until you re-source `~/.cache/zsh/bw_completion.zsh` again the alias
won't come back.

## Defensive options NOT taken

- **`unalias` defensively at the top of `10_aliases.sh`** — would have
  to enumerate every name. Doesn't generalize.
- **`unalias bw-update-completion`** in `95_bitwarden.zsh` after
  sourcing the completion cache — narrowly correct but won't help
  future tools that pull the same trick. Also makes the alias the
  completion script provides effectively unreachable.
- **`setopt ALIAS_FUNC_DEF`** globally — masks real bugs (the OPPOSITE
  case where you intend `name()` to redefine an aliased command).
  Don't.

## Detecting recurrence

If you write a new helper in `dot_config/shell/*.sh` and want to
verify nothing's already aliasing the name in your live shells:

```sh
zsh -ic 'alias' | grep -F "<name>="
bash -ic 'alias' | grep -F "<name>="
```

Returning nothing in both means you can use either function-definition
syntax safely. Returning anything → use `function name { … }`.

## Why `bash` doesn't see it

bash silently allows `name() { ... }` to coexist with `alias name=...`;
the function is callable via `\name` (backslash bypasses alias
expansion) or by `unalias` first. bash also has no equivalent of
`ALIAS_FUNC_DEF`. So a bash-only repo would never have noticed this
class of bug — a portable shell file shared between bash and zsh is
exactly where it bites.

## Related

- `dot_config/zsh/tools/95_bitwarden.zsh` — the `bw` completion cache
  loader.
- `dot_config/shell/10_aliases.sh` — the shared shell helpers,
  `bw-update-completion` lives here.
- AGENTS.md → "Custom aliases & shell functions → `docs/shells/aliases.md`"
  — three-tier file placement rule (shared `dot_config/shell/`, zsh-only
  `dot_config/zsh/`, bash-only `dot_config/bash/`).
