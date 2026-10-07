-- ocui.apps.hudctl -- screen control panel for the glasses HUD, plus
-- energy statistics with charts.
--
-- Tab "HUD": show/hide panels and their parts, panel anchor/offset, width,
-- text scale, with a to-scale preview of where the panels sit on the
-- player's screen. Moves apply to the running HUD instantly; changes
-- that need a rebuild (show/hide, graph window, rows, size) save
-- /etc/ocui/hud.cfg and restart the HUD a moment after the last click.
-- Tab "Energy": live LSC numbers, net-flow and charge charts over
-- 2 min / 1 hour / 24 hours, and window statistics.
--
-- Run it next to the HUD in one pool ("ocpool hud hudctl"), or on its own
-- while the HUD runs in a background pool ("ocpool -b hud", then "hudctl"):
-- it then reaches the HUD through the background pool's ocpool signals
-- (status/restart) and the "ocui_hud_layout" signal (live moves), and its
-- Energy tab has history only from when hudctl started.
-- Needs a T2+ GPU + screen (80x25 or larger). Config: /etc/ocui/hudctl.cfg

local computer = require("computer")

local App = require("ocui.app")
local base = require("ocui.widget")
local widgets = require("ocui.widgets")
local theme = require("ocui.theme")
local fmt = require("ocui.format")
local hud = require("ocui.hud")
local config = require("ocui.config")
local util = require("ocui.util")

local M = {
  name = "hudctl",
  description = "screen control panel for the HUD + energy charts",
  defaults = {
    gpu = false,     -- GPU address, or false for the primary GPU
    screen = false,  -- screen address to bind, or false for the GPU's current one
  },
}

local APPLY_DELAY = 0.8 -- seconds after the last click before saving/restarting

local ANCHOR_NAMES = {
  ["top-left"] = "top-left", ["top-right"] = "top-right",
  ["bottom-left"] = "bottom-left", ["bottom-right"] = "bottom-right",
}

-- ------------------------------------------------------------- Preview --

-- To-scale map of the player's screen with the HUD panels drawn in it.
local Preview = setmetatable({}, { __index = base.Widget })
Preview.__index = Preview

function Preview.new(props)
  local self = setmetatable(base.Widget.new(props), Preview)
  self.getModel = props.getModel
  return self
end

function Preview:draw(canvas)
  local model = self.getModel()
  local w, h = self.w, self.h
  canvas:fillRect(0, 0, w, h, 0x0B0B10)
  canvas:border(0, 0, w, h, theme.border, string.format("screen %dx%d", model.screen.w, model.screen.h))
  local iw, ih = w - 2, h - 2
  if iw <= 0 or ih <= 0 then return end
  local sx, sy = model.screen.w / iw, model.screen.h / ih
  local inner = canvas:sub(1, 1, iw, ih)
  for _, panel in ipairs(model.panels) do
    local cx = math.floor(panel.x / sx)
    local cy = math.floor(panel.y / sy)
    local cw = math.max(math.floor((panel.x + panel.w) / sx + 0.5) - cx, 1)
    local ch = math.max(math.floor((panel.y + panel.h) / sy + 0.5) - cy, 1)
    inner:fillRect(cx, cy, cw, ch, panel.color)
    inner:text(cx, cy, panel.label, 0xFFFFFF, panel.color)
  end
end

-- ------------------------------------------------------------------ app --

function M.start(ctx, cfg)
  local hudApp = require("ocui.apps.hud")
  local energy = ctx:use("energy")

  local hudCfg, loadErr = config.load("hud", hudApp.defaults)
  if hudCfg then hudCfg = hudApp.normalize(hudCfg) end

  local ui = { tab = 1, window = "2m", message = nil }
  local pending = nil
  local app
  local root = base.Container.new({})
  root.dirty = true

  local function invalidate()
    root.dirty = true
  end

  -- The HUD is either in this pool ("local") or in a background pool we
  -- reach with ocpool signals ("remote"); remote state comes from status
  -- replies polled every 2 s.
  local Pool = require("ocui.pool")
  local remote = {}
  local pollId = string.format("hudctl-%d", math.random(1, 1000000000))

  local function localHud()
    for _, a in ipairs(ctx:apps()) do
      if a.name == "hud" then return a end
    end
    return nil
  end

  local function hudState()
    local a = localHud()
    if a then return a.state, a.error, "local" end
    if remote.seenAt and computer.uptime() - remote.seenAt < 5 then
      return remote.state, remote.error, "remote"
    end
    return nil
  end

  local function hudCommand(cmd)
    if localHud() then
      if cmd == "restart" then return ctx:restartApp("hud") end
      if cmd == "stop" then return ctx:stopApp("hud") end
      return ctx:startApp("hud")
    end
    computer.pushSignal(Pool.SIGNAL, cmd, "hud")
    return true
  end

  ctx:every(2, function()
    if not localHud() then computer.pushSignal(Pool.SIGNAL, "status", nil, pollId) end
  end)
  ctx:on(Pool.REPLY, function(_, id, ok, text)
    if id ~= pollId or not ok then return end
    local status = config.parse(text or "")
    for _, a in ipairs(status and status.apps or {}) do
      if a.name == "hud" then
        remote.state, remote.error, remote.seenAt = a.state, a.error, computer.uptime()
        invalidate()
      end
    end
  end)

  -- Records an edit: layout-only edits go to the running HUD at once;
  -- everything is saved (and the HUD restarted if `rebuild`) after a pause.
  local function edited(rebuild)
    pending = pending or {}
    pending.at = computer.uptime() + APPLY_DELAY
    pending.rebuild = pending.rebuild or rebuild
    if not rebuild then
      local layout = {
        lsc = { anchor = hudCfg.lsc.anchor, x = hudCfg.lsc.x, y = hudCfg.lsc.y },
        crafting = { anchor = hudCfg.crafting.anchor, x = hudCfg.crafting.x,
          y = hudCfg.crafting.y, stack = hudCfg.crafting.stack },
      }
      if localHud() then
        ctx:emit("hud_layout", layout)
      else
        computer.pushSignal(hudApp.LAYOUT_SIGNAL, config.serialize(layout))
      end
    end
    ui.message = "unsaved changes..."
    invalidate()
  end

  ctx:every(0.25, function()
    if pending and computer.uptime() >= pending.at then
      local p = pending
      pending = nil
      config.save("hud", hudCfg)
      ui.message = "saved to " .. config.path("hud")
      if p.rebuild and hudState() == "running" then
        local ok, err = hudCommand("restart")
        ui.message = ok and "saved, HUD restarted" or ("HUD restart failed: " .. tostring(err))
      end
      invalidate()
      app:redraw()
    end
  end)

  ctx:on("hud_screen", function(_, w, h)
    hudCfg.screen = { w = w, h = h }
    invalidate()
    app:redraw()
  end)

  ctx:on("energy_update", function()
    if ui.tab == 2 then
      invalidate()
      app:redraw()
    end
  end)

  -- ----------------------------------------------------------- HUD tab --

  local function previewModel()
    local heights = hudApp.heights(hudCfg)
    local pos = hudApp.layout(hudCfg, heights, hudCfg.screen)
    local panels = {}
    if pos.lsc then
      table.insert(panels, { label = "LSC", x = pos.lsc[1], y = pos.lsc[2],
        w = hudCfg.width, h = heights.lsc, color = 0x2B5797 })
    end
    if pos.crafting then
      table.insert(panels, { label = "Craft", x = pos.crafting[1], y = pos.crafting[2],
        w = hudCfg.width, h = heights.crafting, color = 0x6B4C9A })
    end
    return { screen = hudCfg.screen, panels = panels }
  end

  local function add(widget) return root:add(widget) end

  local function label(x, y, text, color, w)
    return add(widgets.Label.new({ x = x, y = y, w = w, h = 1, text = text, fg = color or theme.text }))
  end

  local function toggle(x, y, w, text, tbl, key, rebuild, disabled)
    return add(widgets.Toggle.new({ x = x, y = y, w = w, h = 1, label = text, value = tbl[key],
      disabled = disabled,
      onChange = function(v) tbl[key] = v; edited(rebuild) end }))
  end

  local function cycle(x, y, w, text, options, tbl, key, rebuild, disabled, format)
    return add(widgets.Cycle.new({ x = x, y = y, w = w, h = 1, label = text, options = options,
      value = tbl[key], disabled = disabled, format = format,
      onChange = function(v) tbl[key] = v; edited(rebuild) end }))
  end

  local function stepper(x, y, w, text, tbl, key, rebuild, opts)
    opts = opts or {}
    return add(widgets.Stepper.new({ x = x, y = y, w = w, h = 1, label = text, labelWidth = 10,
      value = tbl[key], steps = opts.steps, min = opts.min, max = opts.max,
      disabled = opts.disabled, format = opts.format,
      onChange = function(v) tbl[key] = v; edited(rebuild) end }))
  end

  local function buildHudTab()
    local W, H = root.w, root.h
    if not hudCfg then
      label(1, 2, "Cannot read hud.cfg: " .. tostring(loadErr), theme.bad, W - 2)
      return
    end

    -- status line
    local state, err, where = hudState()
    local statusText, statusColor
    if state == nil then
      statusText, statusColor = "HUD: not running (start it: ocpool -b hud)", theme.warn
    elseif state == "running" then
      statusText, statusColor = "HUD: running" .. (where == "remote" and " (background pool)" or ""), theme.good
    else
      statusText, statusColor = "HUD: " .. state .. (err and (" - " .. err) or ""), theme.bad
    end
    label(1, 2, statusText, statusColor, 46)
    if state ~= nil then
      local bx = 48
      if state == "running" then
        add(widgets.Button.new({ x = bx, y = 2, text = "Restart", onClick = function()
          hudCommand("restart"); ui.message = "HUD restarted"; invalidate() end }))
        add(widgets.Button.new({ x = bx + 10, y = 2, text = "Stop", onClick = function()
          hudCommand("stop"); ui.message = "HUD stopped"; invalidate() end }))
      else
        add(widgets.Button.new({ x = bx, y = 2, text = "Start", onClick = function()
          local ok, e = hudCommand("start")
          ui.message = ok and "HUD started" or ("start failed: " .. tostring(e))
          invalidate()
        end }))
      end
    end

    local l, c = hudCfg.lsc, hudCfg.crafting
    local colW = 38
    local lx, cx = 1, 41

    label(lx, 4, "LSC panel", theme.accent)
    toggle(lx, 5, colW, "Show panel", l, "enabled", true)
    toggle(lx, 6, colW, "IN/OUT line", l, "showFlow", true, not l.enabled)
    toggle(lx, 7, colW, "Flow graph", l, "showGraph", true, not l.enabled)
    cycle(lx, 8, colW, "Graph window", hudApp.GRAPH_WINDOWS, l, "graphWindow", true,
      not (l.enabled and l.showGraph))
    cycle(lx, 9, colW, "Anchor", hud.ANCHORS, l, "anchor", false, not l.enabled,
      function(v) return ANCHOR_NAMES[v] or tostring(v) end)
    stepper(lx, 10, colW, "Offset X", l, "x", false, { min = 0, max = 4000, disabled = not l.enabled })
    stepper(lx, 11, colW, "Offset Y", l, "y", false, { min = 0, max = 4000, disabled = not l.enabled })

    label(cx, 4, "Autocraft panel", theme.accent)
    toggle(cx, 5, colW, "Show panel", c, "enabled", true)
    toggle(cx, 6, colW, "Stack under LSC panel", c, "stack", false, not c.enabled)
    stepper(cx, 7, colW, "CPU rows", c, "maxRows", true,
      { steps = { -1, 1 }, min = 1, max = 12, disabled = not c.enabled })
    local free = c.enabled and not c.stack
    cycle(cx, 8, colW, "Anchor", hud.ANCHORS, c, "anchor", false, not free,
      function(v) return ANCHOR_NAMES[v] or tostring(v) end)
    stepper(cx, 9, colW, "Offset X", c, "x", false, { min = 0, max = 4000, disabled = not free })
    stepper(cx, 10, colW, "Offset Y", c, "y", false, { min = 0, max = 4000, disabled = not free })

    label(lx, 13, "General", theme.accent)
    stepper(lx, 14, colW, "Width", hudCfg, "width", true, { min = 120, max = 600 })
    cycle(lx, 15, colW, "Text size", { 0.75, 1, 1.25, 1.5, 2 }, hudCfg, "textScale", true, false,
      function(v) return string.format("%gx", v) end)
    label(lx, 16, string.format("Screen %dx%d px (from the glasses)",
      hudCfg.screen.w, hudCfg.screen.h), theme.textDim, colW)
    label(lx, 17, "Moves apply live; other edits", theme.textDim, colW)
    label(lx, 18, "restart the HUD after a moment.", theme.textDim, colW)

    -- to-scale preview in the right column, as large as the space allows
    -- (text cells are about twice as tall as wide)
    local px, py = cx, 12
    local maxW, maxH = W - px - 1, H - py - 1
    local aspect = hudCfg.screen.w / hudCfg.screen.h
    local previewW = math.min(maxW, math.floor(maxH * 2 * aspect))
    local previewH = math.min(maxH, math.floor(previewW / (2 * aspect) + 0.5) + 2)
    if previewW >= 10 and previewH >= 4 then
      add(Preview.new({ x = px, y = py, w = previewW, h = previewH, getModel = previewModel }))
    end
  end

  -- -------------------------------------------------------- Energy tab --

  local function buildEnergyTab()
    local W, H = root.w, root.h
    local state = energy.latest() or {}
    local reading = state.reading

    if not reading then
      label(1, 2, state.error or "Waiting for the first LSC sample...", state.error and theme.bad or theme.textDim, W - 2)
      return
    end

    local flags = {}
    if reading.wireless then table.insert(flags, "wireless") end
    if not reading.maintenanceOk then table.insert(flags, "MAINTENANCE!") end
    label(1, 2, string.format("Stored %s / %s EU   %s", fmt.si(reading.stored), fmt.si(reading.capacity),
      table.concat(flags, " ")), reading.maintenanceOk and theme.text or theme.bad, W - 2)
    add(widgets.ProgressBar.new({ x = 1, y = 3, w = W - 2, h = 1, value = reading.fill,
      fg = reading.wireless and theme.good or 0x00A6FF, bg = theme.barBg,
      text = fmt.percent(reading.fill, 2) }))

    local net = state.net
    local flow = {}
    if reading.avgIn and reading.avgOut then
      table.insert(flow, "IN " .. fmt.si(reading.avgIn))
      table.insert(flow, "OUT " .. fmt.si(reading.avgOut))
    end
    table.insert(flow, "NET " .. (net and fmt.signedSi(net) or "measuring...") .. " EU/t")
    if state.eta and net then
      table.insert(flow, (net > 0 and "full in " or "empty in ") .. fmt.duration(state.eta))
    end
    label(1, 4, table.concat(flow, "   "), net and (net >= 0 and theme.good or theme.bad) or theme.textDim, W - 2)

    local windowLabels, keys = {}, {}
    for _, w in ipairs(energy.windows() or {}) do
      windowLabels[w.key] = w.label
      table.insert(keys, w.key)
    end
    add(widgets.Cycle.new({ x = 1, y = 6, w = 30, h = 1, label = "Window", options = keys, value = ui.window,
      format = function(k) return windowLabels[k] or k end,
      onChange = function(k) ui.window = k; invalidate() end }))

    local history = energy.history(ui.window) or {}
    local nets, fills = {}, {}
    local fillMin, fillMax
    for i, p in ipairs(history) do
      nets[i] = p.net
      fills[i] = p.fill
      if p.fill then
        if not fillMin or p.fill < fillMin then fillMin = p.fill end
        if not fillMax or p.fill > fillMax then fillMax = p.fill end
      end
    end
    -- An LSC's charge moves by hundredths of a percent; a 0..100% chart
    -- would be a flat slab, so zoom to the window's range (with margin).
    fillMin, fillMax = fillMin or 0, fillMax or 1
    local pad = math.max((fillMax - fillMin) * 0.15, 0.0005)
    fillMin, fillMax = math.max(fillMin - pad, 0), math.min(fillMax + pad, 1)

    -- chart heights: whatever is left, 60/40 between flow and charge
    local fixedTop, fixedBottom = 8, 3
    local avail = math.max(H - fixedTop - fixedBottom - 2, 4)
    local netH = math.max(math.floor(avail * 0.6), 2)
    local fillH = math.max(avail - netH, 2)

    label(1, fixedTop - 1, "Net flow, EU/t", theme.textDim)
    add(widgets.Chart.new({ x = 1, y = fixedTop, w = W - 2, h = netH, values = nets,
      bg = theme.panel, posColor = theme.good, negColor = theme.bad,
      format = function(v) return fmt.si(v, 1) end }))
    local fy = fixedTop + netH + 1
    label(1, fy, "Charge", theme.textDim)
    add(widgets.Chart.new({ x = 1, y = fy + 1, w = W - 2, h = fillH, values = fills, mode = "area",
      min = fillMin, max = fillMax, bg = theme.panel, posColor = 0x00A6FF, labelWidth = 8,
      format = function(v) return fmt.percent(v, 2) end }))

    local s = energy.stats(ui.window) or {}
    local sy = fy + 1 + fillH + 1
    if s.netAvg then
      label(1, sy, string.format("avg %s   min %s   max %s EU/t   (%d points)",
        fmt.signedSi(s.netAvg), fmt.signedSi(s.netMin), fmt.signedSi(s.netMax), s.points or 0), theme.text, W - 2)
      local inOut = ""
      if s.euIn > 0 or s.euOut > 0 then
        inOut = string.format("in %s EU   out %s EU   ", fmt.si(s.euIn), fmt.si(s.euOut))
      end
      label(1, sy + 1, inOut .. string.format("charge %s -> %s",
        fmt.percent(s.fillStart or 0, 2), fmt.percent(s.fillEnd or 0, 2)), theme.textDim, W - 2)
    else
      label(1, sy, "Collecting samples...", theme.textDim, W - 2)
    end
  end

  -- -------------------------------------------------------------- root --

  local function rebuild()
    root:clear()
    add(widgets.Tabs.new({ x = 0, y = 0, w = root.w, h = 1, tabs = { "HUD", "Energy" }, active = ui.tab,
      onSelect = function(i) ui.tab = i; invalidate() end }))
    if ui.message then
      local msg = ui.message
      add(widgets.Label.new({ x = math.max(root.w - util.len(msg) - 1, 20), y = 0, h = 1,
        text = msg, fg = theme.textDim, bg = theme.panel }))
    end
    if ui.tab == 1 then buildHudTab() else buildEnergyTab() end
  end

  function root:draw(canvas)
    if self.dirty or self.builtW ~= self.w or self.builtH ~= self.h then
      rebuild()
      self.dirty = false
      self.builtW, self.builtH = self.w, self.h
    end
    base.Container.draw(self, canvas)
  end

  app = App.new({
    root = root,
    background = theme.background,
    tickInterval = 2, -- refreshes the HUD status line
    onTick = invalidate,
    gpu = cfg.gpu or nil,
    screen = cfg.screen or nil,
  })
  app:mount(ctx)
end

return M
