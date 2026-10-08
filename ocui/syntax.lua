-- ocui.syntax
-- Line-by-line syntax highlighters for the editor.
--
--   local hl = syntax.forPath("/home/prog.lua")      -- or syntax.lua / nil
--   local spans, endState = hl.tokenize(lineText, startState)
--
-- spans: { {from = byte, to = byte, kind = "keyword"}, ... } in order;
-- text between spans is plain. kinds: keyword, constant, builtin,
-- string, comment, number, func.
-- A state carries constructs spanning lines (Lua long comments/strings);
-- "" is the normal state. States are strings, so they compare with ==.

local M = {}

local function set(words)
  local t = {}
  for w in words:gmatch("%S+") do t[w] = true end
  return t
end

local KEYWORDS = set([[and break do else elseif end for function goto if in local not or
  repeat return then until while]])
local CONSTANTS = set("true false nil")
local BUILTINS = set([[assert collectgarbage dofile error getmetatable ipairs load loadfile next
  pairs pcall print rawequal rawget rawlen rawset require select setmetatable tonumber tostring
  type xpcall unpack _G _ENV _VERSION self
  string table math os io coroutine debug utf8 unicode bit32
  component computer event filesystem shell term keyboard serialization sides colors]])

local lua = { name = "Lua" }
M.lua = lua

-- Long bracket at byte i ("[[", "[=[", ...): returns its level and the
-- index after it, or nil.
local function longOpen(s, i)
  local eq = s:match("^%[(=*)%[", i)
  if eq then return #eq, i + #eq + 2 end
  return nil
end

-- Searches the close of a level-`level` long bracket from byte i; returns
-- the index after it, or nil (continues on the next line).
local function longClose(s, i, level)
  local close = "]" .. string.rep("=", level) .. "]"
  local _, e = s:find(close, i, true)
  return e and e + 1 or nil
end

function lua.tokenize(s, state)
  local spans = {}
  local function add(from, to, kind)
    if to >= from then spans[#spans + 1] = { from = from, to = to, kind = kind } end
  end
  local i, n = 1, #s
  state = state or ""
  -- a long comment/string left open on a previous line
  if state ~= "" then
    local kind, level = state:match("^(%a+):(%d+)$")
    level = tonumber(level)
    local after = longClose(s, 1, level)
    local spanKind = kind == "c" and "comment" or "string"
    if not after then
      add(1, n, spanKind)
      return spans, state
    end
    add(1, after - 1, spanKind)
    i = after
  end

  local afterFunction = false
  while i <= n do
    local c = s:sub(i, i)
    if c == "-" and s:sub(i + 1, i + 1) == "-" then
      local level, after = longOpen(s, i + 2)
      if level then
        local close = longClose(s, after, level)
        if not close then
          add(i, n, "comment")
          return spans, "c:" .. level
        end
        add(i, close - 1, "comment")
        i = close
      else
        add(i, n, "comment")
        return spans, ""
      end
    elseif c == "\"" or c == "'" then
      local j = i + 1
      while j <= n do
        local d = s:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      add(i, math.min(j, n), "string")
      i = j + 1
    elseif c == "[" and longOpen(s, i) then
      local level, after = longOpen(s, i)
      local close = longClose(s, after, level)
      if not close then
        add(i, n, "string")
        return spans, "s:" .. level
      end
      add(i, close - 1, "string")
      i = close
    elseif c:match("%d") or (c == "." and s:sub(i + 1, i + 1):match("%d")) then
      local num = s:match("^0[xX][%x%.]*[pP][%+%-]?%d+", i) or s:match("^0[xX][%x%.]*", i)
        or s:match("^%d*%.?%d*[eE][%+%-]?%d+", i) or s:match("^%d*%.?%d*", i)
      add(i, i + #num - 1, "number")
      i = i + #num
    elseif c:match("[%a_]") then
      local word = s:match("^[%a_][%w_]*", i)
      local kind
      if KEYWORDS[word] then kind = "keyword"
      elseif CONSTANTS[word] then kind = "constant"
      elseif afterFunction then kind = "func"
      elseif BUILTINS[word] then kind = "builtin" end
      if kind then add(i, i + #word - 1, kind) end
      afterFunction = word == "function"
      i = i + #word
    else
      if not c:match("%s") and c ~= "." and c ~= ":" then afterFunction = false end
      i = i + 1
    end
  end
  return spans, ""
end

-- No highlighting.
M.plain = { name = "Text", tokenize = function() return {}, "" end }

-- The highlighter for a file name (nil path: Lua, the usual case in OC).
function M.forPath(path)
  if path == nil then return lua end
  local ext = path:match("%.([%w]+)$")
  if ext == nil or ext == "lua" or ext == "cfg" then return lua end
  return M.plain
end

return M
