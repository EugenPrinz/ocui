-- desktop -- full-screen app windows + taskbar on this screen.
-- Every installed ocui app can be opened from the home screen or the
-- start menu (F12). Exit from the start menu.
-- To start it at boot instead of the shell: `ocsession on`.

local ok, err = require("ocui.session").runDesktop()
if not ok then
  io.stderr:write("desktop failed: " .. tostring(err) .. "\n")
end
