-- ocui.host
-- Owns one GPU + screen (+ the keyboards attached to it) and shows widget
-- trees on it: a stack of views (the top one fills the screen) and, above
-- them, overlays (dialogs, menus). Routes touch/drag/scroll/keys/paste to
-- the right widget, tracks keyboard focus, and repaints only what changed.
--
--   local host = Host.new({ gpu = addr, screen = addr, background = 0x0F0F14 })
--   host:mount(ctx)                         -- inside a pool app's start()
--   host:setView({ root = rootWidget,       -- or just setView(rootWidget)
--                  bindings = { ["ctrl+q"] = function() ctx:stop() end },
--                  onKey = function(ev) ... end })
--
-- Repainting: widgets call self:invalidate() when what they show changes;
-- the host collects those rectangles and, once per loop round (an idle
-- hook, so a burst of changes costs one frame), redraws the tree clipped
-- to each of them into an off-screen VRAM buffer -- drawing there costs no
-- call budget -- and copies just those rectangles to the screen.
--
-- Copy cost: OC charges a VRAM->screen bitblt by the size of the *source*
-- buffer (a dirty full-screen T3 buffer costs 2.0, more than the 1.5 a T3
-- computer gets per tick), so a small change is copied through a scratch
-- buffer the size of the change: one 160-cell row costs ~0.04. Without
-- free VRAM the host draws straight onto the screen, clipped the same way.
--
-- Keys: key_down from a keyboard attached to this screen goes to the
-- focused widget's onKey(ev) (see ocui.keys), then bubbles up its parents,
-- then the view's onKey and key bindings; an unhandled Tab moves focus.

local component = require("component")

local Canvas = require("ocui.canvas")
local keys = require("ocui.keys")

local Host = {}
Host.__index = Host

-- A frame whose changed area exceeds this share of the screen is copied
-- with one full-screen bitblt instead of piece by piece.
Host.FULL_COPY_SHARE = 0.6
-- Call budget of a dirty full-screen VRAM->screen bitblt on a T3 GPU
-- (bitbltCost 0.5 * 2^tier); used for the cost estimate in host.stats.
Host.BITBLT_COST = 2.0

local clock = os and os.clock or function() return 0 end
local MAX_RECTS = 6
local MERGE_SLACK = 40 -- cells of overdraw accepted to merge two rects

-- opts.gpu / opts.screen: component addresses (or a gpu proxy for opts.gpu);
--   default: the primary GPU and whatever screen it is bound to.
-- opts.background: color behind everything.
-- opts.redrawOnInput: repaint the whole screen after every touch/key a
--   widget consumed (for trees whose widgets don't invalidate themselves).
function Host.new(opts)
  opts = opts or {}
  return setmetatable({
    opts = opts,
    background = opts.background or 0x000000,
    views = {},
    overlays = {},
    damageList = {},
    mods = {},
    bindings = {},
    focusVisible = false,
    buffer = 0,
    frames = 0,
    -- per-frame numbers for apps that want to show them: cpu = seconds the
    -- last repaint took, cost = its estimated call budget, totalCost
    stats = { cpu = 0, cost = 0, totalCost = 0 },
  }, Host)
end

-- ------------------------------------------------------------- the screen --

local function resolveGpu(spec)
  if type(spec) == "table" then return spec end
  if type(spec) == "string" then
    local proxy = component.proxy(spec)
    assert(proxy, "GPU not found: " .. spec)
    return proxy
  end
  local gpu = component.gpu
  assert(gpu, "no GPU found")
  return gpu
end

-- Keyboards attached to the screen, as a set; nil if that can't be told
-- (then keys from any keyboard are accepted).
local function findKeyboards(screen)
  local proxy = component.proxy(screen)
  if not (proxy and proxy.getKeyboards) then return nil end
  local ok, list = pcall(proxy.getKeyboards)
  if not ok or type(list) ~= "table" then return nil end
  local set = {}
  for _, address in ipairs(list) do set[address] = true end
  return set
end

local function allocate(gpu, w, h)
  if not gpu.allocateBuffer then return nil end
  local ok, buf = pcall(gpu.allocateBuffer, w, h)
  if ok and type(buf) == "number" and buf > 0 then return buf end
  return nil
end

-- Takes over the screen: full resolution, a back buffer.
function Host:acquireScreen()
  local gpu = self.gpu
  gpu.setResolution(gpu.maxResolution())
  self.w, self.h = gpu.getResolution()
  self.buffer = allocate(gpu, self.w, self.h) or 0
  for _, view in ipairs(self.views) do self:layoutView(view) end
  self:damageAll()
end

-- Gives the screen back: frees the buffer, clears, restores the resolution.
function Host:releaseScreen()
  local gpu = self.gpu
  if self.buffer ~= 0 then
    gpu.setActiveBuffer(0)
    gpu.freeBuffer(self.buffer)
    self.buffer = 0
  end
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, self.w, self.h, " ")
  if self.prevW and self.prevH then gpu.setResolution(self.prevW, self.prevH) end
end

-- Claims the GPU and screen for this pool app, takes the screen over and
-- registers the input handlers and the repaint hook; everything is undone
-- when the app stops.
function Host:mount(ctx)
  local gpu = resolveGpu(self.opts.gpu)
  if self.opts.screen then gpu.bind(self.opts.screen) end
  local screen = gpu.getScreen and gpu.getScreen() or nil
  assert(screen, "the GPU is not bound to a screen")
  assert(ctx:claim("gpu:" .. tostring(gpu.address)))
  assert(ctx:claim("screen:" .. screen))

  self.ctx = ctx
  self.gpu = gpu
  self.screenAddress = screen
  self.keyboards = findKeyboards(screen)
  self.prevW, self.prevH = gpu.getResolution()
  self:acquireScreen()

  ctx:onStop(function()
    self.mounted = false
    self:releaseScreen()
  end)
  self.mounted = true

  local function onScreen(address) return address == self.screenAddress and not self.suspended end
  ctx:on("touch", function(_, address, x, y, button)
    if onScreen(address) then self:pointerDown(math.floor(x) - 1, math.floor(y) - 1, button) end
  end)
  ctx:on("drag", function(_, address, x, y, button)
    if onScreen(address) then self:pointerMove("onDrag", math.floor(x) - 1, math.floor(y) - 1, button) end
  end)
  ctx:on("drop", function(_, address, x, y, button)
    if onScreen(address) then self:pointerMove("onDrop", math.floor(x) - 1, math.floor(y) - 1, button) end
  end)
  ctx:on("scroll", function(_, address, x, y, dir)
    if onScreen(address) then self:scroll(math.floor(x) - 1, math.floor(y) - 1, dir) end
  end)
  ctx:on("key_down", function(_, kb, char, code)
    if not self.suspended and self:ownsKeyboard(kb) then self:keyDown(char, code) end
  end)
  ctx:on("key_up", function(_, kb, _, code)
    if self:ownsKeyboard(kb) then self:keyUp(code) end
  end)
  ctx:on("clipboard", function(_, kb, text)
    if not self.suspended and self:ownsKeyboard(kb) then self:paste(text) end
  end)
  local function keyboardsChanged(_, _, kind)
    if kind == "keyboard" then self.keyboards = findKeyboards(self.screenAddress) end
  end
  ctx:on("component_added", keyboardsChanged)
  ctx:on("component_removed", keyboardsChanged)
  ctx:idle(function() if self.framePending then self:flush() end end)
end

function Host:ownsKeyboard(address)
  return self.keyboards == nil or self.keyboards[address] == true
end

-- ------------------------------------------------------------------ views --

local function asView(view)
  if view.draw then return { root = view } end
  return view
end

function Host:layoutView(view)
  local root = view.root
  root.host = self
  root.parent = nil
  root.x, root.y = 0, 0
  root.w, root.h = self.w, self.h
end

function Host:currentView()
  return self.views[#self.views]
end

local function show(self, view)
  if self.w then self:layoutView(view) else view.root.host = self end
  if view.onShow then view.onShow(view) end
  self:focus(view.focused or self:firstFocusable(view.root))
  self:damageAll()
end

local function hide(self, view)
  view.focused = self.focused
  if view.onHide then view.onHide(view) end
end

-- Replaces every view with `view` (a widget, or { root, onKey, bindings,
-- onShow, onHide }).
function Host:setView(view)
  view = asView(view)
  local top = self:currentView()
  if top then hide(self, top) end
  self.views = { view }
  show(self, view)
  return view
end

-- Shows `view` on top of the current one until pop().
function Host:push(view)
  view = asView(view)
  local top = self:currentView()
  if top then hide(self, top) end
  table.insert(self.views, view)
  show(self, view)
  return view
end

function Host:pop()
  if #self.views <= 1 then return nil end
  local top = table.remove(self.views)
  hide(self, top)
  top.root.host = nil
  show(self, self:currentView())
  return top
end

-- Global key binding, e.g. host:bind("ctrl+q", fn); fn(ev).
function Host:bind(combo, fn)
  self.bindings[combo] = fn
end

-- --------------------------------------------------------------- overlays --

-- Shows `widget` above the views at its own (screen) x/y until
-- closeOverlay(widget). opts:
--   modal      input outside it is swallowed (default true)
--   onOutside  fn(x, y, button): a touch outside it (e.g. close a menu)
--   onKey      fn(ev): keys nothing inside it consumed
--   focus      widget to focus (default: its first focusable widget)
--   shadow     draw a drop shadow (default true)
function Host:openOverlay(widget, opts)
  opts = opts or {}
  local entry = {
    widget = widget,
    modal = opts.modal ~= false,
    onOutside = opts.onOutside,
    onKey = opts.onKey,
    shadow = opts.shadow ~= false,
    prevFocus = self.focused,
  }
  widget.host = self
  widget.parent = nil
  table.insert(self.overlays, entry)
  self:damageOverlay(entry)
  self:focus(opts.focus or self:firstFocusable(widget))
  return entry
end

function Host:closeOverlay(widget)
  for i, entry in ipairs(self.overlays) do
    if entry.widget == widget then
      table.remove(self.overlays, i)
      self:damageOverlay(entry)
      widget.host = nil
      if i > #self.overlays then -- it was the top one: focus goes back
        local prev = entry.prevFocus
        if prev and prev:getHost() ~= self then prev = nil end
        self:focus(prev)
      end
      return true
    end
  end
  return false
end

function Host:topOverlay()
  return self.overlays[#self.overlays]
end

function Host:damageOverlay(entry)
  local w = entry.widget
  local extra = entry.shadow and 1 or 0
  self:damage(w.x, w.y, w.w + extra, w.h + extra)
end

-- ------------------------------------------------------------------ focus --

-- The tree keyboard focus and Tab are confined to: the top modal overlay,
-- or the current view.
function Host:scopeRoot()
  local top = self:topOverlay()
  if top and top.modal then return top.widget end
  if top and self.focused and self.focused:getHost() == self then
    local r = self.focused
    while r.parent do r = r.parent end
    if r == top.widget then return r end
  end
  local view = self:currentView()
  return view and view.root
end

local function collectFocusable(widget, out)
  if not widget.visible then return end
  if widget.focusable and not widget.disabled then out[#out + 1] = widget end
  if widget.children then
    for _, child in ipairs(widget.children) do collectFocusable(child, out) end
  end
end

function Host:focusables(root)
  local list = {}
  if root then collectFocusable(root, list) end
  return list
end

function Host:firstFocusable(root)
  return self:focusables(root)[1]
end

function Host:focus(widget)
  if widget == self.focused then return end
  local old = self.focused
  self.focused = widget
  if old then old:onBlur() end
  if widget then widget:onFocus() end
end

-- Moves focus to the next (dir = 1) or previous (-1) focusable widget.
function Host:focusNext(dir)
  local list = self:focusables(self:scopeRoot())
  if #list == 0 then return end
  local index = 0
  for i, w in ipairs(list) do
    if w == self.focused then index = i end
  end
  if index == 0 then
    index = dir > 0 and 1 or #list
  else
    index = (index - 1 + dir) % #list + 1
  end
  self:focus(list[index])
end

-- A widget leaving the tree drops focus and pointer capture.
function Host:forget(widget)
  local function within(w)
    while w do
      if w == widget then return true end
      w = w.parent
    end
    return false
  end
  if self.focused and within(self.focused) then self.focused = nil end
  if self.capture and within(self.capture) then self.capture = nil end
end

local function setFocusVisible(self, visible)
  if self.focusVisible == visible then return end
  self.focusVisible = visible
  if self.focused then self.focused:focusChanged() end
end

-- ------------------------------------------------------------------ input --

-- The layer a pointer event at (x, y) goes to, or nil if it is swallowed.
function Host:pointerRoot(x, y, button, isTouch)
  local top = self:topOverlay()
  if top then
    local w = top.widget
    if x >= w.x and y >= w.y and x < w.x + w.w and y < w.y + w.h then return w end
    if isTouch and top.onOutside then top.onOutside(x, y, button) end
    if top.modal or top.onOutside then return nil end
  end
  local view = self:currentView()
  return view and view.root
end

function Host:pointerDown(x, y, button)
  setFocusVisible(self, false)
  self.touchTarget = nil
  self.capture = nil
  local root = self:pointerRoot(x, y, button, true)
  if not root then return end
  local focusBefore = self.focused
  local consumed = root:onTouch(x - root.x, y - root.y, button)
  local target = self.touchTarget or (consumed and root or nil)
  self.touchTarget = nil
  if target and target:getHost() == self then
    self.capture = target
    -- a handler that moved focus itself (e.g. opened a dialog) wins
    if self.focused == focusBefore and target.focusable and not target.disabled then
      self:focus(target)
    end
  end
  if consumed and self.opts.redrawOnInput then self:damageAll() end
end

-- Drag/drop go to the widget that took the touch.
function Host:pointerMove(method, x, y, button)
  local target = self.capture
  if method == "onDrop" then self.capture = nil end
  if not target or target:getHost() ~= self then return end
  local ax, ay = target:absPos()
  if target[method](target, x - ax, y - ay, button) and self.opts.redrawOnInput then
    self:damageAll()
  end
end

function Host:scroll(x, y, dir)
  local root = self:pointerRoot(x, y, nil, false)
  if not root then return end
  if root:onScroll(x - root.x, y - root.y, dir) and self.opts.redrawOnInput then
    self:damageAll()
  end
end

function Host:keyDown(char, code)
  local mod = keys.MODIFIERS[code]
  if mod then
    self.mods[mod] = true
    return
  end
  setFocusVisible(self, true)
  if self:dispatchKey(keys.event(char, code, self.mods)) and self.opts.redrawOnInput then
    self:damageAll()
  end
end

function Host:keyUp(code)
  local mod = keys.MODIFIERS[code]
  if mod then self.mods[mod] = false end
end

-- Focused widget -> its parents -> overlay/view handlers -> bindings ->
-- Tab navigation. Returns true if something consumed the key.
function Host:dispatchKey(ev)
  local w = self.focused
  if w and w:getHost() ~= self then w = nil end
  while w do
    if w:onKey(ev) then return true end
    w = w.parent
  end
  local top = self:topOverlay()
  if top then
    if not self.focused and top.widget:onKey(ev) then return true end
    if top.onKey and top.onKey(ev) then return true end
  end
  if not (top and top.modal) then
    local view = self:currentView()
    if view then
      if not self.focused and view.root:onKey(ev) then return true end
      if view.onKey and view.onKey(ev) then return true end
      local binding = view.bindings and view.bindings[ev.combo]
      if binding then binding(ev); return true end
    end
    local binding = self.bindings[ev.combo]
    if binding then binding(ev); return true end
  end
  if ev.name == "tab" then
    self:focusNext(ev.shift and -1 or 1)
    return true
  end
  return false
end

function Host:paste(text)
  local w = self.focused
  while w do
    if w:onPaste(text) then return true end
    w = w.parent
  end
  return false
end

-- --------------------------------------------------------------- painting --

local function area(r) return r.w * r.h end

local function union(a, b)
  local x0, y0 = math.min(a.x, b.x), math.min(a.y, b.y)
  local x1 = math.max(a.x + a.w, b.x + b.w)
  local y1 = math.max(a.y + a.h, b.y + b.h)
  return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Marks a screen rectangle (0-based) for repainting on the next frame.
function Host:damage(x, y, w, h)
  if not self.w or self.rendering then return end
  local x0, y0 = math.max(x, 0), math.max(y, 0)
  local x1, y1 = math.min(x + w, self.w), math.min(y + h, self.h)
  if x1 <= x0 or y1 <= y0 then return end
  local r = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
  local list = self.damageList
  local i = 1
  while i <= #list do
    local u = union(list[i], r)
    if area(u) <= area(list[i]) + area(r) + MERGE_SLACK then
      r = u
      table.remove(list, i)
      i = 1
    else
      i = i + 1
    end
  end
  table.insert(list, r)
  if #list > MAX_RECTS then
    local all = list[1]
    for j = 2, #list do all = union(all, list[j]) end
    self.damageList = { all }
  end
  self.framePending = true
end

function Host:damageAll()
  if self.w then self:damage(0, 0, self.w, self.h) end
end

-- Repaints everything now.
function Host:redraw()
  self:damageAll()
  self:flush()
end

-- Draws every layer, clipped to `rect`, into the active buffer.
function Host:render(rect)
  local canvas = Canvas.new(self.gpu, 0, 0, self.w, self.h, rect.x, rect.y, rect.w, rect.h, {})
  canvas:fillRect(rect.x, rect.y, rect.w, rect.h, self.background)
  canvas.bg = self.background
  local view = self:currentView()
  if view and view.root.visible then
    local root = view.root
    root:draw(canvas:sub(root.x, root.y, root.w, root.h))
  end
  for _, entry in ipairs(self.overlays) do
    local w = entry.widget
    if entry.shadow then
      canvas:fillRect(w.x + 1, w.y + w.h, w.w, 1, 0x000000)
      canvas:fillRect(w.x + w.w, w.y + 1, 1, w.h, 0x000000)
    end
    if canvas:intersects(w.x, w.y, w.w, w.h) then
      local sub = canvas:sub(w.x, w.y, w.w, w.h)
      w:draw(sub)
    end
  end
end

-- Copies one changed rectangle from the back buffer to the screen through
-- a scratch buffer of its own size (see the cost note at the top).
function Host:present(r)
  local gpu = self.gpu
  local scratch = allocate(gpu, r.w, r.h)
  if scratch then
    gpu.bitblt(scratch, 1, 1, r.w, r.h, self.buffer, r.x + 1, r.y + 1)
    gpu.bitblt(0, r.x + 1, r.y + 1, r.w, r.h, scratch, 1, 1)
    gpu.freeBuffer(scratch)
  else
    gpu.bitblt(0, r.x + 1, r.y + 1, r.w, r.h, self.buffer, r.x + 1, r.y + 1)
  end
end

-- Repaints the damaged areas (runs from the idle hook).
function Host:flush()
  self.framePending = false
  local rects = self.damageList
  self.damageList = {}
  if self.suspended or not self.mounted or #rects == 0 then return end
  local gpu, buf = self.gpu, self.buffer
  local t0 = clock()
  local total = 0
  for _, r in ipairs(rects) do total = total + area(r) end
  local full = total >= self.w * self.h * Host.FULL_COPY_SHARE
  if full then
    rects = { { x = 0, y = 0, w = self.w, h = self.h } }
    total = self.w * self.h
  end

  self.rendering = true
  local ok, err = pcall(function()
    if buf ~= 0 then gpu.setActiveBuffer(buf) end
    for _, r in ipairs(rects) do self:render(r) end
  end)
  self.rendering = false
  if buf ~= 0 then
    gpu.setActiveBuffer(0)
    if ok then
      if full then
        gpu.bitblt(0, 1, 1, self.w, self.h, buf, 1, 1)
      else
        for _, r in ipairs(rects) do self:present(r) end
      end
    end
  end
  self.frames = self.frames + 1
  local stats = self.stats
  stats.cpu = clock() - t0
  stats.cost = buf ~= 0 and Host.BITBLT_COST * total / (self.w * self.h) or 0
  stats.totalCost = stats.totalCost + stats.cost
  if not ok then error(err, 0) end
end

-- --------------------------------------------------------------- suspend --

local function traceback(err)
  if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
  return tostring(err)
end

-- Hands the screen to a regular OpenOS program for the duration of
-- fn(...): the UI is cleared and the shell's resolution restored, fn runs
-- (e.g. `shell.execute("edit", nil, path)`), then the UI comes back as it
-- was. Returns xpcall-style ok, results... Meant for a host on the shell's
-- own screen (a foreground app); blocks the loop while fn runs.
function Host:suspend(fn, ...)
  assert(self.mounted, "host is not mounted")
  self.suspended = true
  self:releaseScreen()
  local okTerm, term = pcall(require, "term")
  if okTerm and type(term) == "table" and term.clear then pcall(term.clear) end
  local results = table.pack(xpcall(fn, traceback, ...))
  self.mods = {}
  self:acquireScreen()
  self.suspended = false
  self:redraw()
  return table.unpack(results, 1, results.n)
end

return Host
