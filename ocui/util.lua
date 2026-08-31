-- ocui.util
-- Pure pattern-matching UTF-8 helpers (no dependency on Lua 5.3's `utf8`
-- library, which OpenComputers' bundled Lua 5.2 does not have). Needed
-- because box-drawing border characters are multi-byte, and Lua's `#`/
-- `:sub` operate on bytes, not codepoints -- truncating a string to a
-- fixed *column* width by byte count can cut a codepoint in half.

local M = {}

local CODEPOINT_PATTERN = "[\0-\127\194-\253][\128-\191]*"

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

return M
