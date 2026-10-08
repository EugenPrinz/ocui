-- ocpool -- run several ocui apps at once, in the foreground or background.
--
--   ocpool [app ...]          run apps in the foreground ('q' / Ctrl+C quits)
--   ocpool -b [app ...]       run apps in the background, shell stays usable
--   ocpool list               apps available in /lib/ocui/apps
--   ocpool status             state of the background pool's apps
--   ocpool start|stop|restart <app>   control the background pool
--   ocpool quit               stop the background pool
--   ocpool log                show /tmp/ocpool.log
--
-- With no app names, runs `autostart` from /etc/ocui/ocpool.cfg. Put
-- `ocpool -b` in /home/.shrc to start your apps on boot.
--
-- In the background, apps can't use the shell's screen: give screen apps
-- their own GPU + screen in their config (gpu = "...", screen = "...").

local computer = require("computer")
local event = require("event")

local Pool = require("ocui.pool")
local config = require("ocui.config")
local storage = require("ocui.storage")

local POOL_DEFAULTS = {
  autostart = { "hud" },  -- apps started by a bare `ocpool` / `ocpool -b`
  restartDelay = 10,      -- seconds before restarting a crashed app
  maxRestarts = 5,        -- restarts before giving up (reset after 5 min OK)
}

-- --------------------------------------------------------------- helpers --

local function parseArgs(...)
  local ok, shell = pcall(require, "shell")
  if ok and shell and shell.parse then
    return shell.parse(...)
  end
  local args, opts = {}, {}
  for _, a in ipairs(table.pack(...)) do
    local flags = type(a) == "string" and a:match("^%-(%a+)$")
    if flags then
      for f in flags:gmatch(".") do opts[f] = true end
    else
      table.insert(args, a)
    end
  end
  return args, opts
end

local availableApps, loadApp = Pool.availableApps, Pool.loadApp

-- Sends a command to a running background pool; returns ok, text, or
-- nil, "no background pool is running".
local function request(cmd, arg, timeout)
  local id = string.format("%d-%.3f", math.random(1, 1000000000), computer.uptime())
  computer.pushSignal(Pool.SIGNAL, cmd, arg, id)
  local name, _, ok, text = event.pull(timeout or 3, Pool.REPLY, id)
  if name == nil then
    return nil, "no background pool is running"
  end
  return ok, text
end

local function shellScreen()
  local ok, tty = pcall(require, "tty")
  if ok and tty and tty.screen then
    local okScreen, address = pcall(tty.screen)
    if okScreen then return address end
  end
  return nil
end

local function printStatus(text)
  local status = config.parse(text, "status")
  if not status then
    print(text)
    return
  end
  print(string.format("%-12s %-8s %8s %8s  %s", "APP", "STATE", "UPTIME", "RESTARTS", "ERROR"))
  for _, app in ipairs(status.apps or {}) do
    local state = app.state .. (app.pendingRestart and "*" or "")
    print(string.format("%-12s %-8s %8s %8d  %s", app.name, state,
      app.uptime and string.format("%.0fs", app.uptime) or "-", app.restarts or 0, app.error or ""))
  end
  if status.log and #status.log > 0 then
    print("\nrecent log:")
    for i = math.max(#status.log - 5, 1), #status.log do
      print("  " .. status.log[i])
    end
  end
end

-- ------------------------------------------------------------- commands --

local args, opts = parseArgs(...)
local cmd = args[1]

if cmd == "list" then
  local names = availableApps()
  if #names == 0 then print("no apps found in ocui/apps") end
  for _, name in ipairs(names) do
    local module, err = loadApp(name)
    print(string.format("%-12s %s", name, module and (module.description or "") or ("(broken: " .. err .. ")")))
  end
  return
end

if cmd == "log" then
  io.write(storage.read(Pool.LOG_PATH) or "(log is empty)\n")
  return
end

if cmd == "status" or cmd == "quit" then
  local ok, text = request(cmd)
  if ok == nil then
    io.stderr:write("ocpool: " .. tostring(text) .. "\n")
    return 1
  end
  if cmd == "status" then printStatus(text) else print("ocpool: background pool stopped") end
  return
end

if cmd == "start" or cmd == "stop" or cmd == "restart" then
  if not args[2] then
    io.stderr:write("usage: ocpool " .. cmd .. " <app>\n")
    return 1
  end
  local ok, text = request(cmd, args[2])
  if not ok then
    io.stderr:write("ocpool: " .. tostring(text) .. "\n")
    return 1
  end
  print(string.format("ocpool: %s %s", cmd, args[2]))
  return
end

if cmd == "help" or opts.h then
  print("usage: ocpool [-b] [app ...] | list | status | start|stop|restart <app> | quit | log")
  return
end

-- ----------------------------------------------------------------- run --

local poolCfg, cfgErr = config.load("ocpool", POOL_DEFAULTS)
if not poolCfg then
  io.stderr:write("ocpool: " .. cfgErr .. "\n")
  return 1
end

local names = #args > 0 and args or poolCfg.autostart
if #names == 0 then
  io.stderr:write("ocpool: no apps given and autostart is empty (/etc/ocui/ocpool.cfg)\n")
  return 1
end

if request("ping", nil, 0.5) then
  io.stderr:write("ocpool: a background pool is already running; use `ocpool start <app>`\n")
  return 1
end

local background = opts.b and true or false
local pool = Pool.new({
  background = background,
  shellScreen = shellScreen(),
  restartDelay = poolCfg.restartDelay,
  maxRestarts = poolCfg.maxRestarts,
  stopWhenIdle = not background, -- a background pool waits for `ocpool start`
})

-- Register every available app so the background pool can start any of
-- them later; the requested ones must load.
for _, name in ipairs(names) do
  local module, err = loadApp(name)
  if not module then
    io.stderr:write("ocpool: cannot load app '" .. name .. "': " .. err .. "\n")
    return 1
  end
  pool:register(module)
end
pool:registerAvailable()

if background then
  local okThread, thread = pcall(require, "thread")
  if not okThread then
    io.stderr:write("ocpool: background mode needs the OpenOS thread library\n")
    return 1
  end
  thread.create(function() pool:run(names) end):detach()
  print("ocpool: running " .. table.concat(names, ", ") .. " in the background")
  print("        `ocpool status` to check, `ocpool quit` to stop")
  return
end

print("ocpool: running " .. table.concat(names, ", ") .. " -- press q to quit")
pool:run(names)

local failed = false
for _, app in ipairs(pool:status()) do
  if app.state == "failed" then
    failed = true
    io.stderr:write(string.format("ocpool: %s failed: %s\n", app.name, app.error or "?"))
  end
end
if failed then
  io.stderr:write("ocpool: details in " .. Pool.LOG_PATH .. "\n")
  return 1
end
