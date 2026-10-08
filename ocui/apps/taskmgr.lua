-- taskmgr: task manager for ocui -- the apps and services of a pool
-- (state, uptime, restarts, CPU time, errors; start/stop/restart), system
-- info (memory, energy, components) and the pool log.
--
--   taskmgr           (see apps/taskmgr.lua) -- controls the background pool
--                     if one runs, else a local pool with every installed app
--   ocpool -b taskmgr -- inside the background pool, on its own screen
--                     (gpu/screen in /etc/ocui/taskmgr.cfg)
--
-- Keys: F1-F4 tabs; on Apps: Enter actions, F5 start, F6 stop, F7
-- restart; Ctrl+Q quits.

local component = require("component")
local computer = require("computer")

local Dialog = require("ocui.dialog")
local Host = require("ocui.host")
local Pool = require("ocui.pool")
local config = require("ocui.config")
local fmt = require("ocui.format")
local menu = require("ocui.menu")
local storage = require("ocui.storage")
local theme = require("ocui.theme")
local util = require("ocui.util")
local widgets = require("ocui.widgets")
local Container = require("ocui.widget").Container

local M = {
  name = "taskmgr",
  description = "task manager: apps, services, system info, log",
  keyboard = true,
  defaults = {},
  -- set by apps/taskmgr.lua: control the background pool through ocpool
  -- signals instead of the pool taskmgr runs in
  remoteMode = false,
  -- after a local run: apps the user chose to keep running in the background
  detach = nil,
}

local STATE_COLORS = {
  running = theme.good, failed = theme.bad, stopped = theme.textDim,
}

-- ---------------------------------------------------------------- backends --

-- The pool taskmgr itself runs in.
local function localBackend(ctx)
  return {
    mode = ctx.background and "background pool" or "local pool",
    poll = function(onStatus)
      onStatus({ apps = ctx:apps(), services = ctx:services() })
    end,
    command = function(cmd, name, done)
      local ok, err = ctx[cmd .. "App"](ctx, name)
      done(ok, err)
    end,
  }
end

-- A background pool, through `ocpool` signals.
local function remoteBackend(ctx)
  local pending, counter = {}, 0
  local lastReply = computer.uptime()
  ctx:on(Pool.REPLY, function(_, id, ok, text)
    local entry = pending[id]
    if entry then
      pending[id] = nil
      lastReply = computer.uptime()
      entry.cb(ok, text)
    end
  end)
  local function request(cmd, arg, cb)
    local now = computer.uptime()
    for id, entry in pairs(pending) do -- forget requests nobody answered
      if now - entry.at > 10 then pending[id] = nil end
    end
    counter = counter + 1
    local id = string.format("taskmgr-%d-%d", math.random(1, 1000000), counter)
    pending[id] = { cb = cb, at = now }
    computer.pushSignal(Pool.SIGNAL, cmd, arg, id)
  end
  return {
    mode = "background pool",
    remote = true,
    alive = function() return computer.uptime() - lastReply < 5 end,
    poll = function(onStatus)
      request("status", nil, function(ok, text)
        local status = ok and config.parse(text, "status")
        if status then onStatus(status) end
      end)
    end,
    command = function(cmd, name, done) request(cmd, name, done) end,
  }
end

-- ------------------------------------------------------------------- app --

function M.start(ctx, cfg)
  local backend = M.remoteMode and remoteBackend(ctx) or localBackend(ctx)
  local host = Host.forApp(ctx, { gpu = cfg.gpu, screen = cfg.screen, background = theme.background,
    title = "Task manager" })
  M.host = host

  local root = widgets.VBox.new({})
  local status -- StatusBar, below

  -- header: tabs + title
  local header = widgets.HBox.new({ h = 1, bg = theme.header })
  local tabs = header:add(widgets.Tabs.new({ w = 44, tabs = { "F1 Apps", "F2 Services", "F3 System", "F4 Log" },
    bg = theme.header }))
  local title = header:add(widgets.Label.new({ align = "right", fg = theme.textDim }))
  root:add(header)

  local body = Container.new({ flex = 1 })
  root:add(body)

  -- -------------------------------------------------------------- Apps --
  local appsPage = widgets.VBox.new({})
  local cpuRate = {} -- name -> ms of CPU per second, from the last two samples
  local appList = appsPage:add(widgets.List.new({
    flex = 1,
    columns = {
      { title = "App", key = "name", width = 14 },
      { title = "State", width = 9, get = function(a) return a.state .. (a.pendingRestart and "*" or "") end,
        color = function(a) return a.pendingRestart and theme.warn or STATE_COLORS[a.state] end },
      { title = "Uptime", width = 8, align = "right",
        get = function(a) return a.uptime and fmt.duration(a.uptime) or "-" end },
      { title = "Restarts", width = 8, align = "right", get = function(a) return a.restarts or 0 end },
      { title = "CPU ms/s", width = 8, align = "right", get = function(a)
        local r = cpuRate[a.name]
        return (a.state == "running" and r) and string.format("%.1f", r) or "-"
      end },
      { title = "Tasks", width = 5, align = "right", get = function(a) return a.tasks or "-" end },
      { title = "Description", flex = 1, get = function(a) return a.error or a.description or "" end,
        color = function(a) return a.error and theme.bad or theme.textDim end },
    },
    empty = "(waiting for the pool...)",
  }))
  appsPage:add(widgets.Label.new({ h = 1, text = " Details", fg = theme.textDim, bg = theme.header }))
  local details = appsPage:add(widgets.TextBox.new({ h = 9, bg = theme.panel }))

  -- ---------------------------------------------------------- Services --
  local servicesPage = widgets.VBox.new({})
  local serviceList = servicesPage:add(widgets.List.new({
    flex = 1,
    columns = {
      { title = "Service", key = "name", width = 14 },
      { title = "State", key = "state", width = 9, color = function(s) return STATE_COLORS[s.state] end },
      { title = "CPU ms/s", width = 8, align = "right", get = function(s)
        local r = cpuRate["service:" .. s.name]
        return (s.state == "running" and r) and string.format("%.1f", r) or "-"
      end },
      { title = "Used by", flex = 1, get = function(s) return table.concat(s.users or {}, ", ") end },
      { title = "Error", flex = 2, get = function(s) return s.error or "" end,
        color = function() return theme.bad end },
    },
    empty = "(no services started -- apps start them when they need data)",
  }))
  servicesPage:add(widgets.TextBox.new({ h = 2, bg = theme.panel, fg = theme.textDim,
    text = " Services are shared data sources (energy = LSC, crafting = AE2). They start with the first"
      .. " app that uses them and stop shortly after the last one." }))

  -- ------------------------------------------------------------ System --
  local systemPage = widgets.HBox.new({ gap = 1 })
  local info = systemPage:add(widgets.Panel.new({ w = 64, title = "Computer", bg = theme.panel }))
  local infoText = info:add(widgets.TextBox.new({ x = 1, y = 0, w = 60, h = 8 }))
  info:add(widgets.Label.new({ x = 1, y = 9, w = 60, text = "Memory", fg = theme.textDim }))
  local memBar = info:add(widgets.ProgressBar.new({ x = 1, y = 10, w = 60, h = 1 }))
  info:add(widgets.Label.new({ x = 1, y = 12, w = 60, text = "Energy", fg = theme.textDim }))
  local energyBar = info:add(widgets.ProgressBar.new({ x = 1, y = 13, w = 60, h = 1, fg = theme.good }))
  info:add(widgets.Label.new({ x = 1, y = 15, w = 60, text = "Memory used, last 2 minutes", fg = theme.textDim }))
  local memChart = info:add(widgets.Chart.new({ x = 1, y = 16, w = 60, h = 8, mode = "area", min = 0,
    posColor = theme.accent, labelWidth = 8, format = function(v) return fmt.bytes(v) end }))
  local compPanel = systemPage:add(widgets.Panel.new({ title = "Components", bg = theme.panel }))
  local compList = compPanel:add(widgets.List.new({
    x = 0, y = 0, h = 1,
    columns = {
      { title = "Type", key = "type", width = 18 },
      { title = "Address", key = "address", flex = 1 },
    },
  }))
  function compPanel:draw(canvas) -- the list fills the panel
    local w, h = self:innerSize()
    compList.w, compList.h = w, h
    widgets.Panel.draw(self, canvas)
  end

  -- --------------------------------------------------------------- Log --
  local logList = widgets.List.new({
    x = 0, y = 0,
    text = function(line) return line end,
    color = function(line)
      if line:find("FAILED", 1, true) or line:find("error", 1, true) then return theme.bad end
      if line:find("started", 1, true) then return theme.good end
      if line:find("stopped", 1, true) then return theme.textDim end
      return nil
    end,
    empty = "(the log is empty)",
  })
  local logPage = widgets.VBox.new({})
  logPage:add(logList).flex = 1

  local pageList = { appsPage, servicesPage, systemPage, logPage }
  for i, page in ipairs(pageList) do
    page.visible = i == 1
    body:add(page)
  end
  function body:draw(canvas)
    for _, page in ipairs(pageList) do page.x, page.y, page.w, page.h = 0, 0, self.w, self.h end
    Container.draw(self, canvas)
  end

  status = widgets.StatusBar.new({})
  root:add(status)

  -- -------------------------------------------------------------- data --
  local last = { apps = {}, services = {} }
  local lastCpu, lastAt = {}, nil
  local memHistory = {}

  local function selectedApp() return appList:selectedItem() end

  local function readLog()
    local text = storage.read(Pool.LOG_PATH) or ""
    local lines = {}
    for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    return lines
  end

  local function updateDetails()
    local a = selectedApp()
    if not a then
      details:setLines({})
      return
    end
    local lines = {
      { text = " " .. a.name .. " -- " .. (a.description or ""), color = theme.text },
      { text = " State: " .. a.state .. (a.pendingRestart and " (restart pending)" or "")
        .. (a.uptime and ("   up " .. fmt.duration(a.uptime)) or "")
        .. "   restarts: " .. tostring(a.restarts or 0), color = STATE_COLORS[a.state] },
    }
    if a.error then
      for _, l in ipairs(util.wrap("Error: " .. a.error, math.max(details.w - 2, 10))) do
        lines[#lines + 1] = { text = " " .. l, color = theme.bad }
      end
    end
    local mine = {}
    for _, line in ipairs(readLog()) do
      if line:find("] " .. a.name .. ":", 1, true) or line:find(" " .. a.name .. "$")
          or line:find(" " .. a.name .. " ", 1, true) then
        mine[#mine + 1] = line
      end
    end
    local room = details.h - #lines
    if room > 1 and #mine > 0 then
      lines[#lines + 1] = { text = " Log:", color = theme.textDim }
      for i = math.max(#mine - room + 2, 1), #mine do
        lines[#lines + 1] = { text = "   " .. mine[i], color = theme.textDim }
      end
    end
    details:setLines(lines)
  end

  local function setBar(bar, value, text)
    if text ~= bar.text then
      bar.text = text
      bar:invalidate()
    end
    bar:setValue(value)
  end

  local function updateSystem()
    local total, free = computer.totalMemory(), computer.freeMemory()
    local used = total - free
    memHistory[#memHistory + 1] = used
    while #memHistory > 120 do table.remove(memHistory, 1) end
    if not systemPage.visible then return end
    local running = 0
    for _, a in ipairs(last.apps) do if a.state == "running" then running = running + 1 end end
    infoText:setLines({
      "Address   " .. tostring(computer.address and computer.address() or "?"),
      "Uptime    " .. fmt.duration(computer.uptime()),
      "OS        " .. tostring(_OSVERSION or "?") .. "   " .. tostring(_VERSION),
      "Pool      " .. backend.mode .. (backend.remote and not backend.alive() and "  (not responding)" or ""),
      "Apps      " .. running .. " running of " .. #last.apps,
      "Services  " .. #last.services,
      "Log       " .. Pool.LOG_PATH,
    })
    setBar(memBar, used / math.max(total, 1), string.format("%s / %s (%d%%)", fmt.bytes(used),
      fmt.bytes(total), math.floor(used / math.max(total, 1) * 100 + 0.5)))
    local energy, maxEnergy = computer.energy(), computer.maxEnergy()
    setBar(energyBar, energy / math.max(maxEnergy, 1),
      string.format("%s / %s", fmt.si(energy), fmt.si(maxEnergy)))
    memChart.max = total
    memChart:setValues(memHistory)
  end

  local function updateComponents()
    local items = {}
    for address, kind in component.list() do items[#items + 1] = { type = kind, address = address } end
    table.sort(items, function(a, b)
      if a.type ~= b.type then return a.type < b.type end
      return a.address < b.address
    end)
    compList:setItems(items, "address")
  end

  local function updateLog()
    if not logPage.visible then return end
    local atEnd = logList.selected >= #logList.items
    logList:setItems(readLog())
    if atEnd then logList:select(#logList.items, true) end
  end

  local function applyStatus(st)
    local now = computer.uptime()
    last = { apps = st.apps or {}, services = st.services or {} }
    local cpuNow = {}
    for _, a in ipairs(last.apps) do cpuNow[a.name] = a.cpu end
    for _, s in ipairs(last.services) do cpuNow["service:" .. s.name] = s.cpu end
    if lastAt and now > lastAt then
      for k, v in pairs(cpuNow) do
        if lastCpu[k] then cpuRate[k] = math.max(v - lastCpu[k], 0) * 1000 / (now - lastAt) end
      end
    end
    lastCpu, lastAt = cpuNow, now
    appList:setItems(last.apps, "name")
    serviceList:setItems(last.services, "name")
    updateDetails()
  end

  local function refresh()
    backend.poll(applyStatus)
    updateSystem()
    updateLog()
    local free, total = computer.freeMemory(), computer.totalMemory()
    title:setText(string.format("ocui task manager -- %s -- mem %d%%  ", backend.mode,
      math.floor((total - free) / math.max(total, 1) * 100 + 0.5)))
  end

  -- ----------------------------------------------------------- actions --
  local function command(cmd)
    local a = selectedApp()
    if not a then return end
    if not backend.remote and a.name == M.name and cmd ~= "start" then
      status:setText("That is this task manager -- quit it with Ctrl+Q", theme.warn)
      return
    end
    backend.command(cmd, a.name, function(ok, err)
      if ok then
        status:setText(cmd .. " " .. a.name, theme.good)
      else
        status:setText(cmd .. " " .. a.name .. " failed: " .. tostring(err), theme.bad)
      end
      refresh()
    end)
  end

  local function actionsMenu(x, y)
    local a = selectedApp()
    if not a then return end
    local running = a.state == "running"
    menu.open(host, x, y, {
      { label = "Start", key = "F5", disabled = running, action = function() command("start") end },
      { label = "Stop", key = "F6", disabled = not running and not a.pendingRestart,
        action = function() command("stop") end },
      { label = "Restart", key = "F7", action = function() command("restart") end },
    }, { minWidth = 20 })
  end

  appList.onSelect = updateDetails
  appList.onActivate = function(index)
    local ax, ay = appList:absPos()
    actionsMenu(ax + 16, ay + 1 + index - appList.top)
  end
  appList.onContext = function(_, _, x, y) actionsMenu(x, y) end

  local HINTS = {
    { { key = "F1-F4", label = "Tabs" }, { key = "Enter", label = "Actions" }, { key = "F5", label = "Start" },
      { key = "F6", label = "Stop" }, { key = "F7", label = "Restart" }, { key = "^Q", label = "Quit" } },
    { { key = "F1-F4", label = "Tabs" }, { key = "^Q", label = "Quit" } },
    { { key = "F1-F4", label = "Tabs" }, { key = "^Q", label = "Quit" } },
    { { key = "F1-F4", label = "Tabs" }, { key = "End", label = "Follow" }, { key = "^Q", label = "Quit" } },
  }
  local FOCUS = { appList, serviceList, compList, logList }

  tabs.onSelect = function(index)
    for i, page in ipairs(pageList) do page:setVisible(i == index) end
    status:setHints(HINTS[index])
    status:setText("")
    if index == 3 then updateComponents(); updateSystem() end
    if index == 4 then
      updateLog()
      logList:select(#logList.items, true)
    end
    FOCUS[index]:focus()
  end
  status:setHints(HINTS[1])

  local function quit()
    if ctx:display() then return ctx:stop() end -- a window on the desktop
    if backend.remote then return ctx:quitPool() end
    if ctx.background then return ctx:stop() end
    local others = {}
    for _, a in ipairs(last.apps) do
      if a.state == "running" and a.name ~= M.name then others[#others + 1] = a.name end
    end
    if #others == 0 then return ctx:quitPool() end
    Dialog.open(host, {
      title = "Quit",
      text = table.concat(others, ", ") .. (#others == 1 and " is" or " are")
        .. " still running in this pool. Keep "
        .. (#others == 1 and "it" or "them") .. " running in the background?",
      buttons = { "Keep running", "Stop all", "Cancel" },
      onResult = function(index)
        if index == 1 then
          M.detach = others
          ctx:quitPool()
        elseif index == 2 then
          ctx:quitPool()
        end
      end,
    })
  end

  host:setView({
    root = root,
    bindings = {
      ["ctrl+q"] = quit,
      f1 = function() tabs:setActive(1) end,
      f2 = function() tabs:setActive(2) end,
      f3 = function() tabs:setActive(3) end,
      f4 = function() tabs:setActive(4) end,
      f5 = function() if tabs.active == 1 then command("start") end end,
      f6 = function() if tabs.active == 1 then command("stop") end end,
      f7 = function() if tabs.active == 1 then command("restart") end end,
      delete = function() if tabs.active == 1 then command("stop") end end,
    },
  })
  appList:focus()

  ctx:on("component_added", function() if systemPage.visible then updateComponents() end end)
  ctx:on("component_removed", function() if systemPage.visible then updateComponents() end end)
  ctx:every(1, refresh)

  M.appList, M.serviceList, M.logList, M.status, M.tabs = appList, serviceList, logList, status, tabs
end

return M
