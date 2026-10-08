-- ocui.widget
-- Base Widget and Container primitives. Every widget has a position/size in
-- its parent's local coordinate space (x, y, w, h) and a draw(canvas)
-- method. Input handlers return true when they consumed the event:
--
--   onTouch(x, y, button)   click/tap (local coordinates; button 0 = left)
--   onDrag(x, y, button)    pointer moved while held, after an onTouch this
--   onDrop(x, y, button)    widget consumed (the host captures the pointer)
--   onScroll(x, y, dir)     mouse wheel (dir > 0 = up)
--   onKey(ev)               key press while focused (see ocui.keys); keys a
--                           focused widget doesn't consume bubble up to its
--                           parents
--   onPaste(text)           clipboard paste while focused
--
-- A widget with `focusable = true` takes keyboard focus when touched or
-- tabbed to; onFocus()/onBlur() repaint it by default (via focusChanged(),
-- which a widget can narrow to the part that looks different).
--
-- Widgets in a tree that is shown by an ocui.host redraw *partially*: after
-- changing what a widget shows, call self:invalidate() (or
-- invalidate(x, y, w, h) for a part of it) and the host repaints just that
-- area on its next frame. Outside a host, invalidate() does nothing.

local Widget = {}
Widget.__index = Widget

-- `w` may be left nil to mean "fill whatever width the parent container
-- offers" -- containers resolve it to a concrete number before drawing or
-- hit-testing a child (see Container:layoutChild). `h` has no such
-- auto-fill convention and defaults to 1.
function Widget.new(props)
  props = props or {}
  return setmetatable({
    x = props.x or 0,
    y = props.y or 0,
    w = props.w,
    h = props.h or 1,
    visible = props.visible ~= false,
    focusable = props.focusable,
    flex = props.flex, -- share of free space in an HBox/VBox
  }, Widget)
end

function Widget:draw(_canvas) end

function Widget:onTouch(_x, _y, _button) return false end
function Widget:onDrag() return false end
function Widget:onDrop() return false end
function Widget:onScroll() return false end
function Widget:onKey(_ev) return false end
function Widget:onPaste(_text) return false end

function Widget:onFocus() self:focusChanged() end
function Widget:onBlur() self:focusChanged() end

-- Repaints what looks different with/without focus (default: all of it).
function Widget:focusChanged() self:invalidate() end

function Widget:contains(x, y)
  return x >= 0 and x < (self.w or 0) and y >= 0 and y < (self.h or 0)
end

-- The ocui.host showing this widget's tree, or nil.
function Widget:getHost()
  local w = self
  while w.parent do w = w.parent end
  return w.host
end

-- Position of the widget's top-left cell in screen space (0-based).
function Widget:absPos()
  local x, y = self.x, self.y
  local p = self.parent
  while p do
    local ox, oy = p:childOffset()
    x, y = x + p.x + ox, y + p.y + oy
    p = p.parent
  end
  return x, y
end

-- True if this widget and all its ancestors are visible.
function Widget:isShown()
  local w = self
  while w do
    if not w.visible then return false end
    w = w.parent
  end
  return true
end

-- Marks (part of) the widget for repainting. Rect in local coordinates;
-- default: the whole widget.
function Widget:invalidate(x, y, w, h)
  local host = self:getHost()
  if not host or not self:isShown() then return end
  local ax, ay = self:absPos()
  host:damage(ax + (x or 0), ay + (y or 0), w or self.w or 0, h or self.h or 0)
end

function Widget:setVisible(visible)
  visible = visible and true or false
  if visible == self.visible then return end
  if not visible then self:invalidate() end -- the area it covered
  self.visible = visible
  if visible then self:invalidate() end
  if self.parent and self.parent.childChanged then self.parent:childChanged(self) end
end

-- Moves keyboard focus here (if shown by a host).
function Widget:focus()
  local host = self:getHost()
  if host then host:focus(self) end
end

function Widget:isFocused()
  local host = self:getHost()
  return host ~= nil and host.focused == self
end

-- Focused *and* the user is driving the UI with the keyboard: the cue for
-- buttons and the like to draw a focus highlight (a touch-driven UI stays
-- unmarked, like :focus-visible on the web).
function Widget:showsFocus()
  local host = self:getHost()
  return host ~= nil and host.focused == self and host.focusVisible
end

-- ------------------------------------------------------------- Container --

local Container = setmetatable({}, { __index = Widget })
Container.__index = Container

function Container.new(props)
  local self = Widget.new(props)
  self.children = {}
  return setmetatable(self, Container)
end

function Container:add(child)
  table.insert(self.children, child)
  child.parent = self
  if child.visible then child:invalidate() end
  return child
end

function Container:remove(child)
  for i, c in ipairs(self.children) do
    if c == child then
      child:invalidate()
      local host = child:getHost()
      if host then host:forget(child) end
      table.remove(self.children, i)
      child.parent = nil
      return true
    end
  end
  return false
end

function Container:clear()
  local host = self:getHost()
  for _, c in ipairs(self.children) do
    if host then host:forget(c) end
    c.parent = nil
  end
  self.children = {}
  self:invalidate()
end

-- Where the children's (0, 0) sits inside this container (a Panel's
-- border makes it 1, 1) and how much room they get.
function Container:childOffset() return 0, 0 end
function Container:clientSize() return self.w or 0, self.h or 0 end

-- If `child.w` was left nil ("fill parent"), resolve it now against this
-- container's own width. Idempotent: does nothing once child.w is set.
function Container:layoutChild(child, availW)
  if child.w == nil then
    local cw = self:clientSize()
    child.w = math.max((availW or cw) - child.x, 0)
  end
end

-- Draws the children into `canvas` (this container's own surface),
-- skipping those outside the area being repainted.
function Container:drawChildren(canvas)
  local ox, oy = self:childOffset()
  local cw, ch = self:clientSize()
  if cw <= 0 or ch <= 0 then return end
  local inner = (ox ~= 0 or oy ~= 0 or cw ~= self.w or ch ~= self.h)
    and canvas:sub(ox, oy, cw, ch) or canvas
  for _, child in ipairs(self.children) do
    if child.visible then
      self:layoutChild(child, cw)
      if inner:intersects(child.x, child.y, child.w, child.h) then
        child:draw(inner:sub(child.x, child.y, child.w, child.h))
      end
    end
  end
end

function Container:draw(canvas)
  self:drawChildren(canvas)
end

-- Topmost (last-added) visible child under the local point, plus the
-- point in that child's coordinates.
function Container:childAt(x, y)
  local ox, oy = self:childOffset()
  local cw, ch = self:clientSize()
  local lx, ly = x - ox, y - oy
  if lx < 0 or ly < 0 or lx >= cw or ly >= ch then return nil end
  for i = #self.children, 1, -1 do
    local child = self.children[i]
    if child.visible then
      self:layoutChild(child, cw)
      local cx, cy = lx - child.x, ly - child.y
      if child:contains(cx, cy) then return child, cx, cy end
    end
  end
  return nil
end

-- Remembers the deepest widget that consumed a pointer event, so the host
-- can focus it and route the following drags to it.
local function noteTarget(self, child)
  local host = self:getHost()
  if host and host.touchTarget == nil then host.touchTarget = child end
end

-- Dispatches to the topmost child under the point.
function Container:onTouch(x, y, button)
  local child, cx, cy = self:childAt(x, y)
  if child and child:onTouch(cx, cy, button) then
    noteTarget(self, child)
    return true
  end
  return false
end

function Container:onScroll(x, y, dir)
  local child, cx, cy = self:childAt(x, y)
  if child and child:onScroll(cx, cy, dir) then return true end
  return false
end

return { Widget = Widget, Container = Container }
