-- https://www.reddit.com/r/neovim/comments/156c9nh/how_to_use_tab_to_confirm_first_autocomplete_in/
-- https://github.com/LazyVim/LazyVim/discussions/39#discussioncomment-6069716
-- https://www.lazyvim.org/configuration/recipes
-- https://www.reddit.com/r/neovim/comments/19054s4/help_how_do_i_auto_complete_with_tab_in_lazyvim/
-- https://github.com/hrsh7th/nvim-cmp/wiki/Example-mappings#intellij-like-mapping
-- https://github.com/LazyVim/LazyVim/discussions/250
return {
  {
    "L3MON4D3/LuaSnip",
    keys = function()
      return {}
    end,
  },
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-emoji",
    },
    ---@param opts cmp.ConfigSchema
    opts = function(_, opts)
      local cmp = require("cmp")

      opts.mapping = vim.tbl_extend("force", opts.mapping, {
        ["<Tab>"] = cmp.mapping(function(fallback)
          -- This little snippet will confirm with tab, and if no entry is selected, will confirm the first item
          if cmp.visible() then
            local entry = cmp.get_selected_entry()
            if not entry then
              cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
            else
              cmp.confirm()
            end
          else
            fallback()
          end
        end, { "i", "s" }),
      })
    end,
  },
}
