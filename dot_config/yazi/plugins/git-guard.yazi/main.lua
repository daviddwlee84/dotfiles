-- Compatibility fetcher for the managed git.yazi dependency.
--
-- Current git.yazi requires Yazi 26.8.15. Dotfile application is install-only,
-- so a host may receive the new lockfile/config before its explicit package
-- upgrade. Cache the load attempt: compatible hosts delegate every job to the
-- real plugin; older or incomplete hosts use Yazi's version-matched noop
-- fetcher and remain fully usable.

local M = {}
local checked = false
local available = false
local git = nil

local function load_git()
	if not checked then
		checked = true
		available, git = pcall(require, "git")
	end
	return available and git or nil
end

function M:fetch(job)
	local plugin = load_git()
	if plugin then
		return plugin:fetch(job)
	end
	return require("noop"):fetch(job)
end

return M
