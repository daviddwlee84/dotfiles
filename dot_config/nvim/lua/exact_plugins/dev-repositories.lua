-- An on-demand view of dev's repository catalog. Native Projects, recent
-- directories, and persistence sessions keep their own sources and behavior.
local pending
local active_picker

local function printable(value)
  return vim.fn.strtrans(value)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Dev Repositories" })
end

local function helper_path()
  if vim.fn.executable("dev-projects") == 1 then
    return vim.fn.exepath("dev-projects")
  end
  local fallback = vim.fn.expand("~/.dotfiles/bin/dev-projects")
  if vim.fn.executable(fallback) == 1 then
    return fallback
  end
end

local function run(argv, timeout, callback)
  local request = {}
  pending = request
  local options = { text = true, timeout = timeout }
  if argv[1] == "git" then
    -- -C cannot override inherited GIT_DIR/GIT_WORK_TREE or injected config.
    -- Keep the ordinary environment, but let this checkout determine Git's
    -- repository, index, object store and discovery context.
    options.env = vim.fn.environ()
    for key in pairs(options.env) do
      if key:match("^GIT_") then
        options.env[key] = nil
      end
    end
    options.env.GIT_OPTIONAL_LOCKS = "0"
    options.env.GIT_TERMINAL_PROMPT = "0"
    options.clear_env = true
  end
  local ok, process = pcall(vim.system, argv, options, function(result)
    vim.schedule(function()
      if pending ~= request then
        return -- Cancelled, or a later request has replaced this one.
      end
      pending = nil
      callback(result)
    end)
  end)
  if ok then
    request.process = process
  else
    pending = nil
    notify("Could not start repository lookup: " .. printable(tostring(process)), vim.log.levels.ERROR)
  end
end

local function process_error(result, action)
  if result.code == 124 then
    notify(action .. " timed out. Run :DevRepositories to try again.", vim.log.levels.WARN)
    return true
  end
  if result.code ~= 0 then
    local detail = printable((result.stderr or ""):sub(1, 300))
    notify(action .. " failed (exit " .. tostring(result.code) .. ")." .. (detail ~= "" and " " .. detail or ""), vim.log.levels.ERROR)
    return true
  end
  return false
end

local function open_repository(picker, item)
  if not item then
    return
  end
  if pending then
    notify("A repository lookup is pending. Run :DevRepositories to cancel it first.", vim.log.levels.WARN)
    return
  end
  local path = item.repo_path
  local stat = vim.uv.fs_stat(path)
  local real_path = vim.uv.fs_realpath(path)
  if not stat or stat.type ~= "directory" or not real_path then
    notify("Repository directory is missing: " .. printable(path) .. ". Reload :DevRepositories.", vim.log.levels.WARN)
    return
  end
  if real_path ~= item.repo_real_path then
    notify("Repository path changed. Reload :DevRepositories before opening it.", vim.log.levels.WARN)
    return
  end
  if vim.fn.executable("git") ~= 1 then
    notify("Git is required to validate the selected checkout.", vim.log.levels.ERROR)
    return
  end
  picker:close()
  notify("Checking " .. printable(path) .. "… Run :DevRepositories again to cancel.")
  run({ "git", "-C", path, "rev-parse", "--show-toplevel" }, 5000, function(result)
    if process_error(result, "Checkout validation") then
      return
    end
    local top = (result.stdout or ""):gsub("\r?\n$", "")
    if vim.uv.fs_realpath(path) ~= real_path or vim.uv.fs_realpath(top) ~= real_path then
      notify("Selected directory is no longer the same Git checkout. Reload :DevRepositories.", vim.log.levels.WARN)
      return
    end
    require("snacks").picker.files({ cwd = path })
  end)
end

local function show_repositories(result)
  if process_error(result, "Repository lookup") then
    return
  end
  local ok, rows = pcall(vim.json.decode, result.stdout or "")
  if not ok or type(rows) ~= "table" or not vim.islist(rows) then
    notify("dev-projects returned invalid data; expected a JSON array of repositories.", vim.log.levels.ERROR)
    return
  end
  local items = {}
  for _, row in ipairs(rows) do
    if type(row) ~= "table" or type(row.path) ~= "string" or row.path == ""
      or row.path:find("\0", 1, true) or type(row.real_path) ~= "string" or row.real_path == ""
      or row.real_path:find("\0", 1, true) then
      notify("dev-projects returned an invalid repository path. Update the helper and retry.", vim.log.levels.ERROR)
      return
    end
    local name = type(row.display) == "string" and row.display ~= "" and row.display
      or type(row.name) == "string" and row.name ~= "" and row.name or row.path
    local category = type(row.category) == "string" and row.category or ""
    local label, group, route = printable(name), printable(category), printable(row.path)
    items[#items + 1] = {
      text = label .. " " .. group .. " " .. route,
      label = label,
      category = group,
      route = route,
      repo_path = row.path,
      repo_real_path = row.real_path,
    }
  end
  if #items == 0 then
    notify("No repositories found in dev's configured scan roots.")
    return
  end
  -- Snacks toggles an existing picker with the same source closed. Close only
  -- our previous instance first so a fresh request always displays fresh data.
  if active_picker then
    active_picker:close()
  end
  active_picker = require("snacks").picker({
    source = "dev_repositories",
    title = "Dev Repositories",
    items = items,
    preview = "none",
    layout = { preview = false },
    format = function(item)
      return {
        { item.label, "Title" },
        { item.category ~= "" and "  [" .. item.category .. "]" or "", "Comment" },
        { "  " .. item.route, "Directory" },
      }
    end,
    confirm = open_repository,
    on_close = function(picker)
      if active_picker == picker then
        active_picker = nil
      end
    end,
    -- These generic file actions must take the same checkout-validation path.
    actions = { jump = open_repository, edit_split = open_repository, edit_vsplit = open_repository, tab = open_repository },
  })
end

local function dev_repositories()
  if pending then
    local request = pending
    pending = nil -- Invalidate even a callback already queued on the main loop.
    if request.process then
      pcall(request.process.kill, request.process, 15)
    end
    notify("Repository lookup cancelled. Run :DevRepositories again to reload.")
    return
  end
  local helper = helper_path()
  if not helper then
    notify("dev-projects is unavailable. Install the managed helper or add it to PATH.", vim.log.levels.WARN)
    return
  end
  if type(vim.system) ~= "function" then
    notify("DevRepositories requires Neovim 0.10 or newer (vim.system).", vim.log.levels.ERROR)
    return
  end
  notify("Loading dev repositories… Run :DevRepositories again to cancel.")
  run({ helper, "list", "--json" }, 15000, show_repositories)
end

-- Register without replacing Snacks' shared init/config hooks. Parsing this
-- plugin spec does not run dev, Git, a picker, or any history/session plugin.
vim.api.nvim_create_user_command("DevRepositories", dev_repositories, {
  desc = "Browse dev repositories (run again to cancel a pending lookup)",
})

return { { "folke/snacks.nvim" } }
