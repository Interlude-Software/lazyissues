-- Locate a repository's Issues data root: the nearest ancestor `Issues/`
-- directory that contains an `Issues/` or `Sprints/` subfolder.

local git = require("lazyissues.git")

local M = {}

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

-- Returns the absolute path to the data root (".../Issues"), or nil.
function M.find(start)
  start = start or vim.fn.getcwd()
  -- Bound the upward walk to the current project: search `start` up to (and
  -- including) its git repo root, but never past it. Otherwise opening in a
  -- repo with no Issues/ would climb into an unrelated ancestor that happens to
  -- contain one (e.g. a sibling project under a shared parent dir).
  local boundary = git.repo_root(start) or start
  local stop = vim.fs.dirname(boundary)
  local hits = vim.fs.find(function(name, path)
    if name ~= "Issues" then
      return false
    end
    local root = path .. "/Issues"
    return is_dir(root .. "/Issues") or is_dir(root .. "/Sprints")
  end, { path = start, upward = true, type = "directory", limit = 1, stop = stop })

  if hits[1] then
    return hits[1]
  end
  -- Also handle being *inside* the data root already (cwd == <repo>/Issues).
  if is_dir(start .. "/Issues") or is_dir(start .. "/Sprints") then
    if vim.fs.basename(start) == "Issues" then
      return start
    end
  end
  return nil
end

function M.issues_dir(root)
  return root .. "/Issues"
end
function M.sprints_dir(root)
  return root .. "/Sprints"
end
function M.releases_dir(root)
  return root .. "/Releases"
end

return M
