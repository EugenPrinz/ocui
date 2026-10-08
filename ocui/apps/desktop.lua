-- desktop: a simple desktop for one screen -- apps open full-screen
-- windows above a taskbar (start menu, one button per window, clock).
-- With no window shown, the home screen lists every app as a tile.
--
--   desktop           (apps/desktop.lua: a pool with every installed app)
--
-- Keys: F12 start menu, Ctrl+Tab / Ctrl+Shift+Tab next / previous window,
-- Ctrl+D home screen; inside a window the app's own keys (Ctrl+Q closes most).
-- Right click a taskbar button: close / restart that app.

local computer = require("computer")

local Dialog = require("ocui.dialog")
local Host = require("ocui.host")
local menu = require("ocui.menu")
local theme = require("ocui.theme")
local util = require("ocui.util")
local widgets = require("ocui.widgets")
local base = require("ocui.widget")
local Widget, Container = base.Widget, base.Container

local M = {
  name = "desktop",
  description = "desktop: full-screen app windows + taskbar",
  keyboard = true,
}

local TASKBAR_BG = 0x1C1C26
local TILE_W, TILE_H = 36, 4

-- ------------------------------------------------------------------ Tile --

local Tile = setmetatable({}, { __index = Widget })
Tile.__index = Tile

function Tile.new(app, onLaunch)
  local self = setmetatable(Widget.new({ w = TILE_W, h = TILE_H }), Tile)
  self.app = app
  self.onLaunch = onLaunch
  self.focusable = true
  return self
end

function Tile:draw(canvas)
  local focus = self:showsFocus()
  local bg = focus and 0x24304A or theme.panel
  canvas:fillRect(0, 0, self.w, self.h, bg)
  canvas.bg = bg
  canvas:border(0, 0, self.w, self.h, focus and theme.accent or theme.border)
  local running = self.app.state == "running"
  canvas:text(2, 1, util.ellipsis(self.app.name, self.w - 6), theme.text)
  if running then canvas:text(self.w - 3, 1, "\226\151\143", theme.good) end -- ●
  canvas:text(2, 2, util.ellipsis(self.app.description or "", self.w - 4), theme.textDim)
end

function Tile:onTouch()
  self.onLaunch(self.app.name)
  return true
end

function Tile:onKey(ev)
  if ev.name == "enter" or ev.name == "space" then
    self.onLaunch(self.app.name)
    return true
  end
  return false
end

-- --------------------------------------------------------------- Taskbar --

local Taskbar = setmetatable({}, { __index = Widget })
Taskbar.__index = Taskbar

function Taskbar.new(desk)
  local self = setmetatable(Widget.new({ h = 1 }), Taskbar)
  self.desk = desk
  self.hits = {}
  self.clock = ""
  return self
end

function Taskbar:draw(canvas)
  canvas:fillRect(0, 0, self.w, 1, TASKBAR_BG)
  canvas.bg = TASKBAR_BG
  self.hits = {}
  local startOpen = self.desk.startMenu ~= nil
  canvas:text(0, 0, " \226\137\161 Start ", theme.text, startOpen and theme.menuActive or theme.accent) -- ≡
  self.hits[#self.hits + 1] = { x0 = 0, x1 = 8, start = true }
  local x = 10
  local right = util.len(self.clock) + 2
  for _, win in ipairs(self.desk.windows) do
    local active = self.desk.host.window == win
    local label = " " .. util.ellipsis(win.title, 18) .. " "
    local w = util.len(label)
    if x + w > self.w - right then break end
    canvas:text(x, 0, label, active and theme.text or theme.textDim, active and theme.selection or theme.button)
    self.hits[#self.hits + 1] = { x0 = x, x1 = x + w - 1, win = win }
    x = x + w + 1
  end
  canvas:text(self.w - right + 1, 0, self.clock, theme.textDim)
end

function Taskbar:setClock(text)
  if text ~= self.clock then
    self.clock = text
    self:invalidate()
  end
end

function Taskbar:onTouch(x, _, button)
  for _, hit in ipairs(self.hits) do
    if x >= hit.x0 and x <= hit.x1 then
      if hit.start then
        self.desk.toggleStart()
      elseif button == 1 then
        self.desk.windowMenu(hit.win, hit.x0)
      else
        self.desk.activate(hit.win)
      end
      return true
    end
  end
  return true
end

-- ------------------------------------------------------------------- app --

function M.start(ctx, cfg)
  local host = Host.new({ gpu = cfg.gpu, screen = cfg.screen, background = 0x101820 })
  host:mount(ctx)
  local W, H = host.w, host.h
  local viewport = { x = 0, y = 0, w = W, h = H - 1 }

  local desk = { host = host, windows = {} }
  M.desk = desk

  -- ----------------------------------------------------------- home screen --
  local rootBox = Container.new({})
  local home = rootBox:add(Container.new({ x = 0, y = 0, w = W, h = H - 1 }))
  local taskbar = rootBox:add(Taskbar.new(desk))
  taskbar.x, taskbar.y, taskbar.w = 0, H - 1, W
  desk.taskbar = taskbar

  local function appList()
    local list = {}
    for _, a in ipairs(ctx:apps()) do
      if a.name ~= M.name then list[#list + 1] = a end
    end
    return list
  end

  local tiles = {}
  local function buildHome()
    home:clear()
    home:add(widgets.Label.new({ x = 3, y = 1, w = W - 6, text = "ocui desktop", fg = theme.text }))
    home:add(widgets.Label.new({ x = 3, y = 2, w = W - 6, fg = theme.textDim,
      text = "Click an app (or Tab + Enter) to open it.  F12 start menu  Ctrl+Tab next window  Ctrl+D this screen" }))
    tiles = {}
    local cols = math.max(1, math.floor((W - 4) / (TILE_W + 2)))
    for i, app in ipairs(appList()) do
      local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
      local tile = Tile.new(app, function(name) desk.launch(name) end)
      tile.x, tile.y = 3 + col * (TILE_W + 2), 4 + row * (TILE_H + 1)
      home:add(tile)
      tiles[i] = tile
    end
    desk.cols = cols
  end

  -- arrows move between tiles
  function home:onKey(ev)
    local focused = host.focused
    local index
    for i, t in ipairs(tiles) do if t == focused then index = i end end
    if not index then return false end
    local delta = ({ left = -1, right = 1, up = -desk.cols, down = desk.cols })[ev.name or ""]
    if not delta then return false end
    local target = tiles[index + delta]
    if target then target:focus() end
    return true
  end

  -- ------------------------------------------------------------- windows --
  function desk.activate(win)
    if desk.startMenu then desk.startMenu:close() end
    home.visible = win == nil -- hidden under a window: nothing to draw
    host:setWindow(win)
    taskbar:invalidate()
    if not win then
      buildHome()
      if tiles[1] and not host.focused then tiles[1]:focus() end
    end
  end

  local function close(win)
    for i, w in ipairs(desk.windows) do
      if w == win then
        table.remove(desk.windows, i)
        if host.window == win then desk.activate(desk.windows[#desk.windows]) end
        break
      end
    end
    taskbar:invalidate()
  end

  function desk.cycle(dir)
    local n = #desk.windows
    if n == 0 then return end
    local index = 0
    for i, w in ipairs(desk.windows) do if w == host.window then index = i end end
    if index == 0 then index = dir > 0 and 0 or n + 1 end
    desk.activate(desk.windows[(index - 1 + dir) % n + 1])
  end

  local function windowOf(name)
    for _, w in ipairs(desk.windows) do
      if w.appName == name then return w end
    end
    return nil
  end

  -- The display apps open windows on (see Host.forApp).
  local display = {}
  function display.openWindow(appCtx, opts)
    local win = Host.new(opts)
    win:attach(host, viewport)
    win.title = opts.title or appCtx.name
    win.appName = appCtx.name
    table.insert(desk.windows, win)
    desk.activate(win)
    appCtx:onStop(function() close(win) end)
    return win
  end
  function display.activate(name)
    local win = windowOf(name)
    if win then desk.activate(win) end
  end
  ctx:setDisplay(display)
  ctx:onStop(function() ctx:setDisplay(nil) end)

  -- --------------------------------------------------------------- apps --
  local function stateOf(name)
    for _, a in ipairs(ctx:apps()) do
      if a.name == name then return a end
    end
    return nil
  end

  function desk.launch(name)
    local win = windowOf(name)
    if win then return desk.activate(win) end
    local app = stateOf(name)
    if app and app.state == "running" then
      Dialog.message(host, name, name .. " is running (it has no window -- e.g. it draws on the glasses).")
      return
    end
    local before = #desk.windows
    local ok, err = ctx:startApp(name)
    if not ok then
      Dialog.message(host, "Cannot start " .. name, util.ellipsis(tostring(err), 400))
    elseif #desk.windows == before then
      buildHome()
      Dialog.message(host, name, name .. " started (it has no window).")
    end
  end

  function desk.windowMenu(win, x)
    menu.open(host, x, H - 5, {
      { label = "Show", action = function() desk.activate(win) end },
      { label = "Restart", action = function() ctx:restartApp(win.appName) end },
      { label = "Close", action = function() ctx:stopApp(win.appName) end },
    }, { minWidth = 16 })
  end

  local function runShell()
    host:suspend(function()
      io.write("OpenOS shell -- type `exit` to return to the desktop\n")
      require("shell").execute("sh")
    end)
  end

  local function exitDesktop()
    if #desk.windows == 0 then return ctx:quitPool() end
    Dialog.confirm(host, "Exit desktop", "Close " .. #desk.windows .. " window(s) and exit?", function(yes)
      if yes then ctx:quitPool() end
    end, "Exit", "Cancel")
  end

  function desk.toggleStart()
    if desk.startMenu then
      desk.startMenu:close()
      return
    end
    local items = {}
    for _, a in ipairs(appList()) do
      local running = a.state == "running"
      items[#items + 1] = {
        label = a.name .. (running and "  \226\151\143" or ""),
        key = windowOf(a.name) and "open" or nil,
        action = function() desk.launch(a.name) end,
      }
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Home screen", key = "^D", action = function() desk.activate(nil) end }
    items[#items + 1] = { label = "OpenOS shell", action = runShell }
    items[#items + 1] = { label = "Exit desktop", action = exitDesktop }
    local popup
    popup = menu.open(host, 0, H - 1 - (#items + 2), items, {
      minWidth = 28,
      shadow = false, -- it sits right on the taskbar
      onClose = function()
        if desk.startMenu == popup then desk.startMenu = nil end
        taskbar:invalidate()
      end,
    })
    desk.startMenu = popup
    taskbar:invalidate()
  end

  host:bind("f12", desk.toggleStart)
  host:bind("ctrl+tab", function() desk.cycle(1) end)
  host:bind("ctrl+shift+tab", function() desk.cycle(-1) end)
  host:bind("ctrl+d", function() desk.activate(nil) end) -- (F11 is Minecraft's fullscreen key)

  host:setView({ root = rootBox })
  buildHome()
  if tiles[1] then tiles[1]:focus() end

  -- the clock, and app states on the home screen
  local lastStates = ""
  ctx:every(5, function()
    local free, total = computer.freeMemory(), computer.totalMemory()
    local ok, time = pcall(os.date, "%H:%M")
    taskbar:setClock(string.format("mem %d%%  %s", math.floor((total - free) / math.max(total, 1) * 100 + 0.5),
      ok and time or ""))
    if not host.window then
      local parts = {}
      for _, a in ipairs(appList()) do parts[#parts + 1] = a.name .. a.state end
      local states = table.concat(parts, ",")
      if states ~= lastStates then
        lastStates = states
        local focusedName = host.focused and host.focused.app and host.focused.app.name
        buildHome()
        for _, t in ipairs(tiles) do
          if t.app.name == focusedName then t:focus() end
        end
      end
    end
  end)
end

return M
