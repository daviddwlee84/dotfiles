-- e.g. in lua/plugins/gitsigns.lua (LazyVim/lazy.nvim)
return {
  "lewis6991/gitsigns.nvim",
  opts = {
    numhl = true,
    sign_priority = 15, -- higher than diagnostic,todo signs. lower than dapui breakpoint sign
    on_attach = function(bufnr)
      local gs = package.loaded.gitsigns

      local function map(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
      end

      map("n", "]h", gs.next_hunk, "Next Git hunk")
      map("n", "[h", gs.prev_hunk, "Prev Git hunk")

      map("n", "<leader>hp", gs.preview_hunk, "Preview hunk")
      map("n", "<leader>hP", gs.preview_hunk_inline, "Preview hunk inline")

      map("n", "<leader>hs", gs.stage_hunk, "Stage hunk")
      map("n", "<leader>hr", gs.reset_hunk, "Revert hunk")

      map("v", "<leader>hs", function()
        gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
      end, "Stage selection")
      map("v", "<leader>hr", function()
        gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
      end, "Revert selection")

      map("n", "<leader>hd", gs.toggle_deleted, "Toggle deleted (inline)")
    end,
  },
}
