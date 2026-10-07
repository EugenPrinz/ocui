-- ocui.lsc
-- Data source for a Lapotronic Supercapacitor (LSC) seen through an
-- Adapter. Verified against GTNH 2.8.4 (GT5-Unofficial 5.09.51.482,
-- OpenComputers 1.11.20-GTNH):
--
--   The adapter exposes the controller as component "gt_machine" with
--   getStoredEUString()/getEUCapacityString() (exact, unclamped values as
--   strings), getEUStored()/getEUMaxStored() (numbers), and
--   getSensorInformation() -> array of 24 lines from the LSC's
--   getInfoData(). Those lines are translated *server-side* -- in
--   single-player that means your client language -- so they are parsed
--   by position and by color code, never by their English wording:
--     [10] avg EU IN  (last 5 s)    [11] avg EU OUT (last 5 s)
--     [17] maintenance: §a ok / §c problems
--     [18] wireless mode: §a enabled / §c disabled
--     [23] total wireless EU (grouped integer)
--   Override the indices via opts.sensorLines if a pack update shifts
--   them.

local M = {}

M.DEFAULT_SENSOR_LINES = {
  avgIn = 10,
  avgOut = 11,
  maintenance = 17,
  wirelessMode = 18,
  wirelessEU = 23,
}

local SECTION = "\194\167" -- "§" (U+00A7) in UTF-8, Minecraft's formatting prefix
local GREEN = SECTION .. "a"
local RED = SECTION .. "c"

local function stripCodes(s)
  return (s:gsub(SECTION .. ".", ""))
end

-- Thousands separators used by Java's NumberFormat across locales:
-- , . ' space, NBSP (ru), narrow NBSP (fr), thin space.
local SEPARATORS = { ",", ".", "'", " ", "\194\160", "\226\128\175", "\226\128\137" }

-- Returns the first integer in `s` as a digit string, joining digit
-- groups split by locale thousands separators ("1 234 567" -> "1234567"),
-- or nil. Also understands newer GT's "key\\arg1\\arg2" wire format.
function M.firstNumber(s)
  if type(s) ~= "string" then return nil end
  s = stripCodes(s)
  local sepAt = s:find("\\\\", 1, true)
  if sepAt then
    s = s:sub(sepAt + 2)
  end
  local start = s:find("%d")
  if not start then return nil end
  local digits = {}
  local i = start
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%d") then
      digits[#digits + 1] = c
      i = i + 1
    else
      local advanced = false
      for _, sep in ipairs(SEPARATORS) do
        local afterSep = i + #sep
        if s:sub(i, afterSep - 1) == sep and s:sub(afterSep, afterSep + 2):match("^%d%d%d$") then
          i = afterSep
          advanced = true
          break
        end
      end
      if not advanced then break end
    end
  end
  return table.concat(digits)
end

-- Exact a - b for non-negative integer digit strings, returned as a Lua
-- number. Doubles only hold ~15 significant digits, so subtracting two
-- 20+ digit EU totals as floats would turn real flow into noise.
function M.decimalDiff(a, b)
  a = a:gsub("^0+", "")
  b = b:gsub("^0+", "")
  if #a <= 15 and #b <= 15 then
    return (tonumber(a) or 0) - (tonumber(b) or 0)
  end
  local sign = 1
  if #a < #b or (#a == #b and a < b) then
    a, b = b, a
    sign = -1
  end
  b = string.rep("0", #a - #b) .. b
  local digits = {}
  local borrow = 0
  for i = #a, 1, -1 do
    local d = a:byte(i) - b:byte(i) - borrow
    if d < 0 then
      d = d + 10
      borrow = 1
    else
      borrow = 0
    end
    digits[i] = d
  end
  local n = 0
  for i = 1, #digits do
    n = n * 10 + digits[i]
  end
  return sign * n
end

local function call(proxy, name)
  local fn = proxy[name]
  if fn == nil then return nil end
  local ok, v = pcall(fn)
  if ok then return v end
  return nil
end

local function isDigits(v)
  return type(v) == "string" and v:match("^%d+$") ~= nil
end

-- Finds the LSC. With an explicit address, uses that. Otherwise prefers a
-- gt_machine whose name mentions the supercapacitor, then any gt_machine
-- with an LSC-sized sensor readout, then the only gt_machine present.
function M.find(component, address)
  if address then
    return component.proxy(address)
  end
  local candidates = {}
  for addr in component.list("gt_machine", true) do
    table.insert(candidates, component.proxy(addr))
  end
  if #candidates == 0 then return nil end
  if #candidates == 1 then return candidates[1] end
  for _, p in ipairs(candidates) do
    local name = tostring(call(p, "getName") or ""):lower()
    if name:find("supercapacitor", 1, true) or name:find("lapotronic", 1, true) then
      return p
    end
  end
  for _, p in ipairs(candidates) do
    local info = call(p, "getSensorInformation")
    if type(info) == "table" and #info >= 23 then
      return p
    end
  end
  return candidates[1]
end

-- Reads one snapshot:
-- {
--   stored, capacity     -- numbers (float for huge values)
--   storedExact          -- digit string when available (for exact diffs)
--   fill                 -- 0..1
--   avgIn, avgOut        -- EU/t, 5-second averages from the sensor, or nil
--   wireless             -- true when the LSC is in wireless mode
--   maintenanceOk        -- false when the LSC reports maintenance problems
-- }
-- opts.wirelessMax: capacity to show 100% against in wireless mode.
-- opts.sensorLines: overrides for M.DEFAULT_SENSOR_LINES.
function M.read(proxy, opts)
  opts = opts or {}
  local lines = opts.sensorLines or M.DEFAULT_SENSOR_LINES
  local info = call(proxy, "getSensorInformation")
  if type(info) ~= "table" then info = {} end

  local r = { maintenanceOk = true, wireless = false }

  local storedStr = call(proxy, "getStoredEUString")
  if isDigits(storedStr) then
    r.storedExact = storedStr
    r.stored = tonumber(storedStr)
  else
    r.stored = tonumber(call(proxy, "getEUStored") or call(proxy, "getStoredEU")) or 0
  end
  r.capacity = tonumber(call(proxy, "getEUCapacityString"))
    or tonumber(call(proxy, "getEUMaxStored"))
    or tonumber(call(proxy, "getEUCapacity"))
    or 0

  local function line(key)
    local idx = lines[key]
    return idx and info[idx] or nil
  end

  local avgIn, avgOut = M.firstNumber(line("avgIn")), M.firstNumber(line("avgOut"))
  r.avgIn = avgIn and tonumber(avgIn) or nil
  r.avgOut = avgOut and tonumber(avgOut) or nil

  local maint = line("maintenance")
  if type(maint) == "string" and maint:find(RED, 1, true) then
    r.maintenanceOk = false
  end

  local wl = line("wirelessMode")
  if type(wl) == "string" and wl:find(GREEN, 1, true) then
    r.wireless = true
    local wEU = M.firstNumber(line("wirelessEU"))
    if wEU then
      r.storedExact = wEU
      r.stored = tonumber(wEU)
      r.capacity = opts.wirelessMax or r.capacity
    end
  end

  r.fill = r.capacity > 0 and math.min(r.stored / r.capacity, 1) or 0
  return r
end

-- Tracks consecutive readings to derive net flow (EU/t) from the change in
-- stored energy -- the fallback when the sensor's averages are missing,
-- and a cross-check otherwise.
local Sampler = {}
Sampler.__index = Sampler

function M.newSampler(clock)
  return setmetatable({ clock = clock, prev = nil }, Sampler)
end

-- Returns net EU/t since the previous reading, or nil on the first call.
function Sampler:update(reading)
  local now = self.clock()
  local net = nil
  local prev = self.prev
  if prev then
    local dt = now - prev.t
    if dt > 0 then
      local delta
      if reading.storedExact and prev.storedExact then
        delta = M.decimalDiff(reading.storedExact, prev.storedExact)
      else
        delta = reading.stored - prev.stored
      end
      net = delta / (dt * 20)
    end
  end
  self.prev = { t = now, stored = reading.stored, storedExact = reading.storedExact }
  return net
end

-- Net flow to plot: the sensor's 5 s averages when both are present,
-- otherwise the stored-energy derivative.
function M.netFlow(reading, derived)
  if reading.avgIn and reading.avgOut then
    return reading.avgIn - reading.avgOut
  end
  return derived
end

-- Seconds until full (net > 0) or empty (net < 0); nil if flat/unknown.
function M.timeToLimit(reading, net)
  if net == nil or net == 0 then return nil end
  if net > 0 then
    return math.max(reading.capacity - reading.stored, 0) / (net * 20)
  end
  return reading.stored / (-net * 20)
end

return M
