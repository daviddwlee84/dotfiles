return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      -- The util.project extra inserts into preset.keys with key="P" and
      -- desc="Projects (util.project)". Fix to lowercase "p" and clean label.
      local keys = vim.tbl_get(opts, "dashboard", "preset", "keys")
      if keys then
        for _, key in ipairs(keys) do
          if key.desc and key.desc:match("Projects") then
            key.key = "p"
            key.desc = "Projects"
          end
        end
      end
    end,
  },
}
