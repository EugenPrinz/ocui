-- uidemo: a tour of the ocui widgets -- menu bar, list with columns, text
-- fields, dialogs, split panes, status bar, and handing the screen to an
-- OpenOS program and back. Keyboard and touch both work.
--
--   uidemo            (or `ocpool uidemo`)
--
-- Ctrl+Q quits; F10 opens the menu.

local theme = require("ocui.theme")
local widgets = require("ocui.widgets")
local Dialog = require("ocui.dialog")
local menu = require("ocui.menu")
local Host = require("ocui.host")

local M = {
  name = "uidemo",
  description = "ocui widget demo (keyboard + touch)",
  keyboard = true,
}

local KINDS = { "ore", "ingot", "plate", "circuit" }

local function sampleItems()
  return {
    { name = "Copper", qty = 1200, kind = "ingot", fav = true },
    { name = "Tin", qty = 640, kind = "ingot", fav = false },
    { name = "Iron Ore", qty = 5400, kind = "ore", fav = false },
    { name = "Steel Plate", qty = 256, kind = "plate", fav = true },
    { name = "Good Circuit", qty = 32, kind = "circuit", fav = false },
    { name = "Аметист", qty = 7, kind = "ore", fav = false },
  }
end

function M.start(ctx)
  local host = Host.new({ background = theme.background })
  host:mount(ctx)

  local items = sampleItems()
  local root = widgets.VBox.new({})

  local status = widgets.StatusBar.new({
    hints = {
      { key = "^N", label = "New" }, { key = "F2", label = "Rename" },
      { key = "Del", label = "Delete" }, { key = "Tab", label = "Next" },
      { key = "F10", label = "Menu" }, { key = "^Q", label = "Quit" },
    },
  })

  -- ------------------------------------------------------------ the list --
  local list = widgets.List.new({
    items = items,
    columns = {
      { title = "Name", key = "name", flex = 1 },
      { title = "Qty", width = 6, align = "right", get = function(it) return it.qty end },
      { title = "Kind", key = "kind", width = 8 },
      { title = "", width = 1, get = function(it) return it.fav and "*" or "" end },
    },
    color = function(it) return it.fav and theme.warn or nil end,
    empty = "(no items -- Ctrl+N adds one)",
  })

  -- -------------------------------------------------------- detail form --
  local form = widgets.Panel.new({ title = "Details", bg = theme.panel })
  form:add(widgets.Label.new({ x = 1, y = 1, text = "Name", fg = theme.textDim }))
  local nameField = form:add(widgets.TextInput.new({ x = 1, y = 2, w = 30, placeholder = "item name" }))
  form:add(widgets.Label.new({ x = 1, y = 4, text = "Quantity", fg = theme.textDim }))
  local qtyField = form:add(widgets.TextInput.new({
    x = 1, y = 5, w = 12, maxLength = 9,
    filter = function(ch) return ch:match("%d") ~= nil end,
  }))
  local kindCycle = form:add(widgets.Cycle.new({ x = 1, y = 7, w = 30, label = "Kind", options = KINDS }))
  local favToggle = form:add(widgets.Toggle.new({ x = 1, y = 8, w = 30, label = "Favourite" }))

  local function current() return items[list.selected] end

  local function loadForm()
    local it = current()
    nameField:setValue(it and it.name or "", true)
    qtyField:setValue(it and tostring(it.qty) or "", true)
    kindCycle.value = it and it.kind or KINDS[1]
    kindCycle:invalidate()
    favToggle:setValue(it and it.fav or false)
  end

  local function save()
    local it = current()
    if not it then return end
    local name = nameField:getValue()
    if name == "" then
      status:setText("A name is required", theme.bad)
      nameField:focus()
      return
    end
    it.name, it.qty = name, tonumber(qtyField:getValue()) or 0
    it.kind, it.fav = kindCycle.value, favToggle.value
    list:setItems(items, true)
    status:setText("Saved " .. name, theme.good)
  end

  nameField.onSubmit = save
  qtyField.onSubmit = save
  form:add(widgets.Button.new({ x = 1, y = 10, text = " Save ", onClick = save }))
  form:add(widgets.Button.new({ x = 9, y = 10, text = " Revert ", onClick = function()
    loadForm()
    status:setText("Reverted")
  end }))

  list.onSelect = function() loadForm() end
  list.onActivate = function() nameField:focus() end

  -- -------------------------------------------------------------- actions --
  local function newItem()
    Dialog.prompt(host, "New item", "Name of the new item:", "", function(name)
      if not name or name == "" then return end
      table.insert(items, { name = name, qty = 0, kind = KINDS[1], fav = false })
      list:setItems(items)
      list:select(#items)
      loadForm()
      status:setText("Added " .. name, theme.good)
    end)
  end

  local function rename()
    local it = current()
    if not it then return end
    Dialog.prompt(host, "Rename", "New name for " .. it.name .. ":", it.name, function(name)
      if not name or name == "" then return end
      it.name = name
      list:setItems(items, true)
      loadForm()
    end)
  end

  local function delete()
    local it = current()
    if not it then return end
    Dialog.confirm(host, "Delete", "Delete " .. it.name .. "?", function(yes)
      if not yes then return end
      table.remove(items, list.selected)
      list:setItems(items)
      loadForm()
      status:setText("Deleted " .. it.name)
    end, "Delete", "Cancel")
  end

  local function runProgram()
    Dialog.prompt(host, "Run program", "OpenOS command (the UI comes back when it ends):", "ls /",
      function(cmd)
        if not cmd or cmd == "" then return end
        local ok, err = host:suspend(function()
          local shell = require("shell")
          shell.execute(cmd)
          io.write("\nPress any key to return to uidemo...")
          require("event").pull("key_down")
        end)
        status:setText(ok and ("Back from: " .. cmd) or ("Failed: " .. tostring(err)), ok and nil or theme.bad)
      end)
  end

  local function about()
    Dialog.message(host, "About",
      "ocui widget demo.\nTab / Shift+Tab move between fields, arrows work in lists and menus, " ..
      "Enter activates, Escape closes dialogs and menus.")
  end

  -- -------------------------------------------------------------- layout --
  local bar = menu.MenuBar.new({
    right = "ocui demo",
    menus = {
      { title = "File", items = {
        { label = "New item", key = "^N", action = newItem },
        { label = "Rename", key = "F2", action = rename },
        { label = "Delete", key = "Del", action = delete },
        { separator = true },
        { label = "Run program...", action = runProgram },
        { separator = true },
        { label = "Quit", key = "^Q", action = function() ctx:stop() end },
      } },
      { title = "Help", items = {
        { label = "About", action = about },
      } },
    },
  })

  root:add(bar)
  root:add(widgets.Split.new({ flex = 1, size = 70, first = list, second = form }))
  root:add(status)

  host:setView({
    root = root,
    onKey = function(ev) return bar:handleKey(ev) end,
    bindings = {
      ["ctrl+q"] = function() ctx:stop() end,
      ["ctrl+n"] = newItem,
      ["f2"] = rename,
      ["delete"] = delete,
    },
  })
  list:focus()
  loadForm()

  M.host, M.list, M.status = host, list, status -- for tests
end

return M
