//! Entry point and game loop. The raylib-specific code is spread across the
//! render layer (render.zig), the detail panel (detail_panel.zig) and this
//! file; the actual physics is in sim.zig, which knows nothing about raylib.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const sim = @import("sim.zig");
const Vec2 = sim.Vec2;
const cfg = @import("config.zig");
const input_shim = @import("input.zig");
const render = @import("render.zig");
const Theme = render.Theme;
const SpriteSet = render.SpriteSet;
const Trail = render.Trail;
const DetailPanel = @import("detail_panel.zig").DetailPanel;
const v = render.v;

/// The browser build renders into a fixed-size canvas, so fullscreen handling
/// only applies to native desktop targets.
const is_web = builtin.target.os.tag == .emscripten;

const screen_w = 1000;
const screen_h = 700;

/// `main` must not return errors: the std error-printing path that would
/// handle them pulls in child-process code that doesn't compile for
/// wasm32-emscripten (same std-lib issue that breaks Debug web builds).
pub fn main() void {
    run() catch |err| rl.traceLog(.err, "fatal: %s", .{@errorName(err).ptr});
}

fn run() !void {
    rl.setConfigFlags(.{ .vsync_hint = true, .window_resizable = true, .msaa_4x_hint = true });
    rl.initWindow(screen_w, screen_h, "space-slop");
    defer rl.closeWindow();
    // Catch clicks shorter than a frame (trackpad taps) that raylib's own
    // per-frame polling loses; see input.zig.
    input_shim.init();

    // Native builds start fullscreen at the monitor's native resolution.
    if (!is_web) {
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
    // Gravity uses arcade patched conics (see sim.gravityAt): inside the
    // moon's sphere of influence only the moon pulls, everywhere else only
    // Earth does, so orbits around both bodies are clean stable ellipses.
    // The moon is small on screen but pulls hard (mass on par with what a
    // much larger body would have): a deep well inside a tight 400 px SOI
    // bubble, plus the sim's capture assist, means a ship that coasts in
    // slowly settles into orbit on its own — while fast flybys slingshot
    // through undisturbed and Earth orbits below ~1100 px never feel the
    // moon at all. Beyond Earth's SOI there is no gravity: deep space.
    // Tuning values come from planets.zon (see config.zig); positions stay
    // here because the moon's is overwritten by its scripted orbit every frame.
    var config = cfg.Config.load();
    var planets = [_]sim.Planet{
        .{ .pos = .{ .x = 0, .y = 0 }, .mass = config.earth.mass, .radius = config.earth.radius, .soi = config.earth.soi, .core = config.earth.core },
        .{ .pos = .{ .x = 1383, .y = -580 }, .mass = config.moon.mass, .radius = config.moon.radius, .soi = config.moon.soi, .core = config.moon.core },
    };

    // The moon slowly circles Earth: it covers its own diameter in ~7 s —
    // clearly visible, but slow next to ship speeds (~10% of the physically
    // correct orbital rate), so leading the moon on an outbound flight stays
    // easy and its SOI doesn't run away from a ship trying to be captured.
    const moon_orbit_r = planets[1].pos.sub(planets[0].pos).len();
    const moon_omega: f32 = 0.008; // rad/s
    var moon_angle: f32 = std.math.atan2(planets[1].pos.y, planets[1].pos.x);

    const start_r: f32 = 340;
    const orbit_speed = sim.World.circularOrbitSpeed(planets[0].mass, start_r);
    var world: sim.World = .{
        .planets = &planets,
        .ship = .{
            .pos = .{ .x = start_r, .y = 0 },
            .vel = .{ .x = 0, .y = orbit_speed }, // counter-clockwise circular orbit
            .angle = -std.math.pi / 2.0, // nose pointing "up" (-y)
        },
    };
    const initial_ship = world.ship;

    // Decorative ISS on a low circular orbit around the primary planet. It
    // lives entirely in the render layer and never affects the physics. Its
    // angular speed starts from the physically correct value for its altitude,
    // then gets slowed by an arcade factor so the orbit reads at a glance.
    const iss_orbit_r: f32 = 190;
    const iss_speed_scale: f32 = 0.45;
    const iss_omega = iss_speed_scale * sim.World.circularOrbitSpeed(planets[0].mass, iss_orbit_r) / iss_orbit_r;
    var iss_angle: f32 = 0;

    // Static starfield in world space, generated once with a fixed seed.
    // Wide enough to cover the moon's whole orbit (radius ~2200).
    var stars: [1500]rl.Vector2 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rng = prng.random();
    for (&stars) |*s| {
        s.* = .{
            .x = rng.float(f32) * 7000.0 - 3500.0,
            .y = rng.float(f32) * 7000.0 - 3500.0,
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

    // --- Fixed-timestep loop ----------------------------------------------
    const fixed_dt: f32 = 1.0 / 120.0;
    var accumulator: f32 = 0;

    while (!rl.windowShouldClose()) {
        // Input -> simulation intent
        var input: sim.Input = .{};
        if (rl.isKeyDown(.a) or rl.isKeyDown(.left)) input.turn -= 1;
        if (rl.isKeyDown(.d) or rl.isKeyDown(.right)) input.turn += 1;
        input.thrust = rl.isKeyDown(.w) or rl.isKeyDown(.up);
        if (rl.isKeyPressed(.r)) {
            world.ship = initial_ship;
            trail.clear();
            pan_offset = .{};
        }
        if (!is_web and rl.isKeyPressed(.f)) rl.toggleFullscreen();
        if (rl.isKeyPressed(.t)) theme = theme.next();
        if (rl.isKeyPressed(.o)) show_soi = !show_soi;

        // Two-finger scroll pans the view; hold cmd (super) to zoom instead.
        // Keep the camera centred on the current window size.
        const wheel = rl.getMouseWheelMoveV();
        const zoom_modifier = rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);
        if (zoom_modifier) {
            if (wheel.y != 0) cam.zoom = std.math.clamp(cam.zoom * (1.0 + wheel.y * 0.1), 0.15, 4.0);
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
        detail.handleMouse(&planets, cam, &pan_offset, input_shim.poll());
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

        // Advance physics in fixed steps, decoupled from render framerate.
        accumulator += rl.getFrameTime();
        if (accumulator > 0.25) accumulator = 0.25; // avoid spiral of death
        while (accumulator >= fixed_dt) : (accumulator -= fixed_dt) {
            // The moon is kinematic: it moves on a fixed circle and the ship
            // physics just sees its updated position each step. Its frame
            // acceleration (centripetal, toward Earth) lets ships in its SOI
            // ride along with it (see sim.Planet.acc).
            moon_angle = @mod(moon_angle + moon_omega * fixed_dt, std.math.tau);
            const moon_dir = Vec2.fromAngle(moon_angle);
            planets[1].pos = planets[0].pos.add(moon_dir.scale(moon_orbit_r));
            planets[1].vel = (Vec2{ .x = -moon_dir.y, .y = moon_dir.x }).scale(moon_omega * moon_orbit_r);
            planets[1].acc = moon_dir.scale(-moon_omega * moon_omega * moon_orbit_r);
            world.step(fixed_dt, input);
            trail.push(world.ship.pos);
            iss_angle = @mod(iss_angle + iss_omega * fixed_dt, std.math.tau);
        }
        // A selected planet becomes the frame of reference: the camera rides
        // along with it, so the ship's motion reads relative to that body.
        // Deselecting (click it again, or click empty space) returns to the
        // ship. Scrolling pans the view around whichever body is followed.
        const follow_pos = if (detail.selected) |idx| planets[idx].pos else world.ship.pos;
        cam.target = v(follow_pos.add(pan_offset));

        // --- Draw ----------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 8, .g = 10, .b = 20, .a = 255 });

        {
            rl.beginMode2D(cam);
            defer rl.endMode2D();

            for (stars) |s| rl.drawCircleV(s, 1.0, .{ .r = 170, .g = 170, .b = 200, .a = 255 });

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
                // Both textures are exported at some fixed world size, so scale
                // each so the sprite spans the body's current physics diameter
                // — that keeps the detail panel's `size` slider honest.
                s.drawSprite(s.earth, planets[0].pos, 0, render.spriteScale(s, s.earth, planets[0].radius));
                s.drawSprite(s.moon, planets[1].pos, 0, render.spriteScale(s, s.moon, planets[1].radius));
            } else {
                for (planets) |p| {
                    rl.drawCircleV(v(p.pos), p.radius, .{ .r = 90, .g = 120, .b = 160, .a = 255 });
                    rl.drawCircleLinesV(v(p.pos), p.radius, .{ .r = 150, .g = 190, .b = 230, .a = 255 });
                }
            }

            // ISS orbits Earth with its truss tangent to the orbit.
            const iss_pos = planets[0].pos.add(Vec2.fromAngle(iss_angle).scale(iss_orbit_r));
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
    }
}
