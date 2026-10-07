-- ocui.apps.tube -- video player: shows frames streamed by
-- server/tube_server.py (YouTube via yt-dlp, local files, or `demo`).
-- Picture only, no sound.
--
-- Needs: an Internet Card with TCP enabled, a T3 GPU + T3 screen (160x50,
-- 256 colors; lower tiers work but look worse), and tube_server.py running
-- somewhere the card may reach. In single-player that is your own PC,
-- which OpenComputers blocks by default: add "allow ip:127.0.0.1" before
-- "deny private" in filteringRules in config/OpenComputers.cfg.
--
-- Why it is choppy: one socket read returns at most 2048 bytes and costs a
-- server tick, so ~40 KB/s get through; pushing a dirty 160x50 VRAM buffer
-- to the screen costs about one more tick. The player tells the server
-- its byte budget per frame and the server sends the most visible changes
-- first, so fast motion smears instead of stalling.
--
-- Touch the screen to pause/resume. Config: /etc/ocui/tube.cfg

local component = require("component")
local computer = require("computer")

local proto = require("ocui.tubeproto")

local M = {
  name = "tube",
  description = "video player (frames from server/tube_server.py)",
  defaults = {
    host = "127.0.0.1",
    port = 4123,
    source = "demo",   -- default source: demo | test | <URL> | <file in the server's media dir>
    fps = 6,           -- frames per second requested from the server
    cols = 0,          -- picture size in cells; 0 = screen maximum (up to 160x50)
    rows = 0,
    budget = 0,        -- bytes per frame; 0 = derived from fps and the 2048-byte reads
    showStats = true,  -- fps / KB/s in the top-right corner
    gpu = false,
    screen = false,
  },
}

-- One-shot overrides set by the `tube` program for a single run.
M.source, M.host, M.port = nil, nil, nil

local READ_SIZE = 2048 -- OpenComputers' default maxReadBuffer

-- Bytes per frame the link can carry: ~20 reads/s, minus about one tick
-- per frame spent pushing the picture to the screen, with some slack.
function M.autoBudget(fps)
  local readsPerSecond = math.max(20 - fps, 2)
  return math.floor(readsPerSecond * READ_SIZE * 0.85 / fps)
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

function M.start(ctx, cfg)
  local source = M.source or cfg.source
  local host = M.host or cfg.host
  local port = M.port or cfg.port
  M.source, M.host, M.port = nil, nil, nil

  assert(component.isAvailable("internet"), "tube needs an Internet Card")
  local inet = component.internet
  assert(inet.connect, "TCP is disabled for Internet Cards (internet.enableTcp in the OpenComputers config)")

  local gpu = resolveGpu(cfg.gpu or nil)
  if cfg.screen then gpu.bind(cfg.screen) end
  local screen = gpu.getScreen()
  assert(screen, "the GPU is not bound to a screen")
  assert(ctx:claim("gpu:" .. tostring(gpu.address)))
  assert(ctx:claim("screen:" .. screen))

  local maxW, maxH = gpu.maxResolution()
  local cols = cfg.cols > 0 and math.min(cfg.cols, maxW) or math.min(160, maxW)
  local rows = cfg.rows > 0 and math.min(cfg.rows, maxH) or math.min(50, maxH)
  local fps = math.max(1, math.min(cfg.fps, 20))
  local budget = cfg.budget > 0 and cfg.budget or M.autoBudget(fps)
  local palette = proto.palette()

  local prevW, prevH = gpu.getResolution()
  gpu.setResolution(cols, rows)

  local buf = 0
  if gpu.allocateBuffer then
    local ok, b = pcall(gpu.allocateBuffer, cols, rows)
    if ok and type(b) == "number" and b > 0 then buf = b end
  end

  -- default grays in the 16 palette slots (another program may have
  -- changed them), and both pages cleared to black
  local pages = { 0 }
  if buf ~= 0 then pages[2] = buf end
  for _, page in ipairs(pages) do
    gpu.setActiveBuffer(page)
    for i = 0, 15 do gpu.setPaletteColor(i, palette[i]) end
    gpu.setBackground(palette[proto.BLACK])
    gpu.fill(1, 1, cols, rows, " ")
  end
  gpu.setActiveBuffer(0)

  local state = { status = nil, statusColor = 0xFFFFFF, stats = "", paused = false }
  local sock

  -- Overlays (status bottom-left, stats top-right) are drawn straight on
  -- the screen after each frame is pushed.
  local function drawOverlays()
    gpu.setActiveBuffer(0)
    gpu.setBackground(0x000000)
    if state.status then
      gpu.setForeground(state.statusColor)
      gpu.set(1, rows, " " .. state.status .. " ")
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

  ctx:onStop(function()
    if sock then
      pcall(sock.close)
      sock = nil
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
    if address ~= screen or not sock or not state.playing then return end
    state.paused = not state.paused
    pcall(sock.write, state.paused and "PAUSE\n" or "RESUME\n")
    if state.paused then setStatus("|| paused - touch to resume") else state.status = nil end
  end)

  setStatus(string.format("connecting to %s:%d ...", host, port))

  ctx:spawn(function()
    local err
    sock, err = inet.connect(host, port)
    if not sock then
      setStatus("cannot connect: " .. tostring(err), 0xE0574C)
      return
    end
    local deadline = computer.uptime() + 10
    while true do
      local ok, connected, cerr = pcall(sock.finishConnect)
      if not ok or connected == nil then
        setStatus(string.format("cannot connect to %s:%d: %s", host, port, tostring(ok and cerr or connected)), 0xE0574C)
        return
      end
      if connected then break end
      if computer.uptime() > deadline then
        setStatus(string.format("timeout connecting to %s:%d", host, port), 0xE0574C)
        return
      end
      ctx.sleep(0.1)
    end

    sock.write(string.format("PLAY fps=%d cols=%d rows=%d budget=%d src=%s\n", fps, cols, rows, budget, source))
    setStatus("loading " .. source .. " ...")

    local dec = proto.newDecoder()
    local dirty, lastPush = false, 0
    local frames, bytes, statsAt = 0, 0, computer.uptime()

    while true do
      local ok, data, rerr = pcall(sock.read, READ_SIZE)
      if not ok or (data == nil and rerr) then
        setStatus("connection lost: " .. tostring(ok and rerr or data), 0xE0574C)
        return
      end
      if data == nil then
        if not state.ended then setStatus("server closed the connection", 0xE0574C) end
        return
      end

      if #data > 0 then
        bytes = bytes + #data
        dec:feed(data)
        while true do
          local okMsg, msg = pcall(dec.next, dec)
          if not okMsg then
            setStatus("bad stream: " .. tostring(msg), 0xE0574C)
            return
          end
          if not msg then break end
          if msg.type == "frame" then
            if buf ~= 0 then gpu.setActiveBuffer(buf) end
            proto.applyFrame(msg.data, msg.from, msg.to, gpu, palette, ctx.yield)
            frames = frames + 1
            dirty = true
            if not state.playing then
              state.playing = true
              if not state.paused then state.status = nil end
            end
          elseif msg.type == "header" then
            if msg.cols ~= cols or msg.rows ~= rows then
              setStatus(string.format("server sent %dx%d, expected %dx%d", msg.cols, msg.rows, cols, rows), 0xE0574C)
              return
            end
          elseif msg.type == "message" then
            state.title = msg.text
            ctx:log("playing %s", msg.text)
            if not state.playing then setStatus("loading " .. msg.text .. " ...") end
          elseif msg.type == "end" then
            state.ended = msg.text
          end
        end
      end

      -- push the picture at most `fps` times a second (each push of a
      -- dirty buffer costs about a tick), or whenever the link is idle
      local now = computer.uptime()
      if dirty and (now - lastPush >= 1 / fps or #data == 0 or state.ended) then
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

      if state.ended then
        state.playing = false
        setStatus("[] " .. state.ended .. " - q to quit", 0x8A8A96)
        return
      end

      if #data == 0 then ctx.sleep(0.05) else ctx.yield() end
    end
  end)
end

return M
