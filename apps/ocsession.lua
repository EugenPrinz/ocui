-- ocsession -- boot into the ocui desktop instead of the plain shell.
--
--   ocsession on       start the desktop at boot (from the next reboot)
--   ocsession off      back to the plain OpenOS shell at boot
--   ocsession status   show the setting
--   ocsession          run the session now (what OpenOS runs at boot)
--
-- Settings: /etc/ocui/session.cfg (splash seconds, background pool,
-- crash auto-restart). At boot, press any key on the splash screen for
-- the plain shell; `exit` in that shell goes to the desktop.

local args = { ... }
local cmd = args[1]

if cmd == "on" or cmd == "off" then
  local session = require("ocui.session")
  local ok, err = session.setBoot(cmd == "on")
  if not ok then
    io.stderr:write("ocsession: " .. tostring(err) .. "\n")
    return 1
  end
  if cmd == "on" then
    if not require("filesystem").exists(session.BOOT_SCRIPT) then
      io.stderr:write("ocsession: " .. session.BOOT_SCRIPT .. " is missing -- run install.lua again\n")
      return 1
    end
    print("ocsession: the desktop starts at boot from the next reboot (`ocsession off` to undo)")
  else
    print("ocsession: the plain OpenOS shell starts at boot from the next reboot")
  end
  return
end

if cmd == "status" then
  local session = require("ocui.session")
  local cfg = session.readConfig()
  print("desktop at boot: " .. (cfg.boot and "on" or "off"))
  print("this session:    " .. (os.getenv("SHELL") == session.PROGRAM and "ocui" or "plain shell"))
  return
end

if cmd then
  io.stderr:write("usage: ocsession [on|off|status]\n")
  return 1
end

-- The session itself. Whatever goes wrong, end up in a working shell.
local ok, err = pcall(function() require("ocui.session").run() end)
if not ok then
  io.stderr:write("ocui session failed: " .. tostring(err) .. "\nStarting the plain OpenOS shell.\n")
  local sh = loadfile("/bin/sh.lua")
  if sh then sh() end
end
