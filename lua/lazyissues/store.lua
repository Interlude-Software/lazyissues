-- Load the on-disk issue tracker model: issues (as a nested tree mirroring the
-- folder hierarchy), sprints, and releases. Read-only for P0/P1.

local json = require("lazyissues.json")
local root = require("lazyissues.root")

local M = {}

-- Read a whole file as raw text (preserves exact bytes), or nil.
function M.read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

local function read_json(path)
  local text = M.read_file(path)
  if not text then
    return nil
  end
  local ok, decoded = pcall(json.decode, text)
  if not ok then
    return nil, decoded
  end
  return decoded
end

-- Is a name a GUID-shaped directory (issue/sprint/release id)?
local function is_guid(name)
  return name:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
    ~= nil
end

-- Iterate child directories of `dir` whose names are GUIDs.
local function guid_dirs(dir)
  local out = {}
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "directory" and is_guid(name) then
      out[#out + 1] = name
    end
  end
  return out
end

-- Recursively load an issue directory into a node:
--   { id, path, issue = <table|nil>, depth, children = { node, ... } }
local function load_issue_node(dir, id, depth)
  local node = { id = id, path = dir, depth = depth, children = {} }
  local issue = read_json(dir .. "/issue.json")
  node.issue = issue
  for _, child_id in ipairs(guid_dirs(dir)) do
    node.children[#node.children + 1] =
      load_issue_node(dir .. "/" .. child_id, child_id, depth + 1)
  end
  table.sort(node.children, function(a, b)
    local ca = a.issue and a.issue.CreatedAt or ""
    local cb = b.issue and b.issue.CreatedAt or ""
    return tostring(ca) < tostring(cb)
  end)
  return node
end

-- Load the full model from a data root.
function M.load(data_root)
  local model = {
    root = data_root,
    issues = {}, -- top-level issue nodes (tree)
    sprints = {}, -- { {id, ...sprint fields} }
    releases = {}, -- { {id, ...release fields} }
    index = {}, -- id -> node (flattened, all depths)
    template = nil, -- loaded template or nil
  }

  -- Template (optional).
  local tmpl = read_json(data_root .. "/template.json")
  if tmpl then
    model.template = tmpl
  end

  -- Issues (tree)
  local issues_dir = root.issues_dir(data_root)
  for _, id in ipairs(guid_dirs(issues_dir)) do
    model.issues[#model.issues + 1] =
      load_issue_node(issues_dir .. "/" .. id, id, 0)
  end
  table.sort(model.issues, function(a, b)
    local ca = a.issue and a.issue.CreatedAt or ""
    local cb = b.issue and b.issue.CreatedAt or ""
    return tostring(ca) < tostring(cb)
  end)

  -- Flatten into an index.
  local function index_node(node)
    model.index[node.id] = node
    for _, c in ipairs(node.children) do
      index_node(c)
    end
  end
  for _, node in ipairs(model.issues) do
    index_node(node)
  end

  -- Sprints (flat)
  for _, id in ipairs(guid_dirs(root.sprints_dir(data_root))) do
    local sp = read_json(root.sprints_dir(data_root) .. "/" .. id .. "/sprint.json")
    if sp then
      sp._path = root.sprints_dir(data_root) .. "/" .. id
      model.sprints[#model.sprints + 1] = sp
    end
  end

  -- Releases (flat; folder may not exist)
  for _, id in ipairs(guid_dirs(root.releases_dir(data_root))) do
    local rel = read_json(root.releases_dir(data_root) .. "/" .. id .. "/release.json")
    if rel then
      rel._path = root.releases_dir(data_root) .. "/" .. id
      model.releases[#model.releases + 1] = rel
    end
  end

  return model
end

return M
