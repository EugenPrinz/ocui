-- ocui.menu
-- Pop-up menus (host overlays) and a menu bar.
--
--   Menu.open(host, x, y, {                    -- screen position, 0-based
--     { label = "Open", key = "Enter", action = function() ... end },
--     { label = "Rename", key = "F2", action = ..., disabled = false },
--     { separator = true },
--     { label = "Quit", key = "^Q", action = ... },
--   }, { onClose = fn })
--
--   local bar = MenuBar.new({ x = 0, y = 0, menus = {
--     { title = "File", items = { ... } },
--     { title = "Help", items = { ... } },
--   } })
--   view.onKey = function(ev) return bar:handleKey(ev) end -- F10 / Alt+letter
--
-- In a menu: Up/Down move, Enter/Space choose, Escape closes, a letter
-- chooses the first item starting with it; in a menu bar's menu,
-- Left/Right switch menus. A touch outside closes the menu.

local base = require("ocui.widget")
local theme = require("ocui.theme")
local util = require("ocui.util")
local Widget = base.Widget

local M = {}

-- ------------------------------------------------------------------ popup --

local Popup = setmetatable({}, { __index = Widget })
Popup.__index = Popup
M.Popup = Popup

local function usable(item)
  return item and not item.separator and not item.disabled
end

function Popup.new(items, opts)
  opts = opts or {}
  local self = setmetatable(Widget.new({}), Popup)
  self.items = items
  self.opts = opts
  self.focusable = true
  local labelW, keyW = 0, 0
  for _, item in ipairs(items) do
    if not item.separator then
      labelW = math.max(labelW, util.len(item.label or ""))
      keyW = math.max(keyW, util.len(item.key or ""))
    end
  end
  self.labelW, self.keyW = labelW, keyW
  self.w = math.max(labelW + (keyW > 0 and keyW + 2 or 0) + 4, opts.minWidth or 0)
  self.h = #items + 2
  self.selected = 0
  for i, item in ipairs(items) do
    if usable(item) then self.selected = i; break end
  end
  return self
end

function Popup:draw(canvas)
  local bg = theme.menu
  canvas:fillRect(0, 0, self.w, self.h, bg)
  canvas.bg = bg
  canvas:border(0, 0, self.w, self.h, theme.border)
  for i, item in ipairs(self.items) do
    local y = i
    if item.separator then
      canvas:text(0, y, "\226\148\156" .. string.rep("\226\148\128", self.w - 2) .. "\226\148\164",
        theme.border) -- ├───┤
    else
      local active = i == self.selected
      local rowBg = active and theme.menuActive or bg
      local fg = item.disabled and theme.disabled or theme.text
      canvas:fillRect(1, y, self.w - 2, 1, rowBg)
      canvas:text(2, y, util.ellipsis(item.label or "", self.labelW), fg, rowBg)
      if item.key then
        canvas:text(self.w - 2 - util.len(item.key), y, item.key, active and fg or theme.textDim, rowBg)
      end
    end
  end
end

function Popup:moveSelection(dir)
  local n = #self.items
  local i = self.selected
  for _ = 1, n do
    i = (i - 1 + dir) % n + 1
    if usable(self.items[i]) then break end
  end
  if usable(self.items[i]) and i ~= self.selected then
    self:invalidate(0, self.selected, self.w, 1)
    self.selected = i
    self:invalidate(0, i, self.w, 1)
  end
end

function Popup:close()
  local host = self.host
  if not host then return end
  host:closeOverlay(self)
  if self.opts.onClose then self.opts.onClose() end
end

function Popup:choose(index)
  local item = self.items[index]
  if not usable(item) then return end
  self:close()
  if item.action then item.action(item) end
end

function Popup:onTouch(_, y)
  local index = y
  if usable(self.items[index]) then self:choose(index) end
  return true
end

function Popup:onKey(ev)
  local name = ev.name
  if name == "up" then self:moveSelection(-1)
  elseif name == "down" then self:moveSelection(1)
  elseif name == "enter" or name == "space" then self:choose(self.selected)
  elseif name == "escape" then self:close()
  elseif (name == "left" or name == "right") and self.opts.onNavigate then
    self.opts.onNavigate(name == "left" and -1 or 1)
  elseif ev.text then
    local ch = ev.text:lower()
    for i, item in ipairs(self.items) do
      if usable(item) and (item.label or ""):sub(1, #ch):lower() == ch then
        self:choose(i)
        return true
      end
    end
  else
    return false
  end
  return true
end

-- Opens a menu with its top-left corner at screen (x, y), moved left/up
-- as needed to stay on screen. Returns the popup.
function M.open(host, x, y, items, opts)
  local popup = Popup.new(items, opts)
  popup.x = math.max(math.min(x, host.w - popup.w - 1), 0)
  popup.y = math.max(math.min(y, host.h - popup.h), 0)
  host:openOverlay(popup, {
    focus = popup,
    onOutside = function() popup:close() end,
  })
  return popup
end

-- ---------------------------------------------------------------- MenuBar --

local MenuBar = setmetatable({}, { __index = Widget })
MenuBar.__index = MenuBar
M.MenuBar = MenuBar

function MenuBar.new(props)
  local self = setmetatable(Widget.new(props), MenuBar)
  self.menus = props.menus or {}
  self.fg = props.fg or theme.text
  self.bg = props.bg or theme.header
  self.right = props.right or ""
  return self
end

-- x positions of the titles
function MenuBar:titleX(index)
  local x = 1
  for i = 1, index - 1 do x = x + util.len(self.menus[i].title) + 2 end
  return x
end

function MenuBar:setRight(text)
  if text == self.right then return end
  self.right = text
  self:invalidate()
end

function MenuBar:draw(canvas)
  canvas:fillRect(0, 0, self.w, self.h, self.bg)
  canvas.bg = self.bg
  for i, menu in ipairs(self.menus) do
    local open = i == self.openIndex
    local x = self:titleX(i)
    canvas:text(x - 1, 0, " " .. menu.title .. " ", open and theme.text or self.fg,
      open and theme.menuActive or self.bg)
  end
  if self.right ~= "" then
    canvas:text(self.w - util.len(self.right) - 1, 0, self.right, theme.textDim)
  end
end

function MenuBar:openMenu(index)
  local n = #self.menus
  if n == 0 then return end
  index = (index - 1) % n + 1
  if self.popup then self.popup:close() end
  local host = self:getHost()
  if not host then return end
  local ax, ay = self:absPos()
  self.openIndex = index
  self:invalidate()
  local popup
  popup = M.open(host, ax + self:titleX(index) - 1, ay + 1, self.menus[index].items, {
    onNavigate = function(dir) self:openMenu(index + dir) end,
    onClose = function()
      if self.popup == popup then
        self.popup, self.openIndex = nil, nil
        self:invalidate()
      end
    end,
  })
  self.popup = popup
end

function MenuBar:onTouch(x)
  for i, menu in ipairs(self.menus) do
    local tx = self:titleX(i)
    if x >= tx - 1 and x <= tx + util.len(menu.title) then
      self:openMenu(i)
      return true
    end
  end
  return false
end

-- For the view's onKey: F10 opens the first menu, Alt+letter the menu
-- whose title starts with that letter.
function MenuBar:handleKey(ev)
  if ev.name == "f10" then
    self:openMenu(1)
    return true
  end
  if ev.alt and not ev.ctrl and ev.name and #ev.name == 1 then
    for i, menu in ipairs(self.menus) do
      if menu.title:sub(1, 1):lower() == ev.name then
        self:openMenu(i)
        return true
      end
    end
  end
  return false
end

return M
