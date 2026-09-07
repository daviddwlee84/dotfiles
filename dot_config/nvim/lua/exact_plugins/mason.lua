return {
  "mason-org/mason.nvim",
  opts = {
    -- LazyVim extends this list and installs only missing tools.
    -- Conform still prefers a project's node_modules/.bin/prettier.
    ensure_installed = { "prettier" },
  },
}
