# View Data Files in the Terminal

Preview and explore tabular / data files — **CSV**, **TSV**, **Parquet**, **Feather/Arrow**,
**Excel `.xlsx`**, **SQLite**, and native **DuckDB** databases — without leaving the terminal, and
without opening an editor or a GUI.

Two layers:

- **Inline previews** in the [yazi](tmux/README.md) file manager — hover a data file and its rows
  render as an aligned table in the right pane, powered by the [`duckdb.yazi`](#duckdbyazi--the-previewer)
  plugin (with two small fallbacks for the formats DuckDB can't read).
- **Interactive exploration** with [VisiData](#visidata--interactive-exploration) (`vd`) — a fast,
  vim-keyed spreadsheet TUI for sorting, filtering, frequency tables, and describe.

The split is deliberate: **DuckDB for the glance, VisiData for the deep-dive.** We evaluated using
VisiData for previews too and rejected it — its non-interactive batch output is raw TSV (or a
`--save-filetype fixed` monochrome table), it can't preview SQLite data (only lists tables), can't
open `.xlsx` (its tool venv has no `openpyxl`), and is slow on the preview hot-path (~0.4 s for CSV,
up to ~10 s cold for parquet, because it imports pandas + pyarrow). DuckDB's `-box` renders a native
aligned table in ~0.1 s and can cheaply `LIMIT` to the first N rows.

## TL;DR

| Format | yazi preview | Engine |
|---|---|---|
| `.csv` `.tsv` | ✅ table | duckdb.yazi |
| `.parquet` | ✅ table | duckdb.yazi |
| `.xlsx` | ✅ table | duckdb.yazi (DuckDB `spatial` ext — see gotcha) |
| `.db` `.duckdb` | ✅ table listing | duckdb.yazi (DuckDB auto-attaches SQLite) |
| `.sqlite` `.sqlite3` | ✅ table listing | piper → `duckdb -readonly` (fallback) |
| `.feather` `.arrow` | ✅ table | piper → VisiData `fixed` (DuckDB has no Arrow-IPC reader) |

All formats open interactively in **VisiData** (`vd <file>`) regardless of the preview engine.

## `duckdb.yazi` — the previewer

[`duckdb.yazi`](https://github.com/wylie102/duckdb.yazi) is a Yazi previewer/preloader plugin that
shells out to the **`duckdb` CLI** (already installed by the `devtools` role) and renders its `-box`
table into the preview pane. It reads CSV, TSV, Parquet, Excel, and DuckDB/SQLite databases.

Three pieces make it work in this repo:

| Piece | Path | Role |
|---|---|---|
| Lockfile (SSOT) | `dot_config/yazi/package.toml` | pins `wylie102/duckdb` (rev + hash) |
| Init | `dot_config/yazi/init.lua` | **required** `require("duckdb"):setup({ mode = "standard" })`, wrapped in `pcall` so a missing plugin warns instead of blocking yazi startup |
| Wiring | `dot_config/yazi/yazi.toml` `[plugin]` | `prepend_previewers` + `prepend_preloaders` (`run = "duckdb"`) |

The `setup()` call in `init.lua` is mandatory — without it the `run = "duckdb"` rules never activate.
We set `mode = "standard"` so hover shows actual data rows (the plugin default is `summarized`); press
`K` at the top of a preview to toggle to DuckDB's `SUMMARIZE` view (min/max/counts per column).

### Keybindings

Added to `dot_config/yazi/keymap.toml` (`[mgr] prepend_keymap`):

| Key | Action |
|---|---|
| `K` | Toggle standard ⇄ SUMMARIZE view (built into the plugin; no keymap entry) |
| `H` / `L` | Scroll one column left / right in the preview |
| `g o` | Open the hovered file in the DuckDB CLI |
| `g u` | Open the hovered file in the DuckDB UI |

> ⚠ **`H` / `L` override Yazi's default history back/forward** (the capital-letter binds). Lowercase
> `h` / `l` (leave / enter directory) are unaffected. On non-data files `H`/`L` no-op.

### The two fallbacks (formats DuckDB can't read)

- **Feather / Arrow** (`.feather` `.arrow`) — DuckDB has no Arrow-IPC file reader, so these route
  through [`piper.yazi`](office-viewers.md#the-ya-pkg-plugin-mechanism) to VisiData's non-interactive
  `fixed` saver:
  ```toml
  { url = "*.feather", run = 'piper -- vd -b -f arrow "$1" -o - --save-filetype fixed 2>/dev/null | head -n 500' }
  ```
  `-f arrow` forces the pure-pyarrow `ArrowSheet` loader (dodges the pandas `StringDtype` crash — see
  [the feather pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/visidata-feather-stringdtype-numpy-dtype.md)), and `2>/dev/null`
  is **mandatory**: piper renders any stderr as an error preview, and VisiData logs status to stderr.
- **SQLite by `.sqlite` / `.sqlite3` name** — the plugin's internal `extension_map` only knows `.db`
  (not `.sqlite`), so those two extensions route through piper to a `duckdb -readonly` table listing.
  Plain `.db` gets the full plugin treatment (DuckDB transparently attaches SQLite databases opened
  directly, so `.db` covers most SQLite files).

## VisiData — interactive exploration

`vd <file>` opens a full-screen, vim-keyed spreadsheet over CSV/TSV/JSON/Parquet/Feather/Arrow/xlsx/
SQLite. This is the tool for actual analysis: sort, filter (`|` / `\`), frequency (`Shift+F`),
describe (`Shift+I`), pivot, and save-as. Defaults are already vim-flavored (`h/j/k/l`, `gg/G`,
`/?` search); the repo adds strict-vim column nav under `enableVimMode`. See
[aliases.md → Data Viewers](../shells/aliases.md#data-viewers) for the `vd-arrow` / `vd-ro` wrappers
and [vim-mode.md → VisiData](../this_repo/vim-mode.md#visidata) for the key rebinds.

VisiData and its companion `~/.visidatarc` are installed/managed regardless (`visidata` is a required
uv tool with `pandas` + `pyarrow`); the `.visidatarc` carries the `.feather` → `ArrowSheet` reroute
that the preview fallback above also relies on.

## Where things live

| Surface | Path |
|---|---|
| Plugin lockfile + installer | `dot_config/yazi/package.toml`, `.chezmoiscripts/global/run_after_45_yazi_plugins.sh.tmpl` |
| Plugin init | `dot_config/yazi/init.lua` |
| Previewers + preloaders | `dot_config/yazi/yazi.toml` `[plugin]` |
| Keybindings | `dot_config/yazi/keymap.toml` |
| DuckDB CLI install | `dot_ansible/roles/devtools/tasks/main.yml` |
| VisiData install + rc | `dot_ansible/roles/python_uv_tools/defaults/main.yml`, `dot_visidatarc.tmpl` |
| Upgrades | `scripts/upgrade_tools.sh` (`just upgrade-yazi-plugins`) |

## Gotchas

- **No plugins at all? Check for `ya`, not duckdb.** If yazi dies at startup with
  `Failed to load plugin from ".../duckdb.yazi/main.lua"`, the usual cause is that `ya` (yazi's CLI
  companion, shipped alongside `yazi` in every release asset) was never installed — so
  `~/.config/yazi/plugins/` was never created and `piper.yazi` is missing too. `ya --version` is the
  one-command diagnosis; `ya pkg install` is the fix. `init.lua` now wraps the `require` in `pcall`,
  so yazi starts anyway and warns instead of refusing to launch. See
  [pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md).
- **`ya.err` needs `YAZI_LOG`.** Plugin errors only reach `~/.local/state/yazi/yazi.log` when the env
  var is set — `YAZI_LOG=debug yazi`. Without it the log file doesn't even exist, which makes plugin
  problems look like they leave no trace.
- **`.xlsx` first preview needs internet.** duckdb.yazi reads Excel via DuckDB's `spatial` extension,
  which it `INSTALL`s on first use — the first `.xlsx` preview on a fresh machine downloads it (cached
  in `~/.duckdb` afterwards). CSV/TSV/Parquet/DB previews use built-ins and need no network.
- **`.xlsx` preview moved off `view-office`.** Yazi now previews `.xlsx` with duckdb.yazi, not
  `markitdown`. The `view-office --preview budget.xlsx` **CLI** is unchanged (still markitdown → glow);
  only Yazi's previewer wiring moved. See [office-viewers.md](office-viewers.md).
- **Lowercase globs.** The `url` globs are lowercase (`*.csv`); a file named `DATA.CSV` won't trigger
  the previewer. (VisiData opened directly still works.)
- **DuckDB normalizes display.** `-box` may render `1200.50` as `1200.5` (type inference) — it's a
  display artifact of the preview, not a change to the file.
- **`view-office` for `.xls`/`.ods`.** Legacy binary `.xls` and OpenDocument `.ods` stay on the
  LibreOffice → OOXML path (DuckDB can't read those); only modern `.xlsx` uses duckdb.yazi.

## See also

- [Office viewers](office-viewers.md) — the `.docx/.pptx` + legacy/ODF sibling stack (doxx / markitdown / LibreOffice), and the `ya pkg` / `piper.yazi` mechanism shared here.
- [Data Viewers (aliases)](../shells/aliases.md#data-viewers) — VisiData `vd-arrow` / `vd-ro` wrappers.
- [tool-managers.md § 15](../this_repo/tool-managers.md) — `ya pkg` plugin mechanism (piper.yazi, duckdb.yazi).
- [Feather / StringDtype pitfall](https://github.com/daviddwlee84/dotfiles/blob/main/pitfalls/visidata-feather-stringdtype-numpy-dtype.md) — why `.feather` needs the ArrowSheet loader.
