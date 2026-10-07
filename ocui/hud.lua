-- ocui.hud
-- Retained-mode UI toolkit for AR glasses (GTNH 2.8.4: OCGlasses
-- 1.6.1-GTNH, component type "glasses").
--
-- Unlike a GPU screen there is no framebuffer: the Glasses Terminal keeps
-- a list of widgets (rects, text labels, ...) that the client renders over
-- the game. Each widget is created once and then mutated. Every setter
-- call on a widget sends a network packet to every player wearing linked
-- glasses, so elements here cache their last value and only forward
-- real changes.
--
-- Coordinates are GUI pixels from the top-left of the player's screen;
-- they scale with Minecraft's "GUI Scale" setting, which a program cannot
-- query. Text is Minecraft's font: 8 px tall, ~6 px per character at
-- scale 1.
--
-- All primitives fan out to every glasses terminal passed to the surface,
-- so several terminals (e.g. one per player) show the same HUD.

local util = require("ocui.util")

local M = {}

M.CHAR_WIDTH = 6
M.LINE_HEIGHT = 10

-- Approximate rendered width of `s` in GUI pixels. Minecraft's font is
-- proportional, so this is an upper-ish estimate for typical text.
function M.textWidth(s, scale)
  return util.len(s) * M.CHAR_WIDTH * (scale or 1)
end

-- 0xRRGGBB -> r, g, b in 0..1. Plain arithmetic: OC's Lua 5.2
-- architecture has no bitwise operators.
local function rgb(hex)
  local r = math.floor(hex / 65536) % 256
  local g = math.floor(hex / 256) % 256
  local b = hex % 256
  return r / 255, g / 255, b / 255
end
M.rgb = rgb

local function signature(...)
  local args = table.pack(...)
  local parts = {}
  for i = 1, args.n do
    local v = args[i]
    if type(v) == "number" then
      parts[i] = string.format("%.2f", v)
    else
      parts[i] = tostring(v)
    end
  end
  return table.concat(parts, "|")
end

-- ------------------------------------------------------------- Element --

local Element = {}
Element.__index = Element

local function newElement(surface, factory, class)
  local raws = {}
  for i, g in ipairs(surface.glasses) do
    raws[i] = g[factory]()
  end
  return setmetatable({ raws = raws, cache = {} }, class)
end

-- Forwards raw[method](...) to every terminal's widget, unless the same
-- arguments were already sent for this `key`.
function Element:apply(key, method, ...)
  local sig = signature(...)
  if self.cache[key] == sig then return end
  self.cache[key] = sig
  for _, raw in ipairs(self.raws) do
    raw[method](...)
  end
end

function Element:setPosition(x, y) self:apply("pos", "setPosition", x, y) end
function Element:setColor(hex) self:apply("color", "setColor", rgb(hex)) end
function Element:setAlpha(a) self:apply("alpha", "setAlpha", a) end
function Element:setVisible(v) self:apply("visible", "setVisible", v and true or false) end

-- ---------------------------------------------------------------- Rect --

local Rect = setmetatable({}, { __index = Element })
Rect.__index = Rect
M.Rect = Rect

-- OCGlasses' Rect2D.setSize takes (vertical extent, horizontal extent) --
-- see SquareWidget.render() -- so this wrapper takes the conventional
-- (width, height) and swaps them.
function Rect:setSize(w, h) self:apply("size", "setSize", h, w) end

-- ---------------------------------------------------------------- Text --

local Text = setmetatable({}, { __index = Element })
Text.__index = Text
M.Text = Text

function Text:setText(s) self:apply("text", "setText", s) end
function Text:setScale(s) self:apply("scale", "setScale", s) end

-- ------------------------------------------------------------- Surface --

local Surface = {}
Surface.__index = Surface

-- All glasses terminals connected to this computer.
function M.findGlasses(component)
  local list = {}
  for address in component.list("glasses", true) do
    table.insert(list, component.proxy(address))
  end
  return list
end

function M.newSurface(glasses)
  assert(type(glasses) == "table" and #glasses > 0, "newSurface needs at least one glasses component")
  return setmetatable({ glasses = glasses }, Surface)
end

-- Removes every widget from every terminal (including ones created by
-- other programs on the same terminal).
function Surface:clear()
  for _, g in ipairs(self.glasses) do
    pcall(g.removeAll)
  end
end

-- props: x, y, w, h, color (0xRRGGBB), alpha, visible
function Surface:rect(props)
  props = props or {}
  local r = newElement(self, "addRect", Rect)
  r:setPosition(props.x or 0, props.y or 0)
  r:setSize(props.w or 1, props.h or 1)
  r:setColor(props.color or 0xFFFFFF)
  r:setAlpha(props.alpha or 1)
  if props.visible == false then r:setVisible(false) end
  return r
end

-- props: x, y, text, color, scale, alpha, visible
function Surface:text(props)
  props = props or {}
  local t = newElement(self, "addTextLabel", Text)
  t:setPosition(props.x or 0, props.y or 0)
  t:setText(props.text or "")
  t:setColor(props.color or 0xFFFFFF)
  t:setScale(props.scale or 1)
  t:setAlpha(props.alpha or 1)
  if props.visible == false then t:setVisible(false) end
  return t
end

-- ----------------------------------------------------------------- Bar --

local Bar = {}
Bar.__index = Bar
M.Bar = Bar

-- A horizontal progress bar: a track rect plus a fill rect.
-- props: x, y, w, h, bg, fg, alpha, value (0..1)
function Bar.new(surface, props)
  local self = setmetatable({
    x = props.x, y = props.y, w = props.w, h = props.h, shown = true,
  }, Bar)
  self.track = surface:rect({ x = props.x, y = props.y, w = props.w, h = props.h,
    color = props.bg or 0x232330, alpha = props.alpha or 0.8 })
  self.fill = surface:rect({ x = props.x, y = props.y, w = 0.01, h = props.h,
    color = props.fg or 0x4C8BF5, alpha = props.alpha or 0.9 })
  self:setValue(props.value or 0)
  return self
end

function Bar:setValue(v)
  if v ~= v then v = 0 end
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  self.value = v
  local fw = self.w * v
  self.fill:setVisible(self.shown and fw >= 0.25)
  self.fill:setSize(math.max(fw, 0.25), self.h)
end

function Bar:setColor(hex) self.fill:setColor(hex) end

function Bar:setPosition(x, y)
  self.x, self.y = x, y
  self.track:setPosition(x, y)
  self.fill:setPosition(x, y)
end

function Bar:setVisible(v)
  self.shown = v and true or false
  self.track:setVisible(self.shown)
  self.fill:setVisible(self.shown and self.w * self.value >= 0.25)
end

-- --------------------------------------------------------------- Graph --

local Graph = {}
Graph.__index = Graph
M.Graph = Graph

-- A scrolling bar chart of the last `bars` values, newest on the right.
-- Positive and negative values grow up/down from a zero line placed so
-- the window's largest values on both sides fill the height exactly
-- (auto-scaled every push).
-- props: x, y, w, h, bars, posColor, negColor, axisColor, bg, alpha,
--        labelColor, labelScale, format (fn(number) -> string)
function Graph.new(surface, props)
  local self = setmetatable({
    x = props.x, y = props.y, w = props.w, h = props.h,
    n = props.bars or 40,
    posColor = props.posColor or 0x4CD787,
    negColor = props.negColor or 0xE0574C,
    format = props.format or tostring,
    labelScale = props.labelScale or 0.75,
    values = {},
  }, Graph)
  if props.bg then
    self.bg = surface:rect({ x = props.x, y = props.y, w = props.w, h = props.h,
      color = props.bg, alpha = props.alpha or 0.5 })
  end
  self.bars = {}
  for i = 1, self.n do
    self.bars[i] = surface:rect({ x = props.x, y = props.y, w = 1, h = 1,
      color = self.posColor, alpha = 0.9, visible = false })
  end
  self.axis = surface:rect({ x = props.x, y = props.y + props.h, w = props.w, h = 0.5,
    color = props.axisColor or 0x8A8A96, alpha = 0.9 })
  local labelColor = props.labelColor or 0xBFBFC8
  self.topLabel = surface:text({ x = props.x + 1, y = props.y + 1, text = "",
    color = labelColor, scale = self.labelScale })
  self.bottomLabel = surface:text({ x = props.x + 1,
    y = props.y + props.h - 8 * self.labelScale - 1, text = "",
    color = labelColor, scale = self.labelScale })
  return self
end

function Graph:push(v)
  if type(v) ~= "number" or v ~= v then v = 0 end
  table.insert(self.values, v)
  while #self.values > self.n do
    table.remove(self.values, 1)
  end
  self:render()
end

-- Replaces the whole series (oldest first). Longer than `bars`: averaged
-- down in equal groups so the whole window fits; shorter: right-aligned.
-- nil entries (no data) count as gaps.
function Graph:setValues(values)
  local n, count = self.n, #values
  local out = {}
  if count <= n then
    for i = 1, count do out[i] = values[i] or 0 end
  else
    for i = 1, n do
      local from = math.floor((i - 1) * count / n) + 1
      local to = math.floor(i * count / n)
      local sum, k = 0, 0
      for j = from, to do
        if values[j] then sum = sum + values[j]; k = k + 1 end
      end
      out[i] = k > 0 and sum / k or 0
    end
  end
  self.values = out
  self:render()
end

function Graph:setPosition(x, y)
  self.x, self.y = x, y
  if self.bg then self.bg:setPosition(x, y) end
  self.topLabel:setPosition(x + 1, y + 1)
  self.bottomLabel:setPosition(x + 1, y + self.h - 8 * self.labelScale - 1)
  self:render()
end

-- --------------------------------------------------------------- Group --

local Group = {}
Group.__index = Group
M.Group = Group

-- A set of elements positioned relative to a shared origin, so a whole
-- panel can be moved with moveTo() (e.g. re-anchored when the screen size
-- becomes known). Children are created through the group with props.x/y
-- relative to the origin.
function M.newGroup(surface, x, y)
  return setmetatable({ surface = surface, x = x or 0, y = y or 0, children = {} }, Group)
end

local function absolute(group, props)
  local p = {}
  for k, v in pairs(props or {}) do p[k] = v end
  local dx, dy = p.x or 0, p.y or 0
  p.x, p.y = group.x + dx, group.y + dy
  return p, dx, dy
end

local function adopt(group, el, dx, dy)
  table.insert(group.children, { el = el, dx = dx, dy = dy })
  return el
end

function Group:rect(props)
  local p, dx, dy = absolute(self, props)
  return adopt(self, self.surface:rect(p), dx, dy)
end

function Group:text(props)
  local p, dx, dy = absolute(self, props)
  return adopt(self, self.surface:text(p), dx, dy)
end

function Group:bar(props)
  local p, dx, dy = absolute(self, props)
  return adopt(self, Bar.new(self.surface, p), dx, dy)
end

function Group:graph(props)
  local p, dx, dy = absolute(self, props)
  return adopt(self, Graph.new(self.surface, p), dx, dy)
end

function Group:moveTo(x, y)
  self.x, self.y = x, y
  for _, c in ipairs(self.children) do
    c.el:setPosition(x + c.dx, y + c.dy)
  end
end

-- Top-left corner for a box of size (w, h) placed `anchor` ("top-left",
-- "top-right", "bottom-left", "bottom-right") with offsets (x, y) from
-- that corner, on a screen of (screenW, screenH) GUI pixels.
function M.anchor(anchor, x, y, w, h, screenW, screenH)
  local ax, ay = x, y
  if anchor == "top-right" or anchor == "bottom-right" then
    ax = screenW - w - x
  end
  if anchor == "bottom-left" or anchor == "bottom-right" then
    ay = screenH - h - y
  end
  return ax, ay
end

M.ANCHORS = { "top-left", "top-right", "bottom-left", "bottom-right" }

local function round(v) return math.floor(v + 0.5) end

function Graph:render()
  local vals = self.values
  local maxPos, maxNeg = 0, 0
  for _, v in ipairs(vals) do
    if v > maxPos then maxPos = v end
    if -v > maxNeg then maxNeg = -v end
  end
  local span = maxPos + maxNeg
  -- Bars use whole GUI pixels only: with fractional widths and positions
  -- the client rounds each bar differently, so equal bars come out 1 px
  -- wider or narrower than their neighbours. The row is right-aligned and
  -- the remainder (less than one step) stays empty on the left.
  local zeroY, scale
  if span == 0 then
    zeroY = round(self.y + self.h)
    scale = 0
  else
    zeroY = round(self.y + self.h * maxPos / span)
    scale = self.h / span
  end
  self.axis:setPosition(self.x, zeroY - 0.25)

  local step = math.max(math.floor(self.w / self.n), 1)
  local gap = step >= 3 and 1 or 0
  local x0 = round(self.x + self.w) - self.n * step
  local offset = self.n - #vals -- right-align: newest value in the last slot
  for i = 1, self.n do
    local bar = self.bars[i]
    local v = vals[i - offset]
    if v == nil or v == 0 or scale == 0 then
      bar:setVisible(false)
    else
      local bh = math.max(round(math.abs(v) * scale), 1)
      local bx = x0 + (i - 1) * step
      if v > 0 then
        bar:setPosition(bx, zeroY - bh)
        bar:setColor(self.posColor)
      else
        bar:setPosition(bx, zeroY)
        bar:setColor(self.negColor)
      end
      bar:setSize(step - gap, bh)
      bar:setVisible(true)
    end
  end

  self.topLabel:setText(maxPos > 0 and ("+" .. self.format(maxPos)) or "")
  self.bottomLabel:setText(maxNeg > 0 and ("-" .. self.format(maxNeg)) or "")
end

return M
