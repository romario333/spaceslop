//! Entry point and game loop. The raylib-specific code is spread across the
//! render layer (render.zig), the detail panel (detail_panel.zig) and this
//! file; the actual physics is in sim.zig, which knows nothing about raylib.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const sim = @import("sim.zig");
const Vec2 = sim.Vec2;
const cfg = @import("config.zig");
const render = @import("render.zig");
const Theme = render.Theme;
const SpriteSet = render.SpriteSet;
const Trail = render.Trail;
const DetailPanel = @import("detail_panel.zig").DetailPanel;
const input = @import("input.zig");
const dbg = @import("debug.zig");
const v = render.v;

/// The browser build renders into a fixed-size canvas, so fullscreen handling
/// only applies to native desktop targets.
const is_web = builtin.target.os.tag == .emscripten;

const screen_w = 1000;
const screen_h = 700;

// Do not rely on the platform's vsync implementation to pace the loop: on
// some native backends the flag is only a hint and the game otherwise renders
// hundreds of identical frames per second. Keep background debug instances
// responsive without spending a full foreground frame budget on them.
const foreground_fps: i32 = 60;
const unfocused_fps: i32 = 15;

// Belt rock arrays — file scope, not run()'s stack: ~240 KB of colliders
// plus ~850 KB of outlines would be a big bite out of the wasm stack.
var belt_rocks: [sim.Belt.Band.asteroid.count]sim.Belt.Rock = undefined;
var belt_visuals: render.AsteroidBelt = undefined;
var kuiper_rocks: [sim.Belt.Band.kuiper.count]sim.Belt.Rock = undefined;
var kuiper_visuals: render.KuiperBelt = undefined;

/// The ship's predicted coast path — ~60 KB of points, so file scope like
/// the belt arrays rather than run()'s stack.
var trajectory: sim.Trajectory = .{};

/// Index of Earth in the canonical body order (see cfg.names); the ship
/// spawns there and the ISS orbits it.
const earth_idx = 3;

const Orbit = sim.Orbit;

/// Scripted Kepler ellipse of each body, index-aligned with the planets array
/// (null = the sun, which sits still at the origin). Parents must precede
/// their children so updateOrbits reads fresh parent state within one pass.
/// Mean motions are a few percent of the physically correct rate for each
/// altitude (~10% before the great mass increase, see config.zig) —
/// the same arcade slowdown the moon always had, keeping Keplerian ordering
/// (inner planets visibly outpace outer ones) while an SOI never outruns a
/// ship trying to get captured. Eccentricities are the real ones where they
/// fit, capped where this compressed system lacks the room (real Mercury is
/// e=0.21, real Mars 0.09; the giants sit far too close together here for
/// their true values): each body's apoapsis-plus-SOI must leave clear water
/// before the next body's periapsis-minus-SOI (e.g. Venus tops out at 11565
/// from the sun, Earth's band begins at 11758) so patched conics stay
/// unambiguous. Periapsis directions are the real longitudes of perihelion.
const orbits = [_]?Orbit{
    null, // sun
    .{ .parent = 0, .semi_major = 5500, .omega = 0.0027, .phase = 2.0, .ecc = 0.15, .peri = 1.35 }, // mercury
    .{ .parent = 0, .semi_major = 9500, .omega = 0.0012, .phase = 4.2, .ecc = 0.007, .peri = 2.30 }, // venus
    .{ .parent = 0, .semi_major = 14500, .omega = 0.0006, .phase = 0.0, .ecc = 0.017, .peri = 1.80 }, // earth
    .{ .parent = earth_idx, .semi_major = 1500, .omega = 0.008, .phase = -0.4, .ecc = 0.055, .peri = 5.55 }, // moon
    .{ .parent = 0, .semi_major = 20000, .omega = 0.0004, .phase = 5.3, .ecc = 0.05, .peri = 5.87 }, // mars
    .{ .parent = 0, .semi_major = 28000, .omega = 0.00024, .phase = 1.2, .ecc = 0.012, .peri = 0.26 }, // jupiter
    .{ .parent = 0, .semi_major = 38500, .omega = 0.00015, .phase = 3.6, .ecc = 0.007, .peri = 1.61 }, // saturn
    .{ .parent = 0, .semi_major = 46500, .omega = 0.00011, .phase = 0.9, .ecc = 0.003, .peri = 2.98 }, // uranus
    .{ .parent = 0, .semi_major = 53500, .omega = 0.00009, .phase = 4.8, .ecc = 0.005, .peri = 0.79 }, // neptune
    // Moons of Mars and Jupiter, compressed to fit their parent's SOI the same
    // way the planets are compressed to fit the sun's. Shapes are realistic:
    // eccentricities are the real ones (all of these moons ride nearly perfect
    // circles), spacing keeps the real semi-major-axis ratios (Deimos at 2.5×
    // Phobos, the Galileans at 1 : 1.59 : 2.54 : 4.46), and the mean motions
    // follow Kepler's third law at the same ~10% arcade slowdown as the
    // planets — which also preserves the Galileans' 4:2:1 Laplace resonance
    // (Io laps Europa twice and Ganymede four times).
    .{ .parent = 5, .semi_major = 320, .omega = 0.0387, .phase = 1.7, .ecc = 0.015, .peri = 2.10 }, // phobos
    .{ .parent = 5, .semi_major = 800, .omega = 0.0097, .phase = 3.9, .ecc = 0.0003, .peri = 0.50 }, // deimos
    .{ .parent = 6, .semi_major = 930, .omega = 0.0208, .phase = 0.6, .ecc = 0.004, .peri = 4.60 }, // io
    .{ .parent = 6, .semi_major = 1480, .omega = 0.0104, .phase = 2.8, .ecc = 0.009, .peri = 1.00 }, // europa
    .{ .parent = 6, .semi_major = 2360, .omega = 0.0052, .phase = 5.1, .ecc = 0.001, .peri = 3.30 }, // ganymede
    .{ .parent = 6, .semi_major = 4150, .omega = 0.0022, .phase = 1.9, .ecc = 0.007, .peri = 5.80 }, // callisto
    // Kuiper dwarfs: visibly eccentric ellipses wandering through the Kuiper
    // belt (see sim.Belt.Band.kuiper), mean motions on the same arcade Kepler
    // curve as the planets. Eccentricities are the real ones where they fit;
    // Pluto (real e=0.25) and Eris (0.44) are capped like Mercury and Mars,
    // pushed out so their periapsides clear Neptune's apoapsis-plus-SOI
    // (~57000) — real Pluto dips inside Neptune's orbit, but patched conics
    // want clear water between planet-sized SOIs. The dwarfs' own bands
    // overlap each other, as in reality; their SOI bubbles are so small that
    // a dwarf–dwarf close approach is a non-event. Periapsis directions are
    // the real longitudes of perihelion.
    .{ .parent = 0, .semi_major = 68000, .omega = 0.000063, .phase = 2.5, .ecc = 0.14, .peri = 3.91 }, // pluto
    .{ .parent = 0, .semi_major = 73000, .omega = 0.000056, .phase = 5.6, .ecc = 0.19, .peri = 0.02 }, // haumea
    .{ .parent = 0, .semi_major = 77500, .omega = 0.000052, .phase = 1.1, .ecc = 0.16, .peri = 0.25 }, // makemake
    .{ .parent = 0, .semi_major = 100000, .omega = 0.000035, .phase = 3.8, .ecc = 0.35, .peri = 3.27 }, // eris
};

comptime {
    std.debug.assert(orbits.len == cfg.names.len);
}

/// Advance every scripted orbit by `dt` (see sim.updateOrbits).
fn updateOrbits(planets: []sim.Planet, angles: []f32, dt: f32) void {
    sim.updateOrbits(&orbits, planets, angles, dt);
}

/// Tunables for the edge-arrow relevance filter (see edgeArrowMask).
/// Sun-orbiting bodies show out to this multiple of the context planet's
/// orbit — your ring and everything inward, plus one ring out.
const arrow_ring_factor: f32 = 1.6;
/// A moon's arrow collapses into its planet's once the moon's orbit spans
/// fewer than this many pixels on screen — below that both arrows would sit
/// on the same edge spot.
const arrow_collapse_px: f32 = 48.0;
/// Bodies within this many screen-widths of the camera always show.
const arrow_reach_screens: f32 = 2.0;

/// Planet-level ancestor of body `i`: the body itself if it orbits the sun
/// (or is the sun), otherwise the planet its moon hangs off.
fn planetAncestor(i: usize) usize {
    var idx = i;
    while (orbits[idx]) |o| {
        if (o.parent == 0) return idx;
        idx = o.parent;
    }
    return idx; // the sun
}

/// Which bodies deserve an edge arrow this frame (see render.drawEdgeArrows).
/// Unfiltered, all 20 off-screen bodies point at once and the edge turns to
/// noise — near Earth nobody cares where Callisto or Makemake is. A body
/// qualifies if any rule passes:
///  1. Anchors: the sun, and the context body (the selected body, else the
///     ship's SOI owner) with its parent chain — you can always find home,
///     and a body you explicitly selected always shows.
///  2. Moons: only those of the context planet, and only while zoomed in far
///     enough to resolve them (see arrow_collapse_px) — Jupiter's moons never
///     clutter the edge while you fly around Earth.
///  3. Sun-orbiting bodies on the context planet's ring or inward, plus one
///     ring out (arrow_ring_factor): at Earth that is Mercury through Mars,
///     with Jupiter and everything beyond hidden. Keyed off semi-major axes,
///     not live distances, so arrows never flicker as bodies orbit.
///  4. Anything within arrow_reach_screens of the camera: zoomed out to
///     system scale, the bodies just off the edge are exactly what the
///     arrows are for, wherever the ship happens to be.
fn edgeArrowMask(planets: []const sim.Planet, world: *const sim.World, cam: rl.Camera2D, selected: ?usize) [cfg.names.len]bool {
    const ctx = selected orelse world.dominantIndex(world.ship.pos) orelse 0;
    const ctx_planet = planetAncestor(ctx);
    const focus: Vec2 = .{ .x = cam.target.x, .y = cam.target.y };
    // Reference orbit scale for rule 3. In deep space (context = sun) use how
    // far out the view sits, floored at Mercury so the inner system always
    // shows.
    const r_ctx = if (orbits[ctx_planet]) |o|
        o.semi_major
    else
        @max(focus.sub(planets[0].pos).len(), orbits[1].?.semi_major);
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const reach = arrow_reach_screens * sw / cam.zoom;

    var mask: [cfg.names.len]bool = undefined;
    for (planets, 0..) |p, i| {
        mask[i] = visible: {
            if (i == 0 or i == ctx or i == ctx_planet) break :visible true; // rule 1
            const near = p.pos.sub(focus).len() < reach; // rule 4
            const o = orbits[i] orelse break :visible true; // only the sun, handled above
            if (o.parent != 0) {
                // Rule 2 — a moon. Rule 4 can pull in a foreign moon system,
                // but the collapse threshold still applies so an unresolvable
                // cluster never lands on its planet's arrow.
                break :visible (o.parent == ctx_planet or near) and o.semi_major * cam.zoom >= arrow_collapse_px;
            }
            break :visible o.semi_major <= arrow_ring_factor * r_ctx or near; // rules 3 + 4
        };
    }
    return mask;
}

/// Ratcheted pan clamp, shared by wheel and click-drag panning. Panning back
/// toward the followed body is always allowed; panning further out stops at
/// max_pan — or wherever the offset already sat (`before`), since selecting a
/// body at the edge of a zoomed-out view can start beyond max_pan.
fn ratchetPan(pan_offset: *Vec2, before: f32) void {
    const limit = @max(DetailPanel.max_pan, before);
    if (pan_offset.len() > limit) pan_offset.* = pan_offset.normalized().scale(limit);
}

/// The ship's spawn state: a counter-clockwise circular low orbit around
/// Earth, wherever Earth currently is. Also used by the R-key reset, so
/// resetting mid-flight puts you back home rather than where Earth used to be.
fn shipStart(earth: sim.Planet) sim.Ship {
    const r: f32 = 340;
    const speed = sim.World.circularOrbitSpeed(earth.mass, r);
    return .{
        .pos = earth.pos.add(.{ .x = r }),
        .vel = earth.vel.add(.{ .y = speed }),
        .angle = -std.math.pi / 2.0, // nose pointing "up" (-y)
    };
}

/// Seconds until the next spontaneous flare: an exponential draw with mean
/// `mean`, the waiting time of a Poisson process. `float` yields [0,1), so
/// `1 - u` lands in (0,1] and the log is always finite.
fn nextFlareWait(rand: std.Random, mean: f32) f32 {
    return -mean * @log(1.0 - rand.float(f32));
}

/// `main` must not return errors: the std error-printing path that would
/// handle them pulls in child-process code that doesn't compile for
/// wasm32-emscripten (same std-lib issue that breaks Debug web builds).
/// It takes `Init.Minimal` (not the full `Init`) for the same reason: the
/// full version drags in environment/IO machinery the web target can't build.
pub fn main(init: std.process.Init.Minimal) void {
    run(init) catch |err| rl.traceLog(.err, "fatal: %s", .{@errorName(err).ptr});
}

fn run(init: std.process.Init.Minimal) !void {
    // Debug mode (`--debug [port]`) is decided before the window opens: a
    // debug-driven instance is a background tool, so it must not take over
    // the screen or steal keyboard focus from whatever the user is doing.
    var debug_port: ?u16 = null;
    if (!is_web) {
        var args = std.process.Args.Iterator.init(init.args);
        _ = args.next(); // program name
        var requested = false;
        var port: u16 = 4444;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--debug")) {
                requested = true;
            } else if (requested) {
                port = std.fmt.parseInt(u16, arg, 10) catch port;
            }
        }
        if (requested) debug_port = port;
    }

    rl.setConfigFlags(.{
        .vsync_hint = true,
        .window_resizable = true,
        .msaa_4x_hint = true,
        // Debug instances open without key focus and keep simulating while
        // minimized, so the bridge stays responsive in the background.
        .window_unfocused = debug_port != null,
        .window_always_run = debug_port != null,
    });
    rl.initWindow(screen_w, screen_h, "space-slop");
    defer rl.closeWindow();
    // Browser builds are already paced by requestAnimationFrame, which also
    // throttles background tabs. Native needs an explicit cap because its
    // vsync hint is not guaranteed to be honoured.
    var target_fps: i32 = foreground_fps;
    if (!is_web) rl.setTargetFPS(target_fps);
    // Catch clicks shorter than a frame (trackpad taps) that raylib's own
    // per-frame polling loses; see input.zig.
    input.init();

    // Native builds start fullscreen at the monitor's native resolution —
    // except in debug mode, which stays a small window in the background.
    if (!is_web and debug_port == null) {
        const monitor = rl.getCurrentMonitor();
        rl.setWindowSize(rl.getMonitorWidth(monitor), rl.getMonitorHeight(monitor));
        rl.toggleFullscreen();
    }

    // --- Sprites & theme ---------------------------------------------------
    // Smooth illustration rendered at world resolution, so it gets bilinear
    // filtering.
    var theme: Theme = .scifi_60s;
    const sprite_sets = [_]SpriteSet{
        try SpriteSet.load("scifi-60s", 1.0, .bilinear),
    };
    defer for (sprite_sets) |s| s.unload();

    const flare_fx = try render.FlareFx.init();
    defer flare_fx.unload();

    // --- World setup -------------------------------------------------------
    // Gravity uses arcade patched conics (see sim.gravityAt): only the body
    // whose innermost sphere of influence contains the ship pulls on it, so
    // orbits around every body are clean stable ellipses. The whole system is
    // scripted kinematics — the sun sits at the origin, Mercury through
    // Neptune ride Kepler ellipses around it, and the moons ride ellipses
    // around Earth, Mars and Jupiter (see `orbits`) — and each body's SOI
    // travels with it. Bodies are small on screen but pull hard: deep wells
    // inside tight SOI bubbles, plus the sim's capture assist, mean a ship
    // that coasts in slowly settles into orbit on its own, while fast flybys
    // slingshot through undisturbed. Beyond the sun's SOI there is no
    // gravity: deep space. Tuning values come from planets.zon (config.zig).
    var config = cfg.Config.load();
    var planets: [cfg.names.len]sim.Planet = undefined;
    for (&planets, 0..) |*p, i| {
        const c = config.planet(i).*;
        p.* = .{ .pos = .{}, .mass = c.mass, .radius = c.radius, .soi = c.soi, .core = c.core, .services = cfg.hasServices(i) };
    }
    var angles: [orbits.len]f32 = undefined;
    for (orbits, 0..) |o, i| angles[i] = if (o) |orb| orb.phase else 0;
    updateOrbits(&planets, &angles, 0); // place every body before the first frame

    // The belts' rocks are real colliders in the sim; the render layer rolls
    // its cosmetic attributes (shape, tint, tumble) from a separate stream,
    // index-aligned with the same array.
    sim.Belt.fillRocks(&belt_rocks, 0xA57E_401D, .asteroid);
    belt_visuals.init(0x0C_407E5);
    sim.Belt.fillRocks(&kuiper_rocks, 0x1CE_BE17, .kuiper);
    kuiper_visuals.init(0x1CE_407E5);

    var world: sim.World = .{
        .planets = &planets,
        .ship = shipStart(planets[earth_idx]),
        .belt = .{ .rocks = &belt_rocks },
        .kuiper = .{ .band = .kuiper, .rocks = &kuiper_rocks },
    };

    // Decorative ISS on a low circular orbit around the primary planet. It
    // lives entirely in the render layer and never affects the physics. Its
    // angular speed starts from the physically correct value for its altitude,
    // then gets slowed by an arcade factor so the orbit reads at a glance.
    const iss_orbit_r: f32 = 190;
    const iss_speed_scale: f32 = 0.45;
    const iss_omega = iss_speed_scale * sim.World.circularOrbitSpeed(planets[earth_idx].mass, iss_orbit_r) / iss_orbit_r;
    var iss_angle: f32 = 0;

    // Repeating starfield, generated once with a fixed seed (see render.zig):
    // one tile is stamped across the view, keeping the on-screen star density
    // constant wherever the ship travels and whatever the zoom.
    const stars = render.Starfield.init(0x5EED_1234);

    var trail: Trail = .{};
    // SOI rings start hidden: the dashed orbit paths already show the system's
    // layout, and the rings are a physics-debugging overlay you turn on (O)
    // when you want to see exactly where gravity hands over.
    var show_soi = false;
    // The predicted flight path starts visible — it's the main flying aid —
    // and P hides it for purists.
    var show_prediction = true;
    var detail: DetailPanel = .{};
    // Where the view sits relative to the followed body, in world px. Keeping
    // it relative means the camera still rides along with the body while you
    // look around. Selecting a planet carries the offset over so the view
    // doesn't jump; deselecting or R zeroes it, snapping back to the ship.
    var pan_offset: Vec2 = .{};
    // Click-drag panning. A press outside the detail panel is withheld from
    // the click paths until it declares itself: travelling past the threshold
    // makes it a pan and swallows the click; releasing before that replays it
    // as a normal click. `drag_anchor` is where the withheld press landed.
    var drag_anchor: ?rl.Vector2 = null;
    var drag_last: rl.Vector2 = .{ .x = 0, .y = 0 };
    var drag_panning = false;
    // Flare directions come from a fixed-seed stream: the sim stays RNG-free
    // (the rolled angle is passed into triggerFlare), the web build needs no
    // entropy source, and debug-bridge runs are reproducible — the first press
    // always fires the same way, while successive presses still vary.
    var flare_prng = std.Random.DefaultPrng.init(0xF1A2E);
    // The sun also erupts on its own. Waits are drawn from an exponential
    // distribution (a Poisson process), so eruptions are memoryless — no
    // countdown the pilot can learn — while averaging one per `flare_mean`
    // of sim time. The clock only runs while the sun is quiet, so the mean
    // measures the gap between eruptions rather than between their starts.
    const flare_mean: f32 = 300; // 5 minutes
    var flare_wait: f32 = nextFlareWait(flare_prng.random(), flare_mean);

    var cam: rl.Camera2D = .{
        .target = v(world.ship.pos),
        .offset = .{ .x = screen_w / 2.0, .y = screen_h / 2.0 },
        .rotation = 0,
        .zoom = 1.0,
    };

    // --- Debug bridge ------------------------------------------------------
    // Always wired (the web build's exported dispatcher may be called at any
    // time); the native TCP transport only starts when asked to.
    dbg.init(.{
        .world = &world,
        .planets = &planets,
        .cam = &cam,
        .detail = &detail,
        .pan_offset = &pan_offset,
        .theme = &theme,
    });
    if (debug_port) |port| dbg.serve(port);

    // --- Fixed-timestep loop ----------------------------------------------
    const fixed_dt: f32 = 1.0 / 120.0;
    var accumulator: f32 = 0;

    while (!rl.windowShouldClose()) {
        if (!is_web) {
            const wanted_fps: i32 = if (rl.isWindowFocused()) foreground_fps else unfocused_fps;
            if (wanted_fps != target_fps) {
                target_fps = wanted_fps;
                rl.setTargetFPS(target_fps);
            }
        }

        dbg.pump();

        // How many fixed steps to run this frame: real elapsed time (scaled
        // by the debug `warp` factor) normally; while the debug bridge holds
        // the sim paused, exactly one step per rendered frame from the `step`
        // budget, so injected per-frame input lands deterministically. A
        // debug `run` batch executes in full this frame on top of either.
        var steps: u32 = 0;
        if (dbg.paused) {
            accumulator = 0; // don't bank real time while frozen
            if (dbg.steps_pending > 0) {
                dbg.steps_pending -= 1;
                steps = 1;
            }
        } else {
            accumulator += rl.getFrameTime() * dbg.warp;
            // Avoid the spiral of death, but scale the cap with warp — a
            // fixed 0.25 s would silently limit warp to ~30x of real time.
            const max_acc = 0.25 * @max(1.0, dbg.warp);
            if (accumulator > max_acc) accumulator = max_acc;
            while (accumulator >= fixed_dt) : (accumulator -= fixed_dt) steps += 1;
        }
        steps += dbg.run_pending;
        dbg.run_pending = 0;

        // Input -> simulation intent
        const in = input.sample(steps > 0);
        const sim_input: sim.Input = .{
            .turn = in.turn,
            .thrust = in.thrust,
            .brake = in.brake,
            .refuel = in.service_fuel,
            .repair = in.service_repair,
        };
        if (in.reset) {
            world.ship = shipStart(planets[earth_idx]);
            trail.clear();
            pan_offset = .{};
        }
        // Debug convenience: top the tank back up without resetting the orbit.
        if (in.refuel) world.ship.fuel = world.ship.tank;
        // Debug: bolt on another 100-unit tank section, delivered full. The
        // HUD bar widens with capacity, so each press visibly grows it.
        if (in.grow_tank) {
            world.ship.tank += 100;
            world.ship.fuel += 100;
        }
        if (!is_web and in.fullscreen) rl.toggleFullscreen();
        if (in.cycle_theme) theme = theme.next();
        if (in.toggle_soi) show_soi = !show_soi;
        if (in.toggle_prediction) show_prediction = !show_prediction;
        // One flare at a time; the key is ignored while one is in flight.
        if (in.flare and world.flare == null) {
            world.triggerFlare(flare_prng.random().float(f32) * std.math.tau);
            // Forcing one restarts the wait, so a manual flare isn't chased by
            // a spontaneous one that happened to be due.
            flare_wait = nextFlareWait(flare_prng.random(), flare_mean);
        }

        // Two-finger scroll pans the view; hold cmd (super) to zoom instead.
        // Keep the camera centred on the current window size.
        const wheel = in.wheel;
        if (in.zoom_modifier) {
            // Floor fits the whole system: Eris tops out near r=135700 plus
            // its SOI, so ~273000 units across; 0.0035 shows that in one window.
            if (wheel.y != 0) cam.zoom = std.math.clamp(cam.zoom * (1.0 + wheel.y * 0.1), 0.0035, 4.0);
        } else if (wheel.x != 0 or wheel.y != 0) {
            // Content follows the fingers: a wheel unit moves the view a
            // fixed number of screen px regardless of zoom.
            const scroll_speed: f32 = 20.0;
            const before = pan_offset.len();
            pan_offset.x -= wheel.x * scroll_speed / cam.zoom;
            pan_offset.y -= wheel.y * scroll_speed / cam.zoom;
            ratchetPan(&pan_offset, before);
        }

        // Click-drag pans the view too. Presses on the detail panel pass
        // through untouched (sliders and buttons keep their immediate feel);
        // any other press is withheld until it declares itself a click or a
        // drag. handleMouse copes with press+release in one frame — the same
        // shape as a trackpad tap — so the replayed click takes the exact
        // paths a direct click would.
        var mouse = in.mouse;
        if (mouse.pressed) {
            drag_anchor = null;
            if (!detail.containsPoint(mouse.pos)) {
                mouse.pressed = false;
                if (mouse.released) {
                    // Same-frame tap: plainly a click, nothing to withhold.
                    mouse.pressed = true;
                } else {
                    drag_anchor = mouse.pos;
                    drag_last = mouse.pos;
                    drag_panning = false;
                }
            }
        } else if (drag_anchor) |anchor| {
            // Travel this far from the press (screen px) and it's a pan.
            const drag_threshold: f32 = 4;
            const dx = mouse.pos.x - anchor.x;
            const dy = mouse.pos.y - anchor.y;
            if (dx * dx + dy * dy > drag_threshold * drag_threshold) drag_panning = true;
            if (drag_panning) {
                // Content follows the cursor: world pinned under the finger.
                const before = pan_offset.len();
                pan_offset.x -= (mouse.pos.x - drag_last.x) / cam.zoom;
                pan_offset.y -= (mouse.pos.y - drag_last.y) / cam.zoom;
                ratchetPan(&pan_offset, before);
            }
            drag_last = mouse.pos;
            if (mouse.released) {
                if (!drag_panning) {
                    // Never moved: replay the withheld press as a click at
                    // the spot the player actually aimed at.
                    mouse.pressed = true;
                    mouse.pos = anchor;
                }
                drag_anchor = null;
                drag_panning = false;
            }
        }
        cam.offset = .{
            .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2.0,
            .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2.0,
        };

        // Planet picking + slider drags. Runs before the physics steps so an
        // edit shows up on this very frame.
        detail.handleMouse(&planets, cam, &pan_offset, mouse);
        detail.save_flash = @max(0, detail.save_flash - rl.getFrameTime());
        if (detail.save_requested) {
            detail.save_requested = false;
            if (detail.selected) |idx| {
                const p = planets[idx];
                config.planet(idx).* = .{ .mass = p.mass, .radius = p.radius, .soi = p.soi, .core = p.core };
                detail.save_ok = if (config.save()) |_| true else |err| blk: {
                    rl.traceLog(.warning, "saving %s failed: %s", .{ cfg.path.ptr, @errorName(err).ptr });
                    break :blk false;
                };
                detail.save_flash = 1.5;
            }
        }

        // Advance physics in fixed steps (count decided above).
        while (steps > 0) : (steps -= 1) {
            // All bodies are kinematic: they move on fixed ellipses and the
            // ship physics just sees their updated positions each step (see
            // updateOrbits and sim.Planet.acc).
            updateOrbits(&planets, &angles, fixed_dt);
            // Spontaneous eruptions run on sim time, so they honour pause,
            // `warp` and `run` just like the rest of the simulation.
            if (world.flare == null) {
                flare_wait -= fixed_dt;
                if (flare_wait <= 0) {
                    world.triggerFlare(flare_prng.random().float(f32) * std.math.tau);
                    flare_wait = nextFlareWait(flare_prng.random(), flare_mean);
                }
            }
            world.step(fixed_dt, sim_input);
            trail.push(world.ship.pos, &world);
            iss_angle = @mod(iss_angle + iss_omega * fixed_dt, std.math.tau);
            dbg.step_count += 1;
        }
        // Predicted coast, recomputed every frame: a burn reshapes it live,
        // and the detail panel can retune masses/SOIs even while paused.
        if (show_prediction) trajectory.predict(&world, &orbits, &angles, fixed_dt);
        // A selected planet becomes the frame of reference: the camera rides
        // along with it, so the ship's motion reads relative to that body.
        // Deselecting (click it again, or click empty space) returns to the
        // ship. Scrolling pans the view around whichever body is followed.
        const follow_pos = if (detail.selected) |idx| planets[idx].pos else world.ship.pos;
        cam.target = v(follow_pos.add(pan_offset));
        // Panel position tracks the selected body, so it needs the final camera.
        detail.place(&planets, cam);

        // --- Draw ----------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 8, .g = 10, .b = 20, .a = 255 });

        {
            rl.beginMode2D(cam);
            defer rl.endMode2D();

            stars.draw(cam);

            // Every body moves on a fixed ellipse around its parent, so its
            // path is that ellipse drawn where the parent is right now.
            for (orbits, 0..) |maybe_orbit, i| {
                const o = maybe_orbit orelse continue;
                render.drawOrbitPath(planets[o.parent].pos, o.semi_major, o.ecc, o.peri, i, cam);
            }

            trail.draw(&planets, cam);
            if (show_prediction) render.drawTrajectory(&trajectory, &planets, cam);

            // Under the planets: a rock passing behind Jupiter should occlude
            // like the background object it is.
            if (world.belt) |*b| belt_visuals.draw(b, planets[0].pos, cam);
            if (world.kuiper) |*b| kuiper_visuals.draw(b, planets[0].pos, cam);

            const sprites: ?*const SpriteSet = switch (theme) {
                .scifi_60s => &sprite_sets[0],
                .classic => null,
            };

            // Sphere-of-influence boundaries (toggle with O). Only the body
            // whose ring you are inside pulls on the ship; outside Earth's
            // ring nothing does. Stroke width is fixed in *screen* px so the
            // rings stay visible zoomed all the way out; capped at half the
            // SOI so a tiny moon's ring never inverts into a filled disc.
            if (show_soi) {
                for (planets) |p| {
                    const half = @min(1.5 / cam.zoom, p.soi * 0.5);
                    rl.drawRing(v(p.pos), p.soi - half, p.soi + half, 0, 360, 240, .{ .r = 170, .g = 140, .b = 255, .a = 110 });
                }
            }

            if (sprites) |s| {
                // Textures are exported at some fixed world size, so scale
                // each so the sprite spans the body's current physics diameter
                // — that keeps the detail panel's `size` slider honest.
                for (planets, 0..) |p, i| {
                    if (s.body(i)) |tex| {
                        s.drawSprite(tex, p.pos, 0, render.spriteScale(s, tex, p.radius));
                    } else {
                        // No art yet (the Kuiper dwarfs): tinted stand-in disc.
                        render.drawPlaceholderBody(p.pos, p.radius, i);
                    }
                }
            } else {
                for (planets) |p| {
                    rl.drawCircleV(v(p.pos), p.radius, .{ .r = 90, .g = 120, .b = 160, .a = 255 });
                    rl.drawCircleLinesV(v(p.pos), p.radius, .{ .r = 150, .g = 190, .b = 230, .a = 255 });
                }
            }

            if (world.flare) |fl| render.drawFlare(fl, planets[0].radius, &flare_fx);

            // ISS orbits Earth with its truss tangent to the orbit.
            const iss_pos = planets[earth_idx].pos.add(Vec2.fromAngle(iss_angle).scale(iss_orbit_r));
            const iss_deg = iss_angle * 180.0 / std.math.pi + 90.0;
            if (sprites) |s| s.drawSprite(s.iss, iss_pos, iss_deg, 1.0) else render.drawIssClassic(iss_pos, iss_deg);

            // A destroyed ship isn't drawn — only the impact sparks below
            // mark the crash site until the player resets with R.
            if (world.ship.alive()) render.drawShip(world.ship, sprites);
            // Sparks for a moment after each hit (see Ship.hit_timer).
            if (world.ship.hit_timer > 0) {
                render.drawBeltImpacts(world.ship.pos, world.belt.?.time);
            }
            detail.drawSelection(&planets);

            // Velocity vector (green) for orbital intuition.
            if (world.ship.alive()) {
                const vel_end = world.ship.pos.add(world.ship.vel.scale(0.4));
                rl.drawLineEx(v(world.ship.pos), v(vel_end), 2.0, .{ .r = 90, .g = 230, .b = 120, .a = 255 });
            }
        }

        const arrow_mask = edgeArrowMask(&planets, &world, cam, detail.selected);
        render.drawEdgeArrows(&planets, cam, &arrow_mask);
        // Parked in a stable orbit: offer that body's services over it.
        if (world.serviceTarget()) |idx| render.drawServicePrompt(world, &planets, idx, cam);
        render.drawHud(world);
        // Name tag for whatever body the cursor is over — same hit test that
        // clicking uses, and skipped over the panel, which owns its own area.
        // A hand cursor marks the body as clickable.
        const hovered: ?usize = if (detail.containsPoint(mouse.pos)) null else DetailPanel.pick(&planets, cam, mouse.pos);
        rl.setMouseCursor(if (hovered != null) .pointing_hand else .default);
        if (hovered) |idx| render.drawHoverLabel(idx, mouse.pos);
        detail.draw(&planets);

        // Runs before the deferred endDrawing above swaps buffers, so a
        // requested screenshot captures exactly this frame.
        dbg.finishFrame();
    }
}
