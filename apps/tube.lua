-- tube -- plays a converted video on this screen (picture only).
--
--   tube                     `source` from /etc/ocui/tube.cfg (default: demo)
--   tube <name>              <name>.octv from your video library (the "videos"
--                            release of the GitHub repo, see the tube workflow)
--   tube <https://.../x.octv>   a converted file from any URL
--   tube live <source> [host:port]
--                            real time from a tube_server.py you run yourself
--
-- Touch the screen to pause, q to quit.

local args = { ... }
local tube = require("ocui.apps.tube")

if args[1] == "live" then
  if not args[2] then
    io.stderr:write("usage: tube live <source> [host:port]\n")
    return 1
  end
  local req = { mode = "live", source = args[2] }
  if args[3] then
    local host, port = args[3]:match("^([^:]+):?(%d*)$")
    req.host, req.port = host, tonumber(port)
  end
  tube.request = req
elseif args[1] then
  tube.request = { mode = "file", source = args[1] }
end

require("ocui.pool").runSingle(tube)
