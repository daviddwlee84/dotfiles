# Shell architecture

This page explains the three-tier shell config layout in this repo, the
migration that landed alongside the `primaryShell` prompt, and the
feasibility of extending the same model to fish / PowerShell.

For practical bash-side detail (init order, footguns, ble.sh + OMB
integration) see [`bash.md`](bash.md). For the alias / function
inventory across shells see [`aliases.md`](aliases.md). For background
on what POSIX actually standardises (and where bash/zsh stop being
portable) see [`posix.md`](posix.md).

## The three tiers

```
~/.config/shell/      — POSIX-portable; sourced by BOTH zsh & bash
  ├── 00_exports.sh.tmpl       PATH, EDITOR, XDG dirs, Homebrew shellenv,
  │                             GFW mirror env vars, GOPATH/BUN/PNPM_HOME
  ├── 01_starship.sh           starship init <shell> dispatched by
  │                             $ZSH_VERSION / $BASH_VERSION
  ├── 02_legacy_tools.sh       Go / Bun / pnpm / Foundry / NVM / .NET PATH
  ├── 05_mise.sh               mise activate <shell>
  ├── 10_aliases.sh            v=nvim, chezmoi-cd, gcam-amend, gundo,
  │                             glop, load-nvm, brew-mirror, ghostty-ssh-
  │                             terminfo, claude-plans-here, ...
  ├── 10_fzf.sh                fzf shell integration with --zsh / --bash
  │                             dispatch + apt-fzf fallback paths
  ├── 20_zoxide.sh             zoxide init + cd→z alias
  ├── 27_thefuck.sh            thefuck (auto-detects shell)
  └── 30_direnv.sh             direnv hook

~/.config/zsh/        — zsh-only (ZLE widgets, compdef, bindkey, setopt)
  ├── 10_aliases.zsh           Just `zsh-profile` alias now (the rest
  │                             moved into shell/10_aliases.sh).
  └── tools/
      ├── 02_shell_integration.zsh   OSC 133 markers via add-zsh-hook
      ├── 04_ai_capture.zsh          aifix / aiexplain / aiblock
      ├── 05_aisuggest.zsh           Inline AI ghost-text (Alt+;) ZLE widget
      ├── 11_tools_picker.zsh        Alt+T tools picker
      ├── 12_television.zsh          Alt+R/P/G/E/A/I tv channel widgets
      ├── 22_sesh.zsh                Alt+S sesh-sessions widget
      └── ... (ZLE widgets, completions)

~/.config/bash/       — bash-only (bind -x / ble-bind, OMB plugin arrays,
                       bash-specific shopts)
  ├── 01_omb_plugins.bash      `plugins=(git sudo bashmarks)`,
  │                             `aliases=(general)`, `completions=(...)`.
  │                             Sourced BEFORE OMB.
  ├── 02_history.bash          HISTSIZE / HISTCONTROL / shopt
  ├── 03_completion.bash       bash-completion v2 with dynamic Homebrew prefix
  ├── 04_blesh.bash            bleopt tweaks (sourced after ble-attach)
  ├── 05_vi_mode.bash          set -o vi (ble.sh auto-detects + upgrades)
  └── 10_aliases.bash          bash-only aliases (bash-profile, reload)
```

`~/.zshrc` and `~/.bashrc` both source `~/.config/shell/` first (via
`load_modular_dir "$XDG_CONFIG_HOME/shell" sh`), then their respective
shell-specific dirs. Single source of truth for env vars / PATH /
trivial aliases; per-shell escape hatch for anything that isn't POSIX.

## Why three tiers, not two

A simpler design might have just `~/.config/zsh/` and `~/.config/bash/`
with each duplicating PATH exports, alias definitions, tool init lines,
GFW mirror env vars. We didn't, because:

1. **Drift.** Aliases / env vars in two files diverge over time. The
   shared layer eliminates the entire drift surface for ~600 LOC of
   POSIX content.
2. **Tool init wrappers.** `eval "$(starship init zsh)"` and
   `eval "$(starship init bash)"` differ only in one flag. A
   shell-detecting wrapper is one extra `if`; two parallel files are
   double the maintenance.
3. **Future shells.** Adding fish / PowerShell would mean re-writing
   the env layer once per shell. If env lives in the shared POSIX
   layer, fish needs translation (since fish isn't POSIX); but if env
   were already duplicated zsh/bash, fish would be a *third* parallel
   tree. See [Future shell extension](#future-shell-extension) below.

The cost is the discipline: anything in `dot_config/shell/` MUST be
POSIX-portable. No `setopt`, no `read -q`, no `${var:t}`, no glob
qualifiers, no zsh-vi-mode hooks, no `bind -x`. The
[`CLAUDE.md` three-tier rule](../../CLAUDE.md#custom-aliases--shell-functions--docsshellsaliasesmd)
codifies this — agents writing new helpers need to pick the right
tier first.

## Migration story (for existing zsh users)

The `primaryShell` prompt and bash bootstrap landed across 7 commits:

1. `init: add primaryShell prompt for zsh/bash login-shell choice`
2. `ansible: gate zsh chsh on primaryShell + add bash role for chsh-to-bash`
3. `shell: extract POSIX layer to dot_config/shell/ for zsh/bash sharing`
4. `bash: ship dot_bashrc.tmpl + dot_bash_profile.tmpl + dot_config/bash/`
5. `bash: add oh-my-bash + ble.sh externals and plugin glue`
6. `docs: cross-file updates for primaryShell + bash bootstrap`
7. `bash: install gawk unconditionally — ble.sh Makefile hard-requires it`

For an existing `chezmoi apply`-managed host on the previous zsh-only
config, the `chezmoi apply` after pulling these commits will:

- **Move 7 files** out of `~/.config/zsh/` into `~/.config/shell/`
  (00_exports, 02_legacy_tools, 01_starship, 05_mise, 20_zoxide,
  27_thefuck, 30_direnv, 10_fzf). The old paths are listed in
  [`.chezmoiremove`](../../.chezmoiremove) so chezmoi deletes the
  orphans on apply (otherwise both old + new would get sourced and
  PATH would double).
- **Strip `~/.config/zsh/10_aliases.zsh`** down to just the
  `zsh-profile` alias. Everything else moved to
  `~/.config/shell/10_aliases.sh`.
- **Deploy `~/.bashrc` + `~/.bash_profile`** even on zsh-primary
  hosts. Existing system `~/.bashrc` (Ubuntu / Debian skel) gets
  backed up via chezmoi's `backupMode` (`smart` by default). After
  the apply, `~/.bashrc.adhoc` is auto-created if missing — sister of
  `~/.zshrc.adhoc`. **Pre-existing `~/.bash_aliases` is preserved**:
  the new bashrc explicitly sources it (step 11), so any aliases the
  user accumulated there over the years keep working.
- **Run `chsh`** to zsh (default `primaryShell=zsh`) only if not
  already on zsh. No change for users already on zsh — they're
  unaffected.

Verified post-apply: zsh `precmd_functions` array byte-identical, all
PATH entries preserved, all hooks (starship/mise/direnv/zvm/omz/zsh-
autosuggestions/zsh-syntax-highlighting) intact.

## What's preserved vs. replaced from system bashrc

`/etc/skel/.bashrc` on Debian / Ubuntu:

| Block                                          | Action      | Why |
| ---------------------------------------------- | ----------- | --- |
| `[[ $- != *i* ]] && return` early-return guard | Preserve    | Same pattern in dot_bashrc.tmpl step 1 |
| `shopt -s checkwinsize histappend cmdhist`     | Preserve    | Harmless + useful (02_history.bash) |
| `shopt -s globstar` (commented in skel)        | Enable      | `**` recursive glob, useful default |
| `HISTSIZE=1000` / `HISTFILESIZE=2000`          | Replace     | We set 10000/20000; OMB then sets unlimited |
| `HISTCONTROL=ignoreboth`                       | Preserve    | Standard sane default |
| `debian_chroot` PS1 fragment                   | Replace     | starship owns the prompt |
| `ls --color=auto` / `grep --color=auto` aliases | Replace     | eza / bat take over |
| `~/.bash_aliases` source                       | Preserve    | dot_bashrc.tmpl step 11 |
| bash-completion v2 source                      | Preserve    | dot_config/bash/03_completion.bash |

`/etc/bashrc` on RHEL families (CentOS / Rocky / Alma) is sourced
explicitly by step 2 of dot_bashrc.tmpl, preserving the protective
`rm -i` / `cp -i` aliases, the Modules system init, and the
distribution's umask defaults. The RHEL-specific `~/.bashrc.d/*`
loop convention (analogous to Debian's `~/.bash_aliases`) is also
preserved by step 11 — anything users dropped into that dir keeps
working.

RHEL family `/etc/skel/.bashrc` carries less than Debian's:

| Block                                                         | Action       | Why |
| ------------------------------------------------------------- | ------------ | --- |
| `if [ -f /etc/bashrc ]; then . /etc/bashrc; fi`               | Preserve     | dot_bashrc.tmpl step 2 |
| `PATH="$HOME/.local/bin:$HOME/bin:$PATH"`                     | Preserve     | Same export in dot_config/shell/00_exports.sh.tmpl |
| `for rc in ~/.bashrc.d/*; do . "$rc"; done`                   | Preserve     | dot_bashrc.tmpl step 11 |
| (no PS1, no aliases, no shopts in skel)                       | N/A          | RHEL leaves prompt + aliases to /etc/bashrc + user dotfiles |

## Future shell extension

The `primaryShell` prompt is currently `["zsh", "bash"]`. Extending to
fish / PowerShell is feasible but each comes with its own cost.

### fish 3.x

**Feasibility: Medium effort, mostly mechanical.**

- Tool init wrappers: starship / zoxide / mise / direnv / atuin all
  have `init fish` (or `mise activate fish`) flags. Trivial
  one-liners.
- Env exports: fish doesn't use `export VAR=val` syntax. Needs
  translation: `set -gx VAR val`. ~30 LOC of mechanical conversion
  for the current `00_exports.sh.tmpl`.
- Aliases: fish syntax is `alias v 'nvim'` (note space, single-quote).
  ~10 LOC of conversion.
- Functions: fish uses `function name; ...; end`. The current
  `~/.config/shell/10_aliases.sh` has 8 functions. Each would need
  a fish rewrite. Some (`gundo`, `gcam-amend`) are trivial; others
  (`claude-plans-here`, `ghostty-ssh-terminfo`) are substantial.
- Plugin manager: oh-my-fish (OMF) is the typical choice. Plugin
  parity with OMZ/OMB git aliases is 80%-good — close enough.
- vi-mode: fish has built-in `fish_vi_key_bindings` (better than
  zsh-vi-mode and ble.sh's). Less to wire up.
- Autosuggestions / syntax highlighting: fish has these BUILT IN.
  No ble.sh-equivalent dependency.

The shared POSIX layer can't be sourced by fish (different syntax),
so fish would need a parallel `dot_config/fish/conf.d/` tree. Suggest:

```
~/.config/fish/conf.d/
  ├── 00_exports.fish        translated from shell/00_exports.sh.tmpl
  ├── 01_starship.fish       starship init fish | source
  ├── 10_aliases.fish        translated from shell/10_aliases.sh
  ├── 20_zoxide.fish         zoxide init fish | source
  └── ...
```

Estimate: ~400 LOC translation + a fish ansible role (chsh logic
identical to bash role) + one new prompt value. Probably one
afternoon of focused work. Tracked in
[`TODO.md`](../../TODO.md) as `[P3/L]` for now.

### PowerShell Core 7+ (`pwsh`)

**Feasibility: Higher effort, more disjoint.**

- Profile location: `~/.config/powershell/Microsoft.PowerShell_profile.ps1`
  on Linux/macOS; very different from bash/zsh `.rc` model.
- Tool inits: starship / zoxide / mise have `init powershell` flags
  (mise uses `mise activate pwsh`). atuin has pwsh support via the
  community plugin. fzf needs PSFzf module.
- Env exports: `$env:VAR = "value"` (no `export`).
- Aliases: `Set-Alias v nvim` (no shell-function-style; pwsh aliases
  can't take arguments — for those, you write a function).
- Functions: completely different syntax (`function Verb-Noun
  { param([string]$Name) ... }`).
- vi-mode: PSReadLine has it (`Set-PSReadLineOption -EditMode Vi`).
- Autosuggest / syntax highlight: PSReadLine has both (the equivalent
  of ble.sh).
- Plugin ecosystem: oh-my-posh is the common prompt (works with
  bash / zsh / pwsh — competes with starship), but pwsh-specific
  plugins live in PowerShell Gallery (`Install-Module`).

The shared POSIX layer can't be reused at all. PowerShell pipelines
are object-streams, not text-streams; aliases / functions need a
fundamentally different mental model.

Estimate: ~1-2 days for a working profile that mirrors the bash UX
(starship + zoxide + PSReadLine vi-mode + a small set of aliases),
plus a new ansible role to install pwsh (apt deb on Ubuntu, brew
cask on macOS, scoop on Windows if we ever go there). Tracked in
[`TODO.md`](../../TODO.md) as `[P?/L]`.

### nushell, elvish, xonsh

Even more disjoint than fish (nushell is structured-data first;
elvish has its own scripting language; xonsh is Python-first). Out
of scope for the foreseeable future. If a user picks one, they
should set `primaryShell=zsh` (or `bash`) for the chsh-managed
login shell and source their alternative shell from `~/.zshrc.adhoc`
or via a wrapper terminal profile.

## Why we didn't go fish / PowerShell first

Three reasons (in priority order):

1. **Bash is universal**: every Linux distro and macOS ship it. Adding
   bash brought "better support for hosts where you can't easily
   install zsh" (locked-down corporate, minimal containers, recovery
   shells), which was the stated need.
2. **POSIX shared layer pays off**: ~600 LOC of zsh code became
   ~600 LOC of POSIX code shared with bash. The fish / PowerShell
   versions would be a 3rd / 4th tree of similar size each. Diminishing
   returns once bash is in.
3. **No specific user signal**: nobody asked for fish or PowerShell
   yet. We added them as `[P3/L]` and `[P?/L]` items in the backlog;
   we'll build them when the first concrete need shows up.

## See also

- [`bash.md`](bash.md) — bash-side practical guide (init order,
  footguns, plain-bash fallback)
- [`aliases.md`](aliases.md) — alias / function inventory across all
  three tiers
- [`CLAUDE.md` → "primaryShell choice gates chsh only"](../../CLAUDE.md#primaryshell-choice-gates-chsh-only--both-shells-always-deploy)
  — the hard invariant for agents adding new shell helpers
- [`TODO.md`](../../TODO.md) — the deferred bash UX gaps (aisuggest /
  tv / sesh ZLE → ble-bind ports) and future-shell items
