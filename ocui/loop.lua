-- ocui.loop
-- Cooperative scheduler + event dispatcher; the engine under ocui.pool,
-- ocui.app and the HUD.
--
-- OpenComputers runs one Lua state per computer, and any non-direct
-- component call (e.g. every AE2 call) freezes that whole state until the
-- next server tick -- OpenOS threads don't change that. So concurrency
-- here is cooperative: every task body runs in its own coroutine and may
-- give way to others mid-work with Loop.yield() / Loop.sleep(seconds).
-- Between tasks the loop blocks in event.pull() for exactly as long as the
-- next wake-up allows, so input stays responsive without busy-waiting.
--
--   local loop = Loop.new()
--   loop:every(1, sampleLsc)               -- now, then every 1 s
--   loop:spawn(function()                  -- long-running task
--     while true do work(); Loop.sleep(5) end
--   end)
--   loop:on("touch", onTouch)              -- handler(name, ...signal args)
--   loop:run()                             -- until loop:stop(), 'q', Ctrl+C
--
-- Inside a task, never call event.pull()/os.sleep(): they block the whole
-- loop. Use Loop.sleep()/Loop.yield().

local computer = require("computer")
local event = require("event")

local Loop = {}
Loop.__index = Loop

local SLEEP = {} -- unique token marking our own yields

-- Number of task coroutines currently being resumed (across loops). In
-- OpenOS every program already runs inside a process coroutine, so
-- coroutine.running() can't tell "inside a task" from "outside" -- this can.
local tasksResuming = 0

-- opts.quitChar: key code that stops the loop (default 113 = 'q';
--   false disables -- needed when running in the background next to a shell).
-- opts.stopOnInterrupt: stop on the "interrupted" signal (default true;
--   false in the background, where Ctrl+C belongs to the shell).
-- opts.onError(err, owner, entry): called when a task or handler raises.
--   Without it, errors propagate out of run().
function Loop.new(opts)
  opts = opts or {}
  local quitChar = opts.quitChar
  if quitChar == nil then quitChar = 113 end
  local stopOnInterrupt = opts.stopOnInterrupt
  if stopOnInterrupt == nil then stopOnInterrupt = true end
  return setmetatable({
    entries = {},
    handlers = {},
    quitChar = quitChar,
    stopOnInterrupt = stopOnInterrupt,
    onError = opts.onError,
    running = false,
    current = nil,
  }, Loop)
end

-- ------------------------------------------------------- task primitives --

-- Suspends the current task for `seconds` (0 = just let others run).
-- Only valid inside a task started by every()/spawn().
function Loop.sleep(seconds)
  if tasksResuming == 0 then
    error("Loop.sleep()/yield() called outside a loop task", 2)
  end
  coroutine.yield(SLEEP, seconds or 0)
end

function Loop.yield()
  Loop.sleep(0)
end

local function newEntry(self, kind, fn, interval, owner)
  local entry = {
    kind = kind, fn = fn, interval = interval, owner = owner,
    nextAt = 0, co = nil, wakeAt = nil, cancelled = false,
  }
  table.insert(self.entries, entry)
  return entry
end

-- Runs fn() now and then every `interval` seconds after each run *starts*.
-- A run that is still sleeping/yielding when the next one is due is not
-- overlapped: the next run starts after it finishes.
function Loop:every(interval, fn, owner)
  return newEntry(self, "every", fn, interval, owner)
end

-- Runs fn() once, as soon as possible; it can live forever with sleeps.
function Loop:spawn(fn, owner)
  return newEntry(self, "spawn", fn, nil, owner)
end

function Loop:cancel(entry)
  entry.cancelled = true
end

-- handler(name, ...) for signal `name`; "*" receives every signal.
function Loop:on(name, fn, owner)
  local h = { name = name, fn = fn, owner = owner, cancelled = false }
  self.handlers[name] = self.handlers[name] or {}
  table.insert(self.handlers[name], h)
  return h
end

function Loop:off(handler)
  handler.cancelled = true
end

-- Cancels every task and handler registered with this owner.
function Loop:cancelOwner(owner)
  for _, e in ipairs(self.entries) do
    if e.owner == owner then e.cancelled = true end
  end
  for _, list in pairs(self.handlers) do
    for _, h in ipairs(list) do
      if h.owner == owner then h.cancelled = true end
    end
  end
end

function Loop:stop()
  self.running = false
end

-- ------------------------------------------------------------- internals --

local function traceback(err)
  if debug and debug.traceback then
    return debug.traceback(tostring(err), 2)
  end
  return tostring(err)
end

function Loop:fail(err, owner, entry)
  if self.onError then
    self.onError(err, owner, entry)
  else
    error(err, 0)
  end
end

-- Resumes an entry's coroutine (creating it for a fresh run).
function Loop:step(entry)
  if not entry.co then
    local fn = entry.fn
    entry.co = coroutine.create(function()
      return xpcall(fn, traceback)
    end)
    entry.startedAt = computer.uptime()
  end
  self.current = entry
  tasksResuming = tasksResuming + 1
  local resumed = table.pack(coroutine.resume(entry.co))
  tasksResuming = tasksResuming - 1
  self.current = nil

  if coroutine.status(entry.co) == "dead" then
    entry.co = nil
    local ok, xok, err = resumed[1], resumed[2], resumed[3]
    if not ok then
      err, xok = xok, false -- coroutine machinery error
    end
    if entry.kind == "spawn" then
      entry.cancelled = true
    else
      local after = computer.uptime()
      entry.nextAt = entry.startedAt + entry.interval
      if entry.nextAt <= after then entry.nextAt = after + entry.interval end
    end
    if not xok then
      self:fail(err, entry.owner, entry)
    end
  else
    -- Yielded: our sleep token, or a foreign yield (treated as yield()).
    local seconds = 0
    if resumed[2] == SLEEP then seconds = tonumber(resumed[3]) or 0 end
    entry.wakeAt = computer.uptime() + seconds
  end
end

function Loop:dueAt(entry)
  if entry.co then return entry.wakeAt end
  return entry.nextAt
end

function Loop:runDue()
  -- Iterate over a snapshot: tasks may add/cancel entries while running.
  local snapshot = {}
  for i, e in ipairs(self.entries) do snapshot[i] = e end
  for _, entry in ipairs(snapshot) do
    if not self.running then return end
    if not entry.cancelled and computer.uptime() >= self:dueAt(entry) then
      self:step(entry)
    end
  end
  -- Compact cancelled entries.
  local live = {}
  for _, e in ipairs(self.entries) do
    if not e.cancelled then table.insert(live, e) end
  end
  self.entries = live
end

function Loop:timeUntilNext()
  local nextAt = math.huge
  for _, e in ipairs(self.entries) do
    if not e.cancelled then
      local at = self:dueAt(e)
      if at < nextAt then nextAt = at end
    end
  end
  if nextAt == math.huge then return nil end -- nothing scheduled: wait for signals
  return math.max(nextAt - computer.uptime(), 0)
end

local function callHandlers(self, list, signal)
  if not list then return end
  local snapshot = {}
  for i, h in ipairs(list) do snapshot[i] = h end
  for _, h in ipairs(snapshot) do
    if not h.cancelled then
      local ok, err = xpcall(function()
        h.fn(table.unpack(signal, 1, signal.n))
      end, traceback)
      if not ok then self:fail(err, h.owner, h) end
    end
  end
end

-- Delivers an in-process event to handlers registered with on(name),
-- synchronously, without going through the OC signal queue. Used by pool
-- services to publish updates to the apps that use them.
function Loop:emit(name, ...)
  local signal = table.pack(name, ...)
  callHandlers(self, self.handlers[name], signal)
end

function Loop:dispatch(signal)
  local name = signal[1]
  if name == nil then return end
  if name == "interrupted" and self.stopOnInterrupt then
    self.running = false
    return
  end
  if name == "key_down" and self.quitChar and signal[3] == self.quitChar then
    self.running = false
    return
  end
  callHandlers(self, self.handlers[name], signal)
  callHandlers(self, self.handlers["*"], signal)
  -- drop cancelled handlers
  for key, list in pairs(self.handlers) do
    local live = {}
    for _, h in ipairs(list) do
      if not h.cancelled then table.insert(live, h) end
    end
    self.handlers[key] = live
  end
end

function Loop:run()
  self.running = true
  while self.running do
    self:runDue()
    if not self.running then break end
    local timeout = self:timeUntilNext()
    -- OpenOS raises "interrupted" out of event.pull on Ctrl+Alt+C (a hard
    -- interrupt aimed at the foreground process): always a clean stop.
    local ok, signal = pcall(function()
      return table.pack(event.pull(timeout))
    end)
    if not ok then
      if tostring(signal):find("interrupted", 1, true) then
        self.running = false
      else
        error(signal, 0)
      end
    else
      self:dispatch(signal)
    end
  end
end

return Loop
