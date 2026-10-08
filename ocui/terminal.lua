-- ocui.terminal
-- A widget that runs OpenOS programs (the shell, edit, ls...) inside it.
--
--   local term = Terminal.new({ onExit = function() ... end })
--   ...add it to a view, give it focus...
--   term:start("sh")            -- once the widget has its size
--
-- How: OpenOS keeps one terminal "window" per process (term.internal.open
-- switches tty.window to process.info().data.window, inherited by child
-- processes). start() opens such a window bound to a virtual GPU
-- (ocui.vgpu) and a virtual keyboard address, in an OpenOS thread, and
-- runs the program there. The program's output lands in the grid this
-- widget shows; keys typed while the widget has focus are pushed as
-- key_down/key_up/clipboard signals from the virtual keyboard, which is
-- the only keyboard that terminal reads. Touch/drag/drop/scroll go to the
-- virtual screen the same way.
--
-- Programs that draw on component.gpu directly (rather than through the
-- terminal) still draw on the real screen.

local base = require("ocui.widget")
local VGpu = require("ocui.vgpu")
local Widget = base.Widget

local computer = require("computer")

local Terminal = setmetatable({}, { __index = Widget })
Terminal.__index = Terminal

Terminal.WAKE = "ocui_terminal_wake" -- pushed so the UI repaints promptly

function Terminal.new(props)
  props = props or {}
  local self = setmetatable(Widget.new(props), Terminal)
  self.focusable = true
  self.onExit = props.onExit
  self.player = props.player or "player"
  return self
end

-- The virtual GPU, created at the widget's size on first use.
function Terminal:vgpu()
  local w, h = math.max(self.w or 1, 1), math.max(self.h or 1, 1)
  if not self.gpu then
    self.gpu = VGpu.new(w, h)
    self.keyboard = self.gpu.address:gsub("vgpu", "vkb")
    self.gpu.onDamage = function(x, y, dw, dh)
      self:invalidate(x, y, dw, dh)
      -- the program runs in its own thread: make sure the UI loop wakes
      -- up to repaint (any signal does)
      if not self.wakePending then
        self.wakePending = true
        computer.pushSignal(Terminal.WAKE)
      end
    end
  elseif select(1, self.gpu.size()) ~= w or select(2, self.gpu.size()) ~= h then
    self.gpu.resize(w, h)
  end
  return self.gpu
end

-- Starts `command` (default "sh") in an OpenOS thread whose terminal is
-- this widget. Returns true, or nil + reason.
function Terminal:start(command)
  local gpu = self:vgpu()
  local okThread, thread = pcall(require, "thread")
  local okTerm, term = pcall(require, "term")
  if not okThread or not okTerm or not (term.internal and term.internal.open) then
    gpu.set(1, 1, "This OpenOS has no terminal windows (term.internal.open).")
    return nil, "no terminal windows in this OpenOS"
  end
  local w, h = gpu.size()
  local keyboard = self.keyboard
  self.thread = thread.create(function()
    local process = require("process")
    local window = term.internal.open(0, 0, w, h)
    process.info().data.window = window
    term.bind(gpu, window)
    window.keyboard = keyboard -- tty.bind clears it; read only our keys
    local shell = require("shell")
    local ok, reason = pcall(shell.execute, command or "sh")
    if not ok then io.stderr:write(tostring(reason) .. "\n") end
    self.exited = true
    computer.pushSignal(Terminal.WAKE)
  end)
  return true
end

function Terminal:stop()
  local t = self.thread
  self.thread = nil
  if t and t.kill and t:status() ~= "dead" then pcall(t.kill, t) end
end

function Terminal:draw(canvas)
  self.wakePending = false
  local gpu = self:vgpu()
  local w, h = gpu.size()
  local y0 = math.max(canvas.clipY - canvas.y, 0)
  local y1 = math.min(canvas.clipY + canvas.clipH - canvas.y, h) - 1
  local x0 = math.max(canvas.clipX - canvas.x, 0)
  local x1 = math.min(canvas.clipX + canvas.clipW - canvas.x, w) - 1
  local cell = gpu.cell
  for y = y0, y1 do
    local x = x0
    while x <= x1 do
      local ch, fg, bg = cell(x + 1, y + 1)
      local run = { ch }
      local j = x + 1
      while j <= x1 do
        local c2, f2, b2 = cell(j + 1, y + 1)
        if b2 ~= bg or (f2 ~= fg and c2 ~= " ") then break end
        run[#run + 1] = c2
        j = j + 1
      end
      canvas:text(x, y, table.concat(run), fg, bg)
      x = j
    end
  end
end

-- -------------------------------------------------------------------- input --

local function push(...) computer.pushSignal(...) end

-- Raw keys (every key_down/key_up, modifiers too) while focused.
function Terminal:onRawKey(kind, char, code)
  self:vgpu()
  push(kind, self.keyboard, char, code, self.player)
  return true
end

function Terminal:onPaste(text)
  self:vgpu()
  push("clipboard", self.keyboard, text, self.player)
  return true
end

function Terminal:onTouch(x, y, button)
  push("touch", self:vgpu().screenAddress, x + 1, y + 1, button, self.player)
  return true
end

function Terminal:onDrag(x, y, button)
  push("drag", self:vgpu().screenAddress, x + 1, y + 1, button, self.player)
  return true
end

function Terminal:onDrop(x, y, button)
  push("drop", self:vgpu().screenAddress, x + 1, y + 1, button, self.player)
  return true
end

function Terminal:onScroll(x, y, dir)
  push("scroll", self:vgpu().screenAddress, x + 1, y + 1, dir, self.player)
  return true
end

return Terminal
