-- mock/component_factory.lua
-- Builds a fake OpenOS environment -- `component`, `computer` and `event`
-- modules plus fake gpu / me_interface / gt_machine (LSC) / glasses
-- components -- so ocui and the apps can be smoke-tested with a plain
-- `lua` interpreter outside Minecraft. Not a faithful OC emulator: just
-- enough surface area, with shapes taken from the GTNH 2.8.4 sources, to
-- exercise real code paths and catch crashes.
--
-- Real OC component proxies are called dot-style with no implicit self
-- (`gpu.fill(x, y, w, h, ch)`), so every "method" here is a plain closure.
--
-- Time is virtual: event.pull(timeout) advances the clock by `timeout`
-- when it has no scripted signal to return, so periodic tasks fire on
-- schedule without real waiting.

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

local function dumpGrid(buf)
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

local function newGpu(maxW, maxH, opts, address, screen)
  local state = {
    screen = screen,
    maxW = maxW, maxH = maxH,
    w = maxW, h = maxH,
    fg = 0xFFFFFF, bg = 0x000000,
    active = 0,
    buffers = { [0] = { w = maxW, h = maxH, grid = newGrid(maxW, maxH) } },
    nextBuf = 1,
    calls = 0,
    lastFrame = nil,
  }

  local gpu = { type = "gpu", address = address }
  local function count() state.calls = state.calls + 1 end

  function gpu.getScreen() return state.screen end

  function gpu.maxResolution() return state.maxW, state.maxH end
  function gpu.getResolution() return state.w, state.h end

  function gpu.setResolution(w, h)
    count()
    state.w, state.h = w, h
    state.buffers[0] = { w = w, h = h, grid = newGrid(w, h) }
    return true
  end

  function gpu.setBackground(c) count(); local old = state.bg; state.bg = c; return old end
  function gpu.setForeground(c) count(); local old = state.fg; state.fg = c; return old end
  function gpu.getBackground() return state.bg end
  function gpu.getForeground() return state.fg end

  function gpu.getActiveBuffer() return state.active end
  function gpu.setActiveBuffer(i)
    assert(state.buffers[i], "setActiveBuffer: no such buffer " .. tostring(i))
    state.active = i
    return i
  end

  if not opts.noVram then
    function gpu.allocateBuffer(w, h)
      w = w or state.w
      h = h or state.h
      local idx = state.nextBuf
      state.nextBuf = state.nextBuf + 1
      state.buffers[idx] = { w = w, h = h, grid = newGrid(w, h) }
      return idx
    end
  else
    function gpu.allocateBuffer() return nil, "not enough video memory" end
  end

  function gpu.freeBuffer(i)
    i = i or state.active
    if i == 0 then return false end
    state.buffers[i] = nil
    if state.active == i then state.active = 0 end
    return true
  end

  function gpu.fill(x, y, w, h, char)
    count()
    local buf = state.buffers[state.active]
    -- A full-screen fill on the screen starts a new frame (no-VRAM path) or
    -- is the exit-time clear: snapshot what was shown just before it.
    if state.active == 0 and x == 1 and y == 1 and w >= buf.w and h >= buf.h then
      state.lastFrame = dumpGrid(buf)
    end
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

  -- One grid cell per Unicode codepoint, as on a real screen.
  function gpu.set(x, y, str, vertical)
    count()
    local buf = state.buffers[state.active]
    local col, rowIdx = x, y
    for _, code in utf8.codes(str) do
      local row = buf.grid[rowIdx]
      if row and row[col] then
        row[col] = { ch = utf8.char(code), fg = state.fg, bg = state.bg }
      end
      if vertical then rowIdx = rowIdx + 1 else col = col + 1 end
    end
    return true
  end

  function gpu.bitblt(dst, col, row, w, h, src, fromCol, fromRow)
    count()
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
    if dst == 0 then state.lastFrame = dumpGrid(db) end
    return true
  end

  function gpu.bind(screenAddress)
    state.screen = screenAddress
    return true
  end

  -- Test helpers (not part of the real GPU API).
  function gpu._calls() return state.calls end
  -- The last complete frame shown before the app cleared the screen.
  function gpu._lastFrame() return state.lastFrame end
  function gpu._screen() return dumpGrid(state.buffers[0]) end

  return gpu
end

-- ------------------------------------------------------- fake me_interface --

-- cpuDefs[i] = {
--   name, storage, coprocessors,
--   output = {name, label, size} or nil (simulates a missing Crafting Monitor),
--   work = total work units of the job, rate = units finished per second,
--   startAt = clock time the job started (default 0),
--   activeChunk = units "in machines" at any time (default 8),
-- } -- or { name, storage, coprocessors } for an idle CPU.
local function newMeInterface(cpuDefs, clock)
  local me = { type = "me_interface" }

  local function remaining(def)
    if not def.work then return 0 end
    local elapsed = clock() - (def.startAt or 0)
    return math.max(def.work - math.floor((def.rate or 0) * elapsed), 0)
  end

  function me.getCpus()
    local out = {}
    for _, def in ipairs(cpuDefs) do
      local busy = remaining(def) > 0
      local cpu = {}
      function cpu.isBusy() return remaining(def) > 0 end
      function cpu.isActive() return true end
      function cpu.cancel() def.work = nil; return true end
      function cpu.finalOutput()
        if remaining(def) == 0 or not def.output then
          return nil, "No crafting monitor"
        end
        return { name = def.output.name, label = def.output.label, size = def.output.size }
      end
      function cpu.activeItems()
        local r = remaining(def)
        if r == 0 then return {} end
        return { { name = "x:active", label = "Active", size = math.min(def.activeChunk or 8, r) } }
      end
      function cpu.pendingItems()
        local r = remaining(def)
        local active = math.min(def.activeChunk or 8, r)
        if r - active <= 0 then return {} end
        -- split across two item types to exercise summing
        local a = math.floor((r - active) / 2)
        return {
          { name = "x:a", label = "A", size = a },
          { name = "x:b", label = "B", size = r - active - a },
        }
      end
      function cpu.storedItems() return {} end

      table.insert(out, {
        name = def.name,
        storage = def.storage,
        coprocessors = def.coprocessors,
        busy = busy,
        cpu = cpu,
      })
    end
    return out
  end

  return me
end

-- --------------------------------------------------------- fake LSC (gt) --

local function group(n, sep)
  local s = string.format("%d", n)
  local out = s:reverse():gsub("(%d%d%d)", "%1" .. sep:reverse()):reverse()
  if out:sub(1, #sep) == sep then out = out:sub(#sep + 1) end
  return out
end

-- def = { stored, capacity (integers), net = EU/t (integer),
--         avgIn, avgOut, lang = "en"|"ru", maintenanceOk, wireless,
--         wirelessEU, noSensor, noStringMethods }
local function newLsc(def, clock)
  local lsc = { type = "gt_machine" }
  local function storedNow()
    local s = def.stored + math.floor(def.net * 20 * clock())
    if s < 0 then s = 0 end
    if s > def.capacity then s = def.capacity end
    return s
  end

  function lsc.getName() return "multimachine.supercapacitor" end
  function lsc.getEUStored() return storedNow() end
  function lsc.getEUMaxStored() return def.capacity end
  if not def.noStringMethods then
    function lsc.getStoredEUString() return string.format("%d", storedNow()) end
    function lsc.getEUCapacityString() return string.format("%d", def.capacity) end
  end

  if not def.noSensor then
    function lsc.getSensorInformation()
      local ru = def.lang == "ru"
      local sep = ru and "\194\160" or ","
      local S = "\194\167"
      local avgIn = group(def.avgIn or 0, sep)
      local avgOut = group(def.avgOut or 0, sep)
      local maint = def.maintenanceOk == false
        and (S .. "c" .. (ru and "Есть проблемы" or "Has Problems") .. S .. "r")
        or (S .. "a" .. (ru and "Работает отлично" or "Working perfectly") .. S .. "r")
      local wl = def.wireless
        and (S .. "a" .. (ru and "включён" or "enabled") .. S .. "r")
        or (S .. "c" .. (ru and "отключён" or "disabled") .. S .. "r")
      local wEU = group(def.wirelessEU or 0, sep)
      local lines = {
        S .. "eOperational Data:" .. S .. "r",
        "EU Stored: " .. group(storedNow(), sep) .. " EU",
        "EU Stored: 1.23E17 EU",
        "Used Capacity: 12.34%",
        "Total Capacity: " .. group(def.capacity, sep) .. " EU",
        "Total Capacity: 4.56E18 EU",
        "Passive Loss: 1" .. sep .. "000 EU/t",
        "EU IN: 1.23M EU/t",
        "EU OUT: 4.56M EU/t",
        ru and ("Средний ввод EU: " .. avgIn .. " (последние 5 секунд)")
           or ("Avg EU IN: " .. avgIn .. " (last 5 seconds)"),
        ru and ("Средний вывод EU: " .. avgOut .. " (последние 5 секунд)")
           or ("Avg EU OUT: " .. avgOut .. " (last 5 seconds)"),
        "Avg EU IN: 1 (last 5 minutes)",
        "Avg EU OUT: 1 (last 5 minutes)",
        "Avg EU IN: 1 (last 1 hour)",
        "Avg EU OUT: 1 (last 1 hour)",
        "Time to Full: 3 hours",
        (ru and "Статус техобслуживания: " or "Maintenance Status: ") .. maint,
        (ru and "Беспроводной режим: " or "Wireless mode: ") .. wl,
        S .. "9UHV" .. S .. "r Capacitors detected: 4",
        S .. "9UEV" .. S .. "r Capacitors detected: 0",
        S .. "9UIV" .. S .. "r Capacitors detected: 0",
        S .. "9UMV" .. S .. "r Capacitors detected: 0",
        "Total wireless EU: " .. S .. "c" .. wEU .. " EU",
        "Total wireless EU: " .. S .. "c1.0E20 EU",
      }
      -- a moving average that drifts with time, so the graph has shape
      if def.wobble then
        local v = math.floor(def.avgOut + def.wobble * math.sin(clock() / 3))
        lines[11] = "Avg EU OUT: " .. group(math.max(v, 0), sep) .. " (last 5 seconds)"
      end
      return lines
    end
  end
  return lsc
end

-- ------------------------------------------------------------ fake glasses --

local function newGlasses()
  local g = { type = "glasses" }
  local widgets = {}
  local state = { packets = 0, lastSnapshot = nil }

  local function snapshot()
    local copy = {}
    for _, w in ipairs(widgets) do
      local c = {}
      for k, v in pairs(w.s) do c[k] = v end
      table.insert(copy, c)
    end
    return copy
  end

  local function add(kind)
    local w = { s = { kind = kind, x = 0, y = 0, a = 0, b = 0, r = 1, g = 1, bl = 1,
      alpha = 1, visible = true, text = "", scale = 1 } }
    local function upd() state.packets = state.packets + 1 end
    w.setPosition = function(x, y) w.s.x, w.s.y = x, y; upd() end
    w.setColor = function(r, gg, b)
      assert(r >= 0 and r <= 1 and gg >= 0 and gg <= 1 and b >= 0 and b <= 1, "color out of 0..1")
      w.s.r, w.s.g, w.s.bl = r, gg, b; upd()
    end
    w.setAlpha = function(a) w.s.alpha = a; upd() end
    w.setVisible = function(v) assert(type(v) == "boolean"); w.s.visible = v; upd() end
    w.getID = function() return #widgets end
    if kind == "rect" then
      -- OCGlasses semantics: first arg = vertical extent, second = horizontal
      w.setSize = function(a, b) w.s.a, w.s.b = a, b; upd() end
    else
      w.setText = function(t) assert(type(t) == "string"); w.s.text = t; upd() end
      w.setScale = function(s) w.s.scale = s; upd() end
    end
    table.insert(widgets, w)
    return w
  end

  function g.addRect() return add("rect") end
  function g.addTextLabel() return add("text") end
  function g.removeAll()
    if #widgets > 0 then state.lastSnapshot = snapshot() end
    widgets = {}
  end
  function g.getObjectCount() return #widgets end

  function g._state() return state end
  function g._snapshot() return snapshot() end
  return g
end

-- Rasterizes a glasses snapshot to ASCII: 3x4 GUI px per cell. Rects use a
-- char chosen from colorChars[hex] ('#' if unmapped, skipped if mapped to
-- false); text is overlaid at ~2 cells per character. Returns the ASCII
-- art plus the list of visible strings.
function M.renderGlasses(snapshot, colorChars, cols, rows)
  cols, rows = cols or 70, rows or 40
  local grid = {}
  for y = 1, rows do
    grid[y] = {}
    for x = 1, cols do grid[y][x] = " " end
  end
  local texts = {}
  for _, w in ipairs(snapshot or {}) do
    if w.visible then
      local hex = math.floor(w.r * 255 + 0.5) * 65536 + math.floor(w.g * 255 + 0.5) * 256
        + math.floor(w.bl * 255 + 0.5)
      if w.kind == "rect" then
        local ch = colorChars[hex]
        if ch == nil then ch = "#" end
        if ch then
          local width, height = w.b, w.a -- horizontal = 2nd setSize arg
          local x0 = math.floor(w.x / 3) + 1
          local x1 = math.floor((w.x + width - 0.01) / 3) + 1
          local y0 = math.floor(w.y / 4) + 1
          local y1 = math.floor((w.y + height - 0.01) / 4) + 1
          for y = y0, y1 do
            for x = x0, x1 do
              if grid[y] and grid[y][x] then grid[y][x] = ch end
            end
          end
        end
      elseif w.text ~= "" then
        table.insert(texts, string.format("(%5.1f,%5.1f) %s", w.x, w.y, w.text))
        local x = math.floor(w.x / 3) + 1
        local y = math.floor((w.y + 3) / 4) + 1
        for _, code in utf8.codes(w.text) do
          if grid[y] and grid[y][x] then grid[y][x] = utf8.char(code) end
          x = x + 2
        end
      end
    end
  end
  local lines = {}
  for y = 1, rows do lines[y] = table.concat(grid[y]) end
  return table.concat(lines, "\n"), texts
end

-- ---------------------------------------------------------------- module --

-- opts: maxW, maxH, noVram, cpus (me_interface defs; nil = no ME),
--       lsc (def; nil = none), glasses (count, default 0),
--       events (scripted signals, consumed one per pull; `false` = let the
--       pull time out), maxPulls (then 'q' is pressed).
function M.new(opts)
  opts = opts or {}
  local clock = 1000 -- uptime starts at an arbitrary non-zero value
  local function now() return clock end

  local gpus = {}
  for i = 1, opts.gpus or 1 do
    gpus[i] = newGpu(opts.maxW or 80, opts.maxH or 25, opts, "gpu-" .. i, "screen-" .. i)
  end
  local gpu = gpus[1]
  local comps = {}
  local byType = {}
  local function register(proxy, address)
    proxy.address = address
    comps[address] = proxy
    byType[proxy.type] = byType[proxy.type] or {}
    table.insert(byType[proxy.type], proxy)
  end

  for _, g in ipairs(gpus) do register(g, g.address) end

  if opts.cpus then
    for _, def in ipairs(opts.cpus) do def.startAt = (def.startAt or 0) + clock end
    register(newMeInterface(opts.cpus, now), "me-1")
  end
  if opts.lsc then
    -- LSC energy curve is defined relative to program start
    local def = opts.lsc
    local t0 = clock
    register(newLsc(def, function() return now() - t0 end), "lsc-1")
  end
  local glassesList = {}
  for i = 1, opts.glasses or 0 do
    local g = newGlasses()
    register(g, "glasses-" .. i)
    table.insert(glassesList, g)
  end

  local component = {}
  setmetatable(component, { __index = function(_, k)
    local list = byType[k]
    return list and list[1] or nil
  end })
  function component.proxy(address) return comps[address] end
  function component.list(filter, exact)
    local results = {}
    for t, list in pairs(byType) do
      local match = filter == nil or (exact and t == filter) or (not exact and t:find(filter, 1, true))
      if match then
        for _, p in ipairs(list) do table.insert(results, { p.address or t, t }) end
      end
    end
    local i = 0
    return function()
      i = i + 1
      if results[i] then return results[i][1], results[i][2] end
    end
  end

  local queue = {}   -- signals from computer.pushSignal, delivered first
  local pushed = {}  -- every pushed signal, for assertions
  local computer = { uptime = now }
  function computer.pushSignal(...)
    local sig = table.pack(...)
    table.insert(queue, sig)
    table.insert(pushed, sig)
    return true
  end

  local pulls = 0
  local scriptIndex = 0 -- separate from `pulls`: queued pushSignals don't consume the script
  local script = opts.events or {}
  local maxPulls = opts.maxPulls or #script
  local endSignal = opts.endSignal or { "key_down", "kb", 113, 16, "player" } -- 'q'
  local event = {}

  local function matches(sig, filters)
    for i = 1, filters.n do
      if filters[i] ~= nil and sig[i] ~= filters[i] then return false end
    end
    return true
  end

  -- event.pull(timeout, [name, ...]) with OpenOS-style positional filters.
  -- Unfiltered pulls take queued pushSignals first, then the script; a
  -- `false` script entry (or running past it) is a timeout. After
  -- maxPulls, endSignal is returned (quit), and a loop that still doesn't
  -- stop is aborted.
  function event.pull(timeout, ...)
    local filters = table.pack(...)
    pulls = pulls + 1
    if pulls > maxPulls + 200 then
      error("mock: event loop did not stop after the end signal")
    end
    if filters.n > 0 then
      for i, sig in ipairs(queue) do
        if matches(sig, filters) then
          table.remove(queue, i)
          clock = clock + 0.05
          return table.unpack(sig, 1, sig.n)
        end
      end
      clock = clock + (timeout or 1)
      return nil
    end
    if #queue > 0 then
      local sig = table.remove(queue, 1)
      clock = clock + 0.05
      return table.unpack(sig, 1, sig.n)
    end
    if pulls > maxPulls then
      return table.unpack(endSignal)
    end
    scriptIndex = scriptIndex + 1
    local ev = script[scriptIndex]
    -- a function entry computes its signal at pull time (e.g. a touch on
    -- wherever a button is currently drawn); it may return false = timeout
    if type(ev) == "function" then ev = ev() end
    if ev then
      clock = clock + 0.05
      return table.unpack(ev)
    end
    clock = clock + (timeout or 1)
    return nil
  end

  -- In-memory storage backend for ocui.storage.
  local files = {}
  local storage = {}
  function storage.read(path) return files[path] end
  function storage.write(path, text) files[path] = text; return true end
  function storage.append(path, text) files[path] = (files[path] or "") .. text; return true end
  function storage.ensureDir() end
  function storage.exists(path) return files[path] ~= nil end

  local extraApps = opts.extraApps or {}
  local filesystem = {}
  function filesystem.isDirectory(dir) return dir:match("ocui/apps$") ~= nil end
  function filesystem.list(dir)
    local names = { "dashboard.lua", "hud.lua", "hudctl.lua" }
    for _, n in ipairs(extraApps) do table.insert(names, n .. ".lua") end
    local i = 0
    return function() i = i + 1; return names[i] end
  end
  function filesystem.exists(path) return files[path] ~= nil end

  local tty = { screen = function() return opts.shellScreen or "screen-1" end }

  local threads = {}
  local thread = {}
  function thread.create(fn, ...)
    local t = { detached = false }
    function t.detach(self) self.detached = true; return self end
    table.insert(threads, t)
    fn(...) -- runs to completion: the scripted events end the loop
    return t
  end

  return {
    component = component,
    computer = computer,
    event = event,
    storage = storage,
    files = files,
    filesystem = filesystem,
    tty = tty,
    thread = thread,
    threads = threads,
    pushed = pushed,
    gpu = gpu,
    gpus = gpus,
    glasses = glassesList,
    pulls = function() return pulls end,
    clock = now,
  }
end

return M
