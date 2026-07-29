-- ~/.config/yazi/init.lua
-- Yazi Lua init — runs once at startup. Managed by chezmoi
-- (source: dot_config/yazi/init.lua). Edits to ~/.config/yazi/init.lua are
-- reverted on next `chezmoi apply` — change the source instead.
--
-- Documentation: https://yazi-rs.github.io/docs/configuration/overview

-- duckdb.yazi — DuckDB-powered table previewer for data files
-- (csv/tsv/parquet/xlsx/db/duckdb). This setup() call is REQUIRED: it registers
-- the plugin's previewer/preloader; without it the `run = "duckdb"` rules in
-- yazi.toml never activate.
--
--   mode = "standard"   → hover shows actual data rows (press K at top-of-file
--                         to toggle to DuckDB's SUMMARIZE view: min/max/counts).
--                         The plugin default is "summarized"; we prefer showing
--                         rows first for a quick "what's in this file" glance.
--
-- Other opts (see the plugin README / main.lua M:setup): cache_size (default 500),
-- row_id (false), minmax_column_width (21), column_fit_factor (10).
-- See docs/tools/data-viewers.md.
--
-- WHY THE pcall: a bare `require("duckdb")` makes a missing plugin a FATAL
-- startup error — yazi refuses to launch at all and reports only
-- `Failed to load plugin from …/duckdb.yazi/main.lua`, which blames the plugin
-- for what is usually a missing `ya` CLI (no `ya` → run-script 45 skips →
-- ~/.config/yazi/plugins/ never created). Losing data previews must not cost
-- you the whole file manager. pcall is yieldable in Lua 5.4, so it correctly
-- catches errors from require's internal poll/yield.
-- Recovery is `ya pkg install`. See pitfalls/yazi-lua-runtime-failed-plugin-main-lua.md.
local ok, err = pcall(function()
	require("duckdb"):setup({ mode = "standard" })
end)

if not ok then
	-- Degrade loudly, not silently: yazi still starts, but say why previews died.
	-- ya.err only lands in the log when YAZI_LOG is set, so notify is the part
	-- you actually see. Guard notify too — never let the guard itself be fatal.
	ya.err("duckdb.yazi failed to load: " .. tostring(err))
	pcall(ya.notify, {
		title = "duckdb.yazi not loaded",
		content = "Data-file previews (csv/parquet/xlsx/db) are disabled. Run `ya pkg install` to restore them.",
		level = "warn",
		timeout = 10,
	})
end
