-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- ---------------------------------------------------------------------------
-- Quick-edit mode: when nvim is invoked as $EDITOR by another tool (OpenCode
-- ctrl+x+e, Claude Code ctrl+g, `crontab -e`, `git commit`, etc.), the buffer
-- is a throwaway scratch file under a tempdir. We don't want markdownlint
-- diagnostics or format-on-save mangling the agent's prompt or the cron line
-- the user is typing.
--
-- Detection (heuristic, two-track):
--
--   1. Path-based: buffer's full path lives under a known tempdir prefix
--      ($TMPDIR, /tmp, /var/folders, /private/var/folders) OR matches a
--      known scratch-file pattern (crontab.*, COMMIT_EDITMSG, *.tmp.*).
--   2. Env-based explicit override: NVIM_QUICK_EDIT=1 forces ON,
--      NVIM_QUICK_EDIT=0 forces OFF (escape hatches for either direction).
--
-- When quick-edit is detected we:
--   - set `vim.b.autoformat = false` (LazyVim's per-buffer format-on-save toggle)
--   - disable diagnostics for that buffer (kills MD034 et al.)
--   - leave LSP, treesitter, syntax highlight, keymaps untouched -- still
--     a usable editor, just no autofix / red squigglies.
--
-- Toggle manually with `:QuickEditMode` if you need to flip it mid-session.
-- ---------------------------------------------------------------------------

local function tempdir_prefixes()
  local prefixes = { "/tmp/", "/var/folders/", "/private/var/folders/", "/private/tmp/" }
  local tmpdir = vim.env.TMPDIR
  if tmpdir and tmpdir ~= "" then
    -- normalise: ensure trailing slash, resolve symlinks
    local resolved = vim.uv.fs_realpath(tmpdir) or tmpdir
    if not resolved:match("/$") then
      resolved = resolved .. "/"
    end
    table.insert(prefixes, resolved)
  end
  return prefixes
end

local function is_quick_edit_path(path)
  if not path or path == "" then
    return false
  end
  local resolved = vim.uv.fs_realpath(path) or path

  -- Path under a known tempdir
  for _, prefix in ipairs(tempdir_prefixes()) do
    if resolved:sub(1, #prefix) == prefix then
      return true
    end
  end

  -- Known scratch-file basenames regardless of location
  local base = vim.fn.fnamemodify(resolved, ":t")
  local patterns = {
    "^crontab%.", -- crontab -e -> /tmp/crontab.XXXXXX/crontab on some systems
    "^COMMIT_EDITMSG$", -- git commit (.git/COMMIT_EDITMSG)
    "^MERGE_MSG$",
    "^TAG_EDITMSG$",
    "^EDIT_DESCRIPTION$", -- gh / glab PR description editor
    "%.tmp%.", -- generic *.tmp.* (OpenCode, Claude Code)
  }
  for _, pat in ipairs(patterns) do
    if base:match(pat) then
      return true
    end
  end
  return false
end

local function detect_quick_edit(bufnr)
  -- Explicit env override wins
  local env = vim.env.NVIM_QUICK_EDIT
  if env == "1" or env == "true" then
    return true
  end
  if env == "0" or env == "false" then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return is_quick_edit_path(name)
end

local function apply_quick_edit(bufnr, on)
  vim.b[bufnr].autoformat = not on -- LazyVim format-on-save per-buffer toggle
  vim.b[bufnr].quick_edit = on
  vim.diagnostic.enable(not on, { bufnr = bufnr })
end

vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("user_quick_edit", { clear = true }),
  callback = function(args)
    if detect_quick_edit(args.buf) then
      apply_quick_edit(args.buf, true)
    end
  end,
})

vim.api.nvim_create_user_command("QuickEditMode", function(opts)
  local arg = (opts.args or ""):lower()
  local bufnr = vim.api.nvim_get_current_buf()
  local target
  if arg == "on" then
    target = true
  elseif arg == "off" then
    target = false
  else
    target = not vim.b[bufnr].quick_edit
  end
  apply_quick_edit(bufnr, target)
  vim.notify("QuickEditMode: " .. (target and "ON (no lint, no format-on-save)" or "OFF"))
end, {
  nargs = "?",
  complete = function()
    return { "on", "off" }
  end,
  desc = "Toggle quick-edit mode for current buffer (no lint, no format-on-save)",
})
