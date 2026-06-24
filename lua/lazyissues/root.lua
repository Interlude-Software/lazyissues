-- Locate a repository's Issues data root: the nearest ancestor `Issues/`
-- directory that contains an `Issues/` or `Sprints/` subfolder.

local M = {}

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

-- Returns the absolute path to the data root (".../Issues"), or nil.
function M.find(start)
  start = start or vim.fn.getcwd()
  local hits = vim.fs.find(function(name, path)
    if name ~= "Issues" then
      return false
    end
    local root = path .. "/Issues"
    return is_dir(root .. "/Issues") or is_dir(root .. "/Sprints")
  end, { path = start, upward = true, type = "directory", limit = 1 })

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
