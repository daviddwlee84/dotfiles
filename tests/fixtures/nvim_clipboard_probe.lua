local options_file = assert(vim.env.NVIM_CLIPBOARD_OPTIONS, "NVIM_CLIPBOARD_OPTIONS is required")
local action = vim.env.NVIM_CLIPBOARD_ACTION or "inspect"

local sent = {}
local notifications = {}
local paste_factory_calls = 0

package.loaded["vim.ui.clipboard.osc52"] = {
  copy = function(reg)
    return function(lines)
      table.insert(sent, { reg = reg, lines = vim.deepcopy(lines) })
    end
  end,
  paste = function()
    paste_factory_calls = paste_factory_calls + 1
    error("OSC 52 paste must not be configured")
  end,
}

vim.notify_once = function(message)
  table.insert(notifications, message)
end

dofile(options_file)

if action == "yank_and_paste" then
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta" })
  vim.cmd.normal({ args = { "yy" }, bang = true })
  vim.cmd.normal({ args = { "p" }, bang = true })
elseif action == "delete_and_paste" then
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta" })
  vim.cmd.normal({ args = { "dd" }, bang = true })
  vim.cmd.normal({ args = { "p" }, bang = true })
elseif action == "setreg_plus" then
  vim.fn.setreg("+", "@lua/config/options.lua:1")
  vim.g.test_cached_plus = vim.fn.getreg("+", 1, true)
elseif action == "empty_plus_paste" then
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha" })
  vim.cmd.normal({ args = { [["+p]] }, bang = true })
end

local provider = type(vim.g.clipboard) == "table" and vim.g.clipboard.name or nil
local result = {
  clipboard = vim.o.clipboard,
  provider = provider or vim.NIL,
  sent = sent,
  notifications = notifications,
  paste_factory_calls = paste_factory_calls,
  lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
  cached_plus = vim.g.test_cached_plus or vim.NIL,
}

io.stdout:write(vim.json.encode(result), "\n")
