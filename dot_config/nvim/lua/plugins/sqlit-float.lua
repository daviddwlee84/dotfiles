return {
  -- 你可以用本地路徑；或之後發佈成 Git repo
  dir = vim.fn.stdpath("config") .. "/lua/sqlit_float",
  name = "sqlit-float",
  config = function()
    require("sqlit_float").setup({
      cmd = { "sqlit" }, -- 想換工具就改這裡：{ "k9s" } / { "btop" } / { "htop" }
      width = 0.9,
      height = 0.85,
      border = "rounded",
      title = " sqlit ",
      winblend = 0,
    })

    -- 你要的：leader + combo
    vim.keymap.set("n", "<leader>zs", function()
      require("sqlit_float").toggle()
    end, { desc = "Toggle sqlit (floating)" })
  end,
}
