-- lazyissues read-only browser: a lazygit-style float of stacked panels.
-- Panels: Scopes / Sprints / Releases (left) | Issues tree (center) | Detail (right).

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local NuiLine = require("nui.line")

local config = require("lazyissues.config")
local store = require("lazyissues.store")
local root = require("lazyissues.root")
local gitmod = require("lazyissues.git")
local actions = require("lazyissues.actions")
local icons = require("lazyissues.ui.icons")

local M = {}

local ns = vim.api.nvim_create_namespace("lazyissues_view")

-- The single active view is tracked in M._view; each function receives it as `V`.

-- ── helpers ────────────────────────────────────────────────────────────────

local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

local function hl(bufnr, group, line, c0, c1)
  vim.api.nvim_buf_add_highlight(bufnr, ns, group, line, c0 or 0, c1 or -1)
end

local function short(id)
  return tostring(id):sub(1, 8)
end

-- Centered input popup. Single-line by default (Enter confirms); pass
-- opts.multiline for a taller, wrapping editor (Ctrl-s saves, Esc cancels).
-- opts.width / opts.height override the size. Mirrors vim.ui.input's contract:
-- on_accept gets the text on confirm, nil on cancel.
local function prompt_input(label, default, on_accept, opts)
  opts = opts or {}
  local multiline = opts.multiline
  local pop = Popup({
    enter = true,
    border = {
      style = "rounded",
      highlight = "LazyIssuesBorder",
      text = {
        top = " " .. vim.trim(label) .. " ",
        top_align = "center",
        bottom = multiline and " Ctrl-s save · Esc cancel " or " Enter confirm · Esc cancel ",
        bottom_align = "center",
      },
    },
    position = "50%",
    size = {
      width = opts.width or (multiline and "60%" or "70%"),
      height = opts.height or (multiline and "40%" or 1),
    },
    zindex = 60,
    buf_options = { modifiable = true, filetype = multiline and "markdown" or "" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder", wrap = multiline or false },
  })
  pop:mount()
  vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, vim.split(tostring(default or ""), "\n", { plain = true }))
  local finished = false
  local function finish(accept)
    if finished then
      return
    end
    finished = true
    local txt
    if accept then
      local lines = vim.api.nvim_buf_get_lines(pop.bufnr, 0, -1, false)
      txt = multiline and table.concat(lines, "\n") or (lines[1] or "")
    end
    pcall(function()
      pop:unmount()
    end)
    if on_accept then
      on_accept(txt)
    end
  end
  if multiline then
    -- Enter inserts a newline; Ctrl-s saves; Esc/q (normal mode) cancels.
    vim.keymap.set({ "n", "i" }, "<C-s>", function()
      finish(true)
    end, { buffer = pop.bufnr })
    for _, k in ipairs({ "<Esc>", "q" }) do
      vim.keymap.set("n", k, function()
        finish(false)
      end, { buffer = pop.bufnr })
    end
  else
    vim.keymap.set({ "n", "i" }, "<CR>", function()
      finish(true)
    end, { buffer = pop.bufnr })
    vim.keymap.set({ "n", "i" }, "<Esc>", function()
      finish(false)
    end, { buffer = pop.bufnr })
  end
  -- Cursor at the end of the prefilled content.
  local last = vim.api.nvim_buf_line_count(pop.bufnr)
  local last_line = vim.api.nvim_buf_get_lines(pop.bufnr, last - 1, last, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, pop.winid, { last, #last_line })
  vim.cmd("startinsert!")
end

-- Centered menu popup. `items` is a list of strings, or { text=, value= } tables.
-- on_choice receives the chosen value on select, or nil on cancel. Mirrors
-- vim.ui.select's contract so callers can swap it in directly.
local function prompt_select(label, items, on_choice)
  local Menu = require("nui.menu")
  local menu_items, width = {}, 0
  for _, entry in ipairs(items) do
    local text = type(entry) == "table" and entry.text or tostring(entry)
    local value = type(entry) == "table" and entry.value or entry
    menu_items[#menu_items + 1] = Menu.item(text, { value = value })
    width = math.max(width, vim.api.nvim_strwidth(text))
  end
  width = math.max(width + 4, vim.api.nvim_strwidth(vim.trim(label)) + 4, 20)
  local handled = false
  local menu = Menu({
    position = "50%",
    size = { width = width, height = math.max(1, math.min(#menu_items, 12)) },
    border = {
      style = "rounded",
      highlight = "LazyIssuesBorder",
      text = {
        top = " " .. vim.trim(label) .. " ",
        top_align = "center",
        bottom = " ↵ select · Esc cancel ",
        bottom_align = "center",
      },
    },
    zindex = 60,
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder,CursorLine:PmenuSel" },
  }, {
    lines = menu_items,
    keymap = {
      focus_next = { "j", "<Down>" },
      focus_prev = { "k", "<Up>" },
      close = { "q", "<Esc>" },
      submit = { "<CR>", "l" },
    },
    on_submit = function(item)
      handled = true
      if on_choice then
        on_choice(item.value)
      end
    end,
    on_close = function()
      if not handled and on_choice then
        on_choice(nil)
      end
    end,
  })
  menu:mount()
end

-- Vertical scrollbar overlay for a panel. Drawn as a 1-column float pinned over
-- the panel's right border, with a proportional thumb; shown only when the
-- buffer overflows the window. Reuses one float/buffer per panel (p._sb).
local sb_ns = vim.api.nvim_create_namespace("lazyissues_scrollbar")

local function close_scrollbar(p)
  if p and p._sb then
    if p._sb.win and vim.api.nvim_win_is_valid(p._sb.win) then
      pcall(vim.api.nvim_win_close, p._sb.win, true)
    end
    p._sb = nil
  end
end

local function update_scrollbar(p)
  if not (p and p.winid and vim.api.nvim_win_is_valid(p.winid)) then
    return close_scrollbar(p)
  end
  local total = vim.api.nvim_buf_line_count(p.bufnr)
  local height = vim.api.nvim_win_get_height(p.winid)
  if total <= height or height < 2 then
    return close_scrollbar(p) -- nothing to scroll
  end
  local topline = (vim.fn.getwininfo(p.winid)[1] or {}).topline or 1
  local thumb = math.max(1, math.floor(height * height / total + 0.5))
  local maxpos = height - thumb
  local pos = math.max(0, math.min(maxpos, math.floor((topline - 1) / (total - height) * maxpos + 0.5)))

  if not (p._sb and vim.api.nvim_buf_is_valid(p._sb.buf)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    p._sb = { buf = buf }
  end
  local lines = {}
  for i = 0, height - 1 do
    lines[i + 1] = (i >= pos and i < pos + thumb) and "█" or "│"
  end
  vim.api.nvim_buf_set_lines(p._sb.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(p._sb.buf, sb_ns, 0, -1)
  for i = 0, height - 1 do
    local g = (i >= pos and i < pos + thumb) and "LazyIssuesScrollThumb" or "LazyIssuesScrollTrack"
    vim.api.nvim_buf_add_highlight(p._sb.buf, sb_ns, g, i, 0, -1)
  end

  local wpos = vim.api.nvim_win_get_position(p.winid)
  local cfg = {
    relative = "editor",
    row = wpos[1],
    col = wpos[2] + vim.api.nvim_win_get_width(p.winid), -- over the right border
    width = 1,
    height = height,
    focusable = false,
    style = "minimal",
    zindex = 55,
    noautocmd = true,
  }
  if p._sb.win and vim.api.nvim_win_is_valid(p._sb.win) then
    vim.api.nvim_win_set_config(p._sb.win, cfg)
  else
    p._sb.win = vim.api.nvim_open_win(p._sb.buf, false, cfg)
  end
end

local function update_scrollbars(V)
  for _, key in ipairs({ "scopes", "sprints", "releases", "issues", "detail" }) do
    update_scrollbar(V[key])
  end
end

-- Word-wrap text (honoring embedded newlines) to `width` columns.
local function wrap(text, width)
  width = math.max(10, width or 40)
  local out = {}
  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for word in para:gmatch("%S+") do
        if line == "" then
          line = word
        elseif #line + 1 + #word <= width then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = word
        end
      end
      if line ~= "" then
        out[#out + 1] = line
      end
    end
  end
  return out
end

local function sprint_name(model, sprint_id)
  if not sprint_id or sprint_id == config.empty_guid or sprint_id == "" then
    return "Backlog"
  end
  for _, sp in ipairs(model.sprints) do
    if sp.Id == sprint_id then
      return sp.Name
    end
  end
  return "?"
end

-- All issue nodes, flattened depth-first.
local function flatten(model)
  local out = {}
  local function rec(n)
    out[#out + 1] = n
    for _, c in ipairs(n.children) do
      rec(c)
    end
  end
  for _, n in ipairs(model.issues) do
    rec(n)
  end
  return out
end

local function is_open_status(s)
  return s == "Open" or s == "InProgress"
end

-- Percent-complete (backend logic): leaf Closed = 1, else 0; a branch is the
-- average of its children's percentages.
local function issue_percent(node)
  if #node.children == 0 then
    return (node.issue and node.issue.Status == "Closed") and 1.0 or 0.0
  end
  local sum, cnt = 0, 0
  for _, c in ipairs(node.children) do
    if c.issue then
      sum = sum + issue_percent(c)
      cnt = cnt + 1
    end
  end
  return cnt == 0 and 0.0 or (sum / cnt)
end

-- ── scope → visible rows ────────────────────────────────────────────────────

-- A row = { node, depth, has_children, expanded }.
local function tree_rows(model, expanded)
  local rows = {}
  local function rec(n)
    local has = #n.children > 0
    rows[#rows + 1] = { node = n, depth = n.depth, has_children = has, expanded = expanded[n.id] }
    if has and expanded[n.id] then
      for _, c in ipairs(n.children) do
        rec(c)
      end
    end
  end
  for _, n in ipairs(model.issues) do
    rec(n)
  end
  return rows
end

local function flat_rows(nodes)
  local rows = {}
  for _, n in ipairs(nodes) do
    rows[#rows + 1] = { node = n, depth = 0, has_children = #n.children > 0, expanded = false }
  end
  return rows
end

-- Issues belonging to a release (via its sprints).
local function release_sprint_ids(model, release_id)
  local set = {}
  for _, sp in ipairs(model.sprints) do
    if sp.ReleaseId == release_id then
      set[sp.Id] = true
    end
  end
  return set
end

-- Free-text match across the most useful fields, not just the title.
local function issue_matches(it, q)
  local hay = { it.Title or "", tostring(it.Id or "") }
  for _, k in ipairs({ "Assignee", "Reporter", "Description", "ReleaseNote" }) do
    if type(it[k]) == "string" then
      hay[#hay + 1] = it[k]
    end
  end
  if type(it.Tags) == "table" then
    hay[#hay + 1] = table.concat(it.Tags, " ")
  end
  return table.concat(hay, "\n"):lower():find(q:lower(), 1, true) ~= nil
end

local function compute_rows(V)
  local model, scope, search = V.model, V.scope, V.search
  -- Tree view for "all" with no search and no field filter; flat list otherwise.
  if scope.kind == "all" and (not search or search == "") and not V.field_filter then
    return tree_rows(model, V.expanded)
  end

  local all = flatten(model)
  local matched = {}
  for _, n in ipairs(all) do
    local it = n.issue
    if it then
      local ok = true
      if scope.kind == "open" then
        ok = is_open_status(it.Status)
      elseif scope.kind == "backlog" then
        ok = (not it.SprintId) or it.SprintId == config.empty_guid
      elseif scope.kind == "sprint" then
        ok = it.SprintId == scope.id
        if ok and scope.status == "open" then
          ok = it.Status ~= "Closed"
        elseif ok and scope.status == "closed" then
          ok = it.Status == "Closed"
        end
      elseif scope.kind == "release" then
        ok = V._rel_sprints[it.SprintId] == true
      end
      if ok and search and search ~= "" then
        ok = issue_matches(it, search)
      end
      if ok and V.field_filter then
        local ff = V.field_filter
        if ff.field == "Tags" then
          ok = type(it.Tags) == "table" and vim.tbl_contains(it.Tags, ff.value)
        else
          ok = tostring(it[ff.field] or "") == ff.value
        end
      end
      if ok then
        matched[#matched + 1] = n
      end
    end
  end
  return flat_rows(matched)
end

-- ── counts ──────────────────────────────────────────────────────────────────

local function counts(model)
  local all = flatten(model)
  local total, open, backlog = 0, 0, 0
  local by_sprint = {}
  for _, n in ipairs(all) do
    local it = n.issue
    if it then
      total = total + 1
      if is_open_status(it.Status) then
        open = open + 1
      end
      if not it.SprintId or it.SprintId == config.empty_guid then
        backlog = backlog + 1
      else
        local b = by_sprint[it.SprintId]
        if not b then
          b = { all = 0, open = 0, closed = 0 }
          by_sprint[it.SprintId] = b
        end
        b.all = b.all + 1
        if it.Status == "Closed" then
          b.closed = b.closed + 1
        else
          b.open = b.open + 1
        end
      end
    end
  end
  return { total = total, open = open, backlog = backlog, by_sprint = by_sprint }
end

-- Tag each node with branch-edit state (self + any edited descendant).
local function tag_changes(V)
  local set = V.changed or {}
  local function walk(n)
    n._changed = set[n.path] == true
    local desc = false
    for _, c in ipairs(n.children) do
      walk(c)
      if c._changed or c._changed_desc then
        desc = true
      end
    end
    n._changed_desc = desc
  end
  for _, n in ipairs(V.model.issues) do
    walk(n)
  end
end

local function recompute_changes(V)
  V.changed = gitmod.changed_dirs(V.root)
  tag_changes(V)
end

-- ── rendering ───────────────────────────────────────────────────────────────

local function render_scopes(V)
  local c = V.counts
  local active = V.scope.kind
  local entries = {
    { key = "all", label = "All", n = c.total },
    { key = "open", label = "Open", n = c.open },
    { key = "backlog", label = "Backlog", n = c.backlog },
  }
  local lines = {}
  for _, e in ipairs(entries) do
    local mark = (active == e.key) and "› " or "  "
    lines[#lines + 1] = string.format("%s%s (%d)", mark, e.label, e.n)
  end
  set_lines(V.scopes.bufnr, lines)
  vim.api.nvim_buf_clear_namespace(V.scopes.bufnr, ns, 0, -1)
  for i, e in ipairs(entries) do
    if active == e.key then
      hl(V.scopes.bufnr, "LazyIssuesActive", i - 1)
    end
  end
  V.scopes._entries = entries
end

local function render_sprints(V)
  local lines, meta, actives = {}, {}, {}
  local sel = V.scope.kind == "sprint" and V.scope or nil
  for _, sp in ipairs(V.model.sprints) do
    local c = V.counts.by_sprint[sp.Id] or { all = 0, open = 0, closed = 0 }
    local expanded = V.sprint_expanded[sp.Id]
    local marker = expanded and "▼ " or "▶ "
    -- A sprint header is "active" when its scope is selected but not collapsed
    -- into a specific category row.
    local header_active = sel and sel.id == sp.Id and (not expanded)
    lines[#lines + 1] = string.format("%s%s (%d)", marker, sp.Name, c.all)
    meta[#meta + 1] = { kind = "sprint", id = sp.Id }
    actives[#lines] = header_active or nil
    if expanded then
      local cats = {
        { status = "all", label = "All", n = c.all },
        { status = "open", label = "Open", n = c.open },
        { status = "closed", label = "Closed", n = c.closed },
      }
      for _, cat in ipairs(cats) do
        local active = sel and sel.id == sp.Id and (sel.status or "all") == cat.status
        local mark = active and "› " or "  "
        lines[#lines + 1] = string.format("    %s%s (%d)", mark, cat.label, cat.n)
        meta[#meta + 1] = { kind = "cat", id = sp.Id, status = cat.status }
        actives[#lines] = active or nil
      end
    end
  end
  if #lines == 0 then
    lines = { "  (no sprints)" }
  end
  set_lines(V.sprints.bufnr, lines)
  vim.api.nvim_buf_clear_namespace(V.sprints.bufnr, ns, 0, -1)
  for line_no in pairs(actives) do
    hl(V.sprints.bufnr, "LazyIssuesActive", line_no - 1)
  end
  V.sprints._meta = meta
end

local function render_releases(V)
  local lines, meta = {}, {}
  for _, rel in ipairs(V.model.releases) do
    local active = V.scope.kind == "release" and V.scope.id == rel.Id
    local mark = active and "› " or "  "
    lines[#lines + 1] = string.format("%s%s", mark, rel.Name)
    meta[#meta + 1] = { id = rel.Id, active = active }
  end
  if #lines == 0 then
    lines = { "  (no releases)" }
  end
  set_lines(V.releases.bufnr, lines)
  V.releases._meta = meta
end

local function render_issues(V)
  V.rows = compute_rows(V)

  -- Pre-compute "is last sibling" for each row so we can draw tree connectors.
  local is_last = {}
  for i = 1, #V.rows do
    is_last[i] = true -- assume last until a later sibling at the same depth proves otherwise
    for j = i + 1, #V.rows do
      if V.rows[j].depth < V.rows[i].depth then break end
      if V.rows[j].depth == V.rows[i].depth then
        is_last[i] = false
        break
      end
    end
  end

  -- Track which ancestor levels have a continuing branch (for │ lines).
  -- continues[depth] = true means there's a non-last ancestor at that depth.
  local continues = {}

  local lines, meta = {}, {}
  for i, r in ipairs(V.rows) do
    local n = r.node
    local it = n.issue or {}
    -- Left gutter: branch-edit marker (bright = this issue, dim = a descendant).
    local gut = n._changed and "▌" or (n._changed_desc and "▏" or " ")
    local gut_hl = n._changed and "LazyIssuesChanged"
      or (n._changed_desc and "LazyIssuesChangedDim" or nil)

    -- Build tree connector prefix.
    local tree = ""
    if r.depth > 0 then
      -- Ancestor continuation lines.
      for d = 1, r.depth - 1 do
        tree = tree .. (continues[d] and "│   " or "    ")
      end
      -- This node's connector.
      tree = tree .. (is_last[i] and "└── " or "├── ")
    end
    -- Update continuation tracking for children.
    continues[r.depth] = not is_last[i]
    -- Clear deeper levels.
    for d = r.depth + 1, 10 do continues[d] = nil end

    local marker = r.has_children and (r.expanded and "▼ " or "▶ ") or ""
    local glyph = icons.glyph(it.Status)
    local prefix = gut .. " " .. tree .. marker
    lines[#lines + 1] = prefix .. glyph .. " " .. (it.Title or "(untitled)")
    meta[#meta + 1] = { gut_hl = gut_hl, prefix_len = #prefix }
  end
  if #lines == 0 then
    lines = { "  (no issues in scope)" }
  end
  set_lines(V.issues.bufnr, lines)
  vim.api.nvim_buf_clear_namespace(V.issues.bufnr, ns, 0, -1)
  for i, r in ipairs(V.rows) do
    local status = (r.node.issue or {}).Status
    local m = meta[i]
    if m.gut_hl then
      hl(V.issues.bufnr, m.gut_hl, i - 1, 0, 3) -- gutter char is 3 bytes
    end
    -- Apply status highlight from the glyph onwards so strikethrough
    -- doesn't extend across the leading gutter/indent area.
    hl(V.issues.bufnr, icons.status_hl[status] or "Normal", i - 1, m.prefix_len, -1)
  end
end

local function render_detail(V, node)
  local bufnr = V.detail.bufnr
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not node or not node.issue then
    set_lines(bufnr, { "", "  Select an issue" })
    return
  end
  local it = node.issue
  local function val(v)
    if v == nil or v == vim.NIL or v == "" then
      return "—"
    end
    return tostring(v)
  end
  local width = (V.detail.winid and vim.api.nvim_win_is_valid(V.detail.winid))
      and (vim.api.nvim_win_get_width(V.detail.winid) - 4)
    or 36

  -- Build lines and highlights together so wrapped (multiline) fields don't
  -- desync hardcoded highlight rows.
  local lines, hls = {}, {}
  local function add(text, group, c0, c1)
    lines[#lines + 1] = text
    if group then
      hls[#hls + 1] = { group, #lines - 1, c0 or 0, c1 or -1 }
    end
    return #lines - 1
  end

  add("")
  add(string.format("  %s   %s", val(it.Id), val(it.Type)), "LazyIssuesHeader")
  add("  " .. string.rep("─", width))
  local title_li = add(string.format("  %-10s %s", "Title", val(it.Title)))
  hls[#hls + 1] = { "LazyIssuesLabel", title_li, 2, 12 }
  if node._changed then
    add("  ✎ edited on this branch", "LazyIssuesChanged")
  end
  add("  " .. string.rep("─", width))

  -- Progress bar for issues with sub-issues (% of descendants complete).
  if #node.children > 0 then
    local p = issue_percent(node)
    local barw = 14
    local filled = math.floor(p * barw + 0.5)
    add(
      "  " .. string.rep("█", filled) .. string.rep("░", barw - filled) .. string.format("  %d%%", math.floor(p * 100 + 0.5)),
      "LazyIssuesInProgress"
    )
    add("")
  end

  local function field(label, value, valgroup)
    local li = add(string.format("  %-10s %s", label, value))
    hls[#hls + 1] = { "LazyIssuesLabel", li, 2, 12 }
    if valgroup then
      hls[#hls + 1] = { valgroup, li, 13, -1 }
    end
  end

  -- Render detail fields from the template if present, else hardcoded.
  local tmpl = V.model.template
  -- Fields that have special rendering and are not shown inline.
  local special = { Title = true, Description = true, Comments = true }
  if tmpl then
    for _, f in ipairs(tmpl.fields) do
      if not special[f.name] then
        local v = it[f.name]
        local display
        if f.name == "SprintId" then
          display = sprint_name(V.model, v)
        elseif f.type == "list" and type(v) == "table" and #v > 0 then
          display = table.concat(v, ", ")
        else
          display = val(v)
        end
        local valgroup = nil
        if f.name == "Status" then
          valgroup = icons.status_hl[v]
        elseif f.name == "Priority" then
          valgroup = icons.priority_hl[v]
        end
        field(f.name, display, valgroup)
      end
    end
  else
    field("Status", val(it.Status), icons.status_hl[it.Status])
    field("Priority", val(it.Priority), icons.priority_hl[it.Priority])
    field("Assignee", val(it.Assignee))
    field("Reporter", val(it.Reporter))
    field("Sprint", sprint_name(V.model, it.SprintId))
    field("Tags", (it.Tags and #it.Tags > 0) and table.concat(it.Tags, ", ") or "—")
    field("Rel. note", val(it.ReleaseNoteType))
  end
  field("Created", val(tostring(it.CreatedAt)):sub(1, 19))

  -- Description (if in template or no template).
  local has_desc = not tmpl
  local has_comments = not tmpl
  if tmpl then
    for _, f in ipairs(tmpl.fields) do
      if f.name == "Description" then
        has_desc = true
      elseif f.name == "Comments" then
        has_comments = true
      end
    end
  end

  if has_desc then
    add("  " .. string.rep("─", width))
    add("  Description", "LazyIssuesLabel")
    for _, dl in ipairs(wrap(it.Description or "", width - 2)) do
      add("    " .. dl)
    end
  end
  -- Comments list (table-style section), if the schema has comments.
  if has_comments then
    local comments = (it.Comments and it.Comments ~= vim.NIL) and it.Comments or {}
    add("  " .. string.rep("─", width))
    add(string.format("  Comments (%d)", #comments), "LazyIssuesLabel")
    if #comments == 0 then
      add("    —")
    else
      for _, c in ipairs(comments) do
        local author = (c.Author and c.Author ~= vim.NIL and c.Author ~= "") and tostring(c.Author) or "—"
        local date = tostring(c.CreatedAt or ""):sub(1, 10)
        local li = add(string.format("  %s · %s", author, date))
        hls[#hls + 1] = { "LazyIssuesLabel", li, 2, 2 + #author }
        for _, bl in ipairs(wrap(tostring(c.Body or ""), width - 4)) do
          add("      " .. bl)
        end
      end
    end
  end

  -- Children list (table-style section), with the tree's status glyph/colour.
  add("  " .. string.rep("─", width))
  add(string.format("  Children (%d)", #node.children), "LazyIssuesLabel")
  if #node.children == 0 then
    add("    —")
  else
    for _, child in ipairs(node.children) do
      local ci = child.issue or {}
      local glyph = icons.glyph(ci.Status)
      local suffix = ""
      if #child.children > 0 then
        suffix = string.format("  %d%%", math.floor(issue_percent(child) * 100 + 0.5))
      end
      local title = tostring(ci.Title or "(untitled)")
      local avail = width - 4 - #suffix
      if avail > 1 and #title > avail then
        title = title:sub(1, avail - 1) .. "…"
      end
      local li = add(string.format("  %s %s%s", glyph, title, suffix))
      local ghl = icons.status_hl[ci.Status]
      if ghl then
        hls[#hls + 1] = { ghl, li, 2, 2 + #glyph }
      end
    end
  end

  set_lines(bufnr, lines)
  for _, h in ipairs(hls) do
    hl(bufnr, h[1], h[2], h[3], h[4])
  end
  update_scrollbar(V.detail)
end

local function selected_node(V)
  if not (V.issues.winid and vim.api.nvim_win_is_valid(V.issues.winid)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(V.issues.winid)[1]
  local r = V.rows[row]
  return r and r.node or nil
end

local function refresh(V, keep_cursor)
  V.counts = counts(V.model)
  if V.scope.kind == "release" then
    V._rel_sprints = release_sprint_ids(V.model, V.scope.id)
  end
  render_scopes(V)
  render_sprints(V)
  render_releases(V)
  render_issues(V)
  if not keep_cursor and V.issues.winid and vim.api.nvim_win_is_valid(V.issues.winid) then
    pcall(vim.api.nvim_win_set_cursor, V.issues.winid, { 1, 0 })
  end
  render_detail(V, selected_node(V))
  update_scrollbars(V)
end

-- ── interaction ─────────────────────────────────────────────────────────────

local function focus(V, which)
  local p = V[which]
  if p and p.winid and vim.api.nvim_win_is_valid(p.winid) then
    vim.api.nvim_set_current_win(p.winid)
  end
end

local function cycle_focus(V, dir)
  local order = { "scopes", "sprints", "releases", "issues", "detail" }
  local cur = vim.api.nvim_get_current_win()
  local idx = 1
  for i, name in ipairs(order) do
    if V[name].winid == cur then
      idx = i
      break
    end
  end
  idx = ((idx - 1 + dir) % #order) + 1
  focus(V, order[idx])
end

local function close(V)
  for _, key in ipairs({ "scopes", "sprints", "releases", "issues", "detail" }) do
    close_scrollbar(V[key])
  end
  if V.layout then
    pcall(function()
      V.layout:unmount()
    end)
  end
  if V.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, V.augroup)
  end
  M._view = nil
end

local function on_enter_scopes(V)
  local row = vim.api.nvim_win_get_cursor(V.scopes.winid)[1]
  local e = V.scopes._entries and V.scopes._entries[row]
  if e then
    V.scope = { kind = e.key }
    V.search = ""
    refresh(V)
  end
end

local function sprint_meta_at_cursor(V)
  local row = vim.api.nvim_win_get_cursor(V.sprints.winid)[1]
  return V.sprints._meta and V.sprints._meta[row]
end

local function toggle_sprint(V)
  local m = sprint_meta_at_cursor(V)
  if m then
    V.sprint_expanded[m.id] = not V.sprint_expanded[m.id]
    local cur = vim.api.nvim_win_get_cursor(V.sprints.winid)
    render_sprints(V)
    pcall(vim.api.nvim_win_set_cursor, V.sprints.winid, cur)
  end
end

local function on_enter_sprints(V)
  local m = sprint_meta_at_cursor(V)
  if not m then
    return
  end
  if m.kind == "sprint" then
    V.sprint_expanded[m.id] = true -- expand to reveal All / Open / Closed
    V.scope = { kind = "sprint", id = m.id, status = "all" }
  else
    V.scope = { kind = "sprint", id = m.id, status = m.status }
  end
  V.search = ""
  refresh(V)
end

local function on_enter_releases(V)
  local row = vim.api.nvim_win_get_cursor(V.releases.winid)[1]
  local m = V.releases._meta and V.releases._meta[row]
  if m then
    V.scope = { kind = "release", id = m.id }
    V.search = ""
    refresh(V)
  end
end

local function toggle_expand(V)
  local node = selected_node(V)
  if node and #node.children > 0 then
    V.expanded[node.id] = not V.expanded[node.id]
    local cur = vim.api.nvim_win_get_cursor(V.issues.winid)
    render_issues(V)
    pcall(vim.api.nvim_win_set_cursor, V.issues.winid, cur)
    render_detail(V, selected_node(V))
  end
end

-- Live filter bar pinned across the bottom of the issues panel. Typing filters
-- the list in real time (compute_rows already matches on V.search); <CR> keeps
-- the filter and returns to the list, <Esc> restores the previous filter.
local function do_search(V)
  local win = V.issues.winid
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local pos = vim.api.nvim_win_get_position(win)
  local w = vim.api.nvim_win_get_width(win)
  local h = vim.api.nvim_win_get_height(win)
  local prev_search = V.search or ""

  local bar = Popup({
    enter = true,
    relative = "editor",
    -- Dock flush across the bottom of the issues panel: content on the last
    -- content row (Nui draws the border at ±1), full panel width so the bar's
    -- side borders line up over the panel's own borders.
    position = { row = pos[1] + math.max(0, h - 1), col = pos[2] },
    size = { width = w, height = 1 },
    border = {
      style = "rounded",
      text = { top = " / live filter ", top_align = "left" },
      highlight = "LazyIssuesBorder",
    },
    zindex = 60,
    buf_options = { modifiable = true, filetype = "" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder" },
  })
  bar:mount()
  if prev_search ~= "" then
    vim.api.nvim_buf_set_lines(bar.bufnr, 0, -1, false, { prev_search })
  end

  local closed = false
  local function dismiss(restore)
    if closed then
      return
    end
    closed = true
    if restore then
      V.search = prev_search
      refresh(V)
    end
    vim.cmd("stopinsert")
    pcall(function()
      bar:unmount()
    end)
    focus(V, "issues")
  end

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = bar.bufnr,
    callback = function()
      V.search = vim.api.nvim_buf_get_lines(bar.bufnr, 0, 1, false)[1] or ""
      refresh(V)
    end,
  })

  local function map(lhs, fn)
    vim.keymap.set({ "n", "i" }, lhs, fn, { buffer = bar.bufnr, nowait = true, silent = true })
  end
  map("<CR>", function()
    dismiss(false)
  end)
  map("<Esc>", function()
    dismiss(true)
  end)

  pcall(vim.api.nvim_win_set_cursor, bar.winid, { 1, #prev_search })
  vim.cmd("startinsert!")
end

-- Filter the issue list by a field value (Status/Priority/Assignee/Tag). The
-- filter composes with the scope and the live search; pick "Clear filter" to drop it.
local function field_filter_action(V)
  local fields = { "Status", "Priority", "Assignee", "Tag" }
  if V.field_filter then
    fields[#fields + 1] = "Clear filter"
  end
  prompt_select("Filter by:", fields, function(field)
    if not field then
      return
    end
    if field == "Clear filter" then
      V.field_filter = nil
      refresh(V)
      return
    end
    local values
    if field == "Status" then
      values = config.issue_status
    elseif field == "Priority" then
      values = config.issue_priority
    elseif field == "Assignee" then
      values = config.assignees
    else -- Tag: distinct tags across all issues
      local seen = {}
      values = {}
      for _, n in ipairs(flatten(V.model)) do
        local it = n.issue
        if it and type(it.Tags) == "table" then
          for _, tg in ipairs(it.Tags) do
            if not seen[tg] then
              seen[tg] = true
              values[#values + 1] = tg
            end
          end
        end
      end
    end
    if not values or #values == 0 then
      vim.notify("lazyissues: no values to filter by", vim.log.levels.INFO)
      return
    end
    prompt_select(field .. " =", values, function(val)
      if not val then
        return
      end
      V.field_filter = { field = field == "Tag" and "Tags" or field, value = val }
      refresh(V)
      focus(V, "issues")
    end)
  end)
end

-- Move the cursor to the next/prev issue edited on this branch (wraps around).
local function jump_changed(V, dir)
  if not (V.issues.winid and vim.api.nvim_win_is_valid(V.issues.winid)) then
    return
  end
  local rows, n = V.rows, #V.rows
  if n == 0 then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(V.issues.winid)[1]
  for step = 1, n do
    local i = ((cur - 1 + dir * step) % n) + 1
    local r = rows[i]
    if r and r.node and r.node._changed then
      pcall(vim.api.nvim_win_set_cursor, V.issues.winid, { i, 0 })
      render_detail(V, selected_node(V))
      update_scrollbar(V.issues)
      return
    end
  end
  vim.notify("lazyissues: no branch-edited issues", vim.log.levels.INFO)
end

-- Expand or collapse every issue that has sub-issues.
local function set_all_expanded(V, expand)
  if not expand then
    V.expanded = {}
  else
    for _, n in ipairs(flatten(V.model)) do
      if #n.children > 0 then
        V.expanded[n.id] = true
      end
    end
  end
  refresh(V, true)
end

local function reload(V)
  V.model = store.load(V.root)
  V.expanded = V.expanded or {}
  recompute_changes(V)
  refresh(V)
end

-- ── mutations ───────────────────────────────────────────────────────────────

-- Reload from disk, then put the cursor back on issue `id` if it's visible.
local function reload_select(V, id)
  V.model = store.load(V.root)
  recompute_changes(V)
  refresh(V)
  if id then
    for i, r in ipairs(V.rows) do
      if r.node.id == id then
        pcall(vim.api.nvim_win_set_cursor, V.issues.winid, { i, 0 })
        render_detail(V, selected_node(V))
        return
      end
    end
  end
end

-- Status is always editable (to reopen); everything else is locked when Closed.
local function editable(node, key)
  if key == "Status" then
    return true
  end
  return (node.issue or {}).Status ~= "Closed"
end

-- Apply a single field change to the selected issue and persist it.
local function apply_field(V, node, key, value)
  if not node or not node.issue then
    return
  end
  if not editable(node, key) then
    vim.notify("lazyissues: issue is Closed — reopen it (s) before editing", vim.log.levels.WARN)
    return
  end
  local it = vim.tbl_extend("force", {}, node.issue)
  it[key] = value
  local ok, err = actions.save_issue(node.path, it, V.model.template)
  if not ok then
    vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  node.issue = it
  refresh(V, true)
end

-- The optional `on_done` callback (used by the edit menu) fires after the edit
-- completes OR is cancelled, so the menu can reopen as a hub.
local function done(cb)
  if cb then
    cb()
  end
end

local function locked_notify()
  vim.notify("lazyissues: issue is Closed — reopen it (s) first", vim.log.levels.WARN)
end

local function picker(V, key, items, prompt, transform, on_done)
  local node = selected_node(V)
  if not node then
    return done(on_done)
  end
  if not editable(node, key) then
    locked_notify()
    return done(on_done)
  end
  prompt_select(prompt, items, function(choice)
    if choice then
      apply_field(V, node, key, transform and transform(choice) or choice)
    end
    done(on_done)
  end)
end

local function pick_sprint(V, on_done)
  local node = selected_node(V)
  if not node then
    return done(on_done)
  end
  if not editable(node, "SprintId") then
    locked_notify()
    return done(on_done)
  end
  local items, map = { "Backlog" }, { Backlog = config.empty_guid }
  for _, sp in ipairs(V.model.sprints) do
    items[#items + 1] = sp.Name
    map[sp.Name] = sp.Id
  end
  prompt_select("Sprint:", items, function(choice)
    if choice then
      apply_field(V, node, "SprintId", map[choice])
    end
    done(on_done)
  end)
end

local function edit_text(V, key, prompt, on_done)
  local node = selected_node(V)
  if not node then
    return done(on_done)
  end
  if not editable(node, key) then
    locked_notify()
    return done(on_done)
  end
  local cur = node.issue[key]
  if cur == vim.NIL then
    cur = ""
  end
  prompt_input(prompt, tostring(cur or ""), function(input)
    if input ~= nil then
      apply_field(V, node, key, input)
    end
    done(on_done) -- save or cancel both return to the edit menu hub
  end)
end

local function edit_tags(V, on_done)
  local node = selected_node(V)
  if not node then
    return done(on_done)
  end
  if not editable(node, "Tags") then
    locked_notify()
    return done(on_done)
  end
  local cur = (node.issue.Tags and table.concat(node.issue.Tags, ", ")) or ""
  prompt_input("Tags (comma-separated)", cur, function(input)
    if input ~= nil then
      local tags = {}
      for t in input:gmatch("[^,]+") do
        local trimmed = vim.trim(t)
        if trimmed ~= "" then
          tags[#tags + 1] = trimmed
        end
      end
      apply_field(V, node, "Tags", tags)
    end
    done(on_done) -- save or cancel both return to the edit menu hub
  end)
end

-- Multi-line editor: thin wrapper over prompt_input. on_accept fires only on
-- save (Ctrl-s); on_close fires on both save and cancel.
local function multiline_input(label, initial, on_accept, on_close)
  prompt_input(label, initial, function(txt)
    if txt ~= nil and on_accept then
      on_accept(txt)
    end
    if on_close then
      on_close()
    end
  end, { multiline = true })
end

local function edit_multiline(V, key, label, on_done)
  local node = selected_node(V)
  if not node then
    return done(on_done)
  end
  if not editable(node, key) then
    locked_notify()
    return done(on_done)
  end
  local cur = node.issue[key]
  if cur == vim.NIL then
    cur = ""
  end
  prompt_input(label, cur, function(txt)
    if txt ~= nil then
      apply_field(V, node, key, txt)
    end
    done(on_done) -- save or cancel both return to the edit menu hub
  end, { multiline = true })
end

-- Comments viewer/manager popup for the selected issue.
local function comments_view(V, on_close)
  local node = selected_node(V)
  if not node then
    return done(on_close)
  end
  local it = node.issue or {}

  local top = NuiLine()
  top:append(" lazyissues ", "LazyIssuesBorder")
  top:append("comments", "FloatTitle")
  top:append(" ", "LazyIssuesBorder")
  local bottom = NuiLine()
  bottom:append(" a add · d delete · q close ", "LazyIssuesBorder")

  local pop = Popup({
    enter = true,
    border = {
      style = "rounded",
      highlight = "LazyIssuesBorder",
      text = { top = top, top_align = "center", bottom = bottom, bottom_align = "center" },
    },
    position = "50%",
    size = { width = "60%", height = "60%" },
    zindex = 60,
    buf_options = { modifiable = false, filetype = "lazyissues-comments" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder", cursorline = true, wrap = true },
  })
  pop:mount()

  local linemap = {}
  local function comments()
    local c = it.Comments
    if c == nil or c == vim.NIL then
      return {}
    end
    return c
  end
  local function redraw()
    local cs = comments()
    local lines, headers = {}, {}
    linemap = {}
    if #cs == 0 then
      lines = { "", "  No comments — press a to add one." }
    else
      for i, c in ipairs(cs) do
        lines[#lines + 1] = string.format("  %s · %s", c.Author or "?", tostring(c.CreatedAt or ""):sub(1, 16))
        headers[#lines] = true
        linemap[#lines] = i
        for _, bl in ipairs(vim.split(c.Body or "", "\n", { plain = true })) do
          lines[#lines + 1] = "    " .. bl
          linemap[#lines] = i
        end
        lines[#lines + 1] = ""
      end
    end
    vim.bo[pop.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, lines)
    vim.bo[pop.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(pop.bufnr, ns, 0, -1)
    for ln in pairs(headers) do
      vim.api.nvim_buf_add_highlight(pop.bufnr, ns, "LazyIssuesHeader", ln - 1, 0, -1)
    end
  end

  local function add_comment()
    local function ask_body(author)
      prompt_input("Comment (" .. author .. ")", "", function(body)
        if body == nil or vim.trim(body) == "" then
          return
        end
        local ok, err = actions.add_comment(node.path, it, author, body)
        if not ok then
          vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        redraw()
      end, { multiline = true })
    end
    local authors = config.comment_authors
    if authors and #authors > 0 then
      prompt_select("Author:", authors, function(author)
        if author then
          ask_body(author)
        end
      end)
    else
      -- No configured authors: ask for one, defaulting to the git/user name.
      local default = gitmod.user_name(V.root) or vim.env.USER or ""
      prompt_input("Comment author", default, function(author)
        author = author and vim.trim(author) or ""
        if author ~= "" then
          ask_body(author)
        end
      end)
    end
  end
  local function del_comment()
    local row = vim.api.nvim_win_get_cursor(pop.winid)[1]
    local idx = linemap[row]
    if not idx then
      return
    end
    local ok, err = actions.delete_comment(node.path, it, idx)
    if not ok then
      vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    redraw()
  end
  local function close()
    pcall(function()
      pop:unmount()
    end)
    recompute_changes(V) -- the issue file changed; update markers + counts
    refresh(V, true)
    done(on_close)
  end

  vim.keymap.set("n", "a", add_comment, { buffer = pop.bufnr })
  for _, k in ipairs({ "d", "x" }) do
    vim.keymap.set("n", k, del_comment, { buffer = pop.bufnr })
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, close, { buffer = pop.bufnr })
  end
  redraw()
end

local function create_issue_action(V, parent_node)
  local label = parent_node and "New child issue title" or "New issue title"
  prompt_input(label, nil, function(title)
    if title == nil or vim.trim(title) == "" then
      return
    end
    local fields = { Title = title }
    if not parent_node and V.scope.kind == "sprint" then
      fields.SprintId = V.scope.id
    end
    local id, _, err = actions.create_issue(V.root, fields, parent_node and parent_node.path or nil)
    if not id then
      vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if parent_node then
      V.expanded[parent_node.id] = true
    end
    reload_select(V, id)
  end)
end

local function delete_action(V)
  local node = selected_node(V)
  if not node then
    return
  end
  local n = 0
  local function count_desc(x)
    for _, c in ipairs(x.children) do
      n = n + 1
      count_desc(c)
    end
  end
  count_desc(node)
  local title = (node.issue and node.issue.Title or node.id):sub(1, 40)
  local extra = n > 0 and (" and " .. n .. " sub-issue(s)") or ""
  prompt_select('Delete "' .. title .. '"' .. extra .. "?", { "No", "Yes" }, function(c)
    if c == "Yes" then
      local ok, err = actions.delete_issue(node.path)
      if not ok then
        vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      reload_select(V, nil)
    end
  end)
end

-- Reusable fuzzy picker: a results list with a live-filter input below it.
-- `items` is a list of { label=, title_lower=(optional), always=(optional), ... };
-- items flagged `always` stay visible regardless of the query (e.g. a "(root)"
-- row). on_choose receives the selected item, or nil if cancelled.
local function fuzzy_pick(title_word, items, on_choose)
  local top = NuiLine()
  top:append(" lazyissues ", "LazyIssuesBorder")
  top:append(title_word, "FloatTitle")
  top:append(" ", "LazyIssuesBorder")

  local list_h = math.min(#items + 2, 24)
  local pop_w = 64
  local list_row = math.floor((vim.o.lines - list_h - 3) / 2)
  local list_col = math.floor((vim.o.columns - pop_w) / 2)

  local list_pop = Popup({
    enter = false,
    relative = "editor",
    position = { row = list_row, col = list_col },
    border = { style = "rounded", text = { top = top, top_align = "center" }, highlight = "LazyIssuesBorder" },
    size = { width = pop_w, height = list_h },
    zindex = 60,
    buf_options = { modifiable = false, filetype = "lazyissues" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder", cursorline = true },
  })
  list_pop:mount()

  local input_pop = Popup({
    enter = true,
    relative = "editor",
    position = { row = list_row + list_h + 2, col = list_col },
    border = {
      style = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
      text = { top = " > ", top_align = "left" },
      highlight = "LazyIssuesBorder",
    },
    size = { width = pop_w, height = 1 },
    zindex = 60,
    buf_options = { modifiable = true, filetype = "" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder" },
  })
  input_pop:mount()

  local sel_row = 1
  local filtered = {}
  for _, it in ipairs(items) do
    filtered[#filtered + 1] = it
  end

  local function redraw_list()
    local lines = {}
    for _, item in ipairs(filtered) do
      lines[#lines + 1] = "  " .. item.label
    end
    if #lines == 0 then
      lines = { "  (no matches)" }
    end
    vim.bo[list_pop.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(list_pop.bufnr, 0, -1, false, lines)
    vim.bo[list_pop.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_pop.bufnr, ns, 0, -1)
    if #filtered > 0 then
      local r = math.min(sel_row, #filtered)
      vim.api.nvim_buf_add_highlight(list_pop.bufnr, ns, "PmenuSel", r - 1, 0, -1)
    end
    if #filtered > 0 and filtered[1].always and sel_row ~= 1 then
      vim.api.nvim_buf_add_highlight(list_pop.bufnr, ns, "LazyIssuesLabel", 0, 0, -1)
    end
    if list_pop.winid and vim.api.nvim_win_is_valid(list_pop.winid) then
      local r = math.min(sel_row, #filtered)
      local win_h = vim.api.nvim_win_get_height(list_pop.winid)
      local topline = vim.fn.getwininfo(list_pop.winid)[1].topline or 1
      if r < topline then
        vim.api.nvim_win_call(list_pop.winid, function()
          vim.cmd("normal! " .. r .. "zt")
        end)
      elseif r >= topline + win_h then
        vim.api.nvim_win_call(list_pop.winid, function()
          vim.cmd("normal! " .. r .. "zb")
        end)
      end
    end
  end

  local function filter(text)
    text = (text or ""):lower()
    filtered = {}
    for _, item in ipairs(items) do
      if text == "" or item.always or (item.title_lower and item.title_lower:find(text, 1, true)) then
        filtered[#filtered + 1] = item
      end
    end
    sel_row = 1
    redraw_list()
  end

  local function cleanup()
    pcall(function()
      input_pop:unmount()
    end)
    pcall(function()
      list_pop:unmount()
    end)
  end

  local function confirm()
    local item = filtered[math.min(sel_row, #filtered)]
    vim.cmd("stopinsert")
    cleanup()
    on_choose(item)
  end

  redraw_list()
  vim.cmd("startinsert")

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_pop.bufnr,
    callback = function()
      filter(vim.api.nvim_buf_get_lines(input_pop.bufnr, 0, 1, false)[1] or "")
    end,
  })

  local function map_input(lhs, fn)
    vim.keymap.set({ "n", "i" }, lhs, fn, { buffer = input_pop.bufnr, nowait = true, silent = true })
  end
  map_input("<CR>", confirm)
  map_input("<Esc>", function()
    vim.cmd("stopinsert")
    cleanup()
    on_choose(nil)
  end)
  local function move(dir)
    if #filtered == 0 then
      return
    end
    sel_row = math.max(1, math.min(#filtered, sel_row + dir))
    redraw_list()
  end
  map_input("<Down>", function()
    move(1)
  end)
  map_input("<Up>", function()
    move(-1)
  end)
  map_input("<C-j>", function()
    move(1)
  end)
  map_input("<C-k>", function()
    move(-1)
  end)
  map_input("<C-n>", function()
    move(1)
  end)
  map_input("<C-p>", function()
    move(-1)
  end)
end

local function change_parent_action(V)
  local node = selected_node(V)
  if not node then
    return
  end
  local prefix = node.path .. "/"

  -- Build the full candidate list: (root) + all valid targets.
  local items = { { label = "(root)", always = true, node = nil } }
  local function collect(list)
    for _, c in ipairs(list) do
      local is_self = c.id == node.id
      local is_desc = c.path:sub(1, #prefix) == prefix
      if not is_self and not is_desc then
        local indent = string.rep("  ", c.depth)
        local title = (c.issue and c.issue.Title or c.id):sub(1, 50)
        items[#items + 1] = { label = indent .. title, title_lower = title:lower(), node = c }
      end
      collect(c.children)
    end
  end
  collect(V.model.issues)

  fuzzy_pick("reparent", items, function(item)
    if not item then
      return
    end
    local target = item.node
    local ok, err = actions.change_parent(V.root, node.path, node.id, target and target.path or nil)
    if not ok then
      vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if target then
      V.expanded[target.id] = true
    end
    reload_select(V, node.id)
  end)
end

-- Fuzzy-jump to any issue across the whole tree, regardless of the current
-- scope/filter. Selecting one switches to the All scope, expands ancestors and
-- moves the cursor to it.
local function jump_to_issue(V)
  local items = {}
  local function collect(list)
    for _, c in ipairs(list) do
      if c.issue then
        local title = (c.issue.Title or "(untitled)"):sub(1, 50)
        items[#items + 1] = { label = icons.glyph(c.issue.Status) .. " " .. title, title_lower = title:lower(), node = c }
      end
      collect(c.children)
    end
  end
  collect(V.model.issues)
  if #items == 0 then
    return
  end
  fuzzy_pick("jump", items, function(item)
    if not (item and item.node) then
      return
    end
    V.scope = { kind = "all" }
    V.search = ""
    V.field_filter = nil
    for _, n in ipairs(flatten(V.model)) do
      if #n.children > 0 then
        V.expanded[n.id] = true
      end
    end
    reload_select(V, item.node.id)
    focus(V, "issues")
  end)
end

-- Discoverable edit menu: a popup listing every field (with current values) and
-- the structural actions. Picking one dispatches to the matching action.
local function edit_menu(V)
  local node = selected_node(V)
  if not node then
    return
  end
  local it = node.issue or {}
  local closed = it.Status == "Closed"
  local ncomments = (it.Comments and it.Comments ~= vim.NIL) and #it.Comments or 0
  local Menu = require("nui.menu")

  local function val(v)
    if v == nil or v == vim.NIL or v == "" then
      return "—"
    end
    return tostring(v)
  end
  local function lk(field)
    return (closed and field and field ~= "Status") and "  (locked)" or ""
  end
  local tags = (it.Tags and #it.Tags > 0) and table.concat(it.Tags, ", "):sub(1, 12) or ""
  local function item(name, value, field, action)
    return Menu.item(string.format("  %-17s %s%s", name, value or "", lk(field)), { action = action })
  end

  -- Reopen the menu after a field edit (success or cancel) so it acts as a hub.
  local reopen
  reopen = function()
    vim.schedule(function()
      edit_menu(V)
    end)
  end

  local lines = {}
  local dispatch = {}
  local tmpl = V.model.template

  -- Build field items from template if available, else hardcoded.
  if tmpl then
    for _, f in ipairs(tmpl.fields) do
      local fname = f.name
      local action = "field_" .. fname
      local display
      if fname == "SprintId" then
        display = sprint_name(V.model, it.SprintId)
      elseif fname == "Comments" then
        display = "(" .. ncomments .. ")"
      elseif f.type == "list" and type(it[fname]) == "table" and #it[fname] > 0 then
        display = table.concat(it[fname], ", "):sub(1, 12)
      elseif fname == "Description" or fname == "ReleaseNote" then
        display = nil
      else
        display = val(it[fname])
      end
      lines[#lines + 1] = item(fname, display, fname, action)

      -- Build dispatch for this field based on type.
      if fname == "Comments" then
        dispatch[action] = function()
          comments_view(V, reopen)
        end
      elseif fname == "SprintId" then
        dispatch[action] = function()
          pick_sprint(V, reopen)
        end
      elseif fname == "Assignee" then
        dispatch[action] = function()
          picker(V, "Assignee", config.assignees, "Assignee:", function(c)
            return c == "Unassigned" and "" or c
          end, reopen)
        end
      elseif f.type == "enum" and f.values then
        dispatch[action] = function()
          picker(V, fname, f.values, fname .. ":", nil, reopen)
        end
      elseif f.type == "list" then
        dispatch[action] = function()
          -- Reuse tag-style editor for any list field.
          local node2 = selected_node(V)
          if not node2 then
            return done(reopen)
          end
          if not editable(node2, fname) then
            locked_notify()
            return done(reopen)
          end
          local cur = (type(node2.issue[fname]) == "table" and table.concat(node2.issue[fname], ", ")) or ""
          prompt_input(fname .. " (comma-separated)", cur, function(input)
            if input ~= nil then
              local items2 = {}
              for t in input:gmatch("[^,]+") do
                local trimmed = vim.trim(t)
                if trimmed ~= "" then
                  items2[#items2 + 1] = trimmed
                end
              end
              apply_field(V, node2, fname, items2)
            end
            done(reopen)
          end)
        end
      elseif fname == "Description" or fname == "ReleaseNote" then
        dispatch[action] = function()
          edit_multiline(V, fname, fname, reopen)
        end
      elseif f.type == "number" then
        dispatch[action] = function()
          local node2 = selected_node(V)
          if not node2 then
            return done(reopen)
          end
          if not editable(node2, fname) then
            locked_notify()
            return done(reopen)
          end
          local cur = node2.issue[fname]
          if cur == vim.NIL then
            cur = ""
          end
          prompt_input(fname .. ":", tostring(cur or ""), function(input)
            if input ~= nil then
              apply_field(V, node2, fname, tonumber(input))
            end
            done(reopen)
          end)
        end
      else
        dispatch[action] = function()
          edit_text(V, fname, fname .. ": ", reopen)
        end
      end
    end
  else
    lines = {
      item("Status", val(it.Status), "Status", "status"),
      item("Priority", val(it.Priority), "Priority", "priority"),
      item("Type", val(it.Type), "Type", "type"),
      item("Assignee", val(it.Assignee), "Assignee", "assignee"),
      item("Sprint", sprint_name(V.model, it.SprintId), "Sprint", "sprint"),
      item("Title", nil, "Title", "title"),
      item("Description", nil, "Description", "description"),
      item("Tags", tags, "Tags", "tags"),
      item("Release note type", val(it.ReleaseNoteType), "ReleaseNoteType", "notetype"),
      item("Release note", nil, "ReleaseNote", "note"),
      item("Comments", "(" .. ncomments .. ")", nil, "comments"),
    }
    dispatch = {
      status = function()
        picker(V, "Status", config.issue_status, "Status:", nil, reopen)
      end,
      priority = function()
        picker(V, "Priority", config.issue_priority, "Priority:", nil, reopen)
      end,
      type = function()
        picker(V, "Type", config.issue_type, "Type:", nil, reopen)
      end,
      assignee = function()
        picker(V, "Assignee", config.assignees, "Assignee:", function(c)
          return c == "Unassigned" and "" or c
        end, reopen)
      end,
      sprint = function()
        pick_sprint(V, reopen)
      end,
      title = function()
        edit_text(V, "Title", "Title: ", reopen)
      end,
      description = function()
        edit_multiline(V, "Description", "Description", reopen)
      end,
      tags = function()
        edit_tags(V, reopen)
      end,
      notetype = function()
        picker(V, "ReleaseNoteType", config.release_note_type, "Release note type:", nil, reopen)
      end,
      note = function()
        edit_multiline(V, "ReleaseNote", "Release note", reopen)
      end,
      comments = function()
        comments_view(V, reopen)
      end,
    }
  end

  -- Structural actions (always present).
  lines[#lines + 1] = Menu.separator("actions")
  lines[#lines + 1] = Menu.item("  + New child issue", { action = "child" })
  lines[#lines + 1] = Menu.item("  ↳ Change parent", { action = "reparent" })
  lines[#lines + 1] = Menu.item("  ✗ Delete issue", { action = "delete" })
  dispatch.child = function()
    create_issue_action(V, node)
  end
  dispatch.reparent = function()
    change_parent_action(V)
  end
  dispatch.delete = function()
    delete_action(V)
  end

  local menu = Menu({
    position = "50%",
    size = { width = 48, height = #lines },
    border = {
      style = "rounded",
      text = { top = " Edit issue ", top_align = "center", bottom = " ↵ select · q close ", bottom_align = "center" },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder,CursorLine:PmenuSel" },
  }, {
    lines = lines,
    keymap = {
      focus_next = { "j", "<Down>" },
      focus_prev = { "k", "<Up>" },
      close = { "q", "<Esc>" },
      submit = { "<CR>", "l" },
    },
    on_submit = function(item)
      local fn = dispatch[item.action]
      if fn then
        vim.schedule(fn)
      end
    end,
  })
  menu:mount()
end

-- ── sprint mutations ─────────────────────────────────────────────────────────

local function selected_sprint(V)
  local m = sprint_meta_at_cursor(V)
  if not m then
    return nil
  end
  for _, sp in ipairs(V.model.sprints) do
    if sp.Id == m.id then
      return sp
    end
  end
end

local function create_sprint_action(V)
  prompt_input("New sprint name", "", function(name)
    if name == nil or vim.trim(name) == "" then
      return
    end
    local id, _, err = actions.create_sprint(V.root, { Name = name })
    if not id then
      vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    reload(V)
  end)
end

local function sprint_edit_menu(V)
  local sp = selected_sprint(V)
  if not sp then
    return
  end
  local Menu = require("nui.menu")
  local reopen
  reopen = function()
    vim.schedule(function()
      sprint_edit_menu(V)
    end)
  end
  local function save()
    actions.save_sprint(sp._path, sp)
    refresh(V, true)
  end

  local lines = {
    Menu.item("  Name         " .. (sp.Name or ""), { action = "name" }),
    Menu.item("  Description   " .. ((sp.Description or ""):sub(1, 22)), { action = "desc" }),
    Menu.item("  Status        " .. (sp.Status or ""), { action = "status" }),
    Menu.separator("actions"),
    Menu.item("  ✗ Delete sprint", { action = "delete" }),
  }
  local dispatch = {
    name = function()
      prompt_input("Sprint name:", sp.Name or "", function(v)
        if v ~= nil and vim.trim(v) ~= "" then
          sp.Name = v
          save()
        end
        reopen()
      end)
    end,
    desc = function()
      local cur = sp.Description
      if cur == vim.NIL then
        cur = ""
      end
      multiline_input("Sprint description", cur or "", function(txt)
        sp.Description = txt
        save()
      end, reopen)
    end,
    status = function()
      prompt_select("Sprint status:", config.sprint_status, function(v)
        if v then
          sp.Status = v
          save()
        end
        reopen()
      end)
    end,
    delete = function()
      prompt_select('Delete sprint "' .. (sp.Name or "") .. '"?', { "No", "Yes" }, function(c)
        if c == "Yes" then
          local ok, err = actions.delete_sprint(sp._path)
          if not ok then
            vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          reload(V)
        else
          reopen()
        end
      end)
    end,
  }

  local menu = Menu({
    position = "50%",
    size = { width = 46, height = #lines },
    border = {
      style = "rounded",
      text = { top = " Edit sprint ", top_align = "center", bottom = " ↵ select · q close ", bottom_align = "center" },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder,CursorLine:PmenuSel" },
  }, {
    lines = lines,
    keymap = {
      focus_next = { "j", "<Down>" },
      focus_prev = { "k", "<Up>" },
      close = { "q", "<Esc>" },
      submit = { "<CR>", "l" },
    },
    on_submit = function(item)
      local fn = dispatch[item.action]
      if fn then
        vim.schedule(fn)
      end
    end,
  })
  menu:mount()
end

-- ── release mutations ────────────────────────────────────────────────────────

local function release_meta_at_cursor(V)
  local row = vim.api.nvim_win_get_cursor(V.releases.winid)[1]
  return V.releases._meta and V.releases._meta[row]
end

local function selected_release(V)
  local m = release_meta_at_cursor(V)
  if not m then
    return nil
  end
  for _, rel in ipairs(V.model.releases) do
    if rel.Id == m.id then
      return rel
    end
  end
end

local function create_release_action(V)
  prompt_input("New release name", "", function(name)
    if name == nil or vim.trim(name) == "" then
      return
    end
    local id, _, err = actions.create_release(V.root, { Name = name })
    if not id then
      vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    reload(V)
  end)
end

-- Release notes preview: issues in the release's sprints that have a non-None,
-- non-blank release note, grouped by type (Features / Improvements / Fixes / Tasks).
local function release_notes_preview(V, rel, on_close)
  local sprint_ids = {}
  for _, sp in ipairs(V.model.sprints) do
    if sp.ReleaseId == rel.Id then
      sprint_ids[sp.Id] = true
    end
  end
  local groups = { Feature = {}, Improvement = {}, Bug = {}, Task = {} }
  local function walk(n)
    local it = n.issue
    if it and sprint_ids[it.SprintId] then
      local rnt = it.ReleaseNoteType
      local note = it.ReleaseNote
      if note == vim.NIL then
        note = nil
      end
      if rnt and rnt ~= vim.NIL and rnt ~= "None" and note and vim.trim(note) ~= "" then
        local g = groups[it.Type] or groups.Task
        g[#g + 1] = { title = it.Title or "", note = note, open = it.Status ~= "Closed" }
      end
    end
    for _, c in ipairs(n.children) do
      walk(c)
    end
  end
  for _, n in ipairs(V.model.issues) do
    walk(n)
  end

  local lines, hls = {}, {}
  local function add(t, h)
    lines[#lines + 1] = t
    if h then
      hls[#hls + 1] = { #lines - 1, h }
    end
  end
  add("  Release notes — " .. (rel.Name or ""), "LazyIssuesHeader")
  add("")
  local order = {
    { "Feature", "Features" },
    { "Improvement", "Improvements" },
    { "Bug", "Fixes" },
    { "Task", "Tasks" },
  }
  local any = false
  for _, grp in ipairs(order) do
    local items = groups[grp[1]]
    if #items > 0 then
      any = true
      add("  " .. grp[2], "LazyIssuesHeader")
      for _, x in ipairs(items) do
        add("    • " .. x.title .. (x.open and "  (open)" or ""), x.open and "LazyIssuesInProgress" or nil)
        for _, nl in ipairs(vim.split(x.note, "\n", { plain = true })) do
          add("        " .. nl, "LazyIssuesDim")
        end
      end
      add("")
    end
  end
  if not any then
    add("  (no release notes for this release)", "LazyIssuesDim")
  end

  local Popup = require("nui.popup")
  local pop = Popup({
    enter = true,
    border = {
      style = "rounded",
      text = { top = " Release notes ", top_align = "center", bottom = " q close ", bottom_align = "center" },
    },
    position = "50%",
    size = { width = "60%", height = "60%" },
    buf_options = { modifiable = false, filetype = "markdown" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder", wrap = true },
  })
  pop:mount()
  set_lines(pop.bufnr, lines)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_add_highlight(pop.bufnr, ns, h[2], h[1], 0, -1)
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      pcall(function()
        pop:unmount()
      end)
      if on_close then
        on_close()
      end
    end, { buffer = pop.bufnr })
  end
end

local function release_edit_menu(V)
  local rel = selected_release(V)
  if not rel then
    return
  end
  local Menu = require("nui.menu")
  local reopen
  reopen = function()
    vim.schedule(function()
      release_edit_menu(V)
    end)
  end
  local function save()
    actions.save_release(rel._path, rel)
    refresh(V, true)
  end
  local in_rel = 0
  for _, sp in ipairs(V.model.sprints) do
    if sp.ReleaseId == rel.Id then
      in_rel = in_rel + 1
    end
  end

  local lines = {
    Menu.item("  Name         " .. (rel.Name or ""), { action = "name" }),
    Menu.item("  Description   " .. ((rel.Description or ""):sub(1, 22)), { action = "desc" }),
    Menu.item("  Status        " .. (rel.Status or ""), { action = "status" }),
    Menu.separator("sprints (" .. in_rel .. ")"),
    Menu.item("  + Add sprint", { action = "addsprint" }),
    Menu.item("  − Remove sprint", { action = "removesprint" }),
    Menu.item("  ≣ Release notes", { action = "notes" }),
    Menu.separator("actions"),
    Menu.item("  ✗ Delete release", { action = "delete" }),
  }
  local dispatch = {
    name = function()
      prompt_input("Release name:", rel.Name or "", function(v)
        if v ~= nil and vim.trim(v) ~= "" then
          rel.Name = v
          save()
        end
        reopen()
      end)
    end,
    desc = function()
      local cur = rel.Description
      if cur == vim.NIL then
        cur = ""
      end
      multiline_input("Release description", cur or "", function(t)
        rel.Description = t
        save()
      end, reopen)
    end,
    status = function()
      prompt_select("Release status:", config.release_status, function(v)
        if v then
          rel.Status = v
          save()
        end
        reopen()
      end)
    end,
    addsprint = function()
      local items, map = {}, {}
      for _, sp in ipairs(V.model.sprints) do
        if sp.ReleaseId ~= rel.Id then
          items[#items + 1] = sp.Name
          map[sp.Name] = sp
        end
      end
      if #items == 0 then
        vim.notify("lazyissues: no other sprints to add", vim.log.levels.INFO)
        return reopen()
      end
      prompt_select("Add sprint to release:", items, function(c)
        if c then
          map[c].ReleaseId = rel.Id
          actions.save_sprint(map[c]._path, map[c])
          refresh(V, true)
        end
        reopen()
      end)
    end,
    removesprint = function()
      local items, map = {}, {}
      for _, sp in ipairs(V.model.sprints) do
        if sp.ReleaseId == rel.Id then
          items[#items + 1] = sp.Name
          map[sp.Name] = sp
        end
      end
      if #items == 0 then
        vim.notify("lazyissues: no sprints in this release", vim.log.levels.INFO)
        return reopen()
      end
      prompt_select("Remove sprint from release:", items, function(c)
        if c then
          map[c].ReleaseId = config.empty_guid
          actions.save_sprint(map[c]._path, map[c])
          refresh(V, true)
        end
        reopen()
      end)
    end,
    notes = function()
      release_notes_preview(V, rel, reopen)
    end,
    delete = function()
      prompt_select('Delete release "' .. (rel.Name or "") .. '"?', { "No", "Yes" }, function(c)
        if c == "Yes" then
          -- Cascade: clear ReleaseId on every sprint pointing at this release.
          for _, sp in ipairs(V.model.sprints) do
            if sp.ReleaseId == rel.Id then
              sp.ReleaseId = config.empty_guid
              actions.save_sprint(sp._path, sp)
            end
          end
          local ok, err = actions.delete_release(rel._path)
          if not ok then
            vim.notify("lazyissues: " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          reload(V)
        else
          reopen()
        end
      end)
    end,
  }

  local menu = Menu({
    position = "50%",
    size = { width = 46, height = #lines },
    border = {
      style = "rounded",
      text = { top = " Edit release ", top_align = "center", bottom = " ↵ select · q close ", bottom_align = "center" },
    },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder,CursorLine:PmenuSel" },
  }, {
    lines = lines,
    keymap = {
      focus_next = { "j", "<Down>" },
      focus_prev = { "k", "<Up>" },
      close = { "q", "<Esc>" },
      submit = { "<CR>", "l" },
    },
    on_submit = function(item)
      local fn = dispatch[item.action]
      if fn then
        vim.schedule(fn)
      end
    end,
  })
  menu:mount()
end

-- Forward declaration (defined after the template picker section).
local edit_template_flow

-- Buffer-local keymaps applied to every panel.
local function map_keys(V, bufnr, kind)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, nowait = true, silent = true })
  end
  map("q", function()
    close(V)
  end)
  map("<Esc>", function()
    close(V)
  end)
  map("<Tab>", function()
    cycle_focus(V, 1)
  end)
  map("<S-Tab>", function()
    cycle_focus(V, -1)
  end)
  map("1", function()
    focus(V, "scopes")
  end)
  map("2", function()
    focus(V, "sprints")
  end)
  map("3", function()
    focus(V, "releases")
  end)
  map("4", function()
    focus(V, "issues")
  end)
  map("5", function()
    focus(V, "detail")
  end)
  map("/", function()
    do_search(V)
  end)
  map("f", function()
    field_filter_action(V)
  end)
  map("F", function()
    jump_to_issue(V)
  end)
  map("r", function()
    reload(V)
  end)
  map("?", function()
    M.help()
  end)
  map("E", function()
    local template = actions.load_template(V.root)
    edit_template_flow(V.root, template, function()
      reload(V)
    end)
  end)

  if kind == "scopes" then
    map("<CR>", function()
      on_enter_scopes(V)
    end)
  elseif kind == "sprints" then
    map("<CR>", function()
      on_enter_sprints(V)
    end)
    map("<Space>", function()
      toggle_sprint(V)
    end)
    map("o", function()
      create_sprint_action(V)
    end)
    map("e", function()
      sprint_edit_menu(V)
    end)
  elseif kind == "releases" then
    map("<CR>", function()
      on_enter_releases(V)
    end)
    map("o", function()
      create_release_action(V)
    end)
    map("e", function()
      release_edit_menu(V)
    end)
  elseif kind == "issues" then
    map("<CR>", function()
      local node = selected_node(V)
      if node and #node.children > 0 then
        toggle_expand(V)
      else
        focus(V, "detail")
      end
    end)
    map("<Space>", function()
      toggle_expand(V)
    end)
    map("zR", function()
      set_all_expanded(V, true)
    end)
    map("zM", function()
      set_all_expanded(V, false)
    end)
    map("]c", function()
      jump_changed(V, 1)
    end)
    map("[c", function()
      jump_changed(V, -1)
    end)
    map("l", function()
      focus(V, "detail")
    end)
    map("h", function()
      focus(V, "scopes")
    end)
    -- Field edits
    map("s", function()
      picker(V, "Status", config.issue_status, "Status:")
    end)
    map("p", function()
      picker(V, "Priority", config.issue_priority, "Priority:")
    end)
    map("t", function()
      picker(V, "Type", config.issue_type, "Type:")
    end)
    map("a", function()
      picker(V, "Assignee", config.assignees, "Assignee:", function(c)
        return c == "Unassigned" and "" or c
      end)
    end)
    map("m", function()
      pick_sprint(V)
    end)
    map("e", function()
      edit_menu(V)
    end)
    map("c", function()
      comments_view(V)
    end)
    map("d", function()
      edit_multiline(V, "Description", "Description")
    end)
    map("T", function()
      edit_tags(V)
    end)
    map("n", function()
      picker(V, "ReleaseNoteType", config.release_note_type, "Release note type:")
    end)
    map("N", function()
      edit_multiline(V, "ReleaseNote", "Release note")
    end)
    -- Structural
    map("o", function()
      create_issue_action(V, nil)
    end)
    map("O", function()
      create_issue_action(V, selected_node(V))
    end)
    map("D", function()
      delete_action(V)
    end)
    map("P", function()
      change_parent_action(V)
    end)
  end
end

-- Highlight the first occurrence of `word` on the given buffer line.
local function hl_word(bufnr, line_idx, word, group)
  local text = vim.api.nvim_buf_get_lines(bufnr, line_idx, line_idx + 1, false)[1] or ""
  local s = text:find(word, 1, true)
  if s then
    vim.api.nvim_buf_add_highlight(bufnr, ns, group, line_idx, s - 1, s - 1 + #word)
  end
end

function M.help()
  local lines = {
    "",
    "  Navigation",
    "    Tab / S-Tab    cycle panels         1 2 3 4 5   jump to a panel",
    "    j / k          move cursor          <CR>        select / open",
    "    <Space>        expand / collapse    /           search by title",
    "    l / h          detail / scopes      r           reload",
    "    E              edit template    ? / q / <Esc>  help / close",
    "",
    "  Edit selected issue",
    "    e edit menu   c comments   o new   D delete   P re-parent",
    "    quick:  s status  p priority  t type  a assignee  m sprint",
    "",
    "  Sprints / Releases panels",
    "    <Space> expand   <CR> filter   o new   e edit (status, sprints, notes)",
    "",
    "  Status      ● Open   ◐ In Progress   ◆ Resolved   ✓ Closed",
    "",
    "  Priority    Low   Medium   High   Critical",
    "",
    "  Type        Bug   Feature   Task   Improvement",
    "",
    "  Edited      ▌ on this branch     ▏ has an edited child",
    "",
  }

  local top = NuiLine()
  top:append(" lazyissues ", "FloatBorder")
  top:append("help", "FloatTitle")
  top:append(" ", "FloatBorder")
  local bottom = NuiLine()
  bottom:append(" q / Esc / ? to close ", "FloatBorder")

  local Popup = require("nui.popup")
  local pop = Popup({
    enter = true,
    border = {
      style = "rounded",
      text = { top = top, top_align = "center", bottom = bottom, bottom_align = "center" },
    },
    position = "50%",
    size = { width = 68, height = #lines },
    buf_options = { modifiable = false, filetype = "lazyissues-help" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder" },
  })
  pop:mount()
  set_lines(pop.bufnr, lines)

  -- Content-driven highlighting: section headers start at column 2 (key rows are
  -- indented 4), and each legend token is colored wherever it appears.
  local b = pop.bufnr
  local tokens = {
    { "● Open", "LazyIssuesOpen" },
    { "◐ In Progress", "LazyIssuesInProgress" },
    { "◆ Resolved", "LazyIssuesResolved" },
    { "✓ Closed", "LazyIssuesClosed" },
    { "Low", "LazyIssuesLow" },
    { "Medium", "LazyIssuesMedium" },
    { "High", "LazyIssuesHigh" },
    { "Critical", "LazyIssuesCritical" },
    { "Bug", "LazyIssuesBug" },
    { "Feature", "LazyIssuesFeature" },
    { "Task", "LazyIssuesTaskType" },
    { "Improvement", "LazyIssuesImprovement" },
    { "▌ on this branch", "LazyIssuesChanged" },
    { "▏ has an edited child", "LazyIssuesChangedDim" },
  }
  for i, line in ipairs(lines) do
    local idx = i - 1
    if line:match("^  %S") then
      vim.api.nvim_buf_add_highlight(b, ns, "LazyIssuesHeader", idx, 0, -1)
    end
    for _, t in ipairs(tokens) do
      hl_word(b, idx, t[1], t[2])
    end
  end

  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function()
      pcall(function()
        pop:unmount()
      end)
    end, { buffer = b, nowait = true, silent = true })
  end
end

-- ── template picker ─────────────────────────────────────────────────────────

-- Interactive checklist for selecting issue fields from the predefined list.
-- `selected` is an optional set { [field_name] = true } of pre-selected fields.
-- `on_done(fields)` is called with the list of selected predefined field defs.
-- If editing an existing template, `existing_template` is passed so we can
-- detect added/removed fields.
local function template_picker(selected, existing_template, on_done)
  local Popup = require("nui.popup")
  local fields = config.predefined_fields
  local checked = {}
  for _, f in ipairs(fields) do
    checked[f.name] = selected and selected[f.name] or false
  end

  local top = NuiLine()
  top:append(" lazyissues ", "LazyIssuesBorder")
  top:append("template", "FloatTitle")
  top:append(" ", "LazyIssuesBorder")
  local bottom = NuiLine()
  bottom:append(" space toggle · enter confirm · q cancel ", "LazyIssuesBorder")

  local pop = Popup({
    enter = true,
    relative = "editor",
    border = {
      style = "rounded",
      text = {
        top = top,
        top_align = "center",
        bottom = bottom,
        bottom_align = "center",
      },
      highlight = "LazyIssuesBorder",
    },
    position = "50%",
    size = { width = 64, height = #fields + 4 },
    zindex = 60,
    buf_options = { modifiable = false, filetype = "lazyissues-picker" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder", cursorline = true },
  })
  pop:mount()

  local function redraw()
    local lines = {
      "  Choose which fields your issues will have:",
      "",
    }
    for _, f in ipairs(fields) do
      local mark = checked[f.name] and "[x]" or "[ ]"
      lines[#lines + 1] = string.format("  %s  %-20s  (%s)", mark, f.name, f.type)
    end
    vim.bo[pop.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(pop.bufnr, 0, -1, false, lines)
    vim.bo[pop.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(pop.bufnr, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(pop.bufnr, ns, "LazyIssuesLabel", 0, 0, -1)
    local offset = 2 -- header lines
    for i, f in ipairs(fields) do
      if checked[f.name] then
        vim.api.nvim_buf_add_highlight(pop.bufnr, ns, "LazyIssuesOpen", offset + i - 1, 0, -1)
      end
    end
  end

  local offset = 2 -- header lines
  local function toggle()
    local row = vim.api.nvim_win_get_cursor(pop.winid)[1]
    local f = fields[row - offset]
    if f then
      checked[f.name] = not checked[f.name]
      redraw()
    end
  end

  local function confirm()
    pcall(function()
      pop:unmount()
    end)
    local result = {}
    for _, f in ipairs(fields) do
      if checked[f.name] then
        result[#result + 1] = vim.deepcopy(f)
      end
    end
    if on_done then
      on_done(result)
    end
  end

  local function cancel()
    pcall(function()
      pop:unmount()
    end)
  end

  local b = pop.bufnr
  vim.keymap.set("n", "<Space>", toggle, { buffer = b, nowait = true, silent = true })
  vim.keymap.set("n", "x", toggle, { buffer = b, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", confirm, { buffer = b, nowait = true, silent = true })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, cancel, { buffer = b, nowait = true, silent = true })
  end
  vim.keymap.set("n", "j", "j", { buffer = b, nowait = true, silent = true })
  vim.keymap.set("n", "k", "k", { buffer = b, nowait = true, silent = true })
  redraw()
  -- Place cursor on the first field row (past the header).
  pcall(vim.api.nvim_win_set_cursor, pop.winid, { offset + 1, 0 })
end

-- Prompt for enum values for enum fields in the selected list.
-- If `existing_template` is provided, only prompts for newly added enums.
-- Calls on_done(fields) with the fields updated with user-chosen values.
local function configure_enum_values(selected_fields, existing_template, on_done)
  local existing_set = {}
  if existing_template then
    for _, f in ipairs(existing_template.fields) do
      existing_set[f.name] = true
    end
  end
  local enums = {}
  for _, f in ipairs(selected_fields) do
    if f.type == "enum" and not existing_set[f.name] then
      enums[#enums + 1] = f
    end
  end
  if #enums == 0 then
    return on_done(selected_fields)
  end
  local idx = 0
  local function next_enum()
    idx = idx + 1
    if idx > #enums then
      return on_done(selected_fields)
    end
    local f = enums[idx]
    local cur = table.concat(f.values or {}, ", ")
    prompt_input(f.name .. " values (comma-separated)", cur, function(input)
      if input and vim.trim(input) ~= "" then
        local vals = {}
        for v in input:gmatch("[^,]+") do
          local trimmed = vim.trim(v)
          if trimmed ~= "" then
            vals[#vals + 1] = trimmed
          end
        end
        if #vals > 0 then
          f.values = vals
        end
      end
      vim.schedule(next_enum)
    end)
  end
  next_enum()
end

-- Build and save template from selected fields. Handles the init flow
-- (no existing template) and the edit flow (existing template with diffs).
local function finalize_template(data_root, selected_fields, existing_template, on_done)
  local template = { fields = selected_fields }

  if existing_template then
    -- Compute added and removed fields.
    local old_set = {}
    for _, f in ipairs(existing_template.fields) do
      old_set[f.name] = true
    end
    local new_set = {}
    for _, f in ipairs(selected_fields) do
      new_set[f.name] = true
    end

    local added = {}
    for _, f in ipairs(selected_fields) do
      if not old_set[f.name] then
        added[#added + 1] = f
      end
    end
    local removed = {}
    for _, f in ipairs(existing_template.fields) do
      if not new_set[f.name] then
        removed[#removed + 1] = f
      end
    end

    -- Process added fields: prompt for default and backfill.
    local function process_added(i, cb)
      if i > #added then
        return cb()
      end
      local f = added[i]
      local prompt = "Default value for new field '" .. f.name .. "': "
      if f.type == "enum" and f.values then
        prompt_select(prompt, f.values, function(choice)
          if choice then
            actions.backfill_field(data_root, f.name, choice)
          else
            actions.backfill_field(data_root, f.name, f.default)
          end
          vim.schedule(function()
            process_added(i + 1, cb)
          end)
        end)
      elseif f.type == "number" then
        prompt_input(prompt, "0", function(input)
          local val = tonumber(input) or f.default
          actions.backfill_field(data_root, f.name, val)
          vim.schedule(function()
            process_added(i + 1, cb)
          end)
        end)
      elseif f.type == "list" then
        actions.backfill_field(data_root, f.name, {})
        vim.schedule(function()
          process_added(i + 1, cb)
        end)
      else
        prompt_input(prompt, tostring(f.default or ""), function(input)
          actions.backfill_field(data_root, f.name, input or f.default or "")
          vim.schedule(function()
            process_added(i + 1, cb)
          end)
        end)
      end
    end

    -- Process removed fields: ask to delete or keep.
    local function process_removed(i, cb)
      if i > #removed then
        return cb()
      end
      local f = removed[i]
      prompt_select(
        "Field '" .. f.name .. "' removed:",
        { "Delete from all issues", "Keep data (orphaned)" },
        function(choice)
          if choice and choice:find("^Delete") then
            actions.remove_field_from_issues(data_root, f.name)
          end
          vim.schedule(function()
            process_removed(i + 1, cb)
          end)
        end
      )
    end

    process_added(1, function()
      process_removed(1, function()
        actions.save_template(data_root, template)
        vim.notify("lazyissues: template updated", vim.log.levels.INFO)
        if on_done then
          on_done()
        end
      end)
    end)
  else
    -- New template: just save.
    actions.save_template(data_root, template)
    vim.notify("lazyissues: template saved", vim.log.levels.INFO)
    if on_done then
      on_done()
    end
  end
end

-- Full template editing flow: pick fields → configure enums → save/migrate.
edit_template_flow = function(data_root, existing_template, on_done)
  local selected = {}
  if existing_template then
    for _, f in ipairs(existing_template.fields) do
      selected[f.name] = true
    end
  else
    -- No template yet: pre-select the classic field set.
    for _, name in ipairs({ "Type", "Title", "Description", "Status", "Priority",
      "SprintId", "Reporter", "Assignee", "Tags", "Comments", "ReleaseNoteType", "ReleaseNote" }) do
      selected[name] = true
    end
  end

  template_picker(selected, existing_template, function(fields)
    if #fields == 0 then
      vim.notify("lazyissues: no fields selected, template unchanged", vim.log.levels.WARN)
      if on_done then
        on_done()
      end
      return
    end
    configure_enum_values(fields, existing_template, function(configured)
      finalize_template(data_root, configured, existing_template, on_done)
    end)
  end)
end

-- ── open ────────────────────────────────────────────────────────────────────

-- Intro / setup screen shown when the repo has no Issues/ folder yet.
function M.offer_init()
  local cwd = vim.fn.getcwd()
  local repo = gitmod.repo_root(cwd) or cwd
  icons.setup()

  local lines = {
    "",
    "  No issue tracker in this repository yet.",
    "",
    "  Initialize one at:",
    "    " .. repo .. "/Issues",
    "",
    "  This creates:",
    "    Issues/     issues & nested sub-issues",
    "    Sprints/    sprints",
    "    Releases/   releases",
    "",
    "  ⏎ / i  initialize          q / Esc  cancel",
    "",
  }

  local top = NuiLine()
  top:append(" lazyissues ", "FloatBorder")
  top:append("setup", "FloatTitle")
  top:append(" ", "FloatBorder")

  local Popup = require("nui.popup")
  local pop = Popup({
    enter = true,
    border = { style = "rounded", text = { top = top, top_align = "center" } },
    position = "50%",
    size = { width = math.max(56, #repo + 16), height = #lines },
    buf_options = { modifiable = false, filetype = "lazyissues-intro" },
    win_options = { winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder" },
  })
  pop:mount()
  set_lines(pop.bufnr, lines)
  local b = pop.bufnr
  vim.api.nvim_buf_add_highlight(b, ns, "LazyIssuesHeader", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(b, ns, "LazyIssuesChanged", 4, 0, -1)
  vim.api.nvim_buf_add_highlight(b, ns, "LazyIssuesLabel", 6, 0, -1)
  vim.api.nvim_buf_add_highlight(b, ns, "LazyIssuesFooter", 11, 0, -1)

  local function do_init()
    pcall(function()
      pop:unmount()
    end)
    local ok, base = actions.init_data_root(repo)
    if not ok then
      vim.notify("lazyissues: " .. tostring(base), vim.log.levels.ERROR)
      return
    end
    vim.notify("lazyissues: initialized " .. base, vim.log.levels.INFO)
    -- Show the template picker so the user can select which fields their issues use.
    -- Pre-select the classic field set.
    local classic = {}
    for _, name in ipairs({ "Type", "Title", "Description", "Status", "Priority",
      "SprintId", "Reporter", "Assignee", "Tags", "Comments", "ReleaseNoteType", "ReleaseNote" }) do
      classic[name] = true
    end
    template_picker(classic, nil, function(fields)
      if #fields == 0 then
        -- User cancelled or selected nothing — use classic defaults.
        M.open()
        return
      end
      configure_enum_values(fields, nil, function(configured)
        finalize_template(base, configured, nil, function()
          M.open()
        end)
      end)
    end)
  end
  for _, k in ipairs({ "<CR>", "i" }) do
    vim.keymap.set("n", k, do_init, { buffer = b, nowait = true, silent = true })
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      pcall(function()
        pop:unmount()
      end)
    end, { buffer = b, nowait = true, silent = true })
  end
end

function M.open()
  if M._view then
    return
  end
  local data_root = root.find(vim.fn.getcwd())
  if not data_root then
    M.offer_init()
    return
  end

  icons.setup()

  local function panel(num, name)
    -- Title: "[N]" in the border color, then the panel name.
    local top = NuiLine()
    top:append(" [" .. num .. "] ", "FloatBorder")
    top:append(name .. " ", "FloatTitle")
    return Popup({
      border = {
        style = "rounded",
        text = { top = top, top_align = "left" },
      },
      focusable = true,
      buf_options = { modifiable = false, filetype = "lazyissues" },
      win_options = { cursorline = true, winhighlight = "Normal:Normal,FloatBorder:LazyIssuesBorder" },
    })
  end

  local V = {
    root = data_root,
    model = store.load(data_root),
    scope = { kind = "all" },
    search = "",
    expanded = {},
    sprint_expanded = {},
    scopes = panel(1, "Scopes"),
    sprints = panel(2, "Sprints"),
    releases = panel(3, "Releases"),
    issues = panel(4, "Issues"),
    detail = panel(5, "Detail"),
    footer = Popup({
      border = "none",
      focusable = false,
      buf_options = { modifiable = false, filetype = "lazyissues-footer" },
      win_options = { winhighlight = "Normal:Normal", wrap = false },
    }),
  }

  -- Build the layout box for a given main height (the footer reserves 1 line).
  -- The left column uses absolute heights summing to main_h so Releases always
  -- reaches the bottom; factored so VimResized can rebuild it.
  local function make_box(main_h)
    local h_scopes = math.floor(main_h * 0.26)
    local h_sprints = math.floor(main_h * 0.44)
    local h_releases = main_h - h_scopes - h_sprints
    return Layout.Box({
      Layout.Box({
        Layout.Box({
          Layout.Box(V.scopes, { size = h_scopes }),
          Layout.Box(V.sprints, { size = h_sprints }),
          Layout.Box(V.releases, { size = h_releases }),
        }, { dir = "col", size = "24%" }),
        Layout.Box(V.issues, { size = "46%" }),
        Layout.Box(V.detail, { size = "30%" }),
      }, { dir = "row", size = main_h }),
      Layout.Box(V.footer, { size = 1 }),
    }, { dir = "col" })
  end

  local wpct = string.format("%d%%", math.floor(config.width * 100))
  local total_h = math.floor(vim.o.lines * config.height)
  V.layout = Layout(
    { relative = "editor", position = "50%", size = { width = wpct, height = total_h } },
    make_box(total_h - 1)
  )
  V.layout:mount()
  M._view = V

  for _, kind in ipairs({ "scopes", "sprints", "releases", "issues", "detail" }) do
    map_keys(V, V[kind].bufnr, kind)
  end

  -- Context-sensitive footer: shortcut hints for the focused panel.
  local FOOTER_HINTS = {
    scopes = "  ⏎ select scope     Tab / 1-5 panels     ? help     q quit",
    sprints = "  ⏎ filter   ␣ expand   o new   e edit   Tab panels   ? help",
    releases = "  ⏎ filter   o new   e edit   Tab panels   ? help",
    issues = "  e edit   c comments   o new   O child   D del   P re-parent   / find   ? help",
    detail = "  Tab / 1-5 panels     ? help     q quit",
  }
  local function current_panel()
    local w = vim.api.nvim_get_current_win()
    for _, name in ipairs({ "scopes", "sprints", "releases", "issues", "detail" }) do
      if V[name].winid == w then
        return name
      end
    end
    return nil
  end
  local function update_footer()
    if not (V.footer.bufnr and vim.api.nvim_buf_is_valid(V.footer.bufnr)) then
      return
    end
    local panel_name = current_panel()
    if not panel_name then
      return
    end
    vim.bo[V.footer.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(V.footer.bufnr, 0, -1, false, { FOOTER_HINTS[panel_name] or "" })
    vim.bo[V.footer.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(V.footer.bufnr, ns, 0, -1)
    vim.api.nvim_buf_add_highlight(V.footer.bufnr, ns, "LazyIssuesFooter", 0, 0, -1)
  end

  V.augroup = vim.api.nvim_create_augroup("LazyIssuesView", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = V.augroup,
    buffer = V.issues.bufnr,
    callback = function()
      render_detail(V, selected_node(V))
      update_scrollbar(V.issues)
    end,
  })
  -- Keep every panel's scrollbar in sync as windows scroll.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = V.augroup,
    callback = function()
      update_scrollbars(V)
    end,
  })
  -- nvim_set_current_win (Tab / 1-5 / l / h) fires WinEnter, so the footer tracks focus.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = V.augroup,
    callback = update_footer,
  })

  -- Reload from disk when Neovim regains focus (e.g. after the web app or git
  -- changed the files), keeping the current selection.
  if config.auto_refresh then
    vim.api.nvim_create_autocmd("FocusGained", {
      group = V.augroup,
      callback = function()
        if M._view ~= V then
          return
        end
        local node = selected_node(V)
        reload_select(V, node and node.id)
      end,
    })
  end

  -- Reflow the layout when the terminal is resized.
  vim.api.nvim_create_autocmd("VimResized", {
    group = V.augroup,
    callback = function()
      if M._view ~= V then
        return
      end
      local th = math.floor(vim.o.lines * config.height)
      pcall(function()
        V.layout:update({ size = { width = wpct, height = th } }, make_box(th - 1))
      end)
      refresh(V, true)
    end,
  })

  recompute_changes(V)
  refresh(V)
  focus(V, "issues")
  update_footer()
end

return M
