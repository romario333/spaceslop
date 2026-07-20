---
name: debug-bridge
description: Run and drive the game programmatically via its debug bridge — launch it, dump sim state as JSON, inject clicks/keys, pause and single-step physics deterministically, take screenshots. Use whenever you need to see or poke the running game - verifying a gameplay/rendering/camera/input change, reproducing an input bug, or capturing a screenshot. Not needed for pure sim-logic changes (extend `zig build test` tests in sim.zig instead).
---

# Driving the game via the debug bridge

The game (native and web) embeds a line-based debug protocol: one command in,
one line out. Dispatcher lives in `src/debug.zig`; synthetic input is injected
in `src/input.zig` upstream of the same code paths real input uses.

**Prefer the native build for development.** Compile times are comparable
(incremental: ~1.7 s native vs ~2.5 s web), but the native iteration loop is
far faster: launch-to-bridge-ready is ~0.7 s, commands are direct TCP writes,
and it has real screenshots. The web path adds an HTTP server + browser load
+ wasm init before the first command, and an unfocused browser tab renders
~1 frame/s — since the bridge consumes one command/step per rendered frame,
step-driven sequences run ~10× slower there. Only use the web build when the
change is web-specific.

## Launch (native)

Run from the **project root** (resources load from cwd). The window opens
small and unfocused and keeps running minimized — it won't interrupt the user.

```sh
zig build
nohup ./zig-out/bin/space-slop --debug > /tmp/space-slop.log 2>&1 &
sleep 2   # window + listener need a moment
```

`nohup` matters: without it the game dies when the launching shell exits.
Default port 4444 (`--debug 5555` for another). Kill when done:
`pkill -f "space-slop --debug"`.

## Talking to it

One-shot (fine for single commands):

```sh
echo state | nc -w 2 localhost 4444
```

For multi-command sequences (pause → inject → step → assert), keep one
connection open from a Python script — `zsh` has no `/dev/tcp`:

```python
import socket, json, time
f = socket.create_connection(("127.0.0.1", 4444)).makefile("rw")
def send(cmd):
    f.write(cmd + "\n"); f.flush()
    return f.readline().strip()
send("pause")
send("clickw 0 0")          # click Earth (world coords)
time.sleep(0.2)             # injected input lands next rendered frame
print(json.loads(send("state"))["selected"])
```

Sleep ~0.2 s after injecting input or stepping before reading `state`:
commands are consumed one per rendered frame.

## Commands

| Command | Effect |
|---------|--------|
| `state` | full game state as one line of JSON: `step` (fixed-step counter), `paused`, `ship` (pos/vel/speed/angle/thrusting), `soi`, `planets`, `camera`, `selected`, `pan_offset`, `screen`, `theme` |
| `screenshot <path>` | save the current frame; replies only after the file exists |
| `click <x> <y> [hold]` | left click at screen px, held `hold` frames. `hold 0` = press **and** release in the same frame (the flaky trackpad tap) |
| `clickw <wx> <wy> [hold]` | same, world coordinates — `clickw 0 0` hits Earth |
| `key <name> [frames]` | hold `w/a/d/up/left/right/thrust` for n physics-stepping frames; `r/t/o/f` are one-shots |
| `wheel <dx> <dy>` | one frame of scroll (pans) |
| `zoom <dy>` | one frame of cmd+scroll (zooms) |
| `pause` / `resume` | freeze/unfreeze physics; rendering and the bridge keep running |
| `step [n]` | while paused, advance exactly n fixed steps, one per rendered frame |
| `help` | list commands |

## Deterministic repro recipe

Held keys tick down only on frames where physics actually steps, so paused
sequences are exact: `pause` → `key thrust 3` → `step 3` is precisely three
thrusting steps. For selection/tap bugs: `pause` → `clickw <x> <y> 0` →
`step 1` → diff `state` before/after. `step` in `state` is the determinism
clock — same commands from a fresh launch replay identically.

## Web build (when native won't do)

```sh
zig build -Dtarget=wasm32-emscripten     # slow; retry once if the emcc cache errors on first run
cd zig-out/web && python3 -m http.server 8000
```

Open `http://localhost:8000/space_slop.html` with the browser preview tools,
then call the same protocol via `preview_evaluate`:
`window.spaceSlopDebug('state')`. Screenshots are unsupported there — use
`preview_snapshot`; and note a hidden tab renders ~1 frame/s, so `step n`
drains slowly and needs longer waits.
