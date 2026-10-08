-- ocui.util
-- Pure pattern-matching UTF-8 helpers (no dependency on Lua 5.3's `utf8`
-- library, which OpenComputers' bundled Lua 5.2 does not have). Needed
-- because box-drawing border characters are multi-byte, and Lua's `#`/
-- `:sub` operate on bytes, not codepoints -- truncating a string to a
-- fixed *column* width by byte count can cut a codepoint in half.

local M = {}

local CODEPOINT_PATTERN = "[\0-\127\194-\253][\128-\191]*"
M.CODEPOINT_PATTERN = CODEPOINT_PATTERN

-- Splits a UTF-8 string into an array of single-codepoint strings.
function M.chars(s)
  local t = {}
  for ch in s:gmatch(CODEPOINT_PATTERN) do
    table.insert(t, ch)
  end
  return t
end

-- Number of codepoints (≈ terminal columns for this monospace font; does
-- not account for double-width glyphs).
function M.len(s)
  local n = 0
  for _ in s:gmatch(CODEPOINT_PATTERN) do
    n = n + 1
  end
  return n
end

-- Truncates `s` to at most `maxChars` codepoints.
function M.truncate(s, maxChars)
  if maxChars <= 0 then return "" end
  local n = 0
  local out = {}
  for ch in s:gmatch(CODEPOINT_PATTERN) do
    n = n + 1
    if n > maxChars then break end
    out[n] = ch
  end
  return table.concat(out)
end

-- Codepoints i..j of `s` (1-based, inclusive; j defaults to the end),
-- like string.sub but counting characters instead of bytes.
function M.sub(s, i, j)
  local n = 0
  local out = {}
  for ch in s:gmatch(CODEPOINT_PATTERN) do
    n = n + 1
    if j and n > j then break end
    if n >= i then out[#out + 1] = ch end
  end
  return table.concat(out)
end

-- UTF-8 encoding of a codepoint (what OC's `unicode.char` does): the
-- `char` of a key_down signal is a number.
function M.char(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  elseif code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

-- Pads (or truncates) `s` to exactly `w` columns.
function M.pad(s, w, align)
  local n = M.len(s)
  if n > w then return M.truncate(s, w) end
  local gap = w - n
  if align == "right" then return string.rep(" ", gap) .. s end
  if align == "center" then
    local left = math.floor(gap / 2)
    return string.rep(" ", left) .. s .. string.rep(" ", gap - left)
  end
  return s .. string.rep(" ", gap)
end

-- Shortens `s` to `w` columns with a trailing "…" when it doesn't fit.
function M.ellipsis(s, w)
  if w <= 0 then return "" end
  if M.len(s) <= w then return s end
  return M.truncate(s, w - 1) .. "\226\128\166" -- …
end

-- Word-wraps `text` to lines of at most `w` columns. Explicit newlines
-- are kept; words longer than a line are split.
function M.wrap(text, w)
  local lines = {}
  w = math.max(w, 1)
  for para in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local line, n = {}, 0
    local function flush()
      lines[#lines + 1] = table.concat(line)
      line, n = {}, 0
    end
    local any = false
    for word in para:gmatch("%S+") do
      any = true
      local chars = M.chars(word)
      if n > 0 and n + 1 + #chars > w then flush() end
      if n > 0 then line[#line + 1] = " "; n = n + 1 end
      for _, ch in ipairs(chars) do
        if n >= w then flush() end
        line[#line + 1] = ch
        n = n + 1
      end
    end
    if n > 0 or not any then flush() end
  end
  return lines
end

return M
