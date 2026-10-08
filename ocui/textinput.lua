-- ocui.textinput
-- Single-line text field.
--
--   TextInput.new({
--     value = "", placeholder = "name",
--     mask = "*",                     -- show every character as this
--     maxLength = 32,                 -- characters
--     filter = function(ch) end,      -- false rejects a typed character
--     onChange = function(value) end,
--     onSubmit = function(value) end, -- Enter
--     onCancel = function() end,      -- Escape (not consumed without it)
--   })
--
-- Keys: Left/Right, Home/End, Ctrl+Left/Right (by word), Backspace,
-- Delete, Ctrl+Backspace (word), Ctrl+U (clear). Clipboard paste
-- (OC's middle click / Insert) inserts at the cursor. Text is UTF-8: a
-- Cyrillic character counts as one.

local base = require("ocui.widget")
local theme = require("ocui.theme")
local util = require("ocui.util")
local Widget = base.Widget

local TextInput = setmetatable({}, { __index = Widget })
TextInput.__index = TextInput

function TextInput.new(props)
  props = props or {}
  local self = setmetatable(Widget.new(props), TextInput)
  self.placeholder = props.placeholder or ""
  self.mask = props.mask
  self.maxLength = props.maxLength
  self.filter = props.filter
  self.onChange = props.onChange
  self.onSubmit = props.onSubmit
  self.onCancel = props.onCancel
  self.fg = props.fg or theme.text
  self.bg = props.bg or theme.input
  self.focusBg = props.focusBg or theme.inputFocus
  self.disabled = props.disabled
  if self.focusable == nil then self.focusable = true end
  self.scroll = 0 -- characters hidden off the left edge
  self:setValue(props.value or "", true)
  return self
end

function TextInput:getValue()
  return table.concat(self.chars)
end

-- Sets the text and puts the cursor at its end. quiet: no onChange.
function TextInput:setValue(value, quiet)
  self.chars = util.chars(tostring(value or ""))
  self.cursor = #self.chars
  self.value = value
  self:changed(quiet)
end

function TextInput:changed(quiet)
  self.value = table.concat(self.chars)
  self:keepCursorVisible()
  self:invalidate()
  if not quiet and self.onChange then self.onChange(self.value) end
end

function TextInput:keepCursorVisible()
  local room = math.max((self.w or 1) - 1, 1)
  if self.cursor < self.scroll then self.scroll = self.cursor end
  if self.cursor > self.scroll + room then self.scroll = self.cursor - room end
  if self.scroll < 0 then self.scroll = 0 end
end

function TextInput:moveCursor(pos)
  pos = math.max(0, math.min(pos, #self.chars))
  if pos == self.cursor then return end
  self.cursor = pos
  self:keepCursorVisible()
  self:invalidate()
end

-- Inserts text at the cursor (filtered, newlines dropped, length capped).
function TextInput:insert(text)
  local added = false
  for _, ch in ipairs(util.chars(text)) do
    if ch ~= "\n" and ch ~= "\r" and (not self.filter or self.filter(ch)) then
      if self.maxLength and #self.chars >= self.maxLength then break end
      table.insert(self.chars, self.cursor + 1, ch)
      self.cursor = self.cursor + 1
      added = true
    end
  end
  if added then self:changed() end
end

local function isWordChar(ch)
  return ch ~= nil and (ch:match("^[%w_]$") ~= nil or #ch > 1)
end

-- Position of the previous / next word boundary from the cursor.
function TextInput:wordLeft()
  local i = self.cursor
  while i > 0 and not isWordChar(self.chars[i]) do i = i - 1 end
  while i > 0 and isWordChar(self.chars[i]) do i = i - 1 end
  return i
end

function TextInput:wordRight()
  local i, n = self.cursor, #self.chars
  while i < n and not isWordChar(self.chars[i + 1]) do i = i + 1 end
  while i < n and isWordChar(self.chars[i + 1]) do i = i + 1 end
  return i
end

function TextInput:deleteRange(from, to) -- characters from+1 .. to
  if to <= from then return end
  for _ = from + 1, to do table.remove(self.chars, from + 1) end
  self.cursor = from
  self:changed()
end

function TextInput:onKey(ev)
  if self.disabled then return false end
  local name = ev.name
  if ev.text then
    self:insert(ev.text)
  elseif name == "left" then
    self:moveCursor(ev.ctrl and self:wordLeft() or self.cursor - 1)
  elseif name == "right" then
    self:moveCursor(ev.ctrl and self:wordRight() or self.cursor + 1)
  elseif name == "home" then
    self:moveCursor(0)
  elseif name == "end" then
    self:moveCursor(#self.chars)
  elseif name == "back" then
    if ev.ctrl then
      self:deleteRange(self:wordLeft(), self.cursor)
    elseif self.cursor > 0 then
      self:deleteRange(self.cursor - 1, self.cursor)
    end
  elseif name == "delete" then
    if self.cursor < #self.chars then self:deleteRange(self.cursor, self.cursor + 1) end
  elseif ev.ctrl and name == "u" then
    self:deleteRange(0, #self.chars)
  elseif name == "enter" then
    if not self.onSubmit then return false end
    self.onSubmit(self.value)
  elseif name == "escape" then
    if not self.onCancel then return false end
    self.onCancel()
  else
    return false
  end
  return true
end

function TextInput:onPaste(text)
  if self.disabled then return false end
  self:insert(text)
  return true
end

function TextInput:onTouch(x)
  if self.disabled then return true end
  self:moveCursor(self.scroll + x)
  return true
end

function TextInput:draw(canvas)
  local focused = self:isFocused()
  local bg = focused and self.focusBg or self.bg
  canvas:fillRect(0, 0, self.w, self.h, bg)
  local n = #self.chars
  if n == 0 and not focused and self.placeholder ~= "" then
    canvas:text(0, 0, util.truncate(self.placeholder, self.w), theme.textDim, bg)
    return
  end
  local visible = {}
  for i = self.scroll + 1, math.min(n, self.scroll + self.w) do
    visible[#visible + 1] = self.mask or self.chars[i]
  end
  local fg = self.disabled and theme.disabled or self.fg
  if #visible > 0 then canvas:text(0, 0, table.concat(visible), fg, bg) end
  if focused then
    local cx = self.cursor - self.scroll
    if cx >= 0 and cx < self.w then
      local under = self.chars[self.cursor + 1]
      if under and self.mask then under = self.mask end
      canvas:text(cx, 0, under or " ", bg, theme.cursor)
    end
  end
end

return TextInput
