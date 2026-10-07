-- hud -- runs the AR-glasses HUD alone (same as `ocpool hud`).
-- Settings: /etc/ocui/hud.cfg (created with defaults on first run).
-- To run it together with other apps, or in the background, use ocpool.
require("ocui.pool").runSingle((require("ocui.apps.hud")))
