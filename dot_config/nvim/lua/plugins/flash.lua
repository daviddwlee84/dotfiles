return {
  "folke/flash.nvim",
  event = "VeryLazy",
  keys = {
    -- Disable S
    { "S", mode = { "n", "x", "o" }, false },
    -- Remap flash.nvim's jump function to "cl"
    {
      "cl",
      mode = { "n", "x", "o" },
      function()
        require("flash").jump()
      end,
      desc = "Flash jump",
    },
    -- Remap flash.nvim's treesitter function to "cc"
    {
      "cc",
      mode = { "n", "x", "o" },
      function()
        require("flash").treesitter()
      end,
      desc = "Flash treesitter",
    },
  },
  opts = {
    modes = {
      char = {
        -- Override the default key ("s") with "cl"
        keys = { "cl" },
      },
      treesitter = {
        -- Override the default key ("S") with "cc"
        keys = { "cc" },
      },
    },
  },
}
