-- ocui.tubeproto
-- Client side of the tube_server.py stream (protocol v1, documented in
-- server/tube_server.py): stream decoder + frame painter. Pure Lua 5.2
-- (no string.unpack, no bit ops), no component access.
--
--   local dec = proto.newDecoder()
--   dec:feed(bytesFromSocket)
--   for msg in dec:messages() do
--     -- msg.type: "header" {cols, rows, fps} | "frame" {data, from, to}
--     --           | "message" {text} | "end" {text}
--   end
--   proto.applyFrame(msg.data, msg.from, msg.to, gpu, palette, yield)

local M = {}

M.VERSION = 1
M.BLACK = 16 -- palette index the client screen starts from
M.HALF = "\226\150\128" -- "▀": fg paints the top pixel, bg the bottom one

-- The 256 colors of a tier 3 screen as 0xRRGGBB, index 0..255; matches
-- li.cil.oc.util.PackedColor.HybridFormat (16 default grays + 6x8x5 cube),
-- so sending these exact values is never re-quantized by the screen.
function M.palette()
  local p = {}
  for i = 0, 15 do
    local s = math.floor(255 * (i + 1) / 17)
    p[i] = s * 65536 + s * 256 + s
  end
  for index = 0, 239 do
    local b = index % 5
    local g = math.floor(index / 5) % 8
    local r = math.floor(index / 40) % 6
    local R = math.floor(r * 255 / 5 + 0.5)
    local G = math.floor(g * 255 / 7 + 0.5)
    local B = math.floor(b * 255 / 4 + 0.5)
    p[16 + index] = R * 65536 + G * 256 + B
  end
  return p
end

local function u16(s, i)
  local a, b = s:byte(i, i + 1)
  return a * 256 + b
end

local function u24(s, i)
  local a, b, c = s:byte(i, i + 2)
  return (a * 256 + b) * 256 + c
end

-- -------------------------------------------------------------- decoder --

local Decoder = {}
Decoder.__index = Decoder

function M.newDecoder()
  return setmetatable({ buf = "", pos = 1, header = nil }, Decoder)
end

function Decoder:feed(data)
  if self.pos > 1 then
    self.buf = self.buf:sub(self.pos)
    self.pos = 1
  end
  self.buf = self.buf .. data
end

function Decoder:buffered()
  return #self.buf - self.pos + 1
end

-- Next complete message, or nil if more data is needed. Frames are
-- returned as (data, from, to) indices into the buffer string to avoid
-- copying a few KB per frame. Raises on a malformed stream.
function Decoder:next()
  local buf, p = self.buf, self.pos
  local avail = #buf - p + 1
  if not self.header then
    if avail < 8 then return nil end
    if buf:sub(p, p + 3) ~= "OCTV" then error("not a tube stream (bad magic)", 0) end
    local version, cols, rows, fps = buf:byte(p + 4, p + 7)
    if version ~= M.VERSION then error("unsupported stream version " .. version, 0) end
    self.header = { type = "header", cols = cols, rows = rows, fps = fps }
    self.pos = p + 8
    return self.header
  end
  if avail < 1 then return nil end
  local kind = buf:sub(p, p)
  if kind == "F" then
    if avail < 4 then return nil end
    local len = u24(buf, p + 1)
    if avail < 4 + len then return nil end
    self.pos = p + 4 + len
    return { type = "frame", data = buf, from = p + 4, to = p + 3 + len }
  elseif kind == "M" or kind == "E" then
    if avail < 3 then return nil end
    local len = u16(buf, p + 1)
    if avail < 3 + len then return nil end
    self.pos = p + 3 + len
    return { type = kind == "M" and "message" or "end", text = buf:sub(p + 3, p + 2 + len) }
  end
  error("bad message type " .. string.format("%q", kind), 0)
end

function Decoder:messages()
  return function() return self:next() end
end

-- -------------------------------------------------------------- painter --

local runs = {}
local function halfBlocks(n)
  local s = runs[n]
  if not s then
    s = string.rep(M.HALF, n)
    runs[n] = s
  end
  return s
end

-- Paints one frame payload (s[from..to]) with `gpu` into whatever buffer is
-- active. `yield`, if given, is called every 400 runs so a big frame can't
-- trip OpenComputers' "too long without yielding". Returns the run count.
function M.applyFrame(s, from, to, gpu, palette, yield)
  local i = from
  local groups = u16(s, i)
  i = i + 2
  local done = 0
  for _ = 1, groups do
    local fg, bg = s:byte(i, i + 1)
    local count = u16(s, i + 2)
    i = i + 4
    gpu.setForeground(palette[fg])
    gpu.setBackground(palette[bg])
    for _ = 1, count do
      local x, y, len = s:byte(i, i + 2)
      i = i + 3
      gpu.set(x + 1, y + 1, halfBlocks(len))
      done = done + 1
      if yield and done % 400 == 0 then yield() end
    end
  end
  if i ~= to + 1 then
    error(string.format("frame length mismatch (%d vs %d)", i - from, to - from + 1), 0)
  end
  return done
end

return M
