# Bash bootstrap

Bash is supported as an alternative to zsh as the primary login shell.
The choice is made at `chezmoi init` time via the `primaryShell` prompt
(default `zsh`) and only governs which shell `chsh` switches to —
`~/.zshrc` and `~/.bashrc` are deployed in parallel on every host so
ad-hoc `bash` (or `zsh`) sessions still pick up the same env vars and
prompt.

The bash side targets **UX parity with zsh** by stacking
[oh-my-bash](https://github.com/ohmybash/oh-my-bash) (for plugin
familiarity / git aliases) and [ble.sh](https://github.com/akinomyoga/ble.sh)
(for autosuggestions, syntax highlighting, advanced vi-mode). Both are
managed via `.chezmoiexternal.toml.tmpl` git clones; ble.sh's runtime
artefact is compiled by
`.chezmoiscripts/global/run_onchange_after_26_install_blesh.sh.tmpl`.

## Selecting bash as primary

```bash
chezmoi init https://github.com/daviddwlee84/dotfiles.git --apply
# Answer: Primary interactive shell (zsh|bash) → bash
```

Or for a Docker test build:

```bash
docker build --build-arg CHEZMOI_PRIMARY_SHELL=bash -t dotfiles-bash .
docker run -it dotfiles-bash
```

To switch an existing host:

```bash
chezmoi init                        # re-prompt and edit ~/.config/chezmoi/chezmoi.toml
# (or hand-edit the file: primaryShell = "bash")
chezmoi apply                       # ansible bash role takes over the chsh
```

## What you get on bash

| Feature                              | Bash side                              | Zsh side                            |
| ------------------------------------ | -------------------------------------- | ----------------------------------- |
| starship prompt                      | ✓ (shared `dot_config/shell/01_starship.sh`) | ✓ |
| Shared env / PATH / GFW mirrors      | ✓ (`dot_config/shell/00_exports.sh.tmpl`)    | ✓ |
| zoxide / mise / direnv / thefuck     | ✓                                      | ✓ |
| fzf shell integration                | ✓ (`fzf --bash`)                       | ✓ (`fzf --zsh`) |
| atuin history                        | ✓ (with `--disable-up-arrow`)          | ✓ |
| oh-my-bash `git` plugin (gst/ga/...) | ✓                                      | ✓ via OMZ git plugin |
| Autosuggestions (ghost text)         | ✓ via ble.sh                           | ✓ via zsh-autosuggestions |
| Syntax highlighting (live)           | ✓ via ble.sh                           | ✓ via zsh-syntax-highlighting |
| Vi-mode                              | ✓ readline + ble.sh*                   | ✓ zsh-vi-mode* |
| `aisuggest` widget (Alt+;)           | ⚠ CLI form only; widget port deferred  | ✓ |
| tmux capture / AI capture functions  | ⚠ subset (CLI form), no ZLE widget     | ✓ |
| Television channel widgets (Alt+R/P/G/E/A/I) | ✗ (CLI `tv <channel>` only)    | ✓ |
| `tools-picker` (Alt+T)               | ✗ (CLI `tools-picker` only)            | ✓ |
| `sesh-sessions` (Alt+S)              | ⚠ CLI `sesh-connect` only              | ✓ |
| OSC 133 shell-integration markers    | ✗ (deferred)                           | ✓ |

The zsh-only items in the deferred column are tracked in `TODO.md` as
`[P3]` follow-ups; ble.sh's `ble-bind` API can host most of them but
each is its own porting effort.

\* Vi-mode (both rows) is gated by the chezmoi `enableVimMode` prompt
(default `true`). When `false`, bash's `set -o vi` is replaced with a
no-op, ble.sh's vi_imap/vi_nmap binds switch to default (emacs) keymap,
and zsh-vi-mode is omitted. Catalog: [`docs/this_repo/vim-mode.md`](../this_repo/vim-mode.md).

## Init order (load-bearing)

`dot_bashrc.tmpl`'s 12-step init is documented in the file's header
comment. The key invariants:

1. **ble.sh sourced with `--attach=none` BEFORE bash-preexec.** Starship
   installs bash-preexec internally; if ble.sh loads after, ble.sh's
   own preexec stack breaks. Reference:
   [ble.sh wiki § A1 Initialization](https://github.com/akinomyoga/ble.sh/wiki/Manual-§A1-Initialization).
2. **`ble-attach` at the very end** — after starship, atuin, OMB, and
   the modular layers have all registered their precmd / preexec hooks.
   This lets ble.sh absorb the entire stack cleanly.
3. **`atuin init bash --disable-up-arrow`** — ble.sh owns up-arrow for
   history navigation. Without the flag, atuin's TUI hijacks up-arrow
   and ble.sh's history walk breaks. `Ctrl+R` still opens atuin's TUI
   (no conflict).
4. **`OSH_THEME=""`** — starship owns the prompt. OMB's bundled themes
   would fight starship and produce double prompts.
5. **OMB plugins exclude `autosuggestions`, `syntax-highlighting`,
   `history-substring-search`** — ble.sh provides better native
   versions; double-init causes flicker + duplicate completions. The
   exclusions are encoded in `dot_config/bash/01_omb_plugins.bash`.

## Stock bashrc / bash_profile collision handling

We **don't** preserve these from `/etc/skel/.bashrc`:

- `debian_chroot` PS1 fragment / `PS1='\u@\h:\w\$'` — starship replaces.
- `HISTSIZE=1000` / `HISTFILESIZE=2000` — we set 10000 / 20000.
- color `ls` / `grep` aliases via `dircolors` — we use eza / bat.

We **do** preserve (intentional, in `dot_config/bash/02_history.bash`):

- `shopt -s checkwinsize` (LINES/COLUMNS update after each command).
- `shopt -s globstar` (`**` recursive glob).
- `shopt -s histappend cmdhist` (multi-shell history sync).
- `[[ $- != *i* ]] && return` early-return guard for non-interactive
  shells (in `dot_bashrc.tmpl` step 1).

On RHEL families (`/etc/bashrc` carries `rm -i` aliases + Modules system
init + protective umask) we source it explicitly in step 2. Debian /
Ubuntu has no `/etc/bashrc`, so the source is a no-op there.

## macOS bash 5.x install

The macOS system bash is 3.2.57 (GPLv3 reluctance). oh-my-bash plugins
require bash 4.4+, and ble.sh requires bash 4.0+. The bash ansible role
detects `os_family == "Darwin" && primary_shell == "bash"` and runs:

1. `brew install bash` (5.x current).
2. Append `/opt/homebrew/bin/bash` to `/etc/shells` (idempotent grep
   guard) so `chsh` accepts the path.
3. `chsh -s /opt/homebrew/bin/bash`.

zsh-primary mac users see **none** of this: no extra brew formula, no
`/etc/shells` edit, no `chsh`. The gate is intentional — bash is only
needed when explicitly chosen.

## Plain-bash fallback (no ble.sh / no OMB)

`dot_bashrc.tmpl` presence-gates every ble.sh and OMB block:

```bash
[ -r "$HOME/.local/share/blesh/ble.sh" ] && source ble.sh --attach=none
...
[ -r "$HOME/.oh-my-bash/oh-my-bash.sh" ] && source $OSH/oh-my-bash.sh
...
[[ -n $BLE_VERSION ]] && ble-attach
```

So a host where the externals haven't finished cloning, or where the
ble.sh `make install` failed, or where the user manually deleted
`~/.local/share/blesh/`, still gets a working starship prompt + the
shared layer + bash-completion v2 + the bash-specific configs. The
`run_onchange_after_26_install_blesh.sh.tmpl` script also handles the
"make not installed" case gracefully (warn + exit 0 instead of failing
the whole chezmoi apply).

## Known footguns

- **`bash-preexec` (third-party) installed in `~/.bash-preexec.sh`
  ahead of ble.sh breaks ble.sh's preexec stack.** We don't install
  it; if a user dropped one in via another path, symptoms are
  starship's `cmd_duration` not updating + ble.sh-bound preexec hooks
  not firing. Fix: remove `~/.bash-preexec.sh`.
- **`atuin` without `--disable-up-arrow`** clobbers ble.sh's
  history walk on up-arrow. The bashrc passes the flag automatically,
  but if you've added a manual `eval "$(atuin init bash)"` in
  `~/.bashrc.adhoc` without the flag, you'll see this. Fix: drop the
  manual init or add the flag.
- **Custom `bind -x` calls in `~/.inputrc` get shadowed by ble-bind
  once ble.sh attaches.** Document custom keybindings via `ble-bind -m
  default_keymap -f ...` instead, in `~/.bashrc.adhoc` (sourced AFTER
  `ble-attach`).
- **macOS Terminal.app launches bash as a login shell** but doesn't
  source `~/.bashrc`. `dot_bash_profile.tmpl` handles this: it sources
  `~/.bashrc` at the end. If you skipped `chezmoi apply` or removed
  `~/.bash_profile` manually, login shells will land in a bare bash
  with no starship.

## Adhoc tail (`~/.bashrc.adhoc`)

Sister to `~/.zshrc.adhoc`. Auto-created on first apply, gitignored
(`.bashrc.adhoc` in `.chezmoiignore.tmpl`), sourced at the very end of
`dot_bashrc.tmpl` **after `ble-attach`**, so `ble-bind` calls in it
take effect.

Use it for:

- Machine-specific PATH additions
- Quick experiments with new aliases / functions
- Custom ble.sh keybindings (`ble-bind -x ...`)
- Per-host `bleopt` overrides (e.g. `bleopt complete_auto_complete=`
  to disable autosuggest on slow remote machines)

## Related docs

- [docs/shells/architecture.md](architecture.md) — 3-tier shell layout
  rationale (`dot_config/shell/` vs `dot_config/zsh/` vs
  `dot_config/bash/`), migration story for existing zsh users, future-
  shell extension feasibility (fish, PowerShell).
- [docs/shells/aliases.md](aliases.md) — shared alias / function
  inventory (which shells each is available in).
- [docs/shells/history.md](history.md) — bash/zsh native history files,
  env vars (`HISTSIZE`, `HISTFILESIZE`, `HISTCONTROL`), `shopt`s, ble.sh
  interaction, multi-user audit on a server, atuin's place.
- [docs/zsh/motd.md](../zsh/motd.md) — SSH login banner styles
  (figlet / fastfetch-slim / fastfetch-full); shared between shells.
