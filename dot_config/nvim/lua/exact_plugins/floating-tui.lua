return {
  {
    "folke/snacks.nvim",
    keys = {
      -- Git / GitHub
      {
        "<leader>zg",
        function()
          Snacks.terminal.toggle({ "gh", "dash" }, {
            cwd = LazyVim.root.git(),
            win = { title = " gh dash " },
          })
        end,
        desc = "gh dash",
      },
      -- NOTE: <leader>gg (LazyGit) is provided by LazyVim via Snacks.lazygit()

      -- Database
      {
        "<leader>zs",
        function()
          Snacks.terminal.toggle("sqlit", {
            win = { title = " sqlit " },
            -- Just use double ESC then q to quit the tool without killing the process
            -- win = {
            --   title = " sqlit ",
            --   keys = {
            --     q = false, -- sqlit uses q to goto query panel; disable Snacks' q-to-hide
            --     hide = { "<C-q>", "hide", mode = "n" }, -- use Ctrl-q to hide instead
            --   },
            -- },
            auto_close = false,
          })
        end,
        desc = "sqlit",
      },

      -- File Manager
      {
        "<leader>fy",
        function()
          Snacks.terminal.toggle("yazi", {
            cwd = vim.uv.cwd(),
            win = { title = " yazi " },
          })
        end,
        desc = "Yazi",
      },

      -- System Monitor
      {
        "<leader>zb",
        function()
          Snacks.terminal.toggle("btop", {
            win = { title = " btop " },
          })
        end,
        desc = "btop",
      },

      -- Container
      {
        "<leader>zd",
        function()
          Snacks.terminal.toggle("lazydocker", {
            win = { title = " lazydocker " },
          })
        end,
        desc = "LazyDocker",
      },

      -- REPL
      {
        "<leader>zi",
        function()
          Snacks.terminal.toggle("ipython", {
            cwd = vim.uv.cwd(),
            win = { title = " ipython " },
          })
        end,
        desc = "IPython",
      },

      ---- Uncomment any of the following to enable:

      -- { "<leader>zh", function() Snacks.terminal.toggle("htop",       { win = { title = " htop " } }) end, desc = "htop" },
      -- { "<leader>zk", function() Snacks.terminal.toggle("k9s",        { win = { title = " k9s " } }) end, desc = "k9s" },
      -- { "<leader>zn", function() Snacks.terminal.toggle("nnn",        { cwd = vim.uv.cwd(), win = { title = " nnn " } }) end, desc = "nnn" },
      -- { "<leader>zp", function() Snacks.terminal.toggle("bpython",    { cwd = vim.uv.cwd(), win = { title = " bpython " } }) end, desc = "bpython" },
      -- { "<leader>zr", function() Snacks.terminal.toggle("ratatui-counter", { win = { title = " ratatui " } }) end, desc = "ratatui" },
      -- { "<leader>zt", function() Snacks.terminal.toggle("tig",        { cwd = LazyVim.root.git(), win = { title = " tig " } }) end, desc = "tig" },

      -- DevOps / Infra
      -- { "<leader>zK", function() Snacks.terminal.toggle("kubectl-tui", { win = { title = " kubectl-tui " } }) end, desc = "kubectl-tui" },
      -- { "<leader>zc", function() Snacks.terminal.toggle("ctop",       { win = { title = " ctop " } }) end, desc = "ctop" },

      -- Database clients
      -- { "<leader>zS", function() Snacks.terminal.toggle("sqlite3",    { cwd = vim.uv.cwd(), win = { title = " sqlite3 " } }) end, desc = "sqlite3" },
      -- { "<leader>zm", function() Snacks.terminal.toggle("mycli",      { win = { title = " mycli " } }) end, desc = "mycli" },
      -- { "<leader>zP", function() Snacks.terminal.toggle("pgcli",      { win = { title = " pgcli " } }) end, desc = "pgcli" },

      -- Network
      -- { "<leader>zw", function() Snacks.terminal.toggle("bandwhich",  { win = { title = " bandwhich " } }) end, desc = "bandwhich" },
    },
  },
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>z", group = "TUI Tools" },
      },
    },
  },
}
