-- ocui.pixels
-- PixelView: a widget that is a pixel framebuffer at twice the vertical
-- resolution of the text grid (each cell shows two square pixels with a
-- half-block character: 160x50 cells = 160x100 pixels on T3).
--
--   local view = PixelView.new({ w = 80, h = 25, bg = 0x000000 })
--   view:begin()                       -- erase what the last frame drew
--   view:line(0, 0, 50, 30, 0xFF0000)
--   view:fillTriangle(10, 10, 40, 12, 20, 40, 0x00FF00)
--   view:finish()                      -- repaint the changed area only
--
-- Only the bounding box of the pixels drawn in the previous and in this
-- frame is repainted. Drawing a frame emits one GPU call per run of cells
-- that can share colors: background cells are skipped (the area is filled
-- once), a cell whose two pixels match becomes a space, and each two-color
-- cell picks "▀" or "▄" so that it can continue the run on its left.
--
-- Colors are 24-bit; quantize() snaps them to the T3 palette so cells of
-- (visibly) the same color can share a run.

local base = require("ocui.widget")
local Widget = base.Widget

local UPPER = "\226\150\128" -- ▀
local LOWER = "\226\150\132" -- ▄

local PixelView = setmetatable({}, { __index = Widget })
PixelView.__index = PixelView

function PixelView.new(props)
  props = props or {}
  local self = setmetatable(Widget.new(props), PixelView)
  self.bg = props.bg or 0x000000
  self.pix = {}
  self.pw, self.ph = 0, 0
  self.drawn = nil -- {x0, y0, x1, y1} pixels drawn in the current frame
  self.shown = nil -- the same for the frame on screen
  return self
end

-- T3 screens show 256 colors: 16 grays + a 6x8x5 RGB cube. Snapping to
-- the cube lets cells of the same visible color share a GPU call.
local R_LEVELS = { 0x00, 0x33, 0x66, 0x99, 0xCC, 0xFF }
local G_LEVELS = { 0x00, 0x24, 0x49, 0x6D, 0x92, 0xB6, 0xDB, 0xFF }
local B_LEVELS = { 0x00, 0x40, 0x80, 0xC0, 0xFF }

local function snap(v, levels)
  local n = #levels - 1
  local i = math.floor(v / 255 * n + 0.5)
  if i < 0 then i = 0 elseif i > n then i = n end
  return levels[i + 1]
end

function PixelView.quantize(r, g, b)
  return snap(r, R_LEVELS) * 65536 + snap(g, G_LEVELS) * 256 + snap(b, B_LEVELS)
end

-- Fits the framebuffer to the widget (call when its size may have changed).
function PixelView:fit()
  local pw, ph = self.w or 0, (self.h or 0) * 2
  if pw ~= self.pw or ph ~= self.ph then
    self.pw, self.ph = pw, ph
    self.pix = {}
    self.drawn, self.shown = nil, nil
    self:invalidate()
  end
  return pw, ph
end

local function grow(box, x, y)
  if not box then return { x, y, x, y } end
  if x < box[1] then box[1] = x end
  if y < box[2] then box[2] = y end
  if x > box[3] then box[3] = x end
  if y > box[4] then box[4] = y end
  return box
end

-- Starts a frame: clears the pixels the previous frame drew.
function PixelView:begin()
  self:fit()
  local box = self.drawn
  if box then
    local pix, pw = self.pix, self.pw
    for y = box[2], box[4] do
      local row = y * pw
      for x = box[1], box[3] do pix[row + x + 1] = nil end
    end
  end
  self.shown = box
  self.drawn = nil
end

function PixelView:pset(x, y, c)
  if x < 0 or y < 0 or x >= self.pw or y >= self.ph then return end
  self.pix[y * self.pw + x + 1] = c
  self.drawn = grow(self.drawn, x, y)
end

-- Horizontal span [x0, x1] on row y, clipped.
function PixelView:span(x0, x1, y, c)
  if y < 0 or y >= self.ph then return end
  if x0 < 0 then x0 = 0 end
  if x1 >= self.pw then x1 = self.pw - 1 end
  if x1 < x0 then return end
  local row = y * self.pw + 1
  local pix = self.pix
  for x = x0, x1 do pix[row + x] = c end
  self.drawn = grow(grow(self.drawn, x0, y), x1, y)
end

-- Bresenham line.
function PixelView:line(x0, y0, x1, y1, c)
  x0, y0 = math.floor(x0 + 0.5), math.floor(y0 + 0.5)
  x1, y1 = math.floor(x1 + 0.5), math.floor(y1 + 0.5)
  local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx + dy
  local limit = dx - dy + 1
  for _ = 1, limit do
    self:pset(x0, y0, c)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 >= dy then err = err + dy; x0 = x0 + sx end
    if e2 <= dx then err = err + dx; y0 = y0 + sy end
  end
end

-- Filled triangle (scanline, pixel centers).
function PixelView:fillTriangle(x0, y0, x1, y1, x2, y2, c)
  -- sort by y
  if y1 < y0 then x0, y0, x1, y1 = x1, y1, x0, y0 end
  if y2 < y0 then x0, y0, x2, y2 = x2, y2, x0, y0 end
  if y2 < y1 then x1, y1, x2, y2 = x2, y2, x1, y1 end
  local yStart = math.max(math.ceil(y0 - 0.5), 0)
  local yEnd = math.min(math.floor(y2 - 0.5), self.ph - 1)
  for y = yStart, yEnd do
    local py = y + 0.5
    -- long edge 0-2
    local xa = x0 + (x2 - x0) * (py - y0) / (y2 - y0)
    local xb
    if py < y1 then
      xb = (y1 ~= y0) and (x0 + (x1 - x0) * (py - y0) / (y1 - y0)) or x1
    else
      xb = (y2 ~= y1) and (x1 + (x2 - x1) * (py - y1) / (y2 - y1)) or x1
    end
    if xa > xb then xa, xb = xb, xa end
    local s, e = math.ceil(xa - 0.5), math.floor(xb - 0.5)
    if e >= s then self:span(s, e, y, c) end
  end
end

-- Ends a frame: repaints the union of the old and new drawn areas.
function PixelView:finish()
  local a, b = self.shown, self.drawn
  local box
  if a then box = { a[1], a[2], a[3], a[4] } end
  if b then box = grow(grow(box, b[1], b[2]), b[3], b[4]) end
  self.shown = self.drawn
  if not box then return end
  local cy0, cy1 = math.floor(box[2] / 2), math.floor(box[4] / 2)
  self:invalidate(box[1], cy0, box[3] - box[1] + 1, cy1 - cy0 + 1)
end

function PixelView:draw(canvas)
  self:fit()
  local bg = self.bg
  canvas:fillRect(0, 0, self.w, self.h, bg)
  canvas.bg = bg
  local box = self.shown
  if not box then return end
  -- the part of the drawn box inside the area being repainted
  local cx0 = math.max(box[1], canvas.clipX - canvas.x)
  local cx1 = math.min(box[3], canvas.clipX + canvas.clipW - canvas.x - 1)
  local cy0 = math.max(math.floor(box[2] / 2), canvas.clipY - canvas.y)
  local cy1 = math.min(math.floor(box[4] / 2), canvas.clipY + canvas.clipH - canvas.y - 1)
  local pix, pw = self.pix, self.pw
  local chars = {}
  for cy = cy0, cy1 do
    local topRow, botRow = 2 * cy * pw + 1, (2 * cy + 1) * pw + 1
    local runX, runFg, runBg, n = nil, nil, nil, 0
    local function flush()
      if n > 0 then
        canvas:text(runX, cy, table.concat(chars, "", 1, n), runFg or runBg, runBg)
        n = 0
      end
      runX = nil
    end
    for cx = cx0, cx1 do
      local top = pix[topRow + cx] or bg
      local bot = pix[botRow + cx] or bg
      if top == bg and bot == bg then
        flush()
      else
        local ch, fg, cbg
        if top == bot then
          -- a space: only the background matters
          ch, fg, cbg = " ", nil, top
          if runX and runBg ~= top then flush() end
        elseif runX and runBg == bot and (runFg == nil or runFg == top) then
          ch, fg, cbg = UPPER, top, bot
        elseif runX and runBg == top and (runFg == nil or runFg == bot) then
          ch, fg, cbg = LOWER, bot, top
        else
          flush()
          -- prefer the background color as the cell's background, so the
          -- cell can merge with runs at the shape's edge
          if top == bg then ch, fg, cbg = LOWER, bot, top else ch, fg, cbg = UPPER, top, bot end
        end
        if not runX then runX, runBg, runFg = cx, cbg, fg end
        if fg then runFg = fg end
        n = n + 1
        chars[n] = ch
      end
    end
    flush()
  end
end

return PixelView
