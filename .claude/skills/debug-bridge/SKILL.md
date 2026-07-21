---
name: debug-bridge
description: Run and drive the game programmatically via its debug bridge — launch it, dump sim state as JSON, inject clicks/keys, pause and single-step physics deterministically, fast-forward sim time (`run`/`warp`), take screenshots. Use whenever you need to see or poke the running game - verifying a gameplay/rendering/camera/input change, reproducing an input bug, or capturing a screenshot. Not needed for pure sim-logic changes (extend `zig build test` tests in sim.zig instead).
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
rm -f .debug-bridge-port
nohup ./zig-out/bin/space-slop --debug > /tmp/space-slop.log 2>&1 &
echo $! > /tmp/space-slop.pid
sleep 2   # window + listener need a moment
PORT=$(cat .debug-bridge-port)
```

`nohup` matters: without it the game dies when the launching shell exits.

**Never assume the port.** Several worktrees of this repo are often driven at
the same time; a hardcoded port would connect you to another agent's game.
The instance claims the first free port from 4444 upward and writes the one it
got to `.debug-bridge-port` in its cwd (gitignored) — read that file, in *your*
worktree, and always delete it before launching so a stale value from an
earlier run can't point you at someone else's instance. `--debug 5555` moves
the scan's starting point if you want a recognisable range.

For the same reason, kill by pid, not by pattern — `pkill -f "space-slop
--debug"` takes down every worktree's instance:

```sh
kill $(cat /tmp/space-slop.pid); rm -f .debug-bridge-port
```

(Use a per-worktree log/pid path, or keep them inside the worktree, if you
launch from several checkouts in one session.)

## Talking to it

One-shot (fine for single commands):

```sh
echo state | nc -w 2 localhost $(cat .debug-bridge-port)
```

For multi-command sequences (pause → inject → step → assert), keep one
connection open from a Python script — `zsh` has no `/dev/tcp`:

```python
import socket, json, time, pathlib
port = int(pathlib.Path(".debug-bridge-port").read_text())
f = socket.create_connection(("127.0.0.1", port)).makefile("rw")
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
| `run <n>` | fast-forward: execute n fixed steps synchronously inside the next frame, paused or not (cap 1M/command). The whole batch sees that one frame's input — use `step` for input-exact sequences |
| `warp <x>` | scale sim speed while running: real time × x feeds the physics accumulator (0.01–100). `warp 1` restores normal speed; useful for *watching* things evolve, where `run` jumps instantly |
| `help` | list commands |

## Deterministic repro recipe

Held keys tick down only on frames where physics actually steps, so paused
sequences are exact: `pause` → `key thrust 3` → `step 3` is precisely three
thrusting steps. For selection/tap bugs: `pause` → `clickw <x> <y> 0` →
`step 1` → diff `state` before/after. `step` in `state` is the determinism
clock — same commands from a fresh launch replay identically.

## Fast-forwarding sim time

Physics runs at 120 Hz, so `run 7200` jumps one sim-minute in a single frame
(deterministic — dt is fixed). To reach a state minutes ahead (orbit
evolution, SOI transitions, long trails), `run` there and then `state` /
`screenshot`; don't wait in real time or drain `step` at one step per frame.
The reply is sent before the batch executes, so sleep ~0.2 s (one frame)
before reading `state`.

## Web build (when native won't do)

```sh
zig build -Dtarget=wasm32-emscripten     # slow; retry once if the emcc cache errors on first run
cd zig-out/web && python3 -u -m http.server 0 > /tmp/space-slop-web.log 2>&1 &
sleep 1 && grep -o 'port [0-9]*' /tmp/space-slop-web.log
```

Port 0 for the same reason as above — port 8000 may already be another
worktree's build, and you'd silently drive the wrong game. Open
`http://localhost:<that port>/space_slop.html` with the browser preview tools,
then call the same protocol via `preview_evaluate`:
`window.spaceSlopDebug('state')`. Screenshots are unsupported there — use
`preview_snapshot`; and note a hidden tab renders ~1 frame/s, so `step n`
drains slowly and needs longer waits.
