-- lazyissues: a lazygit-style TUI for the repo's file-based issue tracker.
-- Standalone — operates directly on <repo>/Issues/, no backend/server.

local M = {}

function M.open()
  require("lazyissues.ui.view").open()
end

function M.setup(opts)
  require("lazyissues.config").setup(opts)
  vim.api.nvim_create_user_command("LazyIssues", function()
    M.open()
  end, { desc = "Open the issue tracker browser" })
end

return M
