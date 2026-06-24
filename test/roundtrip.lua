-- Headless fidelity test: for every issue.json under a data root, decode then
-- re-encode and compare to the original bytes. Reports byte-identical vs diffs.
-- Runs against the bundled fixture by default; pass a path to test real data.
-- Usage (from the repo root):
--   nvim --headless --clean \
--     -c "lua package.path='./lua/?.lua;./lua/?/init.lua;./?.lua;'..package.path" \
--     -c "lua require('test.roundtrip').run()" -c "qa!"

local json = require("lazyissues.json")
local store = require("lazyissues.store")
local rootmod = require("lazyissues.root")

local M = {}

local function script_dir()
  return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
end

local function all_issue_jsons(dir, acc)
  acc = acc or {}
  local h = vim.uv.fs_scandir(dir)
  if not h then
    return acc
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(h)
    if not name then
      break
    end
    local p = dir .. "/" .. name
    if name == "issue.json" then
      acc[#acc + 1] = p
    elseif typ == "directory" then
      all_issue_jsons(p, acc)
    end
  end
  return acc
end

function M.run(data_root)
  data_root = data_root or (script_dir() .. "/fixture/Issues")
  local issues_dir = rootmod.issues_dir(data_root)
  local files = all_issue_jsons(issues_dir)
  local identical, canonical_already, idempotent, not_idem = 0, 0, 0, {}

  for _, path in ipairs(files) do
    local raw = store.read_file(path)
    local enc1 = json.encode_issue(json.decode(raw))
    local enc2 = json.encode_issue(json.decode(enc1))
    if raw == enc1 then
      identical = identical + 1 -- already in exact canonical form
    end
    if enc1 == raw then
      canonical_already = canonical_already + 1
    end
    -- The guarantee that matters: encode∘decode is a fixed point.
    if enc1 == enc2 then
      idempotent = idempotent + 1
    else
      not_idem[#not_idem + 1] = path
    end
  end

  print(string.format("data root : %s", data_root))
  print(string.format("issue.json files          : %d", #files))
  print(string.format("already byte-identical     : %d", identical))
  print(string.format("idempotent (stable canonical): %d / %d", idempotent, #files))
  print(string.format("NON-idempotent (real bugs) : %d", #not_idem))
  local diffs = not_idem
  for i = 1, math.min(3, #diffs) do
    print("  --- diff: " .. diffs[i])
    local raw = store.read_file(diffs[i])
    local enc = json.encode_issue(json.decode(raw))
    -- show first differing line
    local rl = vim.split(raw, "\n", { plain = true })
    local el = vim.split(enc, "\n", { plain = true })
    for j = 1, math.max(#rl, #el) do
      if rl[j] ~= el[j] then
        print(string.format("    line %d:", j))
        print("      raw: " .. tostring(rl[j]))
        print("      enc: " .. tostring(el[j]))
        break
      end
    end
  end
end

return M
