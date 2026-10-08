-- terminal: the OpenOS shell in a window (on the desktop: next to your
-- other windows, which keep running). `exit` closes it.
--
-- Everything typed goes to the shell -- the desktop's own keys (F12,
-- Ctrl+Tab, Ctrl+D) still work. Programs that use the terminal (sh, ls,
-- edit, cat, the ocui CLI tools...) run inside the window; a program that
-- draws on component.gpu directly draws on the real screen instead.

local Host = require("ocui.host")
local Terminal = require("ocui.terminal")

local M = {
  name = "terminal",
  description = "OpenOS shell in a window",
  keyboard = true,
  defaults = { command = "sh" },
}

function M.start(ctx, cfg)
  local host = Host.forApp(ctx, { gpu = cfg.gpu, screen = cfg.screen, background = 0x000000,
    title = "Terminal" })
  local term = Terminal.new({})
  host:setView({ root = term })
  term:focus()
  M.host, M.term = host, term

  -- the shell ended (`exit`): close the window
  ctx:on(Terminal.WAKE, function()
    if term.exited then ctx:stop() end
  end)
  ctx:onStop(function() term:stop() end)
  term:start(cfg.command)
end

return M
