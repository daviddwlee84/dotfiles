-- LazyVim dashboard `Projects` (p) integration.
--
-- Two pieces:
--   1. Snacks picker `projects` dev sources — point at /Volumes/Data/Program
--      so `fd` discovers all repos under <group>/<repo> (e.g. JingleAI/X,
--      Personal/Y, Tadronaut/Z) up to maxdepth=2. Without this, the default
--      ~/dev and ~/projects don't exist on this machine, so picker only
--      shows oldfiles-derived git roots — a tiny subset of the 154 repos.
--
--   2. persistence.nvim — per-cwd session save/restore. Snacks's projects
--      picker default `confirm = "load_session"` calls `:lua
--      require("persistence").load()` after `:tcd`, which restores buffers,
--      windows, tabs, and even nvim-tree state from the last time you were
--      in that repo. Without persistence, `load_session` is a no-op and you
--      just get a `:tcd` + file picker.
--
-- Why /Volumes/Data/Program (not ~/Documents/Program):
--   ~/Documents/Program is a symlink to /Volumes/Data/Program. fd's
--   --absolute-path resolves through the symlink, so listing the canonical
--   side avoids duplicate entries in the picker.
--
-- Three pickers compared (all useful, different scope):
--   * `<leader>fp` (this) → snacks projects: oldfiles + dev fd, with session
--                           restore on confirm.
--   * `<leader>fz`        → custom zoxide picker: full 154-entry zoxide DB,
--                           plain :tcd, no session restore.
--   * `prefix+g` (tmux)   → sesh: spawn/switch tmux session per project,
--                           launches nvim+lazygit in fresh windows.
-- See docs/tools/sesh.md for the comparison table.

return {
  -- Persistence: per-cwd session save/restore. Snacks projects picker's
  -- `load_session` confirm action delegates to this plugin.
  {
    "folke/persistence.nvim",
    event = "BufReadPre",
    opts = {
      -- One session file per cwd, stored under stdpath("state")/sessions/
      options = { "buffers", "curdir", "tabpages", "winsize", "help", "globals", "skiprtp" },
      -- Don't auto-save sessions for ephemeral try-cli projects (they
      -- accumulate noise) or for the home dir (no project context).
      need = 1, -- save session when at least 1 buffer is open
    },
    keys = {
      { "<leader>qs", function() require("persistence").load() end,             desc = "Restore session (cwd)" },
      { "<leader>ql", function() require("persistence").load({ last = true }) end, desc = "Restore last session" },
      { "<leader>qd", function() require("persistence").stop() end,             desc = "Don't save current session" },
    },
  },

  -- Wire snacks picker projects to discover all Program repos.
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        sources = {
          projects = {
            dev = {
              -- Canonical path. Symlink ~/Documents/Program -> here is
              -- resolved via fd --absolute-path, so listing the canonical
              -- side prevents duplicates.
              "/Volumes/Data/Program",
            },
            -- Two-level fd: matches /Volumes/Data/Program/<group>/<repo>
            -- (e.g. JingleAI/AShare_T0_RL, Personal/career-ops). Bump if
            -- you have deeper layouts you want surfaced.
            max_depth = 2,
            -- Defaults preserved: patterns = .git/.hg/package.json/Makefile,
            -- recent = true (still includes oldfiles git roots),
            -- confirm = "load_session" (uses persistence.nvim above).
          },
        },
      },
    },
  },
}
