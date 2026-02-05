return {
  "nvim-mini/mini.surround",
  opts = {
    mappings = {
      add = "gza", -- Normal mode: add surround
      delete = "gzd", -- Normal mode: delete surround
      replace = "gzr", -- Normal mode: replace surround
      -- The key change:
      suffix_last = "gS", -- Visual mode: add surround (end of selection)
      suffix_next = "gS", -- Visual mode: add surround (start of selection)
    },
  },
}
