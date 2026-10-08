-- mock/run_mock.lua
-- Test suite: unit tests for the ocui data/format helpers, then runs the
-- real apps (apps/ae2_dashboard.lua, apps/hud.lua) under the fake OpenOS
-- environment from component_factory.lua across several scenarios, with
-- assertions on what ends up on the screen / glasses.
--
-- Run from the project root:
--   lua mock/run_mock.lua            (add -v to print every rendered frame)

local projectRoot = (arg[0]):match("(.*)[/\\]mock[/\\]run_mock%.lua$") or "."
package.path = projectRoot .. "/?.lua;" .. projectRoot .. "/mock/?.lua;" .. package.path
local verbose = arg[1] == "-v"

local factory = require("component_factory")

local failures, passes = 0, 0
local function check(cond, msg)
  if cond then
    passes = passes + 1
  else
    failures = failures + 1
    print("  FAIL: " .. msg)
  end
end
local function eq(a, b, msg)
  check(a == b, string.format("%s (expected %s, got %s)", msg, tostring(b), tostring(a)))
end
local function section(title) print("\n== " .. title) end

-- Installs a fake environment and (re)loads ocui modules against it.
local function install(env)
  package.loaded["component"] = env.component
  package.loaded["computer"] = env.computer
  package.loaded["event"] = env.event
  package.loaded["filesystem"] = env.filesystem
  package.loaded["tty"] = env.tty
  package.loaded["thread"] = env.thread
  package.loaded["shell"] = env.shell
  package.loaded["term"] = env.term
  package.loaded["process"] = env.process
  for name in pairs(package.loaded) do
    if name:match("^ocui%.") then package.loaded[name] = nil end
  end
  require("ocui.storage").use(env.storage)
end

-- Runs a program file the way OpenOS does: as a chunk receiving the
-- command-line arguments as `...`. Returns ok, error-or-return-value.
local function runApp(path, env, ...)
  install(env)
  local chunk, loadErr = loadfile(projectRoot .. "/" .. path)
  if not chunk then return false, loadErr end
  return pcall(chunk, ...)
end

-- Captures print/io.write/io.stderr output of fn.
local function captureOutput(fn)
  local out = {}
  local oldPrint, oldWrite, oldStderr = print, io.write, io.stderr
  print = function(...)
    local parts = {}
    for i, v in ipairs(table.pack(...)) do parts[i] = tostring(v) end
    table.insert(out, table.concat(parts, "\t") .. "\n")
  end
  io.write = function(...) for _, v in ipairs(table.pack(...)) do table.insert(out, tostring(v)) end end
  io.stderr = { write = function(_, ...) for _, v in ipairs(table.pack(...)) do table.insert(out, tostring(v)) end end }
  local results = table.pack(pcall(fn))
  print, io.write, io.stderr = oldPrint, oldWrite, oldStderr
  return table.concat(out), table.unpack(results, 1, results.n)
end

-- ============================================================ unit tests ==

section("unit: lsc.firstNumber")
install(factory.new({}))
local lsc = require("ocui.lsc")
eq(lsc.firstNumber("Avg EU IN: 1,234,567 (last 5 seconds)"), "1234567", "en grouping")
eq(lsc.firstNumber("Средний ввод EU: 1\194\160234\194\160567 (последние 5 секунд)"), "1234567", "ru NBSP grouping")
eq(lsc.firstNumber("Avg EU IN: 0 (last 5 seconds)"), "0", "zero is not merged with the interval")
eq(lsc.firstNumber("Avg EU IN: 12 (last 5 seconds)"), "12", "short value")
eq(lsc.firstNumber("Total wireless EU: \194\167c98,765,432,109,876,543,210 EU"), "98765432109876543210",
  "color code + huge value")
eq(lsc.firstNumber("kekztech.infodata.lapotronic_super_capacitor.avg_eu_in.sec\\\\1,500\\\\5"), "1500",
  "newer key\\\\arg wire format")
eq(lsc.firstNumber("no digits here"), nil, "no number")
eq(lsc.firstNumber(nil), nil, "nil line")

section("unit: lsc.decimalDiff")
eq(lsc.decimalDiff("100", "40"), 60, "small")
eq(lsc.decimalDiff("40", "100"), -60, "small negative")
eq(lsc.decimalDiff("123456789012345678901", "123456789012345678000"), 901, "21-digit exact diff")
eq(lsc.decimalDiff("100000000000000000000", "99999999999999999999"), 1, "borrow across all digits")
eq(lsc.decimalDiff("99999999999999999999", "100000000000000000000"), -1, "negative across lengths")
-- the float approach this replaces would get it wrong:
check(tonumber("123456789012345678901") - tonumber("123456789012345678000") ~= 901,
  "sanity: float subtraction really loses precision here")

section("unit: format")
local fmt = require("ocui.format")
eq(fmt.si(999), "999", "si below 1000")
eq(fmt.si(1234567), "1.23M", "si M")
eq(fmt.si(-2500), "-2.50K", "si negative")
eq(fmt.signedSi(2500), "+2.50K", "signed positive")
eq(fmt.si(1e30), "1000000.00Y", "si beyond Y doesn't crash")
eq(fmt.count(1e20), "100.0E", "count of a huge float doesn't use %d")
eq(fmt.duration(42), "42s", "duration s")
eq(fmt.duration(3725), "1h 2m", "duration h")
eq(fmt.duration(nil), "--", "duration nil")
eq(fmt.duration(math.huge), "--", "duration inf")
eq(fmt.bytes(4 * 1024 * 1024), "4.0M", "bytes")

section("unit: ae2 tracker")
do
  local env = factory.new({ maxPulls = 100, cpus = {
    { name = "A", storage = 1, coprocessors = 1, work = 100, rate = 10,
      output = { name = "x:out", label = "Out", size = 4 } },
    { name = "B", storage = 1, coprocessors = 1 }, -- idle
    { name = "C", storage = 1, coprocessors = 1, work = 50, rate = 5 }, -- no monitor
  } })
  install(env)
  local ae2 = require("ocui.ae2")
  local tracker = ae2.newTracker(env.computer.uptime)
  local me = env.component.me_interface
  local p1 = tracker:poll(me)
  eq(#p1, 3, "one entry per CPU")
  eq(p1[1].progress, 0, "fresh job starts at 0%")
  eq(p1[1].eta, nil, "no ETA before any progress is seen")
  eq(p1[2].busy, false, "idle CPU")
  eq(p1[2].progress, 1, "idle CPU reports 1")
  eq(p1[3].output, nil, "no Crafting Monitor -> no output")
  env.event.pull(5) -- advance 5 virtual seconds
  local p2 = tracker:poll(me)
  check(p2[1].progress > 0.45 and p2[1].progress < 0.55,
    "50% after 5s at 10/s of 100 (got " .. tostring(p2[1].progress) .. ")")
  check(p2[1].eta and math.abs(p2[1].eta - 5) < 0.5, "ETA ~5s (got " .. tostring(p2[1].eta) .. ")")
  check(p2[3].progress > 0.45 and p2[3].progress < 0.55, "progress works without a monitor too")
  eq(#ae2.busyOnly(p2), 2, "busyOnly")
  env.event.pull(6)
  local p3 = tracker:poll(me)
  eq(p3[1].busy, false, "job finished -> idle")
  eq(p3[1].progress, 1, "finished job reports 1")
end

-- ========================================================== GPU scenarios ==

local DASH = "apps/ae2_dashboard.lua"

local function dashScenario(title, opts, asserts)
  section("dashboard: " .. title)
  local env = factory.new(opts)
  local ok, err = runApp(DASH, env)
  local frame = env.gpu._lastFrame() or ""
  if verbose then print(frame) end
  asserts(ok, err, frame, env)
end

dashScenario("two CPUs, progress over time", {
  maxW = 80, maxH = 25, maxPulls = 3,
  cpus = {
    { name = "CPU-A", storage = 4 * 1024 * 1024, coprocessors = 4, work = 1000, rate = 50,
      output = { name = "gt:plate", label = "Steel Plate", size = 64 } },
    { name = "CPU-B", storage = 1024 * 1024, coprocessors = 1 },
  },
}, function(ok, err, frame)
  check(ok, "ran without error: " .. tostring(err))
  check(frame:find("CPU%-A"), "CPU-A panel title")
  check(frame:find("Steel Plate x64"), "output label + count")
  check(frame:find("storage: 4.0M"), "storage formatted")
  check(frame:find("crafting %d+%%  ETA"), "progress caption with ETA")
  check(not frame:find("crafting 0%%"), "progress moved off 0% after a few ticks")
  check(frame:find("idle"), "idle CPU shown")
  check(frame:find("└"), "borders intact")
end)

dashScenario("busy CPU without a Crafting Monitor", {
  maxPulls = 2, cpus = { { name = "", storage = 1024, coprocessors = 0, work = 10, rate = 1 } },
}, function(ok, err, frame)
  check(ok, "ran: " .. tostring(err))
  check(frame:find("Crafting CPU 1"), "unnamed CPU gets a numbered title")
  check(frame:find("no Crafting Monitor"), "explains the missing output")
end)

dashScenario("empty network", { maxPulls = 1, cpus = {} }, function(ok, err, frame)
  check(ok, "ran: " .. tostring(err))
  check(frame:find("No crafting CPUs"), "empty-state message")
end)

do
  section("dashboard: AE2 read error")
  local env = factory.new({ maxPulls = 1, cpus = {} })
  env.component.me_interface.getCpus = function() error("ME network offline (simulated)") end
  local ok, err = runApp(DASH, env)
  local frame = env.gpu._lastFrame() or ""
  if verbose then print(frame) end
  check(ok, "error is shown, not raised: " .. tostring(err))
  check(frame:find("AE2 read error"), "error message on screen")
end

dashScenario("tiny screen + unicode label", {
  maxW = 26, maxH = 8, maxPulls = 1,
  cpus = { { name = "", storage = 16 * 1024 * 1024, coprocessors = 8, work = 10, rate = 1,
    output = { name = "x", label = "Комплексный двигатель IV", size = 1 } } },
}, function(ok, err, frame)
  check(ok, "ran: " .. tostring(err))
  check(frame:find("Комплексный"), "cyrillic survives truncation")
end)

dashScenario("GPU without free VRAM (direct drawing fallback)", {
  noVram = true, maxPulls = 1, cpus = { { name = "N", storage = 1, coprocessors = 1 } },
}, function(ok, err, frame)
  check(ok, "ran: " .. tostring(err))
  check(frame:find("N"), "drew straight to the screen")
end)

do
  section("dashboard: touch/key events don't trigger extra AE2 polls")
  local polls = 0
  local env = factory.new({
    maxPulls = 12,
    events = { { "touch", "s", 1, 1, 0, "p" }, { "key_down", "k", 97, 30, "p" }, { "touch", "s", 2, 2, 0, "p" },
      { "key_up", "k", 97, 30, "p" }, { "touch", "s", 3, 3, 0, "p" } },
    cpus = { { name = "X", storage = 1, coprocessors = 1 } },
  })
  local real = env.component.me_interface.getCpus
  env.component.me_interface.getCpus = function() polls = polls + 1; return real() end
  local ok, err = runApp(DASH, env)
  check(ok, "ran: " .. tostring(err))
  -- 12 pulls = 5 instant events (~0.25 s total) + 7 timeouts. With the
  -- crafting service polling every 3 s, the number of polls is set by the
  -- elapsed time alone; the old "refresh after every signal" loop would
  -- have polled once per pull.
  local elapsed = env.clock() - 1000
  local expected = math.floor(elapsed / 3) + 1
  check(polls >= expected - 1 and polls <= expected,
    string.format("polls follow the 3s timer (%d polls in %.1fs), not the 12 signals", polls, elapsed))
end

-- ========================================================== HUD scenarios ==

local HUD = "apps/hud.lua"
local COLOR_CHARS = {
  [0x0F0F14] = false, -- panel background: leave blank for readability
  [0x2A2A38] = ".",   -- bar tracks / graph background
  [0x00A6FF] = "=",   -- energy fill
  [0x4C8BF5] = "=",   -- craft fill
  [0x4CD787] = "+",   -- positive flow bars / wireless fill
  [0xE0574C] = "-",   -- negative flow bars
  [0x8A8A96] = "_",   -- graph zero axis
}

local function hudScenario(title, opts, asserts)
  section("hud: " .. title)
  local env = factory.new(opts)
  local ok, err = runApp(HUD, env)
  local g = env.glasses[1]
  local snap = g and g._state().lastSnapshot or {}
  local art, texts = factory.renderGlasses(snap, COLOR_CHARS, 70, 45)
  local all = table.concat(texts, "\n")
  if verbose then
    print(art)
    print(all)
  end
  asserts(ok, err, all, env, art)
end

local LSC_EN = {
  stored = 400000000000000000, capacity = 900000000000000000, -- 18 digits: exact-diff path
  net = -1500000, avgIn = 1234567, avgOut = 2734567, wobble = 900000, lang = "en",
}

hudScenario("LSC (en sensor) + autocraft", {
  glasses = 1, maxPulls = 20, lsc = LSC_EN,
  cpus = {
    { name = "Main", storage = 1, coprocessors = 1, work = 600, rate = 20,
      output = { name = "gt:circuit", label = "Wetware Mainframe", size = 4 } },
    { name = "Aux", storage = 1, coprocessors = 1, work = 90, rate = 1 },
    { name = "Idle", storage = 1, coprocessors = 1 },
  },
}, function(ok, err, all, env, art)
  check(ok, "ran: " .. tostring(err))
  check(all:find("LSC"), "LSC title")
  check(all:find("%d+%.%d%%"), "fill percent")
  check(all:find("/ 900%.00P EU"), "stored / capacity")
  check(all:find("IN 1%.23M  OUT"), "sensor IN/OUT parsed from line 10/11")
  check(all:find("NET %-[%d%.]+[KM] EU/t  empty "), "negative net with time-to-empty")
  check(not all:find("MAINTENANCE"), "no maintenance warning")
  check(all:find("Autocraft  2/3 CPU"), "busy/total CPU count")
  check(all:find("Wetware Mainframe x4 %d+%% "), "craft row with output and percent")
  check(all:find("no monitor"), "row for CPU without monitor")
  check(art:find("%-"), "graph has negative (red) bars")
  check(art:find("="), "energy bar drawn")
  local pk = env.glasses[1]._state().packets
  check(pk < 3000, "packet count stays bounded by caching (" .. pk .. ")")
end)

hudScenario("LSC (ru sensor, NBSP grouping), wireless + maintenance problem", {
  glasses = 2, maxPulls = 6,
  lsc = { stored = 5, capacity = 1000, net = 0, avgIn = 5000000, avgOut = 1000000, lang = "ru",
    wireless = true, wirelessEU = 250000000000000, maintenanceOk = false },
}, function(ok, err, all)
  check(ok, "ran: " .. tostring(err))
  check(all:find("MAINTENANCE"), "maintenance warning from §c color code (language-agnostic)")
  check(all:find("wireless"), "wireless mode detected from §a color code")
  check(all:find("25%.0%%"), "wireless fill = wirelessEU / wirelessMax (2.5e14 / 1e15)")
  check(all:find("IN 5%.00M  OUT 1%.00M"), "ru lines parsed with NBSP separators")
  check(all:find("NET %+4%.00M EU/t"), "positive net")
  check(all:find("ME not found"), "crafting panel explains missing ME")
end)

hudScenario("LSC without sensor/string methods (derivative fallback)", {
  glasses = 1, maxPulls = 5,
  lsc = { stored = 1000000000, capacity = 2000000000, net = 2500, noSensor = true, noStringMethods = true },
}, function(ok, err, all)
  check(ok, "ran: " .. tostring(err))
  check(all:find("IN/OUT n/a"), "explains missing averages")
  check(all:find("NET %+2%.50K EU/t  full "), "net derived from stored delta: +2.5K EU/t")
end)

hudScenario("nothing connected but glasses", { glasses = 1, maxPulls = 2 }, function(ok, err, all)
  check(ok, "ran: " .. tostring(err))
  check(all:find("LSC not found"), "LSC hint")
  check(all:find("ME not found"), "ME hint")
end)

do
  section("hud: no glasses terminal")
  local env = factory.new({ maxPulls = 1 })
  local ok, err = runApp(HUD, env)
  check(not ok and tostring(err):find("No Glasses Terminal"), "clear error without glasses")
end

do
  section("hud: exit clears every terminal")
  local env = factory.new({ glasses = 2, maxPulls = 2, lsc = LSC_EN })
  local ok = runApp(HUD, env)
  check(ok, "ran")
  eq(env.glasses[1].getObjectCount(), 0, "terminal 1 cleared")
  eq(env.glasses[2].getObjectCount(), 0, "terminal 2 cleared")
end

-- ================================================================ loop ==

section("loop: cooperative tasks, sleep, errors")
do
  local env = factory.new({ maxPulls = 50 })
  install(env)
  local Loop = require("ocui.loop")
  local order = {}
  local loop = Loop.new()
  loop:spawn(function()
    for i = 1, 3 do table.insert(order, "a" .. i); Loop.yield() end
  end)
  loop:spawn(function()
    for i = 1, 3 do table.insert(order, "b" .. i); Loop.yield() end
    loop:stop()
  end)
  loop:run()
  eq(table.concat(order, ","), "a1,b1,a2,b2,a3,b3", "spawned tasks interleave at yield points")

  local ok, err = pcall(Loop.sleep, 1)
  check(not ok and tostring(err):find("outside a loop task"), "sleep outside a task is an error")

  -- every() doesn't overlap a run that is still sleeping
  local loop2 = Loop.new()
  local running, maxConcurrent, runs = 0, 0, 0
  loop2:every(1, function()
    running = running + 1
    maxConcurrent = math.max(maxConcurrent, running)
    runs = runs + 1
    Loop.sleep(3)
    running = running - 1
    if runs == 3 then loop2:stop() end
  end)
  loop2:run()
  eq(maxConcurrent, 1, "a periodic task never overlaps itself")

  -- errors go to onError with the owner, and cancelOwner stops everything
  local caught
  local loop3
  loop3 = Loop.new({ onError = function(e, owner)
    caught = owner
    loop3:cancelOwner(owner)
  end })
  local survivor = 0
  loop3:every(1, function() error("kaboom") end, "badOwner")
  loop3:every(1, function()
    survivor = survivor + 1
    if survivor == 4 then loop3:stop() end
  end, "goodOwner")
  loop3:run()
  eq(caught, "badOwner", "error attributed to its owner")
  eq(survivor, 4, "other owner's task kept running")
end

-- ============================================================== config ==

section("config: serialize, merge, load")
do
  local env = factory.new({})
  install(env)
  local config = require("ocui.config")
  local t = { b = 2, a = "x", nested = { flag = true, list = { 1, 2, 3 } }, [5] = "five" }
  local back = config.parse(config.serialize(t))
  check(back and back.a == "x" and back.nested.list[3] == 3 and back[5] == "five", "serialize/parse round trip")
  eq(config.serialize({ a = 0.55 }):match("a = ([^,]+)"), "0.55", "floats written in their shortest form")
  local tricky = { 0.1 + 0.2, 1 / 3, 1e15, 2.5e-7, 123456789.123 }
  local back2 = config.parse(config.serialize(tricky))
  local exact = true
  for i, v in ipairs(tricky) do if back2[i] ~= v then exact = false end end
  check(exact, "floats still read back exactly")
  local merged = config.merge({ a = 1, sub = { x = 1, y = 2 }, list = { "hud" } },
    { sub = { y = 5 }, list = { "dashboard", "x" } })
  check(merged.a == 1 and merged.sub.x == 1 and merged.sub.y == 5, "nested tables merge key by key")
  check(#merged.list == 2 and merged.list[1] == "dashboard", "arrays are replaced, not merged")

  local cfg = config.load("demo", { speed = 3 })
  eq(cfg.speed, 3, "defaults on first run")
  check(env.files["/etc/ocui/demo.cfg"] and env.files["/etc/ocui/demo.cfg"]:find("speed = 3"),
    "config file written with defaults")
  env.files["/etc/ocui/demo.cfg"] = "-- edited\n{ speed = 7, extra = 'y' }"
  eq(config.load("demo", { speed = 3, other = 1 }).speed, 7, "user value wins")
  eq(config.load("demo", { speed = 3, other = 1 }).other, 1, "new default key appears")
  env.files["/etc/ocui/demo.cfg"] = "{ speed = }"
  local broken, err = config.load("demo", { speed = 3 })
  check(broken == nil and tostring(err):find("demo.cfg"), "broken file reported with its path")
  local sandboxed = config.parse("{ x = os and os.exit or 'safe' }")
  eq(sandboxed and sandboxed.x, "safe", "config has no access to globals")
end

-- ================================================================ pool ==

-- Test app: counts ticks; optional failure on tick N / in start.
local function counterApp(name, opts)
  opts = opts or {}
  local app = { name = name, ticks = 0, stops = 0 }
  app.module = {
    name = name,
    description = "test app " .. name,
    start = function(ctx)
      if opts.failStart then error(name .. " cannot start") end
      if opts.claim then assert(ctx:claim(opts.claim)) end
      ctx:onStop(function() app.stops = app.stops + 1 end)
      ctx:every(opts.interval or 1, function()
        app.ticks = app.ticks + 1
        if opts.failOn and app.ticks % opts.failOn == 0 then error(name .. " exploded") end
      end)
    end,
  }
  return app
end

section("pool: crash isolation, restart with limit")
do
  local env = factory.new({ maxPulls = 80 })
  install(env)
  local Pool = require("ocui.pool")
  local good = counterApp("good")
  local bad = counterApp("bad", { failOn = 2 })
  local pool = Pool.new({ restartDelay = 2, maxRestarts = 2 })
  pool:register(good.module)
  pool:register(bad.module)
  pool:run()
  local st = {}
  for _, a in ipairs(pool:status()) do st[a.name] = a end
  check(good.ticks > 30, "healthy app kept ticking (" .. good.ticks .. ")")
  eq(st.bad.state, "failed", "crashing app ends failed")
  eq(st.bad.restarts, 2, "restarted exactly maxRestarts times")
  eq(bad.stops, 3, "cleanup ran on every crash")
  check(st.bad.error and st.bad.error:find("bad exploded"), "error kept for status")
  check((env.files[Pool.LOG_PATH] or ""):find("FAILED"), "failure logged with traceback")
  check(not tostring(st.bad.error):find("\n"), "status error is one line")
end

section("pool: start failure doesn't block others; idle pool exits")
do
  local env = factory.new({ maxPulls = 10 })
  install(env)
  local Pool = require("ocui.pool")
  local good = counterApp("good")
  local broken = counterApp("broken", { failStart = true })
  local pool = Pool.new({ maxRestarts = 0 })
  pool:register(broken.module)
  pool:register(good.module)
  pool:run()
  check(good.ticks > 0, "app after a broken one still started")
  local env2 = factory.new({ maxPulls = 10 })
  install(env2)
  local Pool2 = require("ocui.pool")
  local only = counterApp("only", { failStart = true })
  local pool2 = Pool2.new({ maxRestarts = 0 })
  pool2:register(only.module)
  pool2:run()
  eq(env2.pulls(), 0, "nothing running and nothing pending: run() returns at once")
end

section("pool: exclusive resources")
do
  local env = factory.new({ maxPulls = 5 })
  install(env)
  local Pool = require("ocui.pool")
  local a = counterApp("a", { claim = "screen:screen-1" })
  local b = counterApp("b", { claim = "screen:screen-1" })
  local pool = Pool.new({ maxRestarts = 0 })
  pool:register(a.module)
  pool:register(b.module)
  pool:run()
  local st = {}
  for _, x in ipairs(pool:status()) do st[x.name] = x end
  eq(st.b.state, "failed", "second claimant fails")
  check(st.b.error and st.b.error:find("in use by a"), "error names the holder")
  check(a.ticks > 0, "first claimant runs")
end

section("pool: two screens, touch routed to the right app")
do
  local env = factory.new({ gpus = 2, maxPulls = 6,
    events = { false, { "touch", "screen-2", 3, 2, 0, "player" } } })
  install(env)
  local Pool = require("ocui.pool")
  local App = require("ocui.app")
  local base = require("ocui.widget")
  local touched = {}
  local function screenApp(name, gpuAddress)
    return {
      name = name,
      start = function(ctx)
        local root = base.Container.new({})
        root.onTouch = function() touched[name] = (touched[name] or 0) + 1; return true end
        App.new({ root = root, gpu = gpuAddress, tickInterval = 1 }):mount(ctx)
      end,
    }
  end
  local pool = Pool.new({ maxRestarts = 0 })
  pool:register(screenApp("left", "gpu-1"))
  pool:register(screenApp("right", "gpu-2"))
  pool:run()
  for _, x in ipairs(pool:status()) do
    check(x.state ~= "failed", x.name .. " ran: " .. tostring(x.error))
  end
  eq(touched.right, 1, "touch on screen-2 reached the app on screen-2")
  eq(touched.left, nil, "app on screen-1 ignored it")
end

section("pool: background mode")
do
  local env = factory.new({
    glasses = 1, maxPulls = 14, shellScreen = "screen-1",
    lsc = LSC_EN, cpus = {},
    endSignal = { "ocpool", "quit" },
    events = {
      false,
      { "key_down", "kb", 113, 16, "player" },   -- 'q' typed in the shell
      { "interrupted", 1 },                       -- Ctrl+C in the shell
      false,
      { "ocpool", "status", nil, "r1" },
      { "ocpool", "stop", "hud", "r2" },
      false,
      { "ocpool", "start", "hud", "r3" },
      { "ocpool", "start", "dashboard", "r4" },
      false,
    },
  })
  install(env)
  local Pool = require("ocui.pool")
  local pool = Pool.new({ background = true, shellScreen = "screen-1", stopWhenIdle = false })
  pool:register(require("ocui.apps.hud"))
  pool:register(require("ocui.apps.dashboard"))
  pool:run({ "hud" })
  local replies = {}
  for _, sig in ipairs(env.pushed) do
    if sig[1] == "ocpool_reply" then replies[sig[2]] = { ok = sig[3], text = sig[4] } end
  end
  check(env.pulls() > 10, "'q' and Ctrl+C didn't stop the background pool")
  check(replies.r1 and replies.r1.ok, "status replied")
  local status = replies.r1 and require("ocui.config").parse(replies.r1.text)
  check(status and status.apps[1].name == "hud" and status.apps[1].state == "running",
    "status lists hud as running")
  check(replies.r2 and replies.r2.ok, "remote stop ok")
  check(replies.r3 and replies.r3.ok, "remote start ok")
  check(replies.r4 and replies.r4.ok == false and replies.r4.text:find("shell's screen"),
    "dashboard refused the shell's screen in the background")
  eq(env.glasses[1].getObjectCount(), 0, "quit tore the HUD down")
end

-- ============================================================== ocpool ==

local OCPOOL = "apps/ocpool.lua"

section("ocpool CLI")
do
  local env = factory.new({})
  local out = captureOutput(function() return runApp(OCPOOL, env, "list") end)
  check(out:find("hud%s+AR glasses"), "list shows hud with description")
  check(out:find("dashboard%s+AE2"), "list shows dashboard")

  env = factory.new({})
  local out2, _, ok, code = captureOutput(function() return runApp(OCPOOL, env, "status") end)
  check(out2:find("no background pool is running"), "status without a pool")
  eq(code, 1, "status without a pool exits 1")

  env = factory.new({})
  local out3 = captureOutput(function() return runApp(OCPOOL, env, "nope") end)
  check(out3:find("cannot load app 'nope'"), "unknown app reported")

  -- foreground: HUD and dashboard side by side on one loop
  env = factory.new({ glasses = 1, maxPulls = 12, lsc = LSC_EN,
    cpus = { { name = "CPU-A", storage = 1, coprocessors = 1, work = 500, rate = 10,
      output = { name = "x:y", label = "Quantum Chip", size = 2 } } } })
  local out4 = captureOutput(function() return runApp(OCPOOL, env, "hud", "dashboard") end)
  check(out4:find("running hud, dashboard"), "foreground banner")
  local snap = env.glasses[1]._state().lastSnapshot or {}
  local _, texts = factory.renderGlasses(snap, {}, 70, 45)
  local hudText = table.concat(texts, "\n")
  check(hudText:find("Autocraft  1/1 CPU") and hudText:find("LSC"), "HUD ran")
  check((env.gpu._lastFrame() or ""):find("Quantum Chip x2"), "dashboard ran at the same time")

  -- bare `ocpool` uses autostart from /etc/ocui/ocpool.cfg (created: hud)
  env = factory.new({ glasses = 1, maxPulls = 3 })
  local out5 = captureOutput(function() return runApp(OCPOOL, env) end)
  check(out5:find("running hud "), "autostart default is hud")
  check(env.files["/etc/ocui/ocpool.cfg"], "ocpool.cfg created")

  -- background: detached thread; q in the shell ignored; quit by signal
  env = factory.new({ glasses = 1, maxPulls = 6, lsc = LSC_EN,
    endSignal = { "ocpool", "quit" },
    events = { false, { "key_down", "kb", 113, 16, "player" }, false } })
  local out6 = captureOutput(function() return runApp(OCPOOL, env, "-b", "hud") end)
  check(out6:find("in the background"), "background banner")
  check(env.threads[1] and env.threads[1].detached, "pool runs in a detached thread")
  check(env.pulls() > 4, "background pool ignored 'q'")
end

-- ============================================================ services ==

-- Finds the nth occurrence of `text` in a dumped screen; returns 1-based
-- column (in codepoints) and row, or nil.
local function findText(frame, text, nth)
  nth = nth or 1
  local row = 0
  for line in (frame .. "\n"):gmatch("(.-)\n") do
    row = row + 1
    local from = 1
    while true do
      local s = line:find(text, from, true)
      if not s then break end
      nth = nth - 1
      if nth == 0 then
        return utf8.len(line:sub(1, s - 1)) + 1, row
      end
      from = s + 1
    end
  end
  return nil
end

-- Script entry: a touch on the nth occurrence of `text` on the screen, or a
-- timeout if it isn't there (the assertion on the result will then fail).
local function touchText(envRef, text, nth, dx)
  return function()
    local x, y = findText(envRef().gpu._screen(), text, nth)
    if not x then return false end
    return { "touch", "screen-1", x + (dx or 0), y, 0, "player" }
  end
end

-- Visible HUD texts: the live widgets, or (after the app exited and
-- cleared the glasses) the last state before that clear.
local function glassesTexts(env)
  local g = env.glasses[1]
  local snap = g._snapshot()
  if #snap == 0 then snap = g._state().lastSnapshot or {} end
  local _, texts = factory.renderGlasses(snap, {}, 70, 45)
  return table.concat(texts, "\n")
end

section("services: one AE2 poll and one LSC read for all apps")
do
  local env = factory.new({ glasses = 1, maxPulls = 30, lsc = LSC_EN,
    cpus = { { name = "A", storage = 1, coprocessors = 1, work = 900, rate = 5,
      output = { name = "x:y", label = "Thing", size = 1 } } } })
  install(env)
  local getCpus, sensor = 0, 0
  local realCpus = env.component.me_interface.getCpus
  env.component.me_interface.getCpus = function() getCpus = getCpus + 1; return realCpus() end
  local realSensor = env.component.gt_machine.getSensorInformation
  env.component.gt_machine.getSensorInformation = function() sensor = sensor + 1; return realSensor() end
  local Pool = require("ocui.pool")
  local pool = Pool.new({ maxRestarts = 0 })
  pool:register(require("ocui.apps.hud"))
  pool:register(require("ocui.apps.dashboard"))
  pool:run({ "hud", "dashboard" })
  local elapsed = env.clock() - 1000
  check(getCpus <= math.floor(elapsed / 3) + 1,
    string.format("AE2 polled once per 3s for both apps (%d polls in %.1fs)", getCpus, elapsed))
  check(sensor <= math.floor(elapsed) + 1,
    string.format("LSC read once per second (%d reads in %.1fs)", sensor, elapsed))
  check((env.gpu._lastFrame() or ""):find("Thing x1"), "dashboard got data from the service")
  check(glassesTexts(env):find("Thing x1"), "HUD got the same data")
end

section("energy service: history windows and stats")
do
  install(factory.new({}))
  local energyMod = require("ocui.services.energy")
  local s = energyMod.newSeries(30, 4)
  -- buckets align to absolute time: 1020 is a multiple of 30
  for t = 0, 59 do s:add(1020 + t, { net = t < 30 and 100 or -50, avgIn = 200, avgOut = 100, fill = t / 100 }) end
  local pts = s:list()
  eq(#pts, 2, "60 one-second samples -> two 30 s buckets")
  eq(pts[1].net, 100, "bucket average")
  eq(pts[2].partial, true, "the open bucket is marked partial")
  local st = s:stats(1080)
  eq(st.netMin, -50, "window min")
  eq(st.netMax, 100, "window max")
  check(math.abs(st.euIn - 200 * 20 * 60) < 1, "EU in = 200 EU/t over 60 s (" .. tostring(st.euIn) .. ")")
  for t = 60, 400 do s:add(1020 + t, { net = 1 }) end
  check(#s:list() <= 4, "series keeps at most `points` entries")
end

section("services linger: HUD restart keeps the energy history")
do
  local env = factory.new({ glasses = 1, maxPulls = 60, lsc = LSC_EN, endSignal = { "ocpool", "quit" } })
  install(env)
  local Pool = require("ocui.pool")
  local pool = Pool.new({ maxRestarts = 0, serviceLinger = 5, stopWhenIdle = false, remote = true })
  pool:register(require("ocui.apps.hud"))
  local energyApi
  pool:register({ name = "probe", start = function(ctx)
    ctx:every(1, function()
      local up = env.clock() - 1000
      if up > 10 and up < 11.5 then pool:restart("hud") end
      if up > 30 and up < 31.5 then pool:stop("hud") end
    end)
  end })
  pool:register({ name = "reader", start = function(ctx)
    ctx:every(100, function() end)
  end })
  local origStart = pool.startRecord
  local energyStarts = 0
  pool.startRecord = function(self, rec)
    if rec.name == "energy" then energyStarts = energyStarts + 1 end
    if rec.name == "energy" then
      local ok, err = origStart(self, rec)
      energyApi = rec.facade
      return ok, err
    end
    return origStart(self, rec)
  end
  pool:run({ "hud", "probe" })
  eq(energyStarts, 1, "energy service survived the HUD restart (started once)")
  eq(pool.services.energy.state, "stopped", "and stopped after its last user left + linger")
  check(energyApi ~= nil, "facade handed out")
  local value, err = energyApi.latest()
  check(value == nil and tostring(err):find("unavailable"), "facade reports a stopped service")
end

-- =============================================================== hud v2 ==

section("hud: anchors and screen size from the glasses")
do
  local env = factory.new({ glasses = 1, maxPulls = 8, lsc = LSC_EN,
    events = { false, false, { "glasses_on", "glasses-1", "player", 800, 450 }, false, false } })
  install(env)
  require("ocui.config").save("hud", { lsc = { anchor = "top-right", x = 6, y = 6 }, crafting = { enabled = false } })
  local ok, err = runApp(HUD, env)
  check(ok, "ran: " .. tostring(err))
  local snap = env.glasses[1]._state().lastSnapshot or {}
  local lscX
  for _, w in ipairs(snap) do
    if w.kind == "text" and w.text == "LSC" and w.visible then lscX = w.x end
  end
  eq(lscX, 800 - 190 - 6 + 4, "top-right anchor re-placed for the 800 px wide screen")
  local saved = require("ocui.config").parse((env.files["/etc/ocui/hud.cfg"] or ""):gsub("^%-%-[^\n]*\n", ""))
  local prof = saved and saved.profiles and saved.profiles["glasses-1"]
  check(prof and prof.screen.w == 800 and prof.screen.h == 450, "screen size remembered in the terminal's profile")
  check(saved and saved.default.screen.w == 640, "template keeps its own screen size")
  check(not glassesTexts(env):find("Autocraft"), "disabled autocraft panel not drawn")
end

section("hud: autocraft hidden -> AE2 not polled")
do
  local env = factory.new({ glasses = 1, maxPulls = 10, lsc = LSC_EN,
    cpus = { { name = "A", storage = 1, coprocessors = 1, work = 100, rate = 1 } } })
  install(env)
  require("ocui.config").save("hud", { crafting = { enabled = false } })
  local polls = 0
  local real = env.component.me_interface.getCpus
  env.component.me_interface.getCpus = function() polls = polls + 1; return real() end
  local ok, err = runApp(HUD, env)
  check(ok, "ran: " .. tostring(err))
  eq(polls, 0, "no AE2 calls while the autocraft panel is off")
  local snap = env.glasses[1]._state().lastSnapshot or {}
  local _, texts = factory.renderGlasses(snap, {}, 70, 45)
  check(not table.concat(texts, "\n"):find("Autocraft"), "panel not drawn")
end

section("hud: config from the first version is migrated")
do
  local env = factory.new({ glasses = 1, maxPulls = 3, lsc = LSC_EN })
  install(env)
  env.files["/etc/ocui/hud.cfg"] = "{ x = 20, y = 30, width = 210, lsc = { interval = 2, address = false }, crafting = { interval = 5 } }"
  local ok, err = runApp(HUD, env)
  check(ok, "ran: " .. tostring(err))
  local cfg = require("ocui.config").parse(env.files["/etc/ocui/hud.cfg"]:gsub("^%-%-[^\n]*\n", ""))
  check(cfg and cfg.default.lsc.x == 20 and cfg.default.lsc.y == 30, "old origin became the template's LSC offset")
  check(cfg and cfg.x == nil and cfg.lsc == nil and cfg.default.lsc.interval == nil
    and cfg.default.crafting.interval == nil, "legacy keys removed")
  eq(cfg and cfg.default.width, 210, "other settings kept")
  local prof = cfg and cfg.profiles["glasses-1"]
  check(prof and prof.lsc.x == 20 and prof.width == 210, "the connected terminal got a copy of it")
  eq(prof and prof.label, "player", "profile labelled with the bound player")
end

section("hud: panel heights fit their content")
do
  install(factory.new({}))
  local hudApp = require("ocui.apps.hud")
  local cfg = require("ocui.config").copy(hudApp.PROFILE_DEFAULTS)
  local full = hudApp.heights(cfg).lsc
  cfg.lsc.showGraph = false
  local noGraph = hudApp.heights(cfg).lsc
  cfg.lsc.showFlow = false
  local minimal = hudApp.heights(cfg).lsc
  check(full > noGraph and noGraph > minimal, "hiding parts shrinks the panel")
  eq(full - noGraph, 10 + 1 + 34 + 3 - 10, "graph accounts for exactly its rows")
  eq(hudApp.heights(cfg, 3).crafting - hudApp.heights(cfg, 2).crafting, 16, "one row = 16 px")
end

-- ============================================================ profiles ==

-- Visible texts on one terminal: live widgets, or the state before the
-- final clear when the app has exited.
local function terminalTexts(g)
  local snap = g._snapshot()
  if #snap == 0 then snap = g._state().lastSnapshot or {} end
  local _, texts = factory.renderGlasses(snap, {}, 70, 45)
  return table.concat(texts, "\n")
end

local function savedHudCfg(env)
  return require("ocui.config").parse((env.files["/etc/ocui/hud.cfg"] or ""):gsub("^%-%-[^\n]*\n", ""))
end

section("hud profiles: one per terminal")
do
  local env = factory.new({ glasses = 3, maxPulls = 10, lsc = LSC_EN,
    glassesPlayers = { { "Bogdan" }, { "Alex", "Max" }, {} },
    cpus = { { name = "A", storage = 1, coprocessors = 1, work = 900, rate = 5,
      output = { name = "x:y", label = "Chip", size = 1 } } },
    events = { false, { "glasses_on", "glasses-2", "Alex", 800, 450 }, false } })
  install(env)
  require("ocui.config").save("hud", {
    profiles = {
      ["glasses-1"] = { label = "Bogdan", crafting = { enabled = false } },
      ["glasses-2"] = { label = "Alex", lsc = { enabled = false } },
    },
  })
  local ok, err = runApp(HUD, env)
  check(ok, "ran: " .. tostring(err))
  local t1, t2, t3 = terminalTexts(env.glasses[1]), terminalTexts(env.glasses[2]), terminalTexts(env.glasses[3])
  check(t1:find("LSC") and not t1:find("Autocraft"), "terminal 1: LSC only (its profile)")
  check(t2:find("Autocraft") and not t2:find("LSC"), "terminal 2: autocraft only (its profile)")
  check(t3:find("LSC") and t3:find("Autocraft"), "terminal 3: new, gets the full template")

  local cfg = savedHudCfg(env)
  local p3 = cfg and cfg.profiles["glasses-3"]
  check(p3 ~= nil, "profile created for the new terminal")
  eq(p3 and p3.label, "terminal glasses-", "no bound players -> labelled by address")
  eq(cfg and cfg.profiles["glasses-2"].screen.w, 800, "glasses_on updated terminal 2's screen")
  eq(cfg and cfg.profiles["glasses-1"].screen.w, 640, "terminal 1's screen untouched")
  check(cfg and cfg.profiles["glasses-1"].crafting.enabled == false, "existing profile kept as configured")
end

section("hud profiles: switched-off terminal, labels, hot-plug")
do
  local env
  local events = { false, false }
  table.insert(events, function()
    local address = env.addGlasses({ "Newbie" })
    return { "component_added", address, "glasses" }
  end)
  for _ = 1, 3 do table.insert(events, false) end
  env = factory.new({ glasses = 2, maxPulls = #events, events = events, lsc = LSC_EN,
    glassesPlayers = { { "Bogdan" }, { "Alex" } } })
  install(env)
  require("ocui.config").save("hud", { profiles = { ["glasses-2"] = { label = "Alex", enabled = false } } })
  local ok, err = runApp(HUD, env)
  check(ok, "ran: " .. tostring(err))
  check(terminalTexts(env.glasses[1]):find("LSC"), "terminal 1 shows the HUD")
  eq(terminalTexts(env.glasses[2]), "", "switched-off terminal stays empty")
  check(terminalTexts(env.glasses[3]):find("LSC"), "terminal plugged in at runtime got a HUD")
  local cfg = savedHudCfg(env)
  eq(cfg and cfg.profiles["glasses-1"].label, "Bogdan", "new profile labelled with the bound player")
  eq(cfg and cfg.profiles["glasses-3"] and cfg.profiles["glasses-3"].label, "Newbie",
    "hot-plugged terminal's profile saved")
  eq(cfg and cfg.profiles["glasses-2"].enabled, false, "switch-off kept")
end

section("hudctl profiles: picker and apply-to-all")
do
  local env
  local envRef = function() return env end
  local events = { false, false, false }
  -- two terminals -> starts on the template; apply it to every terminal
  table.insert(events, touchText(envRef, "Apply to all terminals"))
  for _ = 1, 10 do table.insert(events, false) end
  env = factory.new({ glasses = 2, maxPulls = #events, events = events, lsc = LSC_EN,
    glassesPlayers = { { "Bogdan" }, { "Alex" } } })
  install(env)
  require("ocui.config").save("hud", {
    default = { width = 230 },
    profiles = {
      ["glasses-1"] = { label = "Bogdan", width = 150, screen = { w = 800, h = 450 } },
      ["glasses-2"] = { label = "Alex", width = 170, enabled = false },
    },
  })
  local Pool = require("ocui.pool")
  local pool = Pool.new({ maxRestarts = 0 })
  pool:register(require("ocui.apps.hud"))
  pool:register(require("ocui.apps.hudctl"))
  local restarts = 0
  local origRestart = pool.restart
  pool.restart = function(self, name) restarts = restarts + 1; return origRestart(self, name) end
  local firstFrame
  pool:register({ name = "peek", start = function(ctx)
    ctx:every(0.5, function()
      firstFrame = firstFrame or (env.gpu._screen():find("Profile") and env.gpu._screen())
    end)
  end })
  pool:run({ "hud", "hudctl", "peek" })
  check(firstFrame and firstFrame:find("Profile: < Default %(new terminals%) >"),
    "several terminals -> the template is selected")
  local cfg = savedHudCfg(env)
  local p1, p2 = cfg and cfg.profiles["glasses-1"], cfg and cfg.profiles["glasses-2"]
  check(p1 and p1.width == 230 and p2 and p2.width == 230, "template copied into every profile")
  check(p1 and p1.label == "Bogdan" and p1.screen.w == 800, "terminal's label and screen kept")
  check(p2 and p2.enabled == false, "terminal's on/off switch kept")
  eq(restarts, 1, "HUD restarted once to show it")
end

-- ============================================================== hudctl ==

section("hudctl: toggle, live move, energy tab")
do
  local env
  local envRef = function() return env end
  local events = { false, false, false }
  -- 1) hide the autocraft panel (second "Show panel" = right column)
  table.insert(events, touchText(envRef, "Show panel", 2))
  for _ = 1, 8 do table.insert(events, false) end
  -- 2) nudge the LSC panel +10 px to the right. The first "[+10]" on
  --    screen is the autocraft panel's Offset X (row 9, now disabled);
  --    the LSC one is the second.
  table.insert(events, touchText(envRef, "[+10]", 2))
  table.insert(events, false)
  table.insert(events, function() env.markX = true; return false end)
  for _ = 1, 8 do table.insert(events, false) end
  -- 3) open the Energy tab
  table.insert(events, touchText(envRef, " Energy "))
  for _ = 1, 4 do table.insert(events, false) end
  env = factory.new({ glasses = 1, maxPulls = #events, events = events, lsc = LSC_EN,
    cpus = { { name = "A", storage = 1, coprocessors = 1, work = 10000, rate = 1,
      output = { name = "x:y", label = "Chip", size = 1 } } } })
  install(env)
  local Pool = require("ocui.pool")
  local pool = Pool.new({ maxRestarts = 0, serviceLinger = 1 })
  pool:register(require("ocui.apps.hud"))
  pool:register(require("ocui.apps.hudctl"))
  local restarts = 0
  local origRestart = pool.restart
  pool.restart = function(self, name) restarts = restarts + 1; return origRestart(self, name) end
  -- record where the HUD's LSC title is at each moment
  local lscXs = {}
  pool:register({ name = "watch", start = function(ctx)
    ctx:every(0.25, function()
      for _, w in ipairs(env.glasses[1]._snapshot()) do
        if w.kind == "text" and w.text == "LSC" and w.visible then table.insert(lscXs, w.x) end
      end
    end)
  end })
  pool:run({ "hud", "hudctl", "watch" })
  for _, a in ipairs(pool:status()) do
    check(a.state ~= "failed", a.name .. " ok: " .. tostring(a.error))
  end
  local cfg = require("ocui.config").parse((env.files["/etc/ocui/hud.cfg"] or ""):gsub("^%-%-[^\n]*\n", ""))
  local prof = cfg and cfg.profiles["glasses-1"]
  check(prof and prof.crafting.enabled == false, "toggle saved in the terminal's profile")
  check(prof and prof.lsc.x == 16, "nudge saved: lsc.x 6 -> 16 (got " .. tostring(prof and prof.lsc.x) .. ")")
  check(cfg and cfg.default.crafting.enabled == true, "template untouched")
  eq(restarts, 1, "hiding a panel restarted the HUD once; the move didn't")
  check(lscXs[1] == 10 and lscXs[#lscXs] == 20, "LSC panel moved live from x=10 to x=20")
  check(not glassesTexts(env):find("Autocraft"), "HUD rebuilt without the autocraft panel")
  local frame = env.gpu._lastFrame() or ""
  if verbose then print(frame) end
  check(frame:find("Net flow, EU/t"), "energy tab rendered")
  check(frame:find("Stored 400"), "energy numbers shown")
  check(frame:find("\226\150\136") or frame:find("\226\150\132") or frame:find("\226\150\128"),
    "chart drawn with half blocks")
  eq(pool.services.crafting and pool.services.crafting.state, "stopped",
    "crafting service stopped once nobody used it")
end

section("hudctl: remote mode (HUD in a background pool)")
do
  local env
  local envRef = function() return env end
  local events = { false, false, false, false, false }
  table.insert(events, touchText(envRef, "[+10]", 2))          -- LSC Offset X +10 (live)
  for _ = 1, 6 do table.insert(events, false) end
  table.insert(events, touchText(envRef, "Flow graph"))        -- structural -> restart
  -- status polling keeps a few signals queued, so allow plenty of pulls
  for _ = 1, 30 do table.insert(events, false) end
  env = factory.new({ glasses = 1, maxPulls = #events, events = events, lsc = LSC_EN })
  install(env)
  local Pool = require("ocui.pool")
  local configLib = require("ocui.config")
  configLib.save("hud", { profiles = { ["glasses-1"] = { label = "Bogdan" } } })
  local pool = Pool.new({ maxRestarts = 0 })
  pool:register(require("ocui.apps.hudctl"))
  -- stand-in for the background pool: answers status, records commands
  local commands, layouts = {}, {}
  pool:register({ name = "bgpool", start = function(ctx)
    ctx:on("ocpool", function(_, cmd, arg, replyId)
      if cmd == "status" and replyId then
        env.computer.pushSignal("ocpool_reply", replyId, true,
          configLib.serialize({ apps = { { name = "hud", state = "running", restarts = 0 } } }))
      elseif arg == "hud" then
        table.insert(commands, cmd)
      end
    end)
    ctx:on("ocui_hud_layout", function(_, text) table.insert(layouts, configLib.parse(text)) end)
  end })
  pool:run({ "hudctl", "bgpool" })
  local hudFrame = env.gpu._lastFrame() or ""
  if verbose then print(hudFrame) end
  check(hudFrame:find("HUD: running %(background pool%)"), "status learned from the background pool")
  check(#layouts >= 1 and layouts[1].lsc.x == 16 and layouts[1].profile == "glasses-1",
    "live move for that terminal sent as ocui_hud_layout signal (x=16)")
  eq(commands[#commands], "restart", "structural edit restarted the remote HUD")
  local cfg = configLib.parse((env.files["/etc/ocui/hud.cfg"] or ""):gsub("^%-%-[^\n]*\n", ""))
  local prof = cfg and cfg.profiles["glasses-1"]
  check(prof and prof.lsc.showGraph == false and prof.lsc.x == 16, "both edits saved to the profile")
end

-- ============================================================= install ==

-- ========================================================== foundation ==

section("unit: util text helpers")
do
  install(factory.new({}))
  local util = require("ocui.util")
  eq(util.sub("приветмир", 3, 6), "ивет", "sub counts characters")
  eq(util.sub("abc", 2), "bc", "sub to the end")
  eq(util.char(65), "A", "char ascii")
  eq(util.char(1078), "ж", "char cyrillic")
  eq(util.char(0x2500), "─", "char 3-byte")
  eq(util.pad("ab", 4, "right"), "  ab", "pad right")
  eq(util.pad("abcdef", 3), "abc", "pad truncates")
  eq(util.ellipsis("abcdef", 4), "abc…", "ellipsis")
  local lines = util.wrap("one two three four", 9)
  eq(#lines, 3, "wrap line count")
  eq(lines[1], "one two", "wrap first line")
  eq(#util.wrap("a\n\nb", 10), 3, "wrap keeps blank lines")
end

section("unit: key events")
do
  install(factory.new({}))
  local keys = require("ocui.keys")
  local ev = keys.event(97, 30, {})
  eq(ev.text, "a", "typed letter")
  eq(ev.combo, "a", "plain combo")
  ev = keys.event(19, 31, { ctrl = true })
  eq(ev.text, nil, "ctrl+s types nothing")
  eq(ev.combo, "ctrl+s", "ctrl combo name")
  ev = keys.event(1078, 39, {})
  eq(ev.text, "ж", "cyrillic char from its code")
  ev = keys.event(64, 16, { ctrl = true, alt = true })
  eq(ev.text, "@", "AltGr (ctrl+alt) still types")
  ev = keys.event(13, 28, {})
  eq(ev.name, "enter", "enter named")
  eq(ev.text, nil, "enter is not text")
  eq(keys.event(9, 15, { shift = true }).combo, "shift+tab", "shift+tab")
end

section("canvas: text clipped on the left")
do
  local env = factory.new({ maxW = 20, maxH = 3 })
  install(env)
  local Canvas = require("ocui.canvas")
  local c = Canvas.new(env.gpu, 0, 0, 20, 3, 5, 0, 5, 1, {})
  c:text(2, 0, "abcdefghij", 0xFFFFFF, 0)
  eq(env.gpu._screen():sub(1, 12), "     defgh  ", "only the clipped middle is drawn")
end

section("mock filesystem")
do
  local env = factory.new({ files = { ["/home/a.txt"] = "hello" } })
  install(env)
  local fs = env.filesystem
  check(fs.isDirectory("/home"), "parent of a file is a directory")
  fs.makeDirectory("/home/sub/deep")
  local names = {}
  for n in fs.list("/home") do names[#names + 1] = n end
  eq(table.concat(names, ","), "a.txt,sub/", "list marks directories")
  local h = fs.open("/home/b.txt", "w")
  h:write("xyz")
  h:close()
  eq(env.files["/home/b.txt"], "xyz", "files written through the API are in the shared table")
  eq(fs.size("/home/b.txt"), 3, "size")
  check(fs.rename("/home/sub", "/home/moved"), "rename directory")
  check(fs.isDirectory("/home/moved/deep"), "subdirectories move along")
  check(fs.remove("/home"), "recursive remove")
  check(not fs.exists("/home/a.txt"), "removed")
end

section("host: damage rectangles merge")
do
  install(factory.new({}))
  local Host = require("ocui.host")
  local h = Host.new({})
  h.w, h.h = 160, 50
  h:damage(0, 3, 70, 1)
  h:damage(0, 4, 70, 1)
  eq(#h.damageList, 1, "adjacent rows merge")
  h:damage(0, 30, 70, 1)
  eq(#h.damageList, 2, "distant rows stay apart")
  h:damage(-5, 49, 400, 9)
  local r = h.damageList[#h.damageList]
  eq(r.x .. "," .. r.w .. "," .. r.h, "0,160,1", "clipped to the screen")
  check(h.framePending, "a frame is pending")
end

-- Runs uidemo on a 160x50 screen with the given events script; returns
-- env and the app module. `interrupted` ends the run.
local function runDemo(events, opts)
  opts = opts or {}
  opts.maxW, opts.maxH = 160, 50
  opts.events = events
  opts.endSignal = { "interrupted", 0 }
  local env = factory.new(opts)
  local ok, err = runApp("apps/uidemo.lua", env)
  check(ok, "uidemo ran: " .. tostring(err))
  return env, package.loaded["ocui.apps.uidemo"]
end

local function screenOf(env) return env.gpu._screen() end

section("uidemo: first frame, keyboard navigation, partial redraw cost")
do
  local env
  local seen = {}
  local function snap(key) return function() seen[key] = screenOf(env); return false end end
  local function budget(key) return function() seen[key] = env.gpu._budget(); env.gpu._resetBudget(); return false end end
  local events = factory.script(
    snap("start"), budget("startup"),
    factory.press("down"), budget("down"), snap("afterDown"),
    factory.press("tab"), factory.typeText("Xq"), budget("typing"), snap("typed"),
    factory.press("enter"), snap("saved"),
    factory.press("ctrl+q")
  )
  env = factory.new({ maxW = 160, maxH = 50, events = events, endSignal = { "interrupted", 0 } })
  local ok, err = runApp("apps/uidemo.lua", env)
  check(ok, "uidemo ran: " .. tostring(err))
  local demo = package.loaded["ocui.apps.uidemo"]
  check(seen.start and findText(seen.start, "File"), "menu bar drawn")
  check(seen.start and findText(seen.start, "Copper"), "list rows drawn")
  check(seen.start and findText(seen.start, "Аметист"), "UTF-8 item drawn")
  check(seen.start and findText(seen.start, "^Q Quit"), "status bar hints drawn")
  check(seen.startup and seen.startup <= 2.2, "startup is one full-screen copy (budget " .. tostring(seen.startup) .. ")")
  check(seen.down and seen.down < 0.2,
    "moving the selection repaints a few rows only (budget " .. tostring(seen.down) .. ", full screen = 2.0)")
  eq(demo.list.selected, 2, "Down selects the next row")
  check(seen.typing and seen.typing < 0.3, "typing costs little (budget " .. tostring(seen.typing) .. ")")
  check(seen.typed and findText(seen.typed, "TinXq"), "typed text in the name field, 'q' did not quit")
  check(seen.saved and findText(seen.saved, "Saved TinXq"), "Enter saved through onSubmit")
  eq(demo.list.items[2].name, "TinXq", "item renamed")
  check(env.pulls() < #events + 5, "Ctrl+Q quit the app")
end

section("uidemo: dialogs, menus, running a program")
do
  local env
  local seen = {}
  local function snap(key) return function() seen[key] = screenOf(env); return false end end
  local events = factory.script(
    false,
    factory.press("ctrl+n"), snap("newDialog"), factory.typeText("Gold"), factory.press("enter"), snap("added"),
    factory.press("delete"), snap("confirm"), factory.press("enter"), snap("deleted"),
    factory.press("f10"), snap("menu"), factory.press("escape"), snap("menuClosed"),
    factory.press("f10"), factory.press("down"), factory.press("down"), factory.press("down"),
    factory.press("enter"), snap("runPrompt"), factory.press("enter"),
    { "key_down", "kb-1", 32, 57, "player" }, -- "press any key" inside the program
    snap("back"),
    factory.press("ctrl+q")
  )
  env = factory.new({ maxW = 160, maxH = 50, events = events, endSignal = { "interrupted", 0 } })
  local programOutput, _, ok, err = captureOutput(function() return runApp("apps/uidemo.lua", env) end)
  check(ok, "uidemo ran: " .. tostring(err))
  check(programOutput:find("Press any key", 1, true), "the program's own output went to the terminal")
  local demo = package.loaded["ocui.apps.uidemo"]
  check(seen.newDialog and findText(seen.newDialog, "Name of the new item:"), "Ctrl+N opened the prompt")
  check(seen.added and findText(seen.added, "Added Gold"), "prompt result used")
  check(seen.added and not findText(seen.added, "Name of the new item:"), "dialog gone after Enter")
  check(seen.confirm and findText(seen.confirm, "Delete Gold?"), "Delete asks first")
  check(seen.deleted and findText(seen.deleted, "Deleted Gold"), "confirmed with Enter")
  eq(#demo.list.items, 6, "back to six items")
  check(seen.menu and findText(seen.menu, "Run program..."), "F10 opened the File menu")
  check(seen.menuClosed and not findText(seen.menuClosed, "Run program..."), "Escape closed it")
  check(seen.runPrompt and findText(seen.runPrompt, "OpenOS command"), "menu item chosen with arrows + Enter")
  eq(env.executed[1] and env.executed[1].cmd, "ls /", "the program ran through shell.execute")
  check(env.termCalls.clear >= 1, "the terminal was cleared for it")
  check(seen.back and findText(seen.back, "Back from: ls /"), "UI back after the program")
  check(seen.back and findText(seen.back, "Copper"), "UI fully repainted after the program")
  check(seen.back and not findText(seen.back, "program ls / ran"), "program output wiped")
end

section("uidemo: touch, double click, divider drag")
do
  local env
  local seen = {}
  local events = factory.script(
    false,
    { "touch", "screen-1", 5, 5, 0, "player" },          -- Iron Ore
    { "touch", "screen-1", 5, 5, 0, "player" },          -- again at once: double click
    function()
      seen.sel = package.loaded["ocui.apps.uidemo"].list.selected
      local demo = package.loaded["ocui.apps.uidemo"]
      seen.focusIsName = demo.host.focused ~= demo.list and demo.host.focused.getValue ~= nil
      seen.focusVisible = demo.host.focusVisible
      return false
    end,
    { "touch", "screen-1", 71, 10, 0, "player" },        -- the divider
    { "drag", "screen-1", 51, 10, 0, "player" },
    { "drop", "screen-1", 51, 10, 0, "player" },
    function() seen.screen = screenOf(env); return false end,
    factory.press("ctrl+q")
  )
  env = factory.new({ maxW = 160, maxH = 50, events = events, endSignal = { "interrupted", 0 } })
  local ok, err = runApp("apps/uidemo.lua", env)
  check(ok, "uidemo ran: " .. tostring(err))
  eq(seen.sel, 3, "touch selects the row")
  check(seen.focusIsName, "double click activated the row (focus to the name field)")
  eq(seen.focusVisible, false, "no focus highlight after touch input")
  local split = package.loaded["ocui.apps.uidemo"].host:currentView().root.children[2]
  eq(split.size, 50, "divider dragged to column 50")
  local x = seen.screen and findText(seen.screen, "Details")
  check(x and x < 60, "detail panel moved left with the divider")
end

-- Runs a widget tree built by build(host, ctx, out) on its own host.
local function runTree(build, events, opts)
  opts = opts or {}
  opts.events = events
  opts.maxPulls = opts.maxPulls or (#events + 40) -- pushed signals are pulls too
  -- keyboard apps ignore Ctrl+C's "interrupted": end with a signal of our own
  opts.endSignal = { "test_end" }
  local env = factory.new(opts)
  install(env)
  local Pool = require("ocui.pool")
  local Host = require("ocui.host")
  local out = {}
  local ok, err = pcall(Pool.runSingle, { name = "t", keyboard = true, start = function(ctx)
    local host = Host.new({})
    host:mount(ctx)
    ctx:on("test_end", function() ctx:quitPool() end)
    out.host = host
    build(host, ctx, out)
  end })
  check(ok, "tree ran: " .. tostring(err))
  return env, out
end

section("list: scrolling, scrollbar, keys")
do
  local items = {}
  for i = 1, 100 do items[i] = "item " .. i end
  local seen = {}
  local env, out = runTree(function(host, _, o)
    o.list = require("ocui.list").new({ items = items })
    host:setView(o.list)
    seen.list = o.list
  end, factory.script(
    false,
    { "scroll", "screen-1", 5, 5, -1, "player" },
    function() seen.top = seen.list.top; return false end,
    factory.press("end"),
    factory.press("pageUp"),
    function() seen.sel = seen.list.selected; return false end,
    { "touch", "screen-1", 80, 1, 0, "player" },        -- scrollbar, top
    function() seen.top2 = seen.list.top; return false end,
    { "drag", "screen-1", 80, 25, 0, "player" },        -- dragged to the bottom
    { "drop", "screen-1", 80, 25, 0, "player" },
    function() seen.top3 = seen.list.top; return false end,
    factory.typeText("i")                                -- type-ahead
  ))
  eq(seen.top, 4, "wheel scrolls 3 rows")
  eq(seen.sel, 75, "End then PageUp (25 rows)")
  eq(seen.top2, 1, "scrollbar click at the top")
  eq(seen.top3, 76, "scrollbar dragged to the bottom")
  check(env.gpu._lastFrame():find("item 100", 1, true), "last item visible")
  eq(out.list.selected, 76, "type-ahead: next item starting with 'i'")
end

section("text input: other keyboards, paste, UTF-8 editing")
do
  local env, out = runTree(function(host, _, o)
    local root = require("ocui.widgets").VBox.new({})
    o.input = root:add(require("ocui.textinput").new({ h = 1 }))
    o.other = root:add(require("ocui.textinput").new({ h = 1 }))
    host:setView(root)
  end, factory.script(
    false,
    { "key_down", "kb-2", 97, 30, "player" },            -- a keyboard on another screen
    factory.typeText("Привет"),
    { "clipboard", "kb-1", " мир\n!", "player" },
    factory.press("left"), factory.press("back"),
    factory.press("ctrl+left"), factory.typeText("<"),
    factory.press("tab"), factory.typeText("x")
  ))
  -- "Привет мир!" -> Left, Backspace eats the "р" -> Ctrl+Left to the
  -- start of "ми" -> "<" inserted there
  eq(out.input:getValue(), "Привет <ми!", "typed, pasted (newline dropped), edited by character")
  eq(out.other:getValue(), "x", "Tab moved focus to the next field")
  check(env.gpu._lastFrame():find("Привет <ми!", 1, true), "shown on screen")
end

section("host: no VRAM, drawing goes straight to the screen")
do
  local env, out = runTree(function(host, _, o)
    o.input = require("ocui.textinput").new({ w = 20, h = 1 })
    host:setView(o.input)
  end, factory.script(false, factory.typeText("abc"), function()
    return false
  end), { noVram = true })
  eq(out.host.buffer, 0, "no back buffer")
  check(env.gpu._lastFrame():find("abc", 1, true), "typed text on screen")
end

section("layout: HBox / VBox / Split")
do
  install(factory.new({}))
  local layout = require("ocui.layout")
  local widgets = require("ocui.widgets")
  local row = layout.HBox.new({ w = 50, h = 3, gap = 1 })
  local a = row:add(widgets.Button.new({ text = "OK" }))           -- fixed 4
  local b = row:add(widgets.Label.new({ text = "fill" }))          -- flex 1
  local c = row:add(widgets.Label.new({ text = "x", flex = 2 }))
  row:layout()
  eq(a.x .. "/" .. a.w, "0/4", "fixed child keeps its width")
  eq(b.x .. "/" .. b.w, "5/15", "flex 1 share")
  eq(c.x .. "/" .. c.w, "21/29", "flex 2 share")
  eq(b.h, 3, "children span the row's height")
  row:layout()
  eq(b.w, 15, "layout is stable when repeated")
  local col = layout.VBox.new({ w = 10, h = 20 })
  local top = col:add(widgets.Label.new({ h = 1 }))
  local mid = col:add(widgets.Label.new({ flex = 1 }))
  local bottom = col:add(widgets.Label.new({ h = 1 }))
  col:layout()
  eq(top.y .. "," .. mid.y .. "," .. mid.h .. "," .. bottom.y, "0,1,18,19", "VBox flex fills the middle")
  bottom:setVisible(false)
  col:layout()
  eq(mid.h, 19, "a hidden child gives its room away")
  local split = layout.Split.new({ w = 40, h = 10, size = 100, min = 5,
    first = widgets.Label.new({}), second = widgets.Label.new({}) })
  eq(split:firstSize(), 34, "size clamped to leave the second pane its minimum")
end

-- ============================================================ taskmgr ==

section("taskmgr: local pool -- start/stop apps, tabs, keep running on quit")
do
  local env
  local seen = {}
  local function snap(key) return function() seen[key] = screenOf(env); return false end end

  local events = factory.script(
    false, snap("start"),
    factory.typeText("h"), factory.press("f5"), false, false, snap("hudStarted"),
    factory.press("home"), factory.press("f6"), snap("selfStop"),                        -- taskmgr itself
    factory.typeText("h"), factory.press("f6"), false, snap("hudStopped"),
    factory.press("f5"), false, false,
    factory.press("f2"), false, snap("services"),
    factory.press("f3"), false, snap("system"),
    factory.press("f4"), false, snap("log"),
    factory.press("f1"), factory.press("ctrl+q"), snap("quitDialog"), factory.press("enter")
  )
  env = factory.new({ maxW = 160, maxH = 50, glasses = 1, lsc = LSC_EN, events = events,
    maxPulls = #events + 3, endSignal = { "interrupted", 0 } })
  local ok, err = runApp("apps/taskmgr.lua", env)
  check(ok, "taskmgr ran: " .. tostring(err))
  check(seen.start and findText(seen.start, "local pool"), "local mode without a background pool")
  check(seen.start and findText(seen.start, "uidemo") and findText(seen.start, "dashboard"),
    "every installed app listed")
  local function row(frame, name)
    local _, y = findText(frame or "", name .. " ")
    if not y then return "" end
    local n = 0
    for line in (frame .. "\n"):gmatch("(.-)\n") do
      n = n + 1
      if n == y then return line end
    end
    return ""
  end
  check(row(seen.hudStarted, "hud"):find("running"), "type-ahead 'h' + F5 started the HUD")
  check(seen.selfStop and findText(seen.selfStop, "That is this task manager"), "won't stop itself")
  check(row(seen.hudStopped, "hud"):find("stopped"), "F6 stopped the HUD")
  check(seen.services and findText(seen.services, "energy") and row(seen.services, "energy"):find("hud"),
    "services tab: energy used by hud")
  check(seen.system and findText(seen.system, "gt_machine") and findText(seen.system, "Memory"),
    "system tab: components and memory")
  check(seen.log and findText(seen.log, "pool: started hud"), "log tab shows the pool log")
  check(seen.quitDialog and findText(seen.quitDialog, "Keep it running in the background?"),
    "quitting with the HUD running asks")
  local exec = env.executed[1]
  check(exec and exec.cmd == "ocpool" and exec.args[1] == "-b" and exec.args[2] == "hud",
    "Keep running: the HUD handed to `ocpool -b hud`")
  local cpuShown = row(seen.hudStarted, "taskmgr"):match("%d+%.%d")
  check(cpuShown ~= nil, "CPU time per app shown")
end

section("taskmgr: remote control of a background pool")
do
  local events = factory.script(false, false,
    factory.press("down"), factory.press("f5"), false, false,       -- start beta
    factory.press("up"), factory.press("f7"), false, false,         -- restart alpha
    factory.press("ctrl+q"))
  -- status replies are pulls too: leave room for them
  local env = factory.new({ maxW = 160, maxH = 50, events = events, maxPulls = #events + 40,
    endSignal = { "interrupted", 0 } })
  install(env)
  local Pool = require("ocui.pool")
  -- the background pool: a real Pool answering ocpool signals
  local bg = Pool.new({ background = true, logPath = "/tmp/bg.log" })
  local starts = { alpha = 0, beta = 0 }
  for _, name in ipairs({ "alpha", "beta" }) do
    bg:register({ name = name, description = name .. " app", start = function()
      starts[name] = starts[name] + 1
    end })
  end
  bg:start("alpha")
  local taskmgr = require("ocui.apps.taskmgr")
  taskmgr.remoteMode = true
  local fg = Pool.new({})
  fg:register(taskmgr)
  -- stands in for the background pool's own loop: hands it the signals
  fg:register({ name = "bgpool", start = function(ctx)
    ctx:on(Pool.SIGNAL, function(_, cmd, arg, replyId)
      bg:command(cmd, arg, replyId)
    end)
  end })
  fg:run({ "taskmgr", "bgpool" })
  local frame = env.gpu._lastFrame() or ""
  check(frame:find("background pool", 1, true), "remote mode shown")
  eq(bg.apps.beta.state, "running", "F5 started beta in the background pool")
  if verbose then print(frame) end
  check(env.pulls() < #events + 30, "Ctrl+Q quit taskmgr")
  eq(starts.alpha, 2, "F7 restarted alpha")
  check(frame:find("beta app", 1, true), "the background pool's apps listed")
  eq(bg.loop.running, false, "quitting taskmgr leaves the background pool alone (never ran here)")
  eq(bg.apps.alpha.state, "running", "background apps keep running after taskmgr quits")
end

-- ========================================================== render3d ==

section("pixels: rasterizing and run-merged drawing")
do
  local env = factory.new({ maxW = 40, maxH = 10 })
  install(env)
  local PixelView = require("ocui.pixels")
  local Canvas = require("ocui.canvas")
  local v = PixelView.new({ w = 40, h = 10 })
  v:begin()
  v:fillTriangle(0, 0, 20, 0, 0, 20, 0xFF0000)
  local n = 0
  for i = 1, v.pw * v.ph do if v.pix[i] then n = n + 1 end end
  check(n > 180 and n < 230, "triangle covers about half of 20x20 (" .. n .. " px)")
  v:begin()
  for y = 4, 11 do v:span(10, 29, y, 0x00FF00) end           -- 20x8 px block = 20x4 cells
  v:line(0, 19, 39, 19, 0xFFFFFF)                            -- bottom pixel row of cell row 9
  v:finish()
  eq(v.drawn[1] .. "," .. v.drawn[2] .. "," .. v.drawn[3] .. "," .. v.drawn[4], "0,4,39,19", "drawn bounds")
  local calls0 = env.gpu._calls()
  v:draw(Canvas.new(env.gpu, 0, 0, 40, 10))
  local calls = env.gpu._calls() - calls0
  -- 1 fill + per run (set + colors): 4 block rows + 1 line row
  check(calls <= 16, "solid areas drawn as one run per row (" .. calls .. " GPU calls)")
  local fg, bg, ch = env.gpu._cell(11, 3)
  eq(ch .. string.format("%06X", bg), " 00FF00", "block cell = space on green")
  fg, bg, ch = env.gpu._cell(5, 10)
  eq(ch, "▄", "line in the lower half of its cell")
  eq(string.format("%06X/%06X", fg, bg), "FFFFFF/000000", "line color on the background")
  eq(PixelView.quantize(0x4C, 0x8B, 0xF5), 0x3392FF, "colors snap to the T3 palette")
end

section("render3d: frames, shapes, modes, cost per frame")
do
  local events = {}
  local function add(list) for _, e in ipairs(list) do events[#events + 1] = e end end
  for _ = 1, 20 do events[#events + 1] = false end
  add(factory.press("4")); add(factory.press("m"))
  events[#events + 1] = { "touch", "screen-1", 80, 25, 0, "player" }
  events[#events + 1] = { "drag", "screen-1", 90, 25, 0, "player" }
  events[#events + 1] = { "drop", "screen-1", 90, 25, 0, "player" }
  for _ = 1, 25 do events[#events + 1] = false end
  add(factory.press("q"))
  local env = factory.new({ maxW = 160, maxH = 50, events = events, maxPulls = #events + 3,
    endSignal = { "interrupted", 0 } })
  local b0 = env.gpu._budget()
  local ok, err = runApp("apps/render3d.lua", env)
  check(ok, "render3d ran: " .. tostring(err))
  local r3d = package.loaded["ocui.apps.render3d"]
  check((r3d.frames or 0) >= 40, "one frame per pull (" .. tostring(r3d.frames) .. ")")
  check(r3d.fps and r3d.fps > 15, "~20 FPS on the virtual clock (" .. tostring(r3d.fps) .. ")")
  local perFrame = (env.gpu._budget() - b0) / r3d.frames
  check(perFrame < 0.8, string.format("only the object's box is copied: %.2f budget per frame (full screen = 2.0)",
    perFrame))
  local frame = env.gpu._lastFrame() or ""
  check(frame:find("torus wire", 1, true), "4 = torus, M = wireframe (status line)")
  check(env.pulls() < #events + 3, "Q quit")
end

-- =============================================================== ned ==

section("textbuffer: editing, UTF-8, undo, search")
do
  install(factory.new({}))
  local TB = require("ocui.textbuffer")
  local b = TB.new("hello\r\nмир\r\n")
  eq(b:lineCount(), 2, "lines split, final newline remembered")
  eq(b:lineLength(2), 3, "Cyrillic counted by character")
  local stop = b:insert({ line = 2, col = 1 }, "XY\nZ")
  eq(stop.line .. ":" .. stop.col, "3:1", "multi-line insert returns its end")
  eq(b:line(2) .. "|" .. b:line(3), "мXY|Zир", "split inside a UTF-8 line")
  eq(b:range({ line = 1, col = 3 }, { line = 2, col = 2 }), "lo\nмX", "range across lines")
  eq(b:delete({ line = 2, col = 3 }, { line = 3, col = 1 }), "\nZ", "delete returns the text")
  eq(b:line(2), "мXYир", "lines joined")
  check(b:isModified(), "modified")
  b:undo()
  eq(b:line(3), "Zир", "undo restores the deletion")
  b:undo()
  eq(b:getText(), "hello\r\nмир\r\n", "undo back to the original, CRLF + final newline kept")
  check(not b:isModified(), "unmodified again")
  b:redo()
  eq(b:line(2), "мXY", "redo")
  -- typing merges into one undo step
  local t = TB.new("")
  local pos = { line = 1, col = 0 }
  for _, ch in ipairs({ "a", "b", "c" }) do pos = t:insert(pos, ch) end
  t:insert(pos, "\n")
  t:undo()
  eq(t:getText(), "abc", "newline is its own step")
  t:undo()
  eq(t:getText(), "", "the typed word is one step")
  -- save point splits merging
  t:insert({ line = 1, col = 0 }, "x")
  t:markSaved()
  t:insert({ line = 1, col = 1 }, "y")
  check(t:isModified(), "typing after a save is a change")
  t:undo()
  check(not t:isModified(), "undoing back to the save point")
  -- group
  local g = TB.new("a b a")
  g:group(function()
    g:delete({ line = 1, col = 0 }, { line = 1, col = 1 })
    g:insert({ line = 1, col = 0 }, "X")
  end)
  g:undo()
  eq(g:getText(), "a b a", "group undone as one step")
  -- find
  local f = TB.new("one two\nthree two\nOne")
  local a, z = f:find("two", { line = 1, col = 5 })
  eq(a.line .. ":" .. a.col .. "-" .. z.col, "2:6-9", "find forward from the middle")
  a = f:find("two", { line = 2, col = 7 })
  eq(a.line .. ":" .. a.col, "1:4", "find wraps around")
  a = f:find("two", { line = 2, col = 6 }, true)
  eq(a.line .. ":" .. a.col, "1:4", "find backwards")
  a = f:find("one", { line = 1, col = 1 }, false, true)
  eq(a.line .. ":" .. a.col, "3:0", "ignore case")
  eq(f:find("zzz", { line = 1, col = 0 }), nil, "not found")
end

section("syntax: Lua tokens and multi-line state")
do
  install(factory.new({}))
  local syntax = require("ocui.syntax")
  local lua = syntax.lua
  local function kinds(line, state)
    local spans, e = lua.tokenize(line, state)
    local out = {}
    for _, s in ipairs(spans) do out[#out + 1] = line:sub(s.from, s.to) .. "=" .. s.kind end
    return table.concat(out, " "), e
  end
  eq((kinds('local x = "a\\"b" -- hi')), 'local=keyword "a\\"b"=string -- hi=comment', "keyword, escaped string, comment")
  eq((kinds("return 0x1F, 3.5e2, nil")), "return=keyword 0x1F=number 3.5e2=number nil=constant", "numbers, constant")
  eq((kinds("local function foo() print(1) end")),
    "local=keyword function=keyword foo=func print=builtin 1=number end=keyword", "function name, builtin")
  local text, state = kinds("x = 1 --[==[ open")
  eq(state, "c:2", "long comment left open")
  text, state = kinds("still ]=] in ]==] y = 2", state)
  eq(text, "still ]=] in ]==]=comment 2=number", "closed by the matching level only")
  eq(state, "", "back to normal")
  local _, s2 = kinds("s = [[text")
  eq(s2, "s:0", "long string state")
  eq(syntax.forPath("/etc/ocui/hud.cfg"), lua, ".cfg highlighted as Lua")
  eq(syntax.forPath("/home/notes.txt"), syntax.plain, "other files plain")
end

local NED_SAMPLE = [===[
-- demo program
local component = require("component")
--[[ a long
comment ]]
local function greet(name)
  print("Привет, " .. name .. "!")  -- say hi
  return 42, 0x1F, true
end
greet("world")
]===]

-- Runs ned on `file` (with NED_SAMPLE as /home/demo.lua) and the events.
local function runNed(events, opts)
  opts = opts or {}
  opts.maxW, opts.maxH = opts.maxW or 100, opts.maxH or 20
  opts.events = events
  opts.maxPulls = #events + 5
  opts.endSignal = { "interrupted", 0 }
  opts.files = opts.files or { ["/home/demo.lua"] = NED_SAMPLE }
  local env = factory.new(opts)
  if opts.onEnv then opts.onEnv(env) end
  local out, _, ok, err = captureOutput(function()
    return runApp("apps/ned.lua", env, opts.path or "/home/demo.lua")
  end)
  check(ok, "ned ran: " .. tostring(err))
  return env, package.loaded["ocui.apps.ned"], out
end

section("ned: highlighting on screen, typing cost, cascade")
do
  local env
  local seen = {}
  local function snap(key) return function() seen[key] = screenOf(env); return false end end
  local function color(key, x, y)
    return function() seen[key] = string.format("%06X", (env.gpu._cell(x, y))); return false end
  end
  local function budget(key) return function() seen[key] = env.gpu._budget(); env.gpu._resetBudget(); return false end end
  -- screen: title on row 1, line n on row n + 1, text from column 5
  local events = factory.script(false,
    color("local", 5, 3), color("require", 23, 3), color("string", 31, 3), color("comment", 5, 5),
    color("func", 20, 6), color("number", 14, 8), color("constant", 26, 8), color("russian", 13, 7),
    budget("start"),
    factory.press("down"), factory.press("end"), budget("move"),
    factory.typeText("x"), budget("typedCost"), snap("typed"),
    factory.press("ctrl+home"), factory.typeText("--[["), color("cascade", 5, 3), snap("cascaded"),
    factory.press("ctrl+z"), color("uncascade", 5, 3),
    factory.press("ctrl+q"), factory.press("right"), factory.press("enter"))
  runNed(events, { onEnv = function(e) env = e end })
  eq(seen["local"], "C678DD", "keyword color")
  eq(seen.require, "61AFEF", "builtin color")
  eq(seen.string, "98C379", "string color")
  eq(seen.comment, "7F848E", "inside a long comment")
  eq(seen.func, "E5C07B", "function name color")
  eq(seen.number, "D19A66", "number color")
  eq(seen.constant, "D19A66", "true color")
  eq(seen.russian, "98C379", "Cyrillic inside a string")
  -- on this 100x20 screen a full repaint costs 2.0 and one row 0.1
  check(seen.move and seen.move < 0.45,
    "two cursor moves repaint the two rows + position (" .. tostring(seen.move) .. ")")
  check(seen.typedCost and seen.typedCost < 0.25,
    "typing a character repaints its row + title (" .. tostring(seen.typedCost) .. ")")
  check(seen.typed and findText(seen.typed, 'require("component")x'), "typed at the end of line 2")
  eq(seen.cascade, "7F848E", "opening --[[ on line 1 turns line 2 into a comment")
  eq(seen.uncascade, "C678DD", "undo turns it back into code")
  eq(env.files["/home/demo.lua"], NED_SAMPLE, "quit with Don't save left the file alone")
end

section("ned: selection, clipboard, cut lines, indent, undo")
do
  local events = factory.script(false,
    factory.press("ctrl+end"), factory.press("enter"), factory.typeText("x = 1"),
    factory.press("enter"),                                                          -- lines 10, 11
    factory.press("shift+up"), factory.press("ctrl+c"),
    { "interrupted", 0 },                                                            -- OpenOS's Ctrl+C signal
    factory.press("ctrl+end"), factory.press("ctrl+v"),
    factory.press("ctrl+home"), factory.press("ctrl+k"), factory.press("ctrl+k"),     -- cut lines 1-2
    factory.press("ctrl+end"), factory.press("ctrl+u"),
    factory.press("ctrl+home"), factory.press("shift+down"), factory.press("shift+down"),
    factory.press("tab"),                                                            -- indent 2 lines
    factory.press("ctrl+s"),
    factory.press("ctrl+q"))
  local env, ned = runNed(events)
  local text = env.files["/home/demo.lua"] or ""
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
  eq(lines[1], "  --[[ a long", "Tab indented the selected lines (1)")
  eq(lines[2], "  comment ]]", "Tab indented the selected lines (2)")
  eq(lines[3], "local function greet(name)", "the third line, not selected to its start, stays")
  check(text:find('greet%("world"%)\nx = 1\nx = 1\n%-%- demo program\nlocal component = require%("component"%)\n'),
    "copy + paste, and two cut lines pasted at the end:\n" .. text)
  check(ned.editor ~= nil, "Ctrl+C (and its interrupted signal) did not quit")
end

section("ned: find, replace, go to, run, new file")
do
  local env, ned
  local seen = {}
  local events = factory.script(false,
    factory.press("ctrl+f"), factory.typeText("greet"), factory.press("enter"),
    function() seen.found = { ned().editor.cursor.line, ned().editor:selectedText() }; return false end,
    factory.press("f3"),
    function() seen.next = ned().editor.cursor.line; return false end,
    factory.press("ctrl+r"), factory.press("ctrl+u"), factory.typeText("greet"), factory.press("enter"),
    factory.typeText("hello"), factory.press("enter"),
    function() seen.status = screenOf(env); return false end,
    factory.press("ctrl+g"), factory.press("ctrl+u"), factory.typeText("3:4"), factory.press("enter"),
    function() local c = ned().editor.cursor; seen.go = c.line .. ":" .. c.col; return false end,
    factory.press("f5"), { "key_down", "kb-1", 32, 57, "player" },
    function() seen.back = screenOf(env); return false end,
    factory.press("ctrl+q"))
  ned = function() return package.loaded["ocui.apps.ned"] end
  local _, _, out = runNed(events, { onEnv = function(e) env = e end })
  eq(seen.found and seen.found[1], 5, "Ctrl+F found the definition")
  eq(seen.found and seen.found[2], "greet", "match selected")
  eq(seen.next, 9, "F3: next match")
  check(seen.status and findText(seen.status, "Replaced 2 occurrences"), "replace all")
  eq(seen.go, "3:3", "Ctrl+G to line 3, column 4")
  local text = env.files["/home/demo.lua"] or ""
  check(text:find("local function hello%(name%)") and text:find('hello%("world"%)'), "saved before running")
  eq(env.executed[1] and env.executed[1].cmd, "/home/demo.lua", "F5 ran the file")
  check(out:find("program ended", 1, true), "the program's terminal output")
  check(seen.back and findText(seen.back, "Ran /home/demo.lua"), "back in the editor")

  -- a new, unnamed file: Ctrl+S asks for a name
  local events2 = factory.script(false, factory.typeText("print(1)"), factory.press("ctrl+s"),
    factory.press("ctrl+u"), factory.typeText("/home/new.lua"), factory.press("enter"), factory.press("ctrl+q"))
  local env2 = factory.new({ maxW = 100, maxH = 20, events = events2, maxPulls = #events2 + 5,
    endSignal = { "interrupted", 0 } })
  local ok, err = runApp("apps/ned.lua", env2)
  check(ok, "ned without a file: " .. tostring(err))
  eq(env2.files["/home/new.lua"], "print(1)", "saved under the name typed in the prompt")
end

section("ned: long lines scroll sideways, tabs")
do
  local long = string.rep("abcdefghij", 30) .. "END"
  local seen = {}
  local env
  local events = factory.script(false,
    factory.press("end"), function() seen.endFrame = screenOf(env); return false end,
    factory.press("home"), factory.press("down"), factory.press("end"),
    function() seen.tabCol = package.loaded["ocui.apps.ned"].editor.cursor.col; return false end,
    function() seen.tabFrame = screenOf(env); return false end,
    factory.press("ctrl+q"))
  runNed(events, { files = { ["/home/l.txt"] = long .. "\n\tx\ty\n" }, path = "/home/l.txt",
    onEnv = function(e) env = e end })
  check(seen.endFrame and findText(seen.endFrame, "hijEND"), "End scrolled to the end of a 303-char line")
  eq(seen.tabCol, 4, "tab counts as one character")
  check(seen.tabFrame and findText(seen.tabFrame, "  x y"), "tabs shown as spaces to the next stop")
end

-- ===================================================== explorer, desktop ==

local DESK_FILES = { ["/home/demo.lua"] = "print('hi')\n", ["/home/sub/x.txt"] = "x", ["/home/.hidden"] = "h" }

local function copyFiles(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- Script entry: touch the first occurrence of `text` on screen-1.
local function touchOn(envRef, text, button)
  return function()
    local x, y = findText(envRef().gpu._screen(), text)
    if not x then return false end
    return { "touch", "screen-1", x, y, button or 0, "player" }
  end
end

section("explorer: browse, create, copy, rename, delete, edit, run")
do
  local env
  local seen = {}
  local function snap(key) return function() seen[key] = screenOf(env); return false end end
  local function sel() return package.loaded["ocui.apps.explorer"].list:selectedItem() end
  local events = factory.script(false, snap("start"),
    factory.press("f7"), factory.typeText("newdir"), factory.press("enter"),
    function() seen.mkdirSel = sel() and sel().name; return false end,
    factory.press("end"),                                                  -- demo.lua (last)
    factory.press("f5"), factory.press("enter"),                           -- copy_of_demo.lua
    factory.press("ctrl+home"), factory.typeText("c"),                     -- type-ahead to the copy
    factory.press("f2"), factory.press("ctrl+u"), factory.typeText("renamed.lua"), factory.press("enter"),
    function() seen.renamedSel = sel() and sel().name; return false end,
    factory.press("f8"), factory.press("enter"),                           -- delete renamed.lua
    factory.typeText("s"), factory.press("enter"),                         -- into sub/
    snap("sub"),
    factory.press("back"),
    function() seen.backSel = sel() and sel().name; return false end,
    factory.press("ctrl+h"), snap("hidden"),
    factory.press("end"),                                                  -- demo.lua (files: .hidden, demo.lua)
    function() seen.editTarget = sel() and sel().name; return false end,
    factory.press("f4"),
    factory.press("ctrl+enter"), { "key_down", "kb-1", 32, 57, "player" },
    factory.press("ctrl+q"))
  env = factory.new({ maxW = 100, maxH = 25, events = events, maxPulls = #events + 5,
    endSignal = { "interrupted", 0 }, files = copyFiles(DESK_FILES) })
  local _, _, ok, err = captureOutput(function() return runApp("apps/explorer.lua", env, "/home") end)
  check(ok, "explorer ran: " .. tostring(err))
  check(seen.start and findText(seen.start, "sub/") and findText(seen.start, "demo.lua"), "lists the directory")
  check(seen.start and not findText(seen.start, ".hidden"), "hidden files hidden by default")
  eq(seen.mkdirSel, "newdir", "F7 created and selected the directory")
  check(env.filesystem.isDirectory("/home/newdir"), "directory exists")
  eq(seen.renamedSel, "renamed.lua", "F5 copy then F2 rename")
  check(env.files["/home/renamed.lua"] == nil, "F8 deleted it")
  eq(env.files["/home/demo.lua"], "print('hi')\n", "original untouched")
  check(seen.sub and findText(seen.sub, "/home/sub") and findText(seen.sub, "x.txt"), "Enter opened sub/")
  eq(seen.backSel, "sub", "Backspace went up and selected the directory it came from")
  check(seen.hidden and findText(seen.hidden, ".hidden"), "Ctrl+H shows hidden files")
  local ned, run = env.executed[1], env.executed[2]
  check(ned and ned.cmd == "ned" and ned.args[1] == "/home/" .. tostring(seen.editTarget),
    "F4 edits in ned (standalone: as a program)")
  eq(run and run.cmd, "/home/" .. tostring(seen.editTarget), "Ctrl+Enter runs the file")
end

section("desktop: home screen, windows, taskbar, start menu")
do
  local env
  local envRef = function() return env end
  local seen = {}
  local function snap(key) return function() seen[key] = screenOf(env); return false end end
  local function budget(key) return function() seen[key] = env.gpu._budget(); env.gpu._resetBudget(); return false end end
  local function desk() return package.loaded["ocui.apps.desktop"].desk end
  local events = factory.script(false, snap("home"),
    factory.press("f12"), snap("start"), factory.press("escape"), snap("startClosed"),
    touchOn(envRef, "explorer"), false, snap("explorer"),
    factory.press("end"), factory.press("enter"), false, snap("ned"),
    budget("before"), factory.typeText("x"), budget("typing"),
    factory.press("ctrl+tab"), snap("switched"),
    function() seen.windows = #desk().windows; return false end,
    factory.press("ctrl+tab"), factory.press("ctrl+q"),                     -- ned: unsaved -> dialog
    factory.press("right"), factory.press("enter"),                         -- Don't save
    function() seen.afterNed = #desk().windows; return false end, snap("afterNedScreen"),
    factory.press("ctrl+d"), snap("home2"),
    factory.press("f12"), factory.press("up"), factory.press("enter"), factory.press("enter"))
  env = factory.new({ maxW = 120, maxH = 30, events = events, maxPulls = #events + 5,
    endSignal = { "interrupted", 0 }, files = copyFiles(DESK_FILES) })
  local ok, err = runApp("apps/desktop.lua", env)
  check(ok, "desktop ran: " .. tostring(err))
  check(seen.home and findText(seen.home, "ocui desktop") and findText(seen.home, "taskmgr")
    and findText(seen.home, "explorer"), "home screen tiles")
  check(seen.home and findText(seen.home, "Start"), "taskbar")
  check(seen.start and findText(seen.start, "Exit desktop") and findText(seen.start, "OpenOS shell"), "F12 start menu")
  check(seen.start and findText(seen.start, "Start"), "the start menu leaves the Start button visible")
  check(seen.startClosed and not findText(seen.startClosed, "Exit desktop"), "Escape closed it")
  check(seen.explorer and findText(seen.explorer, "/home") and findText(seen.explorer, "Files"),
    "explorer opened in a window, listed on the taskbar")
  check(seen.ned and findText(seen.ned, "ned  /home/demo.lua"), "Enter on a file opened it in a ned window")
  check(seen.typing and seen.typing < 0.3, "typing in a window repaints little (" .. tostring(seen.typing) .. ")")
  check(seen.switched and findText(seen.switched, "Enter Open"), "Ctrl+Tab back to the explorer window")
  eq(seen.windows, 2, "two windows")
  eq(seen.afterNed, 1, "closing ned removed its window")
  check(seen.afterNedScreen and findText(seen.afterNedScreen, "Enter Open"), "the other window shown after closing one")
  check(seen.home2 and findText(seen.home2, "ocui desktop"), "Ctrl+D home screen")
  check(env.pulls() < #events + 5, "Exit desktop from the start menu")
  eq(env.files["/home/demo.lua"], "print('hi')\n", "Don't save left the file alone")
end

-- =========================================================== session ==

local function readProject(path)
  local f = io.open(projectRoot .. "/" .. path, "rb")
  local text = f:read("a")
  f:close()
  return text
end

section("session: on/off and the boot script")
do
  local env = factory.new({})
  install(env)
  local session = require("ocui.session")
  eq(session.readConfig().boot, false, "off by default")
  check(not session.bootCheck(), "boot check: off")
  session.setBoot(true)
  check(env.files["/etc/ocui/session.cfg"]:find("boot = true", 1, true), "ocsession on saved")
  check(not session.bootCheck(), "boot check: on, but the program isn't installed")
  env.files[session.PROGRAM] = readProject("apps/ocsession.lua")
  check(session.bootCheck(), "boot check: on and the program compiles")

  -- the boot script itself
  local shellVar
  local realSetenv = os.setenv
  os.setenv = function(k, v) if k == "SHELL" then shellVar = v end end
  local boot = assert(load(readProject("boot/99_ocui.lua"), "=99_ocui"))
  boot()
  eq(shellVar, session.PROGRAM, "boot script points $SHELL at the session")
  shellVar = nil
  env.files[session.PROGRAM] = "this is not lua ("
  boot()
  eq(shellVar, nil, "a broken session program is not used (plain shell)")
  env.files[session.PROGRAM] = readProject("apps/ocsession.lua")
  session.setBoot(false)
  boot()
  eq(shellVar, nil, "ocsession off: plain shell")
  os.setenv = realSetenv
end

-- Runs session.run() with scripted keys for the splash/crash screens.
local function runSession(opts)
  local env = factory.new({ maxW = 120, maxH = 30, events = opts.events or {},
    maxPulls = #(opts.events or {}) + 5, endSignal = { "interrupted", 0 },
    files = { ["/etc/ocui/session.cfg"] = opts.cfg or "{ boot = true, splash = 2 }" } })
  install(env)
  local session = require("ocui.session")
  local keys = opts.keys or {}
  local screens = {}
  session.waitKey = function()
    screens[#screens + 1] = env.gpu._screen()
    local k = table.remove(keys, 1)
    if k then return string.byte(k), 0 end
    return nil
  end
  if opts.setup then opts.setup(session, env) end
  local out, _, ok, err = captureOutput(function() return pcall(session.run) end)
  return env, session, screens, ok, err, out
end

local EXIT_DESKTOP = factory.script(false, factory.press("f12"), factory.press("up"), factory.press("up"),
  factory.press("up"), factory.press("enter"))

section("session: splash -> desktop -> exit to the shell")
do
  local env, session, screens, ok, err = runSession({ events = EXIT_DESKTOP })
  check(ok, "session ran: " .. tostring(err))
  check(screens[1] and screens[1]:find("Starting the desktop in 2", 1, true), "splash countdown")
  eq(env.executed[1] and env.executed[1].cmd, "ocpool", "background pool started")
  eq(env.executed[1] and env.executed[1].args[1], "-b", "... with -b")
  check(package.loaded["ocui.apps.desktop"].desk ~= nil, "the desktop ran")
  eq(env.executed[2] and env.executed[2].cmd, "sh", "leaving the desktop opens the shell")
  check(session.active, "session marked active (desktop shows Exit to shell / Reboot)")
end

section("session: a key on the splash = plain shell; exit = desktop")
do
  local env, session, _, ok = runSession({ keys = { " " } })
  check(ok, "ran")
  eq(env.executed[2] and env.executed[2].cmd, "sh", "straight to the shell")
  check(not (env.gpu._lastFrame() or ""):find("ocui desktop", 1, true), "no desktop yet")
  -- OpenOS runs the session again after the shell's `exit`
  local runs = 0
  session.runDesktop = function() runs = runs + 1; return true end
  captureOutput(session.run)
  eq(runs, 1, "the next run goes straight to the desktop (no splash, no second pool)")
  eq(#env.executed, 3, "then the shell again")
end

section("session: the desktop crashes -> crash screen, log, restart or shell")
do
  local crashes = 0
  local env, session, screens, ok = runSession({
    cfg = "{ boot = true, splash = 0, backgroundPool = false, autoRestart = 5 }",
    events = EXIT_DESKTOP,
    keys = { "r" },
    setup = function(session)
      local desktop = require("ocui.apps.desktop")
      local start = desktop.start
      desktop.start = function(...)
        crashes = crashes + 1
        if crashes == 1 then error("boom in the desktop") end
        return start(...)
      end
      local _ = session
    end,
  })
  check(ok, "ran")
  check(screens[1] and screens[1]:find("stopped with an error", 1, true) and screens[1]:find("boom in the desktop", 1, true),
    "crash screen with the error")
  check(screens[1] and screens[1]:find("restarting in 5 s", 1, true), "auto-restart countdown")
  check((env.files[session.CRASH_LOG] or ""):find("boom in the desktop", 1, true), "written to the crash log")
  eq(crashes, 2, "R restarted the desktop")
  eq(env.executed[1] and env.executed[1].cmd, "sh", "exiting it afterwards: shell")

  -- S goes to the shell; three crashes in a minute stop the auto-restart
  local autoRestarts = {}
  local env2 = runSession({
    cfg = "{ boot = true, splash = 0, backgroundPool = false }",
    setup = function(s)
      s.runDesktop = function() return false, "always broken" end
      local n = 0
      s.crashScreen = function(_, auto)
        n = n + 1
        autoRestarts[n] = auto
        return n < 3 and "restart" or "shell"
      end
    end,
  })
  eq(autoRestarts[1], 10, "first crash: auto-restart")
  eq(autoRestarts[3], 0, "third crash within a minute: wait for a key")
  eq(env2.executed[1] and env2.executed[1].cmd, "sh", "S: shell")
end

-- ========================================================== terminal ==

section("vgpu: the virtual GPU grid")
do
  install(factory.new({}))
  local VGpu = require("ocui.vgpu")
  local g = VGpu.new(10, 4)
  local damaged = {}
  g.onDamage = function(x, y, w, h) damaged[#damaged + 1] = x .. "," .. y .. " " .. w .. "x" .. h end
  g.setForeground(0xFF0000)
  g.set(2, 1, "Привет")
  local ch, fg = g.get(3, 1)
  eq(ch, "р", "set writes characters, UTF-8 aware")
  eq(fg, 0xFF0000, "with the current foreground")
  eq(damaged[1], "1,0 6x1", "damage of a set, 0-based")
  g.setBackground(0x0000FF)
  g.fill(1, 2, 3, 2, "#")
  local _, _, bg = g.get(2, 3)
  eq(bg, 0x0000FF, "fill uses the background")
  g.copy(1, 2, 3, 1, 5, 0)
  eq((g.get(6, 2)), "#", "copy moves cells")
  eq(select(1, g.getResolution()), 10, "resolution")
  eq(g.setResolution(80, 25), false, "resolution can't be changed by programs")
  g.setForeground(3, true)
  eq(select(2, g.getForeground()), true, "palette colors")
  g.resize(12, 5)
  eq((g.get(3, 1)), "р", "resize keeps the content")
  check(g.getScreen():match("^ocui%-vscreen"), "a virtual screen address")
end

section("terminal widget: keys go to its virtual keyboard")
do
  local env, out = runTree(function(host, _, o)
    o.term = require("ocui.terminal").new({})
    host:setView(o.term)
    o.term:focus()
    o.term.gpu = nil
    o.f12 = 0
    host:bind("f12", function() o.f12 = o.f12 + 1 end)
    o.term:vgpu().set(1, 1, "hello from the shell")
  end, factory.script(
    false,
    factory.typeText("ls"),
    factory.press("ctrl+c"),
    factory.press("f12"),
    { "clipboard", "kb-1", "pasted", "player" }
  ))
  local kb = out.term.keyboard
  local downs, ups, ctrl, paste = {}, 0, false, false
  for _, sig in ipairs(env.pushed) do
    if sig[2] == kb then
      if sig[1] == "key_down" then downs[#downs + 1] = sig[3]; if sig[4] == 29 then ctrl = true end end
      if sig[1] == "key_up" then ups = ups + 1 end
      if sig[1] == "clipboard" then paste = sig[3] == "pasted" end
    end
  end
  check(kb and kb:match("^ocui%-vkb"), "virtual keyboard address")
  eq(downs[1], string.byte("l"), "typed characters forwarded")
  eq(downs[2], string.byte("s"), "in order")
  check(ctrl, "modifier keys forwarded too (Ctrl for Ctrl+C)")
  check(ups >= 1, "key releases forwarded")
  check(paste, "clipboard forwarded")
  eq(out.f12, 1, "the host's own bindings still come first")
  check(env.gpu._lastFrame():find("hello from the shell", 1, true), "the grid is drawn")
end

section("terminal app: the shell runs in a window on the desktop")
do
  local seen = {}
  local env
  local envRef = function() return env end
  local events = factory.script(false,
    touchOn(envRef, "terminal"), false, false, false, false,
    function() seen.windows = #package.loaded["ocui.apps.desktop"].desk.windows; return false end,
    factory.press("f12"), factory.press("up"), factory.press("enter"))
  env = factory.new({ maxW = 100, maxH = 30, events = events, maxPulls = #events + 10,
    endSignal = { "interrupted", 0 },
    onExecute = function(cmd)
      -- what OpenOS's shell would do: write through its terminal window
      local window = require("process").info().data.window
      window.gpu.set(1, 1, "$ " .. cmd .. " -- shell prompt in a window")
      seen.keyboard = window.keyboard
      return true
    end })
  local ok, err = runApp("apps/desktop.lua", env)
  check(ok, "desktop ran: " .. tostring(err))
  -- (the mock runs the thread at once, so the shell has already ended by
  -- the next frame; drawing the grid is tested with the widget above)
  eq(env.executed[1] and env.executed[1].cmd, "sh", "the terminal ran the shell")
  check(seen.keyboard and seen.keyboard:match("^ocui%-vkb"), "its terminal reads the virtual keyboard")
  eq(seen.windows, 0, "the shell ended: its window closed")
  check(env.pulls() < #events + 10, "desktop exited")
end

section("install.lua + manifest")
do
  -- the manifest lists exactly the deployable files, with current checksums
  local tool = dofile(projectRoot .. "/tools/manifest.lua")
  local current = tool.entries(projectRoot)
  check(#current > 0, "git ls-files listed the deployable files")
  local f = io.open(projectRoot .. "/manifest.lua", "rb")
  local manifestText = f:read("a")
  f:close()
  eq(tool.normalize(manifestText), tool.render(current),
    "manifest.lua is up to date (run: lua tools/manifest.lua)")
  local manifest = load(manifestText, "=manifest", "t", {})()

  -- Runs install.lua against a fake internet serving this checkout (LF
  -- text, as raw GitHub does). opts: failOn (404 for that file), corrupt
  -- (serve a changed file), have (files already installed), args.
  local function runInstall(opts)
    opts = opts or {}
    local env = factory.new({})
    local written, requests = {}, {}
    local realOpen, realExit = io.open, os.exit
    env.component.isAvailable = function(t) return t == "internet" end
    env.filesystem.path = function(p) return p:match("^(.*)/[^/]*$") end
    env.filesystem.makeDirectory = function() return true end
    for path, text in pairs(opts.have or {}) do env.files[path] = text end
    -- leftovers of the removed `tube` player from an older install
    env.files["/usr/bin/tube.lua"] = "old"
    env.files["/lib/ocui/tubeproto.lua"] = "old"
    env.filesystem.remove = function(path)
      env.files[path] = nil
      return true
    end
    package.loaded.internet = {
      request = function(url)
        local rel = url:match("/main/(.+)$")
        requests[#requests + 1] = rel
        if rel == opts.failOn then error("HTTP request failed: Not Found") end
        local src = realOpen(projectRoot .. "/" .. rel, "rb")
        local body = tool.normalize(src:read("a"))
        src:close()
        if rel == opts.corrupt then body = body .. "-- tampered\n" end
        local done = false
        return setmetatable({ response = function() return 200, "OK" end }, {
          __call = function()
            if done then return nil end
            done = true
            return body
          end,
        })
      end,
    }
    io.open = function(path, mode)
      if path:sub(1, 1) == "/" then
        if mode == "w" then
          written[path] = ""
          return { write = function(_, s) written[path] = written[path] .. s end, close = function() end }
        end
        local text = env.files[path]
        if not text then return nil, "not found" end
        return { read = function() return text end, close = function() end }
      end
      return realOpen(path, mode)
    end
    os.exit = function(code) error({ exitCode = code }, 0) end
    local out, _, ok, err = captureOutput(function()
      return runApp("install.lua", env, table.unpack(opts.args or {}))
    end)
    io.open, os.exit = realOpen, realExit
    package.loaded.internet = nil
    local count = 0
    for _ in pairs(written) do count = count + 1 end
    return { written = written, count = count, out = out, ok = ok, err = err, requests = requests, files = env.files }
  end

  local r = runInstall()
  check(r.ok, "install ran: " .. tostring(type(r.err) == "table" and r.err.exitCode or r.err))
  eq(r.count, #manifest, "fresh install: every file written")
  eq(r.requests[1], "manifest.lua", "manifest first")
  local src = io.open(projectRoot .. "/ocui/pool.lua", "rb")
  local poolSource = tool.normalize(src:read("a"))
  src:close()
  eq(r.written["/lib/ocui/pool.lua"], poolSource, "library file copied byte for byte")
  check(r.written["/usr/bin/ocpool.lua"], "programs go to /usr/bin")
  check(r.written["/boot/99_ocui.lua"], "the boot hook goes to /boot")
  check(r.out:find("installed to /lib/ocui"), "success message")
  check(r.files["/usr/bin/tube.lua"] == nil and r.files["/lib/ocui/tubeproto.lua"] == nil,
    "obsolete tube files removed")
  check(r.out:find("removed obsolete /usr/bin/tube.lua", 1, true), "removal reported")

  -- a second run with everything in place downloads nothing
  local have = {}
  for path, text in pairs(r.written) do have[path] = text end
  local r2 = runInstall({ have = have })
  check(r2.ok, "update ran")
  eq(r2.count, 0, "nothing rewritten")
  eq(#r2.requests, 1, "only the manifest downloaded")
  check(r2.out:find("up to date"), "says up to date")
  check(not r2.out:find("ocpool quit", 1, true), "no restart advice when nothing changed")

  -- one file changed here: only it is downloaded
  have["/lib/ocui/hud.lua"] = "-- old version\n"
  local r3 = runInstall({ have = have })
  eq(r3.count, 1, "one file updated")
  eq(r3.requests[2], "ocui/hud.lua", "and only that one downloaded")
  have["/lib/ocui/hud.lua"] = r.written["/lib/ocui/hud.lua"]

  local r4 = runInstall({ have = have, args = { "-f" } })
  eq(r4.count, #manifest, "-f downloads everything")

  local r5 = runInstall({ failOn = "ocui/hud.lua" })
  check(not r5.ok and type(r5.err) == "table" and r5.err.exitCode == 1, "download failure exits 1")
  eq(r5.count, 0, "nothing written when one download fails")
  check(r5.out:find("nothing was changed"), "says nothing was changed")

  local r6 = runInstall({ corrupt = "ocui/pool.lua" })
  check(not r6.ok and r6.count == 0, "a file that doesn't match the manifest stops the install")
  check(r6.out:find("does not match the manifest", 1, true), "and says why")
end

print(string.format("\n%d passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
