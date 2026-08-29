-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Locally, use the native system clipboard in both directions. Over SSH, herdr,
-- or zellij, only COPY through OSC 52: those environments need the attached
-- client's clipboard for yanks, but OSC 52 clipboard reads are commonly
-- unsupported (herdr does not forward query responses) and make ordinary `p`
-- block for up to ten seconds. In copy-only mode normal `p` stays on Neovim's
-- unnamed register; paste external clipboard text with the terminal's native
-- Cmd+V / Ctrl+Shift+V instead.
--
-- herdr/zellij pane environments are frozen at multiplexer-server start, so a
-- local pbcopy/wl-copy may target the wrong machine after a remote attach. The
-- pane TTY still proxies to the current client, making OSC 52 writes reliable.
-- X_CLIPBOARD=osc52 forces copy-only mode; a named local backend forces it off.
-- Keep this selection predicate in sync with `prefer_osc52` in executable_x,
-- but do NOT mirror x's paste backend: OSC 52 remains write-only here.
local x_clipboard = vim.env.X_CLIPBOARD
local clipboard_auto = not x_clipboard or x_clipboard == "" or x_clipboard == "auto"
local use_osc52 = x_clipboard == "osc52"
  or (
    clipboard_auto
    and (vim.env.SSH_CONNECTION or vim.env.SSH_TTY or vim.env.SSH_CLIENT or vim.env.HERDR_ENV or vim.env.ZELLIJ)
  )

if use_osc52 then
  vim.opt.clipboard = ""

  local osc52 = require("vim.ui.clipboard.osc52")
  local cache = {}

  local function copy(reg)
    local send = osc52.copy(reg)
    return function(lines, regtype)
      cache[reg] = { vim.deepcopy(lines), regtype }
      send(lines)
    end
  end

  local function paste(reg)
    return function()
      if cache[reg] then
        return vim.deepcopy(cache[reg])
      end
      vim.notify_once(
        "OSC 52 clipboard reads are unavailable here; use the terminal's native paste",
        vim.log.levels.WARN
      )
      return { { "" }, "v" }
    end
  end

  vim.g.clipboard = {
    name = "OSC 52 copy-only",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = 0,
  }

  local group = vim.api.nvim_create_augroup("osc52-copy-only", { clear = true })
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = group,
    desc = "Copy yanks to the attached terminal without making normal paste read OSC 52",
    callback = function()
      local event = vim.v.event
      if event.operator == "y" and event.regname ~= "_" and event.regname ~= "+" and event.regname ~= "*" then
        vim.fn.setreg("+", event.regcontents, event.regtype)
      end
    end,
  })
else
  vim.opt.clipboard = "unnamedplus"
end
