return {
  {
    "yetone/avante.nvim",
    event = "VeryLazy",
    version = false,
    build = "make BUILD_FROM_SOURCE=true",
    opts = {
      -- Use Claude Code via ACP
      provider = "claude-code",
      -- ACP providers configuration
      acp_providers = {
        ["claude-code"] = {
          command = "claude-code-acp",
          args = {},
          env = {
            NODE_NO_WARNINGS = "1",
            ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY"),
          },
        },
      },
      -- Fallback to direct Claude API
      providers = {
        claude = {
          endpoint = "https://api.anthropic.com",
          model = "claude-sonnet-4-20250514",
          timeout = 30000,
          extra_request_body = {
            temperature = 0.75,
            max_tokens = 20480,
          },
        },
      },
    },
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "stevearc/dressing.nvim",
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      --- Optional dependencies
      "nvim-mini/mini.pick", -- for file_selector provider mini.pick (renamed from echasnovski/mini.pick)
      "nvim-telescope/telescope.nvim", -- for file_selector provider telescope
      "hrsh7th/nvim-cmp", -- autocompletion for avante commands and mentions
      "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
      "zbirenbaum/copilot.lua", -- for providers='copilot'
      {
        -- support for image pasting.
        --
        -- `drag_and_drop.insert_mode = true` would make img-clip override
        -- vim.paste() in insert mode, so EVERY paste (URLs, code, plain
        -- text) shells out to pngpaste/xclip to check whether the clipboard
        -- holds an image -- adding ~50-200ms per paste plus a "Content is
        -- not an image." notification each time. We keep drag-and-drop
        -- enabled in normal mode (drop a file/URL onto nvim -> markdown
        -- link) and rely on `:PasteImage` for explicit image paste; Avante
        -- buffers handle their own image flow independently.
        --
        -- `verbose = false` silences the "Content is not an image." toast
        -- that fires from any unrelated cmdline / lua paste.
        "HakonHarnes/img-clip.nvim",
        event = "VeryLazy",
        opts = {
          default = {
            embed_image_as_base64 = false,
            prompt_for_file_name = false,
            verbose = false,
            drag_and_drop = {
              insert_mode = false,
            },
          },
        },
      },
      {
        -- Make sure to set this up properly if you have lazy=true
        "MeanderingProgrammer/render-markdown.nvim",
        opts = {
          file_types = { "markdown", "Avante" },
        },
        ft = { "markdown", "Avante" },
      },
    },
  },
}
