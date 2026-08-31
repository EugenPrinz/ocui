-- ocui.widgets
-- Concrete UI primitives built on top of ocui.widget.

local base = require("ocui.widget")
local util = require("ocui.util")
local Widget, Container = base.Widget, base.Container

local M = {}

-- ---------------------------------------------------------------- Label --

local Label = setmetatable({}, { __index = Widget })
Label.__index = Label
M.Label = Label

function Label.new(props)
  local self = Widget.new(props)
  self.text = props.text or ""
  self.fg = props.fg
  self.bg = props.bg
  self.align = props.align or "left" -- left | center | right
  return setmetatable(self, Label)
end

function Label:setText(text)
  self.text = text
end

function Label:draw(canvas)
  if self.bg then canvas:fillRect(0, 0, self.w, self.h, self.bg) end
  local s = self.text
  if util.len(s) > self.w then s = util.truncate(s, self.w) end
  local slen = util.len(s)
  local x = 0
  if self.align == "center" then
    x = math.floor((self.w - slen) / 2)
  elseif self.align == "right" then
    x = self.w - slen
  end
  canvas:text(math.max(x, 0), 0, s, self.fg, self.bg)
end

-- ------------------------------------------------------------ ProgressBar --

local ProgressBar = setmetatable({}, { __index = Widget })
ProgressBar.__index = ProgressBar
M.ProgressBar = ProgressBar

function ProgressBar.new(props)
  local self = Widget.new(props)
  self.value = props.value or 0
  self.bg = props.bg
  self.fg = props.fg
  self.label = props.label
  return setmetatable(self, ProgressBar)
end

function ProgressBar:setValue(v)
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  self.value = v
end

function ProgressBar:draw(canvas)
  canvas:fillRect(0, 0, self.w, self.h, self.bg)
  local filled = math.floor(self.w * self.value + 0.5)
  if filled > 0 then
    canvas:fillRect(0, 0, filled, self.h, self.fg)
  end
  if self.label then
    local pct = string.format("%d%%", math.floor(self.value * 100 + 0.5))
    local text = self.label .. " " .. pct
    if util.len(text) > self.w then text = util.truncate(text, self.w) end
    local tx = math.max(math.floor((self.w - util.len(text)) / 2), 0)
    canvas:text(tx, 0, text, 0xFFFFFF)
  end
end

-- ----------------------------------------------------------------- Panel --

-- A bordered container with an optional title. Children are laid out in
-- the interior, inset by 1 cell on every side.
local Panel = setmetatable({}, { __index = Container })
Panel.__index = Panel
M.Panel = Panel

function Panel.new(props)
  local self = Container.new(props)
  self.title = props.title
  self.borderColor = props.borderColor
  self.bg = props.bg
  return setmetatable(self, Panel)
end

function Panel:innerSize()
  return math.max(self.w - 2, 0), math.max(self.h - 2, 0)
end

function Panel:draw(canvas)
  if self.bg then canvas:fillRect(0, 0, self.w, self.h, self.bg) end
  canvas:border(0, 0, self.w, self.h, self.borderColor, self.title)
  local iw, ih = self:innerSize()
  if iw <= 0 or ih <= 0 then return end
  local inner = canvas:sub(1, 1, iw, ih)
  for _, child in ipairs(self.children) do
    if child.visible then
      self:layoutChild(child, iw)
      child:draw(inner:sub(child.x, child.y, child.w, child.h))
    end
  end
end

function Panel:onTouch(x, y, button)
  local iw, ih = self:innerSize()
  local lx, ly = x - 1, y - 1
  if lx < 0 or ly < 0 or lx >= iw or ly >= ih then return false end
  for i = #self.children, 1, -1 do
    local child = self.children[i]
    if child.visible then
      self:layoutChild(child, iw)
      local cx, cy = lx - child.x, ly - child.y
      if child:contains(cx, cy) and child:onTouch(cx, cy, button) then
        return true
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------- VStack --

-- Stacks children top to bottom, each spanning the full width, separated
-- by `gap` rows. Heights come from each child's own `h`; x/y on children
-- are overwritten by layout(). Call :layout() after mutating children.
local VStack = setmetatable({}, { __index = Container })
VStack.__index = VStack
M.VStack = VStack

function VStack.new(props)
  local self = Container.new(props)
  self.gap = props.gap or 0
  return setmetatable(self, VStack)
end

function VStack:layout()
  local y = 0
  for _, child in ipairs(self.children) do
    child.x = 0
    child.y = y
    child.w = self.w
    y = y + child.h + self.gap
  end
  self.contentHeight = y
end

function VStack:draw(canvas)
  self:layout()
  Container.draw(self, canvas)
end

return M
