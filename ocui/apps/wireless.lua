-- ocui.apps.wireless -- AR-glasses HUD for the GTNH wireless EU network:
-- the network balance, its net flow and a bar chart of past flow.
--
-- Needs: a Glasses Terminal with linked AR Glasses, and an Adapter on ANY
-- LSC controller. Every LSC reports its owner's wireless network balance
-- (sensor line 23, see ocui.lsc), even with wireless mode off, so the LSC
-- itself is never shown. Data comes from the shared "energy" service.
--
-- Every number is computed exactly from the full balance (a digit string
-- of 20+ digits), never from the LSC's own IN/OUT averages:
--   * a closed bar = (balance at the end of its period - balance at the
--     start) / period;
--   * NET = (balance now - balance one bar period ago) / period, a sliding
--     window; the rightmost (live) bar is drawn from NET, so the number
--     and the bar always agree.
-- A series is kept for every bar period at once, so switching is instant.
--
-- Keys on the computer's keyboard (foreground only; in the background the
-- keyboard belongs to the shell): 1..6 pick the bar period, w cycles.
--
-- It uses the glasses terminal exclusively, like the `hud` app: run them
-- on different terminals, or one of them at a time.
--
-- Config: /etc/ocui/wireless.cfg. Sizes are given for scale = 1 and then
-- multiplied by `scale`; every position and size is rounded to whole GUI
-- pixels (fractional ones render bars and borders of uneven thickness),
-- only the text scale stays fractional.

local component = require("component")

local hud = require("ocui.hud")
local fmt = require("ocui.format")
local lsc = require("ocui.lsc")
local configLib = require("ocui.config")

local M = {
  name = "wireless",
  description = "AR glasses: wireless EU network balance + exact flow chart",
  defaults = {
    scale = 0.67,          -- scale of the whole panel (fractional is fine)
    textScale = 0.75,      -- text scale at scale = 1 (final = textScale * scale)
    textMin = 0,           -- lower limit of the final text scale, 0 = none
    anchor = "top-left",   -- top-left | top-right | bottom-left | bottom-right
    x = 2, y = 2,          -- offset from that corner, GUI pixels (not scaled)
    screen = { w = 640, h = 360 }, -- last known GUI size; updated from the glasses

    -- sizes at scale = 1
    width = 170,
    pad = 3,
    chartHeight = 19,
    barWidth = 2,          -- bar width, GUI pixels
    barGap = 1,            -- gap between bars
    chartFree = 0.17,      -- left share of the chart kept free for the scale label

    bold = true,           -- set false if "§l" shows up as text
    shadow = false,        -- Minecraft-style text shadow (1 font pixel)
    keys = true,           -- 1..6 / w on the computer switch the bar period
    periods = {
      { label = "10s", seconds = 10 },
      { label = "30s", seconds = 30 },
      { label = "1m",  seconds = 60 },
      { label = "5m",  seconds = 300 },
      { label = "10m", seconds = 600 },
      { label = "30m", seconds = 1800 },
    },
    period = 3,            -- index into periods (1m)
    debug = false,         -- log the LSC's sensor lines to /tmp/ocpool.log

    colors = {
      panel  = 0x4D3859,
      border = 0xBFB3D9,
      chart  = 0x1F1A29,
      title  = 0x4099F2,
      text   = 0xFFFFFF,
      dim    = 0xA6A6B3,
      good   = 0x66D966,
      bad    = 0xE6664D,
      shadow = 0x000000,
    },
    alpha = { panel = 0.65, chart = 0.85, shadow = 0.8 },
  },
}

-- Recent samples are all kept for FINE_SEC seconds; older ones, one every
-- COARSE_STEP seconds, for as long as the longest period. Rates stay
-- exact either way: they divide by the real time between the samples.
local FINE_SEC, COARSE_STEP = 300, 5

local SECTION = "\194\167" -- "§"

local function px(v) return math.floor(v + 0.5) end
local function pxMin1(v) return math.max(1, px(v)) end

-- EU/t between two samples { t, eu }, exact for any balance size.
local function rate(a, b)
  return lsc.decimalDiff(b.eu, a.eu) / ((b.t - a.t) * 20)
end

-- Bars of one period: closed at time-bucket boundaries.
local function newSeries(seconds)
  return { seconds = seconds, points = {}, start = nil }
end

local function seriesAdd(s, smp, keep)
  if not s.start then
    s.start = smp
    return
  end
  if math.floor(smp.t / s.seconds) ~= math.floor(s.start.t / s.seconds) then
    s.points[#s.points + 1] = rate(s.start, smp)
    while #s.points > keep do table.remove(s.points, 1) end
    s.start = smp
  end
end

function M.start(ctx, cfg)
  local colors, alpha = cfg.colors, cfg.alpha
  local S = cfg.scale
  local TS = math.max(cfg.textScale * S, cfg.textMin) -- final text scale
  local LH = pxMin1(12 * TS)                          -- line step
  local LINE = pxMin1(S)                              -- border thickness
  local W, PAD, CHART_H = px(cfg.width * S), pxMin1(cfg.pad * S), pxMin1(cfg.chartHeight * S)
  local IW = W - 2 * PAD
  local periods = cfg.periods
  local cur = periods[cfg.period] and cfg.period or 1

  local GAP = pxMin1(LH / 3)
  local yTitle = PAD
  local yTotal = yTitle + LH
  local yNet = yTotal + LH
  local yChart = yNet + LH + pxMin1(GAP / 3)
  local yAvg = yChart + CHART_H + GAP
  local H = yAvg + LH + PAD - pxMin1(2 * S)

  -- Bars: whole pixels, the same for every bar, right-aligned; the
  -- remainder (less than a step) goes to the free zone on the left.
  local BAR_W = pxMin1(cfg.barWidth * S)
  local BAR_GAP = pxMin1(cfg.barGap * S)
  local STEP = BAR_W + BAR_GAP
  local BARS = math.max(1, math.floor((IW * (1 - cfg.chartFree) + BAR_GAP) / STEP))
  local barsX = PAD + IW - BARS * STEP + BAR_GAP
  ctx:log("chart: %d bars of %d px (gap %d px), free zone %d of %d px",
    BARS, BAR_W, BAR_GAP, barsX - PAD, IW)
  local labelW = 5 * hud.CHAR_WIDTH * TS -- a scale label like "2.5E6"
  if labelW > (barsX - PAD) - 2 then
    ctx:log("the scale label (~%.0f px) may overlap the bars (free zone %d px): raise chartFree",
      labelW, barsX - PAD)
  end

  local glasses = hud.findGlasses(component)
  assert(#glasses > 0, "No Glasses Terminal found. Connect one to this computer.")
  for _, g in ipairs(glasses) do
    assert(ctx:claim("glasses:" .. tostring(g.address)))
  end
  local surface = hud.newSurface(glasses)
  surface:clear()
  ctx:onStop(function() surface:clear() end)

  local screen = { w = cfg.screen.w, h = cfg.screen.h }
  local group = hud.newGroup(surface, 0, 0)

  local function place()
    group:moveTo(hud.anchor(cfg.anchor, cfg.x, cfg.y, W, H, screen.w, screen.h))
  end

  local function rect(x, y, w, h, color, a)
    return group:rect({ x = x, y = y, w = w, h = h, color = color, alpha = a or 1 })
  end

  -- text + optional shadow; t:set(s), t:color(hex), t:right(s, xRight)
  local Txt = {}
  Txt.__index = Txt
  local function text(x, y, color, s, plain)
    local t = setmetatable({ plain = plain, x = x, y = y }, Txt)
    if cfg.shadow then
      t.sh = group:text({ x = x + TS, y = y + TS, color = colors.shadow,
        alpha = alpha.shadow, scale = TS })
    end
    t.main = group:text({ x = x, y = y, color = color, scale = TS })
    if s then t:set(s) end
    return t
  end
  function Txt:set(s)
    if cfg.bold and not self.plain then s = SECTION .. "l" .. s end
    self.main:setText(s)
    if self.sh then self.sh:setText(s) end
  end
  function Txt:color(hex) self.main:setColor(hex) end
  function Txt:right(s, xRight)
    local w = hud.textWidth(s, TS)
    if cfg.bold and not self.plain then w = w + #s * TS end -- bold is 1 px wider per char
    local x = px(xRight - w)
    if x ~= self.x then
      self.x = x
      group:place(self.main, x, self.y)
      if self.sh then group:place(self.sh, x + TS, self.y + TS) end
    end
    self:set(s)
  end

  rect(0, 0, W, H, colors.panel, alpha.panel)
  rect(0, 0, W, LINE, colors.border); rect(0, H - LINE, W, LINE, colors.border)
  rect(0, 0, LINE, H, colors.border); rect(W - LINE, 0, LINE, H, colors.border)

  local ui = {}
  ui.title = text(PAD, yTitle, colors.title, "WIRELESS")
  ui.period = text(W - PAD - 20, yTitle, colors.dim)
  ui.total = text(PAD, yTotal, colors.text, "...")
  ui.net = text(PAD, yNet, colors.text, "NET ...")
  rect(PAD, yChart, IW, CHART_H, colors.chart, alpha.chart)
  local bars = {}
  for i = 1, BARS do
    bars[i] = rect(barsX + (i - 1) * STEP, yChart + CHART_H, BAR_W, 0, colors.bad)
  end
  -- created after the bars so it is drawn on top of them
  ui.scale = text(PAD + pxMin1(2 * S), yChart + pxMin1(S), colors.dim, nil, true)
  ui.avg = text(PAD, yAvg, colors.dim)
  place()

  -- ------------------------------------------------------------ history --

  local series = {}
  local maxWindow = 0
  for i, p in ipairs(periods) do
    series[i] = newSeries(p.seconds)
    maxWindow = math.max(maxWindow, p.seconds)
  end
  local fine, coarse = {}, {}
  local lastEU, lastT, status

  local function sample(t, eu)
    local smp = { t = t, eu = eu }
    fine[#fine + 1] = smp
    while fine[2] and fine[2].t <= t - FINE_SEC do table.remove(fine, 1) end
    if not coarse[1] or t - coarse[#coarse].t >= COARSE_STEP then coarse[#coarse + 1] = smp end
    while coarse[2] and coarse[2].t <= t - maxWindow do table.remove(coarse, 1) end
    for _, s in ipairs(series) do seriesAdd(s, smp, BARS - 1) end
  end

  -- Flow over the last `window` seconds (or over what there is so far;
  -- then the second result is true).
  local function windowRate(window)
    local now = fine[#fine]
    if not now then return nil end
    local list = window <= FINE_SEC and fine or coarse
    local base = list[1]
    if window > FINE_SEC and fine[1] and (not base or fine[1].t < base.t) then base = fine[1] end
    for i = #list, 1, -1 do -- the newest sample at least `window` old
      if list[i].t <= now.t - window then
        base = list[i]
        break
      end
    end
    if not base or now.t <= base.t then return nil end
    return rate(base, now), (now.t - base.t) < window - 0.5
  end

  -- ------------------------------------------------------------- render --

  local function render()
    if lastEU then
      ui.total:set(fmt.sciDigits(lastEU) .. " EU")
      ui.total:color(colors.text)
    else
      ui.total:set(status or "waiting for the LSC...")
      ui.total:color(status and colors.bad or colors.dim)
    end

    local net, partial = windowRate(periods[cur].seconds)
    if net then
      ui.net:set("NET " .. fmt.signedSci(net) .. " EU/t" .. (partial and " ~" or ""))
      ui.net:color(net < 0 and colors.bad or (net > 0 and colors.good or colors.text))
    end

    ui.period:right(periods[cur].label, W - PAD)

    local vals = {}
    for i, v in ipairs(series[cur].points) do vals[i] = v end
    if net then vals[#vals + 1] = net end
    local peak, sum = 0, 0
    for _, v in ipairs(vals) do
      peak = math.max(peak, math.abs(v))
      sum = sum + v
    end
    ui.scale:set(peak > 0 and fmt.sci(peak, 1) or "")
    if #vals > 0 then
      local avg = sum / #vals
      ui.avg:set("AVG " .. fmt.signedSci(avg) .. " EU/t")
      ui.avg:color(avg < 0 and colors.bad or (avg > 0 and colors.good or colors.dim))
    else
      ui.avg:set("AVG ...")
    end

    local offset = BARS - #vals
    for i = 1, BARS do
      local v = vals[i - offset]
      local h = (v and peak > 0) and px(math.abs(v) / peak * (CHART_H - 1)) or 0
      local b = bars[i]
      b:setSize(BAR_W, h)
      group:place(b, barsX + (i - 1) * STEP, yChart + CHART_H - h)
      if v then b:setColor(v < 0 and colors.bad or colors.good) end
    end
  end

  -- -------------------------------------------------------------- input --

  local energy = ctx:use("energy")

  local function onEnergy(state)
    local reading = state.reading
    if state.error or not reading then
      lastEU, status = nil, state.error
    elseif not reading.wirelessEU then
      lastEU, status = nil, "no wireless EU in the LSC data"
    else
      lastEU, status = reading.wirelessEU, nil
      if state.updatedAt ~= lastT then
        lastT = state.updatedAt
        sample(lastT, lastEU)
      end
    end
    render()
  end
  ctx:on("energy_update", function(_, state) onEnergy(state) end)

  if cfg.debug then
    local proxy = lsc.find(component)
    local ok, info = pcall(function() return proxy and proxy.getSensorInformation() end)
    local wanted = lsc.DEFAULT_SENSOR_LINES.wirelessEU
    for i, l in ipairs(ok and type(info) == "table" and info or {}) do
      ctx:log("%s%d: %s", i == wanted and ">> " or "   ", i, (tostring(l):gsub(SECTION .. ".", "")))
    end
  end

  if cfg.keys and not ctx.background then
    ctx:on("key_down", function(_, _, ch)
      if type(ch) ~= "number" or ch <= 0 or ch > 255 then return end
      local c = string.char(math.floor(ch)):lower()
      local k = tonumber(c)
      if k and periods[k] then
        cur = k
      elseif c == "w" then
        cur = cur % #periods + 1
      else
        return
      end
      render()
    end)
  end

  -- The glasses report the player's GUI size when put on: remember it and
  -- re-anchor. The size is taken as the last two numeric arguments.
  ctx:on("glasses_on", function(...)
    local args, nums = table.pack(...), {}
    for i = 2, args.n do
      local v = tonumber(args[i])
      if v then nums[#nums + 1] = v end
    end
    if #nums < 2 then return end
    local w, h = nums[#nums - 1], nums[#nums]
    if w == screen.w and h == screen.h then return end
    screen.w, screen.h = w, h
    local saved = configLib.load("wireless", M.defaults)
    if saved then
      saved.screen = { w = w, h = h }
      configLib.save("wireless", saved)
    end
    place()
  end)

  onEnergy(energy.latest() or {})
  ctx:log("running on %d glasses terminal(s)", #glasses)
end

return M
