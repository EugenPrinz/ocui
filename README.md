# ocui — GTNH OpenComputers UI toolkit

A small, reusable UI primitives library for OpenComputers screens in GTNH
(GPU + Container/Widget/Canvas, not a text terminal), plus a demo app that
shows live AE2 autocraft progress on a crafting-CPU dashboard.

## Layout

```
ocui/                 the reusable library — copy this whole folder as-is
  util.lua              UTF-8-safe string length/truncate (no Lua 5.3 dep)
  canvas.lua            GPU wrapper: origin + clip-rect, draw primitives
  widget.lua            Widget base class, Container (generic layout)
  widgets.lua           Label, ProgressBar, Panel, VStack
  theme.lua             default color palette
  ae2.lua               AE2 <-> OC data source (crafting CPU polling)
  app.lua               double-buffered draw/event loop

apps/
  ae2_dashboard.lua    the demo app — one panel per crafting CPU

mock/                  local dev/test harness, never deployed in-game
  component_factory.lua  fake component/gpu/me_interface
  run_mock.lua            multi-scenario smoke test (plain `lua` interpreter)
```

## Deploying in-game

1. Requirements: a Tier 2+ GPU bound to a screen (Tier 2 minimum for
   24-bit color; the demo was tuned against a Tier 3 screen), and an
   **Adapter** placed adjacent to an **ME Interface** or **ME Controller**
   so the computer can see `component.me_interface` / `.me_controller`.
2. Copy the `ocui/` folder to `/lib/ocui` on the OC computer (via a floppy,
   `pastebin`/an HTTP card + `wget`, or any file transfer you already use).
3. Copy `apps/ae2_dashboard.lua` anywhere, e.g. `/home/ae2_dashboard.lua`.
4. Run it: `ae2_dashboard` (or `ae2_dashboard.lua` depending on your
   working directory). Press `q` to quit; it also exits cleanly on
   Ctrl+Alt+C.

The screen refreshes every 2 seconds (`tickInterval` in
`apps/ae2_dashboard.lua`) and re-reads `getCpus()` each time.

## Testing without Minecraft

`mock/run_mock.lua` fakes just enough of `component`/`event`/the AE2
component surface to run the real `ocui` + `ae2_dashboard.lua` code under
a plain Lua interpreter and print the rendered screen as ASCII art. It
caught three real bugs during development (byte-vs-codepoint truncation
of box-drawing borders, a container not stretching children to fill
width, and clip regions not propagating through nested containers), so
it's worth running again after any change to `ocui/`:

```bash
lua mock/run_mock.lua
```

It is **not** a faithful OpenComputers emulator — no power/tick budget
simulation, no real font, no real AE2 semantics beyond the shapes
documented in `ocui/ae2.lua`. It only proves the Lua runs and the layout
math is self-consistent; final verification still has to happen in-game.

## Writing your own screen with ocui

```lua
local component = require("component")
local App        = require("ocui.app")
local widgets     = require("ocui.widgets")
local theme        = require("ocui.theme")

local root = widgets.VStack.new({ gap = 1 })
root:add(widgets.Panel.new({
  h = 3, title = "Hello", borderColor = theme.border, bg = theme.panel,
}):add(widgets.Label.new({ text = "Hi there", fg = theme.text })))

App.new({ root = root, tickInterval = 1 }):start()
```

Primitives available: `Label` (text, alignment), `ProgressBar` (0..1 value
+ centered label), `Panel` (bordered box with title, auto-sized children),
`VStack` (vertical stack, full-width children). A widget's `w` can be left
nil to auto-fill its container's width; `h` must be given explicitly.
Add new primitives by extending `ocui.widget`'s `Widget` (leaf) or
`Container` (has children) — see `ocui/widgets.lua` for the pattern.

## Known limitations

- AE2/OC expose no real "% done" for a crafting job (see
  [AE2#5220](https://github.com/AppliedEnergistics/Applied-Energistics-2/issues/5220)).
  `ocui/ae2.lua` approximates progress as
  `done / (done + pending + active)` for items matching the job's final
  output — a reasonable proxy, not an authoritative percentage for deep
  recipe trees.
- `entry.cpu.finalOutput()` has broken across AE2 versions before (see
  [GTNH#23718](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/23718));
  it's called through `pcall` so a regression degrades to "no active job"
  instead of crashing the dashboard.
- `Canvas:text` doesn't support left-edge clipping (drawing text that
  starts before the visible region) — not needed by any of the bundled
  widgets, but worth knowing if you build a horizontally-scrolling one.
- No scrolling: if you have more crafting CPUs than fit on screen, later
  panels are clipped off rather than becoming scrollable.
