-- Zoxide picker for jumping between projects without leaving Neovim.
--
-- Why this exists:
--   * Day-to-day cd between repos lives in tmux/sesh land, but when you're
--     deep in a 5-window nvim session and need to peek at another repo's file
--     ("how did I solve X over there?"), spawning a new tmux session adds
--     ceremony. <leader>fz lets you jump cwd-as-vim-cwd in-place.
--
-- Two modes:
--   <leader>fz   — pick a zoxide entry, change buffer-local cwd via :tcd
--                  (only this tab follows; other tabs keep their cwd)
--   <leader>fZ   — pick a zoxide entry, change global cwd via :cd
--                  (whole nvim session moves; matches LazyVim file-pickers'
--                   default scope)
--
-- Why :tcd as the default:
--   LazyVim auto-detects project root per buffer; switching global cwd can
--   make file-pickers do confusing things if you have buffers from multiple
--   projects open. :tcd keeps the change scoped to the current tab.
--
-- Falls back gracefully if `zoxide` binary isn't on PATH (no error, key just
-- does nothing — guard inside the function).

local function zoxide_pick(scope)
  if vim.fn.executable("zoxide") == 0 then
    vim.notify("zoxide not installed", vim.log.levels.WARN)
    return
  end

  -- Get scored list from zoxide. Format: "<score> <path>" per line.
  local out = vim.fn.systemlist({ "zoxide", "query", "--list", "--score" })
  if vim.v.shell_error ~= 0 or #out == 0 then
    vim.notify("zoxide DB is empty", vim.log.levels.INFO)
    return
  end

  -- Parse into snacks.picker items. Score is shown as a comment column.
  local items = {}
  for _, line in ipairs(out) do
    local score, path = line:match("^%s*([%d%.]+)%s+(.+)$")
    if score and path and vim.fn.isdirectory(path) == 1 then
      table.insert(items, {
        text = path,
        score_text = score,
        file = path,
        dir = path,
      })
    end
  end

  if #items == 0 then
    vim.notify("zoxide returned no valid directories", vim.log.levels.WARN)
    return
  end

  Snacks.picker({
    title = "Zoxide" .. (scope == "global" and " (cd)" or " (tcd)"),
    items = items,
    format = function(item)
      -- Two-column layout: score (right-aligned 8 chars) + path
      local short = item.text:gsub("^" .. vim.pesc(vim.env.HOME), "~")
      return {
        { ("%8s "):format(item.score_text), "Number" },
        { short, "Directory" },
      }
    end,
    preview = "directory",
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      local cmd = scope == "global" and "cd" or "tcd"
      vim.cmd(cmd .. " " .. vim.fn.fnameescape(item.dir))
      vim.notify(("%s %s"):format(cmd, item.dir), vim.log.levels.INFO)
    end,
  })
end

return {
  {
    "folke/snacks.nvim",
    keys = {
      {
        "<leader>fz",
        function() zoxide_pick("tab") end,
        desc = "Zoxide → :tcd (tab-local)",
      },
      {
        "<leader>fZ",
        function() zoxide_pick("global") end,
        desc = "Zoxide → :cd (global)",
      },
    },
  },
}
