local function toggle_diffview(cmd)
  if next(require("diffview.lib").views) == nil then
    vim.cmd(cmd)
  else
    vim.cmd("DiffviewClose")
  end
end

return {
  "sindrets/diffview.nvim",
  command = "DiffviewOpen",
  cond = is_git_root,
  keys = {
    {
      "<leader>gd",
      function()
        toggle_diffview("DiffviewOpen")
      end,
      desc = "Diff Index",
    },
    {
      "<leader>gD",
      function()
        toggle_diffview("DiffviewOpen master..HEAD")
      end,
      desc = "Diff master",
    },
    {
      "<leader>gf",
      function()
        toggle_diffview("DiffviewFileHistory %")
      end,
      desc = "Open diffs for current File",
    },
  },
}
