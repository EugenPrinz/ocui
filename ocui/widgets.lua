-- ocui.widgets
-- Concrete UI primitives built on top of ocui.widget.

local base = require("ocui.widget")
local theme = require("ocui.theme")
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
  self.fg = props.fg or 0xFFFFFF
  self.bg = props.bg -- nil: transparent over the parent surface
  self.align = props.align or "left" -- left | center | right
  return setmetatable(self, Label)
end

function Label:setText(text)
  if text == self.text then return end
  self.text = text
  self:invalidate()
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

-- props.label: text shown centered as "<label> <NN%>"; props.text, if
-- given, replaces that whole caption verbatim. props.textColor defaults
-- to white.
function ProgressBar.new(props)
  local self = setmetatable(Widget.new(props), ProgressBar)
  self.value = 0
  self.bg = props.bg or 0x232330
  self.fg = props.fg or 0x4C8BF5
  self.textColor = props.textColor or 0xFFFFFF
  self.label = props.label
  self.text = props.text
  self:setValue(props.value or 0)
  return self
end

function ProgressBar:setValue(v)
  if v ~= v then v = 0 end -- NaN
  if v < 0 then v = 0 elseif v > 1 then v = 1 end
  if v == self.value then return end
  self.value = v
  self:invalidate()
end

function ProgressBar:caption()
  if self.text then return self.text end
  if not self.label then return nil end
  return string.format("%s %d%%", self.label, math.floor(self.value * 100 + 0.5))
end

function ProgressBar:draw(canvas)
  canvas:fillRect(0, 0, self.w, self.h, self.bg)
  local filled = math.floor(self.w * self.value + 0.5)
  if filled > 0 then
    canvas:fillRect(0, 0, filled, self.h, self.fg)
  end
  local text = self:caption()
  if not text then return end
  if util.len(text) > self.w then text = util.truncate(text, self.w) end
  local chars = util.chars(text)
  local tx = math.max(math.floor((self.w - #chars) / 2), 0)
  local ty = math.floor((self.h - 1) / 2)
  -- The caption straddles the fill edge: draw the part over the filled
  -- portion and the part over the empty track with their own backgrounds.
  local split = math.max(math.min(filled - tx, #chars), 0)
  if split > 0 then
    canvas:text(tx, ty, table.concat(chars, "", 1, split), self.textColor, self.fg)
  end
  if split < #chars then
    canvas:text(tx + split, ty, table.concat(chars, "", split + 1), self.textColor, self.bg)
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
  self.borderColor = props.borderColor or 0x33333D
  self.bg = props.bg
  return setmetatable(self, Panel)
end

function Panel:innerSize()
  return math.max(self.w - 2, 0), math.max(self.h - 2, 0)
end

function Panel:childOffset() return 1, 1 end
function Panel:clientSize() return self:innerSize() end

function Panel:draw(canvas)
  if self.bg then
    canvas:fillRect(0, 0, self.w, self.h, self.bg)
    canvas.bg = self.bg -- border, title and children sit on this surface
  end
  canvas:border(0, 0, self.w, self.h, self.borderColor, self.title)
  self:drawChildren(canvas)
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

-- ---------------------------------------------------------------- Button --

-- props: text, onClick(button), fg, bg, disabled. Width defaults to the
-- text plus one cell of padding on each side.
local Button = setmetatable({}, { __index = Widget })
Button.__index = Button
M.Button = Button

function Button.new(props)
  local self = setmetatable(Widget.new(props), Button)
  self.text = props.text or ""
  self.onClick = props.onClick
  self.fg = props.fg or 0xFFFFFF
  self.bg = props.bg or 0x33333D
  self.disabled = props.disabled
  if self.focusable == nil then self.focusable = true end
  if self.w == nil then self.w = util.len(self.text) + 2 end
  return self
end

function Button:draw(canvas)
  local fg = self.disabled and theme.disabled or self.fg
  local bg = self:showsFocus() and theme.buttonFocus or self.bg
  canvas:fillRect(0, 0, self.w, self.h, bg)
  local text = util.truncate(self.text, self.w)
  local tx = math.max(math.floor((self.w - util.len(text)) / 2), 0)
  canvas:text(tx, math.floor((self.h - 1) / 2), text, fg, bg)
end

function Button:setText(text)
  if text == self.text then return end
  self.text = text
  self:invalidate()
end

function Button:press()
  if self.disabled then return end
  if self.onClick then self.onClick(self) end
end

function Button:onTouch()
  self:press()
  return true
end

function Button:onKey(ev)
  if ev.name == "enter" or ev.name == "space" then
    self:press()
    return true
  end
  return false
end

-- ---------------------------------------------------------------- Toggle --

-- "[x] label" checkbox. props: label, value, onChange(value), fg, onColor.
local Toggle = setmetatable({}, { __index = Widget })
Toggle.__index = Toggle
M.Toggle = Toggle

function Toggle.new(props)
  local self = setmetatable(Widget.new(props), Toggle)
  self.label = props.label or ""
  self.value = props.value and true or false
  self.onChange = props.onChange
  self.fg = props.fg or 0xE4E4E8
  self.onColor = props.onColor or 0x4CD787
  self.disabled = props.disabled
  if self.focusable == nil then self.focusable = true end
  return self
end

function Toggle:draw(canvas)
  local box = self.value and "[x]" or "[ ]"
  local boxColor = self.disabled and theme.disabled or (self.value and self.onColor or self.fg)
  canvas:text(0, 0, box, boxColor, self:showsFocus() and theme.buttonFocus or nil)
  canvas:text(4, 0, self.label, self.disabled and theme.disabled or self.fg)
end

function Toggle:setValue(value)
  value = value and true or false
  if value == self.value then return end
  self.value = value
  self:invalidate()
end

function Toggle:toggle()
  if self.disabled then return end
  self:setValue(not self.value)
  if self.onChange then self.onChange(self.value) end
end

function Toggle:onTouch()
  self:toggle()
  return true
end

function Toggle:onKey(ev)
  if ev.name == "space" or ev.name == "enter" then
    self:toggle()
    return true
  end
  return false
end

-- ----------------------------------------------------------------- Cycle --

-- "label: < value >" -- click the right part (or anywhere) for the next
-- option, the "<" for the previous one.
-- props: label, options (array), value, onChange(value), format(value).
local Cycle = setmetatable({}, { __index = Widget })
Cycle.__index = Cycle
M.Cycle = Cycle

function Cycle.new(props)
  local self = setmetatable(Widget.new(props), Cycle)
  self.label = props.label or ""
  self.options = props.options or {}
  self.value = props.value
  self.onChange = props.onChange
  self.format = props.format or tostring
  self.fg = props.fg or 0xE4E4E8
  self.valueColor = props.valueColor or 0x4C8BF5
  self.disabled = props.disabled
  if self.focusable == nil then self.focusable = true end
  return self
end

function Cycle:prefix()
  return self.label ~= "" and (self.label .. ": ") or ""
end

function Cycle:draw(canvas)
  local prefix = self:prefix()
  local dim = theme.disabled
  canvas:text(0, 0, prefix, self.disabled and dim or self.fg)
  local x = util.len(prefix)
  canvas:text(x, 0, "< " .. self.format(self.value) .. " >", self.disabled and dim or self.valueColor,
    self:showsFocus() and theme.selection or nil)
end

function Cycle:step(delta)
  local n = #self.options
  if n == 0 then return end
  local index = 1
  for i, v in ipairs(self.options) do
    if v == self.value then index = i end
  end
  index = (index - 1 + delta) % n + 1
  self.value = self.options[index]
  self:invalidate()
  if self.onChange then self.onChange(self.value) end
end

function Cycle:onTouch(x)
  if self.disabled then return true end
  local left = util.len(self:prefix())
  self:step(x <= left + 1 and -1 or 1)
  return true
end

function Cycle:onKey(ev)
  if self.disabled then return false end
  if ev.name == "left" then self:step(-1); return true end
  if ev.name == "right" or ev.name == "space" or ev.name == "enter" then self:step(1); return true end
  return false
end

-- --------------------------------------------------------------- Stepper --

-- "label: [-10][-] value [+][+10]" numeric field.
-- props: label, labelWidth, value, steps (default {-10, -1, 1, 10}),
--        min, max, onChange(value), format(value), disabled.
local Stepper = setmetatable({}, { __index = Widget })
Stepper.__index = Stepper
M.Stepper = Stepper

function Stepper.new(props)
  local self = setmetatable(Widget.new(props), Stepper)
  self.label = props.label or ""
  self.labelWidth = props.labelWidth or (util.len(self.label) + 2)
  self.value = props.value or 0
  self.steps = props.steps or { -10, -1, 1, 10 }
  self.min, self.max = props.min, props.max
  self.onChange = props.onChange
  self.format = props.format or function(v) return string.format("%d", v) end
  self.fg = props.fg or 0xE4E4E8
  self.buttonBg = props.buttonBg or 0x33333D
  self.disabled = props.disabled
  if self.focusable == nil then self.focusable = true end
  self.hits = {}
  return self
end

local function stepText(delta)
  if delta == -1 then return "-" end
  if delta == 1 then return "+" end
  return (delta > 0 and "+" or "") .. tostring(delta)
end

function Stepper:draw(canvas)
  local dim = theme.disabled
  local fg = self.disabled and dim or self.fg
  canvas:text(0, 0, self.label .. ":", fg, self:showsFocus() and theme.selection or nil)
  local x = self.labelWidth
  self.hits = {}
  local valueDrawn = false
  for _, delta in ipairs(self.steps) do
    if delta > 0 and not valueDrawn then
      local v = " " .. self.format(self.value) .. " "
      canvas:text(x, 0, v, fg)
      x = x + util.len(v)
      valueDrawn = true
    end
    local t = "[" .. stepText(delta) .. "]"
    canvas:text(x, 0, t, fg, self.buttonBg)
    table.insert(self.hits, { x0 = x, x1 = x + util.len(t) - 1, delta = delta })
    x = x + util.len(t)
  end
  if not valueDrawn then
    canvas:text(x, 0, " " .. self.format(self.value), fg)
  end
end

function Stepper:change(delta)
  local v = self.value + delta
  if self.min and v < self.min then v = self.min end
  if self.max and v > self.max then v = self.max end
  if v ~= self.value then
    self.value = v
    self:invalidate()
    if self.onChange then self.onChange(v) end
  end
end

function Stepper:onTouch(x)
  if self.disabled then return true end
  for _, hit in ipairs(self.hits) do
    if x >= hit.x0 and x <= hit.x1 then
      self:change(hit.delta)
      return true
    end
  end
  return true
end

-- Left/Right: the smallest step; PageUp/PageDown: the largest.
function Stepper:onKey(ev)
  if self.disabled then return false end
  local small, big = math.huge, 0
  for _, d in ipairs(self.steps) do
    local a = math.abs(d)
    if a < small then small = a end
    if a > big then big = a end
  end
  if small == math.huge then return false end
  local delta = ({ left = -small, right = small, down = -small, up = small,
    pageDown = -big, pageUp = big })[ev.name or ""]
  if not delta then return false end
  self:change(delta)
  return true
end

-- ------------------------------------------------------------------ Tabs --

-- A row of tab headers. props: tabs (array of names), active (index),
-- onSelect(index), fg, activeFg, activeBg, bg.
local Tabs = setmetatable({}, { __index = Widget })
Tabs.__index = Tabs
M.Tabs = Tabs

function Tabs.new(props)
  local self = setmetatable(Widget.new(props), Tabs)
  self.tabs = props.tabs or {}
  self.active = props.active or 1
  self.onSelect = props.onSelect
  self.fg = props.fg or 0x8A8A96
  self.bg = props.bg or 0x16161D
  self.activeFg = props.activeFg or 0xFFFFFF
  self.activeBg = props.activeBg or 0x4C8BF5
  self.hits = {}
  return self
end

function Tabs:draw(canvas)
  canvas:fillRect(0, 0, self.w, self.h, self.bg)
  local x = 0
  self.hits = {}
  for i, name in ipairs(self.tabs) do
    local t = " " .. name .. " "
    local active = i == self.active
    canvas:text(x, 0, t, active and self.activeFg or self.fg, active and self.activeBg or self.bg)
    table.insert(self.hits, { x0 = x, x1 = x + util.len(t) - 1, index = i })
    x = x + util.len(t) + 1
  end
end

function Tabs:onTouch(x)
  for _, hit in ipairs(self.hits) do
    if x >= hit.x0 and x <= hit.x1 then
      if hit.index ~= self.active then
        self.active = hit.index
        self:invalidate()
        if self.onSelect then self.onSelect(hit.index) end
      end
      return true
    end
  end
  return false
end

-- ----------------------------------------------------------------- Chart --

-- Column chart with half-block resolution (2 data rows per text row),
-- drawn with one vertical GPU call per column.
-- props:
--   values      array, oldest first (nil = gap); resampled to the width
--   mode        "diverging" (pos up / neg down from a zero line, default)
--               or "area" (min..max, filled from the bottom)
--   min, max    area mode: values at the bottom/top (default 0 / largest)
--   posColor, negColor, bg, labelColor
--   format      fn(number) -> label text (right-hand label column)
--   labelWidth  width of the label column (0 to hide labels; default 7)
local Chart = setmetatable({}, { __index = Widget })
Chart.__index = Chart
M.Chart = Chart

function Chart.new(props)
  local self = setmetatable(Widget.new(props), Chart)
  self.values = props.values or {}
  self.mode = props.mode or "diverging"
  self.min = props.min
  self.max = props.max
  self.posColor = props.posColor or 0x4CD787
  self.negColor = props.negColor or 0xE0574C
  self.bg = props.bg or 0x16161D
  self.labelColor = props.labelColor or 0x8A8A96
  self.format = props.format or function(v) return string.format("%.0f", v) end
  self.labelWidth = props.labelWidth or 7
  return self
end

function Chart:setValues(values)
  self.values = values or {}
  self:invalidate()
end

-- Averages `values` down to `n` columns (or right-aligns fewer).
local function resample(values, n)
  local count = #values
  local out = {}
  if count <= n then
    local offset = n - count
    for i = 1, count do out[offset + i] = values[i] end
    return out
  end
  for i = 1, n do
    local from = math.floor((i - 1) * count / n) + 1
    local to = math.floor(i * count / n)
    local sum, k = 0, 0
    for j = from, to do
      if values[j] then sum = sum + values[j]; k = k + 1 end
    end
    if k > 0 then out[i] = sum / k end
  end
  return out
end

local HALF = {
  [3] = "\226\150\136", -- █ both halves
  [1] = "\226\150\128", -- ▀ top half
  [2] = "\226\150\132", -- ▄ bottom half
  [0] = " ",
}

-- Column string for sub-rows [top, bottom] filled (0-based, inclusive),
-- trimmed to the cells actually touched. Returns firstRow, string.
local function columnString(top, bottom)
  local firstRow = math.floor(top / 2)
  local lastRow = math.floor(bottom / 2)
  local parts = {}
  for r = firstRow, lastRow do
    local mask = 0
    if 2 * r >= top and 2 * r <= bottom then mask = mask + 1 end
    if 2 * r + 1 >= top and 2 * r + 1 <= bottom then mask = mask + 2 end
    parts[#parts + 1] = HALF[mask]
  end
  return firstRow, table.concat(parts)
end

function Chart:draw(canvas)
  local lw = self.labelWidth
  local cw = self.w - (lw > 0 and (lw + 1) or 0)
  local rows = self.h
  if cw <= 0 or rows <= 0 then return end
  canvas:fillRect(0, 0, cw, rows, self.bg)
  local sub = rows * 2
  local cols = resample(self.values, cw)

  local maxPos, maxNeg = 0, 0
  for i = 1, cw do
    local v = cols[i]
    if v then
      if v > maxPos then maxPos = v end
      if -v > maxNeg then maxNeg = -v end
    end
  end

  local zero, scale
  local base = 0
  if self.mode == "area" then
    -- shift values so the bottom of the chart is `min`
    base = self.min or 0
    local top = (self.max or maxPos) - base
    for i = 1, cw do
      if cols[i] then cols[i] = math.max(cols[i] - base, 0) end
    end
    zero = sub
    scale = top > 0 and (sub / top) or 0
    maxNeg = 0
  else
    local span = maxPos + maxNeg
    zero = span > 0 and math.floor(sub * maxPos / span + 0.5) or sub
    scale = span > 0 and (sub / span) or 0
  end

  for i = 1, cw do
    local v = cols[i]
    if v and v ~= 0 and scale > 0 then
      local len = math.max(math.floor(math.abs(v) * scale + 0.5), 1)
      local top, bottom, color
      if v > 0 then
        top, bottom, color = math.max(zero - len, 0), zero - 1, self.posColor
      else
        top, bottom, color = zero, math.min(zero + len - 1, sub - 1), self.negColor
      end
      if bottom >= top then
        local row, str = columnString(top, bottom)
        canvas:vtext(i - 1, row, str, color, self.bg)
      end
    end
  end

  if lw > 0 then
    local lx = cw + 1
    if self.mode == "area" then
      canvas:text(lx, 0, self.format(self.max or maxPos), self.labelColor)
      canvas:text(lx, rows - 1, self.format(base), self.labelColor)
    else
      if maxPos > 0 then canvas:text(lx, 0, "+" .. self.format(maxPos), self.labelColor) end
      if maxNeg > 0 then canvas:text(lx, rows - 1, "-" .. self.format(maxNeg), self.labelColor) end
      local zeroRow = math.min(math.floor(zero / 2), rows - 1)
      if (maxPos > 0 and maxNeg > 0) and zeroRow > 0 and zeroRow < rows - 1 then
        canvas:text(lx, zeroRow, "0", self.labelColor)
      end
    end
  end
end

-- ------------------------------------------------------------- StatusBar --

-- One row: nano-style key hints ("^S Save  ^Q Quit"), then a message, and
-- text on the right.
-- props: text, right, hints = { {key = "^S", label = "Save"}, ... },
--        fg, bg, keyColor.
local StatusBar = setmetatable({}, { __index = Widget })
StatusBar.__index = StatusBar
M.StatusBar = StatusBar

function StatusBar.new(props)
  local self = setmetatable(Widget.new(props), StatusBar)
  self.text = props.text or ""
  self.right = props.right or ""
  self.hints = props.hints or {}
  self.fg = props.fg or theme.text
  self.bg = props.bg or theme.status
  self.keyColor = props.keyColor or theme.statusKey
  self.textColor = props.textColor
  return self
end

-- setText(text[, color]): the message; nil color = the default.
function StatusBar:setText(text, color)
  text = text or ""
  if text == self.text and color == self.textColor then return end
  self.text, self.textColor = text, color
  self:invalidate()
end

function StatusBar:setRight(text)
  text = text or ""
  if text == self.right then return end
  self.right = text
  self:invalidate()
end

function StatusBar:setHints(hints)
  self.hints = hints or {}
  self:invalidate()
end

function StatusBar:draw(canvas)
  canvas:fillRect(0, 0, self.w, self.h, self.bg)
  canvas.bg = self.bg
  local x = 1
  for _, hint in ipairs(self.hints) do
    canvas:text(x, 0, hint.key, self.bg, self.keyColor)
    x = x + util.len(hint.key)
    local label = " " .. (hint.label or "")
    canvas:text(x, 0, label, self.fg)
    x = x + util.len(label) + 2
  end
  local rw = util.len(self.right)
  if rw > 0 then canvas:text(math.max(self.w - rw - 1, x), 0, self.right, self.fg) end
  if self.text ~= "" then
    local room = self.w - x - (rw > 0 and rw + 2 or 1)
    if room > 0 then canvas:text(x, 0, util.ellipsis(self.text, room), self.textColor or self.fg) end
  end
end

-- The interactive widgets live in their own modules; they are re-exported
-- here so `require("ocui.widgets")` gives the whole set.
M.List = require("ocui.list")
M.TextInput = require("ocui.textinput")
local layout = require("ocui.layout")
M.HBox, M.VBox, M.Split = layout.HBox, layout.VBox, layout.Split

return M
