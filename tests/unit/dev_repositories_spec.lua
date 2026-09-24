-- Run only with the isolated -u NONE/-i NONE runner; no user plugins load.
local source = assert(vim.env.NVIM_DEV_REPOSITORIES_SOURCE)
local repo = assert(vim.env.DEV_REPO_TEST_CHECKOUT)
local other = assert(vim.env.DEV_REPO_TEST_OTHER)
local plain = assert(vim.env.DEV_REPO_TEST_PLAIN)
local helper = assert(vim.env.DEV_REPO_TEST_HELPER)
local original_system = vim.system
local original_executable = vim.fn.executable
local original_exepath = vim.fn.exepath
local cwd = vim.fn.getcwd()
local oldfiles = vim.deepcopy(vim.v.oldfiles)
local notifications, requests, picks, opened
local picker_instances
local available, fallback_available
local tests = 0

local function equal(actual, expected, label)
  assert(vim.deep_equal(actual, expected), (label or "mismatch") .. ": " .. vim.inspect(actual))
end

local function row(path, fields)
  return vim.tbl_extend("force", {
    name = "same-name",
    display = "same-name",
    category = "work",
    path = path,
    real_path = assert(vim.uv.fs_realpath(path)),
  }, fields or {})
end

local function flush()
  vim.wait(10, function() return false end)
end

local function last_message(pattern)
  assert(#notifications > 0 and notifications[#notifications].message:find(pattern, 1, true),
    "missing notification " .. pattern .. ": " .. vim.inspect(notifications))
end

local function reset()
  notifications, requests, picks, opened, picker_instances = {}, {}, {}, {}, {}
  available, fallback_available = true, false
  vim.notify = function(message, level) notifications[#notifications + 1] = { message = message, level = level } end
  vim.fn.executable = function(command)
    if command == "dev-projects" then return available and 1 or 0 end
    if command == vim.fn.expand("~/.dotfiles/bin/dev-projects") then return fallback_available and 1 or 0 end
    return original_executable(command)
  end
  vim.fn.exepath = function(command)
    if command == "dev-projects" then return helper end
    return original_exepath(command)
  end
  vim.system = function(argv, opts, callback)
    local request = { argv = argv, opts = opts, callback = callback }
    requests[#requests + 1] = request
    return { kill = function(_, signal) request.killed = signal end }
  end
  local sources = {}
  local picker = setmetatable({ files = function(opts) opened[#opened + 1] = opts end }, {
    __call = function(_, opts)
      -- Match Snacks' real same-source toggle, rather than an append-only mock.
      if sources[opts.source] and not sources[opts.source].closed then
        sources[opts.source]:close()
        return
      end
      local instance = { closed = false }
      function instance:close()
        if self.closed then return end
        self.closed = true
        if opts.on_close then opts.on_close(self) end
      end
      sources[opts.source] = instance
      picker_instances[opts] = instance
      picks[#picks + 1] = opts
      return instance
    end,
  })
  package.loaded.snacks = { picker = picker }
  package.preload.persistence = function() error("persistence must not load") end
  package.preload.project_nvim = function() error("project_nvim must not load") end
  dofile(source)
end

local function command()
  vim.cmd("DevRepositories")
end

local function complete(index, result)
  requests[index].callback(vim.tbl_extend("force", { code = 0, stdout = "", stderr = "" }, result))
  flush()
end

local function catalog(rows)
  command()
  complete(1, { stdout = vim.json.encode(rows) })
  assert(#picks == 1, "expected custom picker")
  return picks[1]
end

local function select(picker, index)
  local instance = assert(picker_instances[picker])
  picker.confirm(instance, picker.items[index or 1])
  return instance.closed
end

local function test(name, fn)
  reset()
  fn()
  equal(vim.fn.getcwd(), cwd, "cwd changed in " .. name)
  equal(vim.v.oldfiles, oldfiles, "oldfiles changed in " .. name)
  tests = tests + 1
  print("ok " .. tests .. " - " .. name)
end

vim.keymap.set("n", "<leader>fp", "<Cmd>echo 'native projects'<CR>", { desc = "Native Projects" })
local native_mapping = vim.fn.maparg("<leader>fp", "n", false, true)

test("registration does not scan or replace native Projects", function()
  equal(#requests, 0)
  equal(#picks, 0)
  equal(#notifications, 0)
  equal(vim.fn.maparg("<leader>fp", "n", false, true), native_mapping)
  assert(vim.api.nvim_get_commands({}).DevRepositories)
end)

test("on-demand argv lookup and distinct safe labels", function()
  command()
  equal(requests[1].argv, { helper, "list", "--json" })
  equal(requests[1].opts, { text = true, timeout = 15000 })
  last_message("Loading dev repositories")
  complete(1, { stdout = vim.json.encode({ row(repo, { display = "same\27[31m\n中文", category = "wo\trk" }), row(other) }) })
  local picker = picks[1]
  equal(picker.source, "dev_repositories")
  equal(picker.finder, nil)
  equal(picker.preview, "none")
  assert(picker.items[1].text ~= picker.items[2].text)
  for _, item in ipairs(picker.items) do
    assert(not item.text:find("[%z\1-\31\127]"), "control character in match text")
    for _, chunk in ipairs(picker.format(item)) do
      assert(not chunk[1]:find("[%z\1-\31\127]"), "control character in rendered label")
    end
  end
  equal(picker.items[1].repo_path, repo)
end)

test("selection preserves special path argv and opens files only after Git validation", function()
  local picker = catalog({ row(repo) })
  assert(select(picker))
  equal(requests[2].argv, { "git", "-C", repo, "rev-parse", "--show-toplevel" })
  equal(requests[2].opts.timeout, 5000)
  equal(#opened, 0)
  complete(2, { stdout = repo .. "\n" })
  equal(opened, { { cwd = repo } })
end)

test("reopening an existing own picker shows fresh results and retains other pickers", function()
  local native = package.loaded.snacks.picker({ source = "native_projects", items = {} })
  picks = {}
  local first = catalog({ row(repo) })
  command()
  complete(2, { stdout = vim.json.encode({ row(other) }) })
  equal(#picks, 2)
  assert(picker_instances[first].closed, "old own picker was not closed")
  assert(not picker_instances[picks[2]].closed, "fresh picker was toggled off")
  assert(not native.closed, "unrelated native picker was closed")
  equal(picks[2].items[1].repo_path, other)
end)

test("reinvocation cancels and late callback cannot replace fresh results", function()
  command()
  command()
  equal(requests[1].killed, 15)
  equal(#requests, 1)
  last_message("cancelled")
  command()
  complete(2, { stdout = vim.json.encode({ row(other) }) })
  complete(1, { stdout = vim.json.encode({ row(repo) }) })
  equal(#picks, 1)
  equal(picks[1].items[1].repo_path, other)
end)

test("cancellation also invalidates a queued callback", function()
  command()
  requests[1].callback({ code = 0, stdout = vim.json.encode({ row(repo) }) })
  command()
  flush()
  equal(#picks, 0)
end)

test("selection validation can be cancelled without opening files", function()
  assert(select(catalog({ row(repo) })))
  command()
  equal(requests[2].killed, 15)
  complete(2, { stdout = repo .. "\n" })
  equal(#opened, 0)
end)

test("PATH helper takes priority over the executable fallback", function()
  fallback_available = true
  command()
  equal(requests[1].argv[1], helper)
end)

test("executable fallback works without PATH helper", function()
  available, fallback_available = false, true
  command()
  equal(requests[1].argv[1], vim.fn.expand("~/.dotfiles/bin/dev-projects"))
end)

test("missing helper explains how to recover", function()
  available = false
  command()
  equal(#requests, 0)
  last_message("dev-projects is unavailable")
end)

for _, case in ipairs({
  { "process failure", { code = 2, stderr = "bad\27[31m\nargument" }, "failed (exit 2)" },
  { "timeout", { code = 124 }, "timed out" },
  { "non-JSON output", { stdout = "not json" }, "expected a JSON array" },
  { "object output", { stdout = "{}" }, "expected a JSON array" },
  { "invalid row", { stdout = '[{"path":false}]' }, "invalid repository path" },
  { "empty catalog", { stdout = "[]" }, "No repositories found" },
}) do
  test(case[1], function()
    command()
    complete(1, case[2])
    equal(#picks, 0)
    last_message(case[3])
    assert(not notifications[#notifications].message:find("[%z\1-\31\127]"))
  end)
end

test("missing selected directory never starts Git", function()
  local picker = catalog({ row(repo, { path = repo .. "/missing" }) })
  assert(not select(picker))
  equal(#requests, 1)
  last_message("directory is missing")
end)

test("changed route is rejected before Git", function()
  local picker = catalog({ row(repo, { real_path = other }) })
  assert(not select(picker))
  equal(#requests, 1)
  last_message("Repository path changed")
end)

test("plain directories and paths inside a different checkout cannot open", function()
  assert(select(catalog({ row(plain) })))
  complete(2, { code = 128, stderr = "not a git repository" })
  equal(#opened, 0)
  command()
  complete(3, { stdout = vim.json.encode({ row(repo) }) })
  assert(select(picks[2]))
  complete(4, { stdout = other .. "\n" })
  equal(#opened, 0)
  last_message("no longer the same Git checkout")
end)

test("spawn failure clears pending state for retry", function()
  vim.system = function() error("spawn failed") end
  command()
  last_message("Could not start repository lookup")
  available = false
  command()
  last_message("dev-projects is unavailable")
end)

test("real helper subprocess and Git handle spaces, quotes, and CJK", function()
  vim.env.DEV_REPO_TEST_JSON = vim.json.encode({ row(repo) })
  vim.system = original_system
  command()
  assert(vim.wait(5000, function() return #picks == 1 end), "real helper did not finish")
  assert(select(picks[1]))
  assert(vim.wait(5000, function() return #opened == 1 end), "real Git validation did not finish")
  equal(opened, { { cwd = repo } })
end)

test("inherited Git identity cannot make a plain directory pass checkout validation", function()
  local saved_dir, saved_worktree = vim.env.GIT_DIR, vim.env.GIT_WORK_TREE
  vim.env.GIT_DIR = other .. "/.git"
  vim.env.GIT_WORK_TREE = plain
  local picker = catalog({ row(plain) })
  vim.system = original_system
  assert(select(picker))
  assert(vim.wait(5000, function()
    return notifications[#notifications].message:find("Checkout validation failed", 1, true) ~= nil
  end), "inherited Git context bypassed checkout validation")
  equal(#opened, 0)
  vim.env.GIT_DIR, vim.env.GIT_WORK_TREE = saved_dir, saved_worktree
end)

print("DevRepositories: " .. tests .. " cases passed")
