-- lazyissues: shared vocabulary mirrored from the reference tracker
-- (tasktrackerbackend models + tasktrackerfrontend display strings).

local M = {}

-- Enum value sets (stored values, exactly as the .NET backend serializes them).
M.issue_type = { "Bug", "Feature", "Task", "Improvement" }
M.issue_status = { "Open", "InProgress", "Resolved", "Closed" }
M.issue_priority = { "Low", "Medium", "High", "Critical" }
M.sprint_status = { "Planned", "Active", "Completed", "Archived" }
M.release_status = { "InDevelopment", "InProgress", "ReadyToPublish", "Published", "Error" }
M.release_note_type = { "None", "Public" }

-- Fixed pick-lists from the frontend.
M.assignees = { "Unassigned" }
M.comment_authors = {}

-- Defaults applied when a field is absent (older files) or on creation,
-- matching the backend model defaults.
M.empty_guid = "00000000-0000-0000-0000-000000000000"
M.issue_defaults = {
  Type = "Task",
  Title = "",
  Description = "",
  SprintId = M.empty_guid,
  Status = "Open",
  Priority = "Medium",
  Reporter = "",
  Assignee = "",
  Tags = {},
  Comments = {},
  ReleaseNoteType = "None",
  ReleaseNote = "",
}

-- Canonical field order for serialization (C# property declaration order).
M.issue_fields = {
  "Id", "Type", "Title", "Description", "SprintId", "Status", "Priority",
  "Reporter", "Assignee", "CreatedAt", "UpdatedAt", "Tags", "Comments",
  "ReleaseNoteType", "ReleaseNote",
}
M.comment_fields = { "Author", "Body", "CreatedAt" }
M.sprint_fields = { "Id", "Name", "Description", "Status", "ReleaseId" }
M.release_fields = { "Id", "Name", "Description", "Status" }

-- Predefined fields available in the template picker (excludes system fields:
-- Id, CreatedAt, UpdatedAt which are always present and auto-managed).
-- Each entry: { name, type, default, values (for enums) }.
M.predefined_fields = {
  { name = "Type", type = "enum", default = "Task", values = { "Bug", "Feature", "Task", "Improvement" } },
  { name = "Title", type = "string", default = "" },
  { name = "Description", type = "string", default = "" },
  { name = "Status", type = "enum", default = "Open", values = { "Open", "InProgress", "Resolved", "Closed" } },
  { name = "Priority", type = "enum", default = "Medium", values = { "Low", "Medium", "High", "Critical" } },
  { name = "SprintId", type = "string", default = M.empty_guid },
  { name = "Reporter", type = "string", default = "" },
  { name = "Assignee", type = "string", default = "" },
  { name = "Tags", type = "list", default = {} },
  { name = "Comments", type = "list", default = {} },
  { name = "ReleaseNoteType", type = "enum", default = "None", values = { "None", "Public" } },
  { name = "ReleaseNote", type = "string", default = "" },
  { name = "DueDate", type = "date", default = nil },
  { name = "Estimate", type = "number", default = nil },
  { name = "Labels", type = "list", default = {} },
  { name = "Environment", type = "enum", default = nil, values = { "Dev", "Staging", "Prod" } },
  { name = "Severity", type = "enum", default = nil, values = { "Cosmetic", "Minor", "Major", "Critical" } },
  { name = "Resolution", type = "enum", default = nil, values = { "Fixed", "WontFix", "Duplicate", "CannotReproduce" } },
}

-- Lookup predefined field definition by name.
M.predefined_field_map = {}
for _, f in ipairs(M.predefined_fields) do
  M.predefined_field_map[f.name] = f
end

-- Display labels and colors mirrored from the web UI (for later TUI rendering).
M.status_label = {
  Open = "Open",
  InProgress = "In Progress",
  Resolved = "Resolved",
  Closed = "Closed",
}

-- User-overridable UI preferences. (The enums/field-orders above are the fixed
-- backend contract and are NOT overridable.)
M.width = 0.92 -- float width as a fraction of the editor
M.height = 0.88 -- float height as a fraction of the editor
M.auto_refresh = true -- reload from disk when Neovim regains focus

function M.setup(opts)
  opts = opts or {}
  for _, k in ipairs({ "assignees", "comment_authors", "width", "height" }) do
    if opts[k] ~= nil then
      M[k] = opts[k]
    end
  end
  if opts.auto_refresh ~= nil then
    M.auto_refresh = opts.auto_refresh
  end
end

return M
