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

local component = require("component")
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

  local ui = { tab = 1, window = "2m", message = nil, profile = "default" }

  -- Profiles: "default" (template for new terminals) or a terminal address.
  local function connectedTerminals()
    local set = {}
    for address in component.list("glasses", true) do set[address] = true end
    return set
  end

  local function current()
    if ui.profile ~= "default" and hudCfg.profiles[ui.profile] then
      return hudCfg.profiles[ui.profile]
    end
    ui.profile = "default"
    return hudCfg.default
  end

  local function profileIds()
    local ids = {}
    for address in pairs(hudCfg and hudCfg.profiles or {}) do table.insert(ids, address) end
    table.sort(ids, function(a, b)
      local la, lb = hudCfg.profiles[a].label or "", hudCfg.profiles[b].label or ""
      if la ~= lb then return la < lb end
      return a < b
    end)
    table.insert(ids, 1, "default")
    return ids
  end

  local function profileName(id)
    if id == "default" then return "Default (new terminals)" end
    local p = hudCfg.profiles[id]
    local label = (p and p.label ~= "" and p.label) or "terminal"
    local name = label .. " [" .. id:sub(1, 8) .. "]"
    if not connectedTerminals()[id] then name = name .. " (offline)" end
    return name
  end

  -- start on the only connected terminal's profile, if there is exactly one
  if hudCfg then
    local only, count = nil, 0
    for address in pairs(connectedTerminals()) do
      if hudCfg.profiles[address] then only, count = address, count + 1 end
    end
    if count == 1 then ui.profile = only end
  end
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
  -- (Editing the template only affects terminals added later, so it
  -- never restarts the HUD.)
  local function edited(rebuild)
    local prof = current()
    if ui.profile == "default" then rebuild = false end
    pending = pending or {}
    pending.at = computer.uptime() + APPLY_DELAY
    pending.rebuild = pending.rebuild or rebuild
    if not rebuild and ui.profile ~= "default" then
      local layout = {
        profile = ui.profile,
        lsc = { anchor = prof.lsc.anchor, x = prof.lsc.x, y = prof.lsc.y },
        crafting = { anchor = prof.crafting.anchor, x = prof.crafting.x,
          y = prof.crafting.y, stack = prof.crafting.stack },
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

  -- Copies the template into a terminal profile, keeping what belongs to
  -- that terminal (its name, on/off switch and screen size).
  local function resetToTemplate(p)
    local keep = { label = p.label, enabled = p.enabled, screen = p.screen }
    for k in pairs(p) do p[k] = nil end
    for k, v in pairs(config.copy(hudCfg.default)) do p[k] = v end
    for k, v in pairs(keep) do p[k] = v end
  end

  -- An edit that changes several terminals at once: save + restart.
  local function structuralEdit(message)
    pending = pending or {}
    pending.at = computer.uptime() + APPLY_DELAY
    pending.rebuild = true
    ui.message = message
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

  ctx:on("hud_screen", function(_, address, w, h)
    if hudCfg and hudCfg.profiles[address] then
      hudCfg.profiles[address].screen = { w = w, h = h }
      invalidate()
      app:redraw()
    end
  end)

  -- Pick up profiles the HUD created for new terminals (and screen sizes
  -- it learned) -- but never while our own edits are unsaved.
  local function reload()
    if pending then return end
    local fresh = config.load("hud", hudApp.defaults)
    if fresh then hudCfg = hudApp.normalize(fresh) end
  end

  ctx:on("energy_update", function()
    if ui.tab == 2 then
      invalidate()
      app:redraw()
    end
  end)

  -- ----------------------------------------------------------- HUD tab --

  local function previewModel()
    local prof = current()
    local heights = hudApp.heights(prof)
    local pos = hudApp.layout(prof, heights, prof.screen)
    local panels = {}
    if pos.lsc then
      table.insert(panels, { label = "LSC", x = pos.lsc[1], y = pos.lsc[2],
        w = prof.width, h = heights.lsc, color = 0x2B5797 })
    end
    if pos.crafting then
      table.insert(panels, { label = "Craft", x = pos.crafting[1], y = pos.crafting[2],
        w = prof.width, h = heights.crafting, color = 0x6B4C9A })
    end
    return { screen = prof.screen, panels = panels }
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

    local prof = current()
    local isTemplate = ui.profile == "default"
    add(widgets.Cycle.new({ x = 1, y = 3, w = 52, h = 1, label = "Profile", options = profileIds(),
      value = ui.profile, format = profileName,
      onChange = function(id) ui.profile = id; invalidate() end }))
    if not isTemplate then
      toggle(55, 3, 24, "HUD on this terminal", prof, "enabled", true)
    end

    local l, c = prof.lsc, prof.crafting
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
    stepper(lx, 14, colW, "Width", prof, "width", true, { min = 120, max = 600 })
    cycle(lx, 15, colW, "Text size", { 0.75, 1, 1.25, 1.5, 2 }, prof, "textScale", true, false,
      function(v) return string.format("%gx", v) end)
    label(lx, 16, string.format("Screen %dx%d px (from the glasses)",
      prof.screen.w, prof.screen.h), theme.textDim, colW)
    label(lx, 17, "Moves apply live, rest restarts HUD", theme.textDim, colW)
    if isTemplate then
      add(widgets.Button.new({ x = lx, y = 19, text = "Apply to all terminals", onClick = function()
        for _, p in pairs(hudCfg.profiles) do resetToTemplate(p) end
        structuralEdit("template applied to every terminal")
      end }))
    else
      add(widgets.Button.new({ x = lx, y = 19, text = "Reset to template", onClick = function()
        resetToTemplate(prof)
        structuralEdit("profile reset to the template")
      end }))
      if not connectedTerminals()[ui.profile] then
        add(widgets.Button.new({ x = lx + 20, y = 19, text = "Forget", onClick = function()
          hudCfg.profiles[ui.profile] = nil
          ui.profile = "default"
          structuralEdit("offline profile removed")
        end }))
      end
    end

    -- to-scale preview in the right column, as large as the space allows
    -- (text cells are about twice as tall as wide)
    local px, py = cx, 12
    local maxW, maxH = W - px - 1, H - py - 1
    local aspect = prof.screen.w / prof.screen.h
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
    onTick = function()
      reload()
      invalidate()
    end,
    gpu = cfg.gpu or nil,
    screen = cfg.screen or nil,
  })
  app:mount(ctx)
end

return M
