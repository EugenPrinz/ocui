-- ocui.services.crafting -- polls AE2 crafting CPUs once for every app that
-- uses it (each AE2 call costs a server tick, so sharing matters).
--
--   local crafting = ctx:use("crafting")
--   crafting.latest() -> { jobs, busy, error, found, polledAt }
--     jobs: every CPU (see ocui.ae2 Tracker:poll); busy: only busy ones
-- Publishes the in-process event "crafting_update" (state) after each poll.
-- Config: /etc/ocui/crafting.cfg.

local component = require("component")
local computer = require("computer")

local ae2 = require("ocui.ae2")

local M = {
  name = "crafting",
  description = "AE2 crafting CPU poller (shared by hud, dashboard, ...)",
  defaults = {
    interval = 3, -- seconds between polls; each costs 1 + 3 * <busy CPUs> server ticks
  },
}

function M.start(ctx, cfg)
  local tracker = ae2.newTracker(computer.uptime)
  local state = { jobs = {}, busy = {}, found = false }

  ctx:every(cfg.interval, function()
    local me = ae2.find(component)
    state.found = me ~= nil
    if not me then
      state.jobs, state.busy = {}, {}
      state.error = "ME not found: attach an Adapter"
    else
      -- yield between CPUs so other apps' tasks run during a long poll
      local ok, jobs = pcall(tracker.poll, tracker, me, ctx.yield)
      if ok then
        state.jobs, state.busy, state.error = jobs, ae2.busyOnly(jobs), nil
      else
        state.error = tostring(jobs)
      end
    end
    state.polledAt = computer.uptime()
    ctx:emit("crafting_update", state)
  end)

  return { latest = function() return state end }
end

return M
