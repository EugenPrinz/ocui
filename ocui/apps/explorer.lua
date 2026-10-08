-- explorer: a single-panel file manager.
--
--   explorer [dir]    (apps/explorer.lua; or a window on the desktop)
--
-- Enter opens a directory / edits a file in ned, Ctrl+Enter runs it,
-- Backspace goes up; F2 rename, F4 edit, F5 copy, F6 move, F7 new
-- directory, F8 (or Del) delete, Ctrl+N new file, Ctrl+H hidden files,
-- Ctrl+L go to a path, Ctrl+R refresh, Ctrl+Q quit. Right click: menu.

local Dialog = require("ocui.dialog")
local Host = require("ocui.host")
local fmt = require("ocui.format")
local menu = require("ocui.menu")
local theme = require("ocui.theme")
local widgets = require("ocui.widgets")

local M = {
  name = "explorer",
  description = "file manager (single panel)",
  keyboard = true,
  defaults = { showHidden = false },
  path = nil, -- directory to open, set by apps/explorer.lua
}

local DIR_COLOR = 0x61AFEF
local LUA_COLOR = 0x98C379

-- ------------------------------------------------------------- fs helpers --

local function fsLib() return require("filesystem") end

local function join(dir, name)
  if dir:sub(-1) == "/" then return dir .. name end
  return dir .. "/" .. name
end

local function parentOf(path)
  local p = path:gsub("/+$", "")
  local parent = p:match("^(.*)/[^/]*$")
  if not parent or parent == "" then return "/" end
  return parent
end

local function nameOf(path)
  return path:gsub("/+$", ""):match("([^/]*)$")
end

-- Copies a file or a directory tree. Returns true or nil, error.
local function copyTree(fs, from, to)
  if fs.isDirectory(from) then
    local ok, err = fs.makeDirectory(to)
    if not ok and not fs.isDirectory(to) then return nil, err end
    for entry in fs.list(from) do
      local name = entry:gsub("/$", "")
      local okc, errc = copyTree(fs, join(from, name), join(to, name))
      if not okc then return nil, errc end
    end
    return true
  end
  return fs.copy(from, to)
end

local function dateText(ms)
  if not ms or ms <= 0 then return "" end
  local ok, text = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(ms / 1000))
  return ok and text or ""
end

-- ------------------------------------------------------------------- app --

function M.start(ctx, cfg)
  local fs = fsLib()
  local host = Host.forApp(ctx, { gpu = cfg.gpu, screen = cfg.screen, background = theme.background,
    title = "Files" })
  M.host = host

  local state = { dir = nil, showHidden = cfg.showHidden, remembered = {} }

  local root = widgets.VBox.new({})
  local pathBar = root:add(widgets.HBox.new({ h = 1, bg = theme.header }))
  local pathLabel = pathBar:add(widgets.Label.new({ fg = theme.text }))
  local spaceLabel = pathBar:add(widgets.Label.new({ w = 34, align = "right", fg = theme.textDim }))
  local list = root:add(widgets.List.new({
    flex = 1,
    columns = {
      { title = "Name", flex = 1, get = function(it) return it.isDir and (it.name .. "/") or it.name end,
        color = function(it)
          if it.isDir then return DIR_COLOR end
          if it.name:match("%.lua$") then return LUA_COLOR end
          return nil
        end },
      { title = "Size", width = 9, align = "right",
        get = function(it) return it.isDir and "<DIR>" or fmt.bytes(it.size or 0) end },
      { title = "Modified", width = 16, get = function(it) return dateText(it.mtime) end },
    },
    empty = "(empty directory)",
  }))
  local status = root:add(widgets.StatusBar.new({ bg = theme.background }))
  root:add(widgets.StatusBar.new({ hints = {
    { key = "Enter", label = "Open" }, { key = "^Enter", label = "Run" }, { key = "F2", label = "Rename" },
    { key = "F4", label = "Edit" }, { key = "F5", label = "Copy" }, { key = "F6", label = "Move" },
    { key = "F7", label = "Mkdir" }, { key = "F8", label = "Delete" }, { key = "^N", label = "New" },
    { key = "^H", label = "Hidden" }, { key = "^Q", label = "Quit" },
  } }))
  M.list = list

  local function message(text, color) status:setText(text or "", color) end

  -- ------------------------------------------------------------- listing --
  local function read(dir)
    local items = {}
    if dir ~= "/" then items[1] = { name = "..", isDir = true, up = true, path = parentOf(dir) } end
    local entries = {}
    local iter = fs.list(dir)
    if iter then
      for entry in iter do
        local isDir = entry:sub(-1) == "/"
        local name = isDir and entry:sub(1, -2) or entry
        if state.showHidden or name:sub(1, 1) ~= "." then
          local path = join(dir, name)
          entries[#entries + 1] = { name = name, isDir = isDir, path = path,
            size = (not isDir) and fs.size(path) or nil, mtime = fs.lastModified(path) }
        end
      end
    end
    table.sort(entries, function(a, b)
      if a.isDir ~= b.isDir then return a.isDir end
      return a.name:lower() < b.name:lower()
    end)
    for _, e in ipairs(entries) do items[#items + 1] = e end
    return items
  end

  local function updateSpace(dir)
    local text = ""
    if fs.get then
      local ok, proxy = pcall(fs.get, dir)
      if ok and proxy and proxy.spaceTotal then
        local okT, total = pcall(proxy.spaceTotal)
        local okU, used = pcall(proxy.spaceUsed)
        if okT and okU and total and used then
          text = string.format("%s free of %s%s ", fmt.bytes(total - used), fmt.bytes(total),
            (proxy.isReadOnly and proxy.isReadOnly()) and " (read-only)" or "")
        end
      end
    end
    spaceLabel:setText(text)
  end

  -- Shows `dir`, selecting the entry named `select` (or the remembered one).
  local function cd(dir, select)
    if not fs.isDirectory(dir) then
      message("Not a directory: " .. dir, theme.bad)
      return
    end
    if state.dir and list:selectedItem() then
      state.remembered[state.dir] = list:selectedItem().name
    end
    state.dir = dir
    pathLabel:setText(" " .. dir)
    local items = read(dir)
    list:setItems(items)
    select = select or state.remembered[dir]
    list:select(1, true)
    if select then
      for i, it in ipairs(items) do
        if it.name == select then list:select(i, true); break end
      end
    end
    updateSpace(dir)
  end

  local function refresh(select)
    local current = select or (list:selectedItem() and list:selectedItem().name)
    local items = read(state.dir)
    list:setItems(items)
    for i, it in ipairs(items) do
      if it.name == current then list:select(i, true); break end
    end
    updateSpace(state.dir)
  end

  local function selected()
    local it = list:selectedItem()
    if it and not it.up then return it end
    return nil
  end

  -- -------------------------------------------------------------- actions --
  local function edit(path)
    local display = ctx:display()
    if display then
      -- on the desktop: open it in the ned window
      local running = false
      for _, a in ipairs(ctx:apps()) do
        if a.name == "ned" and a.state == "running" then running = true end
      end
      if running then
        ctx:emit("ned_open", path)
        return
      end
      local okLoad, ned = pcall(require, "ocui.apps.ned")
      if okLoad then
        ned.path = path
        local ok, err = ctx:startApp("ned")
        if not ok then message("Cannot start ned: " .. tostring(err), theme.bad) end
        return
      end
    end
    local ok, err = host:suspend(function() require("shell").execute("ned", nil, path) end)
    if not ok then message("ned failed: " .. tostring(err), theme.bad) end
    refresh()
  end

  local function run(path)
    local ok, err = host:suspend(function()
      local result, reason = require("shell").execute(path)
      if not result and reason then io.stderr:write(tostring(reason) .. "\n") end
      io.write("\n[explorer] program ended -- press any key to return")
      require("event").pull("key_down")
    end)
    message(ok and ("Ran " .. path) or ("Run failed: " .. tostring(err)), not ok and theme.bad or nil)
    refresh()
  end

  local function open()
    local it = list:selectedItem()
    if not it then return end
    if it.up then return cd(it.path, nameOf(state.dir)) end
    if it.isDir then return cd(it.path) end
    edit(it.path)
  end

  -- "name" or an absolute path, relative to the current directory
  local function target(text)
    if text:sub(1, 1) == "/" then return text end
    return join(state.dir, text)
  end

  local function rename()
    local it = selected()
    if not it then return end
    Dialog.prompt(host, "Rename / move", "New name or path for " .. it.name .. ":", it.name, function(text)
      if not text or text == "" or text == it.name then return end
      local to = target(text)
      if fs.isDirectory(to) then to = join(to, it.name) end
      if fs.exists(to) then return message("Already exists: " .. to, theme.bad) end
      local ok, err = fs.rename(it.path, to)
      if not ok then return message("Rename failed: " .. tostring(err), theme.bad) end
      message("Moved to " .. to, theme.good)
      refresh(parentOf(to) == state.dir and nameOf(to) or nil)
    end)
  end

  local function copy()
    local it = selected()
    if not it then return end
    Dialog.prompt(host, "Copy", "Copy " .. it.name .. " to (name or path):", "copy_of_" .. it.name, function(text)
      if not text or text == "" then return end
      local to = target(text)
      if fs.isDirectory(to) and not it.isDir then to = join(to, it.name) end
      if fs.exists(to) then return message("Already exists: " .. to, theme.bad) end
      local ok, err = copyTree(fs, it.path, to)
      if not ok then return message("Copy failed: " .. tostring(err), theme.bad) end
      message("Copied to " .. to, theme.good)
      refresh(parentOf(to) == state.dir and nameOf(to) or nil)
    end)
  end

  local function mkdir()
    Dialog.prompt(host, "New directory", "Name:", "", function(text)
      if not text or text == "" then return end
      local path = target(text)
      local ok, err = fs.makeDirectory(path)
      if not ok then return message("Cannot create " .. path .. ": " .. tostring(err), theme.bad) end
      refresh(nameOf(path))
    end)
  end

  local function newFile()
    Dialog.prompt(host, "New file", "Name:", "", function(text)
      if not text or text == "" then return end
      local path = target(text)
      if fs.exists(path) then return message("Already exists: " .. path, theme.bad) end
      local h = fs.open(path, "w")
      if not h then return message("Cannot create " .. path, theme.bad) end
      h:close()
      refresh(nameOf(path))
      edit(path)
    end)
  end

  local function delete()
    local it = selected()
    if not it then return end
    local what = it.isDir and ("the directory " .. it.name .. " and everything in it") or it.name
    Dialog.confirm(host, "Delete", "Delete " .. what .. "?", function(yes)
      if not yes then return end
      local ok, err = fs.remove(it.path)
      if not ok then return message("Delete failed: " .. tostring(err), theme.bad) end
      message("Deleted " .. it.name)
      local index = list.selected
      refresh()
      list:select(math.min(index, #list.items), true)
    end, "Delete", "Cancel")
  end

  local function properties()
    local it = selected()
    if not it then return end
    local lines = {
      "Path:      " .. it.path,
      "Type:      " .. (it.isDir and "directory" or "file"),
    }
    if not it.isDir then lines[#lines + 1] = "Size:      " .. fmt.bytes(it.size or 0) .. " (" .. tostring(it.size) .. " bytes)" end
    lines[#lines + 1] = "Modified:  " .. dateText(it.mtime)
    Dialog.message(host, it.name, table.concat(lines, "\n"))
  end

  local function goTo()
    Dialog.prompt(host, "Go to", "Directory:", state.dir, function(text)
      if text and text ~= "" then cd(target(text)) end
    end)
  end

  local function contextMenu(x, y)
    local it = list:selectedItem()
    if not it then return end
    local isFile = not it.isDir
    menu.open(host, x, y, {
      { label = it.isDir and "Open" or "Edit", key = "Enter", action = open },
      { label = "Run", key = "^Enter", disabled = not isFile, action = function() run(it.path) end },
      { separator = true },
      { label = "Rename / move", key = "F2", disabled = it.up, action = rename },
      { label = "Copy", key = "F5", disabled = it.up, action = copy },
      { label = "Delete", key = "F8", disabled = it.up, action = delete },
      { separator = true },
      { label = "New file", key = "^N", action = newFile },
      { label = "New directory", key = "F7", action = mkdir },
      { label = "Properties", disabled = it.up, action = properties },
    }, { minWidth = 24 })
  end

  list.onActivate = function() open() end
  list.onContext = function(_, _, x, y) contextMenu(x, y) end
  list.onSelect = function(_, it)
    if it and not it.up then
      message(it.path .. (it.isDir and "/" or ("  " .. fmt.bytes(it.size or 0))))
    else
      message("")
    end
  end

  host:setView({
    root = root,
    bindings = {
      ["ctrl+enter"] = function()
        local it = selected()
        if it and not it.isDir then run(it.path) end
      end,
      back = function() if state.dir ~= "/" then cd(parentOf(state.dir), nameOf(state.dir)) end end,
      f2 = rename, f6 = rename, f4 = function() local it = selected(); if it and not it.isDir then edit(it.path) end end,
      f5 = copy, f7 = mkdir, f8 = delete, delete = delete,
      ["ctrl+n"] = newFile,
      ["ctrl+h"] = function()
        state.showHidden = not state.showHidden
        refresh()
        message(state.showHidden and "Showing hidden files" or "Hiding hidden files")
      end,
      ["ctrl+l"] = goTo,
      ["ctrl+r"] = function() refresh(); message("Refreshed") end,
      f10 = function()
        local ax, ay = list:absPos()
        contextMenu(ax + 2, ay + 1 + list.selected - list.top)
      end,
      ["ctrl+q"] = function() ctx:stop() end,
    },
  })

  local start = M.path
  M.path = nil
  if not start then
    local okShell, shell = pcall(require, "shell")
    start = okShell and shell.getWorkingDirectory and shell.getWorkingDirectory() or "/home"
  end
  if not fs.isDirectory(start) then start = "/" end
  cd(start)
  list:focus()
end

return M
