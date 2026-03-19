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
