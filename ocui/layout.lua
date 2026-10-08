-- ocui.layout
-- Containers that size and place their children:
--
--   HBox / VBox   children in a row / column. A child with `flex = n`
--                 shares the free space by weight; others keep their own
--                 w (HBox) / h (VBox) -- in an HBox a child with no w
--                 counts as flex = 1. Every child spans the box's other
--                 dimension. props: gap, padding, bg.
--   Split         two panes side by side (dir = "h") or stacked ("v")
--                 with a divider that can be dragged. props: first,
--                 second, size (first pane, cells) or ratio (default 0.5),
--                 min (smallest pane, default 4), dividerColor, bg.

local base = require("ocui.widget")
local theme = require("ocui.theme")
local Container = base.Container

local M = {}

-- -------------------------------------------------------------------- Box --

local Box = setmetatable({}, { __index = Container })
Box.__index = Box

local function newBox(props, dir, class)
  props = props or {}
  local self = Container.new(props)
  self.dir = dir
  self.gap = props.gap or 0
  self.padding = props.padding or 0
  self.bg = props.bg
  return setmetatable(self, class)
end

local function mainSize(child, horizontal)
  if horizontal then return child.w end
  return child.h
end

function Box:layout()
  local horizontal = self.dir == "h"
  local pad = self.padding
  local main = (horizontal and self.w or self.h) - 2 * pad
  local cross = math.max((horizontal and self.h or self.w) - 2 * pad, 0)

  local visible, fixed, flexTotal = {}, 0, 0
  for _, child in ipairs(self.children) do
    if child.visible then
      visible[#visible + 1] = child
      if child.flex then
        flexTotal = flexTotal + child.flex
      else
        fixed = fixed + (mainSize(child, horizontal) or 0)
      end
    end
  end
  if #visible == 0 then return end
  local free = math.max(main - fixed - self.gap * (#visible - 1), 0)

  local pos, given, flexSeen = pad, 0, 0
  for _, child in ipairs(visible) do
    local size
    if child.flex then
      flexSeen = flexSeen + child.flex
      local upTo = math.floor(free * flexSeen / flexTotal + 0.5)
      size = upTo - given
      given = upTo
    else
      size = mainSize(child, horizontal) or 0
    end
    if horizontal then
      child.x, child.y, child.w, child.h = pos, pad, size, cross
    else
      child.x, child.y, child.w, child.h = pad, pos, cross, size
    end
    pos = pos + size + self.gap
  end
end

function Box:draw(canvas)
  self:layout()
  if self.bg then
    canvas:fillRect(0, 0, self.w, self.h, self.bg)
    canvas.bg = self.bg
  end
  self:drawChildren(canvas)
end

function Box:childAt(x, y)
  self:layout()
  return Container.childAt(self, x, y)
end

-- Adding/removing/hiding a child moves its siblings: repaint the box.
function Box:add(child)
  -- in a row, a child with no width of its own takes a share of the room
  if self.dir == "h" and child.w == nil and child.flex == nil then child.flex = 1 end
  Container.add(self, child)
  self:invalidate()
  return child
end

function Box:remove(child)
  local ok = Container.remove(self, child)
  if ok then self:invalidate() end
  return ok
end

function Box:childChanged()
  self:invalidate()
end

local HBox = setmetatable({}, { __index = Box })
HBox.__index = HBox
M.HBox = HBox
function HBox.new(props) return newBox(props, "h", HBox) end

local VBox = setmetatable({}, { __index = Box })
VBox.__index = VBox
M.VBox = VBox
function VBox.new(props) return newBox(props, "v", VBox) end

-- ------------------------------------------------------------------ Split --

local Split = setmetatable({}, { __index = Container })
Split.__index = Split
M.Split = Split

function Split.new(props)
  local self = setmetatable(Container.new(props), Split)
  self.dir = props.dir or "h"
  self.size = props.size
  self.ratio = props.ratio or 0.5
  self.min = props.min or 4
  self.dividerColor = props.dividerColor or theme.border
  self.bg = props.bg
  self.draggable = props.draggable ~= false
  if props.first then self:add(props.first) end
  if props.second then self:add(props.second) end
  return self
end

function Split:extent()
  return self.dir == "h" and (self.w or 0) or (self.h or 0)
end

-- Size of the first pane, kept within [min, extent - min - 1].
function Split:firstSize()
  local extent = self:extent()
  local s = self.size or math.floor((extent - 1) * self.ratio + 0.5)
  local hi = extent - self.min - 1
  if s > hi then s = hi end
  if s < self.min then s = self.min end
  return math.max(math.min(s, extent - 1), 0)
end

function Split:layout()
  local a, b = self.children[1], self.children[2]
  local s = self:firstSize()
  local extent = self:extent()
  if self.dir == "h" then
    if a then a.x, a.y, a.w, a.h = 0, 0, s, self.h end
    if b then b.x, b.y, b.w, b.h = s + 1, 0, math.max(extent - s - 1, 0), self.h end
  else
    if a then a.x, a.y, a.w, a.h = 0, 0, self.w, s end
    if b then b.x, b.y, b.w, b.h = 0, s + 1, self.w, math.max(extent - s - 1, 0) end
  end
  return s
end

function Split:draw(canvas)
  local s = self:layout()
  if self.bg then
    canvas:fillRect(0, 0, self.w, self.h, self.bg)
    canvas.bg = self.bg
  end
  self:drawChildren(canvas)
  local color = self.dragging and theme.accent or self.dividerColor
  if self.dir == "h" then
    canvas:vline(s, 0, self.h, color)
  else
    canvas:hline(0, s, self.w, color)
  end
end

function Split:childAt(x, y)
  self:layout()
  return Container.childAt(self, x, y)
end

function Split:onTouch(x, y, button)
  local s = self:layout()
  if self.draggable and (self.dir == "h" and x == s or self.dir ~= "h" and y == s) then
    self.dragging = true
    self:invalidate()
    return true
  end
  return Container.onTouch(self, x, y, button)
end

-- Moves the divider to the pointer; setting `size` in cells.
function Split:onDrag(x, y)
  if not self.dragging then return false end
  local pos = self.dir == "h" and x or y
  local old = self:firstSize()
  self.size = pos
  if self:firstSize() ~= old then self:invalidate() end
  return true
end

function Split:onDrop()
  if not self.dragging then return false end
  self.dragging = false
  self:invalidate()
  return true
end

return M
