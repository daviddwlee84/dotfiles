-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- System clipboard integration for yank/paste
vim.opt.clipboard = "unnamedplus"

-- Route the + / * registers through OSC 52 (yank lands in the clipboard of
-- whatever terminal is attached) instead of the default provider shelling out
-- to a LOCAL pbcopy/wl-copy/xclip. The local tool is the wrong machine over
-- SSH, and a frozen/stale display inside herdr or zellij: their pane
-- environment is fixed at multiplexer-server start and never refreshed
-- ($WAYLAND_DISPLAY / $SSH_CONNECTION describe whoever launched the daemon),
-- while the pane TTY always proxies to the real client. tmux refreshes these
-- via update-environment, so a bare tmux session stays on the local provider.
--
-- X_CLIPBOARD=osc52 forces this on; X_CLIPBOARD=<any local tool> forces it off.
-- Keep the predicate in sync with `prefer_osc52` in dot_dotfiles/bin/executable_x.
local x_clipboard = vim.env.X_CLIPBOARD
local use_osc52 = x_clipboard == "osc52"
  or (
    not x_clipboard
    and (vim.env.SSH_CONNECTION or vim.env.SSH_TTY or vim.env.SSH_CLIENT or vim.env.HERDR_ENV or vim.env.ZELLIJ)
  )

if use_osc52 then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
end
