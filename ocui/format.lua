-- ocui.format
-- Number/duration formatting shared by screen and HUD apps. Safe for the
-- huge float values GTNH produces (wireless EU, UMV LSCs): never uses
-- string.format("%d") on a value that might not fit an integer.

local M = {}

local SI = { "", "K", "M", "G", "T", "P", "E", "Z", "Y" }

-- 1234567 -> "1.23M"; keeps the sign; values below 1000 print as-is.
function M.si(n, digits)
  if n == nil or n ~= n then return "?" end
  digits = digits or 2
  local sign = n < 0 and "-" or ""
  n = math.abs(n)
  local i = 1
  while n >= 1000 and i < #SI do
    n = n / 1000
    i = i + 1
  end
  if i == 1 then
    return sign .. string.format("%.0f", n)
  end
  return sign .. string.format("%." .. digits .. "f%s", n, SI[i])
end

-- Like si() but always shows an explicit "+" for positive values.
function M.signedSi(n, digits)
  if n ~= nil and n > 0 then
    return "+" .. M.si(n, digits)
  end
  return M.si(n, digits)
end

-- Scientific notation as GregTech shows it: 1234567 -> "1.23E6"; keeps
-- the sign; values below 1000 print as-is.
function M.sci(n, digits)
  if n == nil or n ~= n then return "?" end
  digits = digits or 2
  local a = math.abs(n)
  if a < 1000 then return string.format("%.0f", n) end
  local e = math.floor(math.log(a, 10))
  local m = a / 10 ^ e
  if tonumber(string.format("%." .. digits .. "f", m)) >= 10 then
    m = m / 10
    e = e + 1
  end
  return (n < 0 and "-" or "") .. string.format("%." .. digits .. "fE%d", m, e)
end

function M.signedSci(n, digits)
  if n ~= nil and n > 0 then
    return "+" .. M.sci(n, digits)
  end
  return M.sci(n, digits)
end

-- The same for an exact digit string of any length (e.g. a wireless EU
-- balance): "73891000000000000000000" -> "7.38E22". Digits are cut, not
-- rounded, so the exponent is always right.
function M.sciDigits(d, digits)
  digits = digits or 2
  d = tostring(d):gsub("^0+", "")
  if d == "" then return "0" end
  if #d <= 3 then return d end
  return d:sub(1, 1) .. "." .. d:sub(2, 1 + digits) .. "E" .. (#d - 1)
end

-- Item counts: plain integer up to 99,999, SI beyond that.
function M.count(n)
  if n == nil then return "?" end
  if math.abs(n) < 100000 then
    return string.format("%.0f", n)
  end
  return M.si(n, 1)
end

function M.percent(v, digits)
  return string.format("%." .. (digits or 1) .. "f%%", (v or 0) * 100)
end

-- 3725 -> "1h 2m"; 42 -> "42s"; nil/inf -> "--".
function M.duration(seconds)
  if seconds == nil or seconds ~= seconds or seconds == math.huge or seconds < 0 then
    return "--"
  end
  seconds = math.floor(seconds + 0.5)
  if seconds < 60 then
    return string.format("%ds", seconds)
  end
  local m = math.floor(seconds / 60)
  if m < 60 then
    return string.format("%dm %ds", m, seconds % 60)
  end
  local h = math.floor(m / 60)
  if h < 48 then
    return string.format("%dh %dm", h, m % 60)
  end
  local d = math.floor(h / 24)
  if d < 365 then
    return string.format("%dd %dh", d, h % 24)
  end
  return M.si(d / 365, 1) .. "y"
end

local KILO = 1024
local BYTES = { "B", "K", "M", "G", "T" }

function M.bytes(n)
  n = n or 0
  local i = 1
  while n >= KILO and i < #BYTES do
    n = n / KILO
    i = i + 1
  end
  if i == 1 then
    return string.format("%.0f%s", n, BYTES[i])
  end
  return string.format("%.1f%s", n, BYTES[i])
end

return M
