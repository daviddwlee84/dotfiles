# Plan: Cursor-style file-reference copy keybindings in Neovim

## Context

When handing code to Claude Code (or Cursor), the useful thing to paste is a
reference like `@path/to/file`, `@path/to/file:12`, or `@path/to/file:12-40`
— the `@` triggers the agent's file-mention and the `:line[-line]` points it at
exact code. Today there is no way to grab that from Neovim; you retype paths and
line numbers by hand.

This adds four Neovim keybindings that build such a reference from the current
buffer + cursor line (normal mode) or visual selection (visual mode) and copy it
to the system clipboard, in both **project-relative** and **machine-absolute**
path flavors.

Decisions already made with the user:
- Bind under a **new `<leader>y` ("copy ref") group** — that prefix is currently
  unused (unlike the contested `<leader>a` AI group shared by avante + claudecode).
- Provide **4 explicit keys**: line-aware and file-only, each × relative/absolute.

## Keymap semantics (the contract)

`<leader>` = Space. All four work in normal **and** visual mode (`{ "n", "x" }`).

| Key | Path flavor | Normal mode | Visual mode |
|---|---|---|---|
| `<leader>yr` | relative | `@rel/path:12` (cursor line) | `@rel/path:12-40` (selection) |
| `<leader>ya` | absolute | `@/abs/path:12` | `@/abs/path:12-40` |
| `<leader>yf` | relative | `@rel/path` (no line) | `@rel/path` (no line) |
| `<leader>yF` | absolute | `@/abs/path` (no line) | `@/abs/path` (no line) |

Notes:
- **Line-aware keys (`yr`/`ya`) use the current cursor line in normal mode** —
  deliberately *not* whole-file — so they are meaningfully distinct from the
  file-only keys (`yf`/`yF`). This maps your three example formats to distinct
  actions: `@file` → `yf`, `@file:line` → `yr` (normal), `@file:line1-line2` →
  `yr` (visual).
- Single-line visual selection collapses `:12-12` → `:12`.
- Relative base = **git root** (`LazyVim.root.git()`); files outside the git root
  fall back to a cwd/home-relative path (`:~:.`).

## Implementation

All in one file — **`dot_config/nvim/lua/config/keymaps.lua`** (currently 14
lines; the established home for standalone maps + a `which-key.add` group, and
NOT gated by `enableVimMode` per the repo's nvim rule). No new file is added
(the sibling `lua/exact_plugins/` dir has the chezmoi `exact_` attribute, which
would delete unmanaged files — avoid touching it).

Reuse (confirmed present on this nvim 0.12.4), no new deps:
- `LazyVim.root.git()` — git root; already used at `lua/exact_plugins/floating-tui.lua:10`.
- `vim.fs.relpath(root, abspath)` — builtin, returns `nil` if not a subpath.
- `vim.fn.setreg("+", ref)` — SSH-safe copy (respects the OSC52 provider set in
  `lua/config/options.lua:12-18`; do **not** shell out to `pbcopy`).
- Visual range via `vim.fn.line(".")` / `vim.fn.line("v")` — the house pattern at
  `lua/exact_plugins/gitsigns.lua:23-28`.
- `vim.notify(..., vim.log.levels.*)` — house feedback style.

Add a `copy_reference` helper + the four maps + the which-key group:

```lua
-- Copy a Cursor-style file reference to the system clipboard, for pasting into
-- Claude Code / Cursor:  @path  |  @path:12  |  @path:12-40
-- Normal mode -> cursor line; visual mode -> selection range.
local function copy_reference(opts)
  local abspath = vim.api.nvim_buf_get_name(0)
  if abspath == "" then
    vim.notify("copy-ref: buffer has no file", vim.log.levels.WARN)
    return
  end
  abspath = vim.fn.fnamemodify(abspath, ":p")

  -- path component
  local path
  if opts.absolute then
    path = abspath
  else
    -- pcall guards the nvim-0.12 vim.fs.find ENOENT-on-nil-cwd trap
    -- (pitfalls/nvim-fs-find-enoent-stale-cwd.md)
    local ok, root = pcall(function() return LazyVim.root.git() end)
    path = (ok and root and vim.fs.relpath(root, abspath)) or vim.fn.fnamemodify(abspath, ":~:.")
  end

  -- line component
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local suffix = ""
  if opts.lines then
    if visual then
      local a, b = vim.fn.line("."), vim.fn.line("v")
      if a > b then a, b = b, a end
      suffix = (a == b) and (":" .. a) or (":" .. a .. "-" .. b)
    else
      suffix = ":" .. vim.fn.line(".")
    end
  end
  if visual then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false) -- leave visual mode
  end

  local ref = "@" .. path .. suffix
  vim.fn.setreg("+", ref)
  vim.notify("Copied " .. ref, vim.log.levels.INFO)
end

require("which-key").add({
  { "<leader>y", group = "copy ref" },
})

vim.keymap.set({ "n", "x" }, "<leader>yr", function() copy_reference({ lines = true }) end,
  { desc = "Ref: relative + line" })
vim.keymap.set({ "n", "x" }, "<leader>ya", function() copy_reference({ lines = true, absolute = true }) end,
  { desc = "Ref: absolute + line" })
vim.keymap.set({ "n", "x" }, "<leader>yf", function() copy_reference({}) end,
  { desc = "Ref: relative (file only)" })
vim.keymap.set({ "n", "x" }, "<leader>yF", function() copy_reference({ absolute = true }) end,
  { desc = "Ref: absolute (file only)" })
```

Edge cases handled: unnamed/scratch buffer → warn + no-op; deleted cwd → `pcall`
falls back to a relative path instead of erroring; file outside git root →
`:~:.` fallback.

## Verification

1. Deploy: `chezmoi diff` then `chezmoi apply` (nvim files are copied verbatim,
   not templated) — or edit the target directly for a quick loop.
2. Headless smoke (config loads + maps registered, no Lua error):
   `nvim --headless -c 'lua print(vim.fn.maparg("<leader>yr", "n"))' -c 'qa!'`
   (expect a non-empty rhs; stderr clean).
3. Interactive, in a real project file:
   - Normal mode: `<leader>yf` → clipboard `@rel/path`; `<leader>yr` →
     `@rel/path:<curline>`. Confirm with `:echo getreg('+')` or paste.
   - Visual-select several lines → `<leader>yr` → `@rel/path:L1-L2`; single-line
     selection → `@rel/path:L`.
   - `<leader>ya` / `<leader>yF` → machine-absolute variants.
   - Press `<leader>y` → which-key shows the "copy ref" group with 4 entries.
   - No collision: `:verbose map <leader>yr` shows only our map.
   - Edge: `:enew` (unnamed) → `<leader>yf` → warning toast, no crash.
4. Real target: paste `@rel/path:12-40` into Claude Code and confirm it resolves.

## Out of scope / optional

- **Docs**: no maintenance rule mandates a doc for nvim leader-maps (the
  `Ctrl+`/`Alt+` keybinding row targets shell/tmux). Optionally, following the
  `docs/neovim/floating-tui.md` precedent, a short `docs/neovim/copy-reference.md`
  (+ `.zh-TW`, + `mkdocs.yml` nav, + `uv run mkdocs build --strict`) could be
  added later — left out to keep this change lean unless you want it.
