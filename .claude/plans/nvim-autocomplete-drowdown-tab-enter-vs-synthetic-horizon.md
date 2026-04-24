# nvim-cmp: VSCode-style smart `<CR>` (Enter ≠ auto-accept)

## Context

Currently in Neovim, both **Tab** and **Enter** accept the completion item
from `nvim-cmp`. Enter's accept is the problem: when the user just wants to
start a new line and an AI suggestion (Copilot ghost-text promoted into the
cmp menu, or an auto-preselected LSP entry) happens to be highlighted,
pressing Enter silently accepts it instead of inserting a newline. The user
has been routinely escaping with `Esc + o` to work around it.

Target behavior ("VSCode `acceptSuggestionOnEnter: smart`"):

- **Tab** — unchanged. Select first item if none selected, otherwise confirm.
- **Enter** — insert a real newline *unless* the user has **explicitly**
  navigated to an item with arrow keys / `Ctrl-n` / `Ctrl-p`. Auto-preselected
  entries (LSP `preselect`, cmp's default highlight) do NOT count as
  "explicit" — Enter still inserts a newline.

The trick is `cmp.get_active_entry()` vs `cmp.get_selected_entry()`:
`get_active_entry()` returns `nil` when the highlight is only a preselect
and no user navigation has happened — exactly the distinction we want.

## Scope

Isolated change, single file. nvim-cmp config is local to this repo; no
LazyVim fork, no autopairs (`cmp_autopairs.on_confirm_done`) integration,
no Copilot Tab/CR override in `dot_config/nvim/lua/exact_plugins/copilot.lua`
(Copilot ghost-text accept is handled separately by copilot.lua's own
bindings and is unaffected).

## Change

**File**: `dot_config/nvim/lua/exact_plugins/nvim-cmp.lua`

Add one entry to the `vim.tbl_extend("force", opts.mapping, { ... })` block
(currently only overrides `<Tab>`, line 24–36). The existing `<Tab>`
mapping is untouched.

```lua
["<CR>"] = cmp.mapping(function(fallback)
  -- VSCode "smart" accept: Enter only accepts when the user has
  -- EXPLICITLY navigated to an entry (arrow keys / C-n / C-p).
  -- Auto-preselected items do NOT count, so a fresh Enter is always
  -- a real newline even if the popup is open with an AI suggestion
  -- highlighted. Use <Tab> to accept explicitly.
  if cmp.visible() and cmp.get_active_entry() then
    cmp.confirm({ behavior = cmp.ConfirmBehavior.Replace, select = false })
  else
    fallback()
  end
end, { "i", "s" }),
```

Notes:
- `select = false` on `confirm` is belt-and-suspenders: we already gated
  on `get_active_entry()`, but this guarantees no auto-selection side-effect.
- `ConfirmBehavior.Replace` matches common LazyVim smart-CR recipes — it
  replaces the word the cursor is inside, which is the VSCode default.
  Can be dropped / changed to `Insert` if the user prefers additive
  insertion later.
- Mode `{ "i", "s" }` mirrors the `<Tab>` entry so select-mode (active
  during snippet jumps) behaves the same way.

## Files touched

- `dot_config/nvim/lua/exact_plugins/nvim-cmp.lua` — add `<CR>` entry to
  the mapping block (~5 lines incl. comment).

## Not changing

- `dot_config/nvim/lua/exact_plugins/copilot.lua` — Copilot ghost-text
  accept keybinding is independent; the user's pain was cmp-menu Enter,
  not ghost-text.
- No `CLAUDE.md` / README update needed — this is a personal-preference
  tweak, not a repo invariant or cross-file surface.
- No chezmoi template / prefix change; the file is a plain `lua` source
  (not `modify_` / `create_`), so editing it directly is correct.

## Verification

1. Reload Neovim (or `:Lazy reload nvim-cmp`).
2. In an insert buffer, trigger completion (any file with LSP — e.g. open
   one of the `scripts/*.py` files and start typing an identifier).
3. **Popup open, nothing manually selected** — press Enter. Expect:
   newline inserted, popup closes, no completion text inserted.
4. **Popup open, arrow-Down to pick an entry, then Enter**. Expect:
   entry is accepted (replaces current word), no newline.
5. **Popup open, press Tab without navigating**. Expect: first entry
   highlighted (existing Tab-select behavior preserved).
6. **Popup open, navigate with arrow keys, press Tab**. Expect: entry
   accepted (existing Tab-confirm behavior preserved).
7. Open a markdown/help file and confirm Copilot ghost-text (if
   triggered) still accepts via its own binding — unchanged.
