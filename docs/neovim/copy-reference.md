# Copy Cursor-style file references (`@file:line`)

Four Neovim keymaps that copy a **Cursor / Claude Code style file reference** —
`@path`, `@path:12`, or `@path:12-40` — to the system clipboard, built from the
current buffer plus the cursor line (normal mode) or the visual selection
(visual mode). The `@` triggers the agent's file-mention and the `:line[-line]`
points it at exact code, so you paste an exact pointer instead of retyping paths
and line numbers by hand.

All four live in `lua/config/keymaps.lua` under a `<leader>y` ("copy ref")
which-key group. Press `<leader>y` (Space then `y`) to see them.

## Keymaps

`<leader>` = Space. Every key works in **normal** and **visual** mode.

| Keymap | Path flavor | Normal mode (cursor line) | Visual mode (selection) |
|--------|-------------|---------------------------|-------------------------|
| `<leader>yr` | project-relative | `@rel/path:12` | `@rel/path:12-40` |
| `<leader>ya` | machine-absolute | `@/abs/path:12` | `@/abs/path:12-40` |
| `<leader>yf` | project-relative | `@rel/path` (no line) | `@rel/path` (no line) |
| `<leader>yF` | machine-absolute | `@/abs/path` (no line) | `@/abs/path` (no line) |

Mnemonic: `r`elative / `a`bsolute carry the line; `f`ile-only (capital `F` =
absolute) is the bare path. Together the four cover all three reference shapes:

- `@file` → `<leader>yf`
- `@file:line` → `<leader>yr` in normal mode
- `@file:line1-line2` → `<leader>yr` in visual mode

A single-line visual selection collapses `:12-12` → `:12`. After copying in
visual mode the mapping leaves visual mode and shows a `Copied @…` toast.

## Path flavors

- **Relative** (`yr` / `yf`) is resolved against the **git root**
  (`LazyVim.root.git()` — the same root used by [Floating TUI](floating-tui.md)).
  A file outside the git root falls back to a `~` / cwd-relative path.
- **Absolute** (`ya` / `yF`) is the full machine path (`expand("%:p")`), with no
  symlink resolution.

Relative is usually what you want for Claude Code (it operates inside the
project); absolute is for files outside the repo, or when a tool needs the full
path.

## Implementation notes

The feature is a ~40-line `copy_reference(opts)` helper plus four
`vim.keymap.set({ "n", "x" }, …)` calls in `lua/config/keymaps.lua`. It reuses,
with no new dependencies:

- `LazyVim.root.git()` — git-root detection.
- `vim.fs.relpath(root, abspath)` — built-in relative-path computation.
- `vim.fn.setreg("+", ref)` — respects the OSC 52 clipboard provider configured
  in `lua/config/options.lua`, so it copies into your local terminal clipboard
  even over SSH. Do **not** shell out to `pbcopy` — that bypasses OSC 52. See
  [Clipboard](../tools/clipboard.md).
- Visual range via `vim.fn.line(".")` / `vim.fn.line("v")` — the same pattern the
  gitsigns stage-selection maps use.

Edge cases: an unnamed / scratch buffer shows a `copy-ref: buffer has no file`
warning and copies nothing; a deleted cwd is guarded with `pcall` (avoids the
Neovim 0.12 `vim.fs.find` ENOENT trap) and falls back to a relative path.

## Why `<leader>y`

`<leader>y` was an unused prefix. The AI keymaps under `<leader>a` are already
crowded — avante and claudecode both bind many `<leader>a…` keys and even
collide with each other — so a fresh `y` ("yank / copy") group keeps these
reference-copy actions clear of that contention and easy to find in which-key.

To change or extend the set, edit the `copy_reference` helper and the
`vim.keymap.set` block in `lua/config/keymaps.lua`.
