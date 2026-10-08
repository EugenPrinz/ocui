-- ocui.session
-- Boot straight into the ocui desktop. OpenOS runs /boot/*.lua at boot
-- and then, forever, the program named by $SHELL; /boot/99_ocui.lua
-- (installed by install.lua) points $SHELL at /usr/bin/ocsession.lua
-- when the session is switched on (`ocsession on`), and that program
-- calls run() here:
--
--   splash (any key: plain OpenOS shell instead)
--   -> background pool (`ocpool -b`, its autostart apps), once per boot
--   -> desktop; leaving it opens the OpenOS shell, and `exit` there comes
--      back to the desktop
--   -> if the desktop crashes: a crash screen with the error (also in
--      /home/ocui-crash.log); R restarts it, S opens the shell, and it
--      restarts by itself after a few seconds unless it keeps crashing.
--
-- Nothing in OpenOS itself is changed: `ocsession off` (or deleting
-- /boot/99_ocui.lua) gives the plain shell back.

local computer = require("computer")
local component = require("component")
local event = require("event")

local config = require("ocui.config")
local storage = require("ocui.storage")

local M = {
  PROGRAM = "/usr/bin/ocsession.lua",
  BOOT_SCRIPT = "/boot/99_ocui.lua",
  CRASH_LOG = "/home/ocui-crash.log",
  defaults = {
    boot = false,          -- start the session at boot (`ocsession on|off`)
    splash = 3,            -- seconds to press a key for the plain shell
    backgroundPool = true, -- run `ocpool -b` (its autostart apps) once per boot
    autoRestart = 10,      -- seconds before restarting a crashed desktop
  },
  started = false,  -- background pool started this boot
  active = false,   -- running as the session (the desktop offers exit/reboot)
  crashes = {},
}

local COLORS = { bg = 0x101820, text = 0xE4E4E8, dim = 0x8A8A96, accent = 0x4C8BF5, bad = 0xE0574C }

-- ---------------------------------------------------------------- config --

-- The session settings, without creating the file (safe at boot).
function M.readConfig()
  local text = storage.read(config.path("session"))
  local user = text and config.parse((text:gsub("^%s*%-%-[^\n]*\n", "")), "session")
  return config.merge(M.defaults, user or {})
end

function M.setBoot(on)
  local cfg = M.readConfig()
  cfg.boot = on and true or false
  return config.save("session", cfg)
end

-- Called by /boot/99_ocui.lua: whether to take over $SHELL. The session
-- program must at least compile, so a broken update can't lock the
-- computer in a loop of errors.
function M.bootCheck()
  if not M.readConfig().boot then return false end
  local text = storage.read(M.PROGRAM)
  return text ~= nil and load(text, "=" .. M.PROGRAM) ~= nil
end

-- --------------------------------------------------------------- screens --

local function gpu() return component.isAvailable("gpu") and component.gpu or nil end

-- Clears the screen and draws `lines` ({text, color} or strings) centered.
local function screen(lines, top)
  local g = gpu()
  if not g then
    for _, l in ipairs(lines) do print(type(l) == "table" and l[1] or l) end
    return
  end
  local w, h = g.maxResolution()
  g.setResolution(w, h)
  g.setBackground(COLORS.bg)
  g.fill(1, 1, w, h, " ")
  local y = top or math.max(math.floor((h - #lines) / 2), 1)
  for _, l in ipairs(lines) do
    local text, color = l, COLORS.text
    if type(l) == "table" then text, color = l[1], l[2] or COLORS.text end
    text = tostring(text)
    if #text > w then text = text:sub(1, w) end
    g.setForeground(color)
    local len = require("ocui.util").len(text)
    g.set(math.max(math.floor((w - len) / 2) + 1, 1), y, text)
    y = y + 1
  end
end

-- Waits up to `seconds` for a key; returns its char/code or nil. (A
-- function so tests can script it.)
function M.waitKey(seconds)
  local name, _, char, code = event.pull(seconds, "key_down")
  if name then return char, code end
  return nil
end

local function resetTerminal()
  local g = gpu()
  if g then
    g.setBackground(0x000000)
    g.setForeground(0xFFFFFF)
    local w, h = g.getResolution()
    g.fill(1, 1, w, h, " ")
  end
  local ok, term = pcall(require, "term")
  if ok and term and term.clear then pcall(term.clear) end
end

-- Splash with a countdown; true if a key was pressed (= plain shell).
function M.splash(seconds)
  for left = seconds, 1, -1 do
    screen({
      { "ocui", COLORS.accent },
      "",
      { "Starting the desktop in " .. left .. "...", COLORS.text },
      { "press any key for the OpenOS shell", COLORS.dim },
    })
    if M.waitKey(1) then return true end
  end
  return false
end

local function logCrash(err)
  local stamp = os.date and select(2, pcall(os.date, "%Y-%m-%d %H:%M:%S")) or ""
  pcall(storage.append, M.CRASH_LOG, string.format("[%s, uptime %.0f s]\n%s\n\n",
    tostring(stamp), computer.uptime(), tostring(err)))
end

-- Shows the crash; returns "restart" or "shell".
function M.crashScreen(err, autoRestart)
  local util = require("ocui.util")
  local g = gpu()
  local w = g and select(1, g.maxResolution()) or 80
  local lines = {
    { "The ocui desktop stopped with an error", COLORS.bad },
    "",
  }
  local shown = 0
  for line in (tostring(err) .. "\n"):gmatch("([^\n]*)\n") do
    for _, part in ipairs(util.wrap((line:gsub("\t", "  ")), w - 8)) do
      if shown < 30 then lines[#lines + 1] = { part, COLORS.dim } end
      shown = shown + 1
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = { "Saved to " .. M.CRASH_LOG, COLORS.dim }
  lines[#lines + 1] = ""
  local footer = #lines + 1
  for left = autoRestart > 0 and autoRestart or math.huge, 1, -1 do
    lines[footer] = { autoRestart > 0
      and string.format("R restart the desktop    S OpenOS shell    (restarting in %d s)", left)
      or "R restart the desktop    S OpenOS shell", COLORS.text }
    screen(lines, 3)
    local char = M.waitKey(1)
    if char then
      local c = type(char) == "number" and char > 0 and string.char(char):lower() or ""
      if c == "s" then return "shell" end
      if c == "r" then return "restart" end
    end
  end
  return "restart"
end

-- ------------------------------------------------------------------ parts --

local function startBackgroundPool()
  local Pool = require("ocui.pool")
  local id = "ocsession-" .. math.random(1, 1000000)
  computer.pushSignal(Pool.SIGNAL, "ping", nil, id)
  if event.pull(0.5, Pool.REPLY, id) then return end -- already running
  pcall(require("shell").execute, "ocpool", nil, "-b")
end

-- Runs the desktop with every installed app; returns true when the user
-- left it, or false, error if it crashed.
function M.runDesktop()
  local Pool = require("ocui.pool")
  local desktop = require("ocui.apps.desktop")
  local pool = Pool.new({})
  pool:register(desktop)
  pool:registerAvailable()
  -- a crashed desktop is ours to handle (crash screen), not the pool's to
  -- restart; and without it the other windows have nowhere to go. (A
  -- task, not loop:stop() right away: the crash may come while the pool
  -- is still starting, before its loop runs.)
  local crashed
  pool.loop:on(Pool.FAILED, function(_, name)
    if name ~= desktop.name then return end
    local rec = pool.apps[name]
    crashed = rec.errorFull or rec.error
    rec.pendingRestart = nil
    pool.loop:spawn(function() pool.loop:stop() end)
  end)
  local ok, err = pcall(pool.run, pool, { desktop.name })
  if not ok then return false, err end
  if crashed then return false, crashed end
  return true
end

local function runShell()
  resetTerminal()
  io.write("OpenOS shell -- type `exit` to go back to the ocui desktop\n")
  local ok, err = pcall(require("shell").execute, "sh")
  if not ok then io.stderr:write(tostring(err) .. "\n") end
end

-- Too many crashes in the last minute: stop restarting by ourselves.
local function crashLoop()
  local now = computer.uptime()
  table.insert(M.crashes, now)
  while M.crashes[1] and now - M.crashes[1] > 60 do table.remove(M.crashes, 1) end
  return #M.crashes >= 3
end

-- --------------------------------------------------------------------- run --

-- The session: what $SHELL runs. Returns after the shell's `exit` (OpenOS
-- then runs it again, which brings the desktop back).
function M.run()
  M.active = true
  local cfg = M.readConfig()
  if not M.started then
    M.started = true
    if os.setenv then os.setenv("HOME", os.getenv and os.getenv("HOME") or "/home") end
    local okShell, shell = pcall(require, "shell")
    if okShell and shell.setWorkingDirectory then pcall(shell.setWorkingDirectory, "/home") end
    if cfg.backgroundPool then startBackgroundPool() end
    if cfg.splash > 0 and M.splash(cfg.splash) then
      runShell()
      return
    end
  end
  while true do
    local ok, err = M.runDesktop()
    if ok then
      runShell()
      return
    end
    logCrash(err)
    local looping = crashLoop()
    if M.crashScreen(err, looping and 0 or cfg.autoRestart) == "shell" then
      runShell()
      return
    end
  end
end

return M
