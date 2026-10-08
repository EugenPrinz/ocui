-- ocui.textbuffer
-- Text as an array of lines, edited by character position, with undo/redo.
--
--   local buf = TextBuffer.new("first line\nsecond")
--   local stop = buf:insert({ line = 1, col = 5 }, "XY\nZ")   -- returns end pos
--   local removed = buf:delete({ line = 1, col = 0 }, { line = 2, col = 1 })
--   buf:undo() / buf:redo()          -- return the position to put the cursor at
--   buf:getText(), buf:isModified(), buf:markSaved()
--
-- Positions are { line = 1.., col = 0..length } with col counted in
-- characters (UTF-8 codepoints), so Cyrillic text edits like ASCII.
-- buf.onChange(firstLine, lastLine, linesDelta) is called after every
-- change: lines firstLine..lastLine (new numbering) changed, and
-- linesDelta lines were added (or removed, if negative) after firstLine.
--
-- Consecutive typing (single characters, no newline) and consecutive
-- Backspaces/Deletes merge into one undo step; group(fn) makes all the
-- edits of fn one step.

local util = require("ocui.util")

local TextBuffer = {}
TextBuffer.__index = TextBuffer

-- -------------------------------------------------------------- helpers --

local function isAscii(s) return not s:find("[\128-\255]") end

-- Byte index where character `col` + 1 starts (col 0 -> 1); #s + 1 at the end.
local function byteAt(s, col)
  if col <= 0 then return 1 end
  if isAscii(s) then return math.min(col, #s) + 1 end
  local n = 0
  for start in s:gmatch("()" .. util.CODEPOINT_PATTERN) do
    if n == col then return start end
    n = n + 1
  end
  return #s + 1
end
TextBuffer.byteAt = byteAt

local function charLen(s)
  if isAscii(s) then return #s end
  return util.len(s)
end
TextBuffer.charLen = charLen

local function splitLines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  return lines
end

local function before(a, b)
  return a.line < b.line or (a.line == b.line and a.col < b.col)
end
TextBuffer.before = before

-- a, b ordered so that a comes first
function TextBuffer.order(a, b)
  if before(b, a) then return b, a end
  return a, b
end

-- --------------------------------------------------------------- create --

-- text: file contents. "\r\n" line ends and a final newline are
-- remembered and given back by getText().
function TextBuffer.new(text)
  text = text or ""
  local self = setmetatable({}, TextBuffer)
  self.crlf = text:find("\r\n", 1, true) ~= nil
  if self.crlf then text = text:gsub("\r\n", "\n") end
  self.finalNewline = #text > 0 and text:sub(-1) == "\n"
  if self.finalNewline then text = text:sub(1, -2) end
  self.lines = splitLines(text)
  self.undoStack, self.redoStack = {}, {}
  self.nextId = 1
  self.savedId = 0 -- id of the undo step the file on disk matches
  return self
end

function TextBuffer:getText()
  local text = table.concat(self.lines, "\n")
  if self.finalNewline then text = text .. "\n" end
  if self.crlf then text = text:gsub("\n", "\r\n") end
  return text
end

function TextBuffer:lineCount() return #self.lines end
function TextBuffer:line(i) return self.lines[i] or "" end
function TextBuffer:lineLength(i) return charLen(self.lines[i] or "") end

function TextBuffer:clamp(pos)
  local line = math.max(1, math.min(pos.line, #self.lines))
  local col = math.max(0, math.min(pos.col, self:lineLength(line)))
  return { line = line, col = col }
end

-- Text between positions a and b (any order).
function TextBuffer:range(a, b)
  a, b = TextBuffer.order(a, b)
  local first = self.lines[a.line]
  if a.line == b.line then
    return first:sub(byteAt(first, a.col), byteAt(first, b.col) - 1)
  end
  local parts = { first:sub(byteAt(first, a.col)) }
  for i = a.line + 1, b.line - 1 do parts[#parts + 1] = self.lines[i] end
  local last = self.lines[b.line]
  parts[#parts + 1] = last:sub(1, byteAt(last, b.col) - 1)
  return table.concat(parts, "\n")
end

-- ---------------------------------------------------------- raw editing --

function TextBuffer:changed(first, last, delta)
  if self.onChange then self.onChange(first, last, delta) end
end

-- Inserts without touching the undo history; returns the end position.
function TextBuffer:rawInsert(pos, text)
  local line = self.lines[pos.line]
  local cut = byteAt(line, pos.col)
  local head, tail = line:sub(1, cut - 1), line:sub(cut)
  local parts = splitLines(text)
  if #parts == 1 then
    self.lines[pos.line] = head .. text .. tail
    self:changed(pos.line, pos.line, 0)
    return { line = pos.line, col = pos.col + charLen(text) }
  end
  self.lines[pos.line] = head .. parts[1]
  for i = 2, #parts - 1 do table.insert(self.lines, pos.line + i - 1, parts[i]) end
  local lastLine = pos.line + #parts - 1
  table.insert(self.lines, lastLine, parts[#parts] .. tail)
  self:changed(pos.line, lastLine, #parts - 1)
  return { line = lastLine, col = charLen(parts[#parts]) }
end

-- Deletes a..b without touching the undo history; returns the text.
function TextBuffer:rawDelete(a, b)
  a, b = TextBuffer.order(a, b)
  local removed = self:range(a, b)
  local first, last = self.lines[a.line], self.lines[b.line]
  self.lines[a.line] = first:sub(1, byteAt(first, a.col) - 1) .. last:sub(byteAt(last, b.col))
  for _ = a.line + 1, b.line do table.remove(self.lines, a.line + 1) end
  self:changed(a.line, a.line, -(b.line - a.line))
  return removed
end

-- ---------------------------------------------------------------- undo --

local function endOf(pos, text)
  local parts = splitLines(text)
  if #parts == 1 then return { line = pos.line, col = pos.col + charLen(text) } end
  return { line = pos.line + #parts - 1, col = charLen(parts[#parts]) }
end

function TextBuffer:record(op)
  self.redoStack = {}
  if self.grouping then
    table.insert(self.grouping, op)
    return
  end
  local top = self.undoStack[#self.undoStack]
  local last = top and top.ops[#top.ops]
  -- merge runs of typing / of Backspace / of Delete into one step
  if last and #top.ops == 1 and top.id ~= self.savedId and not op.text:find("\n", 1, true)
      and charLen(op.text) == 1 and last.kind == op.kind and not last.text:find("\n", 1, true) then
    if op.kind == "insert" then
      local stop = endOf(last.pos, last.text)
      if stop.line == op.pos.line and stop.col == op.pos.col then
        last.text = last.text .. op.text
        return
      end
    elseif op.pos.line == last.pos.line then
      if op.pos.col + 1 == last.pos.col then -- Backspace
        last.text = op.text .. last.text
        last.pos = op.pos
        return
      elseif op.pos.col == last.pos.col then -- Delete
        last.text = last.text .. op.text
        return
      end
    end
  end
  table.insert(self.undoStack, { id = self.nextId, ops = { op } })
  self.nextId = self.nextId + 1
end

function TextBuffer:insert(pos, text)
  if text == "" then return { line = pos.line, col = pos.col } end
  pos = self:clamp(pos)
  local stop = self:rawInsert(pos, text)
  self:record({ kind = "insert", pos = pos, text = text })
  return stop
end

function TextBuffer:delete(a, b)
  a, b = TextBuffer.order(self:clamp(a), self:clamp(b))
  if a.line == b.line and a.col == b.col then return "" end
  local removed = self:rawDelete(a, b)
  self:record({ kind = "delete", pos = a, text = removed })
  return removed
end

-- Runs fn(); every edit it makes becomes one undo step.
function TextBuffer:group(fn)
  if self.grouping then return fn() end
  self.grouping = {}
  local ok, err = pcall(fn)
  local ops = self.grouping
  self.grouping = nil
  if #ops > 0 then
    table.insert(self.undoStack, { id = self.nextId, ops = ops })
    self.nextId = self.nextId + 1
  end
  if not ok then error(err, 0) end
end

-- Undoes the last step; returns where the cursor should go, or nil.
function TextBuffer:undo()
  local step = table.remove(self.undoStack)
  if not step then return nil end
  local cursor
  for i = #step.ops, 1, -1 do
    local op = step.ops[i]
    if op.kind == "insert" then
      self:rawDelete(op.pos, endOf(op.pos, op.text))
      cursor = op.pos
    else
      cursor = self:rawInsert(op.pos, op.text)
    end
  end
  table.insert(self.redoStack, step)
  return cursor
end

function TextBuffer:redo()
  local step = table.remove(self.redoStack)
  if not step then return nil end
  local cursor
  for _, op in ipairs(step.ops) do
    if op.kind == "insert" then
      cursor = self:rawInsert(op.pos, op.text)
    else
      self:rawDelete(op.pos, endOf(op.pos, op.text))
      cursor = op.pos
    end
  end
  table.insert(self.undoStack, step)
  return cursor
end

function TextBuffer:currentId()
  local top = self.undoStack[#self.undoStack]
  return top and top.id or 0
end

function TextBuffer:isModified() return self:currentId() ~= self.savedId end
function TextBuffer:markSaved() self.savedId = self:currentId() end

-- ---------------------------------------------------------------- search --

-- Next occurrence of `needle` (plain text, one line) at or after `from`
-- (or before it, with backwards), wrapping around. Returns start, end
-- positions or nil.
function TextBuffer:find(needle, from, backwards, ignoreCase)
  if needle == "" or needle:find("\n", 1, true) then return nil end
  local n = #self.lines
  local function prep(s) return ignoreCase and s:lower() or s end
  local pattern = prep(needle)
  local function match(i, fromCol, toCol)
    local line = prep(self.lines[i])
    local best
    local init = byteAt(line, fromCol or 0)
    while true do
      local s, e = line:find(pattern, init, true)
      if not s then break end
      local col = charLen(line:sub(1, s - 1))
      if toCol and col >= toCol then break end
      best = { s = s, e = e, col = col }
      if not backwards then break end
      init = s + 1
    end
    if not best then return nil end
    return { line = i, col = best.col },
      { line = i, col = best.col + charLen(self.lines[i]:sub(best.s, best.e)) }
  end
  for step = 0, n do
    local i
    if backwards then i = (from.line - 1 - step) % n + 1 else i = (from.line - 1 + step) % n + 1 end
    local a, b
    if step == 0 then
      if backwards then a, b = match(i, 0, from.col) else a, b = match(i, from.col) end
    elseif step == n then
      if backwards then a, b = match(i, from.col) else a, b = match(i, 0, from.col) end
    else
      a, b = match(i)
    end
    if a then return a, b end
  end
  return nil
end

return TextBuffer
