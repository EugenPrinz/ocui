-- ocui.apps.hud -- AR-glasses HUD: LSC energy + AE2 autocraft progress.
--
-- Needs: Glasses Terminal(s) connected to the computer, AR Glasses linked to
-- them (shift-right-click the terminal) and worn. Data comes from the
-- shared services "energy" (LSC) and "crafting" (AE2) -- a panel no
-- terminal shows doesn't use its service, so e.g. hiding autocraft
-- everywhere also stops AE2 polling (unless the dashboard still uses it).
--
-- Profiles: everyone bound to one terminal sees the same widgets (that's
-- how OCGlasses works), so settings are per terminal. /etc/ocui/hud.cfg:
--   default  = { ...profile... }            template for new terminals
--   profiles = { ["<terminal address>"] = { label = "...", ...profile... } }
-- A terminal without a profile gets a copy of `default` (labelled with the
-- players bound to it) the first time the HUD sees it. Edit with `hudctl`.
--
-- Panel positions are an anchor corner plus an offset from that corner, in
-- GUI pixels. The screen size comes from the glasses: the terminal signals
-- glasses_on(terminal, player, width, height) when a player puts them on,
-- and it is remembered in that terminal's profile.
--
-- In-process events it listens to:
--   "hud_layout" (layout)  -- live move from hudctl: layout = { profile = <address>,
--                             lsc = {anchor,x,y}, crafting = {anchor,x,y,stack} }
-- OC signal: "ocui_hud_layout" (serialized layout) -- the same, from a
--   hudctl in another pool (e.g. HUD in the background, hudctl in front)
-- and emits:
--   "hud_screen" (address, w, h) -- when a terminal reports a screen size

local component = require("component")

local hud = require("ocui.hud")
local fmt = require("ocui.format")
local util = require("ocui.util")
local configLib = require("ocui.config")

local M = {
  name = "hud",
  description = "AR glasses: LSC charge + flow graph, autocraft progress (per-terminal profiles)",
}

-- Everything one terminal shows.
M.PROFILE_DEFAULTS = {
  label = "",            -- shown in hudctl; defaults to the bound players
  enabled = true,        -- false: nothing on this terminal
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
}

M.defaults = {
  default = M.PROFILE_DEFAULTS,
  profiles = {},
}

M.GRAPH_WINDOWS = { "2m", "1h", "24h" }

-- OC signal for live layout changes from a hudctl running in another pool.
M.LAYOUT_SIGNAL = "ocui_hud_layout"

-- Keys of a profile that may appear at the top level of an old,
-- single-profile hud.cfg.
local PROFILE_KEYS = { "width", "alpha", "textScale", "screen", "lsc", "crafting", "colors", "x", "y" }

-- Brings one profile up to date: the first version's HUD origin (x/y)
-- becomes the LSC panel offset, sampling settings that moved to the
-- services are dropped, missing options get their defaults.
local function normalizeProfile(p)
  local changed = false
  p = configLib.merge(M.PROFILE_DEFAULTS, p)
  if p.x ~= nil or p.y ~= nil then
    p.lsc.x = p.x or p.lsc.x
    p.lsc.y = p.y or p.lsc.y
    p.x, p.y = nil, nil
    changed = true
  end
  for _, key in ipairs({ "address", "interval", "wirelessMax" }) do
    if p.lsc[key] ~= nil then p.lsc[key] = nil; changed = true end
  end
  if p.crafting.interval ~= nil then p.crafting.interval = nil; changed = true end
  return p, changed
end

-- Brings a whole hud.cfg up to date (also an old single-profile one, whose
-- settings become the `default` template). Returns cfg, changed.
function M.normalize(cfg)
  local changed = false
  local legacy = nil
  for _, key in ipairs(PROFILE_KEYS) do
    if cfg[key] ~= nil then
      legacy = legacy or {}
      legacy[key] = cfg[key]
      cfg[key] = nil
    end
  end
  if legacy then
    cfg.default = configLib.merge(cfg.default or {}, legacy)
    changed = true
  end
  local c
  cfg.default, c = normalizeProfile(cfg.default or {})
  changed = changed or c
  cfg.profiles = cfg.profiles or {}
  for address, p in pairs(cfg.profiles) do
    cfg.profiles[address], c = normalizeProfile(p)
    changed = changed or c
  end
  return cfg, changed
end

-- A new profile for a terminal: a copy of the template, labelled.
function M.newProfile(cfg, label)
  local p = configLib.copy(cfg.default)
  p.label = label or ""
  p.enabled = true
  return p
end

-- "Bogdan, Alex" for the players bound to a terminal, or a short address.
function M.terminalLabel(glasses)
  local ok, players = pcall(function() return table.pack(glasses.getBindPlayers()) end)
  local names = {}
  if ok then
    for i = 1, players.n do
      if type(players[i]) == "string" and players[i] ~= "" then table.insert(names, players[i]) end
    end
  end
  if #names > 0 then return table.concat(names, ", ") end
  return "terminal " .. tostring(glasses.address):sub(1, 8)
end

local PAD = 4

local function lineHeight(profile)
  return math.floor(hud.LINE_HEIGHT * profile.textScale + 0.5)
end

-- Panel heights in GUI pixels for a profile; the crafting panel grows
-- with the busy-CPU rows shown (default: all maxRows). Panels that are
-- disabled are absent. Used by the HUD itself and by hudctl's preview.
function M.heights(profile, craftingRows)
  local LINE = lineHeight(profile)
  local out = {}
  if profile.lsc.enabled then
    local l = profile.lsc
    local h = PAD + LINE + 9
    if l.showFlow then h = h + LINE end
    if l.showGraph then h = h + LINE + 1 + l.graphHeight + 3 else h = h + LINE end
    out.lsc = h + LINE + PAD - 2
  end
  if profile.crafting.enabled then
    local rows = craftingRows or profile.crafting.maxRows
    out.crafting = PAD + LINE + math.max(rows, 1) * (LINE + 6) + PAD - 4
  end
  return out
end

-- Where each panel goes, given a profile, panel heights and screen size.
-- Returns { lsc = {x, y}, crafting = {x, y} } for the panels that exist.
function M.layout(profile, heights, screen)
  local out = {}
  local l, c = profile.lsc, profile.crafting
  if heights.lsc then
    out.lsc = { hud.anchor(l.anchor, l.x, l.y, profile.width, heights.lsc, screen.w, screen.h) }
  end
  if heights.crafting then
    local anchor, ox, oy = c.anchor, c.x, c.y
    if c.stack then
      -- same corner as the LSC panel, one panel further from it; for a
      -- bottom anchor that means above the LSC panel
      anchor, ox = l.anchor, l.x
      oy = heights.lsc and (l.y + heights.lsc + 4) or l.y
    end
    out.crafting = { hud.anchor(anchor, ox, oy, profile.width, heights.crafting, screen.w, screen.h) }
  end
  return out
end

-- ------------------------------------------------------------------ view --

-- Builds the panels of one profile on one terminal's surface and wires
-- them to the services. Returns { place(), applyLayout(layout),
-- setScreen(w, h), profile }.
local function buildView(ctx, surface, profile)
  local colors = profile.colors
  local LINE = lineHeight(profile)
  local W = profile.width
  local innerW = W - 2 * PAD
  local screen = { w = profile.screen.w, h = profile.screen.h }
  local panels = {}

  -- Truncates text to fit `width` GUI pixels at the profile's text scale.
  local function fit(s, width)
    local maxChars = math.floor(width / (hud.CHAR_WIDTH * profile.textScale))
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
    local pos = M.layout(profile, heights, screen)
    for name, p in pairs(pos) do
      panels[name].group:moveTo(p[1], p[2])
    end
  end

  -- ----------------------------------------------------- LSC panel --

  local function buildLscPanel()
    local l = profile.lsc
    local group = hud.newGroup(surface, 0, 0)
    local p = { group = group }
    local function label(x, y, text, color)
      return group:text({ x = x, y = y, text = text, color = color or colors.text, scale = profile.textScale })
    end

    local y = PAD
    p.bg = group:rect({ x = 0, y = 0, w = W, h = 1, color = colors.panel, alpha = profile.alpha })
    label(PAD, y, "LSC", colors.title)
    p.warning = label(PAD + hud.textWidth("LSC  ", profile.textScale), y, "", colors.bad)
    p.percent = label(W - PAD - hud.textWidth("100.0%", profile.textScale), y, "", colors.text)
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
    p.height = M.heights(profile).lsc
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

  -- ------------------------------------------------ Crafting panel --

  local ROW_H = LINE + 6

  local function buildCraftingPanel()
    local c = profile.crafting
    local group = hud.newGroup(surface, 0, 0)
    local p = { group = group, rows = {} }
    local function label(x, y, text, color)
      return group:text({ x = x, y = y, text = text, color = color or colors.text, scale = profile.textScale })
    end

    p.bg = group:rect({ x = 0, y = 0, w = W, h = 1, color = colors.panel, alpha = profile.alpha })
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
      p.height = M.heights(profile, rowsShown).crafting
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
            local rightW = hud.textWidth(" " .. right, profile.textScale)
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

  if profile.lsc.enabled then panels.lsc = buildLscPanel() end
  if profile.crafting.enabled then panels.crafting = buildCraftingPanel() end
  placeAll()

  local view = { profile = profile }

  function view.setScreen(w, h)
    screen.w, screen.h = w, h
    profile.screen = { w = w, h = h }
    placeAll()
  end

  function view.applyLayout(layout)
    for _, name in ipairs({ "lsc", "crafting" }) do
      local src = layout[name]
      if type(src) == "table" then
        for _, key in ipairs({ "anchor", "x", "y", "stack" }) do
          if src[key] ~= nil then profile[name][key] = src[key] end
        end
      end
    end
    placeAll()
  end

  return view
end

-- ------------------------------------------------------------------- app --

function M.start(ctx, config)
  local cfg, changed = M.normalize(config)

  -- one view per terminal, each with its own surface and profile
  local views = {}
  local surfaces = {}

  local function addTerminal(glasses)
    local address = glasses.address
    if views[address] or surfaces[address] then return end
    local ok, err = ctx:claim("glasses:" .. tostring(address))
    if not ok then
      ctx:log("skipping terminal %s: %s", tostring(address), tostring(err))
      return
    end
    local profile = cfg.profiles[address]
    if not profile then
      profile = M.newProfile(cfg, M.terminalLabel(glasses))
      cfg.profiles[address] = profile
      changed = true
      ctx:log("new terminal %s (%s): profile created from the default", tostring(address), profile.label)
    end
    local surface = hud.newSurface({ glasses })
    surface:clear()
    surfaces[address] = surface
    if profile.enabled then
      views[address] = buildView(ctx, surface, profile)
    end
  end

  local function removeTerminal(address)
    views[address] = nil
    surfaces[address] = nil
  end

  ctx:onStop(function()
    for _, surface in pairs(surfaces) do surface:clear() end
  end)

  local glasses = hud.findGlasses(component)
  assert(#glasses > 0, "No Glasses Terminal found. Connect one to this computer.")
  for _, g in ipairs(glasses) do addTerminal(g) end

  -- saves just what the HUD itself learned, on top of the file as it is now
  -- (hudctl may have edited it in the meantime)
  local function persist(mutate)
    local saved = configLib.load("hud", M.defaults)
    if not saved then return end
    saved = M.normalize(saved)
    mutate(saved)
    configLib.save("hud", saved)
  end

  if changed then
    persist(function(saved)
      saved.default = cfg.default
      for address, p in pairs(cfg.profiles) do
        if not saved.profiles[address] then saved.profiles[address] = p end
      end
    end)
  end

  -- glasses_on(terminal, player, width, height): OC puts the terminal's
  -- address first, like for every component signal.
  ctx:on("glasses_on", function(_, address, _, w, h)
    local view = views[address]
    w, h = tonumber(w), tonumber(h)
    if not view or not w or not h then return end
    local s = view.profile.screen
    if s and s.w == w and s.h == h then return end
    view.setScreen(w, h)
    persist(function(saved)
      if saved.profiles[address] then saved.profiles[address].screen = { w = w, h = h } end
    end)
    ctx:emit("hud_screen", address, w, h)
  end)

  -- terminals connected or removed while running
  ctx:on("component_added", function(_, address, kind)
    if kind ~= "glasses" then return end
    local proxy = component.proxy(address)
    if not proxy then return end
    addTerminal(proxy)
    persist(function(saved)
      if not saved.profiles[address] and cfg.profiles[address] then
        saved.profiles[address] = cfg.profiles[address]
      end
    end)
  end)
  ctx:on("component_removed", function(_, address, kind)
    if kind == "glasses" then removeTerminal(address) end
  end)

  -- Live moves from hudctl (structural changes restart the app instead):
  -- an in-process event from a hudctl in this pool, or an OC signal
  -- carrying the serialized layout from a hudctl in another pool.
  local function applyLayout(layout)
    if type(layout) ~= "table" then return end
    local view = views[layout.profile]
    if view then view.applyLayout(layout) end
  end
  ctx:on("hud_layout", function(_, layout) applyLayout(layout) end)
  ctx:on(M.LAYOUT_SIGNAL, function(_, text)
    if type(text) == "string" then applyLayout(configLib.parse(text)) end
  end)

  ctx:log("running on %d glasses terminal(s)", #glasses)
end

return M
