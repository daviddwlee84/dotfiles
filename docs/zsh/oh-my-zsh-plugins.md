# Zsh Plugins (oh-my-zsh + custom)

What's currently active, what's worth adding, and how plugins are managed in this repo.

## How plugins are managed

Plugin source trees are declared in [`.chezmoiexternal.toml.tmpl`](https://github.com/daviddwlee84/MyDotfiles/blob/main/.chezmoiexternal.toml.tmpl) at the repo root. Chezmoi clones them on `chezmoi apply` (`--depth 1`, `--ff-only`) and `git pull`s weekly (`refreshPeriod = "168h"`). Force an immediate refresh with `chezmoi apply --refresh-externals`.

Activation lives in `dot_zshrc.tmpl`:

```zsh
plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    {{ if .enableVimMode }}zsh-vi-mode{{ end }}
)
```

`zsh-completions` is cloned but NOT in the `plugins=()` array — it's referenced via `fpath` only (extra completion functions; nothing to "load"). See [`zsh-completions.md`](zsh-completions.md) Section A for how that works.

> The ansible `zsh` role explicitly defers plugin install to chezmoi externals (`dot_ansible/roles/zsh/defaults/main.yml:4-7`). Don't reintroduce plugin clones into ansible — they'd race with chezmoi.

## Currently active

| Plugin | Source | What it does | Loaded how |
|---|---|---|---|
| `git` | oh-my-zsh built-in | 200+ git aliases (`gst` `gco` `gp` `gcam`…) + helper functions (`git_main_branch`, `gccd`, `gunwipall`). Full catalog: [`docs/shells/aliases.md`](../shells/aliases.md) "Git" section. | Bundled in `~/.oh-my-zsh/plugins/git` |
| `zsh-autosuggestions` | [zsh-users/zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) | Fish-style inline ghost text from history (gray suggestion as you type; → or End to accept). | Custom plugin, cloned to `~/.oh-my-zsh/custom/plugins/` |
| `zsh-syntax-highlighting` | [zsh-users/zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting) | Colors command words as you type (green = valid command, red = invalid, etc.). | Custom plugin, cloned. |
| `zsh-vi-mode` | [jeffreytse/zsh-vi-mode](https://github.com/jeffreytse/zsh-vi-mode) | Modal editing (Esc → normal mode; vi keys for line editing). Gated on `enableVimMode` chezmoi prompt. | Custom plugin, cloned (only when `enableVimMode = true`). |
| `zsh-completions` | [zsh-users/zsh-completions](https://github.com/zsh-users/zsh-completions) | ~184 extra completion functions for tools without first-party support. | Cloned but **not** in `plugins=()` — added to `fpath` by `dot_zshrc.tmpl:69`. |

## Recommended additions (curated)

### Tier 1: Slot in cleanly (low risk, immediate win)

| Plugin | What it does | Why for this setup | Conflict |
|---|---|---|---|
| **[fzf-tab](https://github.com/Aloxaf/fzf-tab)** | Replaces zsh's TAB completion menu with fzf popup + per-context preview (`git checkout <TAB>` → branch list with commit log preview). | Works for **every** compdef-based completion automatically — the 14 auto-gen upstream tools + 5 in-house CLIs (`fleet`/`mlf`/`pqsum`/`mi-router`/`x`) we just wired up all benefit zero-config. | Minor: needs `ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(fzf-tab-complete)` so autosuggestions doesn't ghost-text the fzf input. Documented in fzf-tab wiki. |
| **[colored-man-pages](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/colored-man-pages)** | Sets `LESS_TERMCAP_*` env vars so `man <cmd>` renders headings/keywords in color. ~15 lines, zero overhead. | Pairs naturally with starship/bat/etc. you're already using. | None known. |
| **[sudo](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/sudo)** | Press `Esc Esc` to prepend `sudo ` to the current line, or to the previous command if the line is empty. | Tiny convenience; you already escalate to sudo in `cas`/`cau`. | Esc Esc is unbound currently; safe. |
| **[dirhistory](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/dirhistory)** | `Alt+Left`/`Alt+Right` navigate cd history (back/forward); `Alt+Up`/`Alt+Down` parent/child. | Fits the existing Alt+ namespace muscle memory (Alt+P for tv files, Alt+R for atuin, etc.). | Alt+Left/Right/Up/Down currently unbound — safe. Verify in iTerm/Ghostty: some terminals send escape codes that Alt-arrows can't catch (Option+arrow on macOS). |

### Tier 2: Consider with care (real trade-offs)

| Plugin | Trade-off |
|---|---|
| **[fast-syntax-highlighting](https://github.com/zdharma-continuum/fast-syntax-highlighting)** | Fork of zsh-syntax-highlighting — faster on long buffers (300ms+ savings), more themes (`fast-theme zdharma`). Migration cost: swap entries in `.chezmoiexternal.toml.tmpl` + `plugins=()`. Risk: fork is community-maintained (zdharma-continuum is the post-zdharma resurrection — active but smaller team than zsh-users). |
| **[command-not-found](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/command-not-found)** | When you type an unknown command, suggests the package to install. Linux: relies on `command-not-found` apt package (smooth). macOS: needs `brew tap homebrew/command-not-found` + indexing (less smooth). |
| **[alias-finder](https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/alias-finder)** / **[you-should-use](https://github.com/MichaelAquilina/zsh-you-should-use)** | Discovery aid: when you type a long form (`git status`), tells you there's an alias (`gst`). `alias-finder` runs every prompt (more spammy); `you-should-use` only after the long form was actually run. Useful while learning the OMZ git plugin's 200+ aliases; turn off once internalized. |
| **[history-substring-search](https://github.com/zsh-users/zsh-history-substring-search)** | Up/Down on the empty prompt search by current buffer prefix (Fish-like). **But** atuin already binds Alt+R for fuzzy history, and zsh-vi-mode rebinds `k`/`j` in normal mode for line-editing — both fight Up/Down semantics. If you really want this UX, atuin's `--inline-height` mode is the integrated alternative. |
| **[forgit](https://github.com/wfxr/forgit)** | fzf-driven git UI (`ga` interactive add, `glo` interactive log, `grh` interactive reset). Overlaps with `lazygit` (already used). Pick one mental model. |

### Tier 3: Skip for this setup (already covered)

| Plugin | Why skip |
|---|---|
| `z` / `autojump` | `zoxide` already does this (`dot_config/shell/20_zoxide.sh`) and is faster + multi-shell. |
| `fzf` (the OMZ plugin) | We `eval "$(fzf --zsh)"` ourselves in `dot_config/shell/10_fzf.sh` — gives same Ctrl+T/R, Alt+C, `**<TAB>` triggers without OMZ wrapping. |
| `gh` / `docker` / `kubectl` / `terraform` | Each tool's first-party completion is better — covered by the auto-gen hook (`scripts/generate_completions.sh`) for installed ones. |
| `gitfast` | Replaces git completion with bash-completion-shipped script. We already get richer completion via the OMZ git plugin + fpath. |
| `extract` | Useful for power users who deal with mixed archives, but `dot_config/shell/29_media.sh` doesn't cover archives — could add as Tier 1 if you actually want it. |

## TAB display upgrades — alternatives evaluated

`fzf-tab` is the obvious upgrade for this repo (Tier 1 above). Other options considered and rejected:

| Tool | What | Why not | Status |
|---|---|---|---|
| **[fzf-tab](https://github.com/Aloxaf/fzf-tab)** | OMZ-style plugin; replaces zsh's compsys list display with fzf popup + previews | — | ⭐ recommended |
| **[zsh-autocomplete](https://github.com/marlonrichert/zsh-autocomplete)** | Fish-style "as-you-type" auto-suggestions menu (async) | Heavy ZLE conflicts with `zsh-autosuggestions` and `zsh-vi-mode` (all three want Up/Down/Tab/Enter). Author warns about the conflicts in README. | skip |
| **[carapace-bin](https://github.com/carapace-sh/carapace-bin)** | Universal completion engine — one binary generates spec-driven completion for 1000+ tools, multi-shell (zsh / bash / fish / pwsh / nushell) | Would override the hand-written `_fleet` / `_mlf` / `_mi-router` / `_pqsum` / `_x` we just shipped (carapace's "macros" don't know about in-house CLIs without YAML spec files). Still active dev — breaking changes are expected. | skip for now (re-evaluate if it ships fzf-tab-style preview natively) |
| **[inshellisense](https://github.com/microsoft/inshellisense)** | Microsoft's port of Fig's autocomplete; subprocess-based, multi-shell | Not native ZLE — runs in a separate process. Heavier than ZLE-native tools. Cool tech, wrong abstraction layer for this repo. | skip |

### Bash side

`ble.sh` (already in `.chezmoiexternal.toml.tmpl:105-112`, init order documented in [`docs/shells/bash.md`](../shells/bash.md)) provides the bash equivalent of OMZ's autosuggestions + syntax-highlighting + vi-mode. Plus ble.sh has [native fzf integration](https://github.com/akinomyoga/ble.sh/wiki/Manual-§-Completion#fzf) for menu filtering — gives ~70% of fzf-tab's UX without a separate plugin. No bash-side equivalent install needed if you adopt fzf-tab on the zsh side.

## Adding a new plugin

For a custom plugin (anything not built into oh-my-zsh):

1. **Add an external** to `.chezmoiexternal.toml.tmpl` — copy an existing entry (e.g. `zsh-autosuggestions`), change the URL + path. Must clone under `.oh-my-zsh/custom/plugins/<name>/` for OMZ to pick it up.
2. **Add to `plugins=()`** in `dot_zshrc.tmpl:21-28`. Order matters for some pairs — `zsh-syntax-highlighting` MUST be the last one loaded if you keep it (per upstream README); `fast-syntax-highlighting` has no such constraint.
3. **Apply**: `chezmoi apply --refresh-externals` clones the new plugin and re-renders `~/.zshrc`.
4. **Reload**: `exec zsh` or open a new terminal.

For an OMZ built-in plugin (lives in `~/.oh-my-zsh/plugins/<name>/`): skip step 1 — just add to `plugins=()`.

For a plugin that DOESN'T fit OMZ's structure (standalone repo with `<name>.zsh` at root, e.g. fzf-tab): clone to `.oh-my-zsh/custom/plugins/<name>/`, then add `<name>` to `plugins=()`. OMZ's loader sources `<name>.plugin.zsh` first, falling back to `<name>.zsh`. fzf-tab ships `fzf-tab.plugin.zsh` so it works as-is.

## Removing a plugin

1. Drop the entry from `plugins=()` in `dot_zshrc.tmpl`.
2. Remove the external block from `.chezmoiexternal.toml.tmpl` (otherwise chezmoi keeps `git pull`-ing it weekly).
3. `chezmoi apply` deploys the new `~/.zshrc`. The orphan plugin clone under `~/.oh-my-zsh/custom/plugins/<name>/` stays — `rm -rf` manually if you want to reclaim disk.
