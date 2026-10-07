-- ocui.apps.hud -- AR-glasses HUD: LSC energy + AE2 autocraft progress.
--
-- Needs: a Glasses Terminal connected to the computer and AR Glasses linked
-- to it (shift-right-click the terminal) and worn. Data comes from the
-- shared services "energy" (LSC) and "crafting" (AE2) -- a disabled panel
-- doesn't use its service, so e.g. hiding autocraft also stops AE2 polling
-- (unless another app such as the dashboard still uses it).
--
-- Config: /etc/ocui/hud.cfg -- edit it or use the `hudctl` screen app.
-- Panel positions are an anchor corner plus an offset from that corner, in
-- GUI pixels; the screen size is learned from the glasses ("glasses_on",
-- sent when a player puts them on) and remembered in the config.
--
-- In-process events it listens to:
--   "hud_layout" (layout)  -- live move: layout = { lsc = {anchor,x,y},
--                             crafting = {anchor,x,y,stack} } (hudctl)
-- OC signal: "ocui_hud_layout" (serialized layout) -- the same, from a
--   hudctl in another pool (e.g. HUD in the background, hudctl in front)
-- and emits:
--   "hud_screen" (w, h)    -- when the glasses report a screen size

local component = require("component")

local hud = require("ocui.hud")
local fmt = require("ocui.format")
local util = require("ocui.util")
local configLib = require("ocui.config")

local M = {
  name = "hud",
  description = "AR glasses: LSC charge + flow graph, autocraft progress",
  defaults = {
    width = 190,           -- panel width, GUI pixels
    alpha = 0.55,          -- panel background opacity (0..1)
    textScale = 1,
    screen = { w = 640, h = 360 }, -- last known GUI size; updated from the glasses

    lsc = {
      enabled = true,
      anchor = "top-left", -- top-left | top-right | bottom-left | bottom-right
      x = 6, y = 6,        -- offset from that corner
      showFlow = true,     -- "IN ... OUT ..." line
      showGraph = true,
      graphWindow = "2m",  -- 2m | 1h | 24h (see the energy service)
      graphBars = 60,
      graphHeight = 34,
    },

    crafting = {
      enabled = true,
      stack = true,        -- place right under the LSC panel (ignores anchor/x/y)
      anchor = "top-left",
      x = 6, y = 160,
      maxRows = 6,         -- busy CPUs shown; the rest are summarized
    },

    colors = {
      panel   = 0x0F0F14,
      title   = 0x4C8BF5,
      text    = 0xE4E4E8,
      dim     = 0x8A8A96,
      good    = 0x4CD787,
      warn    = 0xE0B341,
      bad     = 0xE0574C,
      barBg   = 0x2A2A38,
      energy  = 0x00A6FF,
      craft   = 0x4C8BF5,
    },
  },
}

M.GRAPH_WINDOWS = { "2m", "1h", "24h" }

-- OC signal for live layout changes from a hudctl running in another pool.
M.LAYOUT_SIGNAL = "ocui_hud_layout"

-- Brings a config from the first ocui version up to date: the HUD origin
-- (top-level x/y) becomes the LSC panel offset, and sampling settings that
-- moved to the services are dropped. Returns cfg, changed.
function M.normalize(cfg)
  local changed = false
  if cfg.x ~= nil or cfg.y ~= nil then
    cfg.lsc.x = cfg.x or cfg.lsc.x
    cfg.lsc.y = cfg.y or cfg.lsc.y
    cfg.x, cfg.y = nil, nil
    changed = true
  end
  for _, key in ipairs({ "address", "interval", "wirelessMax" }) do
    if cfg.lsc[key] ~= nil then cfg.lsc[key] = nil; changed = true end
  end
  if cfg.crafting.interval ~= nil then cfg.crafting.interval = nil; changed = true end
  return cfg, changed
end

local PAD = 4

local function lineHeight(cfg)
  return math.floor(hud.LINE_HEIGHT * cfg.textScale + 0.5)
end

-- Panel heights in GUI pixels for this config; the crafting panel grows
-- with the busy-CPU rows shown (default: all maxRows). Panels that are
-- disabled are absent. Used by the HUD itself and by hudctl's preview.
function M.heights(cfg, craftingRows)
  local LINE = lineHeight(cfg)
  local out = {}
  if cfg.lsc.enabled then
    local l = cfg.lsc
    local h = PAD + LINE + 9
    if l.showFlow then h = h + LINE end
    if l.showGraph then h = h + LINE + 1 + l.graphHeight + 3 else h = h + LINE end
    out.lsc = h + LINE + PAD - 2
  end
  if cfg.crafting.enabled then
    local rows = craftingRows or cfg.crafting.maxRows
    out.crafting = PAD + LINE + math.max(rows, 1) * (LINE + 6) + PAD - 4
  end
  return out
end

-- Where each panel goes, given the config, panel heights and screen size.
-- Exposed for hudctl's preview and for tests. Returns { lsc = {x, y},
-- crafting = {x, y} } for the panels that exist.
function M.layout(cfg, heights, screen)
  local out = {}
  local l, c = cfg.lsc, cfg.crafting
  if heights.lsc then
    out.lsc = { hud.anchor(l.anchor, l.x, l.y, cfg.width, heights.lsc, screen.w, screen.h) }
  end
  if heights.crafting then
    local anchor, ox, oy = c.anchor, c.x, c.y
    if c.stack then
      -- same corner as the LSC panel, one panel further from it; for a
      -- bottom anchor that means above the LSC panel
      anchor, ox = l.anchor, l.x
      oy = heights.lsc and (l.y + heights.lsc + 4) or l.y
    end
    out.crafting = { hud.anchor(anchor, ox, oy, cfg.width, heights.crafting, screen.w, screen.h) }
  end
  return out
end

function M.start(ctx, config)
  local cfg, migrated = M.normalize(config)
  if migrated then
    configLib.save("hud", cfg)
    ctx:log("moved settings from the old hud.cfg layout (sampling now lives in energy.cfg/crafting.cfg)")
  end
  local colors = cfg.colors
  local LINE = lineHeight(cfg)
  local W = cfg.width
  local innerW = W - 2 * PAD

  local glasses = hud.findGlasses(component)
  assert(#glasses > 0, "No Glasses Terminal found. Connect one to this computer.")
  for _, g in ipairs(glasses) do
    assert(ctx:claim("glasses:" .. tostring(g.address)))
  end
  local surface = hud.newSurface(glasses)
  surface:clear()
  ctx:onStop(function() surface:clear() end)

  local screen = { w = cfg.screen.w, h = cfg.screen.h }
  local panels = {}

  -- Truncates text to fit `width` GUI pixels at the HUD's text scale.
  local function fit(s, width)
    local maxChars = math.floor(width / (hud.CHAR_WIDTH * cfg.textScale))
    if util.len(s) > maxChars then
      return util.truncate(s, math.max(maxChars - 1, 0)) .. "~"
    end
    return s
  end

  local function placeAll()
    local heights = {
      lsc = panels.lsc and panels.lsc.height,
      crafting = panels.crafting and panels.crafting.height,
    }
    local pos = M.layout(cfg, heights, screen)
    for name, p in pairs(pos) do
      panels[name].group:moveTo(p[1], p[2])
    end
  end

  -- ------------------------------------------------------- LSC panel --

  local function buildLscPanel()
    local l = cfg.lsc
    local group = hud.newGroup(surface, 0, 0)
    local p = { group = group }
    local function label(x, y, text, color)
      return group:text({ x = x, y = y, text = text, color = color or colors.text, scale = cfg.textScale })
    end

    local y = PAD
    p.bg = group:rect({ x = 0, y = 0, w = W, h = 1, color = colors.panel, alpha = cfg.alpha })
    label(PAD, y, "LSC", colors.title)
    p.warning = label(PAD + hud.textWidth("LSC  ", cfg.textScale), y, "", colors.bad)
    p.percent = label(W - PAD - hud.textWidth("100.0%", cfg.textScale), y, "", colors.text)
    y = y + LINE
    p.bar = group:bar({ x = PAD, y = y, w = innerW, h = 6, bg = colors.barBg, fg = colors.energy })
    y = y + 6 + 3
    p.stored = label(PAD, y, "", colors.text)
    if l.showFlow then
      y = y + LINE
      p.flow = label(PAD, y, "", colors.dim)
    end
    if l.showGraph then
      y = y + LINE + 1
      p.graph = group:graph({ x = PAD, y = y, w = innerW, h = l.graphHeight,
        bars = l.graphBars, bg = colors.barBg, alpha = 0.6,
        posColor = colors.good, negColor = colors.bad,
        format = function(v) return fmt.si(v, 1) end })
      p.window = label(W - PAD - hud.textWidth(l.graphWindow, 0.75) - 1, y + 1, l.graphWindow, colors.dim)
      p.window:setScale(0.75)
      y = y + l.graphHeight + 3
    else
      y = y + LINE
    end
    p.net = label(PAD, y, "", colors.text)
    p.netY = y
    p.height = M.heights(cfg).lsc
    p.bg:setSize(W, p.height)

    local energy = ctx:use("energy")

    function p.update(state)
      if not state.found or not state.reading then
        p.stored:setText(fit(state.error or "waiting for the LSC...", innerW))
        p.stored:setColor(state.error and colors.bad or colors.dim)
        return
      end
      if state.error then
        p.warning:setText("read error")
        p.warning:setColor(colors.bad)
        return
      end
      local reading, net = state.reading, state.net

      p.percent:setText(fmt.percent(reading.fill))
      p.bar:setValue(reading.fill)
      p.bar:setColor(reading.wireless and colors.good or colors.energy)

      local warn = {}
      if not reading.maintenanceOk then table.insert(warn, "MAINTENANCE") end
      if reading.wireless then table.insert(warn, "wireless") end
      p.warning:setText(table.concat(warn, " "))
      p.warning:setColor(reading.maintenanceOk and colors.dim or colors.bad)

      p.stored:setText(fit(string.format("%s / %s EU", fmt.si(reading.stored), fmt.si(reading.capacity)), innerW))
      p.stored:setColor(colors.text)

      if p.flow then
        if reading.avgIn and reading.avgOut then
          p.flow:setText(fit(string.format("IN %s  OUT %s EU/t", fmt.si(reading.avgIn), fmt.si(reading.avgOut)), innerW))
        else
          p.flow:setText("IN/OUT n/a (from stored delta)")
        end
      end

      if p.graph then
        local nets = {}
        for i, point in ipairs(energy.history(l.graphWindow) or {}) do nets[i] = point.net end
        p.graph:setValues(nets)
      end

      if net == nil then
        p.net:setText("NET measuring...")
        p.net:setColor(colors.dim)
        return
      end
      local tail = ""
      if state.eta then
        tail = (net > 0 and "  full " or "  empty ") .. fmt.duration(state.eta)
      end
      p.net:setText(fit("NET " .. fmt.signedSi(net) .. " EU/t" .. tail, innerW))
      p.net:setColor(net >= 0 and colors.good or colors.bad)
    end

    ctx:on("energy_update", function(_, state) p.update(state) end)
    p.update(energy.latest() or {})
    return p
  end

  -- -------------------------------------------------- Crafting panel --

  local ROW_H = LINE + 6

  local function buildCraftingPanel()
    local c = cfg.crafting
    local group = hud.newGroup(surface, 0, 0)
    local p = { group = group, rows = {} }
    local function label(x, y, text, color)
      return group:text({ x = x, y = y, text = text, color = color or colors.text, scale = cfg.textScale })
    end

    p.bg = group:rect({ x = 0, y = 0, w = W, h = 1, color = colors.panel, alpha = cfg.alpha })
    p.title = label(PAD, PAD, "Autocraft", colors.title)
    p.status = label(PAD, PAD + LINE, "", colors.dim)

    for i = 1, c.maxRows do
      local ry = PAD + LINE + (i - 1) * ROW_H
      local row = {}
      row.text = label(PAD, ry, "", colors.text)
      row.bar = group:bar({ x = PAD, y = ry + LINE - 1, w = innerW, h = 3, bg = colors.barBg, fg = colors.craft })
      row.text:setVisible(false)
      row.bar:setVisible(false)
      p.rows[i] = row
    end

    local function setRows(rowsShown)
      p.height = M.heights(cfg, rowsShown).crafting
      p.bg:setSize(W, p.height)
    end
    setRows(0)

    local crafting = ctx:use("crafting")

    local function hideRows()
      for _, row in ipairs(p.rows) do
        row.text:setVisible(false)
        row.bar:setVisible(false)
      end
    end

    function p.update(state)
      local before = p.height
      if state.error then
        p.status:setText(fit(state.found and ("AE2 error: " .. state.error) or state.error, innerW))
        p.status:setColor(colors.bad)
        p.status:setVisible(true)
        hideRows()
        setRows(0)
      elseif not state.polledAt then
        p.status:setText("waiting for AE2...")
        p.status:setColor(colors.dim)
      else
        local jobs, busy = state.jobs or {}, state.busy or {}
        p.title:setText(string.format("Autocraft  %d/%d CPU", #busy, #jobs))
        if #busy == 0 then
          p.status:setText(#jobs == 0 and "no crafting CPUs" or "idle")
          p.status:setColor(colors.dim)
          p.status:setVisible(true)
        else
          p.status:setVisible(false)
        end

        local shown = math.min(#busy, #p.rows)
        for i, row in ipairs(p.rows) do
          local job = busy[i]
          if job and i <= shown then
            local what
            if job.output then
              what = string.format("%s x%s", job.output.label, fmt.count(job.output.size))
            else
              what = (job.name ~= "" and job.name or ("CPU " .. job.index)) .. " (no monitor)"
            end
            local right = fmt.percent(job.progress, 0)
            if job.eta then right = right .. " " .. fmt.duration(job.eta) end
            if i == shown and #busy > shown then
              right = right .. string.format(" +%d", #busy - shown)
            end
            local rightW = hud.textWidth(" " .. right, cfg.textScale)
            row.text:setText(fit(what, innerW - rightW) .. " " .. right)
            row.text:setVisible(true)
            row.bar:setVisible(true)
            row.bar:setValue(job.progress)
          else
            row.text:setVisible(false)
            row.bar:setVisible(false)
          end
        end
        setRows(shown)
      end
      -- a bottom-anchored or stacked panel moves when its height changes
      if p.height ~= before and panels.crafting then placeAll() end
    end

    ctx:on("crafting_update", function(_, state) p.update(state) end)
    p.update(crafting.latest() or {})
    return p
  end

  -- ------------------------------------------------------------- setup --

  if cfg.lsc.enabled then panels.lsc = buildLscPanel() end
  if cfg.crafting.enabled then panels.crafting = buildCraftingPanel() end
  placeAll()

  -- The glasses report the player's GUI size when put on; anchors depend
  -- on it, so remember it and re-place.
  ctx:on("glasses_on", function(_, _, w, h)
    w, h = tonumber(w), tonumber(h)
    if not w or not h or (w == screen.w and h == screen.h) then return end
    screen.w, screen.h = w, h
    cfg.screen = { w = w, h = h }
    local saved = configLib.load("hud", M.defaults)
    if saved then
      saved.screen = { w = w, h = h }
      configLib.save("hud", saved)
    end
    placeAll()
    ctx:emit("hud_screen", w, h)
  end)

  -- Live moves from hudctl (structural changes restart the app instead):
  -- an in-process event from a hudctl in this pool, or an OC signal
  -- carrying the serialized layout from a hudctl in another pool.
  local function applyLayout(layout)
    if type(layout) ~= "table" then return end
    for _, name in ipairs({ "lsc", "crafting" }) do
      local src = layout[name]
      if type(src) == "table" then
        for _, key in ipairs({ "anchor", "x", "y", "stack" }) do
          if src[key] ~= nil then cfg[name][key] = src[key] end
        end
      end
    end
    placeAll()
  end
  ctx:on("hud_layout", function(_, layout) applyLayout(layout) end)
  ctx:on(M.LAYOUT_SIGNAL, function(_, text)
    if type(text) == "string" then applyLayout(configLib.parse(text)) end
  end)

  ctx:log("running on %d glasses terminal(s)", #glasses)
end

return M
