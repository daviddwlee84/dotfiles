# Superfile hotkey research — findings

Read-only investigation; no edits made. Sources at end.

## a) Where `hotkeys.toml` lives on disk

Confirmed via official docs page `configure/config-file-path` (source: `website/src/content/docs/configure/config-file-path.mdx`):

| Platform | Path |
|---|---|
| Linux | `~/.config/superfile/hotkeys.toml` |
| macOS | `~/Library/Application Support/superfile/hotkeys.toml` |
| Windows | `%LOCALAPPDATA%/superfile/hotkeys.toml` |

**macOS is NOT XDG** — it uses Apple's `Application Support` dir, not `~/.config/superfile/`. This matters for the chezmoi template target path. Config dir is OS-resolved (Go's `os.UserConfigDir()` semantics).

Override flag exists: `spf --hotkey-file /path/to/hotkeys.toml` (and `-c`/`--config-file` for `config.toml`). `spf pl` prints all resolved paths on the running host.

Companion files in the same directory: `config.toml`, `theme/` subdir.

## b) TOML structure

**Flat top-level table with section comments**, NOT sectioned TOML tables (except a trailing `[open_with]` table in `config.toml`, unrelated). Each action maps to a **list of key strings**, where every action accepts exactly two slots — the second can be `''` (empty string) for "no second binding". Some actions take three (e.g. `delete_items`, `paste_items`, `parent_directory`).

Three comment-delimited sections in `hotkeys.toml`:

1. **Global hotkeys** — must be unique repo-wide (Basic Actions, Navigation, File Panel Controls, Focus Manipulation, File/Dir Creation/Renaming, Main File Operations, Archive, Editor Actions, Other Actions).
2. **Typing hotkeys** — can override all other hotkeys (`confirm_typing`, `cancel_typing`).
3. **Mode-Specific Hotkeys** — can conflict with other modes but not with globals (Normal Mode: `parent_directory`, `search_bar`; Selection Mode: `file_panel_select_mode_items_select_*`, `file_panel_select_all_items`).

Forbidden bindings (per docs `custom-hotkeys.mdx` caution box):
- `Ctrl+M` conflicts with Enter
- `Ctrl+I` conflicts with Tab
- `Ctrl+?`, `Ctrl+[` conflict with Delete and Backspace

## c) Default `hotkeys.toml` — verbatim

Fetched from `src/superfile_config/hotkeys.toml` on `main`:

```toml
#-- Basic Actions
confirm = ['enter', 'right', 'l']
cd_quit = ['Q', '']
quit = ['q', 'esc']

#-- Navigation
list_down = ['down', 'j']
list_up = ['up', 'k']
page_down = ['pgdown','']
page_up = ['pgup','']

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
```

Note: default already includes `j`/`k`/`l`/`h` as secondary bindings on navigation/confirm/parent — partial vim friendliness out of the box. The vim preset goes further by remapping primary file-op letters (`y`/`x`/`p`/`d`).

## d) Built-in vim mode toggle?

**No runtime toggle in `config.toml`** — full default `config.toml` reviewed (editor, dir_editor, auto_check_update, cd_on_quit, default_open_file_preview, show_image_preview, show_panel_footer_info, default_directory, file_size_use_si, default_sort_type, sort_order_reversed, case_sensitive_sort, shell_close_on_success, page_scroll_size, debug, ignore_missing_fields, file_panel_extra_columns, file_panel_name_percent, theme, code_previewer, nerdfont, show_select_icons, transparent_background, file_preview_width, enable_file_preview_border, sidebar_width, sidebar_sections, border_*, metadata, enable_md5_checksum, zoxide_support, `[open_with]`). **No `vim_mode` key, no `keymap_preset` key.**

**But there IS a maintainer-blessed second hotkey file shipped in-repo**: `src/superfile_config/vimHotkeys.toml` (maintainer `nonepork`). The README itself says:

> WARNING: If you are vim/nvim user please change your default hotkeys config to vim version!

The docs page `custom-hotkeys` embeds both files via `<CodeBlock file="src/superfile_config/vimHotkeys.toml" />`. **Switching is done by overwriting `hotkeys.toml` content**, not flipping a flag. Perfect fit for chezmoi `{{ if .enableVimMode }}` template branching.

## e) Vim-style preset (verbatim from `vimHotkeys.toml`)

```toml
#-- Basic Actions
confirm = ['enter', '']
quit = ['ctrl+c', '']  # "theprimeagen troller"
cd_quit = ['Q', '']

#-- Navigation
list_up = ['k', '']
list_down = ['j', '']
page_up = ['pgup','']
page_down = ['pgdown','']

#-- File Panel Controls
create_new_file_panel = ['n', '']
close_file_panel = ['q', '']
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
change_panel_mode = ['m', '']
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
parent_directory = ['-', '']
search_bar = ['/', '']

# Selection Mode
file_panel_select_mode_items_select_down = ['J', '']
file_panel_select_mode_items_select_up = ['K', '']
file_panel_select_all_items = ['A', '']
```

Key vim-preset differences from default to flag for the chezmoi template:

- `quit` becomes `ctrl+c` (no plain `q`/`esc`) — frees `q` for `close_file_panel`.
- `confirm` drops `right` and `l` (l/h reserved for hjkl mental model; in this preset they actually are unused, only `j`/`k` are bound).
- `copy_items` = `y`, `cut_items` = `x`, `paste_items` = `p`, `delete_items` = `d`, `copy_path` = `Y` — Ctrl-prefixed counterparts removed.
- `file_panel_item_create` = `a` (vim "append"), `file_panel_item_rename` = `r` (vim "replace").
- `change_panel_mode` = `m`, freeing `v` (which is unused in this preset).
- `parent_directory` = `-` only (vim-vinegar / netrw convention); the default's `h` / `backspace` / `left` are dropped.
- `focus_on_*` all become `ctrl+*` so single-letter `m`/`p`/`s` are free.
- `toggle_footer` = `ctrl+f` (was `F`).
- `next_file_panel` / `previous_file_panel` lose the `L` / `H` shift-letter secondaries.

## Chezmoi template implications

1. **Target path is OS-dependent** — chezmoi source name must split macOS vs Linux. Either two separate `dot_*` files under conditional `{{ if eq .chezmoi.os "darwin" }}` or use a chezmoi template that emits the path via `chezmoi.config.destDir` + OS branch. macOS path `~/Library/Application Support/superfile/hotkeys.toml` is non-XDG.
2. **Single template file** can switch entire body with `{{ if .enableVimMode }}…{{ else }}…{{ end }}` — both bodies fit verbatim from upstream.
3. **`enableVimMode` semantic note** (per repo CLAUDE.md invariant): currently scoped to "shells + tmux only", explicitly NOT editors. Superfile is a TUI file manager, not a shell or editor — closer to tmux's category. Likely fits the gate; if added, must be listed in the `docs/this_repo/vim-mode.md` catalog table in the same commit.
4. **No need for `modify_` script** — overwrite semantics is fine; user customisations would conflict-prompt on apply, expected behaviour for a gated preset swap.
5. **Forbidden bindings to avoid** if writing custom (not preset) overrides: `Ctrl+M`, `Ctrl+I`, `Ctrl+?`, `Ctrl+[`.
6. **Both bodies should stay synced with upstream** — pin to a tag or note "synced from `main` @ <sha>" in a top comment so future bumps are mechanical.

## Sources

- `https://github.com/yorukot/superfile/blob/main/src/superfile_config/hotkeys.toml` (default)
- `https://github.com/yorukot/superfile/blob/main/src/superfile_config/vimHotkeys.toml` (vim preset, by `nonepork`)
- `https://github.com/yorukot/superfile/blob/main/src/superfile_config/config.toml` (default config — verified no vim toggle key)
- `https://github.com/yorukot/superfile/blob/main/website/src/content/docs/configure/config-file-path.mdx` (per-OS paths)
- `https://github.com/yorukot/superfile/blob/main/website/src/content/docs/configure/custom-hotkeys.mdx` (caveats + both-presets embed)
- `https://github.com/yorukot/superfile/blob/main/README.md` ("vim users please change your default hotkeys config" warning)
- Live URLs (`https://superfile.dev/configure/custom-hotkeys/` and `…/superfile-config/`) returned 403 to WebFetch during this run — fetched the source `.mdx` files via `gh api` instead; content is the canonical upstream.
