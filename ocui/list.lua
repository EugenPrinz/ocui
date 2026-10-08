-- ocui.list
-- Scrollable, selectable list with optional columns and header.
--
--   List.new({
--     items = { ... },              -- strings, or tables
--     text = function(item) end,   -- row text without columns (default:
--                                  -- item.text / item.label / tostring)
--     columns = {                  -- optional; then rows are tables
--       { title = "Name", key = "name", flex = 1 },
--       { title = "Size", width = 8, align = "right",
--         get = function(item) return fmt.bytes(item.size) end },
--     },
--     header = true,               -- column titles row (default with columns)
--     color = function(item) end,  -- optional per-row text color
--     onSelect = function(index, item) end,    -- selection moved
--     onActivate = function(index, item) end,  -- Enter / double click
--     onContext = function(index, item, x, y) end, -- right click (screen x/y)
--   })
--
-- Keys (when focused): Up/Down, PageUp/PageDown, Home/End, Enter; typing a
-- letter jumps to the next row starting with it. The wheel scrolls; the
-- scrollbar on the right can be clicked or dragged.

local base = require("ocui.widget")
local theme = require("ocui.theme")
local util = require("ocui.util")
local Widget = base.Widget

local computer = require("computer")

local List = setmetatable({}, { __index = Widget })
List.__index = List

List.DOUBLE_CLICK = 0.5 -- seconds

function List.new(props)
  props = props or {}
  local self = setmetatable(Widget.new(props), List)
  self.items = props.items or {}
  self.textOf = props.text
  self.columns = props.columns
  self.header = props.header
  if self.header == nil then self.header = props.columns ~= nil end
  self.colorOf = props.color
  self.onSelect = props.onSelect
  self.onActivate = props.onActivate
  self.onContext = props.onContext
  self.selected = (#self.items > 0) and (props.selected or 1) or 0
  self.top = 1
  self.fg = props.fg or theme.text
  self.bg = props.bg or theme.panel
  self.headerFg = props.headerFg or theme.textDim
  self.headerBg = props.headerBg or theme.header
  self.empty = props.empty or ""
  if self.focusable == nil then self.focusable = true end
  return self
end

-- ---------------------------------------------------------------- geometry --

function List:headerRows() return self.header and 1 or 0 end

function List:visibleRows()
  return math.max(self.h - self:headerRows(), 0)
end

function List:hasScrollbar()
  return #self.items > self:visibleRows()
end

function List:rowWidth()
  return self.w - (self:hasScrollbar() and 1 or 0)
end

-- Screen-independent: local y of item `index`, or nil if scrolled away.
function List:rowY(index)
  local r = index - self.top
  if r < 0 or r >= self:visibleRows() then return nil end
  return r + self:headerRows()
end

function List:invalidateRow(index)
  local y = self:rowY(index)
  if y then self:invalidate(0, y, self.w, 1) end
end

-- Focus only changes the selected row's color.
function List:focusChanged() self:invalidateRow(self.selected) end

-- Column widths for the current row width: fixed widths first, the rest
-- shared by flex weight; one space between columns.
function List:columnWidths()
  local cols = self.columns
  local total = self:rowWidth() - 1 -- one cell left margin
  local fixed, flexTotal = 0, 0
  for _, c in ipairs(cols) do
    if c.width then fixed = fixed + c.width else flexTotal = flexTotal + (c.flex or 1) end
  end
  local free = math.max(total - fixed - (#cols - 1), 0)
  local widths, given, seen = {}, 0, 0
  for i, c in ipairs(cols) do
    if c.width then
      widths[i] = c.width
    else
      seen = seen + (c.flex or 1)
      local upTo = math.floor(free * seen / flexTotal + 0.5)
      widths[i] = upTo - given
      given = upTo
    end
  end
  return widths
end

-- ------------------------------------------------------------------ items --

function List:itemText(item)
  if self.textOf then return tostring(self.textOf(item)) end
  if type(item) == "table" then return tostring(item.text or item.label or item.name or "") end
  return tostring(item)
end

local function cellText(column, item)
  local v
  if column.get then v = column.get(item) else v = item[column.key] end
  if v == nil then return "" end
  return tostring(v)
end

-- Replaces the items. keepSelection: try to keep the same item selected
-- (compared with ==, or by `key` field if given), else the same index.
function List:setItems(items, keepSelection)
  local old = self.items[self.selected]
  self.items = items or {}
  local index = math.min(math.max(self.selected, 1), #self.items)
  if keepSelection and old ~= nil then
    for i, item in ipairs(self.items) do
      if item == old or (type(keepSelection) == "string" and type(item) == "table"
          and type(old) == "table" and item[keepSelection] == old[keepSelection]) then
        index = i
        break
      end
    end
  end
  self.selected = #self.items > 0 and index or 0
  self:clampTop()
  self:invalidate()
end

function List:selectedItem()
  return self.items[self.selected]
end

function List:clampTop()
  local rows = self:visibleRows()
  local maxTop = math.max(#self.items - rows + 1, 1)
  if self.selected > 0 and rows > 0 then
    if self.selected < self.top then self.top = self.selected end
    if self.selected >= self.top + rows then self.top = self.selected - rows + 1 end
  end
  if self.top > maxTop then self.top = maxTop end
  if self.top < 1 then self.top = 1 end
end

-- Selects item `index` (clamped), scrolling it into view.
function List:select(index, quiet)
  if #self.items == 0 then return end
  index = math.max(1, math.min(index, #self.items))
  if index == self.selected then return end
  local oldSel, oldTop = self.selected, self.top
  self.selected = index
  self:clampTop()
  if self.top ~= oldTop then
    self:invalidate()
  else
    self:invalidateRow(oldSel)
    self:invalidateRow(index)
  end
  if self.onSelect and not quiet then self.onSelect(index, self.items[index]) end
end

-- Scrolls by `delta` rows without moving the selection.
function List:scrollBy(delta)
  local old = self.top
  self.top = self.top + delta
  local maxTop = math.max(#self.items - self:visibleRows() + 1, 1)
  if self.top > maxTop then self.top = maxTop end
  if self.top < 1 then self.top = 1 end
  if self.top ~= old then self:invalidate() end
end

function List:activate()
  local item = self.items[self.selected]
  if item ~= nil and self.onActivate then self.onActivate(self.selected, item) end
end

-- ------------------------------------------------------------------- draw --

function List:drawRow(canvas, y, item, selected, rowW)
  local focused = self:isFocused()
  local bg = self.bg
  local fg = (self.colorOf and self.colorOf(item)) or self.fg
  if selected then bg = focused and theme.selection or theme.selectionDim end
  canvas:fillRect(0, y, rowW, 1, bg)
  if self.columns then
    local x = 1
    for i, w in ipairs(self:columnWidths()) do
      local col = self.columns[i]
      if w > 0 then
        local text = util.pad(util.ellipsis(cellText(col, item), w), w, col.align)
        canvas:text(x, y, text, col.color and col.color(item) or fg, bg)
      end
      x = x + w + 1
    end
  else
    canvas:text(1, y, util.ellipsis(self:itemText(item), rowW - 2), fg, bg)
  end
end

function List:draw(canvas)
  local rowW = self:rowWidth()
  local hy = self:headerRows()
  if self.header then
    canvas:fillRect(0, 0, self.w, 1, self.headerBg)
    if self.columns then
      local x = 1
      for i, w in ipairs(self:columnWidths()) do
        local col = self.columns[i]
        if w > 0 then
          canvas:text(x, 0, util.pad(util.ellipsis(col.title or "", w), w, col.align), self.headerFg, self.headerBg)
        end
        x = x + w + 1
      end
    end
  end
  local rows = self:visibleRows()
  for r = 0, rows - 1 do
    local index = self.top + r
    local item = self.items[index]
    local y = hy + r
    if canvas:intersects(0, y, self.w, 1) then
      if item ~= nil then
        self:drawRow(canvas, y, item, index == self.selected, rowW)
      else
        canvas:fillRect(0, y, rowW, 1, self.bg)
        if index == 1 and self.empty ~= "" then
          canvas:text(1, y, util.ellipsis(self.empty, rowW - 2), theme.textDim, self.bg)
        end
      end
    end
  end
  if self:hasScrollbar() and rows > 0 then
    -- thumb size/position proportional to the visible share
    local n = #self.items
    local thumb = math.max(math.floor(rows * rows / n + 0.5), 1)
    local pos = math.floor((self.top - 1) * (rows - thumb) / math.max(n - rows, 1) + 0.5)
    canvas:fillRect(self.w - 1, hy, 1, rows, theme.barBg)
    canvas:fillRect(self.w - 1, hy + pos, 1, thumb, theme.textDim)
  end
end

-- ------------------------------------------------------------------ input --

function List:scrollTo(y)
  local rows = self:visibleRows()
  local n = #self.items
  if n <= rows then return end
  local r = math.max(math.min(y - self:headerRows(), rows - 1), 0)
  local top = math.floor(r * (n - rows) / math.max(rows - 1, 1) + 0.5) + 1
  self:scrollBy(top - self.top)
end

function List:onTouch(x, y, button)
  if self:hasScrollbar() and x == self.w - 1 and y >= self:headerRows() then
    self.draggingBar = true
    self:scrollTo(y)
    return true
  end
  local r = y - self:headerRows()
  if r < 0 then return true end
  local index = self.top + r
  if index > #self.items then return true end
  local now = computer.uptime()
  local double = button ~= 1 and self.lastClick and self.lastClick.index == index
    and now - self.lastClick.at <= List.DOUBLE_CLICK
  self:select(index)
  if button == 1 then
    self.lastClick = nil
    if self.onContext then
      local ax, ay = self:absPos()
      self.onContext(index, self.items[index], ax + x, ay + y)
    end
  elseif double then
    self.lastClick = nil
    self:activate()
  else
    self.lastClick = { index = index, at = now }
  end
  return true
end

function List:onDrag(_, y)
  if self.draggingBar then self:scrollTo(y) end
  return true
end

function List:onDrop()
  self.draggingBar = false
  return true
end

function List:onScroll(_, _, dir)
  self:scrollBy(dir > 0 and -3 or 3)
  return true
end

-- Next item (after the selection, wrapping) whose text starts with `ch`.
function List:jumpTo(ch)
  ch = ch:lower()
  local n = #self.items
  for step = 1, n do
    local i = (self.selected - 1 + step) % n + 1
    local item = self.items[i]
    local text = self.columns and cellText(self.columns[1], item) or self:itemText(item)
    if text:sub(1, #ch):lower() == ch then
      self:select(i)
      return true
    end
  end
  return false
end

function List:onKey(ev)
  local rows = math.max(self:visibleRows(), 1)
  local name = ev.name
  if name == "up" then self:select(self.selected - 1)
  elseif name == "down" then self:select(self.selected + 1)
  elseif name == "pageUp" then self:select(self.selected - rows)
  elseif name == "pageDown" then self:select(self.selected + rows)
  elseif name == "home" then self:select(1)
  elseif name == "end" then self:select(#self.items)
  elseif name == "enter" then self:activate()
  elseif ev.text and ev.text ~= " " and not ev.alt then return self:jumpTo(ev.text)
  else return false end
  return true
end

return List
