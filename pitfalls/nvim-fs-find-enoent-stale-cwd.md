# nvim 0.12 startup ENOENT from vim.fs.find via avante / lualine / lazy checker

**Symptoms** (grep this section):

- `vim.schedule callback: vim/fs.lua:0: ENOENT: no such file or directory`
- `[C]: in function 'assert'` followed by `vim/fs.lua: in function 'find'`
- Source frames: `lazy/avante.nvim/lua/avante/utils/root.lua:106` (avante)
- Source frames: `lazy/LazyVim/lua/lazyvim/util/root.lua:55` (lualine)
- Often paired with: `lualine: Failed to refresh statusline: ... vim/fs.lua:0: ENOENT`
- Triggered from: `lazy/manage/checker.lua` (background plugin update check) or
  `lualine.refresh` immediately after startup
- One-shot at startup; nvim continues to function but the popup is noisy

**First seen**: 2026-04 (Neovim 0.12.1, macOS, Apple Silicon)
**Affects**: Neovim **0.12.x** + LazyVim + avante.nvim + lualine.nvim. Did not
occur on 0.11.x.
**Status**: workaround = `cd` to a real directory before launching nvim. No
upstream issue filed (regression in `runtime/lua/vim/fs.lua`).

## Symptom

Verbatim from a real session:

```
Error  20:05:51 msg_show.lua_error vim.schedule callback: vim/fs.lua:0: ENOENT: no such file or directory
stack traceback:
	[C]: in function 'assert'
	vim/fs.lua: in function 'find'
	...al/share/nvim/lazy/avante.nvim/lua/avante/utils/root.lua:106: in function <...al/share/nvim/lazy/avante.nvim/lua/avante/utils/root.lua:102>
	...al/share/nvim/lazy/avante.nvim/lua/avante/utils/root.lua:167: in function 'detect'
	...al/share/nvim/lazy/avante.nvim/lua/avante/utils/root.lua:206: in function 'get_project_root'
	...al/share/nvim/lazy/avante.nvim/lua/avante/suggestion.lua:43: in function 'new'
	...4/.local/share/nvim/lazy/avante.nvim/lua/avante/init.lua:425: in function '_init'
	...
	...al/share/nvim/lazy/lazy.nvim/lua/lazy/manage/checker.lua:43: in function 'fast_check'

Error  20:06:04 msg_show.lua_error vim.schedule callback: ...share/nvim/lazy/lualine.nvim/lua/lualine/utils/utils.lua:211: lualine: Failed to refresh statusline:
...ee84/.local/share/nvim/lazy/lualine.nvim/lua/lualine.lua:433: Lua: vim/fs.lua:0: ENOENT: no such file or directory
stack traceback:
	[C]: in function 'assert'
	vim/fs.lua: in function 'find'
	....local/share/nvim/lazy/LazyVim/lua/lazyvim/util/root.lua:55: in function <....local/share/nvim/lazy/LazyVim/lua/lazyvim/util/root.lua:52>
	....local/share/nvim/lazy/LazyVim/lua/lazyvim/util/root.lua:106: in function 'detect'
	...
```

Both stacks bottom out at the **same** `[C]: in function 'assert'` →
`vim/fs.lua: in function 'find'` frame.

## Root cause

In Neovim **0.12**, `runtime/lua/vim/fs.lua` added an unguarded `assert` on
the result of `vim.uv.cwd()` inside the upward-walking branch of
`vim.fs.find()`:

```lua
-- runtime/lua/vim/fs.lua, around line 716
local cwd = assert((iswin and prefix:match('^%w:$')) and uv.fs_realpath(prefix) or uv.cwd())
```

`uv.cwd()` returns `nil, "ENOENT", "ENOENT: no such file or directory"`
when the process's current working directory has been **deleted out from
under the running shell** — the classic cases:

- `git switch` / `git checkout` to a branch where the current directory
  doesn't exist
- `rm -rf` the directory you're sitting in (often via `yazi`, `oil`,
  `lazygit`, or another tmux pane)
- `mv` the parent directory away
- The shell that launched nvim was started in a directory that has since
  been deleted

When `uv.cwd()` returns nil, the `assert()` raises, which surfaces as the
generic `vim/fs.lua:0: ENOENT: no such file or directory` traceback —
**with no hint that the real culprit is a missing cwd**.

Two innocent callers happen to trigger this at startup:

1. **`avante.nvim`** (`utils/root.lua:106`) calls `vim.fs.find(..., { path =
   M.bufpath(buf) or vim.uv.cwd(), upward = true })` from
   `suggestion.lua:43` during `_init()`. If `bufpath` is nil for the
   current buffer (no name yet, scratch, dashboard), the fallback hits the
   stale cwd.
2. **`LazyVim`** (`util/root.lua:55`) does the same pattern, called from
   `util/lualine.lua` on every `lualine.refresh()` — so the error fires
   continuously, not just once.

The `lazy.nvim` checker frame (`lazy/manage/checker.lua:43 → git.lua:192
get_tag_refs`) is unrelated; it just happens to call `vim.fs.find` from a
scheduled callback at the same moment.

This is **not** a bug in avante, LazyVim, lualine, or lazy — they all worked
on 0.11. It's a Neovim 0.12 regression: the new assert in `vim.fs.find`
turns a previously-recoverable nil-cwd into a hard error.

## Workaround

**Immediate (per-session):** cd to a directory that exists and re-launch
nvim:

```sh
cd ~ && nvim
# or, from inside the broken nvim:
:cd ~
:e
```

To verify which side is wrong (your shell vs nvim itself):

```sh
pwd                    # if this errors, your shell's cwd is gone
ls "$(pwd)"            # confirm the dir actually exists on disk
nvim --headless -c 'lua print(vim.uv.cwd())' -c 'qa!'
# nil = stale cwd, the assert will fire
```

**Defensive (per-machine, optional):** add a pre-startup guard to your
shell rc — if `pwd` fails, jump to `$HOME` before launching interactive
tools. Not added to this repo's `dot_config/zsh/` because the failure mode
is loud enough to notice and the underlying state (`rm -rf $PWD`) usually
indicates the user already knows.

**Code-level workaround (not applied):** monkey-patch `vim.fs.find` to fall
back to `vim.fn.expand("~")` when `uv.cwd()` is nil, e.g. in
`dot_config/nvim/lua/config/options.lua`. Skipped because (a) upstream will
likely revert/guard the assert, (b) silently rewriting cwd hides genuine
state corruption, (c) the trigger is rare in practice.

## Prevention

- Don't `rm -rf` or `git switch`-away from the directory a long-lived
  shell is sitting in. If you must, `cd ~` first.
- Tools that delete-then-recreate the cwd (some `git worktree` workflows,
  container rebuilds, `mise` cache resets) are the most common root cause —
  prefer `cd` out before the destructive action.
- If you see the symptom *without* having deleted the cwd, the next
  suspect is your shell's `chpwd`/`precmd` racing with a background
  process; check `~/.config/zsh/` hooks.

Not graduated to a `AGENTS.md` Hard invariant: trigger is user-action-driven,
not a config-level trap that recurs across machines.

## Related

- Upstream source: `runtime/lua/vim/fs.lua` line ~716 in Neovim 0.12.x
  (`assert((iswin and prefix:match('^%w:$')) and uv.fs_realpath(prefix) or uv.cwd())`)
- Affected callers in this repo's plugin set:
  - `lazy/avante.nvim/lua/avante/utils/root.lua:106` (`detectors.pattern`)
  - `lazy/LazyVim/lua/lazyvim/util/root.lua:55` (also `detectors.pattern`)
- No upstream issue filed at neovim/neovim, avante.nvim, or LazyVim as of
  2026-04. If this recurs across multiple users, file at
  https://github.com/neovim/neovim/issues with the verbatim traceback and
  the `nvim --headless -c 'lua print(vim.uv.cwd())'` repro.
