# Adhoc & Secrets — User-Local Override Layer

This repo provides **six** user-local files where you can drop machine-specific
config without going through `chezmoi edit` / commit / apply. They form a
3-tier × 3-scope matrix that covers every "I want to override something"
need without forcing duplication between zsh and bash.

All six files are listed in [`.chezmoiignore.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoiignore.tmpl)
— chezmoi will never overwrite, track, or delete them.

## TL;DR — which file?

```
Need to override something?
│
├─ Is it a secret (API key / token / proxy)?
│   ├─ Both shells need it?       → ~/.shellrc.secrets        ← shared
│   ├─ zsh only (e.g. compinit)?  → ~/.config/zsh/secrets.zsh
│   └─ bash only?                 → ~/.config/bash/secrets.sh
│
└─ Not a secret (alias / export / experiment / binding)?
    ├─ POSIX, both shells?        → ~/.shellrc.adhoc          ← shared
    ├─ zsh-only construct?        → ~/.zshrc.adhoc
    │   (setopt, ZLE widget, compdef, bindkey, read -q, ${m:t}, glob qualifiers)
    └─ bash-only construct?       → ~/.bashrc.adhoc
        (bind -x, ble-bind, shopt, complete -F, OMB plugin tweaks)
```

**Default to the shared file.** Drop down to per-shell only when you actually
need shell-specific syntax.

## The six files

| Tier | File | Scope | Auto-stub | Notes |
|---|---|---|---|---|
| Secrets | `~/.shellrc.secrets` | both shells (POSIX) | no | Sourced by both `~/.zshrc` and `~/.bashrc` before any adhoc files |
| Secrets | `~/.config/zsh/secrets.zsh` | zsh only | no | Sourced after the shared layer; can use zsh-only syntax |
| Secrets | `~/.config/bash/secrets.sh` | bash only | no | Same as above but bash |
| Adhoc | `~/.shellrc.adhoc` | both shells (POSIX) | yes | Auto-created on first shell launch with a POSIX-only warning header |
| Adhoc | `~/.zshrc.adhoc` | zsh only | yes | Auto-created on first zsh launch |
| Adhoc | `~/.bashrc.adhoc` | bash only | yes | Auto-created on first bash launch |

Why secrets aren't auto-stubbed: an empty `secrets.*` file is a footgun
(committed accidentally is harmless because it's chezmoi-ignored, but `set -u`
scripts could trip on missing vars and silently 'succeed' with `[ -r ]`
guards). You create them yourself the first time you have a secret to store.

## Load order

### zsh (`dot_zshrc.tmpl`)

```
1. Shared POSIX modules        ~/.config/shell/*.sh           (managed)
2. zsh modules                 ~/.config/zsh/*.zsh + tools/   (managed)
3. Shared secrets (NEW)        ~/.shellrc.secrets             (user-local)
4. zsh secrets                 ~/.config/zsh/secrets.zsh      (user-local)
5. Shared adhoc (NEW)          ~/.shellrc.adhoc               (user-local)
6. zsh adhoc                   ~/.zshrc.adhoc                 (user-local)
```

### bash (`dot_bashrc.tmpl`, mapped to its 12-step init order)

See [`docs/shells/bash.md`](bash.md) for the full step list. The relevant
positions:

```
... steps 1-7: env, exports, OMB, bash-preexec, ble.sh source, modules ...
 8. atuin init
 9a. Shared secrets (NEW)      ~/.shellrc.secrets    ← before ble-attach
 9b. bash secrets              ~/.config/bash/secrets.sh
10. ble-attach
11. ~/.bash_aliases + ~/.bashrc.d/*  (distro skel compat)
12a. Shared adhoc (NEW)        ~/.shellrc.adhoc      ← after ble-attach
12b. bash adhoc                ~/.bashrc.adhoc
```

Secrets run **before** `ble-attach` so vars are already exported when ble.sh,
starship, atuin, and OMB precmd hooks fire. Adhoc runs **after** `ble-attach`
so any `bind -x` / `ble-bind` calls in `~/.bashrc.adhoc` take effect (the
shared file should not contain ble-bind, but the position is the same for
symmetry).

## Precedence rules

Two simple rules, applied in order:

1. **Secrets sourced before adhoc.** This means `~/.shellrc.adhoc` can read
   variables defined in `~/.shellrc.secrets`. Useful pattern:

   ```sh
   # ~/.shellrc.secrets
   export OPENAI_API_KEY=sk-...

   # ~/.shellrc.adhoc
   alias gpt='openai api -k "$OPENAI_API_KEY" ...'
   ```

2. **Shared sourced before per-shell.** Per-shell files are sourced *last* in
   their tier, so they override the shared layer on any naming conflict —
   matching the existing `~/.bash_aliases` → `~/.bashrc.adhoc` ordering.

   ```sh
   # ~/.shellrc.adhoc
   export MY_VAR=shared

   # ~/.zshrc.adhoc
   export MY_VAR=zshlocal       # zsh sees this; bash sees `shared`
   ```

## POSIX-only constraint for shared files

`~/.shellrc.adhoc` and `~/.shellrc.secrets` are sourced by **both** shells, so
they MUST be POSIX-portable.

**Forbidden in shared files:**

- zsh-only: `setopt`, `compdef`, ZLE widgets (`zle -N`), `bindkey`, `read -q`,
  `${m:t}` modifier expansion, glob qualifiers (`*(.om[1])`), `(($var))` arith
  in some contexts, `=~` with PCRE
- bash-only: `bind -x`, `bind -X`, `ble-bind`, `shopt`, `complete -F`,
  `BASH_REMATCH`, OMB plugin array vars

**If you really need shell-specific logic in the shared file**, dispatch via
`$ZSH_VERSION` / `$BASH_VERSION` — the same convention used by every file in
[`dot_config/shell/`](https://github.com/daviddwlee84/dotfiles/tree/main/dot_config/shell):

```sh
# ~/.shellrc.adhoc
if [ -n "$ZSH_VERSION" ]; then
    setopt prompt_subst
elif [ -n "$BASH_VERSION" ]; then
    shopt -s histappend
fi
```

But if you find yourself writing this dispatch, the bigger question is: does
this even belong in the shared file? Usually moving it to the per-shell file
is cleaner.

> **Why `$ZSH_VERSION` not `$SHELL`?** `$SHELL` reflects the login shell from
> `/etc/passwd`, which can disagree with the actually-running shell after
> `chsh` until next login (and is dead-wrong inside `bash -c '...'` from a
> zsh primary). Source-time detection via `$ZSH_VERSION` / `$BASH_VERSION` is
> always accurate. See the "Hard repo invariants" section of `CLAUDE.md`.

## Worked examples

### Cross-shell API key

```sh
# ~/.shellrc.secrets
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GITHUB_TOKEN=ghp_...
```

Both `claude`, `openai`, and `gh` will see these whether you launch them from
zsh or bash.

### Cross-shell alias / function

```sh
# ~/.shellrc.adhoc
alias k=kubectl
alias dc='docker compose'
notes() { ${EDITOR:-vim} "$HOME/notes/$(date +%Y-%m-%d).md"; }
```

### zsh-only ZLE widget

```zsh
# ~/.zshrc.adhoc
my_widget() { LBUFFER+="hello" }
zle -N my_widget
bindkey '^X^H' my_widget
```

### bash-only readline binding

```bash
# ~/.bashrc.adhoc
my_widget() { READLINE_LINE+="hello"; READLINE_POINT=${#READLINE_LINE}; }
bind -x '"\C-x\C-h": my_widget'
# Or via ble.sh if you prefer:
# ble-bind -x 'C-x C-h' my_widget
```

### Machine-specific PATH (laptop only)

```sh
# ~/.shellrc.adhoc on the laptop
export PATH="$HOME/work/laptop-tools/bin:$PATH"
```

The same `~/.shellrc.adhoc` won't exist on the desktop, so the desktop is
unaffected.

## Lifecycle: chezmoi never touches these

All six files are listed in [`.chezmoiignore.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoiignore.tmpl).
Concretely:

- `chezmoi apply` will not overwrite, delete, or stat these files
- `chezmoi add ~/.shellrc.adhoc` (or any of the six) is a no-op
- `chezmoi diff` will not show them
- `chezmoi forget` is unnecessary — they were never tracked

The four `*.adhoc` files have **auto-stub creation** in `dot_zshrc.tmpl` /
`dot_bashrc.tmpl`: if missing, the rc creates an empty file with a doc-comment
header on first shell launch. The two `*.secrets` files do not auto-stub.

## Migrating from the old (per-shell-only) pattern

If you previously had the same secret pasted into `~/.config/zsh/secrets.zsh`
AND `~/.config/bash/secrets.sh`, you can now consolidate:

1. Move the shared lines into `~/.shellrc.secrets`.
2. Delete the duplicates from the per-shell files (or leave them — per-shell
   wins on conflict, so they'll just shadow the shared value harmlessly).

Same for `~/.zshrc.adhoc` ↔ `~/.bashrc.adhoc`: anything POSIX-portable can
move up to `~/.shellrc.adhoc`. No migration required — the per-shell files
keep working unchanged.

## See also

- [`docs/shells/architecture.md`](architecture.md) — full zsh/bash init order,
  including how the modular `dot_config/{shell,zsh,bash}/` dirs feed into
  these adhoc/secrets sources
- [`docs/shells/bash.md`](bash.md) — bash 12-step init breakdown (ble.sh +
  OMB stacking) showing where 9a/9b/12a/12b sit
- [`docs/this_repo/config-conventions.md`](../this_repo/config-conventions.md)
  — broader XDG / `.d/` / `*.local` / `*.adhoc` convention catalog
- [`CLAUDE.md`](https://github.com/daviddwlee84/dotfiles/blob/main/CLAUDE.md) →
  "Three-tier override layer" hard invariant
