-- ocui.apps.dashboard -- AE2 crafting CPUs on a screen.
--
-- Needs: a T2+ GPU + screen, an Adapter next to an ME Interface/Controller,
-- and a Crafting Monitor in each crafting CPU (AE2 only reports what a CPU
-- is crafting through the monitor).
-- Data comes from the shared "crafting" service (one AE2 poll for every
-- app); its poll interval is in /etc/ocui/crafting.cfg.
-- Config: /etc/ocui/dashboard.cfg (created on first run).

local App = require("ocui.app")
local widgets = require("ocui.widgets")
local theme = require("ocui.theme")
local fmt = require("ocui.format")

local M = {
  name = "dashboard",
  description = "AE2 crafting CPUs with progress/ETA on a screen",
  defaults = {
    gpu = false,     -- GPU address, or false for the primary GPU
    screen = false,  -- screen address to bind, or false for the GPU's current one
  },
}

local function progressCaption(job)
  if not job.busy then return "idle" end
  local text = "crafting " .. fmt.percent(job.progress, 0)
  if job.eta then
    text = text .. "  ETA " .. fmt.duration(job.eta)
  elseif job.elapsed and job.elapsed > 0 then
    text = text .. "  measuring..."
  end
  return text
end

local function buildRows(root, jobs)
  root:clear()
  if #jobs == 0 then
    root:add(widgets.Label.new({ h = 1, text = "No crafting CPUs on this network.", fg = theme.textDim }))
    return
  end
  for _, job in ipairs(jobs) do
    local panel = widgets.Panel.new({
      h = 5, -- border + 3 content rows (info, output, progress) + border
      title = (job.name ~= "" and job.name) or ("Crafting CPU " .. job.index),
      borderColor = job.busy and theme.borderFocus or theme.border,
      bg = theme.panel,
    })

    panel:add(widgets.Label.new({ y = 0, h = 1, fg = theme.textDim, text = string.format(
      "co-processors: %s   storage: %s   %s",
      fmt.count(job.coprocessors or 0), fmt.bytes(job.storage), job.busy and "BUSY" or "idle") }))

    local outputText
    if job.output then
      outputText = string.format("%s x%s", job.output.label, fmt.count(job.output.size))
    elseif job.busy then
      outputText = "busy (no Crafting Monitor: output unknown)"
    else
      outputText = "no active job"
    end
    panel:add(widgets.Label.new({ y = 1, h = 1, text = outputText, fg = theme.text }))

    panel:add(widgets.ProgressBar.new({
      y = 2, h = 1,
      value = job.progress,
      bg = theme.barBg,
      fg = job.busy and theme.barFg or theme.good,
      text = progressCaption(job),
    }))

    root:add(panel)
  end
end

function M.start(ctx, cfg)
  local crafting = ctx:use("crafting")
  local root = widgets.VStack.new({ gap = 1 })

  local function render(state)
    if state.error then
      root:clear()
      local text = state.found and ("AE2 read error: " .. state.error) or state.error
      root:add(widgets.Label.new({ h = 1, text = text, fg = theme.bad }))
    elseif state.polledAt then
      buildRows(root, state.jobs or {})
    else
      root:clear()
      root:add(widgets.Label.new({ h = 1, text = "Waiting for AE2...", fg = theme.textDim }))
    end
  end

  local app = App.new({
    root = root,
    background = theme.background,
    tickInterval = 5, -- periodic redraw; data redraws happen on each poll
    gpu = cfg.gpu or nil,
    screen = cfg.screen or nil,
  })
  render(crafting.latest() or {})
  app:mount(ctx)
  ctx:on("crafting_update", function(_, state)
    render(state)
    app:redraw()
  end)
end

return M
