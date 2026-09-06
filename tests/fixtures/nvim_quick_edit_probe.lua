-- Pure path-regression probe: no LazyVim install, plugins, network or real files.
local real_vim = vim
local source = os.getenv("NVIM_QUICK_EDIT_SOURCE")
assert(source and source ~= "")
local function check(path, env, windows, expected)
  local callback
  local buffer = {}
  local enabled
  vim = {
    env = env,
    uv = { fs_realpath = function(value) return value end },
    fn = {
      has = function() return windows and 1 or 0 end,
      fnamemodify = function(value) return value:gsub("\\", "/"):match("([^/]+)$") end,
    },
    b = setmetatable({}, { __index = function() return buffer end }),
    diagnostic = { enable = function(value) enabled = value end },
    api = {
      nvim_create_augroup = function() return 1 end,
      nvim_create_autocmd = function(_, spec) callback = spec.callback end,
      nvim_create_user_command = function() end,
      nvim_buf_get_name = function() return path end,
    },
  }
  dofile(source)
  callback({ buf = 1 })
  assert((buffer.quick_edit == true) == expected, "wrong quick-edit detection: " .. path)
  if expected then assert(buffer.autoformat == false and enabled == false) end
end
check([[C:\Users\Alice\AppData\Local\Temp\prompt.md]], { TEMP = [[c:/users/alice/appdata/local/temp]] }, true, true)
check([[C:\Scratch\prompt.md]], { TMP = [[C:\Scratch\]] }, true, true)
check([[C:\Scratch-other\prompt.md]], { TMP = [[C:\Scratch]] }, true, false)
check([[\\server\share\Temp\prompt.md]], { TEMP = [[\\SERVER\share\temp]] }, true, true)
check("/tmp/prompt.md", {}, false, true)
check("/tmp-other/prompt.md", {}, false, false)
check("/custom/temp/prompt.md", { TMPDIR = "/custom/temp/" }, false, true)
check("/project/.git/COMMIT_EDITMSG", {}, false, true)
check("/project/notes.md", {}, false, false)
check("/project/notes.md", { NVIM_QUICK_EDIT = "1" }, false, true)
check("/tmp/prompt.md", { NVIM_QUICK_EDIT = "0" }, false, false)
vim = real_vim
print("quick-edit paths: 11 cases passed")
