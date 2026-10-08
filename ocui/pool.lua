-- ocui.pool
-- Runs several ocui apps at once on one cooperative loop (ocui.loop), plus
-- shared data services they can subscribe to.
--
-- An app is a module (ocui/apps/<name>.lua):
--   return {
--     name = "hud",
--     description = "one line for `ocpool list`",
--     defaults = { ... },          -- config defaults; nil = no config file
--     keyboard = true,             -- optional: takes typed input ('q' won't quit)
--     start = function(ctx, config) ... end,
--   }
-- start() sets the app up and returns; all ongoing work is registered via
-- ctx (tasks, signal handlers, cleanups), so the pool can stop or restart
-- any one app without touching the others:
--
--   ctx:every(seconds, fn)   periodic task (coroutine; may ctx.sleep/yield)
--   ctx:spawn(fn)            long-running task
--   ctx:on(signal, fn)       signal or in-process event handler (fn(name, ...))
--   ctx:idle(fn)             runs after every loop round (see Loop:idle)
--   ctx:emit(event, ...)     in-process event to every ctx:on(event) handler
--   ctx:cancel(handle)       cancel one task/handler
--   ctx:onStop(fn)           cleanup, run when the app stops for any reason
--   ctx:claim(resource)      exclusive resource, e.g. "screen:<address>";
--                            returns true or nil, reason
--   ctx:use(service)         shared service API (see below)
--   ctx:log(fmt, ...)        line in /tmp/ocpool.log
--   ctx:stop()               stop this app
--   ctx:apps()               status of every app (like `ocpool status`)
--   ctx:startApp(name) / stopApp(name) / restartApp(name)
--   ctx.sleep(s), ctx.yield()
--   ctx.name, ctx.config, ctx.background, ctx.shellScreen
--
-- A service is a module (ocui/services/<name>.lua) with the same shape,
-- whose start(ctx, config) returns an API table. It is started on the
-- first ctx:use(name), shared by every app that uses it, and stopped
-- `serviceLinger` seconds after its last user stops (so restarting an app
-- doesn't throw away a service's history). ctx:use returns a stable facade:
-- if the service crashes and restarts, the same facade keeps working; while
-- it is down, its functions return nil, "<name> unavailable".
--
-- Errors in an app or service (in start, a task or a handler) stop only
-- that one; it is restarted after `restartDelay` seconds, up to
-- `maxRestarts` times (the count resets once it has run for 5 minutes).
--
-- Control from another program (used by `ocpool` in background mode; only
-- a pool created with remote = true -- by default, a background one --
-- answers):
--   computer.pushSignal("ocpool", cmd, arg, replyId)
--   cmd: "status" | "start" | "stop" | "restart" | "quit" | "ping"
--   reply: signal "ocpool_reply", replyId, ok, text (status = serialized)

local computer = require("computer")

local Loop = require("ocui.loop")
local config = require("ocui.config")
local storage = require("ocui.storage")

local Pool = {}
Pool.__index = Pool

Pool.SIGNAL = "ocpool"
Pool.REPLY = "ocpool_reply"
Pool.LOG_PATH = "/tmp/ocpool.log"

local STABLE_AFTER = 300 -- seconds of uptime that reset the restart count
local LOG_KEEP = 50

-- opts.background: true when running detached next to the shell ('q' and
--   Ctrl+C are then left to the shell, and the shell's screen is off-limits).
-- opts.shellScreen: address of the screen the shell uses.
-- opts.restartDelay (10), opts.maxRestarts (5), opts.serviceLinger (15).
-- opts.stopWhenIdle: stop the loop once no app is running or pending a
--   restart (default true).
-- opts.remote: answer `ocpool` control signals (default: = background).
-- opts.logPath: log file (default Pool.LOG_PATH).
function Pool.new(opts)
  opts = opts or {}
  local self = setmetatable({
    apps = {},
    order = {},
    services = {},
    claims = {},
    background = opts.background and true or false,
    shellScreen = opts.shellScreen,
    restartDelay = opts.restartDelay or 10,
    maxRestarts = opts.maxRestarts or 5,
    serviceLinger = opts.serviceLinger or 15,
    stopWhenIdle = opts.stopWhenIdle ~= false,
    recent = {},
    logLines = 0,
    logPath = opts.logPath or Pool.LOG_PATH,
  }, Pool)
  local remote = opts.remote
  if remote == nil then remote = self.background end
  self.loop = Loop.new({
    quitChar = (not self.background) and 113 or false,
    stopOnInterrupt = not self.background,
    onError = function(err, owner) self:onError(owner, err) end,
  })
  if remote then
    self.loop:on(Pool.SIGNAL, function(_, cmd, arg, replyId)
      self:command(cmd, arg, replyId)
    end, self)
  end
  return self
end

-- ------------------------------------------------------------------ log --

function Pool:log(source, fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = tostring(fmt) end
  local line = string.format("[%8.1f] %s: %s", computer.uptime(), source, msg)
  table.insert(self.recent, line)
  while #self.recent > LOG_KEEP do table.remove(self.recent, 1) end
  self.logLines = self.logLines + 1
  -- keep the file bounded: rewrite it from the in-memory tail now and then
  if self.logLines > 500 then
    self.logLines = #self.recent
    pcall(storage.write, self.logPath, table.concat(self.recent, "\n") .. "\n")
  else
    pcall(storage.append, self.logPath, line .. "\n")
  end
end

-- -------------------------------------------------------------- registry --

local function newRecord(module, kind)
  assert(type(module) == "table" and type(module.name) == "string" and type(module.start) == "function",
    kind .. " module needs a name and a start function")
  return {
    name = module.name,
    kind = kind,
    module = module,
    state = "stopped",
    restarts = 0,
    cleanups = {},
    claims = {},
    uses = {},   -- services this record uses
    users = {},  -- (services) records using it
  }
end

function Pool:register(module)
  if not self.apps[module.name] then
    table.insert(self.order, module.name)
  end
  self.apps[module.name] = newRecord(module, "app")
  return self.apps[module.name]
end

-- Services are found lazily as ocui.services.<name>; registerService lets
-- tests or embedders supply one directly.
function Pool:registerService(module)
  self.services[module.name] = newRecord(module, "service")
  return self.services[module.name]
end

-- ------------------------------------------------------------- resources --

function Pool:claim(rec, resource)
  if self.background and self.shellScreen and resource == "screen:" .. self.shellScreen then
    return nil, "that is the shell's screen; run ocpool in the foreground or configure another screen"
  end
  local holder = self.claims[resource]
  if holder and holder ~= rec then
    return nil, resource .. " is in use by " .. holder.name
  end
  self.claims[resource] = rec
  rec.claims[resource] = true
  return true
end

function Pool:release(rec)
  for resource in pairs(rec.claims) do
    if self.claims[resource] == rec then self.claims[resource] = nil end
  end
  rec.claims = {}
end

-- -------------------------------------------------------------- services --

local function facade(svc)
  return setmetatable({}, {
    __index = function(_, key)
      local api = svc.api
      if svc.state == "running" and api and api[key] ~= nil then
        return api[key]
      end
      return function() return nil, svc.name .. " unavailable" end
    end,
  })
end

-- Returns the facade of service `name` for `user`, starting it if needed.
function Pool:use(user, name)
  local svc = self.services[name]
  if not svc then
    local ok, module = pcall(require, "ocui.services." .. name)
    if not ok or type(module) ~= "table" then
      error("unknown service: " .. tostring(name) .. (ok and "" or (" (" .. tostring(module) .. ")")), 0)
    end
    svc = self:registerService(module)
  end
  svc.users[user] = true
  user.uses[name] = svc
  svc.facade = svc.facade or facade(svc)
  if svc.state ~= "running" then
    svc.pendingRestart = nil
    local ok, err = self:startRecord(svc)
    if not ok then error("service " .. name .. " failed to start: " .. tostring(err), 0) end
  end
  return svc.facade
end

-- Drops `user` from every service it used; services left without users
-- are stopped after serviceLinger seconds unless someone uses them again.
function Pool:releaseServices(user)
  for name, svc in pairs(user.uses) do
    svc.users[user] = nil
    if next(svc.users) == nil then
      local linger = self.serviceLinger
      self.loop:spawn(function()
        Loop.sleep(linger)
        if next(svc.users) == nil and svc.state ~= "stopped" then
          svc.pendingRestart = nil
          if svc.state == "running" then self:teardown(svc) end
          svc.state = "stopped"
          self:log("pool", "service %s stopped (no users)", name)
        end
      end, self)
    end
  end
  user.uses = {}
end

-- --------------------------------------------------------------- context --

local function newContext(pool, rec, cfg)
  local loop = pool.loop
  local ctx = {
    name = rec.name,
    config = cfg,
    background = pool.background,
    shellScreen = pool.shellScreen,
    sleep = Loop.sleep,
    yield = Loop.yield,
  }
  function ctx:every(interval, fn) return loop:every(interval, fn, rec) end
  function ctx:spawn(fn) return loop:spawn(fn, rec) end
  function ctx:on(name, fn) return loop:on(name, fn, rec) end
  function ctx:idle(fn) return loop:idle(fn, rec) end
  function ctx:emit(name, ...) loop:emit(name, ...) end
  function ctx:cancel(handle)
    if handle.kind then loop:cancel(handle) else loop:off(handle) end
  end
  function ctx:onStop(fn) table.insert(rec.cleanups, fn) end
  function ctx:claim(resource) return pool:claim(rec, resource) end
  function ctx:use(name) return pool:use(rec, name) end
  function ctx:log(fmt, ...) pool:log(rec.name, fmt, ...) end
  function ctx:stop()
    if rec.kind == "app" then pool:stop(rec.name) end
  end
  function ctx:apps() return pool:status() end
  function ctx:services() return pool:serviceStatus() end
  -- Stops the whole pool (every app), as `ocpool quit` would.
  function ctx:quitPool() pool.loop:stop() end
  function ctx:startApp(name) return pool:start(name) end
  function ctx:stopApp(name) return pool:stop(name) end
  function ctx:restartApp(name) return pool:restart(name) end
  return ctx
end

-- ------------------------------------------------------------- lifecycle --

local function traceback(err)
  if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
  return tostring(err)
end

-- Starts an app or service record. Returns true, or nil + error.
function Pool:startRecord(rec)
  if rec.state == "running" then return true end
  rec.pendingRestart = nil

  local cfg = {}
  if rec.module.defaults ~= nil then
    local loaded, err = config.load(rec.name, rec.module.defaults)
    if not loaded then
      self:markFailed(rec, err, false)
      return nil, err
    end
    cfg = loaded
  end

  rec.state = "running"
  rec.error = nil
  rec.startedAt = computer.uptime()
  rec.cleanups = {}
  local ctx = newContext(self, rec, cfg)
  local ok, result = xpcall(function() return rec.module.start(ctx, cfg) end, traceback)
  if not ok then
    self:fail(rec, result)
    return nil, rec.error
  end
  if rec.kind == "service" then rec.api = result end
  self:updateQuitKey()
  self:log("pool", "started %s%s", rec.kind == "service" and "service " or "", rec.name)
  return true
end

function Pool:start(name)
  local app = self.apps[name]
  if not app then return nil, "unknown app: " .. tostring(name) end
  return self:startRecord(app)
end

-- Tears a record down: cancels its tasks/handlers, runs cleanups (last
-- registered first), releases its resources and service subscriptions.
function Pool:teardown(rec)
  self.loop:cancelOwner(rec)
  for i = #rec.cleanups, 1, -1 do
    local ok, err = pcall(rec.cleanups[i])
    if not ok then self:log(rec.name, "cleanup error: %s", tostring(err)) end
  end
  rec.cleanups = {}
  self:release(rec)
  self:releaseServices(rec)
end

function Pool:stop(name)
  local app = self.apps[name]
  if not app then return nil, "unknown app: " .. tostring(name) end
  app.pendingRestart = nil
  if app.state == "running" then
    self:teardown(app)
    self:log("pool", "stopped %s", name)
  end
  app.state = "stopped"
  self:checkIdle()
  return true
end

function Pool:restart(name)
  local ok, err = self:stop(name)
  if not ok then return nil, err end
  self.apps[name].restarts = 0
  return self:start(name)
end

function Pool:markFailed(rec, err, allowRestart)
  rec.state = "failed"
  -- first line for status displays; the full traceback goes to the log
  rec.errorFull = tostring(err)
  rec.error = rec.errorFull:match("^[^\n]*")
  self:log(rec.name, "FAILED: %s", tostring(err))
  if allowRestart and rec.restarts < self.maxRestarts then
    rec.pendingRestart = true
    local delay = self.restartDelay
    self.loop:spawn(function()
      Loop.sleep(delay)
      if rec.state == "failed" and rec.pendingRestart then
        if rec.kind == "service" and next(rec.users) == nil then return end
        rec.restarts = rec.restarts + 1
        self:log("pool", "restarting %s (attempt %d/%d)", rec.name, rec.restarts, self.maxRestarts)
        self:startRecord(rec)
      end
    end, self)
  end
  self:checkIdle()
end

function Pool:fail(rec, err)
  if rec.state == "running" then
    if rec.startedAt and computer.uptime() - rec.startedAt > STABLE_AFTER then
      rec.restarts = 0
    end
    self:teardown(rec)
  end
  self:markFailed(rec, err, true)
end

function Pool:onError(owner, err)
  if type(owner) == "table" and owner.module then
    self:fail(owner, err)
  else
    self:log("pool", "internal error: %s", tostring(err))
  end
end

-- An app module with `keyboard = true` takes text input, so a plain 'q'
-- must not quit a foreground pool while such an app runs (it brings its
-- own way out).
function Pool:updateQuitKey()
  if self.background then return end
  for _, app in pairs(self.apps) do
    if app.state == "running" and app.module.keyboard then
      self.loop.quitChar = false
      return
    end
  end
  self.loop.quitChar = 113
end

-- Services alone don't keep a foreground pool alive.
function Pool:checkIdle()
  self:updateQuitKey()
  if not self.stopWhenIdle or self.starting or not self.loop.running then return end
  for _, name in ipairs(self.order) do
    local app = self.apps[name]
    if app.state == "running" or app.pendingRestart then return end
  end
  self.loop:stop()
end

function Pool:status()
  local now = computer.uptime()
  local list = {}
  for _, name in ipairs(self.order) do
    local app = self.apps[name]
    table.insert(list, {
      name = name,
      description = app.module.description,
      state = app.state,
      error = app.error,
      uptime = app.state == "running" and (now - app.startedAt) or nil,
      restarts = app.restarts,
      pendingRestart = app.pendingRestart or nil,
      cpu = self.loop:cpuTime(app),
      tasks = app.state == "running" and self.loop:countOwned(app) or 0,
    })
  end
  return list
end

function Pool:serviceStatus()
  local list = {}
  for name, svc in pairs(self.services) do
    local users = {}
    for user in pairs(svc.users) do table.insert(users, user.name) end
    table.sort(users)
    table.insert(list, { name = name, state = svc.state, error = svc.error, users = users,
      cpu = self.loop:cpuTime(svc) })
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- ---------------------------------------------------------- remote control --

function Pool:command(cmd, arg, replyId)
  local ok, text = true, ""
  if cmd == "status" then
    text = config.serialize({
      apps = self:status(), services = self:serviceStatus(),
      log = self.recent, background = self.background,
    })
  elseif cmd == "start" then
    ok, text = self:start(arg)
  elseif cmd == "stop" then
    ok, text = self:stop(arg)
  elseif cmd == "restart" then
    ok, text = self:restart(arg)
  elseif cmd == "quit" then
    self.loop:stop()
  elseif cmd == "ping" then
    text = "pong"
  else
    ok, text = nil, "unknown command: " .. tostring(cmd)
  end
  if replyId ~= nil then
    computer.pushSignal(Pool.REPLY, replyId, ok and true or false, tostring(text or ""))
  end
end

-- -------------------------------------------------------------------- run --

-- Starts `names` (all registered apps if nil) and runs until quit. Every
-- app and service is stopped (cleanups run) before returning.
function Pool:run(names)
  pcall(storage.write, self.logPath, "")
  self.starting = true
  for _, name in ipairs(names or self.order) do
    local ok, err = self:start(name)
    if not ok then self:log("pool", "could not start %s: %s", name, tostring(err)) end
  end
  self.starting = false
  self.loop.running = true
  self:checkIdle() -- nothing started and nothing pending: don't block
  if self.loop.running then
    self.loop:run()
  end
  for _, name in ipairs(self.order) do
    local app = self.apps[name]
    app.pendingRestart = nil
    if app.state == "running" then
      self:teardown(app)
      app.state = "stopped"
    end
  end
  for _, svc in pairs(self.services) do
    svc.pendingRestart = nil
    if svc.state == "running" then
      self:teardown(svc)
      svc.state = "stopped"
    end
  end
end

-- ------------------------------------------------------------ app lookup --

-- Directories that can hold ocui.apps.* modules, from package.path.
local function appDirs()
  local dirs, seen = {}, {}
  for template in package.path:gmatch("[^;]+") do
    local base = template:match("^(.*)%?%.lua$")
    if base then
      local dir = base .. "ocui/apps"
      if not seen[dir] then
        seen[dir] = true
        table.insert(dirs, dir)
      end
    end
  end
  return dirs
end

-- Names of the app modules installed (ocui/apps/*.lua), sorted.
function Pool.availableApps()
  local okFs, fs = pcall(require, "filesystem")
  local names, seen = {}, {}
  if not okFs then return names end
  for _, dir in ipairs(appDirs()) do
    if fs.isDirectory(dir) then
      for entry in fs.list(dir) do
        local name = entry:match("^([%w_%-]+)%.lua$")
        if name and not seen[name] then
          seen[name] = true
          table.insert(names, name)
        end
      end
    end
  end
  table.sort(names)
  return names
end

-- Loads app module `name`; returns it, or nil + error.
function Pool.loadApp(name)
  local ok, module = pcall(require, "ocui.apps." .. name)
  if not ok then return nil, tostring(module) end
  if type(module) ~= "table" or type(module.start) ~= "function" then
    return nil, "ocui.apps." .. name .. " is not an app module"
  end
  return module
end

-- Registers every installed app that loads (and isn't registered yet).
function Pool:registerAvailable()
  for _, name in ipairs(Pool.availableApps()) do
    if not self.apps[name] then
      local module = Pool.loadApp(name)
      if module then self:register(module) end
    end
  end
end

-- Runs one app module on its own pool, standalone; returns when it quits.
-- If the app ended in failure, raises its error (like a plain program).
function Pool.runSingle(module, opts)
  opts = opts or {}
  if opts.maxRestarts == nil then opts.maxRestarts = 0 end
  local pool = Pool.new(opts)
  pool:register(module)
  pool:run({ module.name })
  local app = pool.apps[module.name]
  if app.state == "failed" then
    error(app.errorFull or app.error, 0)
  end
end

return Pool
