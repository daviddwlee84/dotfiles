# Route A — Add `duckdb.yazi` data-file previewer to yazi

## Context

Yazi currently previews only Office files (`.docx/.xlsx/.pptx` + legacy/OpenDocument) via the
`piper.yazi` → `view-office` pipeline. Data files (`.csv/.tsv/.parquet/.feather/.db/.sqlite`) get no
table preview — they show as raw text or binary/hex on hover.

We evaluated using **visidata** as the previewer and rejected it: visidata's non-interactive `-b`
output is raw TSV (or a `TypeError`-broken `.md`), it can't preview SQLite data (only lists tables),
can't open `.xlsx` (its venv lacks `openpyxl`), and is slow on the hot-path (~0.4s CSV, up to ~10s
cold for parquet). visidata stays the **interactive** opener. For **previews**, `duckdb -box` is far
better (native aligned table, ~0.12s, `LIMIT` for cheap first-N-rows), and a ready-made yazi plugin
already wraps it: **`wylie102/duckdb.yazi`**. Both `duckdb` CLI (devtools role) and `visidata` +
`piper.yazi` are already required in this repo, so this adds **zero new install burden**.

Verified on this host (duckdb 1.4.4, vd 3.3): duckdb renders csv/parquet cleanly and — importantly —
**auto-attaches raw SQLite** `.db` files (`duckdb -readonly t.db` returns both table list and row
data), so duckdb.yazi's `.db` handler covers SQLite despite the plugin source not loading
`sqlite_scanner` explicitly. duckdb has **no feather/arrow reader** (confirmed: `read_parquet`
rejects Arrow IPC, `nanoarrow` ext 404s), so feather is handled by a visidata fallback.

### Decisions (from user)
- **xlsx → duckdb.yazi** (moves off the view-office/markitdown previewer path). First xlsx preview per
  machine downloads DuckDB's `spatial` extension (one-time network) — accepted.
- **Feather/arrow → visidata fallback** via `piper` running `vd -b … --save-filetype fixed` (the one
  clean headless visidata mode; verified renders feather correctly).
- **Keybindings → take the plugin's `H`/`L` + `g o`/`g u` as-is** (overrides yazi's default H/L
  directory-history nav, by explicit choice).

## Changes (file by file)

### 1. `dot_config/yazi/package.toml` — pin the plugin (SSOT, drives install)
Do **not** hand-write `rev`/`hash`. On a live box:
```
ya pkg add wylie102/duckdb
cp ~/.config/yazi/package.toml "$(chezmoi source-path ~/.config/yazi/package.toml)"
```
Adds a second `[[plugin.deps]]` (`use = "wylie102/duckdb"`, `rev`, `hash`) before `[flavor]`. The
hash-gated installer `.chezmoiscripts/global/run_onchange_after_45_yazi_plugins.sh.tmpl` re-runs
`ya pkg install` automatically on the changed sha256 — **no edit to the run-script**. Upgrade path
(`scripts/upgrade_tools.sh::cat_yazi_plugins` + `just upgrade-yazi-plugins`) is generic — **no edit**.

### 2. `dot_config/yazi/init.lua` — **NEW FILE** (required; none exists today)
```lua
-- Initialize the duckdb.yazi data-file previewer.
require("duckdb"):setup({ mode = "standard" })  -- show data rows by default; press K for SUMMARIZE
```
Without this call the plugin never registers. `mode = "standard"` chosen so hover shows actual rows
(plugin default is `summarized`); one-line change if we prefer summaries.

### 3. `dot_config/yazi/yazi.toml` — previewer + preloader wiring (lines ~191-205)
- In the existing Office `prepend_previewers`, **remove the `*.xlsx` line** (xlsx now owned by duckdb).
  Keep `*.xls`/`*.ods` on view-office (legacy binary/ODF → LibreOffice; duckdb can't read those).
- **Add duckdb entries** (plugin previewer → `run = "duckdb"`, bare plugin name, not piper):
  `*.csv *.tsv *.parquet *.xlsx *.db *.duckdb *.sqlite *.sqlite3`
- **Add feather/arrow fallback** via piper → visidata `fixed`:
  ```
  { url = "*.feather", run = 'piper -- sh -c ''vd -b "$1" -o - --save-filetype fixed 2>/dev/null | head -n 500'' -- "$1"' },
  { url = "*.arrow",   run = 'piper -- sh -c ''vd -b "$1" -o - --save-filetype fixed 2>/dev/null | head -n 500'' -- "$1"' },
  ```
  (Inline `sh -c` matches the file's existing `sh -lc` opener style; `-- "$1"` passes the path as the
  inner shell's `$1`. `piper.yazi` already installed.)
- **Add `prepend_preloaders`** (duckdb.yazi needs these to build its scroll caches):
  `*.csv *.tsv *.parquet *.xlsx` each `{ … run = "duckdb", multi = false }`.
- Deliberately **omit `*.json` and `*.txt`** from the duckdb map (plugin lists them, but routing all
  JSON/text to a table view would hijack config/log previews).
- **Key-name caveat to verify:** existing Office entries use `url = "*.ext"`; the duckdb.yazi README
  uses `name = "*.ext"`. Mirror the repo's `url =` for consistency, then verify previews actually fire
  (see Verification). If `url` turns out invalid for previewer rules in the installed yazi, that's a
  pre-existing Office-previewer bug — switch the whole `[plugin]` block to `name =` in one pass.

### 4. `dot_config/yazi/keymap.toml` — plugin keybindings (currently all-commented template)
Add a `[manager] prepend_keymap` with the 4 documented binds verbatim:
`H` → `plugin duckdb -1`, `L` → `plugin duckdb +1` (scroll columns), `g o` → `plugin duckdb -open`
(open in duckdb CLI), `g u` → `plugin duckdb -ui`. Note in a comment that H/L override yazi's default
directory-history nav (chosen deliberately). SUMMARIZE toggle is `K` at top-of-file — built into the
plugin, no keymap entry needed.

### 5. Docs (CLAUDE.md cross-file rules mandate same-commit updates)
- **NEW `docs/tools/data-viewers.md`** — the duckdb.yazi previewer: formats, `K`/`H`/`L`/`g o`/`g u`,
  the xlsx-spatial-first-run-network note, the feather→visidata fallback, SQLite-via-duckdb-auto-attach.
  Cross-link ↔ `office-viewers.md` and `../shells/aliases.md` (visidata).
- **`mkdocs.yml`** — nav entry next to `Office viewers … tools/office-viewers.md` (~line 334):
  `- Data viewers (duckdb.yazi): tools/data-viewers.md`. Then `uv run mkdocs build --strict`.
- **`docs/this_repo/tool-managers.md`** — § 15 (`ya pkg`) add a `duckdb.yazi` row under `piper.yazi`;
  A–Z index add a `duckdb.yazi` plugin row (mechanism `ya pkg`, role `devtools (yazi)`). The `duckdb`
  **CLI** row already exists — leave it.
- **`docs/tools/office-viewers.md`** — one line noting `.xlsx` **preview** now routes to duckdb.yazi
  (the `view-office --preview file.xlsx` CLI path via markitdown is unchanged; only yazi's previewer
  moved). markitdown's `[docx,xlsx,pptx]` extras **stay** (CLI still uses them).
- **`CLAUDE.md`** — add a "Data-file viewing" row to the cross-file table (sibling of "Office
  viewing") listing: `package.toml` duckdb dep, `yazi.toml` duckdb entries, **`init.lua`** requirement,
  `keymap.toml` binds, the **feather piper→`vd --save-filetype fixed` contract**, and the
  "xlsx preview owned by duckdb.yazi (needs spatial ext, network-on-first-use)" note.
- **`README.md`** — optional: extend the yazi/duckdb bullet to mention data-file table previews.

## Critical files
- Functional: `dot_config/yazi/package.toml`, `dot_config/yazi/init.lua` (new),
  `dot_config/yazi/yazi.toml`, `dot_config/yazi/keymap.toml`
- Reused as-is (no edit): `.chezmoiscripts/global/run_onchange_after_45_yazi_plugins.sh.tmpl`,
  `scripts/upgrade_tools.sh`, `justfile`, `dot_ansible/roles/devtools/tasks/main.yml` (duckdb CLI),
  `dot_visidatarc.tmpl` (feather ArrowSheet override already deployed)
- Docs: `docs/tools/data-viewers.md` (new), `mkdocs.yml`, `docs/this_repo/tool-managers.md`,
  `docs/tools/office-viewers.md`, `CLAUDE.md`, `README.md`

## Verification (end-to-end)
1. `ya pkg add wylie102/duckdb` on this host; copy `package.toml` back; `chezmoi diff` the yazi files.
2. `chezmoi apply` (or `chezmoi apply ~/.config/yazi`) → confirm `ya pkg install` materializes
   `~/.config/yazi/plugins/duckdb.yazi/`, and `init.lua`/`keymap.toml` deploy.
3. Launch `yazi` and hover each test file (already generated in `/tmp`: `t.csv t.parquet t.feather
   t.db`; make a `t.xlsx`): confirm each renders an aligned table. **This confirms the `url=` vs
   `name=` key question** — if a `.csv` shows a table, the key is correct.
   - Press `K` (summarized), `H`/`L` (column scroll), `g o` / `g u` (open in duckdb).
   - `.db`/`.sqlite`: confirm table-listing + that SQLite files preview (duckdb auto-attach).
   - `.feather`: confirm the visidata `fixed` table renders (fallback path).
   - `.xlsx`: confirm duckdb table (first run may pause to fetch `spatial`).
4. yazi starts with no config error (validates `yazi.toml`/`keymap.toml`/`init.lua` parse).
5. `uv run mkdocs build --strict` passes (docs + nav).
6. Sanity: a plain `.txt`/`.json`/config file still previews as text (we omitted those from the map).

## Follow-ups / notes
- If `.sqlite`/`.sqlite3` don't dispatch inside the plugin (its internal extension map may only know
  `.db`/`.duckdb`), fall back to a piper→`duckdb -box -readonly "$1" -c "…"` previewer for those two,
  or drop them. Verify in step 3.
- Feather preview loads the whole file (visidata has no cheap first-N); fine for the rare fallback.
  If it grows, promote feather/arrow into a proper `view-data` dispatcher (the deferred "Route B").
