# Plan: Gate superfile `hotkeys.toml` under `enableVimMode`

## Context

`superfile` (`spf`, https://superfile.dev) is installed via `dot_ansible/roles/devtools/tasks/main.yml` (~line 2143–2298) but **its config files are not managed by chezmoi**. As a result, the repo's `enableVimMode` flag has no effect on superfile, and a fresh install lands the user on superfile's default keymap — which uses `ctrl+c`/`ctrl+x`/`ctrl+v` for file ops and reserves single letters for unrelated actions. The user's screenshot of superfile's first-run prompt ("If you are vim/nvim user please change your default hotkeys config to vim version") confirms this is the upstream-recommended swap path.

Superfile **honors `XDG_CONFIG_HOME` on macOS too** (verified by user's `spf pl`):

```
[Hotkeys file path]            /Users/daviddwlee84/.config/superfile/hotkeys.toml
[Configuration directory path] /Users/daviddwlee84/.config/superfile
```

So a single source path under `dot_config/superfile/` covers both macOS and Linux — no `private_Library/` branch needed.

This change qualifies as **"Yes, gate it"** per [`docs/this_repo/vim-mode.md` → "For maintainers"](../../docs/this_repo/vim-mode.md): TUI file manager (not editor), non-vim users actively suffer if `y`/`x`/`p`/`d` are bound to file ops, templatable cleanly.

## Approach

**Single new template** at `dot_config/superfile/hotkeys.toml.tmpl` with two verbatim bodies branched by `{{ if .enableVimMode }}`:

- **`enableVimMode = true`**: upstream `vimHotkeys.toml` body **with four user-requested tweaks** for yazi-parity muscle memory (see body sketch below).
- **`enableVimMode = false`**: upstream `hotkeys.toml` body **verbatim** (the default already includes `j`/`k` as secondary nav, so non-vim users keep optional vim navigation but lose the disruptive single-letter file ops).

Mechanism for switching is upstream-blessed: superfile's README literally says "change your default hotkeys config to vim version" — there is no `vim_mode` flag in `config.toml`, you swap file contents. Perfect fit for chezmoi conditional templating. No `modify_` script needed — full overwrite semantics is correct here; user hand-edits would conflict-prompt on apply (expected behavior for a gated preset).

`config.toml` (non-hotkey settings: editor path, sort options, image preview, etc.) is **intentionally out of scope** — user only asked about vim-mode hotkeys.

## Files

### Create

- `dot_config/superfile/hotkeys.toml.tmpl` — sketch below.

### Update

- `docs/this_repo/vim-mode.md` — add a row to the catalog table (line ~26–42) and mention superfile in the "Cross-references" section.
- `CLAUDE.md` (the "`enableVimMode` gates shell + tmux vim, NOT Neovim or editors" invariant): bump the count from **"6 gated templated files + 1 first-seed `marimo.toml`"** → **"7 gated templated files + 1 first-seed `marimo.toml`"**. Also update the `AGENTS.md`/`GEMINI.md` mirrors automatically since they are symlinks (per CLAUDE.md "edit one").
- (Optional, mention only) `README.md` — superfile is already in the dev-tools inventory; no new line needed.

## Template body sketch

Top-of-file comment cites upstream + sync date so future bumps are mechanical:

```toml
{{- /* Managed by chezmoi (dotfiles repo). Hand edits will be overwritten.
       enableVimMode = {{ .enableVimMode }} — superfile hotkeys.

       Sources (yorukot/superfile @ main, snapshot 2026-05-13):
         - default: src/superfile_config/hotkeys.toml
         - vim:     src/superfile_config/vimHotkeys.toml
       Re-sync manually by re-fetching the two files above; no scripts/upgrade_* category for this yet.

       Forbidden bindings (per upstream docs):
         ctrl+m (Enter), ctrl+i (Tab), ctrl+? / ctrl+[ (Delete/Backspace) */ -}}
{{ if .enableVimMode -}}
#-- Basic Actions
confirm = ['enter', 'right', 'l']             # tweak: keep right/l (default secondaries) vs upstream vim ['enter', '']
quit = ['q', 'esc']                           # tweak: keep q/esc vs upstream vim ['ctrl+c', '']
cd_quit = ['Q', '']

#-- Navigation
list_up = ['k', '']
list_down = ['j', '']
page_up = ['pgup', '']
page_down = ['pgdown', '']

#-- File Panel Controls
create_new_file_panel = ['n', '']
close_file_panel = ['w', '']                  # moved to w (since q now means quit; upstream vim used q here)
next_file_panel = ['tab', '']
previous_file_panel = ['shift+tab', '']
split_file_panel = ['N', '']
toggle_file_preview_panel = ['f', '']
open_sort_options_menu = ['o', '']
toggle_reverse_sort = ['R', '']

#-- Focus Manipulation
focus_on_process_bar = ['ctrl+p', '']
focus_on_sidebar = ['ctrl+s', '']
focus_on_metadata = ['ctrl+d', '']

#-- File/Dir Creation/Renaming
file_panel_item_create = ['a', '']
file_panel_item_rename = ['r', '']

#-- Main File Operations
copy_items = ['y', '']
cut_items = ['x', '']
paste_items = ['p', '']
delete_items = ['d', '']
permanently_delete_items = ['D', '']

#-- Archive Manipulation
extract_file = ['ctrl+e', '']
compress_file = ['ctrl+a', '']

#-- Editor Actions
open_file_with_editor = ['e', '']
open_current_directory_with_editor = ['E', '']

#-- Other Actions
pinned_directory = ['P', '']
toggle_dot_file = ['.', '']
change_panel_mode = ['v', '']                 # tweak: keep v (default) vs upstream vim 'm'
open_help_menu = ['?', '']
open_spf_prompt = ['>', '']
open_command_line = [':', '']
open_zoxide = ['z', '']
copy_path = ['Y', '']
copy_present_working_directory = ['c', '']
toggle_footer = ['ctrl+f', '']

# Typing
confirm_typing = ['enter', '']
cancel_typing = ['esc', '']

# Normal Mode
parent_directory = ['h', 'left', 'backspace'] # tweak: keep default secondaries vs upstream vim ['-', '']
search_bar = ['/', '']

# Selection Mode
file_panel_select_mode_items_select_down = ['J', '']
file_panel_select_mode_items_select_up = ['K', '']
file_panel_select_all_items = ['A', '']
{{- else -}}
# enableVimMode = false → upstream default hotkeys.toml verbatim.
# (Default already includes j/k/l/h as *secondary* bindings on navigation,
#  so non-vim users still get optional vim-style nav, just without single-letter file ops.)

#-- Basic Actions
confirm = ['enter', 'right', 'l']
cd_quit = ['Q', '']
quit = ['q', 'esc']

#-- Navigation
list_down = ['down', 'j']
list_up = ['up', 'k']
page_down = ['pgdown', '']
page_up = ['pgup', '']

#-- File Panel Controls
close_file_panel = ['w', '']
create_new_file_panel = ['n', '']
next_file_panel = ['tab', 'L']
open_sort_options_menu = ['o', '']
pinned_directory = ['P', '']
previous_file_panel = ['shift+left', 'H']
split_file_panel = ['N', '']
toggle_file_preview_panel = ['f', '']
toggle_reverse_sort = ['R', '']

#-- Focus Manipulation
focus_on_metadata = ['m', '']
focus_on_process_bar = ['p', '']
focus_on_sidebar = ['s', '']

#-- File/Dir Creation/Renaming
file_panel_item_create = ['ctrl+n', '']
file_panel_item_rename = ['ctrl+r', '']

#-- Main File Operations
copy_items = ['ctrl+c', '']
cut_items = ['ctrl+x', '']
delete_items = ['ctrl+d', 'delete', '']
paste_items = ['ctrl+v', 'ctrl+w', '']
permanently_delete_items = ['D', '']

#-- Archive Manipulation
compress_file = ['ctrl+a', '']
extract_file = ['ctrl+e', '']

#-- Editor Actions
open_current_directory_with_editor = ['E', '']
open_file_with_editor = ['e', '']

#-- Other Actions
change_panel_mode = ['v', '']
copy_path = ['ctrl+p', '']
copy_present_working_directory = ['c', '']
open_command_line = [':', '']
open_help_menu = ['?', '']
open_spf_prompt = ['>', '']
open_zoxide = ['z', '']
toggle_dot_file = ['.', '']
toggle_footer = ['F', '']

# Typing
confirm_typing = ['enter', '']
cancel_typing = ['ctrl+c', 'esc']

# Normal Mode
parent_directory = ['h', 'left', 'backspace']
search_bar = ['/', '']

# Selection Mode
file_panel_select_mode_items_select_down = ['shift+down', 'J']
file_panel_select_mode_items_select_up = ['shift+up', 'K']
file_panel_select_all_items = ['A', '']
{{- end }}
```

## Catalog row for `docs/this_repo/vim-mode.md`

Inserted between the marimo row and the Neovim row in the existing table:

```markdown
| superfile `hotkeys.toml` (`dot_config/superfile/`) | yazi-parity vim preset (j/k nav, y/x/p/d file ops, `h` parent, `l`/Enter open, `q` quit, `a` create, `r` rename, `v` panel mode, `?` help) | upstream default preset (Ctrl-prefixed file ops, single-letter focus keys) |
```

Plus a new bullet in the "Cross-references" list at the bottom:

```markdown
- [`docs/tools/superfile.md`](../tools/superfile.md) — superfile config notes; documents the vim/default preset swap mechanism (no runtime `vim_mode` flag in `config.toml` — gated by overwriting `hotkeys.toml` body).
```

(The cross-ref link assumes we'd at some point add `docs/tools/superfile.md`. If not creating that file in this PR, drop the bullet.)

## CLAUDE.md edit

In the "`enableVimMode` gates shell + tmux vim, NOT Neovim or editors" section, change:

> Full catalog of the **6** gated templated files + 1 first-seed `marimo.toml`: …

to:

> Full catalog of the **7** gated templated files + 1 first-seed `marimo.toml`: …

No other CLAUDE.md changes — no new hard invariant needed; this gating is mechanically identical to the existing tmux pattern.

## Verification

1. **Lint the template**:
   ```bash
   chezmoi execute-template < dot_config/superfile/hotkeys.toml.tmpl | head -20
   ```
   (Should render the vim body since `enableVimMode = true` is current default.)

2. **TOML syntax check** on rendered output:
   ```bash
   chezmoi execute-template < dot_config/superfile/hotkeys.toml.tmpl | taplo check -
   ```
   (Per CLAUDE.md "Validate app configs with the app, not just syntax": taplo syntax alone is insufficient, but it catches the easy class of errors.)

3. **App-level validation**:
   ```bash
   chezmoi apply --include='dot_config/superfile/**'
   spf pl                 # confirms hotkeys file path is the one we just wrote
   spf                    # smoke: launch, test j/k nav, l to enter, h to go up, q to quit
   ```
   Then in spf: copy a test file with `y`, paste with `p`, delete with `d` (recoverable trash), confirm `?` opens help, `:` opens command line.

4. **Flip the flag and re-verify**:
   ```bash
   # Render the false branch without changing chezmoi state:
   chezmoi execute-template --init --promptBool enableVimMode=false < dot_config/superfile/hotkeys.toml.tmpl | head -30
   ```
   Confirm the body shows `copy_items = ['ctrl+c', '']` and `file_panel_item_create = ['ctrl+n', '']` (default-preset markers).

5. **Docs build**:
   ```bash
   uv run mkdocs build --strict
   ```
   (catches anchor drift after editing `vim-mode.md`.)

6. **Mirror check** for the CLAUDE.md edit:
   ```bash
   ls -la AGENTS.md GEMINI.md   # both should be symlinks to CLAUDE.md, so single edit propagates
   ```

## Out of scope (deliberate)

- `dot_config/superfile/config.toml` — not managed. Settings like `editor`, `default_sort_type`, `nerdfont`, `theme` deserve a separate pass if/when the user asks.
- `dot_config/superfile/theme/` — same reasoning.
- No `scripts/upgrade_*` category for superfile config sync — manual fetch from upstream when bumping. Note left in template top comment.
- No new chezmoi prompt — `enableVimMode` already exists; just hooking a new file under it.
