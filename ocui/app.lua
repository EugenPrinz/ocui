-- ocui.app
-- Owns the GPU, the double-buffered back buffer, and the draw/event loop.
-- Usage:
--   local App = require("ocui.app")
--   local app = App.new({ root = myRootWidget, tickInterval = 1, onTick = refresh })
--   app:start()

local component = require("component")
local event = require("event")

local Canvas = require("ocui.canvas")

local App = {}
App.__index = App

function App.new(opts)
  opts = opts or {}
  assert(opts.root, "App.new requires opts.root")
  local self = setmetatable({}, App)
  self.gpu = opts.gpu or component.gpu
  if opts.screen then
    self.gpu.bind(opts.screen)
  end
  self.root = opts.root
  self.tickInterval = opts.tickInterval or 1
  self.onTick = opts.onTick
  self.onEvent = opts.onEvent
  self.running = false
  return self
end

-- Runs the draw/event loop until :stop() is called, 'q' is pressed, or the
-- program is interrupted. GPU state (resolution, colors, buffers) is
-- restored on the way out even if the loop body errors.
function App:start()
  local gpu = self.gpu
  local mw, mh = gpu.maxResolution()
  local prevW, prevH = gpu.getResolution()
  gpu.setResolution(mw, mh)
  local w, h = gpu.getResolution()
  self.root.x, self.root.y = 0, 0
  self.root.w, self.root.h = w, h

  local buf = gpu.allocateBuffer(w, h)
  local backCanvas = Canvas.new(gpu, buf, 0, 0, w, h)

  self.running = true
  local ok, err = pcall(function()
    while self.running do
      gpu.setActiveBuffer(buf)
      gpu.setBackground(0x000000)
      gpu.fill(1, 1, w, h, " ")
      self.root:draw(backCanvas)
      gpu.setActiveBuffer(0)
      gpu.bitblt(0, 1, 1, w, h, buf, 1, 1)

      local signal = { event.pull(self.tickInterval) }
      local name = signal[1]
      if name == "touch" then
        local sx, sy, button = signal[3], signal[4], signal[5]
        self.root:onTouch(sx - 1, sy - 1, button)
      elseif name == "key_down" then
        local char = signal[3]
        if char == 113 then -- 'q'
          self.running = false
        end
      elseif name == "interrupted" then
        self.running = false
      end
      if self.onEvent and name then
        self.onEvent(table.unpack(signal))
      end
      if self.onTick then
        self.onTick()
      end
    end
  end)

  gpu.setActiveBuffer(0)
  gpu.freeBuffer(buf)
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, w, h, " ")
  if prevW and prevH then
    gpu.setResolution(prevW, prevH)
  end

  if not ok then
    error(err, 0)
  end
end

function App:stop()
  self.running = false
end

return App
