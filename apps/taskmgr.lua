-- taskmgr -- task manager for ocui apps (same UI as `ocpool taskmgr`).
--
-- If a background pool is running (`ocpool -b ...`), shows and controls
-- that pool. Otherwise runs a local pool with every installed app (all
-- stopped, start them from the list); quitting asks whether apps you
-- started should keep running in the background. Ctrl+Q quits.

local computer = require("computer")
local event = require("event")

local Pool = require("ocui.pool")

local id = string.format("taskmgr-ping-%d", math.random(1, 1000000000))
computer.pushSignal(Pool.SIGNAL, "ping", nil, id)
local background = event.pull(0.5, Pool.REPLY, id) ~= nil

local taskmgr = require("ocui.apps.taskmgr")
taskmgr.remoteMode = background
taskmgr.detach = nil

-- next to a background pool, keep its log (/tmp/ocpool.log) intact
local pool = Pool.new({ logPath = background and "/tmp/taskmgr.log" or nil })
pool:register(taskmgr)
if not background then pool:registerAvailable() end
pool:run({ "taskmgr" })
taskmgr.remoteMode = false -- the module stays loaded; don't leak the mode

for _, app in ipairs(pool:status()) do
  if app.state == "failed" and app.name == "taskmgr" then
    io.stderr:write("taskmgr failed: " .. tostring(app.error) .. "\n")
  end
end

if taskmgr.detach and #taskmgr.detach > 0 then
  require("shell").execute("ocpool", nil, "-b", table.unpack(taskmgr.detach))
end
