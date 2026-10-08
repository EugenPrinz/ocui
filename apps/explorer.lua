-- explorer -- single-panel file manager (same as `ocpool explorer`).
--   explorer [dir]      Enter opens, F4 edits in ned, Ctrl+Enter runs,
--   F2/F5/F6/F7/F8 rename/copy/move/mkdir/delete, Ctrl+Q quits.

local args = { ... }
local dir = args[1]
if dir then
  local ok, shell = pcall(require, "shell")
  if ok and shell and shell.resolve then dir = shell.resolve(dir) end
end

local explorer = require("ocui.apps.explorer")
explorer.path = dir
require("ocui.pool").runSingle(explorer)
