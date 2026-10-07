-- ocui.services.energy -- samples the LSC once for every app that uses it
-- and keeps its history at three resolutions.
--
--   local energy = ctx:use("energy")
--   energy.latest()       -> { reading, net, eta, error, found, updatedAt }
--                            (reading: see ocui.lsc.read)
--   energy.windows()      -> { {key, label, bucket, points}, ... }
--   energy.history(key)   -> array of points, oldest first:
--                            { t, net, netMin, netMax, avgIn, avgOut, fill, partial }
--   energy.stats(key)     -> { netAvg, netMin, netMax, euIn, euOut,
--                              fillStart, fillEnd, seconds, points }
-- Publishes the in-process event "energy_update" (state) after each sample.
-- Config: /etc/ocui/energy.cfg. History lives in memory: it survives app
-- restarts (the service lingers) but not a pool restart.

local component = require("component")
local computer = require("computer")

local lsc = require("ocui.lsc")

local M = {
  name = "energy",
  description = "LSC sampler with history (shared by hud, hudctl, ...)",
  defaults = {
    address = false,      -- gt_machine address if several are connected, else false
    interval = 1,         -- seconds between samples
    wirelessMax = 1e15,   -- what counts as 100% when the LSC is in wireless mode
  },
}

M.WINDOWS = {
  { key = "2m",  label = "2 min",    bucket = 1,   points = 120 },
  { key = "1h",  label = "1 hour",   bucket = 30,  points = 120 },
  { key = "24h", label = "24 hours", bucket = 600, points = 144 },
}

-- ---------------------------------------------------------------- Series --

-- Fixed-size history of time buckets. Samples falling in the same bucket
-- are averaged (net, IN, OUT), with min/max of net and the last fill.
local Series = {}
Series.__index = Series

function M.newSeries(bucket, maxPoints)
  return setmetatable({ bucket = bucket, max = maxPoints, points = {}, open = nil }, Series)
end

local function newBucket(start)
  return { t = start, n = 0, netSum = 0, netMin = math.huge, netMax = -math.huge,
    inSum = 0, inN = 0, outSum = 0, outN = 0, fill = nil }
end

local function finish(o, partial)
  return {
    t = o.t,
    net = o.n > 0 and o.netSum / o.n or nil,
    netMin = o.n > 0 and o.netMin or nil,
    netMax = o.n > 0 and o.netMax or nil,
    avgIn = o.inN > 0 and o.inSum / o.inN or nil,
    avgOut = o.outN > 0 and o.outSum / o.outN or nil,
    fill = o.fill,
    partial = partial or nil,
  }
end

-- s = { net, avgIn, avgOut, fill }, any of them may be nil.
function Series:add(t, s)
  local start = math.floor(t / self.bucket) * self.bucket
  if self.open and self.open.t ~= start then
    table.insert(self.points, finish(self.open))
    while #self.points > self.max do table.remove(self.points, 1) end
    self.open = nil
  end
  local o = self.open
  if not o then
    o = newBucket(start)
    self.open = o
  end
  if s.net then
    o.n = o.n + 1
    o.netSum = o.netSum + s.net
    if s.net < o.netMin then o.netMin = s.net end
    if s.net > o.netMax then o.netMax = s.net end
  end
  if s.avgIn then o.inSum = o.inSum + s.avgIn; o.inN = o.inN + 1 end
  if s.avgOut then o.outSum = o.outSum + s.avgOut; o.outN = o.outN + 1 end
  if s.fill then o.fill = s.fill end
end

-- Closed points plus the bucket still being filled (marked partial), so
-- long windows show data before their first bucket closes. At most `max`.
function Series:list()
  local out = {}
  local first = 1
  if self.open and #self.points >= self.max then first = 2 end
  for i = first, #self.points do out[#out + 1] = self.points[i] end
  if self.open then out[#out + 1] = finish(self.open, true) end
  return out
end

-- Duration-weighted summary of list() up to time `now`.
function Series:stats(now)
  local points = self:list()
  local s = { points = #points, seconds = 0, euIn = 0, euOut = 0 }
  local netWeighted, netSeconds = 0, 0
  for _, p in ipairs(points) do
    local dur = self.bucket
    if p.partial then dur = math.max(math.min(now - p.t, self.bucket), 1) end
    s.seconds = s.seconds + dur
    if p.net then
      netWeighted = netWeighted + p.net * dur
      netSeconds = netSeconds + dur
      if s.netMin == nil or p.netMin < s.netMin then s.netMin = p.netMin end
      if s.netMax == nil or p.netMax > s.netMax then s.netMax = p.netMax end
    end
    if p.avgIn then s.euIn = s.euIn + p.avgIn * 20 * dur end
    if p.avgOut then s.euOut = s.euOut + p.avgOut * 20 * dur end
    if p.fill then
      if s.fillStart == nil then s.fillStart = p.fill end
      s.fillEnd = p.fill
    end
  end
  if netSeconds > 0 then s.netAvg = netWeighted / netSeconds end
  return s
end

-- --------------------------------------------------------------- service --

function M.start(ctx, cfg)
  local address = cfg.address or nil
  local proxy = lsc.find(component, address)
  local sampler = lsc.newSampler(computer.uptime)
  local series = {}
  for _, w in ipairs(M.WINDOWS) do
    series[w.key] = M.newSeries(w.bucket, w.points)
  end

  local state = { found = proxy ~= nil }
  if not proxy then state.error = "LSC not found: attach an Adapter" end

  ctx:every(cfg.interval, function()
    if not proxy then
      proxy = lsc.find(component, address) -- picked up once an Adapter appears
      state.found = proxy ~= nil
      if not proxy then
        ctx:emit("energy_update", state)
        return
      end
    end
    local ok, reading = pcall(lsc.read, proxy, { wirelessMax = cfg.wirelessMax })
    if not ok then
      state.error = tostring(reading)
      ctx:emit("energy_update", state)
      return
    end
    local net = lsc.netFlow(reading, sampler:update(reading))
    local now = computer.uptime()
    state.reading = reading
    state.net = net
    state.eta = lsc.timeToLimit(reading, net)
    state.error = nil
    state.updatedAt = now
    local sample = { net = net, avgIn = reading.avgIn, avgOut = reading.avgOut, fill = reading.fill }
    for _, s in pairs(series) do s:add(now, sample) end
    ctx:emit("energy_update", state)
  end)

  local api = {}
  function api.latest() return state end
  function api.windows() return M.WINDOWS end
  function api.history(key)
    return series[key] and series[key]:list() or {}
  end
  function api.stats(key)
    return series[key] and series[key]:stats(computer.uptime()) or {}
  end
  return api
end

return M
