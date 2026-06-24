-- Visual vocabulary mirrored from the web UI (colors + glyphs).

local M = {}

M.status_glyph = {
  Open = "●",
  InProgress = "◐",
  Resolved = "◆",
  Closed = "✓",
}

M.status_hl = {
  Open = "LazyIssuesOpen",
  InProgress = "LazyIssuesInProgress",
  Resolved = "LazyIssuesResolved",
  Closed = "LazyIssuesClosed",
}

M.type_hl = {
  Bug = "LazyIssuesBug",
  Feature = "LazyIssuesFeature",
  Task = "LazyIssuesTaskType",
  Improvement = "LazyIssuesImprovement",
}

M.priority_hl = {
  Low = "LazyIssuesLow",
  Medium = "LazyIssuesMedium",
  High = "LazyIssuesHigh",
  Critical = "LazyIssuesCritical",
}

function M.glyph(status)
  return M.status_glyph[status] or "•"
end

-- Define highlight groups (idempotent; default=true so themes can override).
function M.setup()
  local hl = {
    LazyIssuesOpen = { fg = "#4caf50" },
    LazyIssuesInProgress = { fg = "#FC9E4F" },
    LazyIssuesResolved = { fg = "#3454D1" },
    LazyIssuesClosed = { fg = "#777777", strikethrough = true },
    LazyIssuesBug = { fg = "#FFA500" },
    LazyIssuesFeature = { fg = "#5c6bc0" },
    LazyIssuesTaskType = { fg = "#4caf50" },
    LazyIssuesImprovement = { fg = "#ff9800" },
    LazyIssuesLow = { fg = "#6ab04c" },
    LazyIssuesMedium = { fg = "#b8b85a" },
    LazyIssuesHigh = { fg = "#ff5252" },
    LazyIssuesCritical = { fg = "#ff1744", bold = true },
    -- Edited-on-this-branch markers.
    LazyIssuesChanged = { fg = "#e0af68" },
    LazyIssuesChangedDim = { fg = "#8a7a55" },
    -- Footer shortcut bar — brighter than Comment so it reads clearly.
    LazyIssuesFooter = { fg = "#b8c0e0" },
  }
  for name, spec in pairs(hl) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  -- Links (respect the active colorscheme).
  local links = {
    LazyIssuesHeader = "Title",
    LazyIssuesLabel = "Comment",
    LazyIssuesDim = "Comment",
    LazyIssuesActive = "PmenuSel",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

return M
