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
-- Normal mode -> 游標所在行；Visual mode -> 選取範圍。
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
    local ok, root = pcall(function()
      return LazyVim.root.git()
    end)
    path = (ok and root and vim.fs.relpath(root, abspath)) or vim.fn.fnamemodify(abspath, ":~:.")
  end

  -- line component
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local suffix = ""
  if opts.lines then
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
