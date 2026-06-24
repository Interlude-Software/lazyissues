-- Mutations: write issues to disk using the faithful encoder, mirroring the
-- .NET backend's behavior (whole-object writes, recursive delete, folder-based
-- re-parenting, server-side GUIDs, the one close/release-note validation rule).

local json = require("lazyissues.json")
local config = require("lazyissues.config")
local root = require("lazyissues.root")

local M = {}

local seeded = false
local function uuid4()
  if not seeded then
    math.randomseed(os.time() + math.floor(vim.uv.hrtime() % 1000000))
    seeded = true
  end
  return (string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

local function now_iso()
  -- UTC ISO 8601 with 7 fractional digits, matching the backend's DateTime "O".
  return os.date("!%Y-%m-%dT%H:%M:%S") .. ".0000000Z"
end

local function write_file(path, text)
  local fd, err = io.open(path, "wb")
  if not fd then
    return false, err
  end
  fd:write(text)
  fd:close()
  return true
end

local function blank(s)
  return s == nil or s == vim.NIL or vim.trim(tostring(s)) == ""
end

-- The backend's only validation rule (only applies when those fields exist).
function M.validate(it)
  if it.Status == "Closed" and it.ReleaseNoteType == "Public" and blank(it.ReleaseNote) then
    return false, "Cannot close an issue with a Public release note and an empty release note."
  end
  return true
end

-- Persist an issue table to <dir>/issue.json (whole-object write).
-- If a template is provided, uses the template's field order for encoding.
function M.save_issue(dir, it, template)
  if it.ReleaseNote ~= nil and type(it.ReleaseNote) == "string" then
    it.ReleaseNote = vim.trim(it.ReleaseNote)
  end
  local ok, err = M.validate(it)
  if not ok then
    return false, err
  end
  return write_file(dir .. "/issue.json", json.encode_issue(it, template))
end

-- Create a new issue. `parent_dir` nil => top-level under Issues/. Returns id, dir.
-- If a template exists, uses it for field defaults; otherwise falls back to hardcoded defaults.
function M.create_issue(data_root, fields, parent_dir)
  local template = M.load_template(data_root)
  local it, id
  if template then
    it, id = M.issue_from_template(template, fields)
  else
    id = uuid4()
    it = vim.tbl_extend("force", {
      Id = id,
      Type = config.issue_defaults.Type,
      Title = "",
      Description = "",
      SprintId = config.empty_guid,
      Status = config.issue_defaults.Status,
      Priority = config.issue_defaults.Priority,
      Reporter = "",
      Assignee = "",
      CreatedAt = now_iso(),
      UpdatedAt = vim.NIL,
      Tags = {},
      Comments = {},
      ReleaseNoteType = "None",
      ReleaseNote = "",
    }, fields or {})
    it.Id = id -- never let caller override
  end

  local base = parent_dir or root.issues_dir(data_root)
  local dir = base .. "/" .. id
  if vim.fn.mkdir(dir, "p") == 0 then
    return nil, nil, "could not create issue directory"
  end
  local ok, err = M.save_issue(dir, it, template)
  if not ok then
    return nil, nil, err
  end
  return id, dir
end

-- Recursively delete an issue directory (cascades to sub-issues, like the backend).
function M.delete_issue(dir)
  if vim.fn.delete(dir, "rf") ~= 0 then
    return false, "delete failed"
  end
  return true
end

-- Scaffold an Issues/ data root (Issues, Sprints, Releases) under repo_root.
function M.init_data_root(repo_root)
  local base = repo_root .. "/Issues"
  for _, sub in ipairs({ "Issues", "Sprints", "Releases" }) do
    vim.fn.mkdir(base .. "/" .. sub, "p")
    if vim.fn.isdirectory(base .. "/" .. sub) == 0 then
      return false, "could not create " .. sub
    end
  end
  return true, base
end

-- ── comments ─────────────────────────────────────────────────────────────

function M.add_comment(dir, it, author, body)
  if it.Comments == nil or it.Comments == vim.NIL then
    it.Comments = {}
  end
  table.insert(it.Comments, { Author = author or "", Body = body or "", CreatedAt = now_iso() })
  return M.save_issue(dir, it)
end

function M.delete_comment(dir, it, index)
  if not (it.Comments and it.Comments ~= vim.NIL and it.Comments[index]) then
    return false, "no such comment"
  end
  table.remove(it.Comments, index)
  return M.save_issue(dir, it)
end

-- ── sprints ──────────────────────────────────────────────────────────────

function M.save_sprint(dir, sp)
  if sp.ReleaseId == nil or sp.ReleaseId == vim.NIL then
    sp.ReleaseId = config.empty_guid
  end
  return write_file(dir .. "/sprint.json", json.encode_sprint(sp))
end

function M.create_sprint(data_root, fields)
  local id = uuid4()
  local sp = vim.tbl_extend("force", {
    Id = id,
    Name = "",
    Description = "",
    Status = "Planned",
    ReleaseId = config.empty_guid,
  }, fields or {})
  sp.Id = id
  local dir = root.sprints_dir(data_root) .. "/" .. id
  if vim.fn.mkdir(dir, "p") == 0 then
    return nil, nil, "could not create sprint directory"
  end
  local ok, err = M.save_sprint(dir, sp)
  if not ok then
    return nil, nil, err
  end
  return id, dir
end

function M.delete_sprint(dir)
  if vim.fn.delete(dir, "rf") ~= 0 then
    return false, "delete failed"
  end
  return true
end

-- ── releases ─────────────────────────────────────────────────────────────

function M.save_release(dir, rel)
  return write_file(dir .. "/release.json", json.encode_release(rel))
end

function M.create_release(data_root, fields)
  local id = uuid4()
  local rel = vim.tbl_extend("force", {
    Id = id,
    Name = "",
    Description = "",
    Status = "InDevelopment",
  }, fields or {})
  rel.Id = id
  local dir = root.releases_dir(data_root) .. "/" .. id
  if vim.fn.mkdir(dir, "p") == 0 then
    return nil, nil, "could not create release directory"
  end
  local ok, err = M.save_release(dir, rel)
  if not ok then
    return nil, nil, err
  end
  return id, dir
end

function M.delete_release(dir)
  if vim.fn.delete(dir, "rf") ~= 0 then
    return false, "delete failed"
  end
  return true
end

-- ── template ─────────────────────────────────────────────────────────────

-- Load template.json from the data root. Returns the parsed table or nil.
function M.load_template(data_root)
  local path = data_root .. "/template.json"
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(json.decode, text)
  if not ok then
    return nil
  end
  return decoded
end

-- Save a template table to Issues/template.json (pretty-printed).
function M.save_template(data_root, template)
  return write_file(data_root .. "/template.json", json.encode_template(template))
end

-- Build an issue table from the template (uses template fields + system fields).
function M.issue_from_template(template, fields)
  local id = uuid4()
  local it = {
    Id = id,
    CreatedAt = now_iso(),
    UpdatedAt = vim.NIL,
  }
  -- Apply template field defaults.
  for _, f in ipairs(template.fields) do
    local def = f.default
    if def == vim.NIL then
      def = nil
    end
    -- Deep-copy list defaults to avoid shared references.
    if f.type == "list" and type(def) == "table" then
      def = vim.deepcopy(def)
    end
    it[f.name] = def
  end
  -- Override with caller-provided fields.
  if fields then
    for k, v in pairs(fields) do
      it[k] = v
    end
  end
  it.Id = id -- never let caller override
  return it, id
end

-- Backfill a field into all existing issues under data_root.
function M.backfill_field(data_root, field_name, default_value)
  local issues_dir = root.issues_dir(data_root)
  local function walk(dir)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "directory" then
        local child = dir .. "/" .. name
        local issue_path = child .. "/issue.json"
        local fd = io.open(issue_path, "rb")
        if fd then
          local text = fd:read("*a")
          fd:close()
          local ok, it = pcall(json.decode, text)
          if ok and it then
            if it[field_name] == nil then
              it[field_name] = default_value
              M.save_issue(child, it)
            end
          end
        end
        walk(child)
      end
    end
  end
  walk(issues_dir)
end

-- Remove a field from all existing issues under data_root.
function M.remove_field_from_issues(data_root, field_name)
  local issues_dir = root.issues_dir(data_root)
  local function walk(dir)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, typ = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if typ == "directory" then
        local child = dir .. "/" .. name
        local issue_path = child .. "/issue.json"
        local fd = io.open(issue_path, "rb")
        if fd then
          local text = fd:read("*a")
          fd:close()
          local ok, it = pcall(json.decode, text)
          if ok and it then
            if it[field_name] ~= nil then
              it[field_name] = nil
              M.save_issue(child, it)
            end
          end
        end
        walk(child)
      end
    end
  end
  walk(issues_dir)
end

-- Move an issue dir under new_parent_dir (or to the issues root if nil).
-- Rejects moving into itself or a descendant.
function M.change_parent(data_root, issue_dir, issue_id, new_parent_dir)
  local target_base = new_parent_dir or root.issues_dir(data_root)
  local dest = target_base .. "/" .. issue_id
  if dest == issue_dir then
    return true -- no-op
  end
  if (target_base .. "/"):sub(1, #issue_dir + 1) == issue_dir .. "/" then
    return false, "cannot move an issue into itself or a descendant"
  end
  local ok = vim.uv.fs_rename(issue_dir, dest)
  if not ok then
    return false, "move failed"
  end
  return true, dest
end

return M
