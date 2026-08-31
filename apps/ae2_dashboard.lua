-- apps/ae2_dashboard.lua
--
-- Deploy: copy the ocui/ directory to /lib/ocui on the OC computer, then
-- this file anywhere (e.g. /home/ae2_dashboard.lua) and run it.
--
-- Requires: a Tier 2+ GPU bound to a screen, and an Adapter placed next to
-- an ME Interface or ME Controller so component.me_interface (or
-- .me_controller) is available.

local component = require("component")

local App = require("ocui.app")
local base = require("ocui.widget")
local widgets = require("ocui.widgets")
local theme = require("ocui.theme")
local ae2 = require("ocui.ae2")

local me = ae2.find(component)
assert(me, "No ME Interface/Controller found. Attach an Adapter to an ME Interface or ME Controller.")

local root = widgets.VStack.new({ gap = 1 })

local function buildRows(jobs)
  root:clear()
  if #jobs == 0 then
    root:add(widgets.Label.new({ h = 1, text = "No crafting CPUs on this network.", fg = theme.textDim }))
    return
  end
  for _, job in ipairs(jobs) do
    local panel = widgets.Panel.new({
      h = 5, -- border + 3 content rows (info, output, progress) + border
      title = (job.name ~= "" and job.name) or "Crafting CPU",
      borderColor = job.busy and theme.borderFocus or theme.border,
      bg = theme.panel,
    })

    local infoText = string.format(
      "co-processors: %d   storage: %s   %s",
      job.coprocessors or 0,
      ae2.formatBytes(job.storage),
      job.busy and "BUSY" or "idle"
    )
    panel:add(widgets.Label.new({ y = 0, h = 1, text = infoText, fg = theme.textDim }))

    local outputText
    if job.output then
      outputText = string.format("%s x%d", job.output.label or "?", job.output.size or 0)
    elseif job.busy then
      outputText = "..."
    else
      outputText = "no active job"
    end
    panel:add(widgets.Label.new({ y = 1, h = 1, text = outputText, fg = theme.text }))

    panel:add(widgets.ProgressBar.new({
      y = 2, h = 1,
      value = job.progress,
      bg = theme.barBg,
      fg = job.busy and theme.barFg or theme.good,
      label = job.busy and "crafting" or "idle",
    }))

    root:add(panel)
  end
end

local function refresh()
  local ok, jobs = pcall(ae2.getCraftingJobs, me)
  if ok then
    buildRows(jobs)
  else
    root:clear()
    root:add(widgets.Label.new({ h = 1, text = "AE2 read error: " .. tostring(jobs), fg = theme.bad }))
  end
end

refresh()

local app = App.new({
  root = root,
  tickInterval = 2, -- seconds between refreshes; also the touch/key poll timeout
  onTick = refresh,
})

app:start()
