-- render3d: a small 3D renderer as a stress test of the screen code --
-- flat-shaded or wireframe meshes rotating on a 160x100 half-block pixel
-- view, with FPS and the estimated GPU budget per frame.
--
--   render3d          (or `ocpool render3d`)
--
-- Keys: 1-4 shape, M mode (solid / wire / both), Space pause, arrows spin,
-- +/- zoom, R reset, Q / Ctrl+Q quit. Drag to rotate, wheel to zoom.

local computer = require("computer")

local Host = require("ocui.host")
local PixelView = require("ocui.pixels")
local theme = require("ocui.theme")
local widgets = require("ocui.widgets")

local M = {
  name = "render3d",
  description = "3D renderer demo / screen stress test",
  keyboard = true,
}

local clock = os and os.clock or function() return 0 end

-- ----------------------------------------------------------------- meshes --

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b)
  return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function centroid(verts, idx)
  local c = { 0, 0, 0 }
  for _, i in ipairs(idx) do
    for k = 1, 3 do c[k] = c[k] + verts[i][k] end
  end
  for k = 1, 3 do c[k] = c[k] / #idx end
  return c
end

-- faces: { idx = {...}, color = 0xRRGGBB, ref = point inside the solid
-- (default origin) } -- winding is fixed so normals point away from ref.
local function mesh(name, verts, faces)
  local edges, seen = {}, {}
  for _, f in ipairs(faces) do
    local idx = f.idx
    local n = cross(sub(verts[idx[2]], verts[idx[1]]), sub(verts[idx[3]], verts[idx[1]]))
    if dot(n, sub(centroid(verts, idx), f.ref or { 0, 0, 0 })) < 0 then
      local rev = {}
      for i = #idx, 1, -1 do rev[#rev + 1] = idx[i] end
      f.idx = rev
    end
    idx = f.idx
    for i = 1, #idx do
      local a, b = idx[i], idx[i % #idx + 1]
      local key = math.min(a, b) .. ":" .. math.max(a, b)
      if not seen[key] then
        seen[key] = true
        edges[#edges + 1] = { a, b }
      end
    end
  end
  local tris = 0
  for _, f in ipairs(faces) do tris = tris + #f.idx - 2 end
  return { name = name, verts = verts, faces = faces, edges = edges, tris = tris }
end

local function cube()
  local v = {}
  for i = 0, 7 do
    v[i + 1] = { (i % 2 == 0) and -1 or 1, (math.floor(i / 2) % 2 == 0) and -1 or 1,
      (math.floor(i / 4) == 0) and -1 or 1 }
  end
  return mesh("cube", v, {
    { idx = { 1, 2, 4, 3 }, color = 0xE0574C }, { idx = { 5, 6, 8, 7 }, color = 0x4CD787 },
    { idx = { 1, 2, 6, 5 }, color = 0x4C8BF5 }, { idx = { 3, 4, 8, 7 }, color = 0xE0B341 },
    { idx = { 1, 3, 7, 5 }, color = 0xC060E0 }, { idx = { 2, 4, 8, 6 }, color = 0x40D0D0 },
  })
end

local function pyramid()
  local v = { { -1, -0.8, -1 }, { 1, -0.8, -1 }, { 1, -0.8, 1 }, { -1, -0.8, 1 }, { 0, 1.2, 0 } }
  return mesh("pyramid", v, {
    { idx = { 1, 2, 3, 4 }, color = 0xE0B341 },
    { idx = { 1, 2, 5 }, color = 0xE0574C }, { idx = { 2, 3, 5 }, color = 0x4CD787 },
    { idx = { 3, 4, 5 }, color = 0x4C8BF5 }, { idx = { 4, 1, 5 }, color = 0xC060E0 },
  })
end

local function octahedron()
  local s = 1.3
  local v = { { s, 0, 0 }, { -s, 0, 0 }, { 0, s, 0 }, { 0, -s, 0 }, { 0, 0, s }, { 0, 0, -s } }
  local colors = { 0xE0574C, 0x4CD787, 0x4C8BF5, 0xE0B341, 0xC060E0, 0x40D0D0, 0xE08040, 0xA0A0F0 }
  local faces, k = {}, 0
  for _, x in ipairs({ 1, 2 }) do
    for _, y in ipairs({ 3, 4 }) do
      for _, z in ipairs({ 5, 6 }) do
        k = k + 1
        faces[k] = { idx = { x, y, z }, color = colors[k] }
      end
    end
  end
  return mesh("octahedron", v, faces)
end

local function torus()
  local R, r, nu, nv = 1.0, 0.42, 16, 8
  local v, faces = {}, {}
  local function id(i, j) return (i % nu) * nv + (j % nv) + 1 end
  for i = 0, nu - 1 do
    local u = i / nu * 2 * math.pi
    for j = 0, nv - 1 do
      local w = j / nv * 2 * math.pi
      v[id(i, j)] = { (R + r * math.cos(w)) * math.cos(u), r * math.sin(w), (R + r * math.cos(w)) * math.sin(u) }
    end
  end
  for i = 0, nu - 1 do
    local u = (i + 0.5) / nu * 2 * math.pi
    for j = 0, nv - 1 do
      faces[#faces + 1] = {
        idx = { id(i, j), id(i + 1, j), id(i + 1, j + 1), id(i, j + 1) },
        color = (i + j) % 2 == 0 and 0x4C8BF5 or 0x40D0D0,
        ref = { R * math.cos(u), 0, R * math.sin(u) }, -- the tube's center line
      }
    end
  end
  return mesh("torus", v, faces)
end

M.SHAPES = { cube, pyramid, octahedron, torus }
M.MODES = { "solid", "wire", "both" }

-- --------------------------------------------------------------- renderer --

local LIGHT = (function()
  local l = { -0.5, 0.7, -0.6 }
  local n = math.sqrt(dot(l, l))
  return { l[1] / n, l[2] / n, l[3] / n }
end)()

local function shade(color, k)
  local r = math.floor(color / 65536) % 256
  local g = math.floor(color / 256) % 256
  local b = color % 256
  return PixelView.quantize(math.min(r * k, 255), math.min(g * k, 255), math.min(b * k, 255))
end

-- Draws `m` rotated by (ax, ay) into `view`; returns triangles drawn.
local function render(view, m, ax, ay, zoom, mode)
  local pw, ph = view.pw, view.ph
  local cx, cy = pw / 2, ph / 2
  local dist = 4.5
  local f = ph * 0.9 * zoom
  local ca, sa, cb, sb = math.cos(ax), math.sin(ax), math.cos(ay), math.sin(ay)
  local tv, pv = {}, {}
  for i, p in ipairs(m.verts) do
    -- rotate around Y, then X
    local x = p[1] * cb + p[3] * sb
    local z = -p[1] * sb + p[3] * cb
    local y = p[2] * ca - z * sa
    z = p[2] * sa + z * ca + dist
    tv[i] = { x, y, z }
    pv[i] = { cx + x * f / z, cy - y * f / z }
  end

  local tris = 0
  if mode ~= "wire" then
    local visible = {}
    for _, face in ipairs(m.faces) do
      local idx = face.idx
      local a, b, c = tv[idx[1]], tv[idx[2]], tv[idx[3]]
      local n = cross(sub(b, a), sub(c, a))
      local center = centroid(tv, idx)
      if dot(n, center) < 0 then -- facing the camera at the origin
        local len = math.sqrt(dot(n, n))
        local light = len > 0 and dot(n, LIGHT) / len or 0
        visible[#visible + 1] = { face = face, depth = center[3],
          color = shade(face.color, 0.3 + 0.8 * math.max(light, 0)) }
      end
    end
    table.sort(visible, function(p, q) return p.depth > q.depth end)
    for _, item in ipairs(visible) do
      local idx = item.face.idx
      local p0 = pv[idx[1]]
      for k = 2, #idx - 1 do
        local p1, p2 = pv[idx[k]], pv[idx[k + 1]]
        view:fillTriangle(p0[1], p0[2], p1[1], p1[2], p2[1], p2[2], item.color)
        tris = tris + 1
      end
      if mode == "both" then
        for k = 1, #idx do
          local p, q = pv[idx[k]], pv[idx[k % #idx + 1]]
          view:line(p[1], p[2], q[1], q[2], 0xFFFFFF)
        end
      end
    end
  else
    for _, e in ipairs(m.edges) do
      local p, q = pv[e[1]], pv[e[2]]
      -- nearer edges brighter
      local z = (tv[e[1]][3] + tv[e[2]][3]) / 2
      local k = math.max(math.min((6 - z) / 3, 1), 0.25)
      view:line(p[1], p[2], q[1], q[2], shade(0xFFFFFF, k))
    end
  end
  return tris
end

-- ------------------------------------------------------------------- app --

function M.start(ctx, cfg)
  local host = Host.forApp(ctx, { gpu = cfg.gpu, screen = cfg.screen, background = 0x000000, title = "3D" })
  M.host = host

  local state = {
    shape = 1, mode = 1, ax = 0.5, ay = 0.6, vx = 0.6, vy = 1.0,
    zoom = 1, paused = false,
  }
  local meshes = {}
  local function currentMesh()
    meshes[state.shape] = meshes[state.shape] or M.SHAPES[state.shape]()
    return meshes[state.shape]
  end

  local root = widgets.VBox.new({})
  local view = root:add(PixelView.new({ flex = 1, bg = 0x000000 }))
  M.view = view
  local status = root:add(widgets.StatusBar.new({
    hints = {
      { key = "1-4", label = "Shape" }, { key = "M", label = "Mode" }, { key = "Spc", label = "Pause" },
      { key = "\226\134\144\226\134\145\226\134\146\226\134\147", label = "Spin" }, -- ←↑→↓
      { key = "+-", label = "Zoom" }, { key = "R", label = "Reset" }, { key = "Q", label = "Quit" },
    },
  }))

  -- drag to rotate, wheel to zoom
  function view:onTouch(x, y) self.dragFrom = { x, y }; return true end
  function view:onDrag(x, y)
    local from = self.dragFrom
    if from then
      state.ay = state.ay + (x - from[1]) * 0.06
      state.ax = state.ax + (y - from[2]) * 0.12
      self.dragFrom = { x, y }
    end
    return true
  end
  function view:onDrop() self.dragFrom = nil; return true end
  function view:onScroll(_, _, dir)
    state.zoom = math.max(0.3, math.min(state.zoom * (dir > 0 and 1.1 or 1 / 1.1), 3))
    return true
  end

  local function quit() ctx:stop() end
  local keys = {
    q = quit, ["ctrl+q"] = quit, escape = quit,
    space = function() state.paused = not state.paused end,
    m = function() state.mode = state.mode % #M.MODES + 1 end,
    r = function()
      state.ax, state.ay, state.vx, state.vy, state.zoom, state.paused = 0.5, 0.6, 0.6, 1.0, 1, false
    end,
    left = function() state.vy = state.vy - 0.4 end,
    right = function() state.vy = state.vy + 0.4 end,
    up = function() state.vx = state.vx - 0.4 end,
    down = function() state.vx = state.vx + 0.4 end,
  }
  for i = 1, #M.SHAPES do keys[tostring(i)] = function() state.shape = i end end
  host:setView({
    root = root,
    onKey = function(ev)
      if ev.text == "+" or ev.text == "=" then state.zoom = math.min(state.zoom * 1.15, 3); return true end
      if ev.text == "-" then state.zoom = math.max(state.zoom / 1.15, 0.3); return true end
      local fn = keys[ev.combo]
      if fn then fn(); return true end
      return false
    end,
  })

  -- frame loop: render as fast as the computer allows (one frame per pull)
  local stats = { frames = 0, raster = 0, draw = 0, cost = 0, since = computer.uptime() }
  M.stats = stats
  local last = computer.uptime()
  local tris = 0
  ctx:spawn(function()
    while true do
      local now = computer.uptime()
      local dt = math.min(now - last, 0.5)
      last = now
      if not state.paused then
        state.ax = state.ax + state.vx * dt
        state.ay = state.ay + state.vy * dt
      end
      local t0 = clock()
      view:begin()
      tris = render(view, currentMesh(), state.ax, state.ay, state.zoom, M.MODES[state.mode])
      view:finish()
      stats.raster = stats.raster + (clock() - t0)
      stats.frames = stats.frames + 1
      M.frames = (M.frames or 0) + 1
      ctx.sleep(0)
    end
  end)

  -- repaint numbers (from the host) and a once-a-second status line
  local lastCost = host.stats.totalCost
  local seenFrames = host.frames
  ctx:idle(function()
    if host.frames ~= seenFrames then -- runs before the repaint: count the last one
      seenFrames = host.frames
      stats.draw = stats.draw + host.stats.cpu
    end
  end)
  ctx:every(1, function()
    local now = computer.uptime()
    local span = math.max(now - stats.since, 1e-6)
    local n = math.max(stats.frames, 1)
    local cost = host.stats.totalCost - lastCost
    lastCost = host.stats.totalCost
    M.fps = stats.frames / span
    M.costPerFrame = cost / n
    status:setRight(string.format("%s %s  %d tris  %.1f FPS  raster %.1f + draw %.1f ms  ~%.2f budget/frame",
      currentMesh().name, M.MODES[state.mode], tris, M.fps, stats.raster * 1000 / n,
      stats.draw * 1000 / n, M.costPerFrame))
    stats.frames, stats.raster, stats.draw, stats.since = 0, 0, 0, now
  end)
end

return M
