-- ocui.apps.tube -- video player for converted videos (picture only).
--
-- Two ways to get frames (same stream format, see server/tube_server.py):
--
--  * file (default): a .octv file fetched over HTTP -- e.g. from the
--    "videos" release of your GitHub repo, filled by the "tube" GitHub
--    Actions workflow. Nothing to install anywhere; works on remote
--    servers as long as the Internet Card may reach GitHub (if
--    install.lua worked, it can). The player paces the frames itself.
--      tube <name>             -> <library><name>.octv
--      tube https://.../x.octv
--  * live: real time over TCP from a tube_server.py you run yourself
--    (needs TCP allowed and the server reachable from the game server).
--      tube live <source> [host:port]
--
-- Needs an Internet Card and a T3 GPU + T3 screen (160x50, 256 colors;
-- lower tiers work but look worse).
--
-- Why it is choppy: one Internet Card read returns at most 2048 bytes and
-- costs a server tick (~40 KB/s), and pushing a dirty 160x50 VRAM buffer to
-- the screen costs about one more tick. Videos are encoded with a byte
-- budget per frame that fits that link; fast motion smears instead of
-- stalling.
--
-- Touch the screen to pause/resume, q to quit. Config: /etc/ocui/tube.cfg

local component = require("component")
local computer = require("computer")

local proto = require("ocui.tubeproto")

local M = {
  name = "tube",
  description = "video player for converted videos (GitHub release or live server)",
  defaults = {
    -- file mode: where `tube <name>` looks for <name>.octv
    library = "https://github.com/EugenPrinz/ocui-videos/releases/download/videos/",
    source = "demo",   -- what `tube` with no arguments plays
    -- live mode (tube live ...)
    host = "127.0.0.1",
    port = 4123,
    fps = 6,           -- live: frames per second requested from the server
    cols = 0,          -- live: picture size in cells; 0 = screen maximum (up to 160x50)
    rows = 0,
    budget = 0,        -- live: bytes per frame; 0 = derived from fps
    -- both
    showStats = true,  -- fps / KB/s in the top-right corner
    gpu = false,
    screen = false,
  },
}

-- One-shot overrides set by the `tube` program for a single run.
M.request = nil -- { mode = "file"|"live", source = ..., host = ..., port = ... }

local READ_SIZE = 2048      -- OpenComputers' default maxReadBuffer
local MAX_BUFFERED = 32768  -- file mode: bytes read ahead of playback (RAM is scarce)

-- Bytes per frame the link can carry: ~20 reads/s, minus about one tick
-- per frame spent pushing the picture to the screen, with some slack.
-- Mirrors tube_server.auto_budget.
function M.autoBudget(fps)
  local readsPerSecond = math.max(20 - fps, 2)
  return math.floor(readsPerSecond * READ_SIZE * 0.85 / fps)
end

-- "name" -> library URL; URLs pass through.
function M.resolveUrl(source, library)
  if source:match("^https?://") then return source end
  if not source:match("%.octv$") then source = source .. ".octv" end
  return library .. source
end

local function resolveGpu(spec)
  if type(spec) == "string" then
    local proxy = component.proxy(spec)
    assert(proxy, "GPU not found: " .. spec)
    return proxy
  end
  assert(component.gpu, "no GPU found")
  return component.gpu
end

-- -------------------------------------------------------------- transports --
-- A transport opens the stream and exposes read(n) -> data | "" (nothing
-- yet) | nil, err (closed); setPaused(bool); close().

-- Waits until a request/socket handle is ready; returns true or nil, err.
local function waitReady(ctx, handle, what)
  local deadline = computer.uptime() + 15
  while true do
    local ok, ready, err = pcall(handle.finishConnect)
    if not ok or ready == nil then
      return nil, string.format("cannot reach %s: %s", what, tostring(ok and err or ready))
    end
    if ready then return true end
    if computer.uptime() > deadline then
      return nil, "timeout connecting to " .. what
    end
    ctx.sleep(0.1)
  end
end

local function openFile(ctx, inet, url)
  if not inet.request then
    return nil, "HTTP is disabled for Internet Cards (internet.enableHttp)"
  end
  local handle, err = inet.request(url)
  if not handle then return nil, "cannot request " .. url .. ": " .. tostring(err) end
  local ok, werr = waitReady(ctx, handle, url)
  if not ok then return nil, werr end
  if handle.response then
    local okResp, code, message = pcall(handle.response)
    if okResp and type(code) == "number" and code ~= 200 then
      pcall(handle.close)
      if code == 404 then
        return nil, "not found (convert it first): " .. url
      end
      return nil, string.format("HTTP %d %s: %s", code, tostring(message or ""), url)
    end
  end
  return {
    paced = true,
    read = function(n) return handle.read(n) end,
    setPaused = function() end,
    close = function() pcall(handle.close) end,
  }
end

local function openLive(ctx, inet, req, params)
  if not inet.connect then
    return nil, "TCP is disabled for Internet Cards (internet.enableTcp)"
  end
  local what = string.format("%s:%d", req.host, req.port)
  local sock, err = inet.connect(req.host, req.port)
  if not sock then return nil, "cannot connect to " .. what .. ": " .. tostring(err) end
  local ok, werr = waitReady(ctx, sock, what)
  if not ok then
    pcall(sock.close)
    return nil, werr
  end
  sock.write(string.format("PLAY fps=%d cols=%d rows=%d budget=%d src=%s\n",
    params.fps, params.cols, params.rows, params.budget, req.source))
  return {
    paced = false, -- the server sends in real time
    sock = sock,
    read = function(n) return sock.read(n) end,
    setPaused = function(p) pcall(sock.write, p and "PAUSE\n" or "RESUME\n") end,
    close = function()
      pcall(sock.write, "STOP\n")
      pcall(sock.close)
    end,
  }
end

-- ------------------------------------------------------------------- app --

function M.start(ctx, cfg)
  local req = M.request or { mode = "file", source = cfg.source }
  M.request = nil
  req.host = req.host or cfg.host
  req.port = req.port or cfg.port

  assert(component.isAvailable("internet"), "tube needs an Internet Card")
  local inet = component.internet

  local gpu = resolveGpu(cfg.gpu or nil)
  if cfg.screen then gpu.bind(cfg.screen) end
  local screen = gpu.getScreen()
  assert(screen, "the GPU is not bound to a screen")
  assert(ctx:claim("gpu:" .. tostring(gpu.address)))
  assert(ctx:claim("screen:" .. screen))

  local maxW, maxH = gpu.maxResolution()
  local palette = proto.palette()
  local prevW, prevH = gpu.getResolution()
  local cols, rows -- set from the stream header (file) or requested (live)
  local buf = 0

  -- (Re)sizes the screen and VRAM page to cols x rows, resets the 16
  -- palette grays (another program may have changed them), clears to black.
  local function setupDisplay(w, h)
    cols, rows = math.min(w, maxW), math.min(h, maxH)
    if buf ~= 0 then
      gpu.setActiveBuffer(0)
      gpu.freeBuffer(buf)
      buf = 0
    end
    gpu.setResolution(cols, rows)
    if gpu.allocateBuffer then
      local ok, b = pcall(gpu.allocateBuffer, cols, rows)
      if ok and type(b) == "number" and b > 0 then buf = b end
    end
    local pages = { 0 }
    if buf ~= 0 then pages[2] = buf end
    for _, page in ipairs(pages) do
      gpu.setActiveBuffer(page)
      for i = 0, 15 do gpu.setPaletteColor(i, palette[i]) end
      gpu.setBackground(palette[proto.BLACK])
      gpu.fill(1, 1, cols, rows, " ")
    end
    gpu.setActiveBuffer(0)
  end

  local liveParams
  if req.mode == "live" then
    local fps = math.max(1, math.min(cfg.fps, 20))
    setupDisplay(cfg.cols > 0 and cfg.cols or 160, cfg.rows > 0 and cfg.rows or 50)
    liveParams = { fps = fps, cols = cols, rows = rows,
      budget = cfg.budget > 0 and cfg.budget or M.autoBudget(fps) }
  else
    setupDisplay(math.min(160, maxW), math.min(50, maxH))
  end

  local state = { status = nil, statusColor = 0xFFFFFF, stats = "", paused = false }
  local transport

  -- Word-wraps `text` to `width` columns (long words such as URLs are
  -- split), at most `maxLines` lines.
  local function wrap(text, width, maxLines)
    local lines, line = {}, ""
    for word in text:gmatch("%S+") do
      while #word > width do
        if line ~= "" then table.insert(lines, line); line = "" end
        table.insert(lines, word:sub(1, width))
        word = word:sub(width + 1)
      end
      if line == "" then
        line = word
      elseif #line + 1 + #word <= width then
        line = line .. " " .. word
      else
        table.insert(lines, line)
        line = word
      end
    end
    if line ~= "" then table.insert(lines, line) end
    while #lines > maxLines do table.remove(lines) end
    return lines
  end

  -- Overlays (status at the bottom, wrapped; stats top-right) go straight
  -- on the screen after each frame is pushed.
  local function drawOverlays()
    gpu.setActiveBuffer(0)
    gpu.setBackground(0x000000)
    if state.status then
      gpu.setForeground(state.statusColor)
      local lines = wrap(state.status, cols - 2, math.max(math.floor(rows / 3), 1))
      for i, text in ipairs(lines) do
        gpu.set(1, rows - #lines + i, " " .. text .. " ")
      end
    end
    if cfg.showStats and state.stats ~= "" then
      gpu.setForeground(0x8A8A96)
      gpu.set(math.max(cols - #state.stats, 1), 1, state.stats)
    end
  end

  local function setStatus(text, color)
    state.status = text
    state.statusColor = color or 0xFFFFFF
    drawOverlays()
  end

  local function fail(text)
    setStatus(text, 0xE0574C)
    ctx:log("%s", text)
  end

  ctx:onStop(function()
    if transport then
      transport.close()
      transport = nil
    end
    if buf ~= 0 then
      gpu.setActiveBuffer(0)
      gpu.freeBuffer(buf)
    end
    gpu.setActiveBuffer(0)
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, cols, rows, " ")
    gpu.setResolution(prevW, prevH)
  end)

  ctx:on("touch", function(_, address)
    if address ~= screen or not transport or not state.playing then return end
    state.paused = not state.paused
    transport.setPaused(state.paused)
    if state.paused then
      state.pausedAt = computer.uptime()
      setStatus("|| paused - touch to resume")
    else
      -- file mode: shift the clock by the pause so frames don't rush
      if state.clockStart then state.clockStart = state.clockStart + (computer.uptime() - state.pausedAt) end
      state.status = nil
    end
  end)

  local label = req.mode == "live" and (req.source .. " @ " .. req.host .. ":" .. req.port)
    or M.resolveUrl(req.source, cfg.library)
  setStatus("connecting: " .. label)

  ctx:spawn(function()
    local err
    if req.mode == "live" then
      transport, err = openLive(ctx, inet, req, liveParams)
    else
      transport, err = openFile(ctx, inet, M.resolveUrl(req.source, cfg.library))
    end
    if not transport then return fail(err) end
    setStatus("loading " .. req.source .. " ...")

    local dec = proto.newDecoder()
    local fps = liveParams and liveParams.fps or 6
    local dirty, lastPush = false, 0
    local frames, bytes, statsAt = 0, 0, computer.uptime()
    local frameIndex = 0
    local pending = nil -- file mode: next decoded message not yet due
    local eof = false

    local function push(now)
      if buf ~= 0 then
        gpu.setActiveBuffer(0)
        gpu.bitblt(0, 1, 1, cols, rows, buf, 1, 1)
      end
      dirty, lastPush = false, now
      if now - statsAt >= 2 then
        state.stats = string.format(" %.1f fps %.1f KB/s ", frames / (now - statsAt), bytes / 1024 / (now - statsAt))
        frames, bytes, statsAt = 0, 0, now
      end
      drawOverlays()
    end

    -- Handles one decoded message; returns false to stop playback.
    local function handle(msg)
      if msg.type == "frame" then
        if buf ~= 0 then gpu.setActiveBuffer(buf) end
        proto.applyFrame(msg.data, msg.from, msg.to, gpu, palette, ctx.yield)
        frames = frames + 1
        frameIndex = frameIndex + 1
        dirty = true
        if not state.playing then
          state.playing = true
          if not state.paused then state.status = nil end
        end
      elseif msg.type == "header" then
        fps = math.max(msg.fps, 1)
        if req.mode == "live" then
          if msg.cols ~= cols or msg.rows ~= rows then
            fail(string.format("server sent %dx%d, expected %dx%d", msg.cols, msg.rows, cols, rows))
            return false
          end
        elseif msg.cols > maxW or msg.rows > maxH then
          fail(string.format("video is %dx%d, this screen only %dx%d", msg.cols, msg.rows, maxW, maxH))
          return false
        elseif msg.cols ~= cols or msg.rows ~= rows then
          setupDisplay(msg.cols, msg.rows)
        end
      elseif msg.type == "message" then
        state.title = msg.text
        ctx:log("playing %s", msg.text)
        if not state.playing then setStatus("loading " .. msg.text .. " ...") end
      elseif msg.type == "end" then
        state.ended = msg.text
      end
      return true
    end

    while true do
      local now = computer.uptime()

      -- read, unless (file mode) enough is buffered ahead or we're paused
      local data = ""
      local wantData = not eof and not (transport.paced and (state.paused or dec:buffered() > MAX_BUFFERED))
      if wantData then
        local ok, d, rerr = pcall(transport.read, READ_SIZE)
        if not ok or (d == nil and rerr) then
          return fail("connection lost: " .. tostring(ok and rerr or d))
        end
        if d == nil then
          eof = true
        else
          data = d
          if #d > 0 then
            bytes = bytes + #d
            dec:feed(d)
          end
        end
      end

      -- decode; file mode holds back frames that aren't due yet
      if not state.paused or not transport.paced then
        while true do
          local msg = pending
          pending = nil
          if not msg then
            local okMsg, m = pcall(dec.next, dec)
            if not okMsg then return fail("bad stream: " .. tostring(m)) end
            msg = m
          end
          if not msg then break end
          if transport.paced and msg.type == "frame" then
            state.clockStart = state.clockStart or computer.uptime()
            if state.clockStart + frameIndex / fps > computer.uptime() then
              pending = msg
              break
            end
          end
          if handle(msg) == false then return end
        end
      end

      now = computer.uptime()
      if dirty and (now - lastPush >= 1 / fps or #data == 0 or state.ended or eof) then
        push(now)
      end

      if state.ended or (eof and not pending and dec:buffered() == 0) then
        if dirty then push(computer.uptime()) end
        state.playing = false
        if state.ended then
          setStatus("[] " .. state.ended .. " - q to quit", 0x8A8A96)
        else
          fail(transport.paced and "download ended early" or "server closed the connection")
        end
        return
      end

      if pending then
        -- wait for the next frame's slot (reads continue meanwhile)
        local wait = state.clockStart + frameIndex / fps - computer.uptime()
        ctx.sleep(math.max(math.min(wait, 0.05), 0))
      elseif #data == 0 then
        ctx.sleep(0.05)
      else
        ctx.yield()
      end
    end
  end)
end

return M
