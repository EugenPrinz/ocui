-- hudctl -- control panel for the glasses HUD + energy charts, on this
-- computer's screen.
--
-- If a background pool is running (`ocpool -b hud`), runs the panel alone
-- and controls the HUD in that pool; otherwise runs the HUD and the panel
-- together (same as `ocpool hud hudctl`). Press q to quit.

local computer = require("computer")
local event = require("event")

local Pool = require("ocui.pool")

local id = string.format("hudctl-ping-%d", math.random(1, 1000000000))
computer.pushSignal(Pool.SIGNAL, "ping", nil, id)
local background = event.pull(0.5, Pool.REPLY, id) ~= nil

-- next to a background pool, keep its log (/tmp/ocpool.log) intact
local pool = Pool.new({ logPath = background and "/tmp/hudctl.log" or nil })
if not background then
  pool:register((require("ocui.apps.hud")))
end
pool:register((require("ocui.apps.hudctl")))
pool:run(background and { "hudctl" } or { "hud", "hudctl" })

for _, app in ipairs(pool:status()) do
  if app.state == "failed" then
    io.stderr:write(string.format("hudctl: %s failed: %s\n", app.name, app.error or "?"))
  end
end
