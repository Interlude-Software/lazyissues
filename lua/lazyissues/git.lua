-- Detect which issue files have been edited on the current branch, so the UI
-- can flag them. "Edited on this branch" = committed since the merge-base with
-- the default branch, plus staged/unstaged/untracked working-tree changes.

local M = {}

local function git(root, args)
  local res = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
  if res.code ~= 0 then
    return nil
  end
  return res.stdout or ""
end

local function lines(text)
  local out = {}
  for line in (text or ""):gmatch("[^\n]+") do
    out[#out + 1] = line
  end
  return out
end

function M.repo_root(dir)
  local out = git(dir, { "rev-parse", "--show-toplevel" })
  return out and vim.trim(out) or nil
end

-- Best guess at the branch this work diverged from.
local function base_ref(root)
  local out = git(root, { "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })
  if out and vim.trim(out) ~= "" then
    return vim.trim(out) -- e.g. "origin/main"
  end
  for _, b in ipairs({ "main", "master" }) do
    if git(root, { "rev-parse", "--verify", "--quiet", b }) then
      return b
    end
  end
  return nil
end

-- Returns a set { [absolute issue/sprint dir] = true } of entities edited on
-- this branch. Empty table if not a git repo or on error.
function M.changed_dirs(data_root)
  local root = M.repo_root(data_root)
  if not root then
    return {}
  end

  local files = {}
  local function collect(text)
    for _, f in ipairs(lines(text)) do
      files[f] = true
    end
  end

  local base = base_ref(root)
  if base then
    collect(git(root, { "diff", "--name-only", base .. "...HEAD" }))
  end
  collect(git(root, { "diff", "--name-only", "HEAD" })) -- staged + unstaged
  collect(git(root, { "ls-files", "--others", "--exclude-standard" })) -- untracked

  local set = {}
  for rel in pairs(files) do
    if rel:match("/issue%.json$") or rel:match("/sprint%.json$") or rel:match("/release%.json$") then
      set[vim.fs.dirname(root .. "/" .. rel)] = true
    end
  end
  return set
end

return M
