-- Luacheck config for a Neovim plugin (pure Lua, Neovim 0.10+).
std = "lua54"
-- Neovim injects these globals at runtime.
read_globals = { "vim" }
-- Test harness mutates package.path; allow it.
globals = { "package" }
exclude_files = { "Issues/", "test/fixture/" }
max_line_length = false
-- 122: "setting read-only field of global vim" — writing vim.bo[buf].* is valid Neovim API.
ignore = { "122" }
