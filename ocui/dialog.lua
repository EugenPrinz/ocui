-- ocui.dialog
-- Modal dialogs shown as host overlays, centered on the screen.
--
--   Dialog.open(host, {
--     title = "Delete", text = "Delete foo.lua?",   -- text may have \n
--     buttons = { "Delete", "Cancel" },             -- default { "OK" }
--     default = 1,       -- Enter (default 1)
--     cancel = 2,        -- Escape (default: the last button)
--     input = { value = "", placeholder = "", mask = nil },  -- optional field
--     onResult = function(index, label, value) end, -- value: the field's text
--   })
--   Dialog.message(host, title, text[, onClose])
--   Dialog.confirm(host, title, text, onResult(yes)[, yesLabel, noLabel])
--   Dialog.prompt(host, title, text, value, onResult(valueOrNil))
--
-- Tab / Left / Right move between the field and the buttons; Enter presses
-- the focused button (or the default one from the field); Escape cancels.
-- onResult runs after the dialog closed, so it may open another one.

local theme = require("ocui.theme")
local util = require("ocui.util")
local widgets = require("ocui.widgets")

local Dialog = {}

local function buttonsWidth(labels)
  local w = 0
  for _, label in ipairs(labels) do w = w + util.len(label) + 4 + 1 end
  return w - 1
end

function Dialog.open(host, opts)
  local labels = opts.buttons or { "OK" }
  local default = opts.default or 1
  local cancel = opts.cancel or #labels
  local maxW = math.max(host.w - 4, 20)

  local textW = 0
  for line in (tostring(opts.text or "") .. "\n"):gmatch("([^\n]*)\n") do
    textW = math.max(textW, util.len(line))
  end
  local width = math.max(textW, buttonsWidth(labels), opts.input and 30 or 0,
    util.len(opts.title or "") + 4, opts.width or 0, 20) + 4
  width = math.min(width, maxW)
  local lines = opts.text and util.wrap(opts.text, width - 4) or {}

  local innerH = 1 + #lines + (opts.input and 2 or 0) + 2
  local height = math.min(innerH + 2, host.h)
  local panel = widgets.Panel.new({
    x = math.floor((host.w - width) / 2), y = math.floor((host.h - height) / 2),
    w = width, h = height, title = opts.title,
    bg = theme.panel, borderColor = theme.borderFocus,
  })

  local y = 1
  for _, line in ipairs(lines) do
    panel:add(widgets.Label.new({ x = 1, y = y, w = width - 4, text = line, fg = theme.text }))
    y = y + 1
  end

  local done = false
  local field
  local function finish(index)
    if done then return end
    done = true
    host:closeOverlay(panel)
    if opts.onResult then
      opts.onResult(index, labels[index], field and field:getValue() or nil)
    end
  end

  if opts.input then
    y = y + 1
    field = panel:add(widgets.TextInput.new({
      x = 1, y = y, w = width - 4,
      value = opts.input.value, placeholder = opts.input.placeholder, mask = opts.input.mask,
      maxLength = opts.input.maxLength, filter = opts.input.filter,
      onSubmit = function() finish(default) end,
    }))
    y = y + 1
  end

  y = y + 1
  local bx = math.max(math.floor((width - 2 - buttonsWidth(labels)) / 2), 0)
  local buttons = {}
  for i, label in ipairs(labels) do
    local b = widgets.Button.new({
      x = bx, y = y, text = "  " .. label .. "  ",
      bg = i == default and theme.selectionDim or theme.button,
      onClick = function() finish(i) end,
    })
    panel:add(b)
    buttons[i] = b
    bx = bx + b.w + 1
  end

  function panel:onKey(ev)
    if ev.name == "escape" then finish(cancel); return true end
    if ev.name == "enter" then finish(default); return true end
    if ev.name == "left" or ev.name == "right" then
      host:focusNext(ev.name == "left" and -1 or 1)
      return true
    end
    return false
  end
  panel.close = function() finish(cancel) end
  panel.buttons, panel.field = buttons, field

  host:openOverlay(panel, { focus = field or buttons[default] })
  return panel
end

function Dialog.message(host, title, text, onClose)
  return Dialog.open(host, {
    title = title, text = text,
    onResult = function() if onClose then onClose() end end,
  })
end

function Dialog.confirm(host, title, text, onResult, yesLabel, noLabel)
  return Dialog.open(host, {
    title = title, text = text, buttons = { yesLabel or "Yes", noLabel or "No" },
    onResult = function(index) if onResult then onResult(index == 1) end end,
  })
end

function Dialog.prompt(host, title, text, value, onResult)
  return Dialog.open(host, {
    title = title, text = text, buttons = { "OK", "Cancel" },
    input = { value = value or "" },
    onResult = function(index, _, v) if onResult then onResult(index == 1 and v or nil) end end,
  })
end

return Dialog
