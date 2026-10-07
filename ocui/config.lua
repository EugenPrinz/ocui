-- ocui.config
-- Per-app config files: /etc/ocui/<app>.cfg, a Lua table literal.
--
-- load(name, defaults): reads the file, deep-merges it over `defaults`
-- (so keys added in a newer app version get their defaults), and creates
-- the file from the defaults on first run so there is something to edit.
-- A broken file is reported, not silently replaced.

local storage = require("ocui.storage")

local M = {}

M.dir = "/etc/ocui"

function M.path(name)
  return M.dir .. "/" .. name .. ".cfg"
end

-- ------------------------------------------------------------- serialize --

local function isIdentifier(k)
  return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do table.insert(keys, k) end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  return keys
end

local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local function serializeValue(v, indent)
  local tv = type(v)
  if tv == "string" then
    return string.format("%q", v)
  elseif tv == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%.0f", v)
    end
    return string.format("%.17g", v)
  elseif tv == "boolean" or tv == "nil" then
    return tostring(v)
  elseif tv == "table" then
    if next(v) == nil then return "{}" end
    local pad = string.rep("  ", indent + 1)
    local lines = {}
    if isArray(v) then
      for _, item in ipairs(v) do
        table.insert(lines, pad .. serializeValue(item, indent + 1) .. ",")
      end
    else
      for _, k in ipairs(sortedKeys(v)) do
        local key = isIdentifier(k) and k or ("[" .. serializeValue(k, 0) .. "]")
        table.insert(lines, pad .. key .. " = " .. serializeValue(v[k], indent + 1) .. ",")
      end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. string.rep("  ", indent) .. "}"
  end
  error("cannot serialize a " .. tv)
end

function M.serialize(t)
  return serializeValue(t, 0)
end

-- Parses a table literal without giving it access to any globals.
function M.parse(text, chunkName)
  local chunk, err = load("return " .. text, "=" .. (chunkName or "config"), "t", {})
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok then return nil, value end
  if type(value) ~= "table" then return nil, "config must be a table" end
  return value
end

-- ---------------------------------------------------------------- merge --

local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepCopy(x) end
  return out
end

-- User values win; nested tables merge key by key, except arrays, which
-- the user replaces wholesale (a list of apps is a list, not a patch).
function M.merge(defaults, user)
  local out = deepCopy(defaults)
  for k, v in pairs(user or {}) do
    if type(v) == "table" and type(out[k]) == "table" and not isArray(v) and not isArray(out[k]) then
      out[k] = M.merge(out[k], v)
    else
      out[k] = deepCopy(v)
    end
  end
  return out
end

-- -------------------------------------------------------------- load/save --

M.copy = deepCopy

-- Writes `t` as /etc/ocui/<name>.cfg.
function M.save(name, t)
  local header = "-- " .. name .. " config (ocui). Edit and restart the app.\n"
  return storage.write(M.path(name), header .. M.serialize(t) .. "\n")
end

-- Returns config, or nil + error message if the file exists but is broken.
function M.load(name, defaults)
  defaults = defaults or {}
  local path = M.path(name)
  local text = storage.read(path)
  if text == nil then
    M.save(name, defaults)
    return deepCopy(defaults)
  end
  local body = text:gsub("^%s*%-%-[^\n]*\n", "") -- leading comment line(s)
  while body:match("^%s*%-%-") do
    body = body:gsub("^%s*%-%-[^\n]*\n", "")
  end
  local user, err = M.parse(body, path)
  if not user then
    return nil, path .. ": " .. tostring(err)
  end
  return M.merge(defaults, user)
end

return M
