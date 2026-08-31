-- ocui.canvas
-- Thin wrapper around a GPU + buffer index. Coordinates are 0-based (widget
-- space); GPU calls are 1-based, converted at the edge here.
--
-- Every Canvas carries an absolute origin (x, y) and an absolute clip
-- rect (clipX, clipY, clipW, clipH) that is the *intersection* of every
-- ancestor's bounds accumulated through :sub() calls. This means content
-- that overflows its container is always clipped away rather than
-- bleeding into a sibling or the parent's border -- a widget can never
-- draw outside the box its container gave it, no matter how deep the
-- nesting.

local util = require("ocui.util")

local Canvas = {}
Canvas.__index = Canvas

function Canvas.new(gpu, buffer, x, y, w, h, parentClipX, parentClipY, parentClipW, parentClipH)
  x, y = x or 0, y or 0
  local self = setmetatable({
    gpu = gpu,
    buffer = buffer or 0,
    x = x, y = y, w = w, h = h,
  }, Canvas)

  if parentClipX == nil then
    -- Root canvas: its own bounds are the clip.
    self.clipX, self.clipY, self.clipW, self.clipH = x, y, w, h
  else
    local x0 = math.max(parentClipX, x)
    local y0 = math.max(parentClipY, y)
    local x1 = math.min(parentClipX + parentClipW, x + w)
    local y1 = math.min(parentClipY + parentClipH, y + h)
    self.clipX, self.clipY = x0, y0
    self.clipW, self.clipH = math.max(x1 - x0, 0), math.max(y1 - y0, 0)
  end
  return self
end

-- Returns a child canvas offset by (x, y) in this canvas' local space,
-- clipped to (w, h) intersected with this canvas' own accumulated clip.
function Canvas:sub(x, y, w, h)
  return Canvas.new(self.gpu, self.buffer, self.x + x, self.y + y, w, h,
    self.clipX, self.clipY, self.clipW, self.clipH)
end

local function withBuffer(self, fn)
  local gpu = self.gpu
  local prev = gpu.getActiveBuffer()
  if prev ~= self.buffer then
    gpu.setActiveBuffer(self.buffer)
  end
  local ok, err = pcall(fn)
  if prev ~= self.buffer then
    gpu.setActiveBuffer(prev)
  end
  if not ok then
    error(err, 0)
  end
end

-- Intersects the local rect (x, y, w, h) with this canvas' accumulated
-- clip region. Returns 1-based (col, row, w, h) ready for a GPU call, or
-- nil if fully clipped away.
function Canvas:clipToAbs(x, y, w, h)
  local ax, ay = self.x + x, self.y + y
  local x0 = math.max(ax, self.clipX)
  local y0 = math.max(ay, self.clipY)
  local x1 = math.min(ax + w, self.clipX + self.clipW)
  local y1 = math.min(ay + h, self.clipY + self.clipH)
  local cw, ch = x1 - x0, y1 - y0
  if cw <= 0 or ch <= 0 then
    return nil
  end
  return x0 + 1, y0 + 1, cw, ch
end

function Canvas:fillRect(x, y, w, h, bg, char)
  local col, row, cw, ch = self:clipToAbs(x, y, w, h)
  if not col then return end
  withBuffer(self, function()
    if bg then self.gpu.setBackground(bg) end
    self.gpu.fill(col, row, cw, ch, char or " ")
  end)
end

-- Left-edge clipping (drawing text that starts before the clip region) is
-- not supported -- none of ocui's own widgets ever position text with a
-- negative offset into their own clip, so this only needs to handle the
-- common case: vertical clipping and right-edge truncation.
function Canvas:text(x, y, str, fg, bg)
  local ax, ay = self.x + x, self.y + y
  if ay < self.clipY or ay >= self.clipY + self.clipH then return end
  if ax < self.clipX then return end
  local maxCols = (self.clipX + self.clipW) - ax
  if maxCols <= 0 then return end
  if util.len(str) > maxCols then str = util.truncate(str, maxCols) end
  if #str == 0 then return end
  withBuffer(self, function()
    if fg then self.gpu.setForeground(fg) end
    if bg then self.gpu.setBackground(bg) end
    self.gpu.set(ax + 1, ay + 1, str)
  end)
end

function Canvas:hline(x, y, w, color, char)
  self:fillRect(x, y, w, 1, color, char or "\226\148\128") -- "─"
end

function Canvas:vline(x, y, h, color, char)
  char = char or "\226\148\130" -- "│"
  for i = 0, h - 1 do
    self:text(x, y + i, char, color)
  end
end

-- Draws a single-line box border around (x, y, w, h) with an optional
-- title embedded in the top edge.
function Canvas:border(x, y, w, h, color, title)
  if w < 2 or h < 2 then return end
  local top = "\226\148\140" .. string.rep("\226\148\128", w - 2) .. "\226\148\144" -- ┌─…─┐
  local bottom = "\226\148\148" .. string.rep("\226\148\128", w - 2) .. "\226\148\152" -- └─…─┘
  self:text(x, y, top, color)
  self:text(x, y + h - 1, bottom, color)
  self:vline(x, y + 1, h - 2, color)
  self:vline(x + w - 1, y + 1, h - 2, color)
  if title and w > 4 then
    local t = " " .. title .. " "
    if util.len(t) > w - 2 then t = util.truncate(t, w - 2) end
    self:text(x + 2, y, t, color)
  end
end

return Canvas
