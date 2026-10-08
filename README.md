# ocui — GTNH OpenComputers UI toolkit

UI toolkit for OpenComputers in GT New Horizons, with two front ends:

- **screen** (GPU + monitor): widgets with keyboard focus, lists, text
  fields, dialogs, menus and split panes, repainted only where they
  changed;
- **HUD** (AR glasses via a Glasses Terminal): retained-mode Rect / Text /
  Bar / Graph.

Targets **GTNH 2.8.4** (GT5-Unofficial 5.09.51.482, OpenComputers
1.11.20-GTNH, AE2 rv3-beta-695-GTNH, OCGlasses 1.6.1-GTNH); every
component API used was checked against those exact source tags.

## Apps

| App (`ocpool` name) | Shows | Needs |
|---|---|---|
| `hud` | On AR glasses: LSC charge %, stored/capacity, avg IN/OUT, a scrolling net-flow graph (green = charging, red = draining), time to full/empty, maintenance & wireless flags; below it the busy AE2 crafting CPUs with progress bar, % and ETA | Glasses Terminal + linked AR Glasses; Adapter on the LSC controller; Adapter on an ME Interface/Controller |
| `dashboard` | On a screen: one panel per crafting CPU with output, progress %, ETA | T2+ GPU and screen; Adapter on an ME Interface/Controller |
| `taskmgr` | On a screen: task manager — every app with state, uptime, restarts, CPU time and errors (start/stop/restart with F5/F6/F7 or Enter), the shared services and who uses them, system info (memory and energy with a memory chart, components), the pool log. Controls the background pool if one runs, else a local pool with every installed app | T3 GPU and screen, a keyboard on the screen |
| `uidemo` | On a screen: a tour of the screen widgets — menu bar, list with columns, text fields, dialogs, split panes, status bar, running an OpenOS program and coming back. Keyboard and touch; Ctrl+Q quits | T3 GPU and screen, a keyboard on the screen |
| `hudctl` | On a screen: control panel for the HUD (a profile per glasses terminal; show/hide panels and parts, anchor + offset per panel, width, text size, to-scale preview) and an **Energy** tab: live LSC numbers, net-flow and charge charts over 2 min / 1 h / 24 h, avg/min/max, EU in/out | T2+ GPU and screen (80x25+); an LSC for the Energy tab |

The HUD and the dashboard get their data from shared **services**
(`energy` for the LSC, `crafting` for AE2). Each service polls once, for
every app that uses it, and keeps the energy history across app restarts.
A hidden HUD panel doesn't use its service: switching off the autocraft
panel stops AE2 polling, unless the dashboard still needs it.

**Each crafting CPU needs a Crafting Monitor** for AE2 to report *what*
it is crafting (`finalOutput()`); without one the CPU still shows progress
and ETA, just labelled "no monitor".

## Running several apps: `ocpool`

```
ocpool hud dashboard        run both in the foreground (q / Ctrl+C quits)
ocpool -b hud               run in the background; the shell stays usable
ocpool                      run `autostart` from /etc/ocui/ocpool.cfg (default: hud)
ocpool list                 available apps
ocpool status               background pool: state, uptime, restarts, errors
ocpool stop|start|restart hud
ocpool quit                 stop the background pool
ocpool log                  /tmp/ocpool.log (crash tracebacks end up here)
```

`hud`, `ae2_dashboard` and `hudctl` work as single-command shortcuts.
`hudctl` runs the HUD alongside itself, or, if a background pool is
already running (`ocpool -b hud`), controls the HUD in that pool.

How it behaves:

- **One cooperative loop, not threads.** OpenComputers runs one Lua state
  per computer and every non-direct component call (each AE2 call)
  freezes the whole computer until the next server tick, so real
  parallelism isn't possible. Apps run as coroutine tasks that hand over
  control at `ctx.yield()`/`ctx.sleep()`. The AE2 poll yields between
  CPUs, so a long poll doesn't hold up the LSC samples.
- **Crash isolation.** An error in one app tears down only that app (its
  cleanup restores the screen/HUD) and restarts it after `restartDelay`
  seconds, at most `maxRestarts` times. The count resets once the app has
  run for 5 minutes. Other apps keep running.
- **Exclusive resources.** Apps claim their GPU, screen and glasses
  terminals; a second app wanting the same one fails with "in use by …".
  Two screen apps need two GPU + screen pairs (set `gpu`/`screen` in
  their config); touches go to the app on the touched screen.
- **Background mode** (`-b`) runs the pool in a detached OpenOS thread.
  There 'q' and Ctrl+C belong to the shell and are ignored, and an app
  may not take the shell's screen. Put `ocpool -b` in `/home/.shrc` to
  start your apps on boot.

### Task manager

`taskmgr` shows what the pool is doing and lets you start and stop apps:

- **Apps** (F1): every installed app with its state (`*` = restart
  pending), uptime, restarts, CPU time it used in the last second (ms per
  second), live tasks/handlers and its description or last error; below,
  details and the app's recent log lines. F5 start, F6 (or Del) stop, F7
  restart, Enter or a right click for a menu.
- **Services** (F2): the shared data services, their CPU time and which
  apps use them.
- **System** (F3): memory and energy of the computer, a 2-minute memory
  chart, every component with its address.
- **Log** (F4): `/tmp/ocpool.log`, following new lines while the last one
  is selected.

Run as `taskmgr` while a background pool runs (`ocpool -b ...`), it
controls that pool. Without one, it runs a local pool holding every
installed app; on Ctrl+Q, if you started apps there, it offers to keep
them running in the background (it hands them to `ocpool -b`). It can also
live in the background pool itself on a second screen: `ocpool -b hud
taskmgr` with `gpu`/`screen` set in `/etc/ocui/taskmgr.cfg`.

In a foreground pool, `q` quits only while no keyboard app (taskmgr,
uidemo) is running; those quit with Ctrl+Q.

## Configuration

Each app reads `/etc/ocui/<app>.cfg` (a Lua table), created with the
defaults on first run. Edit it, then `ocpool restart <app>`. Your file is
merged over the defaults, so new options from an update appear without
losing your edits. A broken file stops only that app, and the error names
the file.

- `hud.cfg` (easiest via `hudctl`) holds **one profile per Glasses
  Terminal**. With OCGlasses, everyone bound to a terminal sees the same
  widgets, so give each player their own terminal (all on the same
  computer) and they each get their own HUD.
  - `default` is the template. A terminal the HUD hasn't seen before gets
    a copy of it, labelled with the players bound to it.
  - `profiles["<terminal address>"]` holds each terminal's own settings.
    In `hudctl`, pick the profile at the top. `Reset to template` copies
    the template into it, `Apply to all terminals` copies it into every
    profile, and `Forget` drops the profile of a terminal that is no
    longer connected. All three keep each terminal's label, on/off switch
    and screen size.

  Each profile has:
  - `label`, `enabled` (false = nothing on that terminal);
  - `width`, `alpha`, `textScale`;
  - `screen` — the player's GUI size; learned automatically when glasses
    linked to that terminal are put on;
  - `lsc.*` — `enabled`, `anchor` (top-left / top-right / bottom-left /
    bottom-right), `x`/`y` offset from that corner, `showFlow`,
    `showGraph`, `graphWindow` (2m / 1h / 24h), `graphBars`,
    `graphHeight`;
  - `crafting.*` — `enabled`, `stack` (sit right under the LSC panel),
    `anchor`, `x`, `y`, `maxRows`;
  - `colors.*`.
- `energy.cfg`: `address` (which gt_machine is the LSC), `interval`,
  `wirelessMax`.
- `crafting.cfg`: `interval` (each poll costs 1 + 3 x busy CPUs ticks).
- `dashboard.cfg`, `hudctl.cfg`: `gpu`, `screen`.
- `ocpool.cfg`: `autostart`, `restartDelay`, `maxRestarts`.

Positions are GUI pixels and depend on the player's window size and GUI
Scale. Anchoring a panel to the corner it lives in keeps it there when
those change. OCGlasses only reports the size when the glasses are put
on, so after resizing the window, take the glasses off and on again.

> Upgrading: a single-profile `hud.cfg` from before profiles becomes the
> `default` template, and every connected terminal starts from it. Older
> `hud.cfg` files (a single `x`/`y` for the whole HUD,
> intervals inside `lsc`/`crafting`) are converted automatically on the
> first start. The old `x`/`y` becomes the LSC panel's offset, and the
> intervals now live in `energy.cfg` and `crafting.cfg`.

## Layout

```
ocui/                 the library — copy this whole folder to /lib/ocui
  loop.lua              cooperative scheduler + event dispatch
  pool.lua              apps + shared services, crash isolation, resources
  config.lua            /etc/ocui/<app>.cfg load/merge/serialize
  storage.lua           file I/O facade (swappable for tests)
  util.lua              UTF-8 helpers: len/sub/truncate/wrap (OC's Lua 5.2)
  format.lua            SI numbers, durations, bytes (safe for huge floats)
  canvas.lua            screen: GPU wrapper with nested clipping
  host.lua              screen: owns a GPU + screen; views, overlays, focus,
                        input routing, partial repaint, suspend/resume
  keys.lua              screen: key codes and key events
  widget.lua            screen: Widget, Container (focus, invalidate)
  widgets.lua           screen: Label, ProgressBar, Panel, VStack, Button,
                        Toggle, Cycle, Stepper, Tabs, Chart (half-block),
                        StatusBar (+ re-exports the ones below)
  list.lua              screen: List (columns, scrolling, type-ahead)
  textinput.lua         screen: TextInput (single line, UTF-8)
  layout.lua            screen: HBox, VBox, Split
  dialog.lua            screen: message / confirm / prompt dialogs
  menu.lua              screen: pop-up menus, MenuBar
  theme.lua             screen: default palette
  app.lua               screen: a host + one widget tree, in one call
  hud.lua               glasses: Surface, Rect, Text, Bar, Graph, Group, anchors
  ae2.lua               data: crafting CPU tracker (progress + ETA)
  lsc.lua               data: Lapotronic Supercapacitor reader
  services/
    energy.lua          LSC sampler + 2m/1h/24h history
    crafting.lua        AE2 crafting CPU poller
  apps/
    hud.lua             app: glasses HUD (LSC + autocraft)
    hudctl.lua          app: HUD control panel + energy charts
    dashboard.lua       app: screen dashboard of crafting CPUs
    taskmgr.lua         app: task manager
    uidemo.lua          app: widget demo

apps/                  programs — copy to /home or /usr/bin
  ocpool.lua            the launcher/controller
  hud.lua               shortcut: hud alone
  hudctl.lua            shortcut: control panel (+ hud, or the background one)
  ae2_dashboard.lua     shortcut: dashboard alone
  taskmgr.lua           task manager (background pool, or a local one)
  uidemo.lua            shortcut: widget demo

install.lua            in-game installer/updater (Internet Card)

mock/                  local test harness — never deployed in-game
  component_factory.lua  fake OpenOS (component/computer/event, gpu with
                         call-budget accounting, screens + keyboards,
                         me_interface, LSC, glasses, threads, shell, clock),
                         key/typing signal helpers
  memfs.lua              in-memory `filesystem`
  run_mock.lua           unit tests + app/pool/CLI scenarios with assertions
```

## Installing / updating in-game

With an **Internet Card** in the computer:

```
wget -f https://raw.githubusercontent.com/EugenPrinz/ocui/main/install.lua /tmp/install.lua
/tmp/install.lua
```

The same two commands update an existing install. `install.lua`:

- downloads every file first and writes nothing if any download fails,
  so a dropped connection can't leave a mix of old and new versions;
- puts the library into `/lib/ocui` and the programs into `/usr/bin`, so
  `ocpool`, `hud`, `hudctl` and `ae2_dashboard` run from any directory;
- clears the cached `ocui` modules from memory;
- never touches your settings in `/etc/ocui`.

`/tmp/install.lua <branch|tag|commit>` installs a specific version.
GitHub's raw files can lag a push by a few minutes. If a background pool
is running, restart it afterwards with `ocpool quit && ocpool -b`.

Without an Internet Card, copy `ocui/` to `/lib/ocui` and `apps/*.lua` to
`/usr/bin` by any other means (floppy, …).

Then:

1. For the HUD: connect a **Glasses Terminal** to the computer, link the
   **AR Glasses** to it (shift-right-click the terminal) and wear them.
2. Run `hudctl` (panel + HUD), or `ocpool hud dashboard`, or
   `ocpool -b hud` to keep the shell free.

## How the numbers are obtained

**Crafting progress.** AE2 exposes no "% done", and a job's final output
goes straight into the network as it is produced, so it can't be counted
in the CPU. `ocui/ae2.lua` tracks each job's *remaining work* —
`sum(pendingItems) + sum(activeItems)`, which only shrinks while a job runs
— against the largest value seen for that job:
`progress = 1 - remaining/baseline`, `ETA = remaining / observed rate`.
A job that was already running when the program started is measured from
the moment it was first seen. Progress is in item units, not time, so it
can move unevenly through a recipe tree. Each AE2 call costs one server
tick, so a poll costs `1 + 3 × busy CPUs` ticks — keep `interval` in
`/etc/ocui/crafting.cfg` at 2–3 s or more with many CPUs.

**LSC.** `getStoredEUString()`/`getEUCapacityString()` give exact values
(no Long clamping). Average IN/OUT, maintenance and wireless mode come from
`getSensorInformation()`. In 2.8.4 those lines are translated on the
server — in single-player, into *your* client language — so they're read
by line position (10/11 avg IN/OUT, 17 maintenance, 18 wireless mode, 23
wireless EU) and by Minecraft color code (§a ok/enabled, §c
problem/disabled), never by English text, and numbers are parsed with any
locale's thousands separators (`,`, NBSP, …). If a future pack shifts the
lines, adjust `ocui/lsc.lua`'s `DEFAULT_SENSOR_LINES`. Without sensor data
the net flow falls back to the change in stored EU, computed with exact
decimal-string subtraction (floats can't resolve per-second deltas on
20+ digit totals). In wireless mode the bar shows wireless EU against
`lsc.wirelessMax`.

**HUD cost.** Widget setters on the glasses are executed directly (no
server-tick sync), but each one sends a packet to every linked player, so
`ocui/hud.lua` caches every property and only sends real changes. A
60-bar graph sampled every second is ~100–200 small packets/s while the
values move.

## Testing without Minecraft

```bash
lua mock/run_mock.lua
```

Needs Lua 5.3+ on the PC (the fake GPU uses the `utf8` library; the
deployed `ocui/` code doesn't). `-v` prints every rendered screen frame and
an ASCII raster of the HUD. The suite has unit tests (sensor-line parsing in
English and Russian, exact big-number diff, formatting, the crafting
tracker on a virtual clock) and scenario runs of both apps: progress
moving over time, missing Crafting Monitor, empty/erroring ME network, tiny
screen with Cyrillic text, GPU without VRAM, input events not causing extra
AE2 polls, wireless + maintenance flags, sensor-less LSC, missing
components, cleanup of every glasses terminal on exit. Pool and launcher
tests cover:

- cooperative interleaving and periodic tasks that never overlap;
- crash isolation with limited restarts, and a failed start not blocking
  other apps;
- resource conflicts, and two screens with touch routing;
- background mode: 'q'/Ctrl+C ignored, the shell's screen refused,
  remote status/stop/start/quit;
- config merge and sandboxing;
- `ocpool list`/`status`, foreground and background runs.

Screen widget tests drive `uidemo` and small widget trees with scripted
keys, touches, drags, wheel and clipboard signals: focus and Tab order,
typing (Cyrillic included) and editing, dialogs and menus by keyboard,
double click, scrollbar and divider drags, keys from a keyboard on
another screen being ignored, a GPU without VRAM, and running an OpenOS
program from the UI and coming back. The fake GPU charges OC's T3 call
budget costs (set/fill/colors on the screen, bitblt by source size), so
the tests also check that moving a list selection or typing costs a few
hundredths of a tick's budget instead of a full-screen copy.
OpenOS threads are faked: the "detached" pool runs synchronously until a
scripted `quit`.

It is **not** an OpenComputers emulator: only the GPU's call budget is
modelled, there are no real font metrics, no real AE2/GT behavior beyond
the documented shapes. It proves
the Lua runs and the layout and math are consistent; the final check is
in-game.

## Writing your own app

An app is a module in `ocui/apps/<name>.lua`. `ocpool list` finds it
automatically.

```lua
local hud = require("ocui.hud")

return {
  name = "clock",
  description = "uptime on the glasses",
  defaults = { x = 10, y = 200 },          -- becomes /etc/ocui/clock.cfg
  start = function(ctx, cfg)
    local component = require("component")
    local glasses = hud.findGlasses(component)
    for _, g in ipairs(glasses) do assert(ctx:claim("glasses:" .. g.address)) end
    local surface = hud.newSurface(glasses)
    local text = surface:text({ x = cfg.x, y = cfg.y })
    ctx:onStop(function() surface:clear() end)  -- runs on stop, crash, quit
    ctx:every(1, function()
      text:setText(string.format("%.0f s", require("computer").uptime()))
    end)
  end,
}
```

The `ctx` API (full list in `ocui/pool.lua`):

| Call | What it does |
|---|---|
| `ctx:every(s, fn)` / `ctx:spawn(fn)` | add a task |
| `ctx:on(signal, fn)` | add a signal handler |
| `ctx:onStop(fn)` | add a cleanup |
| `ctx:claim(resource)` | take exclusive use of a GPU, screen or glasses terminal |
| `ctx.sleep(s)` / `ctx.yield()` | hand over control inside a task |
| `ctx:log(...)` | write to the pool log |
| `ctx:stop()` | stop this app |

Never call `os.sleep`/`event.pull` inside an app: they block every other
app.

Screen apps build a widget tree and mount it:

```lua
local App     = require("ocui.app")
local widgets = require("ocui.widgets")

-- inside start(ctx, cfg):
local root = widgets.VStack.new({ gap = 1 })
local panel = root:add(widgets.Panel.new({ h = 3, title = "Hello", bg = 0x16161D }))
panel:add(widgets.Label.new({ text = "Hi there" }))
App.new({ root = root, tickInterval = 1, onTick = update, gpu = cfg.gpu or nil }):mount(ctx)
```

Screen widgets: a widget's `w` may be left nil to fill its container;
`h` is explicit. Extend `ocui.widget`'s `Widget` (leaf) or `Container`
(has children); see `ocui/widgets.lua`. HUD elements are created once and
mutated; call setters freely — unchanged values aren't re-sent.

### Interactive screens (keyboard, dialogs, menus)

For apps driven by the keyboard, use `ocui.host` directly (or
`App.new({ ..., partial = true })`) and mark the module `keyboard = true`
so a typed `q` doesn't quit the pool:

```lua
local Host    = require("ocui.host")
local widgets = require("ocui.widgets")
local Dialog  = require("ocui.dialog")

return {
  name = "notes", keyboard = true,
  start = function(ctx)
    local host = Host.new({ background = 0x0F0F14 })
    host:mount(ctx)                        -- claims the GPU + screen
    local root = widgets.VBox.new({})
    local list = root:add(widgets.List.new({ flex = 1, items = { "a", "b" },
      onActivate = function(i, item) Dialog.message(host, "Item", item) end }))
    local status = root:add(widgets.StatusBar.new({ hints = { { key = "^Q", label = "Quit" } } }))
    host:setView({ root = root, bindings = { ["ctrl+q"] = function() ctx:stop() end } })
  end,
}
```

- **Repainting.** Widgets call `self:invalidate()` when what they show
  changes (the built-in ones do in their setters: `setText`, `setValue`,
  `setItems`, `select`...). The host repaints only those rectangles, once
  per loop round, into an off-screen buffer, and copies them to the screen
  through a buffer of their own size — OC charges a copy by the size of
  its source, so a changed row costs ~0.04 of a T3 tick's budget where a
  full-screen copy costs 2.0. Assigning a widget's fields directly doesn't
  repaint; call `invalidate()` after, or `host:damageAll()`.
- **Keys.** A key goes to the focused widget's `onKey(ev)`, then up its
  parents, then the view's `onKey` and `bindings` (`"ctrl+s"`, `"f2"`,
  `"shift+tab"`...); an unhandled Tab moves focus. `ev.text` is the typed
  character (UTF-8), `ev.name` the key (`"enter"`, `"left"`, `"a"`), plus
  `ev.ctrl/shift/alt`. Only keyboards attached to the host's screen count.
- **Focus.** `focusable` widgets take focus when touched or tabbed to;
  buttons and toggles show a highlight only while the keyboard is in use.
- **Overlays.** `Dialog.message/confirm/prompt/open` and `Menu.open` /
  `MenuBar` are modal overlays; Escape closes them, a touch outside closes
  a menu. `host:push(view)` / `host:pop()` stack full-screen views.
- **Running a program.** `host:suspend(fn)` gives the screen back to
  OpenOS while `fn` runs (e.g. `shell.execute("edit", nil, path)`) and
  restores the UI afterwards — for a foreground app on the shell's screen.

## Known limitations

- One app's long non-yielding work (or a slow component call) still
  delays the others: the pool is cooperative, not preemptive.
- HUD positions are in GUI pixels. The screen size is only reported when
  the glasses are put on, not on window resize. All players linked to a
  terminal see the same layout, placed for the last reported screen size.
- Energy history is in memory: it survives app restarts but not a pool
  restart or reboot. A `hudctl` reaching a HUD in a background pool keeps
  its own history, starting when `hudctl` started.
- HUD text width is estimated (Minecraft's font is proportional), so long
  item names are truncated a little conservatively.
- Screen dashboard has no scrolling: CPUs beyond the screen height are
  clipped. The HUD shows `crafting.maxRows` busy CPUs and a `+N` count.
- `host:suspend` (running an OpenOS program from a UI) only makes sense
  for an app in the foreground on the shell's own screen; the loop and
  every other app in the pool wait while the program runs.
- Screen apps are made for T3 (160x50, 256 colors); smaller screens work
  but layouts are not tuned for them.
