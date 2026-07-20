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
| mouse wheel | zoom |
| `R` | reset ship |
| `T` | cycle visual theme (pixelart → scifi-60s → classic) |
| `O` | toggle sphere-of-influence rings |
| click a planet | open the debug panel: live sliders for mass, SOI and size |

Planet tuning (mass, visual radius, SOI, gravity core) lives in **`planets.zon`**
in the project root and is loaded at startup; if the file is missing or invalid
the built-in defaults are used. The debug panel's **save** button writes the
current values back to it. The web build has no persistent filesystem, so it
always uses the defaults and hides the save button.

## Layout

```
src/sim.zig    Pure-Zig simulation: Vec2 math, gravity, integrator. No raylib.
src/main.zig   Renderer + input. The only file that imports raylib.
planets.zon    Planet tuning config (ZON), editable in-game via the debug panel.
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
