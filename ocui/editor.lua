-- ocui.editor
-- Multi-line text editor widget over an ocui.textbuffer, with syntax
-- highlighting (ocui.syntax), selection, clipboard, undo, search, line
-- numbers and mouse support. Repaints only the lines that changed.
--
--   local ed = Editor.new({ buffer = TextBuffer.new(text), highlighter = syntax.lua,
--                           onChange = fn(ed), onCursor = fn(ed) })
--
-- Keys (when focused):
--   arrows, Home/End (Home toggles first non-blank / column 0), PgUp/PgDn,
--   Ctrl+Home/End, Ctrl+Left/Right (words); Shift + any of them selects;
--   Enter (keeps the indentation), Tab / Shift+Tab (indent / unindent the
--   selected lines), Backspace/Delete (Ctrl: by word);
--   Ctrl+A select all, Ctrl+C copy, Ctrl+X cut, Ctrl+V paste,
--   Ctrl+K cut the line (repeat to collect several), Ctrl+U paste them,
--   Ctrl+Z undo, Ctrl+Y redo. The clipboard signal (OC's paste) inserts.
-- Mouse: click places the cursor, drag selects, double click selects a
-- word, the wheel scrolls.

local base = require("ocui.widget")
local TextBuffer = require("ocui.textbuffer")
local theme = require("ocui.theme")
local util = require("ocui.util")
local Widget = base.Widget

local computer = require("computer")

local Editor = setmetatable({}, { __index = Widget })
Editor.__index = Editor

Editor.COLORS = {
  keyword = 0xC678DD, constant = 0xD19A66, builtin = 0x61AFEF, string = 0x98C379,
  comment = 0x7F848E, number = 0xD19A66, func = 0xE5C07B,
}
Editor.clipboard = "" -- shared by every editor in this program

local CHAR = util.CODEPOINT_PATTERN

function Editor.new(props)
  props = props or {}
  local self = setmetatable(Widget.new(props), Editor)
  self.focusable = true
  self.highlighter = props.highlighter
  self.tabWidth = props.tabWidth or 2
  self.lineNumbers = props.lineNumbers ~= false
  self.readOnly = props.readOnly
  self.fg = props.fg or theme.text
  self.bg = props.bg or theme.background
  self.lineBg = props.lineBg or 0x16161D
  self.selBg = props.selBg or theme.selection
  self.gutterFg = props.gutterFg or theme.disabled
  self.onChange = props.onChange
  self.onCursor = props.onCursor
  self:setBuffer(props.buffer or TextBuffer.new(props.text or ""))
  return self
end

function Editor:setBuffer(buffer)
  self.buffer = buffer
  self.cursor = { line = 1, col = 0 }
  self.anchor = nil
  self.top, self.left = 1, 0
  self.wantX = nil
  self.states, self.valid = { "" }, 1
  self.painted = {}
  buffer.onChange = function(first, last, delta) self:bufferChanged(first, last, delta) end
  self:invalidate()
end

function Editor:setHighlighter(hl)
  self.highlighter = hl
  self.states, self.valid = { "" }, 1
  self.painted = {}
  self:invalidate()
end

-- --------------------------------------------------------------- geometry --

function Editor:gutterWidth()
  if not self.lineNumbers then return 0 end
  return math.max(3, #tostring(self.buffer:lineCount())) + 1
end

function Editor:textWidth() return math.max((self.w or 0) - self:gutterWidth(), 1) end

-- Display column of character `col` of a line (tabs expanded).
function Editor:displayCol(text, col)
  if not text:find("\t", 1, true) then
    if not text:find("[\128-\255]") then return math.min(col, #text) end
    return math.min(col, util.len(text))
  end
  local d, n = 0, 0
  for ch in text:gmatch(CHAR) do
    if n >= col then break end
    d = d + (ch == "\t" and (self.tabWidth - d % self.tabWidth) or 1)
    n = n + 1
  end
  return d
end

-- Character column nearest to display column `x`.
function Editor:colAt(text, x)
  local d, n = 0, 0
  for ch in text:gmatch(CHAR) do
    local w = ch == "\t" and (self.tabWidth - d % self.tabWidth) or 1
    if d + w / 2 > x then return n end
    d = d + w
    n = n + 1
  end
  return n
end

function Editor:rowOf(line)
  local r = line - self.top
  if r < 0 or r >= self.h then return nil end
  return r
end

function Editor:invalidateLines(a, b)
  if a > b then a, b = b, a end
  local r0 = math.max(a - self.top, 0)
  local r1 = math.min(b - self.top, self.h - 1)
  if r1 >= r0 then self:invalidate(0, r0, self.w, r1 - r0 + 1) end
end

-- Scrolls so the cursor is visible; repaints everything if it scrolled.
function Editor:ensureVisible()
  local h, tw = math.max(self.h, 1), self:textWidth()
  local top, left = self.top, self.left
  if self.cursor.line < top then top = self.cursor.line end
  if self.cursor.line > top + h - 1 then top = self.cursor.line - h + 1 end
  local dc = self:displayCol(self.buffer:line(self.cursor.line), self.cursor.col)
  local margin = math.min(8, math.floor(tw / 4))
  if dc < left then left = math.max(dc - margin, 0) end
  if dc >= left + tw then left = dc - tw + 1 + margin end
  if top ~= self.top or left ~= self.left then
    self.top, self.left = top, left
    self.painted = {}
    self:invalidate()
  end
end

-- -------------------------------------------------------------- selection --

function Editor:hasSelection()
  local a, c = self.anchor, self.cursor
  return a ~= nil and (a.line ~= c.line or a.col ~= c.col)
end

-- Ordered selection bounds, or nil.
function Editor:selection()
  if not self:hasSelection() then return nil end
  return TextBuffer.order(self.anchor, self.cursor)
end

function Editor:selectedText()
  local a, b = self:selection()
  if not a then return "" end
  return self.buffer:range(a, b)
end

local function copyPos(p) return { line = p.line, col = p.col } end

-- Moves the cursor; extend = keep/start a selection from the old spot.
function Editor:setCursor(pos, extend, keepWant)
  pos = self.buffer:clamp(pos)
  local old, oldAnchor = self.cursor, self.anchor
  local hadSel = self:hasSelection()
  if extend then
    if not self.anchor then self.anchor = copyPos(old) end
  else
    self.anchor = nil
  end
  self.cursor = pos
  if not keepWant then self.wantX = nil end
  -- repaint the rows whose look changed: the cursor rows, and everything
  -- a selection covered before or covers now
  local lo, hi = math.min(old.line, pos.line), math.max(old.line, pos.line)
  if hadSel and oldAnchor then lo, hi = math.min(lo, oldAnchor.line), math.max(hi, oldAnchor.line) end
  if self.anchor then lo, hi = math.min(lo, self.anchor.line), math.max(hi, self.anchor.line) end
  if hadSel or self:hasSelection() then
    self:invalidateLines(lo, hi)
  else
    self:invalidateLines(old.line, old.line)
    self:invalidateLines(pos.line, pos.line)
  end
  self:ensureVisible()
  if self.onCursor then self.onCursor(self) end
end

function Editor:select(a, b)
  self:setCursor(a)
  self:setCursor(b, true)
end

function Editor:selectAll()
  local n = self.buffer:lineCount()
  self:select({ line = 1, col = 0 }, { line = n, col = self.buffer:lineLength(n) })
end

-- ----------------------------------------------------------- highlighting --

-- Highlighter state at the start of line i.
function Editor:stateAt(i)
  local hl = self.highlighter
  if not hl then return "" end
  local lines = self.buffer.lines
  while self.valid < i and self.valid <= #lines do
    local j = self.valid
    local _, e = hl.tokenize(lines[j], self.states[j])
    self.states[j + 1] = e
    self.valid = j + 1
  end
  return self.states[i] or ""
end

function Editor:bufferChanged(first, last, delta)
  if first < self.valid then self.valid = first end
  if delta ~= 0 then
    -- lines moved: everything from here down looks different
    self.painted = {}
    local gutter = self:gutterWidth()
    if gutter ~= self.lastGutter then
      self.lastGutter = gutter
      self:invalidate()
    else
      self:invalidateLines(first, self.top + self.h)
    end
  else
    self:invalidateLines(first, last)
    -- a changed line may open/close a long comment or string: if the
    -- state the next line was painted with is no longer right, repaint
    -- the rest of the screen
    local painted = self.painted[last + 1]
    if painted ~= nil and self.highlighter then
      local _, e = self.highlighter.tokenize(self.buffer.lines[last], self:stateAt(last))
      if e ~= painted then
        self.painted = {}
        self:invalidateLines(last + 1, self.top + self.h)
      end
    end
  end
  if self.onChange then self.onChange(self) end
end

-- ------------------------------------------------------------------- draw --

function Editor:drawLine(canvas, y, i)
  local text = self.buffer.lines[i]
  local gw, tw = self:gutterWidth(), self:textWidth()
  local isCurrent = i == self.cursor.line
  local bg = isCurrent and self.lineBg or self.bg
  canvas:fillRect(0, y, self.w, 1, bg)
  if gw > 0 then
    local num = tostring(i)
    canvas:text(gw - 1 - #num, y, num, isCurrent and self.fg or self.gutterFg, bg)
  end
  -- character colors from the highlighter
  local spans = {}
  if self.highlighter then
    local start = self:stateAt(i)
    self.painted[i] = start
    spans = self.highlighter.tokenize(text, start)
  end
  local selA, selB = self:selection()
  local selFrom, selTo -- selected character columns on this line ([from, to))
  if selA and i >= selA.line and i <= selB.line then
    selFrom = i == selA.line and selA.col or 0
    selTo = i == selB.line and selB.col or math.huge
  end

  local cells = {}
  local left, right = self.left, self.left + tw
  local d, n, si, byte = 0, 0, 1, 1
  local colors = Editor.COLORS
  for ch in text:gmatch(CHAR) do
    if d >= right then break end
    while spans[si] and spans[si].to < byte do si = si + 1 end
    local span = spans[si]
    local fg = (span and span.from <= byte) and colors[span.kind] or self.fg
    local cbg = (selFrom and n >= selFrom and n < selTo) and self.selBg or bg
    local width = ch == "\t" and (self.tabWidth - d % self.tabWidth) or 1
    for k = 0, width - 1 do
      local x = d + k - left
      if x >= 0 and x < tw then
        cells[x + 1] = { ch == "\t" and " " or ch, fg, cbg }
      end
    end
    d = d + width
    n = n + 1
    byte = byte + #ch
  end
  -- a selected line break shows as one selected cell
  if selTo == math.huge and d - left >= 0 and d - left < tw then
    cells[d - left + 1] = { " ", self.fg, self.selBg }
  end
  if isCurrent and self:isFocused() then
    local x = self:displayCol(text, self.cursor.col) - left
    if x >= 0 and x < tw then
      local cell = cells[x + 1]
      cells[x + 1] = { cell and cell[1] or " ", self.bg, theme.cursor }
    end
  end
  -- one GPU call per run of same-colored cells
  local x = 1
  while x <= tw do
    local cell = cells[x]
    if cell and (cell[1] ~= " " or cell[3] ~= bg) then
      local fg, cbg = cell[2], cell[3]
      local run = { cell[1] }
      local j = x + 1
      while j <= tw do
        local c = cells[j]
        if not c or c[3] ~= cbg or (c[2] ~= fg and c[1] ~= " ") then break end
        run[#run + 1] = c[1]
        j = j + 1
      end
      canvas:text(gw + x - 1, y, table.concat(run), fg, cbg)
      x = j
    else
      x = x + 1
    end
  end
end

function Editor:draw(canvas)
  local gw = self:gutterWidth()
  self.lastGutter = gw
  local lines = self.buffer:lineCount()
  for r = 0, self.h - 1 do
    if canvas:intersects(0, r, self.w, 1) then
      local i = self.top + r
      if i <= lines then
        self:drawLine(canvas, r, i)
      else
        canvas:fillRect(0, r, self.w, 1, self.bg)
        if gw > 0 then canvas:text(gw - 2, r, "~", self.gutterFg, self.bg) end
      end
    end
  end
end

function Editor:focusChanged()
  self:invalidateLines(self.cursor.line, self.cursor.line)
end

-- ---------------------------------------------------------------- editing --

-- Replaces the selection (if any) with `text`; one undo step.
function Editor:insertText(text)
  if self.readOnly then return end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local pos
  self.buffer:group(function()
    local a, b = self:selection()
    if a then
      self.buffer:delete(a, b)
      self.cursor, self.anchor = a, nil
    end
    pos = self.buffer:insert(self.cursor, text)
  end)
  self:setCursor(pos)
end

function Editor:deleteSelection()
  local a, b = self:selection()
  if not a or self.readOnly then return false end
  self.buffer:delete(a, b)
  self.anchor = nil
  self:setCursor(a)
  return true
end

local function isWordChar(ch)
  return ch ~= nil and ch ~= "" and (ch:match("^[%w_]$") ~= nil or #ch > 1)
end

local function charAt(text, col) -- 0-based character index
  local b = TextBuffer.byteAt(text, col)
  return text:match("^" .. CHAR, b)
end

-- Position one word left/right of `pos`, crossing lines.
function Editor:wordMove(pos, dir)
  local buf = self.buffer
  local line, col = pos.line, pos.col
  local text = buf:line(line)
  if dir < 0 then
    if col == 0 then
      if line == 1 then return pos end
      return { line = line - 1, col = buf:lineLength(line - 1) }
    end
    while col > 0 and not isWordChar(charAt(text, col - 1)) do col = col - 1 end
    while col > 0 and isWordChar(charAt(text, col - 1)) do col = col - 1 end
  else
    local len = buf:lineLength(line)
    if col >= len then
      if line == buf:lineCount() then return pos end
      return { line = line + 1, col = 0 }
    end
    while col < len and not isWordChar(charAt(text, col)) do col = col + 1 end
    while col < len and isWordChar(charAt(text, col)) do col = col + 1 end
  end
  return { line = line, col = col }
end

function Editor:backspace(byWord)
  if self.readOnly or self:deleteSelection() then return end
  local c = self.cursor
  local from
  if byWord then
    from = self:wordMove(c, -1)
  elseif c.col > 0 then
    from = { line = c.line, col = c.col - 1 }
  elseif c.line > 1 then
    from = { line = c.line - 1, col = self.buffer:lineLength(c.line - 1) }
  else
    return
  end
  self.buffer:delete(from, c)
  self:setCursor(from)
end

function Editor:deleteForward(byWord)
  if self.readOnly or self:deleteSelection() then return end
  local c = self.cursor
  local to
  if byWord then
    to = self:wordMove(c, 1)
  elseif c.col < self.buffer:lineLength(c.line) then
    to = { line = c.line, col = c.col + 1 }
  elseif c.line < self.buffer:lineCount() then
    to = { line = c.line + 1, col = 0 }
  else
    return
  end
  self.buffer:delete(c, to)
  self:setCursor(c)
end

function Editor:newline()
  local text = self.buffer:line(self.cursor.line)
  local indent = text:match("^[ \t]*")
  local before = text:sub(1, TextBuffer.byteAt(text, self.cursor.col) - 1)
  if #indent > #before then indent = before end
  self:insertText("\n" .. indent)
end

-- Indents (dir = 1) or unindents (-1) the lines the selection touches.
function Editor:indentLines(dir)
  if self.readOnly then return end
  local a, b = self:selection()
  if not a then a, b = self.cursor, self.cursor end
  local last = b.line
  if b.col == 0 and b.line > a.line then last = last - 1 end
  local unit = string.rep(" ", self.tabWidth)
  local anchor, cursor = self.anchor and copyPos(self.anchor), copyPos(self.cursor)
  self.buffer:group(function()
    for i = a.line, last do
      local text = self.buffer:line(i)
      local shift = 0
      if dir > 0 then
        if text ~= "" then self.buffer:insert({ line = i, col = 0 }, unit); shift = self.tabWidth end
      else
        local lead = text:match("^ *")
        local n = math.min(#lead, self.tabWidth)
        if n == 0 and text:sub(1, 1) == "\t" then n = 1 end
        if n > 0 then self.buffer:delete({ line = i, col = 0 }, { line = i, col = n }) end
        shift = -n
      end
      if anchor and anchor.line == i then anchor.col = math.max(anchor.col + shift, 0) end
      if cursor.line == i then cursor.col = math.max(cursor.col + shift, 0) end
    end
  end)
  self.anchor = anchor
  self:setCursor(cursor, anchor ~= nil)
end

function Editor:insertTab()
  if self:hasSelection() and self.anchor.line ~= self.cursor.line then
    return self:indentLines(1)
  end
  local d = self:displayCol(self.buffer:line(self.cursor.line), self.cursor.col)
  self:insertText(string.rep(" ", self.tabWidth - d % self.tabWidth))
end

function Editor:copy()
  if self:hasSelection() then Editor.clipboard = self:selectedText() end
end

function Editor:cut()
  if not self:hasSelection() or self.readOnly then return end
  Editor.clipboard = self:selectedText()
  self:deleteSelection()
end

-- nano's ^K: cuts the current line; consecutive cuts collect the lines.
function Editor:cutLine()
  if self.readOnly then return end
  if self:hasSelection() then return self:cut() end
  local buf, line = self.buffer, self.cursor.line
  local text
  if line < buf:lineCount() then
    text = buf:delete({ line = line, col = 0 }, { line = line + 1, col = 0 })
  else
    text = buf:delete({ line = line, col = 0 }, { line = line, col = buf:lineLength(line) })
    if line > 1 then
      buf:delete({ line = line - 1, col = buf:lineLength(line - 1) }, { line = line, col = 0 })
      line = line - 1
    end
    text = text .. "\n"
  end
  if self.lastAction == "cutLine" then
    Editor.clipboard = Editor.clipboard .. text
  else
    Editor.clipboard = text
  end
  self:setCursor({ line = line, col = 0 })
end

function Editor:paste()
  if Editor.clipboard ~= "" then self:insertText(Editor.clipboard) end
end

function Editor:undo()
  local pos = self.buffer:undo()
  if pos then self:setCursor(pos) end
end

function Editor:redo()
  local pos = self.buffer:redo()
  if pos then self:setCursor(pos) end
end

-- Selects the next (or previous) occurrence of `needle`; returns true if
-- found.
function Editor:find(needle, backwards, ignoreCase)
  local from = self.cursor
  if backwards then
    local a = self:selection()
    from = a or self.cursor
  end
  local a, b = self.buffer:find(needle, from, backwards, ignoreCase)
  if not a then return false end
  if not backwards and a.line == self.cursor.line and a.col == self.cursor.col and self:hasSelection() then
    -- the match is the current selection: look past it
    a, b = self.buffer:find(needle, b, false, ignoreCase)
  end
  self:select(a, b)
  return true
end

-- Replaces every occurrence; returns the count (one undo step).
function Editor:replaceAll(needle, replacement, ignoreCase)
  if needle == "" or self.readOnly then return 0 end
  local count = 0
  local pos = { line = 1, col = 0 }
  self.buffer:group(function()
    while true do
      local a, b = self.buffer:find(needle, pos, false, ignoreCase)
      if not a or TextBuffer.before(a, pos) then break end
      self.buffer:delete(a, b)
      pos = self.buffer:insert(a, replacement)
      count = count + 1
    end
  end)
  if count > 0 then self:setCursor(self.buffer:clamp(self.cursor)) end
  return count
end

function Editor:gotoLine(line, col)
  self:setCursor({ line = line, col = col or 0 })
  -- show it a third of the way down, not at the very edge
  local top = math.max(1, self.cursor.line - math.floor(self.h / 3))
  if top ~= self.top and (self.cursor.line < self.top or self.cursor.line >= self.top + self.h) then
    self.top = top
    self.painted = {}
    self:invalidate()
  end
end

-- ------------------------------------------------------------------ input --

function Editor:moveVertical(delta, extend)
  local buf = self.buffer
  local text = buf:line(self.cursor.line)
  self.wantX = self.wantX or self:displayCol(text, self.cursor.col)
  local line = math.max(1, math.min(self.cursor.line + delta, buf:lineCount()))
  local col = self:colAt(buf:line(line), self.wantX)
  if line == self.cursor.line and delta ~= 0 then
    col = delta < 0 and 0 or buf:lineLength(line)
  end
  self:setCursor({ line = line, col = col }, extend, true)
end

function Editor:onKey(ev)
  local name, ctrl, shift = ev.name, ev.ctrl, ev.shift
  local c = self.cursor
  local buf = self.buffer
  local action = nil
  if ev.text and not ctrl then
    self:insertText(ev.text)
  elseif name == "left" then
    if self:hasSelection() and not shift then
      self:setCursor((self:selection()))
    elseif ctrl then
      self:setCursor(self:wordMove(c, -1), shift)
    elseif c.col > 0 then
      self:setCursor({ line = c.line, col = c.col - 1 }, shift)
    elseif c.line > 1 then
      self:setCursor({ line = c.line - 1, col = buf:lineLength(c.line - 1) }, shift)
    end
  elseif name == "right" then
    if self:hasSelection() and not shift then
      local _, b = self:selection()
      self:setCursor(b)
    elseif ctrl then
      self:setCursor(self:wordMove(c, 1), shift)
    elseif c.col < buf:lineLength(c.line) then
      self:setCursor({ line = c.line, col = c.col + 1 }, shift)
    elseif c.line < buf:lineCount() then
      self:setCursor({ line = c.line + 1, col = 0 }, shift)
    end
  elseif name == "up" then self:moveVertical(-1, shift)
  elseif name == "down" then self:moveVertical(1, shift)
  elseif name == "pageUp" then self:moveVertical(-(self.h - 1), shift)
  elseif name == "pageDown" then self:moveVertical(self.h - 1, shift)
  elseif name == "home" then
    if ctrl then
      self:setCursor({ line = 1, col = 0 }, shift)
    else
      local first = #(buf:line(c.line):match("^[ \t]*"))
      self:setCursor({ line = c.line, col = c.col == first and 0 or first }, shift)
    end
  elseif name == "end" then
    if ctrl then
      local n = buf:lineCount()
      self:setCursor({ line = n, col = buf:lineLength(n) }, shift)
    else
      self:setCursor({ line = c.line, col = buf:lineLength(c.line) }, shift)
    end
  elseif name == "enter" then self:newline()
  elseif name == "tab" then
    if shift then self:indentLines(-1) else self:insertTab() end
  elseif name == "back" then self:backspace(ctrl)
  elseif name == "delete" then self:deleteForward(ctrl)
  elseif ctrl and name == "a" then self:selectAll()
  elseif ctrl and name == "c" then self:copy()
  elseif ctrl and name == "x" then self:cut()
  elseif ctrl and name == "v" then self:paste()
  elseif ctrl and name == "k" then self:cutLine(); action = "cutLine"
  elseif ctrl and name == "u" then self:paste()
  elseif ctrl and name == "z" then self:undo()
  elseif ctrl and name == "y" then self:redo()
  else
    return false
  end
  self.lastAction = action
  return true
end

function Editor:onPaste(text)
  self:insertText(text)
  return true
end

function Editor:posAt(x, y)
  local buf = self.buffer
  local line = math.max(1, math.min(self.top + y, buf:lineCount()))
  local col = self:colAt(buf:line(line), x - self:gutterWidth() + self.left)
  return { line = line, col = col }
end

function Editor:onTouch(x, y, button)
  if button == 1 then return true end
  local pos = self:posAt(x, y)
  local now = computer.uptime()
  local last = self.lastClick
  if last and last.line == pos.line and last.col == pos.col and now - last.at <= 0.5 then
    -- double click: select the word
    local text = self.buffer:line(pos.line)
    local a, b = pos.col, pos.col
    while a > 0 and isWordChar(charAt(text, a - 1)) do a = a - 1 end
    while isWordChar(charAt(text, b)) do b = b + 1 end
    self:select({ line = pos.line, col = a }, { line = pos.line, col = b })
    self.lastClick = nil
    return true
  end
  self.lastClick = { line = pos.line, col = pos.col, at = now }
  self:setCursor(pos)
  self.dragAnchor = copyPos(self.cursor)
  return true
end

function Editor:onDrag(x, y)
  if not self.dragAnchor then return false end
  if y < 0 and self.top > 1 then
    self.top = self.top - 1
    self.painted = {}
    self:invalidate()
  elseif y >= self.h and self.top + self.h <= self.buffer:lineCount() then
    self.top = self.top + 1
    self.painted = {}
    self:invalidate()
  end
  local pos = self:posAt(x, math.max(0, math.min(y, self.h - 1)))
  self.anchor = self.anchor or copyPos(self.dragAnchor)
  self:setCursor(pos, true)
  return true
end

function Editor:onDrop()
  self.dragAnchor = nil
  return true
end

function Editor:onScroll(_, _, dir)
  local maxTop = math.max(self.buffer:lineCount() - self.h + 1, 1)
  local top = math.max(1, math.min(self.top + (dir > 0 and -3 or 3), maxTop))
  if top ~= self.top then
    self.top = top
    self.painted = {}
    self:invalidate()
  end
  return true
end

return Editor
