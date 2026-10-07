-- ocui.app
-- A screen UI: owns one GPU + screen, a double-buffered back buffer, and
-- redraws a widget tree.
--
-- Inside a pool app (see ocui.pool):
--   App.new({ root = rootWidget, tickInterval = 2, onTick = refresh,
--             gpu = "<address>", screen = "<address>" }):mount(ctx)
-- Standalone:
--   App.new({ ... }):start()          -- blocks until 'q' / Ctrl+C
--
-- onTick runs every `tickInterval` seconds as a pool task (so it may
-- ctx.yield()/ctx.sleep() mid-work) and the screen is redrawn right after
-- it, and after every touch on *this* screen that a widget consumed.

local component = require("component")

local Canvas = require("ocui.canvas")

local App = {}
App.__index = App

-- opts.gpu / opts.screen: component addresses (or a gpu proxy for opts.gpu);
-- default: the primary GPU and whatever screen it is bound to.
function App.new(opts)
  opts = opts or {}
  assert(opts.root, "App.new requires opts.root")
  return setmetatable({
    opts = opts,
    root = opts.root,
    background = opts.background or 0x000000,
    tickInterval = opts.tickInterval or 1,
    onTick = opts.onTick,
  }, App)
end

-- Allocates an off-screen VRAM buffer to draw into. Falls back to drawing
-- straight onto the screen (buffer 0) if the GPU has no free video memory.
local function allocateBackBuffer(gpu, w, h)
  if not gpu.allocateBuffer then return 0 end
  local ok, buf = pcall(gpu.allocateBuffer, w, h)
  if ok and type(buf) == "number" and buf > 0 then
    return buf
  end
  return 0
end

function App:redraw()
  local gpu, buf, w, h = self.gpu, self.buffer, self.w, self.h
  if buf ~= 0 then gpu.setActiveBuffer(buf) end
  local canvas = Canvas.new(gpu, 0, 0, w, h)
  canvas:fillRect(0, 0, w, h, self.background)
  canvas.bg = self.background
  self.root:draw(canvas)
  if buf ~= 0 then
    gpu.setActiveBuffer(0)
    gpu.bitblt(0, 1, 1, w, h, buf, 1, 1)
  end
end

local function resolveGpu(spec)
  if type(spec) == "table" then return spec end
  if type(spec) == "string" then
    local proxy = component.proxy(spec)
    assert(proxy, "GPU not found: " .. spec)
    return proxy
  end
  local gpu = component.gpu
  assert(gpu, "no GPU found")
  return gpu
end

-- Claims the GPU and screen, sets up the display, registers the refresh
-- task and touch handler, and restores everything when the app stops.
function App:mount(ctx)
  local gpu = resolveGpu(self.opts.gpu)
  if self.opts.screen then
    gpu.bind(self.opts.screen)
  end
  local screen = gpu.getScreen and gpu.getScreen() or nil
  assert(screen, "the GPU is not bound to a screen")

  assert(ctx:claim("gpu:" .. tostring(gpu.address)))
  assert(ctx:claim("screen:" .. screen))

  self.gpu = gpu
  self.screenAddress = screen
  local prevW, prevH = gpu.getResolution()
  gpu.setResolution(gpu.maxResolution())
  self.w, self.h = gpu.getResolution()
  self.root.x, self.root.y = 0, 0
  self.root.w, self.root.h = self.w, self.h
  self.buffer = allocateBackBuffer(gpu, self.w, self.h)

  ctx:onStop(function()
    if self.buffer ~= 0 then
      gpu.setActiveBuffer(0)
      gpu.freeBuffer(self.buffer)
      self.buffer = 0
    end
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, self.w, self.h, " ")
    if prevW and prevH then
      gpu.setResolution(prevW, prevH)
    end
  end)

  ctx:every(self.tickInterval, function()
    if self.onTick then self.onTick() end
    self:redraw()
  end)

  ctx:on("touch", function(_, screenAddress, x, y, button)
    if screenAddress ~= self.screenAddress then return end
    if self.root:onTouch(x - 1, y - 1, button) then
      self:redraw()
    end
  end)
end

-- Runs this screen alone until 'q' / Ctrl+C. Errors propagate.
function App:start()
  local Pool = require("ocui.pool")
  Pool.runSingle({
    name = self.opts.name or "app",
    start = function(ctx) self:mount(ctx) end,
  })
end

return App
