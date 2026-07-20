# space-slop

A tiny 2D top-down space game written in **Zig** with **raylib**: a rocket flies
between planets under Newtonian gravity. Built to learn Zig, and it targets both
native desktop and the browser via WebAssembly.

## Requirements

- **Zig 0.16.0** (pinned in `build.zig.zon` via `minimum_zig_version`)
- Nothing else — raylib is compiled from source as a Zig dependency, and the web
  build downloads its own Emscripten SDK automatically on first run.

## Build & run

Run all commands from the **project root** (the web build embeds `resources/`
using a path relative to the current directory).

```sh
zig build run                      # native desktop build + run
zig build                          # native build only -> zig-out/bin/space-slop
zig build test                     # run the dependency-free simulation tests
zig build -Dtarget=wasm32-emscripten   # web build -> zig-out/web/
```

### Playing the web build

Emscripten output must be served over HTTP (opening the `.html` from disk won't
work):

```sh
cd zig-out/web && python3 -m http.server 8000
# then open http://localhost:8000/space_slop.html
```

## Controls

| Key | Action |
|-----|--------|
| `W` / `↑` | thrust along heading |
| `A` `D` / `←` `→` | rotate |
| scroll / two-finger swipe | pan the view |
| `⌘` + scroll | zoom |
| `R` | reset ship |
| `T` | cycle visual theme (pixelart → scifi-60s → classic) |
| `O` | toggle sphere-of-influence rings |
| click a planet | open the detail panel; its debug section has live sliders for mass, SOI and size |

Planet tuning (mass, visual radius, SOI, gravity core) lives in **`planets.zon`**
in the project root and is loaded at startup; if the file is missing or invalid
the built-in defaults are used. The debug section's **save** button writes the
current values back to it. The web build has no persistent filesystem, so it
always uses the defaults and hides the save button.

## Debug bridge

The game can be driven from outside — for automation, agent-assisted debugging
or scripted reproduction of timing-sensitive input bugs. One line-based command
protocol (`src/debug.zig`), two transports:

```sh
zig build run -- --debug          # native: listens on 127.0.0.1:4444
zig build run -- --debug 5555     # ...or a custom port
echo state | nc localhost 4444    # one-shot query
```

On the web build the same dispatcher is exported to the page; open the browser
console and call `spaceSlopDebug('state')`.

| Command | Effect |
|---------|--------|
| `state` | dump the whole game state as one line of JSON |
| `screenshot <path>` | save a screenshot of the current frame (native only) |
| `click <x> <y> [hold]` | synthetic left click at screen px, held `hold` frames; `hold 0` = press **and** release inside one frame (the flaky-trackpad-tap case) |
| `clickw <wx> <wy> [hold]` | same, but world coordinates (e.g. `clickw 0 0` clicks Earth) |
| `key <name> [frames]` | hold a key for n frames: `w/a/d/up/left/right/thrust`, one-shots `r/t/o/f` |
| `wheel <dx> <dy>` | one frame of scroll (pans the view) |
| `zoom <dy>` | one frame of cmd+scroll (zooms) |
| `pause` / `resume` | freeze / unfreeze the simulation (rendering keeps running) |
| `step [n]` | while paused: advance exactly n fixed physics steps, one per rendered frame |

Synthetic input is injected in `src/input.zig`, upstream of the same code paths
real input takes. Held keys only tick down on frames where physics actually
steps, so `key thrust 3` + `step 3` is exactly three thrusting steps no matter
how long the sim sits paused in between — sequences real devices only produce
occasionally can be constructed deliberately.

## Layout

```
src/sim.zig    Pure-Zig simulation: Vec2 math, gravity, integrator. No raylib.
src/main.zig   Entry point and game loop.
src/render.zig Drawing layer: themes, sprites, trail, HUD.
src/input.zig  Input seam: real raylib input + debug-injected synthetic events.
src/debug.zig  Debug bridge: command dispatcher, TCP server, web export.
planets.zon    Planet tuning config (ZON), editable in-game via the detail panel.
web/shell.html Custom Emscripten HTML shell (canvas + loader).
resources/     Game assets (embedded into the web build), one folder per theme.
art/           Art source/workspace and the specs the sprites were made to.
build.zig      Native + web targets, plus the `test` step.
```

The split is deliberate: **all game logic lives in `sim.zig` with zero raylib
dependency**, so it's unit-tested with `zig build test` and could be driven by a
different renderer later (e.g. a hand-written wasm/canvas backend) without
touching the physics.

## Notes on the web target

- The web build is forced to **ReleaseSmall** even if you ask for Debug: Zig
  0.16.0's std lib fails to compile for `wasm32-emscripten` in Debug (the
  panic/IO path pulls in child-process code the target can't build). `build.zig`
  bumps it automatically so the plain command just works.
- Rendering runs on the **GPU via WebGL** (raylib's OpenGL ES → WebGL through
  Emscripten); the simulation runs on the CPU in the wasm module.
- The main loop uses Emscripten **ASYNCIFY** (raylib-zig's default), so the
  ordinary `while (!windowShouldClose())` loop works unchanged in the browser.
