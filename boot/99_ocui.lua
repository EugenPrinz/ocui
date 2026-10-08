-- ocui: when switched on (`ocsession on`), OpenOS runs the ocui desktop
-- session instead of the plain shell. Installed by ocui's install.lua;
-- delete this file (or run `ocsession off`) to undo.
local ok, take = pcall(function() return require("ocui.session").bootCheck() end)
if ok and take then
  os.setenv("SHELL", require("ocui.session").PROGRAM)
end
