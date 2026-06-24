-- Faithful JSON (de)serialization matching the .NET backend's System.Text.Json
-- output: PascalCase, 2-space indent, enums as strings, nulls written, and the
-- default JavaScriptEncoder escaping (" ' < > & + ` and non-ASCII as \uXXXX).
-- Goal: writes produce minimal git diffs against backend-written files.

local config = require("lazyissues.config")

local M = {}

-- Characters the .NET default encoder escapes to \uXXXX or short forms.
local ESCAPE = {
  ['"'] = "\\u0022",
  ["&"] = "\\u0026",
  ["'"] = "\\u0027",
  ["+"] = "\\u002B",
  ["<"] = "\\u003C",
  [">"] = "\\u003E",
  ["`"] = "\\u0060",
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

-- Decode one UTF-8 sequence starting at byte index i; returns codepoint, length.
local function utf8_decode(s, i, b)
  if b < 0xE0 then
    return ((b - 0xC0) * 0x40) + (string.byte(s, i + 1) - 0x80), 2
  elseif b < 0xF0 then
    return ((b - 0xE0) * 0x1000)
      + ((string.byte(s, i + 1) - 0x80) * 0x40)
      + (string.byte(s, i + 2) - 0x80),
      3
  else
    return ((b - 0xF0) * 0x40000)
      + ((string.byte(s, i + 1) - 0x80) * 0x1000)
      + ((string.byte(s, i + 2) - 0x80) * 0x40)
      + (string.byte(s, i + 3) - 0x80),
      4
  end
end

function M.escape_string(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = string.byte(s, i)
    if b < 0x80 then
      local ch = string.sub(s, i, i)
      local mapped = ESCAPE[ch]
      if mapped then
        out[#out + 1] = mapped
      elseif b < 0x20 then
        out[#out + 1] = string.format("\\u%04X", b)
      else
        out[#out + 1] = ch
      end
      i = i + 1
    else
      local cp, size = utf8_decode(s, i, b)
      i = i + size
      if cp <= 0xFFFF then
        out[#out + 1] = string.format("\\u%04X", cp)
      else
        cp = cp - 0x10000
        out[#out + 1] = string.format(
          "\\u%04X\\u%04X",
          0xD800 + math.floor(cp / 0x400),
          0xDC00 + (cp % 0x400)
        )
      end
    end
  end
  return table.concat(out)
end

-- Encode a scalar (string / null). Numbers/bools pass through if ever present.
local function scalar(v)
  if v == nil or v == vim.NIL then
    return "null"
  elseif type(v) == "string" then
    return '"' .. M.escape_string(v) .. '"'
  elseif type(v) == "boolean" or type(v) == "number" then
    return tostring(v)
  end
  return '"' .. M.escape_string(tostring(v)) .. '"'
end

-- Encode a list of strings (e.g. Tags) at the given indent.
local function string_array(arr, indent)
  if not arr or arr == vim.NIL or #arr == 0 then
    return "[]"
  end
  local pad = string.rep(" ", indent + 2)
  local parts = {}
  for _, s in ipairs(arr) do
    parts[#parts + 1] = pad .. scalar(s)
  end
  return "[\n" .. table.concat(parts, ",\n") .. "\n" .. string.rep(" ", indent) .. "]"
end

-- Encode an ordered object as { "Key": value, ... } at the given indent.
-- pairs_fn(field) -> rendered value string for each field name.
local function object(field_order, indent, value_for)
  local fpad = string.rep(" ", indent + 2)
  local lines = {}
  for _, key in ipairs(field_order) do
    lines[#lines + 1] = fpad .. '"' .. key .. '": ' .. value_for(key)
  end
  return "{\n" .. table.concat(lines, ",\n") .. "\n" .. string.rep(" ", indent) .. "}"
end

-- Encode the Comments array (array of ordered objects).
local function comments_array(arr, indent)
  if not arr or arr == vim.NIL or #arr == 0 then
    return "[]"
  end
  local pad = string.rep(" ", indent + 2)
  local objs = {}
  for _, c in ipairs(arr) do
    objs[#objs + 1] = pad
      .. object(config.comment_fields, indent + 2, function(k)
        return scalar(c[k])
      end)
  end
  return "[\n" .. table.concat(objs, ",\n") .. "\n" .. string.rep(" ", indent) .. "]"
end

-- Encode an issue table to canonical issue.json text (no trailing newline).
-- Absent fields (Lua nil) fall back to backend defaults; an explicit vim.NIL
-- (e.g. UpdatedAt) is preserved as null.
-- If a template is provided, uses the template's field order; otherwise uses
-- the hardcoded config.issue_fields order.
function M.encode_issue(it, template)
  local field_order
  if template then
    -- System fields first, then template fields in order.
    field_order = { "Id" }
    for _, f in ipairs(template.fields) do
      field_order[#field_order + 1] = f.name
    end
    field_order[#field_order + 1] = "CreatedAt"
    field_order[#field_order + 1] = "UpdatedAt"
  else
    field_order = config.issue_fields
  end
  return object(field_order, 0, function(key)
    -- Arrays sit at the field's indent (2), so their elements nest at 4 — matching
    -- System.Text.Json. (Empty [] hid this; non-empty Tags/Comments need it.)
    if key == "Tags" or key == "Labels" then
      return string_array(it[key], 2)
    elseif key == "Comments" then
      return comments_array(it.Comments, 2)
    end
    local v = it[key]
    if v == nil and not template then
      v = config.issue_defaults[key]
    end
    return scalar(v)
  end)
end

function M.encode_sprint(sp)
  return object(config.sprint_fields, 0, function(key)
    return scalar(sp[key])
  end)
end

function M.encode_release(rel)
  return object(config.release_fields, 0, function(key)
    return scalar(rel[key])
  end)
end

-- Decode JSON text, preserving nulls as vim.NIL (so UpdatedAt round-trips).
function M.decode(text)
  return vim.json.decode(text, { luanil = { object = false, array = false } })
end

-- Encode a template to pretty-printed JSON.
function M.encode_template(template)
  local parts = { "{\n" }
  parts[#parts + 1] = '  "fields": [\n'
  for i, f in ipairs(template.fields) do
    parts[#parts + 1] = "    {\n"
    parts[#parts + 1] = '      "name": ' .. scalar(f.name) .. ",\n"
    parts[#parts + 1] = '      "type": ' .. scalar(f.type) .. ",\n"
    if f.values then
      local vals = {}
      for _, v in ipairs(f.values) do
        vals[#vals + 1] = scalar(v)
      end
      parts[#parts + 1] = '      "values": [' .. table.concat(vals, ", ") .. "],\n"
    end
    -- Default: handle nil, tables, and scalars.
    local def = f.default
    if def == nil or def == vim.NIL then
      parts[#parts + 1] = '      "default": null\n'
    elseif type(def) == "table" then
      if #def == 0 then
        parts[#parts + 1] = '      "default": []\n'
      else
        local items = {}
        for _, v in ipairs(def) do
          items[#items + 1] = scalar(v)
        end
        parts[#parts + 1] = '      "default": [' .. table.concat(items, ", ") .. "]\n"
      end
    else
      parts[#parts + 1] = '      "default": ' .. scalar(def) .. "\n"
    end
    parts[#parts + 1] = i < #template.fields and "    },\n" or "    }\n"
  end
  parts[#parts + 1] = "  ]\n"
  parts[#parts + 1] = "}"
  return table.concat(parts)
end

return M
