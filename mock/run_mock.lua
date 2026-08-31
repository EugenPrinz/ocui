-- mock/run_mock.lua
-- Smoke test: runs apps/ae2_dashboard.lua under a fake component/event
-- environment with a plain `lua` interpreter, across a few scenarios, to
-- catch Lua errors and sanity-check layout without needing
-- Minecraft/OpenComputers.
--
-- Run from the project root:
--   lua mock/run_mock.lua

local projectRoot = (arg[0]):match("(.*)[/\\]mock[/\\]run_mock%.lua$") or "."
package.path = projectRoot .. "/?.lua;" .. projectRoot .. "/mock/?.lua;" .. package.path

local factory = require("component_factory")

-- Fresh require of ocui.app and apps/ae2_dashboard per scenario: both are
-- stateless modules, but ae2_dashboard runs its whole body (including
-- app:start()) at require/dofile time, so it must be re-executed each run.
local function clearAppModules()
  for name in pairs(package.loaded) do
    if name:match("^ocui%.") then
      package.loaded[name] = nil
    end
  end
end

local function runScenario(label, opts, eventScript)
  io.write(("\n==== %s ====\n"):format(label))

  local comp, gpu = factory.new(opts)
  if opts.brokenGetCpus then
    comp.me_interface.getCpus = function() error("ME network offline (simulated)") end
  end

  local pullCount = 0
  local mockEvent = {
    pull = function(_timeout)
      pullCount = pullCount + 1
      local ev = eventScript[pullCount]
      if ev then return table.unpack(ev) end
      return "key_down", "kb-addr", 113, 16, "player" -- default: quit on 'q'
    end,
  }

  package.loaded["component"] = comp
  package.loaded["event"] = mockEvent
  clearAppModules()

  local tickCount = 0
  local lastFrame = nil
  local App = require("ocui.app")
  local origNew = App.new
  App.new = function(appOpts)
    local userOnTick = appOpts.onTick
    appOpts.onTick = function()
      tickCount = tickCount + 1
      lastFrame = gpu.dump()
      if userOnTick then userOnTick() end
    end
    return origNew(appOpts)
  end

  local ok, err = pcall(dofile, projectRoot .. "/apps/ae2_dashboard.lua")

  print(lastFrame or "<no frame captured>")
  print(string.format("(ticks=%d pulls=%d)", tickCount, pullCount))

  if not ok then
    print("FAILED: " .. tostring(err))
    return false
  end
  print("OK")
  return true
end

local scenarios = {
  {
    label = "normal: two CPUs, one busy",
    opts = {
      maxW = 80, maxH = 25,
      cpus = {
        {
          name = "CPU-A", storage = 4 * 1024 * 1024, coprocessors = 4, busy = true,
          output = { name = "gtnh:item.plate", label = "Steel Plate", size = 64 },
          stored = { { name = "gtnh:item.plate", label = "Steel Plate", size = 20 } },
          pending = { { name = "gtnh:item.plate", label = "Steel Plate", size = 30 } },
          active = { { name = "gtnh:item.plate", label = "Steel Plate", size = 14 } },
        },
        { name = "CPU-B", storage = 1024 * 1024, coprocessors = 1, busy = false },
      },
    },
    events = { {nil}, {"touch", "screen-addr", 5, 3, 0, "player"} },
  },
  {
    label = "empty network: zero crafting CPUs",
    opts = { maxW = 80, maxH = 25, cpus = {} },
    events = {},
  },
  {
    label = "AE2 read error (me.getCpus throws)",
    opts = { maxW = 80, maxH = 25, cpus = {}, brokenGetCpus = true },
    events = {},
  },
  {
    label = "tiny T1-ish screen (26x8) + long unicode item name",
    opts = {
      maxW = 26, maxH = 8,
      cpus = {
        {
          name = "", storage = 16 * 1024 * 1024, coprocessors = 8, busy = true,
          output = { name = "x", label = "\208\154\208\190\208\188\208\191\208\187\208\181\208\186\209\129\208\189\209\139\208\185 \208\180\208\178\208\184\208\179\208\176\209\130\208\181\208\187\209\140 IV", size = 1 },
          stored = { { name = "x", label = "y", size = 1 } },
          pending = {},
          active = {},
        },
      },
    },
    events = {},
  },
}

local allOk = true
for _, scenario in ipairs(scenarios) do
  local ok = runScenario(scenario.label, scenario.opts, scenario.events)
  allOk = allOk and ok
end

if not allOk then
  print("\nSMOKE TEST SUITE: FAILED")
  os.exit(1)
end
print("\nSMOKE TEST SUITE: ALL OK")
