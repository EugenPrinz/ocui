-- ocui.widget
-- Base Widget and Container primitives. Every widget has a position/size in
-- its parent's local coordinate space (x, y, w, h), a draw(canvas) method,
-- and an onTouch(x, y, button) method that returns true if it consumed the
-- event.

local Widget = {}
Widget.__index = Widget

-- `w` may be left nil to mean "fill whatever width the parent container
-- offers" — containers resolve it to a concrete number before drawing or
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
  }, Widget)
end

function Widget:draw(_canvas) end

function Widget:onTouch(_x, _y, _button)
  return false
end

function Widget:contains(x, y)
  return x >= 0 and x < (self.w or 0) and y >= 0 and y < (self.h or 0)
end

local Container = setmetatable({}, { __index = Widget })
Container.__index = Container

function Container.new(props)
  local self = Widget.new(props)
  self.children = {}
  return setmetatable(self, Container)
end

function Container:add(child)
  table.insert(self.children, child)
  return child
end

function Container:clear()
  self.children = {}
end

-- If `child.w` was left nil ("fill parent"), resolve it now against this
-- container's own width. Idempotent: does nothing once child.w is set.
function Container:layoutChild(child, availW)
  if child.w == nil then
    child.w = math.max((availW or self.w or 0) - child.x, 0)
  end
end

function Container:draw(canvas)
  for _, child in ipairs(self.children) do
    if child.visible then
      self:layoutChild(child)
      child:draw(canvas:sub(child.x, child.y, child.w, child.h))
    end
  end
end

-- Dispatches to the topmost (last-added) child whose bounds contain the
-- point, front to back.
function Container:onTouch(x, y, button)
  for i = #self.children, 1, -1 do
    local child = self.children[i]
    if child.visible then
      self:layoutChild(child)
      local lx, ly = x - child.x, y - child.y
      if child:contains(lx, ly) then
        if child:onTouch(lx, ly, button) then
          return true
        end
      end
    end
  end
  return false
end

return { Widget = Widget, Container = Container }
