# Copy Cursor-style file references (`@file:line`)

Four Neovim keymaps that copy a **Cursor / Claude Code style file reference** —
`@path`, `@path:12`, or `@path:12-40` — to the system clipboard, built from the
current buffer plus the cursor line (normal mode), the visual selection
(visual mode), or — in a file explorer — the node under the cursor. The `@` triggers the agent's file-mention and the `:line[-line]`
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

## File explorers (neo-tree / snacks)

Trigger a keymap while focused in a **file-explorer** buffer and the reference
points at the **node under the cursor** instead (no line number) — e.g.
`<leader>yf` on a tree entry copies `@rel/path/to/that/file`. This mirrors
neo-tree's own `Y` (copy path).

- **neo-tree** is supported today (resolves the node via neo-tree's manager API).
- **snacks explorer** — LazyVim's neo-tree successor — is handled best-effort, so
  the keymaps keep working after that migration.
- Any other special buffer (terminal, help, quickfix, an unknown explorer, an
  unnamed buffer) is safely rejected with a `copy-ref: no file under cursor here`
  warning — never a bogus `@neo-tree filesystem [1]`.

## Shell twin: `cref`

Outside the editor, the [`cref`](../shells/aliases.md#shell-utilities) shell
function produces the **same reference shapes** from the command line and copies
them to the clipboard — through the `x` CLI's OSC 52 path, so it works over SSH
too:

```sh
cref src/app.py:42        # copies @src/app.py:42
cref -a src/app.py:10-20  # @/abs/src/app.py:10-20  (machine-absolute)
rg -n TODO | cref         # ref from ripgrep's first match line
```

It mirrors the same path flavors — git-root-relative by default (with the same
cwd/`~`/absolute fallback), `-a` for absolute — plus a `-c` for an explicitly
cwd-relative path. A shell has no cursor line, so the line component comes from a
`FILE:LINE[-LINE]` argument, trailing positionals (`cref FILE 12 40`), or a piped
grep/ripgrep line (`FILE:LINE:…`, with the `:col` stripped). Source:
`dot_config/shell/59_cref.sh`.

## Implementation notes

The feature is a small `copy_ref_target()` + `copy_reference()` helper pair plus
four `vim.keymap.set({ "n", "x" }, …)` calls in `lua/config/keymaps.lua`. It
reuses, with no new dependencies:

- `LazyVim.root.git()` — git-root detection.
- `vim.fs.relpath(root, abspath)` — built-in relative-path computation.
- `vim.fn.setreg("+", ref)` — respects the provider configured in
  `lua/config/options.lua`: native clipboard locally, copy-only OSC 52 under
  SSH/Herdr/Zellij. It therefore reaches the attached client's clipboard
  without enabling terminal clipboard reads. Do **not** shell out to `pbcopy`
  — that bypasses OSC 52. See [Clipboard](../tools/clipboard.md).
- Visual range via `vim.fn.line(".")` / `vim.fn.line("v")` — the same pattern the
  gitsigns stage-selection maps use.

Buffer resolution lives in a `copy_ref_target()` helper: real file buffers
(empty `buftype`) yield the file plus line context; known explorers yield the
node under the cursor; everything else returns `nil` and the caller warns.
Explorer lookups are `pcall`-wrapped so a changed or absent API degrades to that
warning instead of crashing or emitting a garbage path. A deleted cwd is likewise
guarded with `pcall` (avoids the Neovim 0.12 `vim.fs.find` ENOENT trap) and falls
back to a relative path.

## Why `<leader>y`

`<leader>y` was an unused prefix. The AI keymaps under `<leader>a` are already
crowded — avante and claudecode both bind many `<leader>a…` keys and even
collide with each other — so a fresh `y` ("yank / copy") group keeps these
reference-copy actions clear of that contention and easy to find in which-key.

To change or extend the set, edit the `copy_reference` helper and the
`vim.keymap.set` block in `lua/config/keymaps.lua`.
