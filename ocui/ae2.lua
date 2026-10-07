-- ocui.ae2
-- Data source for AE2 crafting CPUs via the OpenComputers "common network"
-- API (me_interface / me_controller), normalized into plain Lua tables so
-- UI code never touches the raw component proxy.
--
-- API (verified for GTNH 2.8.4 = OpenComputers 1.11.20-GTNH,
-- li/cil/oc/integration/appeng/NetworkControl.scala):
--   me.getCpus() -> array of {name, storage, coprocessors, busy, cpu}
--   entry.cpu.finalOutput()  -> item stack {name, label, size} or nil, err
--                               (needs a Crafting Monitor in the CPU!)
--   entry.cpu.pendingItems() -> stacks still scheduled to be crafted
--   entry.cpu.activeItems()  -> stacks currently being crafted
-- None of these are "direct" callbacks: every call costs one server tick
-- (50 ms), so one poll costs 1 + 3 * <busy CPUs> ticks.
--
-- Progress: AE2 exposes no "% done" for a job, and the final output is
-- pushed straight into the network as it is produced (it never sits in
-- the CPU's storage), so it can't be counted directly. Instead the tracker
-- measures the job's *remaining work*:
--   remaining = sum(pendingItems sizes) + sum(activeItems sizes)
-- which only ever goes down while a job runs (a pushed pattern moves
-- items from pending to active, finished crafts leave active). The
-- largest value seen for the job is its baseline, and
--   progress = 1 - remaining / baseline,   eta = remaining / observed rate
-- Caveats: a job already running when the program starts is measured from
-- the moment it was first seen; progress counts item units, not
-- crafting time, so a step with many cheap items weighs more than one slow
-- step.

local M = {}

-- Finds the first component of type "me_interface" or "me_controller".
function M.find(component)
  return component.me_interface or component.me_controller
end

local function sumSizes(list)
  local total = 0
  if type(list) ~= "table" then return 0 end
  for _, item in ipairs(list) do
    total = total + (tonumber(item.size) or 0)
  end
  return total
end

-- Calls a CPU method, returning nil instead of raising if the cluster went
-- away mid-poll or the AE2 side errors (it has broken across versions).
local function try(fn)
  if fn == nil then return nil end
  local ok, result = pcall(fn)
  if ok then return result end
  return nil
end

local Tracker = {}
Tracker.__index = Tracker

-- clock: function returning seconds (computer.uptime in OC).
function M.newTracker(clock)
  return setmetatable({ clock = clock, jobs = {} }, Tracker)
end

-- Polls every crafting CPU and returns an array (getCpus() order) of:
-- {
--   index, name, coprocessors, storage, busy,
--   output    = { name, label, size } or nil (no Crafting Monitor / idle),
--   remaining = work units left (nil when idle),
--   progress  = 0..1 (1 when idle),
--   eta       = seconds or nil (unknown until some progress is observed),
--   elapsed   = seconds since the job was first seen (nil when idle),
-- }
-- yield (optional): called after each busy CPU's three AE2 calls, e.g.
-- ctx.yield, so other pool tasks can run in the middle of a long poll.
function Tracker:poll(me, yield)
  local seen = {}
  local result = {}

  for index, entry in ipairs(me.getCpus()) do
    local job = {
      index = index,
      name = entry.name,
      coprocessors = entry.coprocessors,
      storage = entry.storage,
      busy = entry.busy,
      progress = 1,
    }

    if entry.busy and entry.cpu then
      local final = try(entry.cpu.finalOutput)
      if type(final) == "table" and final.name then
        job.output = { name = final.name, label = final.label or final.name, size = final.size }
      end

      local remaining = sumSizes(try(entry.cpu.pendingItems)) + sumSizes(try(entry.cpu.activeItems))
      local now = self.clock() -- per CPU: the poll may yield between CPUs
      local identity = job.output and job.output.name or "?"
      local key = tostring(index) .. ":" .. tostring(entry.name)
      local state = self.jobs[key]

      -- Remaining work never grows within one job, so growth (or a new
      -- output item) means the CPU has started a different job.
      if state == nil or state.identity ~= identity or remaining > state.last then
        state = { identity = identity, baseline = remaining, startedAt = now }
      end
      state.last = remaining
      seen[key] = state

      job.remaining = remaining
      job.elapsed = now - state.startedAt
      job.progress = state.baseline > 0 and (1 - remaining / state.baseline) or 0
      local done = state.baseline - remaining
      if done > 0 and job.elapsed > 0 then
        job.eta = remaining * job.elapsed / done
      end
      if yield then yield() end
    end

    table.insert(result, job)
  end

  -- CPUs that went idle (or disappeared) forget their job.
  self.jobs = seen
  return result
end

-- Convenience: only the busy CPUs from a poll, in CPU order.
function M.busyOnly(jobs)
  local out = {}
  for _, job in ipairs(jobs) do
    if job.busy then table.insert(out, job) end
  end
  return out
end

return M
