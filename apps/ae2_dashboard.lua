-- ae2_dashboard -- runs the AE2 crafting dashboard alone (same as
-- `ocpool dashboard`). Settings: /etc/ocui/dashboard.cfg (created on first run).
require("ocui.pool").runSingle((require("ocui.apps.dashboard")))
