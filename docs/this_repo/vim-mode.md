# Vim mode in this dotfiles repo

Catalog of every place vim-style modal editing or vim-flavored navigation
is wired into this dotfiles repo, gated by a single chezmoi prompt
`enableVimMode` (default `true`).

## TL;DR

- Default: **`enableVimMode = true`** — zsh / bash / tmux all behave the
  same as before this flag was introduced.
- Set `false` (e.g. for non-vim friends, CI, the `minimal` Docker bundle)
  → modal editing in shells off, vim-tmux-navigator off, copy-mode goes
  emacs.
- **Neovim is never affected**, regardless of the flag. Neovim is
  inherently vim and stays so.
- **Editor configs (VSCode/Cursor/Antigravity/Codex/OpenCode/Cursor-CLI)
  are never affected** — this repo doesn't manage their vim-mode
  extensions.
- Re-prompt: `chezmoi init --force` (re-asks every prompt) or
  `chezmoi execute-template '{{ promptBoolOnce . "enableVimMode" "..." true }}'`
  for one-off testing. The full prompt text is in
  [`.chezmoi.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoi.toml.tmpl).

## Scope: what's gated, what's not

| Surface | `enableVimMode = true` (default) | `enableVimMode = false` |
|---|---|---|
| zsh OMZ plugins | includes `zsh-vi-mode` | omits `zsh-vi-mode` |
| `~/.oh-my-zsh/custom/plugins/zsh-vi-mode` git clone | cloned (chezmoi external) | not cloned |
| zsh `zvm_after_init` rebind block | defined | omitted (no plugin to wipe keymaps → unnecessary) |
| bash `set -o vi` (`05_vi_mode.bash`) | runs | replaced with no-op `:` |
| ble.sh `ble-bind` keymap (`04_blesh.bash`) | `-m vi_imap` / `-m vi_nmap` | default keymap (emacs) |
| tmux `mode-keys` (`common.conf`) | `vi` | `emacs` |
| tmux copy-mode bindings (`keybindings.conf`) | bound on `copy-mode-vi` table | bound on `copy-mode` table (same actions) |
| tmux vim-tmux-navigator (`Ctrl+h/j/k/l` root) | bound | unbound (frees `Ctrl+L` clear, `Ctrl+H` backspace, etc. for inner apps) |
| tmux `prefix + h/j/k/l` pane select | bound | **bound** (kept — prefix-gated, no conflict; vim-letter shortcut is harmless for non-vim users) |
| tmux `prefix + H/J/K/L` resize 5 cells | bound | **bound** (kept) |
| tmux `prefix + M-h/j/k/l` fine resize | bound | **bound** (kept) |
| marimo `[keymap] preset` (`create_marimo.toml`) | `vim` | `default` (FRESH installs only — `create_` prefix means the file is seeded once and never re-touched) |
| btop `vim_keys` (`create_btop.conf`) | `True` | `False` (FRESH installs only — `create_` prefix means the file is seeded once and never re-touched) |
| superfile `hotkeys.toml` (`dot_config/superfile/`) | yazi-parity vim preset (`j`/`k` nav, `y`/`x`/`p`/`d` file ops, `h` parent, `l`/Enter open, `q` quit, `a` create, `r` rename, `v` panel mode, `?` help) — adapted from upstream `vimHotkeys.toml` with `q`/`esc` quit, `h`/`←`/`backspace` parent, `right`/`l` confirm, `v` panel-mode kept | upstream default preset (`ctrl+c`/`ctrl+x`/`ctrl+v` file ops, single-letter focus keys `m`/`p`/`s`) |
| VisiData `~/.visidatarc` (`dot_visidatarc.tmpl`) | INSERT mnemonic: `i` → `edit-cell` (additive — `e` still works); column nav: `0` / `$` / `_` / `^` → `go-leftmost` / `go-rightmost` (mirrors vim line-internal chars); displaced commands relocated to `z$` (type-currency), `zw` (resize-col-max), `zN` (rename-col) | no rebind — `i` stays bound to `addcol-incr`; `$` / `_` / `^` keep their VisiData defaults (`type-currency`, `resize-col-max`, `rename-col`); `gh`/`gl` remain the canonical column-jump keystrokes |
| Neovim (`dot_config/nvim/`) | unchanged | **unchanged** (out of scope by design) |
| VSCode / Cursor / Antigravity vim extension | not managed | **not managed** (out of scope) |
| Codex / OpenCode / Cursor-CLI vim mode | not managed | **not managed** (out of scope) |

## The gate: `enableVimMode` chezmoi prompt

Defined in [`.chezmoi.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoi.toml.tmpl)
near the `primaryShell` line. The exact prompt text is reproduced below
because **`chezmoi init --promptBool` matches by full prompt text, not
by key**, so it must be byte-identical across `.chezmoi.toml.tmpl`,
`Dockerfile`, and `scripts/init/dotfiles_init.py PROMPTS`:

```
Enable vim-style modal editing in shells (zsh-vi-mode, set -o vi,
ble.sh vi-mode) and tmux vim navigation (vim-tmux-navigator
C-h/j/k/l, mode-keys vi); does NOT affect Neovim
```

The "does NOT affect Neovim" tail is deliberate — it's there so the
prompt itself reassures vim-fluent users who'd otherwise hesitate to
opt out for fear of losing their editor.

**Three-file rule**: any new chezmoi prompt must be added to
`.chezmoi.toml.tmpl` + `Dockerfile` ARG + `dotfiles_init.py PROMPTS`
in the same commit. `enableVimMode` follows that rule. Verify with:

```bash
uv run --script scripts/init/dotfiles_init.py doctor
```

(Note: pre-existing `installTunnelTools` drift in the script/Dockerfile
is unrelated to this prompt and tracked separately.)

**Bundle behavior** (`scripts/init/dotfiles_init.py BUNDLES`):

- `personal-mac`, `work-mac`, `server-linux`, `custom` — fall through
  to default `True` (vim mode on).
- `minimal` — explicitly forces `enableVimMode = False` because CI /
  Docker doesn't benefit from modal editing and emacs-keymap shells
  match what most automation expects.

## Catalog: every vim touch-point in the repo

### Shell layer

#### zsh — `zsh-vi-mode` plugin

**File**: [`dot_zshrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_zshrc.tmpl)
lines ~21–53.

The plugin (`jeffreytse/zsh-vi-mode`) is added to OMZ's plugin array,
and a `zvm_after_init` hook re-applies fzf / atuin (`Alt+R`) /
aisuggest (`Alt+;`) / keys-picker (`Alt+/`) bindings across `viins`,
`vicmd`, and `emacs` keymaps. The hook exists because zsh-vi-mode
**wipes all keymaps on init** — without re-binding, `Ctrl+R` would
stop launching atuin etc.

When `enableVimMode = false`, both the plugin entry and the
`zvm_after_init` block are gated out. The picker tools
(`dot_config/zsh/tools/{05_aisuggest,11_tools_picker,12_television,13_keys_picker,22_sesh}.zsh`)
each call `bindkey -M emacs` at source-time, so without the wiping
plugin those bindings stick on first source — no rebind hook needed.

**External clone**: [`.chezmoiexternal.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/.chezmoiexternal.toml.tmpl)
lines ~55–62 — the `git-repo` entry that clones the plugin into
`~/.oh-my-zsh/custom/plugins/zsh-vi-mode` is also gated, saving a
network round-trip on opt-out hosts.

**Harmless leftovers** (intentionally not gated): the `bindkey -M viins`
/ `bindkey -M vicmd` lines inside the picker tool files are no-ops when
zsh-vi-mode isn't loaded — keeping them avoids cluttering each tool
file with another conditional.

#### bash — `set -o vi` + ble.sh vi keymap

**Files**:
[`dot_config/bash/05_vi_mode.bash.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/bash/05_vi_mode.bash.tmpl) (single `set -o vi` line),
[`dot_config/bash/04_blesh.bash.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/bash/04_blesh.bash.tmpl) (vi-mode-aware ble.sh tweaks).

`set -o vi` is **the trigger** for ble.sh's vi-mode (ble.sh auto-detects
readline vi mode at attach time). When opted out:

- `05_vi_mode.bash.tmpl` body becomes `:` (no-op) → readline stays in
  default emacs keymap, ble.sh stays in default keymap.
- `04_blesh.bash.tmpl` swaps the four `ble-bind -m vi_imap`/`vi_nmap`
  calls (`C-RET` / `S-RET` accept-line, `C-c` discard-line) to plain
  `ble-bind` (binds in current/emacs keymap), so multi-line submit and
  Ctrl+C cancel still work the way zsh users expect.

**Why both files were renamed to `.tmpl`**: `dot_config/bash/` is
otherwise a non-templated drop-in directory loaded by
`load_modular_dir` from `dot_bashrc.tmpl`. Adding `.tmpl` to specific
files lets chezmoi process the `{{ if .enableVimMode }}` blocks while
the rest of the `*.bash` files in the dir stay verbatim. chezmoi
deploys the templated file at `~/.config/bash/04_blesh.bash` (suffix
stripped) — same target path, same load order.

**Out of scope**: oh-my-bash plugins are loaded by name from `OSH_PLUGINS`
in [`dot_bashrc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_bashrc.tmpl);
none of the loaded plugins are vim-mode-related (the `vi-mode` OMB
plugin is intentionally *not* loaded — ble.sh's vi-mode is much
better when it's on, and `set -o vi` is enough when ble.sh isn't).

### Multiplexer layer

#### tmux — `mode-keys vi` + `copy-mode-vi` table

**Files**:
[`dot_config/tmux/common.conf.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/tmux/common.conf.tmpl) (line ~68: `mode-keys`),
[`dot_config/tmux/keybindings.conf.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/tmux/keybindings.conf.tmpl)
(lines ~98–120: `copy-mode-vi` table bindings).

Both files renamed to `.tmpl` — same target path on apply.

`mode-keys` selects the table tmux's copy-mode dispatches keys against:

- `vi` table (`copy-mode-vi`): `h/j/k/l` cursor, `v` begin-selection,
  `V` line-select, `C-v` rectangle-toggle, `y` copy-and-cancel,
  `gg` / `G` top/bottom, `/` / `?` search.
- `emacs` table (`copy-mode`): `Ctrl+B`/`Ctrl+F`/`Ctrl+N`/`Ctrl+P`
  cursor, `Space` begin-selection, `Meta+w` copy.

Custom bindings in this repo (`v`, `V`, `C-v`, `y`,
`MouseDragEnd1Pane`, `DoubleClick1Pane`, `{` / `}` previous/next
prompt, `M-[` / `M-]` previous/next output) are templated to bind
under the **active table** based on `enableVimMode`:

```
{{- $copyTable := "copy-mode" -}}
{{- if .enableVimMode -}}{{ $copyTable = "copy-mode-vi" }}{{- end }}
bind -T {{ $copyTable }} v send-keys -X begin-selection
...
```

The `send-keys -X begin-selection` action itself is table-agnostic, so
the same five lines work for both tables. The `prefix + M-y` / `M-i`
macros at lines ~147–165 (Warp-style copy-last-output / copy-last-input)
are **not** templated — they use `send-keys -X previous-prompt` /
`next-prompt` which work regardless of `mode-keys`.

#### tmux — vim-tmux-navigator (root-table `Ctrl+h/j/k/l`)

**File**: [`dot_config/tmux/keybindings.conf.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/tmux/keybindings.conf.tmpl) lines ~181–192.

Implements the [christoomey/vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator)
contract via `bind-key -n` (root-table, no prefix) on `Ctrl+h/j/k/l`:
`is_vim` heuristic forwards the key to the inner pane if it's running
vim/nvim, otherwise calls `select-pane -L/-D/-U/-R`. Plus 4 mirrors on
the `copy-mode-vi` table so the same nav works while in copy-mode.

When `enableVimMode = false`, the entire 12-line block is omitted.
Consequence: `Ctrl+L` reaches the inner shell again (clears the
screen), `Ctrl+H` reaches readline as backspace, `Ctrl+J` is back to
LF (newline), `Ctrl+K` is back to readline's kill-line. **For
non-vim users this is the more conventional behavior**.

Pane navigation is still possible via `prefix + h/j/k/l` (kept, see
next section) or `prefix + Arrow` (tmux default).

**Documentation cross-link**: [`dot_config/television/config.toml`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/television/config.toml)
removes its built-in `Ctrl+J/K` bindings to avoid conflict with
vim-tmux-navigator. That removal is **kept regardless of
`enableVimMode`** — vim-mode users would conflict, and non-vim users
don't lose anything because TV's `Ctrl+P/N` already handle next/prev.

#### tmux — vim-letter pane select / resize (NOT gated)

**File**: [`dot_config/tmux/keybindings.conf.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/tmux/keybindings.conf.tmpl) lines ~171–208.

Three blocks are **NOT gated** by `enableVimMode`:

- `prefix + h/j/k/l` → `select-pane -L/-D/-U/-R` (pane select)
- `prefix + H/J/K/L` → `resize-pane -L/-D/-U/-R 5` (resize 5 cells, repeatable)
- `prefix + M-h/j/k/l` → `resize-pane -L/-D/-U/-R 1` (fine resize, repeatable)

Rationale: all three are prefix-gated, so they don't shadow anything
for non-vim users. They're "vim-letter shortcuts" but don't get in
anyone's way. Removing them would force non-vim users into
`prefix + Arrow`, which works but loses muscle-memory parity for users
who *do* know vim. Kept by deliberate decision.

If you do want them gone too, edit `keybindings.conf.tmpl` and wrap
those three blocks in `{{ if .enableVimMode }}…{{ end }}`. The tmux
defaults `prefix + Arrow` for select and `prefix + Ctrl-Arrow` for
resize will take over.

### Editor layer (none of these are gated)

By design, **no editor's vim mode is gated** by `enableVimMode`. This
keeps the flag's meaning unambiguous: shells + tmux only.

| Editor | What this repo manages | Vim mode? |
|---|---|---|
| Neovim (`dot_config/nvim/`) | LazyVim distro, lazy-lock, plugins, options | inherently vim — never disabled |
| VSCode (`.chezmoitemplates/editor/overlay.json` → various `dot_config/*/User/settings.json`) | font, line numbers, format-on-save | not managed; install `vscodevim.vim` extension manually if wanted |
| Cursor / Antigravity | same overlay as VSCode | not managed |
| Codex (`dot_codex/modify_config.toml.tmpl`) | model + tools settings | no vim-mode key managed |
| OpenCode (`dot_config/opencode/modify_*.json.tmpl`) | provider, leader key | no vim-mode key managed |
| Cursor-CLI (`dot_cursor/modify_cli-config.json`) | provider, defaults | no vim-mode key managed |

`editor.lineNumbers: "relative"` in the shared editor overlay is
vim-flavored display but not vim mode — kept regardless.

**If you want VSCode-style vim** on opt-out machines, install the
`vscodevim.vim` extension manually. Don't try to gate it from this
repo's overlay — the overlay is shared across VSCode/Cursor/Antigravity
and the vim extension key would diverge between editors.

### App layer

#### marimo — `[keymap] preset = "vim"`

**File**: [`dot_config/marimo/create_marimo.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/marimo/create_marimo.toml.tmpl) line ~80.

Marimo (Python notebook web UI) supports `[keymap] preset = "vim"` or
`"default"`. Templated to pick based on `enableVimMode`:

```toml
[keymap]
destructive_delete = true
preset = "{{ if .enableVimMode }}vim{{ else }}default{{ end }}"
```

**Caveat — `create_` semantics**: this file uses chezmoi's `create_`
prefix, which means chezmoi only seeds the file **once** (when the
target doesn't exist). It never re-touches the contents. So:

- **Fresh install** → preset matches `enableVimMode` correctly.
- **Existing install** → preset stays whatever it was originally
  (probably `"vim"` since that was the historical default).

If you flip `enableVimMode = false` on an existing machine and want
marimo to switch too, hand-edit `~/.config/marimo/marimo.toml` or
delete it and run `chezmoi apply` (which will re-seed with the new
template result).

Why not `modify_` instead? Because marimo writes its own settings
(theme, recent files, snippet paths) into the same file via the web
UI, and a `modify_` script would have to reconcile those — overkill
for one keymap key.

#### btop — `vim_keys` gated on `enableVimMode`

**File**: [`dot_config/btop/create_btop.conf.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/btop/create_btop.conf.tmpl) line ~25.

btop (system monitor) exposes a `vim_keys` config key that enables
`h,j,k,l,g,G` directional control in its process / device lists
(the conflicting `h`→help and `k`→kill stay reachable with Shift).
Templated on `enableVimMode`:

```ini
vim_keys = {{ if .enableVimMode }}True{{ else }}False{{ end }}
```

**Caveat — `create_` semantics** (identical to marimo): the file is
seeded **once**; chezmoi never re-touches it, and btop rewrites the
whole config on every exit. Flipping `enableVimMode` later will
**not** re-flip `vim_keys` on an existing machine — delete
`~/.config/btop/btop.conf` and `chezmoi apply` to re-seed. Full
config notes: [btop](../tools/btop.md).

#### superfile — `hotkeys.toml` preset swap

**File**: [`dot_config/superfile/hotkeys.toml.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/superfile/hotkeys.toml.tmpl).

Superfile (`spf`) is a TUI file manager. There is no runtime
`vim_mode` flag in `config.toml` — upstream ships **two** separate
preset files (`hotkeys.toml` default, `vimHotkeys.toml`) and the
README literally says "If you are vim/nvim user please change your
default hotkeys config to vim version". The chezmoi template
swaps the full body based on `enableVimMode`:

- **`true`** → upstream `vimHotkeys.toml` body with four yazi-parity
  tweaks: `quit = ['q', 'esc']` (vs upstream vim `ctrl+c`),
  `parent_directory = ['h', 'left', 'backspace']` (vs upstream vim
  `-` only), `confirm = ['enter', 'right', 'l']` (vs upstream vim
  `enter` only), `change_panel_mode = ['v', '']` (vs upstream vim
  `m`). `close_file_panel` lands on `w` since `q` is reclaimed for
  quit.
- **`false`** → upstream `hotkeys.toml` verbatim. File ops are
  Ctrl-prefixed (`copy_items = ['ctrl+c', '']`,
  `paste_items = ['ctrl+v', 'ctrl+w', '']`); the default already
  includes `j`/`k`/`l`/`h` as *secondary* nav bindings, so non-vim
  users keep optional vim nav without disruptive single-letter
  file ops.

**Path note**: superfile honors `XDG_CONFIG_HOME` on macOS too
(verified via `spf pl` → `~/.config/superfile/hotkeys.toml`), so a
single source path under `dot_config/superfile/` covers macOS and
Linux. No `private_Library/private_Application Support/` branch
needed despite Go's `os.UserConfigDir()` defaulting to
`~/Library/Application Support` on Darwin — superfile resolves the
path itself.

**Forbidden bindings** (per upstream docs): `Ctrl+M` conflicts with
Enter, `Ctrl+I` with Tab, `Ctrl+?` / `Ctrl+[` with Delete/Backspace.
Both preset bodies in the template avoid these.

**Re-sync**: bodies pinned via comment to
`yorukot/superfile @ main` snapshot date. Re-fetch
`src/superfile_config/hotkeys.toml` + `vimHotkeys.toml` when
bumping.

#### VisiData

**File**: [`dot_visidatarc.tmpl`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_visidatarc.tmpl).

VisiData is **already heavily vim-flavored by default** — `h/j/k/l`
row/column navigation, `gg`/`G` top/bottom row, `gh`/`gl` leftmost/rightmost
column, `/`/`?` search, `n`/`N` next/prev match, `q`/`Q` quit are all
bound out of the box. The `enableVimMode` block in `dot_visidatarc.tmpl`
adds strict-vim parity on top of those defaults: the INSERT-mode mnemonic
(`i`) and the line-internal navigation characters (`0` / `$` / `_` / `^`).

##### INSERT mnemonic: `i` → `edit-cell`

From VisiData's own
[customize docs](https://www.visidata.org/docs/customize/#example-bind-i-to-edit-cell-globally) — rebind `i` from `addcol-incr` to `edit-cell`
so vim users get their INSERT-mode mnemonic on cell editing:

```python
TableSheet.unbindkey('i')
TableSheet.bindkey('i', 'edit-cell')
```

**Trade-off**: `addcol-incr` (add column with incrementing values,
[`visidata/features/incr.py:27`](https://github.com/saulpw/visidata/blob/main/visidata/features/incr.py))
loses its single-letter shortcut. Still reachable via
`Space addcol-incr<Enter>` or the `Alt+H` command menu. The related
`gi` / `zi` / `gzi` family (set-incr / step-incr variants) is
unaffected. Also `e` (the historical edit-cell binding) continues
to work — the gate is purely additive on the keystroke `i`.

##### Column navigation: full vim parity (`0` / `$` / `_` / `^`)

VisiData's defaults provide `gh` / `gl` for go-leftmost / go-rightmost
column (mirroring the `gg` / `G` row convention). The vim
line-internal navigation characters are not bound by default and three
of them displace useful single-letter VisiData commands. This block
binds all four and relocates the displaced commands to mnemonic 2-char
slots so nothing is lost:

| key | new action     | displaced from     | relocated to | mnemonic        |
| --- | -------------- | ------------------ | ------------ | --------------- |
| `0` | `go-leftmost`  | *(was unbound)*    | —            | vim default     |
| `$` | `go-rightmost` | `type-currency`    | `z$`         | `z` + same char |
| `_` | `go-leftmost`  | `resize-col-max`   | `zw`         | `z` + Width     |
| `^` | `go-leftmost`  | `rename-col`       | `zN`         | `z` + Name      |

The `z` prefix is VisiData's idiomatic "related-variant" namespace
(e.g. `_` = resize-col-max, `z_` = resize-col-input,
`gz_` = resize-cols-input) — picking 2-char slots from the same
namespace keeps the relocations discoverable. Verified-free pre-flight:
`vd.bindkeys._get('z$' | 'zw' | 'zN', obj=TableSheet)` returns `None`
before this rc loads, so we do not clobber any existing default. The
related families (`g_` = resize-cols-max, `g^` = rename-cols-row,
`z^` = rename-col-selected, `z$` etc.) keep their original bindings.

**Trade-off (be aware)**: `_` and `^` both alias to `go-leftmost` —
this differs from strict vim where `_` is "first non-blank of line"
and `^` is "first non-blank visible". VisiData has no analogue to
"first non-blank cell", so all three (`0` / `_` / `^`) collapse onto
the same semantic of "leftmost visible column". `gh` is the
non-overloaded canonical alias.

##### Data safety: read-only mode

For raw-data files you don't want to accidentally overwrite, open
VisiData via the `vd-ro` alias
([`dot_config/shell/10_aliases.sh`](https://github.com/daviddwlee84/dotfiles/blob/main/dot_config/shell/10_aliases.sh)):

```bash
vd-ro data.feather       # = visidata --readonly data.feather
vd-ro -f arrow data.csv  # combine with the ArrowSheet escape hatch
```

VisiData's protection model has three layers worth understanding:

1. **No auto-save, ever.** Edits live in deferred buffers
   (`Sheet._deferredAdds` / `_deferredMods` / `_deferredDels`,
   [`visidata/modify.py:37-47`](https://github.com/saulpw/visidata/blob/main/visidata/modify.py))
   until you explicitly press `Ctrl+S` (save-as, prompts for path) or
   `g Ctrl+S` (save back to source, prompts to confirm overwrite).
   Closing with `q` / `Q` / `gq` discards the buffer.
2. **`--readonly` blocks the save path.** `vd.optalias('readonly', 'overwrite', 'n')`
   ([`visidata/modify.py:11`](https://github.com/saulpw/visidata/blob/main/visidata/modify.py))
   makes `--readonly` an alias for `--overwrite=n`, which causes
   `confirmOverwrite()` to `fail('overwrite disabled')` on any save
   attempt. In-memory edits remain ALLOWED (so the deferred-tracking
   colorizers still work for prototyping), but the change cannot be
   written back. This is the layer `vd-ro` adds.
3. **Pair with `vd-arrow` for `.feather`.** `visidata --readonly -f arrow file.feather`
   gets you both the StringDtype workaround (pure-pyarrow loader,
   see [pitfall page](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/visidata-feather-stringdtype-numpy-dtype.md))
   and the save-block. The `dot_visidatarc.tmpl` reroute makes
   `-f arrow` redundant for `.feather` on managed hosts, but it's a
   useful belt for ad-hoc machines or `.arrow` inputs.

When NOT to use `--readonly`: when you actively want to script-edit
and write back (e.g. cleanup workflow). The shell alias is opt-in;
plain `visidata` still works as upstream.

##### Why no broader gating?

Other potential customizations
(`vd.editCellBindings['Enter'] = acceptThenFunc('go-down', 'edit-cell')`
for spreadsheet-style save-and-down, etc.) stray into spreadsheet
ergonomics rather than vim semantics. Add them per-user via
`~/.visidatarc` or a `$VD_DIR/plugins/` Python file if wanted, or open
a TODO to gate behind a different flag.

##### Why `~/.visidatarc` and not `~/.config/visidata/config.py`?

VisiData v2.9+ supports an XDG-located `config.py`, but
`appdirs.user_config_dir('visidata')` on Darwin returns
`~/Library/Preferences/visidata` (NOT `~/.config/visidata`), so a
Linux-style migration would silently fail on macOS. Migrating
correctly requires exporting `VD_CONFIG` / `VD_DIR` in
`dot_config/shell/00_exports.sh.tmpl`. Tracked as `[P3/S]` in
[`TODO.md`](https://github.com/daviddwlee84/dotfiles/blob/main/TODO.md);
full caveat:
[`pitfalls/visidata-feather-stringdtype-numpy-dtype.md → XDG path note`](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/visidata-feather-stringdtype-numpy-dtype.md).

#### Other tools

Spot-checked and confirmed **not** managed (or no vim keys present):

- `lazygit` (`dot_config/lazygit/config.yml`) — only sets the delta
  pager. No `keybindings:` block. Defaults are vim-flavored upstream
  but that's not in this repo's surface area.
- `yazi` (`dot_config/yazi/keymap.toml`) — empty stub, no managed
  keybindings.
- `lf`, `ranger`, `broot` — no configs in this repo.
- `fzf` (`dot_config/shell/10_fzf.sh`) — `FZF_DEFAULT_OPTS` has no
  `--bind` for vi keys; default emacs-style.
- `less`, `bat`, `delta` — no `LESS=…` vi-keys env, no managed
  `~/.lesskey`.
- `k9s`, `htop`, `lazydocker`, `gh-dash` — not managed by
  this repo. (`btop` **is** managed — see the btop subsection above.)
- `television` — global keymap is Ctrl-style; channel-specific
  configs use Alt+letter, no vi keys.
- `zellij` — uses `default_mode "locked"`, all keys pass through to
  inner apps; nothing to disable.
- `claude-code` (`~/.claude/keybindings.json` overlay) — uses Ctrl-style
  keys (`Ctrl+R`, `Ctrl+T`, `Ctrl+G`, `Ctrl+S`, `Shift+Tab`); no vim
  bindings managed.

If a future tool gains managed vim keybindings, add a row to the
catalog table above and update [`AGENTS.md`](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md)'s
"Hard repo invariant: `enableVimMode` gates shell + tmux vim, NOT
Neovim" section in the same commit.

## What happens when you flip `enableVimMode = false`

After `chezmoi apply`:

- `~/.zshrc` no longer contains `zsh-vi-mode` in `plugins=(...)` and
  the `zvm_after_init` block is gone.
- `~/.oh-my-zsh/custom/plugins/zsh-vi-mode/` is **not** cloned (the
  externals stanza is templated out — saves a network round-trip).
- `~/.config/bash/05_vi_mode.bash` body is `: # vim mode disabled by chezmoi enableVimMode=false`
  → readline + ble.sh stay in default emacs keymap.
- `~/.config/bash/04_blesh.bash` binds `Ctrl+RET` / `Shift+RET` /
  `Ctrl+C` on the default keymap (no `-m vi_imap` / `-m vi_nmap`).
- `~/.config/tmux/common.conf` has `setw -g mode-keys emacs`.
- `~/.config/tmux/keybindings.conf` has `bind -T copy-mode v send-keys -X begin-selection`
  (etc.) **and no `bind-key -n 'C-h' if-shell ...`** vim-tmux-navigator
  bindings.
- (FRESH installs only) `~/.config/marimo/marimo.toml` has
  `preset = "default"`.
- (FRESH installs only) `~/.config/btop/btop.conf` has
  `vim_keys = False`.
- `~/.config/superfile/hotkeys.toml` has upstream default body
  (Ctrl-prefixed file ops, `j`/`k`/`l`/`h` as secondary nav).
- `~/.visidatarc` has no `enableVimMode` block at all → all VisiData
  default keystrokes stay intact: `i` = `addcol-incr`, `$` =
  `type-currency`, `_` = `resize-col-max`, `^` = `rename-col`, `0`
  unbound. Use `e` to edit a cell and `gh`/`gl` for column-jump.
  The relocations (`z$`, `zw`, `zN`) are NOT installed either —
  they only exist as aliases when the vim block runs.

**Behavioral consequences inside tmux**:

- `Ctrl+L` clears the inner shell screen again (no longer captured
  by vim-tmux-navigator).
- `Ctrl+H` is backspace at the prompt.
- `Ctrl+J` is plain LF (newline).
- `Ctrl+K` is `kill-line` in readline (zle line-end-killer in zsh).
- Inside tmux copy-mode: `Space` starts selection, `Meta+w` copies,
  `Ctrl+B`/`Ctrl+F` move cursor — instead of `v`/`y`/`h`/`l`.
- Pane navigation: `prefix + h/j/k/l` still works (kept). Use
  `prefix + Arrow` if you don't want vim letters.

## How to opt out (existing install)

```bash
# Re-prompt for everything (you'll be asked enableVimMode plus ~22 others):
chezmoi init --force

# Or just edit the data file by hand:
$EDITOR ~/.config/chezmoi/chezmoi.toml
# change: enableVimMode = false
chezmoi apply

# Reload the active session(s):
exec zsh                # or: exec bash
tmux kill-server        # then start a fresh tmux
```

If you want a side-by-side preview of what would change before
committing to apply:

```bash
chezmoi diff             # shows everything
chezmoi diff dot_config/tmux dot_config/bash dot_zshrc \
             .chezmoiexternal.toml dot_config/marimo \
             dot_config/superfile
```

**Verify on a single host without affecting others**: this is the
ideal use of `just fleet-status` (read-only readiness probe per host)
and `just fleet-apply --hosts <one-host>` to roll out the change
gradually. See [`docs/this_repo/fleet-apply.md`](fleet-apply.md).

## How to opt back in

Same flow with the value flipped:

```bash
$EDITOR ~/.config/chezmoi/chezmoi.toml   # set enableVimMode = true
chezmoi apply
exec zsh
tmux kill-server
```

The first apply will:

- re-clone `zsh-vi-mode` into `~/.oh-my-zsh/custom/plugins/`
  (chezmoi external),
- re-add the plugin name to `~/.zshrc`,
- restore `set -o vi` in bash,
- swap tmux `mode-keys` back to `vi`,
- restore the 12 vim-tmux-navigator lines.

Marimo's `create_marimo.toml` will **not** auto-flip back — `create_`
files seed once. To force a re-seed, delete `~/.config/marimo/marimo.toml`
first, then `chezmoi apply`.

## For maintainers: adding a new vim-touched config

If you add a new app config that has a vim/emacs choice, decide first
whether it belongs under `enableVimMode`'s umbrella:

**Yes, gate it** if all of:

- It's a TUI / multiplexer / shell-adjacent tool (not a heavyweight
  GUI editor).
- A non-vim user would actively suffer if vim-mode is left on.
- The setting can be templated cleanly (i.e. the file is already
  `.tmpl` or it's reasonable to make it one).

Then:

1. Edit the relevant config to template the vim/emacs choice on
   `{{ if .enableVimMode }}` — rename the file to `.tmpl` if needed.
2. Add a row to the catalog table at the top of this doc.
3. Update the corresponding tool doc (e.g. `docs/tools/<tool>.md`) to
   note the gating.
4. If the gating is non-trivial (e.g. a `create_` file that won't
   auto-migrate), add a "Hard repo invariant" entry in
   [`AGENTS.md`](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md)
   under the existing "`enableVimMode` gates shell + tmux vim, NOT
   Neovim" section.

**No, leave it alone** if any of:

- It's an editor / IDE (VSCode, Cursor, Codex TUI, OpenCode TUI,
  Neovim) — separate concern, users may want vim in their editor
  even if they don't want it in their shell.
- The setting is buried in a `modify_` script that hand-merges live
  state — gating would risk corrupting user-edited keys.
- The default behavior is identical for vim and non-vim users (no
  conflict either way).

When in doubt: **don't gate**. The flag's semantic is "shells + tmux";
expanding it case-by-case keeps the contract clear.

## Cross-references

- [`docs/shells/keybindings.md`](../shells/keybindings.md) — full keybinding
  catalog for zsh / bash / shared keys-picker; notes which entries are
  conditional on `enableVimMode`.
- [`docs/shells/bash.md`](../shells/bash.md) — bash bootstrap with
  oh-my-bash + ble.sh; the vi-mode row in the bash-vs-zsh table is
  conditional.
- [`docs/shells/architecture.md`](../shells/architecture.md) — three-tier
  shell layout (`dot_config/{shell,zsh,bash}/`); explains why
  `04_blesh.bash` and `05_vi_mode.bash` were renamed to `.tmpl`.
- [`docs/shells/emacs-line-editing.md`](../shells/emacs-line-editing.md)
  — origin and must-know subset of emacs line editing; the
  go-to reference for `enableVimMode = false` users.
- [`docs/tools/tmux/README.md`](../tools/tmux/README.md) — tmux config
  overview; documents `mode-keys vi` is gated, copy-mode bindings
  switch table.
- [`docs/tools/tmux/keybindings.md`](../tools/tmux/keybindings.md) —
  full tmux keybinding table; vim-tmux-navigator row marked conditional.
- [`docs/tools/tmux/vim.md`](../tools/tmux/vim.md) — vim integration
  inside tmux (vim-tmux-navigator details, OSC 52 clipboard from vim).
- [`docs/tools/chezmoi-templating.md`](../tools/chezmoi-templating.md) —
  conventions for `.profile` vs `.chezmoi.os` vs feature-flag prompts.
- [`docs/tools/chezmoi-prefixes.md`](../tools/chezmoi-prefixes.md) —
  why `dot_config/marimo/create_marimo.toml.tmpl` won't auto-migrate
  on opt-in/opt-out flip (`create_` semantics).
- [`AGENTS.md`](https://github.com/daviddwlee84/dotfiles/blob/main/AGENTS.md)
  — agent-facing contract; "Hard repo invariant: `enableVimMode` gates
  shell + tmux vim, NOT Neovim" subsection.
