-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- System clipboard integration for yank/paste
vim.opt.clipboard = "unnamedplus"

-- Over SSH, route the + / * registers through OSC 52 so yanks land in the
-- LOCAL terminal's clipboard. Without this, the default provider shells out
-- to pbcopy/xclip on the REMOTE host, which is useless for pasting locally.
-- Locally (no SSH), keep LazyVim's default provider so paste also works.
if vim.env.SSH_CONNECTION or vim.env.SSH_TTY then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
end
