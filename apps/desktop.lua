-- desktop -- full-screen app windows + taskbar on this screen.
-- Every installed ocui app can be opened from the home screen or the
-- start menu (F12). Exit from the start menu.

local Pool = require("ocui.pool")
local desktop = require("ocui.apps.desktop")

local pool = Pool.new({})
pool:register(desktop)
pool:registerAvailable()
pool:run({ "desktop" })

for _, app in ipairs(pool:status()) do
  if app.state == "failed" and app.name == "desktop" then
    io.stderr:write("desktop failed: " .. tostring(app.error) .. "\n")
  end
end
