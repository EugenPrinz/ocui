-- tube -- plays a video streamed by server/tube_server.py on this screen.
--
--   tube                          `source` from /etc/ocui/tube.cfg (default: demo)
--   tube demo                     built-in test animation (server needs no ffmpeg)
--   tube https://youtu.be/...     anything yt-dlp can fetch
--   tube clip.mp4                 a file in the server's --media directory
--   tube <source> 192.168.1.5:4123   another server than in tube.cfg
--
-- Touch the screen to pause, q to quit.

local args = { ... }
local tube = require("ocui.apps.tube")

tube.source = args[1]
if args[2] then
  local host, port = args[2]:match("^([^:]+):?(%d*)$")
  tube.host = host
  tube.port = tonumber(port)
end

require("ocui.pool").runSingle(tube)
