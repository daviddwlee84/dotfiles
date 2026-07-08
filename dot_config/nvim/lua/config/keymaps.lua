-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Register <leader>t as "toggle" group in which-key
require("which-key").add({
  { "<leader>t", group = "toggle" },
})

-- 快速切換 Copilot 自動建議 (Ghost text)
vim.keymap.set("n", "<leader>tp", function()
  require("copilot.suggestion").toggle_auto_trigger()
  print("Copilot Auto Trigger Toggled")
end, { desc = "Toggle Copilot Auto Trigger" })

-- 複製 Cursor 風格的檔案 reference 到系統剪貼簿，方便貼給 Claude Code / Cursor:
--   @path  |  @path:12  |  @path:12-40
-- Normal mode -> 游標所在行；Visual mode -> 選取範圍；file-explorer -> 游標下的節點。

-- Resolve what the reference should point at: returns (absolute_path, allow_line).
-- Real file buffers -> the file, with line context. File-explorer buffers
-- (neo-tree now; snacks explorer after LazyVim's migration) -> the node under
-- the cursor, without line context. Anything else -> nil (caller warns).
local function copy_ref_target()
  if vim.bo.buftype == "" then
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" then
      return vim.fn.fnamemodify(name, ":p"), true
    end
    return nil
  end

  local ft = vim.bo.filetype
  local ok, path = pcall(function()
    if ft == "neo-tree" then
      -- mirror neo-tree's own copy-path (Y): node:get_id() is the abs path
      local mgr = require("neo-tree.sources.manager")
      local state = mgr.get_state_for_window(vim.api.nvim_get_current_win())
      local node = state and state.tree and state.tree:get_node()
      return node and (node.path or node:get_id()) or nil
    elseif ft == "snacks_picker_list" then
      -- snacks explorer (LazyVim's neo-tree successor); best-effort
      local picker = Snacks.picker.get({ source = "explorer" })[1]
      local item = picker and picker:current()
      return item and (item.file or item._path) or nil
    end
    return nil
  end)

  -- accept only an absolute path; anything else falls through to the warn
  if ok and type(path) == "string" and path:sub(1, 1) == "/" then
    return vim.fn.fnamemodify(path, ":p"), false
  end
  return nil
end

local function copy_reference(opts)
  local abspath, allow_line = copy_ref_target()
  if not abspath then
    vim.notify("copy-ref: no file under cursor here", vim.log.levels.WARN)
    return
  end

  -- path component
  local path
  if opts.absolute then
    path = abspath
  else
    -- pcall guards the nvim-0.12 vim.fs.find ENOENT-on-nil-cwd trap
    -- (pitfalls/nvim-fs-find-enoent-stale-cwd.md)
    local ok, root = pcall(function()
      return LazyVim.root.git()
    end)
    path = (ok and root and vim.fs.relpath(root, abspath)) or vim.fn.fnamemodify(abspath, ":~:.")
  end

  -- line component (only meaningful in a real file buffer)
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local suffix = ""
  if opts.lines and allow_line then
    if visual then
      local a, b = vim.fn.line("."), vim.fn.line("v")
      if a > b then
        a, b = b, a
      end
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

vim.keymap.set({ "n", "x" }, "<leader>yr", function()
  copy_reference({ lines = true })
end, { desc = "Ref: relative + line" })
vim.keymap.set({ "n", "x" }, "<leader>ya", function()
  copy_reference({ lines = true, absolute = true })
end, { desc = "Ref: absolute + line" })
vim.keymap.set({ "n", "x" }, "<leader>yf", function()
  copy_reference({})
end, { desc = "Ref: relative (file only)" })
vim.keymap.set({ "n", "x" }, "<leader>yF", function()
  copy_reference({ absolute = true })
end, { desc = "Ref: absolute (file only)" })
