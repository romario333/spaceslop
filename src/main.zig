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

/// Index of Earth in the canonical body order (see cfg.names); the ship
/// spawns there and the ISS orbits it.
const earth_idx = 3;

const Orbit = struct { parent: usize, radius: f32, omega: f32, phase: f32 };

/// Scripted circular orbit of each body, index-aligned with the planets array
/// (null = the sun, which sits still at the origin). Parents must precede
/// their children so updateOrbits reads fresh parent state within one pass.
/// Angular speeds are ~10% of the physically correct rate for each altitude —
/// the same arcade slowdown the moon always had, keeping Keplerian ordering
/// (inner planets visibly outpace outer ones) while an SOI never outruns a
/// ship trying to get captured. Orbit radii leave clear water between
/// neighbouring SOIs (e.g. Venus tops out at 11500 from the sun, Earth's
/// begins at 12000) so patched conics stay unambiguous.
const orbits = [_]?Orbit{
    null, // sun
    .{ .parent = 0, .radius = 5500, .omega = 0.0027, .phase = 2.0 }, // mercury
    .{ .parent = 0, .radius = 9500, .omega = 0.0012, .phase = 4.2 }, // venus
    .{ .parent = 0, .radius = 14500, .omega = 0.0006, .phase = 0.0 }, // earth
    .{ .parent = earth_idx, .radius = 1500, .omega = 0.008, .phase = -0.4 }, // moon
    .{ .parent = 0, .radius = 20000, .omega = 0.0004, .phase = 5.3 }, // mars
};

comptime {
    std.debug.assert(orbits.len == cfg.names.len);
}

/// Advance every scripted orbit by `dt` and refresh each body's kinematic
/// state: position on its circle, world velocity, and frame acceleration
/// (the parent's acceleration plus this body's own centripetal term). The
/// acceleration is what lets ships inside a moving SOI ride along with the
/// body (see sim.Planet.acc).
fn updateOrbits(planets: []sim.Planet, angles: []f32, dt: f32) void {
    for (orbits, 0..) |maybe_orbit, i| {
        const o = maybe_orbit orelse continue;
        angles[i] = @mod(angles[i] + o.omega * dt, std.math.tau);
        const parent = planets[o.parent];
        const dir = Vec2.fromAngle(angles[i]);
        planets[i].pos = parent.pos.add(dir.scale(o.radius));
        planets[i].vel = parent.vel.add((Vec2{ .x = -dir.y, .y = dir.x }).scale(o.omega * o.radius));
        planets[i].acc = parent.acc.add(dir.scale(-o.omega * o.omega * o.radius));
    }
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
    // Both packs are smooth illustration rendered above world resolution
    // (pixelart at 2×), so both get bilinear filtering — nearest-neighbour on
    // a minified 2× texture just aliases.
    var theme: Theme = .scifi_60s;
    const sprite_sets = [_]SpriteSet{
        try SpriteSet.load("pixelart", 0.5, .bilinear),
        try SpriteSet.load("scifi-60s", 1.0, .bilinear),
    };
    defer for (sprite_sets) |s| s.unload();

    // --- World setup -------------------------------------------------------
    // Gravity uses arcade patched conics (see sim.gravityAt): only the body
    // whose innermost sphere of influence contains the ship pulls on it, so
    // orbits around every body are clean stable ellipses. The whole system is
    // scripted kinematics — the sun sits at the origin, Mercury through Mars
    // circle it, the moon circles Earth (see `orbits`) — and each body's SOI
    // travels with it. Bodies are small on screen but pull hard: deep wells
    // inside tight SOI bubbles, plus the sim's capture assist, mean a ship
    // that coasts in slowly settles into orbit on its own, while fast flybys
    // slingshot through undisturbed. Beyond the sun's SOI there is no
    // gravity: deep space. Tuning values come from planets.zon (config.zig).
    var config = cfg.Config.load();
    var planets: [cfg.names.len]sim.Planet = undefined;
    for (&planets, 0..) |*p, i| {
        const c = config.planet(i).*;
        p.* = .{ .pos = .{}, .mass = c.mass, .radius = c.radius, .soi = c.soi, .core = c.core };
    }
    var angles: [orbits.len]f32 = undefined;
    for (orbits, 0..) |o, i| angles[i] = if (o) |orb| orb.phase else 0;
    updateOrbits(&planets, &angles, 0); // place every body before the first frame

    var world: sim.World = .{
        .planets = &planets,
        .ship = shipStart(planets[earth_idx]),
    };

    // Decorative ISS on a low circular orbit around the primary planet. It
    // lives entirely in the render layer and never affects the physics. Its
    // angular speed starts from the physically correct value for its altitude,
    // then gets slowed by an arcade factor so the orbit reads at a glance.
    const iss_orbit_r: f32 = 190;
    const iss_speed_scale: f32 = 0.45;
    const iss_omega = iss_speed_scale * sim.World.circularOrbitSpeed(planets[earth_idx].mass, iss_orbit_r) / iss_orbit_r;
    var iss_angle: f32 = 0;

    // Starfield tile, generated once with a fixed seed. A single static field
    // spanning the whole solar system (~50k px across) would need tens of
    // thousands of stars, so instead this one tile repeats: at draw time every
    // copy that intersects the view is drawn, which keeps the on-screen star
    // density constant wherever the ship travels.
    const star_tile: f32 = 7000.0;
    var stars: [1500]rl.Vector2 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rng = prng.random();
    for (&stars) |*s| {
        s.* = .{
            .x = rng.float(f32) * star_tile - star_tile / 2.0,
            .y = rng.float(f32) * star_tile - star_tile / 2.0,
        };
    }

    var trail: Trail = .{};
    var show_soi = true;
    var detail: DetailPanel = .{};
    // Where the view sits relative to the followed body, in world px. Keeping
    // it relative means the camera still rides along with the body while you
    // look around. Selecting a planet carries the offset over so the view
    // doesn't jump; deselecting or R zeroes it, snapping back to the ship.
    var pan_offset: Vec2 = .{};

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
        dbg.pump();

        // How many fixed steps to run this frame: real elapsed time normally;
        // while the debug bridge holds the sim paused, exactly one step per
        // rendered frame from the `step` budget, so injected per-frame input
        // lands deterministically.
        var steps: u32 = 0;
        if (dbg.paused) {
            accumulator = 0; // don't bank real time while frozen
            if (dbg.steps_pending > 0) {
                dbg.steps_pending -= 1;
                steps = 1;
            }
        } else {
            accumulator += rl.getFrameTime();
            if (accumulator > 0.25) accumulator = 0.25; // avoid spiral of death
            while (accumulator >= fixed_dt) : (accumulator -= fixed_dt) steps += 1;
        }

        // Input -> simulation intent
        const in = input.sample(steps > 0);
        const sim_input: sim.Input = .{ .turn = in.turn, .thrust = in.thrust, .brake = in.brake };
        if (in.reset) {
            world.ship = shipStart(planets[earth_idx]);
            trail.clear();
            pan_offset = .{};
        }
        if (!is_web and in.fullscreen) rl.toggleFullscreen();
        if (in.cycle_theme) theme = theme.next();
        if (in.toggle_soi) show_soi = !show_soi;

        // Two-finger scroll pans the view; hold cmd (super) to zoom instead.
        // Keep the camera centred on the current window size.
        const wheel = in.wheel;
        if (in.zoom_modifier) {
            // Floor fits the whole inner system: Mars orbits at r=20000 plus
            // its SOI, so ~43000 units across; 0.02 shows that in one window.
            if (wheel.y != 0) cam.zoom = std.math.clamp(cam.zoom * (1.0 + wheel.y * 0.1), 0.02, 4.0);
        } else if (wheel.x != 0 or wheel.y != 0) {
            // Content follows the fingers: a wheel unit moves the view a
            // fixed number of screen px regardless of zoom.
            const scroll_speed: f32 = 20.0;
            const before = pan_offset.len();
            pan_offset.x -= wheel.x * scroll_speed / cam.zoom;
            pan_offset.y -= wheel.y * scroll_speed / cam.zoom;
            // Selecting a body at the edge of a zoomed-out view can start
            // beyond max_pan, so ratchet: scrolling back in is always
            // allowed, scrolling further out is not.
            const limit = @max(DetailPanel.max_pan, before);
            if (pan_offset.len() > limit) pan_offset = pan_offset.normalized().scale(limit);
        }
        cam.offset = .{
            .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2.0,
            .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2.0,
        };

        // Planet picking + slider drags. Runs before the physics steps so an
        // edit shows up on this very frame.
        detail.handleMouse(&planets, cam, &pan_offset, in.mouse);
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
            // All bodies are kinematic: they move on fixed circles and the
            // ship physics just sees their updated positions each step (see
            // updateOrbits and sim.Planet.acc).
            updateOrbits(&planets, &angles, fixed_dt);
            world.step(fixed_dt, sim_input);
            trail.push(world.ship.pos);
            iss_angle = @mod(iss_angle + iss_omega * fixed_dt, std.math.tau);
            dbg.step_count += 1;
        }
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

            // Draw every copy of the star tile that intersects the view (a
            // copy at tile index k covers k*tile ± tile/2 around the origin).
            {
                const view_w = @as(f32, @floatFromInt(rl.getScreenWidth())) / cam.zoom;
                const view_h = @as(f32, @floatFromInt(rl.getScreenHeight())) / cam.zoom;
                const half = star_tile / 2.0;
                const tx0: i32 = @intFromFloat(@ceil((cam.target.x - view_w / 2.0 - half) / star_tile));
                const tx1: i32 = @intFromFloat(@floor((cam.target.x + view_w / 2.0 + half) / star_tile));
                const ty0: i32 = @intFromFloat(@ceil((cam.target.y - view_h / 2.0 - half) / star_tile));
                const ty1: i32 = @intFromFloat(@floor((cam.target.y + view_h / 2.0 + half) / star_tile));
                var ty = ty0;
                while (ty <= ty1) : (ty += 1) {
                    var tx = tx0;
                    while (tx <= tx1) : (tx += 1) {
                        const ox = @as(f32, @floatFromInt(tx)) * star_tile;
                        const oy = @as(f32, @floatFromInt(ty)) * star_tile;
                        for (stars) |s| rl.drawCircleV(
                            .{ .x = s.x + ox, .y = s.y + oy },
                            1.0,
                            .{ .r = 170, .g = 170, .b = 200, .a = 255 },
                        );
                    }
                }
            }

            trail.draw();

            const sprites: ?*const SpriteSet = switch (theme) {
                .pixelart => &sprite_sets[0],
                .scifi_60s => &sprite_sets[1],
                .classic => null,
            };

            // Sphere-of-influence boundaries (toggle with O). Only the body
            // whose ring you are inside pulls on the ship; outside Earth's
            // ring nothing does.
            if (show_soi) {
                for (planets) |p| {
                    rl.drawRing(v(p.pos), p.soi - 1.5, p.soi + 1.5, 0, 360, 240, .{ .r = 170, .g = 140, .b = 255, .a = 110 });
                }
            }

            if (sprites) |s| {
                // Textures are exported at some fixed world size, so scale
                // each so the sprite spans the body's current physics diameter
                // — that keeps the detail panel's `size` slider honest.
                for (planets, 0..) |p, i| {
                    const tex = s.body(i);
                    s.drawSprite(tex, p.pos, 0, render.spriteScale(s, tex, p.radius));
                }
            } else {
                for (planets) |p| {
                    rl.drawCircleV(v(p.pos), p.radius, .{ .r = 90, .g = 120, .b = 160, .a = 255 });
                    rl.drawCircleLinesV(v(p.pos), p.radius, .{ .r = 150, .g = 190, .b = 230, .a = 255 });
                }
            }

            // ISS orbits Earth with its truss tangent to the orbit.
            const iss_pos = planets[earth_idx].pos.add(Vec2.fromAngle(iss_angle).scale(iss_orbit_r));
            const iss_deg = iss_angle * 180.0 / std.math.pi + 90.0;
            if (sprites) |s| s.drawSprite(s.iss, iss_pos, iss_deg, 1.0) else render.drawIssClassic(iss_pos, iss_deg);

            render.drawShip(world.ship, sprites);
            detail.drawSelection(&planets);

            // Velocity vector (green) for orbital intuition.
            const vel_end = world.ship.pos.add(world.ship.vel.scale(0.4));
            rl.drawLineEx(v(world.ship.pos), v(vel_end), 2.0, .{ .r = 90, .g = 230, .b = 120, .a = 255 });
        }

        render.drawHud(world, theme, detail.selected);
        detail.draw(&planets);

        // Runs before the deferred endDrawing above swaps buffers, so a
        // requested screenshot captures exactly this frame.
        dbg.finishFrame();
    }
}
