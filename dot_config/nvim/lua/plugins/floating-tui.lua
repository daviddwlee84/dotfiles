return {
  {
    "folke/snacks.nvim",
    keys = {
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
      {
        "<leader>zs",
        function()
          Snacks.terminal.toggle("sqlit", {
            win = { title = " sqlit " },
          })
        end,
        desc = "sqlit",
      },
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
      {
        "<leader>zb",
        function()
          Snacks.terminal.toggle("btop", {
            win = { title = " btop " },
          })
        end,
        desc = "btop",
      },
      {
        "<leader>zd",
        function()
          Snacks.terminal.toggle("lazydocker", {
            win = { title = " lazydocker " },
          })
        end,
        desc = "LazyDocker",
      },
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
