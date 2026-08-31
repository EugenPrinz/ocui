-- ocui.ae2
-- Data-source wrapper around the AE2 <-> OpenComputers "common network"
-- API (me_interface / me_controller components), normalized into plain
-- Lua tables so UI code never touches the raw component proxy.
--
-- API reference (verified against GTNewHorizons/OpenComputers source,
-- src/main/scala/li/cil/oc/integration/appeng/NetworkControl.scala):
--   me.getCpus() -> array of {name, storage, coprocessors, busy, cpu}
--   entry.cpu.isBusy() / isActive() / cancel()
--   entry.cpu.finalOutput() -> item-stack table (label, name, size) or nil
--   entry.cpu.storedItems() / pendingItems() / activeItems() -> arrays of
--     item-stack tables {name, label, size, ...}
--
-- Caveat: AE2/OC do not expose a real "% done" for a crafting job (see
-- github.com/AppliedEnergistics/Applied-Energistics-2 issue #5220, request
-- for craftingETA/craftingStackSize was never fully implemented upstream).
-- We approximate progress as
--   done / (done + pending + active)
-- counting only items matching the job's final output, which is a
-- reasonable proxy for "how much of the requested stack already exists"
-- but is not an authoritative percentage for multi-step recipe trees.

local M = {}

-- Finds the first component of type "me_interface" or "me_controller".
-- Pass an explicit address if you have more than one and need a specific
-- one (e.g. via sides + component.get, or a saved address).
function M.find(component)
  return component.me_interface or component.me_controller
end

local function sumMatching(list, name)
  local total = 0
  for _, item in ipairs(list) do
    if item.name == name then
      total = total + (item.size or 0)
    end
  end
  return total
end

local KILO = 1024
local UNITS = { "B", "K", "M", "G", "T" }

function M.formatBytes(n)
  n = n or 0
  local i = 1
  while n >= KILO and i < #UNITS do
    n = n / KILO
    i = i + 1
  end
  if i == 1 then
    return string.format("%d%s", n, UNITS[i])
  end
  return string.format("%.1f%s", n, UNITS[i])
end

-- Returns an array of jobs: {
--   name, coprocessors, storage, busy,
--   output = { label, size } or nil,
--   progress = 0..1,
-- }
-- one entry per crafting CPU on the network, in getCpus() order.
function M.getCraftingJobs(me)
  local jobs = {}
  local cpus = me.getCpus()
  for _, entry in ipairs(cpus) do
    local job = {
      name = entry.name,
      coprocessors = entry.coprocessors,
      storage = entry.storage,
      busy = entry.busy,
      output = nil,
      progress = entry.busy and 0 or 1,
    }
    if entry.busy then
      -- finalOutput (and the AE2 tile it reads from) has broken across AE2
      -- versions before, hence the pcall guard.
      local ok, final = pcall(entry.cpu.finalOutput)
      if ok and final then
        job.output = { label = final.label or final.name, size = final.size }
        local done = sumMatching(entry.cpu.storedItems(), final.name)
        local pending = sumMatching(entry.cpu.pendingItems(), final.name)
        local active = sumMatching(entry.cpu.activeItems(), final.name)
        local total = done + pending + active
        job.progress = total > 0 and (done / total) or 0
      end
    end
    table.insert(jobs, job)
  end
  return jobs
end

return M
