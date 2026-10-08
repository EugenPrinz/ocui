-- ocui.vgpu
-- A virtual GPU: an in-memory grid of characters and colors that answers
-- the same calls as a real GPU proxy (dot-style: vgpu.set(x, y, s)), so
-- OpenOS's terminal (tty/term, the shell, edit, ls...) can draw into a
-- window instead of onto the screen.
--
--   local vgpu = VGpu.new(80, 25)
--   vgpu.onDamage = function(x, y, w, h) ... end   -- 0-based cells changed
--   vgpu.cell(x, y) -> char, fg, bg               -- 1-based, for drawing
--
-- Resolution changes are refused (the window decides the size); resize()
-- is ours, for a window that changes size.

local util = require("ocui.util")

local VGpu = {}

local DEFAULT_PALETTE = {
  [0] = 0x0F0F0F, 0x1E1E1E, 0x2D2D2D, 0x3C3C3C, 0x4B4B4B, 0x5A5A5A, 0x696969, 0x787878,
  0x878787, 0x969696, 0xA5A5A5, 0xB4B4B4, 0xC3C3C3, 0xD2D2D2, 0xE1E1E1, 0xF0F0F0,
}

local counter = 0

function VGpu.new(w, h)
  counter = counter + 1
  local g = {
    type = "gpu",
    address = string.format("ocui-vgpu-%d", counter),
    screenAddress = string.format("ocui-vscreen-%d", counter),
  }
  local W, H = w, h
  local chars, fgs, bgs = {}, {}, {}
  local fg, bg = 0xFFFFFF, 0x000000
  local fgPal, bgPal = nil, nil
  local palette = {}
  for i = 0, 15 do palette[i] = DEFAULT_PALETTE[i] end

  local function clear()
    for i = 1, W * H do chars[i], fgs[i], bgs[i] = " ", 0xFFFFFF, 0x000000 end
  end
  clear()

  local function damage(x, y, dw, dh)
    if g.onDamage and dw > 0 and dh > 0 then g.onDamage(x, y, dw, dh) end
  end

  -- ours ---------------------------------------------------------------
  function g.resize(nw, nh)
    local oc, of, ob = chars, fgs, bgs
    chars, fgs, bgs = {}, {}, {}
    for y = 1, nh do
      for x = 1, nw do
        local i, j = (y - 1) * nw + x, (y - 1) * W + x
        if x <= W and y <= H then
          chars[i], fgs[i], bgs[i] = oc[j], of[j], ob[j]
        else
          chars[i], fgs[i], bgs[i] = " ", 0xFFFFFF, 0x000000
        end
      end
    end
    W, H = nw, nh
    damage(0, 0, W, H)
  end

  function g.cell(x, y)
    local i = (y - 1) * W + x
    return chars[i], fgs[i], bgs[i]
  end

  function g.size() return W, H end

  -- the GPU API --------------------------------------------------------
  function g.getScreen() return g.screenAddress end
  function g.bind() return true end
  function g.getResolution() return W, H end
  function g.getViewport() return W, H end
  function g.maxResolution() return W, H end
  function g.setResolution() return false end
  function g.setViewport() return false end
  function g.getDepth() return 8 end
  function g.maxDepth() return 8 end
  function g.setDepth() return 8 end
  function g.totalMemory() return 0 end
  function g.freeMemory() return 0 end

  function g.getPaletteColor(i) return palette[i] end
  function g.setPaletteColor(i, color)
    local old = palette[i]
    palette[i] = color
    return old
  end

  function g.setForeground(color, isPalette)
    local old, oldPal = fg, fgPal
    if isPalette then fgPal, fg = color, palette[color] or 0xFFFFFF else fgPal, fg = nil, color end
    return old, oldPal
  end
  function g.setBackground(color, isPalette)
    local old, oldPal = bg, bgPal
    if isPalette then bgPal, bg = color, palette[color] or 0 else bgPal, bg = nil, color end
    return old, oldPal
  end
  function g.getForeground() return fgPal or fg, fgPal ~= nil end
  function g.getBackground() return bgPal or bg, bgPal ~= nil end

  function g.get(x, y)
    if x < 1 or y < 1 or x > W or y > H then return nil, "index out of bounds" end
    local i = (y - 1) * W + x
    return chars[i], fgs[i], bgs[i], nil, nil
  end

  function g.set(x, y, value, vertical)
    value = tostring(value)
    local cx, cy = math.floor(x), math.floor(y)
    local x0, y0, n = cx, cy, 0
    for ch in value:gmatch(util.CODEPOINT_PATTERN) do
      if cx >= 1 and cy >= 1 and cx <= W and cy <= H then
        local i = (cy - 1) * W + cx
        chars[i], fgs[i], bgs[i] = ch, fg, bg
      end
      n = n + 1
      if vertical then cy = cy + 1 else cx = cx + 1 end
    end
    if vertical then damage(x0 - 1, y0 - 1, 1, n) else damage(x0 - 1, y0 - 1, n, 1) end
    return true
  end

  function g.fill(x, y, fw, fh, ch)
    ch = util.truncate(tostring(ch), 1)
    if ch == "" then ch = " " end
    local x0, y0 = math.max(math.floor(x), 1), math.max(math.floor(y), 1)
    local x1, y1 = math.min(math.floor(x + fw - 1), W), math.min(math.floor(y + fh - 1), H)
    for cy = y0, y1 do
      local row = (cy - 1) * W
      for cx = x0, x1 do
        local i = row + cx
        chars[i], fgs[i], bgs[i] = ch, fg, bg
      end
    end
    damage(x0 - 1, y0 - 1, x1 - x0 + 1, y1 - y0 + 1)
    return true
  end

  function g.copy(x, y, cw, ch, tx, ty)
    local snap = {}
    for cy = y, y + ch - 1 do
      for cx = x, x + cw - 1 do
        if cx >= 1 and cy >= 1 and cx <= W and cy <= H then
          local i = (cy - 1) * W + cx
          snap[#snap + 1] = { cx + tx, cy + ty, chars[i], fgs[i], bgs[i] }
        end
      end
    end
    for _, s in ipairs(snap) do
      local dx, dy = s[1], s[2]
      if dx >= 1 and dy >= 1 and dx <= W and dy <= H then
        local i = (dy - 1) * W + dx
        chars[i], fgs[i], bgs[i] = s[3], s[4], s[5]
      end
    end
    damage(math.max(x + tx, 1) - 1, math.max(y + ty, 1) - 1, cw, ch)
    return true
  end

  return g
end

return VGpu
