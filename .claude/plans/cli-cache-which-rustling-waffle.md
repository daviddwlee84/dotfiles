# Plan: navigate `appsrc` — full-inventory tv channels + `appsrc tui` (Textual)

## Context

**Problem.** `appsrc scan` now prints ~2264 rows (GUI + CLI, every source) — a
flat wall of text. There's no way to *navigate* it: filter by source, find the
space hogs (now that `appsrc size` exists), drill into detail. The existing `tv
appsrc` channel only covers GUI apps.

**Decision (locked).** Build **both** (user chose): a fast tv-picker layer over
the *full* inventory + a size-sorted "space hogs" picker, **and** a Textual
`appsrc tui` dashboard (sortable-by-size, filterable) — mirroring the repo's
`mlf` pattern ("tv = fast picker, TUI = dashboard", CLAUDE.md line 21).

**Outcome.** `tv appsrc` (browse everything by source), `tv appsrc-size` (biggest
consumers first), and `appsrc tui` (interactive: sort by size, filter, Enter→size
detail).

## Design

### 1. CLI additions (`dot_dotfiles/bin/executable_appsrc`)
- **`scan --sort {source,name,size}`** (default `source`, current behaviour).
  `--sort size` implies `--size`; sorts records by `size_bytes` desc. Applies to
  table / `--tsv` / `--json`. ~10 lines in `do_scan` before rendering.
- **`tui` subcommand** → `do_tui()`. Lazy `import textual` *inside* `do_tui` (so
  `scan`/`which`/`size`/`-h` never load it); add `"textual>=5"` to the PEP723
  block. `tui` refuses to run when `sys.stdout` isn't a TTY (copy mlf
  `tui.py:main` guard). Add `tui` to `parse_args` subparsers + `main` dispatch.

### 2. Textual TUI — inline `AppsrcTUI(App)` in the same file
Single-file (no `scripts/appsrc/` package needed) — the App **calls the existing
module functions directly**: `_mac_gui_apps`/`_path_binaries`/`_classify_gui`/
`_classify_cli`/`compute_size`/`_resolve_record`/`_human`/`_du_bytes`.
- **Widget:** one `textual.widgets.DataTable` (`cursor_type="row"`), columns
  `Name / Source / Kind / Size / Path`; docked `Input` filter (hidden until `/`),
  docked `Static` status bar, `Header`/`Footer`. Copy mlf's CSS + `compose` +
  `on_mount` column-setup + filter show/hide + `Input.Changed` rebuild verbatim
  (`scripts/mlf/tui.py:424-561,1099-1250`).
- **Load (fast):** `@work(thread=True, exclusive=True, group="scan")` runs the
  inventory (no sizes) → `call_from_thread` fills rows; status `"scanning…"` →
  `"N items"`. Exact worker skeleton from `tui.py:565-599`.
- **Sizes on demand:** binding `s` = size the **currently-visible (filtered)**
  rows in a worker (bounds `du` cost to what's on screen), fill the Size column,
  then sort by size desc. Avoids du-ing all 2264 up front.
- **Sort/filter:** `DataTable.sort(col)` bindings — `s` size, `o` source, `n`
  name (net-new vs mlf, which sorts in Python; `DataTable.sort` is one call). `/`
  filter box (substring over name+source), rebuild rows on `Input.Changed`.
- **Drill-in / actions** (mirror the tv channel single-letter mnemonics):
  `enter`→size detail (a `ModalScreen` rendering `compute_size` via
  `_resolve_record(prefer_app=True)`, or a `Static`), `d`→which detail,
  `o`… conflict → use `enter`=detail, `s`=size-sort, `y`=copy path, `r`=reveal,
  `j`=json. Wire `@on(DataTable.RowHighlighted/RowSelected)` reading
  `event.row_key` (the one net-new piece — mlf drives off a Tree, not the table).
- Est. ~250-300 lines (mlf agent estimate for a single-table sortable TUI).

### 3. tv channels (`dot_config/television/cable/`)
- **`appsrc.toml`** (existing) — broaden source from `scan --kind gui --tsv` to
  the **full inventory** `appsrc scan --tsv`; add source+kind to `display` so
  fuzzy-typing `cask`/`manual`/`app-store` filters. Keep current
  detail/size/copy/reveal/json actions.
- **`appsrc-size.toml`** (new) — space hogs. `source = "appsrc scan --kind gui
  --size --sort size --tsv"`, `no_sort = true` (preserve CLI order — the idiom in
  `ansible.toml:41` etc.), display `"<size>  <name>  (<source>)"`; preview/Enter =
  `appsrc size --path`. (GUI-only default so the source command stays ~warm-3.6s;
  note the cold-scan cost in the header comment.)
- Mirror `Alt+<letter>` actions with the TUI mnemonics per CLAUDE.md invariant.

### 4. Integration
| File | Change |
|---|---|
| `dot_dotfiles/bin/executable_appsrc` | `--sort`, `tui` subcommand + `AppsrcTUI`, `textual` dep |
| `dot_config/television/cable/appsrc.toml` + new `appsrc-size.toml` | full-inventory + size-sorted channels |
| `dot_config/{zsh/tools,bash}/57_appsrc_completion.*` | add `tui` subcommand + `--sort {source,name,size}` to scan |
| `docs/tools/appsrc.md` | "Navigating (tv + tui)" section |
| `docs/shells/aliases.md`, `dot_agents/skills/chezmoi-dotfiles/SKILL.md.tmpl` | mention `tui` + the two channels |
| `docs/zsh/zsh-completions.md` | note `tui` in the dynamic bullet |
| `CLAUDE.md` | new invariant row: `executable_appsrc` (tui BINDINGS) ↔ `appsrc*.toml` channel Alt-keys ↔ completions — mirror single-letter mnemonics in one commit (model on the `mlf` row, line 21). Keep ≤30k headroom. |

No `docs/tools/` new page (extend appsrc.md). `textual` needs **no**
`python_uv_tools` entry (library dep, PEP723-only — same as `rich`).

## Reuse
- Launch/TTY guard + worker/`call_from_thread` + DataTable rebuild + filter Input:
  `scripts/mlf/tui.py` (§ lines above); PEP723 `textual>=5` from `executable_mlf`.
- All data/sizing logic already exists in `executable_appsrc` (§2) — the TUI is a
  thin view over it; no logic duplication.
- `no_sort`/pre-sorted channel idiom: `dot_config/television/cable/ansible.toml`.

## Verification
1. `appsrc scan --sort size --tsv | head` → Docker/Chrome/nvim on top (desc).
2. `appsrc tui` in a real terminal: table paints fast; `/` filters; `s` sizes the
   visible set and sorts (Docker 25 G top); `enter` shows the size detail;
   `y`/`r` copy/reveal; `q` quits. (Headless caveat per
   `memory/tv-channel-headless-validation.md`: TUI needs a TTY — smoke via a real
   pane / tmux; validate the *data* functions standalone, don't assert by piping.)
3. `tv appsrc` lists GUI+CLI, fuzzy `cask` filters; `tv appsrc-size` opens with
   biggest first (validate the source/preview commands standalone, not the TUI).
4. Completions: `appsrc <Tab>` offers `scan/which/size/tui`; `appsrc scan --sort
   <Tab>` → `source name size`. `zsh -n` / `bash -n` clean.
5. `uv run mkdocs build --strict` adds no new warning; `chezmoi execute-template`
   renders SKILL.md.tmpl; `just gen-prompts --check` (CLAUDE.md edit is prose, no
   prompt change) unaffected.
6. Confirm `appsrc -h` / `scan` / `which` still fast (textual NOT imported on
   non-tui paths — `python3 -X importtime` or just timing).
