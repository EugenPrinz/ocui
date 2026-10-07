-- wireless -- runs the wireless EU network HUD alone (same as `ocpool wireless`).
-- Settings: /etc/ocui/wireless.cfg (created with defaults on first run).
-- To run it together with other apps, or in the background, use ocpool.
require("ocui.pool").runSingle((require("ocui.apps.wireless")))
