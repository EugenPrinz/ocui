-- ocui.app
-- A screen UI in one call: an ocui.host on one GPU + screen showing one
-- widget tree, plus a periodic refresh.
--
-- Inside a pool app (see ocui.pool):
--   App.new({ root = rootWidget, tickInterval = 2, onTick = refresh,
--             gpu = "<address>", screen = "<address>" }):mount(ctx)
-- Standalone:
--   App.new({ ... }):start()          -- blocks until 'q' / Ctrl+C
--
-- onTick runs every `tickInterval` seconds as a pool task (so it may
-- ctx.yield()/ctx.sleep() mid-work).
--
-- Two ways to keep the screen current:
--   partial = false (default): the whole screen is repainted after every
--     onTick and after every touch/key a widget consumed -- simple, for
--     trees whose widgets are changed by assigning fields directly.
--   partial = true: only what widgets invalidate() is repainted (all the
--     built-in widgets do when changed through their methods) -- much
--     cheaper for interactive apps; app:redraw() still repaints it all.
-- opts.bindings / opts.onKey: key handling for the view (see ocui.host).

local Host = require("ocui.host")

local App = {}
App.__index = App

function App.new(opts)
  opts = opts or {}
  assert(opts.root, "App.new requires opts.root")
  return setmetatable({
    opts = opts,
    root = opts.root,
    background = opts.background or 0x000000,
    tickInterval = opts.tickInterval or 1,
    onTick = opts.onTick,
    partial = opts.partial and true or false,
  }, App)
end

-- Repaints the whole screen (on the next loop round).
function App:redraw()
  if self.host then self.host:damageAll() end
end

-- Claims the GPU and screen, sets up the display, registers the refresh
-- task and input handlers, and restores everything when the app stops.
function App:mount(ctx)
  local host = Host.new({
    gpu = self.opts.gpu,
    screen = self.opts.screen,
    background = self.background,
    redrawOnInput = not self.partial,
  })
  self.host = host
  host:mount(ctx)
  self.view = host:setView({ root = self.root, bindings = self.opts.bindings, onKey = self.opts.onKey })
  self.gpu, self.screenAddress, self.w, self.h = host.gpu, host.screenAddress, host.w, host.h

  if self.onTick or not self.partial then
    ctx:every(self.tickInterval, function()
      if self.onTick then self.onTick() end
      if not self.partial then host:damageAll() end
    end)
  end
  return host
end

-- Runs this screen alone until 'q' / Ctrl+C (or ctx:stop() from a
-- binding when opts.keyboard is set). Errors propagate.
function App:start()
  local Pool = require("ocui.pool")
  Pool.runSingle({
    name = self.opts.name or "app",
    keyboard = self.opts.keyboard,
    start = function(ctx) self:mount(ctx) end,
  })
end

return App
