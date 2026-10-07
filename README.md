# ocui — GTNH OpenComputers UI toolkit

UI toolkit for OpenComputers in GT New Horizons, with two front ends:

- **screen** (GPU + monitor): Canvas / Widget / Container, double-buffered;
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
| `tube` | On a screen: video player (picture only) for videos converted by `server/tube_server.py`, played over HTTP (e.g. from a GitHub release, converted by a GitHub Actions workflow — nothing to install) or live from your own PC | Internet Card, T3 GPU + screen |
| `hudctl` | On a screen: control panel for the HUD (show/hide panels and parts, anchor + offset per panel, width, text size, to-scale preview) and an **Energy** tab: live LSC numbers, net-flow and charge charts over 2 min / 1 h / 24 h, avg/min/max, EU in/out | T2+ GPU and screen (80x25+); an LSC for the Energy tab |

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

## Configuration

Each app reads `/etc/ocui/<app>.cfg` (a Lua table), created with the
defaults on first run. Edit it, then `ocpool restart <app>`. Your file is
merged over the defaults, so new options from an update appear without
losing your edits. A broken file stops only that app, and the error names
the file.

- `hud.cfg` (easiest via `hudctl`):
  - `width`, `alpha`, `textScale`;
  - `screen` — the player's GUI size; learned automatically when the
    glasses are put on;
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

> Upgrading: older `hud.cfg` files (a single `x`/`y` for the whole HUD,
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
  util.lua              UTF-8-safe len/truncate (works on OC's Lua 5.2)
  format.lua            SI numbers, durations, bytes (safe for huge floats)
  canvas.lua            screen: GPU wrapper with nested clipping
  widget.lua            screen: Widget, Container
  widgets.lua           screen: Label, ProgressBar, Panel, VStack, Button,
                        Toggle, Cycle, Stepper, Tabs, Chart (half-block)
  theme.lua             screen: default palette
  app.lua               screen: double-buffered UI mounted into a pool
  hud.lua               glasses: Surface, Rect, Text, Bar, Graph, Group, anchors
  tubeproto.lua         tube stream decoder + frame painter
  ae2.lua               data: crafting CPU tracker (progress + ETA)
  lsc.lua               data: Lapotronic Supercapacitor reader
  services/
    energy.lua          LSC sampler + 2m/1h/24h history
    crafting.lua        AE2 crafting CPU poller
  apps/
    hud.lua             app: glasses HUD (LSC + autocraft)
    hudctl.lua          app: HUD control panel + energy charts
    tube.lua            app: video player
    dashboard.lua       app: screen dashboard of crafting CPUs

apps/                  programs — copy to /home or /usr/bin
  ocpool.lua            the launcher/controller
  hud.lua               shortcut: hud alone
  hudctl.lua            shortcut: control panel (+ hud, or the background one)
  tube.lua              shortcut: tube <name|url> / tube live <src> [host:port]
  ae2_dashboard.lua     shortcut: dashboard alone

install.lua            in-game installer/updater (Internet Card)

server/
  tube_server.py        video converter (--convert) / live streamer for `tube`
  tube-workflow.yml     GitHub Actions template for a separate videos repo

mock/                  local test harness — never deployed in-game
  component_factory.lua  fake OpenOS (component/computer/event, gpu,
                         me_interface, LSC, glasses, threads, files, clock)
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

## Video player: `tube`

Picture only, no sound: a fun experiment, not a real video player. Expect
a chunky 160x100 picture in 256 colors at ~5–10 fps. Black-and-white
videos (Bad Apple!!) look best.

**How it works.** OpenComputers can't decode video, so
`server/tube_server.py` converts it:

1. It decodes the video with yt-dlp + ffmpeg and scales it to 160x100
   pixels.
2. It packs two pixels into each character cell: an upper half block
   `▀`, whose foreground is the top pixel and background the bottom one.
3. It maps the colors onto the exact palette of a tier 3 screen.
4. It stores only the changed cells, frame by frame.

An Internet Card reads at most 2048 bytes per server tick (~40 KB/s), so
each frame gets a byte budget that fits the link. The most visible
changes go first and the rest follow a few frames later, so fast motion
smears instead of stalling. The player applies changes in a VRAM buffer,
where drawing costs no call budget, and pushes the picture to the screen
once per frame.

There are two ways to play.

### Converted file over HTTP (default; nothing to install)

Works on remote servers: if `install.lua` worked, the card can reach
GitHub.

```
tube <name>                     # <library><name>.octv
tube https://.../video.octv     # any URL
```

`library` in `/etc/ocui/tube.cfg` defaults to the "videos" release of
[`EugenPrinz/ocui-videos`](https://github.com/EugenPrinz/ocui-videos).
That repository is kept separate from the code, so whatever lands in its
release can't affect `ocui`. Converting runs on GitHub's machines:

- `videos.txt` in that repo is the playlist, one `name fps source` per
  line;
- editing it, even right in the browser, triggers the workflow
  ([`server/tube-workflow.yml`](server/tube-workflow.yml) +
  [`server/tube_library.py`](server/tube_library.py));
- the workflow converts new or changed videos into the release and
  removes deleted ones;
- in game you then run `tube <name>`.

YouTube sometimes refuses GitHub's servers ("Sign in to confirm you're
not a bot"). A direct link to a video file always works.

### Live from your own PC (`tube live`)

Run `python server/tube_server.py` on a machine the game server can
reach; it needs yt-dlp + ffmpeg for videos. Then in game:

```
tube live <url|file|demo> [host:port]
```

The game server's OpenComputers config must allow TCP, and the address
must not be filtered. In single-player, add `"allow ip:127.0.0.1",`
before `"deny private"` in `filteringRules` of
`config/OpenComputers.cfg`.

Touch the screen to pause, `q` to quit. Downloading from YouTube goes
against YouTube's terms of service, and publishing other people's videos
in a public release can draw a takedown notice. Convert your own,
permitted or freely licensed videos, and delete them after watching.

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

`tube` is covered end to end: `tube_server.py --selftest` runs, the Lua
and Python palettes are compared, and a stream generated by the server is
played through a fake Internet Card socket. Every cell on the screen must
match what the server thinks the client shows, with and without a byte
budget. Refused connections, timeouts and pause are covered as well.

OpenOS threads are faked: the "detached" pool runs synchronously until a
scripted `quit`.

It is **not** an OpenComputers emulator: no call budgets, no real font
metrics, no real AE2/GT behavior beyond the documented shapes. It proves
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
- `Canvas:text` doesn't support left-edge clipping (not needed by the
  bundled widgets).
