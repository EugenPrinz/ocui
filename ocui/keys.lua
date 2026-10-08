-- ocui.keys
-- Keyboard codes (LWJGL, what OC's key_down/key_up signals carry) and the
-- key event table every widget's onKey(ev) receives:
--
--   ev.name   "enter", "left", "a", "f5", ... (see NAMES; nil if unknown)
--   ev.code   raw key code; ev.char the raw char number
--   ev.text   the typed character as a UTF-8 string, nil for control keys
--   ev.ctrl, ev.shift, ev.alt   modifier state (tracked by ocui.host)
--   ev.combo  "ctrl+shift+s" style name for shortcuts (modifiers sorted
--             ctrl, alt, shift), or just the name with no modifiers
--
-- OpenOS has its own `keyboard` library, but its modifier state is global
-- for all keyboards and it isn't there outside OpenOS (tests); the host
-- tracks modifiers per keyboard from the raw signals instead.

local util = require("ocui.util")

local M = {}

local CODES = {
  escape = 1, back = 14, tab = 15, enter = 28, space = 57,
  lcontrol = 29, rcontrol = 157, lshift = 42, rshift = 54,
  lmenu = 56, rmenu = 184, capital = 58,
  f1 = 59, f2 = 60, f3 = 61, f4 = 62, f5 = 63, f6 = 64, f7 = 65, f8 = 66,
  f9 = 67, f10 = 68, f11 = 87, f12 = 88,
  home = 199, up = 200, pageUp = 201, left = 203, right = 205,
  ["end"] = 207, down = 208, pageDown = 209, insert = 210, delete = 211,
  numpadenter = 156,
  ["1"] = 2, ["2"] = 3, ["3"] = 4, ["4"] = 5, ["5"] = 6, ["6"] = 7,
  ["7"] = 8, ["8"] = 9, ["9"] = 10, ["0"] = 11, minus = 12, equals = 13,
  q = 16, w = 17, e = 18, r = 19, t = 20, y = 21, u = 22, i = 23, o = 24,
  p = 25, lbracket = 26, rbracket = 27,
  a = 30, s = 31, d = 32, f = 33, g = 34, h = 35, j = 36, k = 37, l = 38,
  semicolon = 39, apostrophe = 40, grave = 41, backslash = 43,
  z = 44, x = 45, c = 46, v = 47, b = 48, n = 49, m = 50,
  comma = 51, period = 52, slash = 53,
}
M.CODES = CODES

local NAMES = {}
for name, code in pairs(CODES) do NAMES[code] = name end
NAMES[CODES.numpadenter] = "enter"
M.NAMES = NAMES

M.MODIFIERS = {
  [CODES.lcontrol] = "ctrl", [CODES.rcontrol] = "ctrl",
  [CODES.lshift] = "shift", [CODES.rshift] = "shift",
  [CODES.lmenu] = "alt", [CODES.rmenu] = "alt",
}

-- Builds the event table from a key_down signal's char/code and the
-- current modifier state.
function M.event(char, code, mods)
  mods = mods or {}
  local name = NAMES[code]
  local ev = {
    code = code, name = name, char = char,
    ctrl = mods.ctrl or false, shift = mods.shift or false, alt = mods.alt or false,
  }
  -- Printable unless it is a control character (with Ctrl held, OC
  -- delivers ^A..^Z as 1..26; Ctrl+Alt is AltGr on many layouts, which
  -- does type) or a key we treat as a command.
  if type(char) == "number" and char >= 32 and char ~= 127 and (not ev.ctrl or ev.alt)
      and code ~= CODES.enter and code ~= CODES.tab and code ~= CODES.back then
    ev.text = util.char(char)
  end
  local parts = {}
  if ev.ctrl then parts[#parts + 1] = "ctrl" end
  if ev.alt then parts[#parts + 1] = "alt" end
  if ev.shift then parts[#parts + 1] = "shift" end
  parts[#parts + 1] = name or tostring(code)
  ev.combo = table.concat(parts, "+")
  return ev
end

return M
