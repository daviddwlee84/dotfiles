# Floating TUI Tools in Neovim

Floating terminal windows for TUI tools, powered by [Snacks.terminal](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md) (bundled with LazyVim).

## How It Works

All TUI keymaps live in `lua/plugins/floating-tui.lua`. Each tool is a single `Snacks.terminal.toggle(cmd, opts)` call — no custom Lua module needed. Snacks handles:

- Floating window lifecycle (create, show, hide, resize)
- Terminal session persistence (hide with `q`, reopen with same keymap)
- Double-Esc to exit terminal insert mode
- Auto-cleanup when the process exits

This is the same mechanism behind `<leader>gg` (LazyGit via `Snacks.lazygit()`).

## Default Keymaps

| Keymap | Tool | Category |
|--------|------|----------|
| `<leader>gg` | LazyGit | Git (LazyVim built-in) |
| `<leader>zg` | gh dash | Git / GitHub |
| `<leader>zs` | sqlit | Database |
| `<leader>fy` | yazi | File Manager |
| `<leader>zb` | btop | System Monitor |
| `<leader>zd` | lazydocker | Container |
| `<leader>zi` | ipython | REPL |

Inside a floating TUI window:

- **Double-Esc** — exit terminal insert mode (back to normal mode)
- **q** (normal mode) — hide the window, process keeps running
- **Same keymap again** — reopen the hidden window

For the managed `gh-dash` / `diffnav` / `lazygit` setup behind `<leader>zg`, see [Git Diff Workflow](../tools/git_diff_workflow.md).

## Adding a New TUI

Add an entry to the `keys` table in `lua/plugins/floating-tui.lua`:

```lua
{
  "<leader>zX",
  function()
    Snacks.terminal.toggle("mytool", {
      win = { title = " mytool " },
    })
  end,
  desc = "MyTool",
},
```

### Common Options

```lua
Snacks.terminal.toggle(cmd, {
  cwd = vim.uv.cwd(),          -- working directory
  cwd = LazyVim.root.git(),    -- or use git root
  env = { FOO = "bar" },       -- environment variables
  auto_close = false,           -- keep window after process exits (for short-lived tools)
  win = {
    title = " tool name ",      -- floating window title
    width = 0.9,                -- 0-1 = ratio, >1 = columns
    height = 0.9,
    border = "rounded",         -- "rounded", "double", "single", "none"
    position = "float",         -- "float" (default for cmd), "bottom", "left", "right"
  },
})
```

### Multi-word Commands

Pass a table for commands with arguments:

```lua
Snacks.terminal.toggle({ "gh", "dash" }, { ... })
Snacks.terminal.toggle({ "psql", "postgres://localhost/mydb" }, { ... })
```

### Tools That Exit Quickly

Some tools (like `sqlit`) may exit and show `[Process exited 0]`. Set `auto_close = false` to keep the window visible so you can inspect output. The next toggle after closing will create a fresh instance.

### Tools with Vim-like Keybindings

Tools that use Esc internally (like sqlit's vim mode) work fine with Snacks' **double-Esc** timer — a single Esc goes to the TUI, pressing Esc again within 200ms exits terminal insert mode.

### Tools That Use `q` to Quit

By default, Snacks maps `q` in normal mode to **hide** the floating window (process keeps running). However, some TUI tools (like `sqlit`) use `q` as their own quit command, which terminates the process.

**The conflict:** if you Double-Esc back to Neovim normal mode and press `q`, Snacks hides the window — but if you press `q` while still in terminal insert mode, the TUI receives it and may exit the process entirely.

**Solution:** Remap the Snacks hide key to `<C-q>` for these tools, so `q` is never intercepted by Snacks:

```lua
Snacks.terminal.toggle("sqlit", {
  win = {
    title = " sqlit ",
    keys = {
      q = false,                              -- disable default q-to-hide
      hide = { "<C-q>", "hide", mode = "n" }, -- use Ctrl-q to hide instead
    },
  },
  auto_close = false,
})
```

Workflow for these tools:
- **Double-Esc** — exit terminal insert mode
- **Ctrl-q** (normal mode) — hide the window, process keeps running
- **Same keymap** (e.g. `<leader>zs`) — reopen the hidden window

This pattern applies to any TUI tool where `q` has special meaning (e.g. database clients, interactive viewers).

## When to Use a Dedicated Plugin Instead

For most TUI tools, `Snacks.terminal.toggle` is sufficient. Consider a dedicated plugin when you need:

- **Deep Neovim integration** — e.g. `Snacks.lazygit()` auto-configures colorscheme themes and nvim-remote editing
- **File selection callbacks** — e.g. [yazi.nvim](https://github.com/mikavilpas/yazi.nvim) can open selected files in Neovim buffers
- **Output parsing / RPC** — tools that need to send structured data back to Neovim

| Tool | Generic (Snacks) | Dedicated Plugin |
|------|:-:|:-:|
| lazygit | OK | `Snacks.lazygit()` (built-in, recommended) |
| yazi | OK for browsing | `yazi.nvim` if you need file-open callbacks |
| gh dash | OK | `gh-dash.nvim` if used daily |
| btop, htop, k9s, etc. | Recommended | N/A |
