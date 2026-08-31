-- mock/component_factory.lua
-- Builds a fake stand-in for OpenOS's `component` module (a fake GPU,
-- screen and me_interface), so ocui and the AE2 dashboard can be
-- smoke-tested with a plain `lua` interpreter outside Minecraft. Not a
-- faithful OC emulator: just enough surface area to exercise real code
-- paths and catch crashes.
--
-- Real OC component proxies are called dot-style with no implicit self
-- (e.g. `gpu.fill(x, y, w, h, ch)`, not `gpu:fill(...)`), so every "method"
-- here is a plain closure over local state, not a colon/self method.
--
-- The runner injects the built table into package.loaded["component"] so
-- that `require("component")` inside app code picks it up unmodified;
-- this file is never itself required as "component".

local M = {}

-- ------------------------------------------------------------- fake GPU --

local function newGrid(w, h)
  local grid = {}
  for y = 1, h do
    local row = {}
    for x = 1, w do
      row[x] = { ch = " ", fg = 0xFFFFFF, bg = 0x000000 }
    end
    grid[y] = row
  end
  return grid
end

local function newGpu(maxW, maxH)
  local state = {
    maxW = maxW, maxH = maxH,
    w = maxW, h = maxH,
    fg = 0xFFFFFF, bg = 0x000000,
    active = 0,
    buffers = { [0] = { w = maxW, h = maxH, grid = newGrid(maxW, maxH) } },
    nextBuf = 1,
  }

  local gpu = {}

  function gpu.maxResolution() return state.maxW, state.maxH end
  function gpu.getResolution() return state.w, state.h end

  function gpu.setResolution(w, h)
    state.w, state.h = w, h
    state.buffers[0] = { w = w, h = h, grid = newGrid(w, h) }
    return true
  end

  function gpu.setBackground(c) local old = state.bg; state.bg = c; return old end
  function gpu.setForeground(c) local old = state.fg; state.fg = c; return old end
  function gpu.getBackground() return state.bg end
  function gpu.getForeground() return state.fg end

  function gpu.getActiveBuffer() return state.active end
  function gpu.setActiveBuffer(i)
    assert(state.buffers[i], "setActiveBuffer: no such buffer " .. tostring(i))
    state.active = i
    return i
  end

  function gpu.allocateBuffer(w, h)
    w = w or state.w
    h = h or state.h
    local idx = state.nextBuf
    state.nextBuf = state.nextBuf + 1
    state.buffers[idx] = { w = w, h = h, grid = newGrid(w, h) }
    return idx
  end

  function gpu.freeBuffer(i)
    i = i or state.active
    if i == 0 then return false end
    state.buffers[i] = nil
    if state.active == i then state.active = 0 end
    return true
  end

  function gpu.getBufferSize(i)
    local b = state.buffers[i or state.active]
    return b.w, b.h
  end

  function gpu.buffers()
    local list = {}
    for idx in pairs(state.buffers) do table.insert(list, idx) end
    table.sort(list)
    return list
  end

  function gpu.fill(x, y, w, h, char)
    local buf = state.buffers[state.active]
    for row = y, y + h - 1 do
      if buf.grid[row] then
        for col = x, x + w - 1 do
          if buf.grid[row][col] then
            buf.grid[row][col] = { ch = char, fg = state.fg, bg = state.bg }
          end
        end
      end
    end
    return true
  end

  -- Real screens address one grid cell per Unicode codepoint (the game's
  -- font, not raw bytes), so this walks `str` by UTF-8 codepoint rather
  -- than by byte -- otherwise multi-byte box-drawing characters would
  -- each clobber several grid cells.
  function gpu.set(x, y, str, _vertical)
    local buf = state.buffers[state.active]
    local row = buf.grid[y]
    if not row then return false end
    local col = x
    for _, code in utf8.codes(str) do
      if row[col] then
        row[col] = { ch = utf8.char(code), fg = state.fg, bg = state.bg }
      end
      col = col + 1
    end
    return true
  end

  function gpu.copy() return true end

  function gpu.bitblt(dst, col, row, w, h, src, fromCol, fromRow)
    dst = dst or 0
    src = src or state.active
    col, row = col or 1, row or 1
    fromCol, fromRow = fromCol or 1, fromRow or 1
    local sb, db = state.buffers[src], state.buffers[dst]
    w = w or sb.w
    h = h or sb.h
    for dy = 0, h - 1 do
      local srow = sb.grid[fromRow + dy]
      local drow = db.grid[row + dy]
      if srow and drow then
        for dx = 0, w - 1 do
          local cell = srow[fromCol + dx]
          if cell and drow[col + dx] then
            drow[col + dx] = { ch = cell.ch, fg = cell.fg, bg = cell.bg }
          end
        end
      end
    end
    return true
  end

  function gpu.bind() return true end

  -- Renders buffer 0 (the screen) as plain text, for eyeballing in a
  -- terminal. Not part of the real GPU API.
  function gpu.dump()
    local buf = state.buffers[0]
    local lines = {}
    for y = 1, buf.h do
      local chars = {}
      for x = 1, buf.w do
        chars[x] = buf.grid[y][x].ch
      end
      lines[y] = table.concat(chars)
    end
    return table.concat(lines, "\n")
  end

  return gpu
end

-- ------------------------------------------------------- fake me_interface --

-- Builds a fake AE2 "common network" component matching the shape produced
-- by GTNewHorizons/OpenComputers' NetworkControl.scala getCpus(): an array
-- of {name, storage, coprocessors, busy, cpu}, where `cpu` itself exposes
-- dot-called closures (isBusy, finalOutput, storedItems, pendingItems,
-- activeItems, cancel).
local function newMeInterface(cpuDefs)
  local me = {}

  function me.getCpus()
    local out = {}
    for _, def in ipairs(cpuDefs) do
      local cpu = {}
      function cpu.isBusy() return def.busy end
      function cpu.isActive() return def.busy end
      function cpu.cancel() def.busy = false; return true end
      function cpu.finalOutput()
        if not def.busy or not def.output then
          return nil, "Nothing is crafted"
        end
        return { name = def.output.name, label = def.output.label, size = def.output.size }
      end
      local function stacks(list)
        local r = {}
        for _, it in ipairs(list or {}) do
          table.insert(r, { name = it.name, label = it.label, size = it.size })
        end
        return r
      end
      function cpu.storedItems() return stacks(def.stored) end
      function cpu.pendingItems() return stacks(def.pending) end
      function cpu.activeItems() return stacks(def.active) end

      table.insert(out, {
        name = def.name,
        storage = def.storage,
        coprocessors = def.coprocessors,
        busy = def.busy,
        cpu = cpu,
      })
    end
    return out
  end

  return me
end

-- ---------------------------------------------------------------- module --

function M.new(opts)
  opts = opts or {}
  local gpu = newGpu(opts.maxW or 80, opts.maxH or 25)
  local comp = {
    gpu = gpu,
    me_interface = newMeInterface(opts.cpus or {}),
  }
  function comp.proxy(address)
    return comp[address]
  end
  function comp.list(_type)
    return function() return nil end
  end
  return comp, gpu
end

return M
