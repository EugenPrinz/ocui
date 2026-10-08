-- ned -- text editor with Lua syntax highlighting (nano-like keys).
--   ned [file]      F1 shows the keys; Ctrl+S saves, Ctrl+Q quits.
-- Settings: /etc/ocui/ned.cfg (tabWidth, lineNumbers).

local args = { ... }
local path = args[1]
if path then
  local ok, shell = pcall(require, "shell")
  if ok and shell and shell.resolve then path = shell.resolve(path) end
end

local ned = require("ocui.apps.ned")
ned.path = path
require("ocui.pool").runSingle(ned)
