-- lua/sqlit_float/init.lua
local M = {}

---@class SqlitFloatConfig
---@field cmd string[]|string
---@field width number        -- 0~1
---@field height number       -- 0~1
---@field border string
---@field title string
---@field title_pos "center"|"left"|"right"
---@field winblend integer    -- 0~100
---@field persist boolean     -- keep terminal/job state between toggles
---@field close_key string    -- terminal-mode key to hide/close window, e.g. "<C-q>"
local default_config = {
  cmd = { "sqlit" },
  width = 0.9,
  height = 0.85,
  border = "rounded",
  title = " sqlit ",
  title_pos = "center",
  winblend = 0,
  persist = true,
  close_key = "<C-q>",
}

local state = {
  buf = nil, ---@type integer|nil
  win = nil, ---@type integer|nil
  job = nil, ---@type integer|nil
  config = default_config,
}

local function is_valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function calc_win_config()
  local columns = vim.o.columns
  local lines = vim.o.lines

  local w = math.floor(columns * state.config.width)
  local h = math.floor(lines * state.config.height)
  if w < 20 then
    w = 20
  end
  if h < 5 then
    h = 5
  end

  local row = math.floor((lines - h) / 2 - 1)
  local col = math.floor((columns - w) / 2)
  if row < 0 then
    row = 0
  end
  if col < 0 then
    col = 0
  end

  return {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
    style = "minimal",
    border = state.config.border,
    title = state.config.title,
    title_pos = state.config.title_pos,
  }
end

local function ensure_buf()
  if is_valid_buf(state.buf) then
    return
  end

  state.buf = vim.api.nvim_create_buf(false, true) -- listed=false, scratch=true

  -- ⚠️ 不要手動設 buftype=terminal，會 E474
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].bufhidden = state.config.persist and "hide" or "wipe"
end

local function set_buf_keymaps()
  if not is_valid_buf(state.buf) then
    return
  end

  -- ✅ 外層控制鍵：用 <C-q> 隱藏/關閉，避免搶走 sqlit 的 Esc / vim mode
  vim.keymap.set("t", state.config.close_key, function()
    M.close()
  end, { buffer = state.buf, silent = true, nowait = true, desc = "Hide/close floating TUI" })

  -- ✅ 需要時離開 terminal-mode：用內建的 <C-\><C-n>
  --（不做映射也行；這是 nvim 的預設行為）
end

local function open_window()
  ensure_buf()

  local win = vim.api.nvim_open_win(state.buf, true, calc_win_config())
  state.win = win

  vim.wo[win].winblend = state.config.winblend
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false

  set_buf_keymaps()

  return win
end

local function start_job_if_needed()
  if state.job and state.job > 0 then
    return
  end

  local cmd = state.config.cmd

  -- 讓 jobstart({term=true}) attach 到我們的 buffer
  vim.api.nvim_buf_call(state.buf, function()
    local job = vim.fn.jobstart(cmd, {
      term = true,
      on_exit = function()
        vim.schedule(function()
          state.job = nil
          -- job 結束就把 window 關掉；buffer 是否保留由 persist 決定
          if is_valid_win(state.win) then
            pcall(vim.api.nvim_win_close, state.win, true)
          end
          state.win = nil

          if not state.config.persist then
            state.buf = nil
          end
        end)
      end,
    })

    if job <= 0 then
      vim.notify("jobstart failed: " .. tostring(job), vim.log.levels.ERROR)
      return
    end

    state.job = job
  end)
end

function M.open()
  if is_valid_win(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end

  open_window()
  start_job_if_needed()

  -- 進入 terminal-mode（不綁 Esc，避免跟 sqlit vim-mode 衝突）
  vim.cmd("startinsert")
end

function M.close()
  if is_valid_win(state.win) then
    if state.config.persist then
      pcall(vim.api.nvim_win_hide, state.win) -- ✅ 隱藏，保留狀態
    else
      pcall(vim.api.nvim_win_close, state.win, true)
    end
  end
  state.win = nil

  if not state.config.persist then
    if state.job then
      pcall(vim.fn.jobstop, state.job)
    end
    state.job = nil
    if is_valid_buf(state.buf) then
      pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    end
    state.buf = nil
  end
end

function M.toggle()
  if is_valid_win(state.win) then
    M.close()
  else
    M.open()
  end
end

---@param cfg SqlitFloatConfig|nil
function M.setup(cfg)
  state.config = vim.tbl_deep_extend("force", {}, default_config, cfg or {})

  vim.api.nvim_create_user_command("SqlitFloatToggle", function()
    M.toggle()
  end, {})

  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if is_valid_win(state.win) then
        vim.api.nvim_win_set_config(state.win, calc_win_config())
      end
    end,
  })
end

return M
