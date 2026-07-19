//! Renderer + input layer. All the raylib-specific code lives here; the actual
//! physics is in sim.zig, which knows nothing about raylib.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const sim = @import("sim.zig");
const Vec2 = sim.Vec2;

/// The browser build renders into a fixed-size canvas, so fullscreen handling
/// only applies to native desktop targets.
const is_web = builtin.target.os.tag == .emscripten;

const screen_w = 1000;
const screen_h = 700;

/// Convert a simulation Vec2 into a raylib Vector2.
fn v(p: Vec2) rl.Vector2 {
    return .{ .x = p.x, .y = p.y };
}

/// Visual theme, cycled with `T`. The texture themes load sprites from
/// `resources/<dir>/`; `classic` is the original flat-shape rendering.
const Theme = enum {
    pixelart,
    scifi_60s,
    classic,

    fn next(self: Theme) Theme {
        return switch (self) {
            .pixelart => .scifi_60s,
            .scifi_60s => .classic,
            .classic => .pixelart,
        };
    }

    fn label(self: Theme) [:0]const u8 {
        return switch (self) {
            .pixelart => "pixelart",
            .scifi_60s => "scifi-60s",
            .classic => "classic",
        };
    }
};

/// One theme's sprites. `px_scale` is world pixels per texture pixel: the
/// pixelart theme exports at 1x, scifi-60s at 2x (see art/<theme>/SCALE.txt),
/// so both render Earth at exactly its 280 px world diameter.
const SpriteSet = struct {
    earth: rl.Texture2D,
    moon: rl.Texture2D,
    ship: rl.Texture2D,
    iss: rl.Texture2D,
    px_scale: f32,

    fn load(comptime dir: []const u8, px_scale: f32, filter: rl.TextureFilter) !SpriteSet {
        const set: SpriteSet = .{
            .earth = try rl.loadTexture("resources/" ++ dir ++ "/earth.png"),
            .moon = try rl.loadTexture("resources/" ++ dir ++ "/moon.png"),
            .ship = try rl.loadTexture("resources/" ++ dir ++ "/ship.png"),
            .iss = try rl.loadTexture("resources/" ++ dir ++ "/iss.png"),
            .px_scale = px_scale,
        };
        for ([_]rl.Texture2D{ set.earth, set.moon, set.ship, set.iss }) |t| {
            rl.setTextureFilter(t, filter);
        }
        return set;
    }

    fn unload(self: SpriteSet) void {
        rl.unloadTexture(self.earth);
        rl.unloadTexture(self.moon);
        rl.unloadTexture(self.ship);
        rl.unloadTexture(self.iss);
    }

    /// Draw `tex` centred on `pos`, rotated by `rotation_deg` (0 = facing +x,
    /// matching the sprites' right-facing convention). `extra_scale` enlarges
    /// a sprite beyond the theme's base scale (used to keep the ship readable).
    fn drawSprite(self: SpriteSet, tex: rl.Texture2D, pos: Vec2, rotation_deg: f32, extra_scale: f32) void {
        const tw: f32 = @floatFromInt(tex.width);
        const th: f32 = @floatFromInt(tex.height);
        const w = tw * self.px_scale * extra_scale;
        const h = th * self.px_scale * extra_scale;
        rl.drawTexturePro(
            tex,
            .{ .x = 0, .y = 0, .width = tw, .height = th },
            .{ .x = pos.x, .y = pos.y, .width = w, .height = h },
            .{ .x = w / 2.0, .y = h / 2.0 },
            rotation_deg,
            rl.Color.white,
        );
    }
};

/// Fixed-size ring buffer of recent ship positions, drawn as a fading trail.
const Trail = struct {
    const cap = 480;
    points: [cap]Vec2 = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Trail, p: Vec2) void {
        self.points[self.head] = p;
        self.head = (self.head + 1) % cap;
        if (self.len < cap) self.len += 1;
    }

    fn clear(self: *Trail) void {
        self.head = 0;
        self.len = 0;
    }

    fn draw(self: *const Trail) void {
        if (self.len < 2) return;
        var i: usize = 1;
        while (i < self.len) : (i += 1) {
            // Walk from oldest to newest so alpha ramps up along the tail.
            const a_idx = (self.head + cap - self.len + i - 1) % cap;
            const b_idx = (self.head + cap - self.len + i) % cap;
            const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(self.len));
            const alpha: u8 = @intFromFloat(t * 160.0);
            rl.drawLineV(v(self.points[a_idx]), v(self.points[b_idx]), .{ .r = 120, .g = 200, .b = 255, .a = alpha });
        }
    }
};

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

    // Native builds start fullscreen at the monitor's native resolution.
    if (!is_web) {
        const monitor = rl.getCurrentMonitor();
        rl.setWindowSize(rl.getMonitorWidth(monitor), rl.getMonitorHeight(monitor));
        rl.toggleFullscreen();
    }

    // --- Sprites & theme ---------------------------------------------------
    // Pixelart samples nearest-neighbour so its pixels stay crisp; scifi-60s
    // is a 2x export drawn at half size, so it gets bilinear filtering.
    var theme: Theme = .pixelart;
    const sprite_sets = [_]SpriteSet{
        try SpriteSet.load("pixelart", 2.0, .point),
        try SpriteSet.load("scifi-60s", 1.0, .bilinear),
    };
    defer for (sprite_sets) |s| s.unload();

    // --- World setup -------------------------------------------------------
    var planets = [_]sim.Planet{
        .{ .pos = .{ .x = 0, .y = 0 }, .mass = 8000, .radius = 140 },
        .{ .pos = .{ .x = 1050, .y = -440 }, .mass = 3000, .radius = 84 },
    };

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
    var stars: [500]rl.Vector2 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rng = prng.random();
    for (&stars) |*s| {
        s.* = .{
            .x = rng.float(f32) * 4000.0 - 2000.0,
            .y = rng.float(f32) * 4000.0 - 2000.0,
        };
    }

    var trail: Trail = .{};

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
        }
        if (!is_web and rl.isKeyPressed(.f)) rl.toggleFullscreen();
        if (rl.isKeyPressed(.t)) theme = theme.next();

        // Zoom on scroll, keep camera centred on the current window size.
        const wheel = rl.getMouseWheelMove();
        if (wheel != 0) cam.zoom = std.math.clamp(cam.zoom * (1.0 + wheel * 0.1), 0.15, 4.0);
        cam.offset = .{
            .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2.0,
            .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2.0,
        };

        // Advance physics in fixed steps, decoupled from render framerate.
        accumulator += rl.getFrameTime();
        if (accumulator > 0.25) accumulator = 0.25; // avoid spiral of death
        while (accumulator >= fixed_dt) : (accumulator -= fixed_dt) {
            world.step(fixed_dt, input);
            trail.push(world.ship.pos);
            iss_angle = @mod(iss_angle + iss_omega * fixed_dt, std.math.tau);
        }
        cam.target = v(world.ship.pos);

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

            if (sprites) |s| {
                s.drawSprite(s.earth, planets[0].pos, 0, 1.0);
                s.drawSprite(s.moon, planets[1].pos, 0, 1.0);
            } else {
                for (planets) |p| {
                    rl.drawCircleV(v(p.pos), p.radius, .{ .r = 90, .g = 120, .b = 160, .a = 255 });
                    rl.drawCircleLinesV(v(p.pos), p.radius, .{ .r = 150, .g = 190, .b = 230, .a = 255 });
                }
            }

            // ISS orbits Earth with its truss tangent to the orbit.
            const iss_pos = planets[0].pos.add(Vec2.fromAngle(iss_angle).scale(iss_orbit_r));
            const iss_deg = iss_angle * 180.0 / std.math.pi + 90.0;
            if (sprites) |s| s.drawSprite(s.iss, iss_pos, iss_deg, 1.0) else drawIssClassic(iss_pos, iss_deg);

            drawShip(world.ship, sprites);

            // Velocity vector (green) for orbital intuition.
            const vel_end = world.ship.pos.add(world.ship.vel.scale(0.4));
            rl.drawLineEx(v(world.ship.pos), v(vel_end), 2.0, .{ .r = 90, .g = 230, .b = 120, .a = 255 });
        }

        drawHud(world, theme);
    }
}

/// The ship renders larger than the theme's base scale so it stays readable
/// against the (much bigger) planets.
const ship_extra_scale: f32 = 1.5;

fn drawShip(ship: sim.Ship, sprites: ?*const SpriteSet) void {
    const deg = ship.angle * 180.0 / std.math.pi;

    // Exhaust flame behind the ship while thrusting. The flame belongs to the
    // engine, not the sprites (see art/README.md), so it's drawn for every theme.
    if (ship.thrusting) {
        const back = ship.pos.sub(Vec2.fromAngle(ship.angle).scale(30.0));
        rl.drawCircleV(v(back), 9.0, .{ .r = 255, .g = 170, .b = 40, .a = 255 });
    }

    if (sprites) |s| {
        s.drawSprite(s.ship, ship.pos, deg, ship_extra_scale);
    } else {
        // Classic body: a triangle whose leading vertex points along the heading.
        rl.drawPoly(v(ship.pos), 3, 26.0, deg, .{ .r = 235, .g = 235, .b = 245, .a = 255 });
        rl.drawPolyLines(v(ship.pos), 3, 26.0, deg, .{ .r = 120, .g = 140, .b = 170, .a = 255 });
    }
}

/// Flat-shape ISS for the classic theme: solar panels, truss, centre module.
/// Footprint matches the sprite versions at their doubled world scale.
fn drawIssClassic(pos: Vec2, rotation_deg: f32) void {
    rl.drawRectanglePro(
        .{ .x = pos.x, .y = pos.y, .width = 44, .height = 28 },
        .{ .x = 22, .y = 14 },
        rotation_deg,
        .{ .r = 45, .g = 75, .b = 150, .a = 255 },
    );
    rl.drawRectanglePro(
        .{ .x = pos.x, .y = pos.y, .width = 56, .height = 6 },
        .{ .x = 28, .y = 3 },
        rotation_deg,
        .{ .r = 200, .g = 205, .b = 215, .a = 255 },
    );
    rl.drawCircleV(v(pos), 6.0, .{ .r = 230, .g = 232, .b = 240, .a = 255 });
}

var hud_buf: [128]u8 = undefined;

fn drawHud(world: sim.World, theme: Theme) void {
    const ship = world.ship;
    const speed = ship.vel.len();
    // Altitude above the primary planet's surface.
    const p0 = world.planets[0];
    const altitude = ship.pos.sub(p0.pos).len() - p0.radius;

    rl.drawFPS(10, 10);

    const speed_txt = std.fmt.bufPrintZ(&hud_buf, "speed: {d:.1}   altitude: {d:.0}   theme: {s}", .{ speed, altitude, theme.label() }) catch "";
    rl.drawText(speed_txt, 10, 34, 20, .{ .r = 200, .g = 220, .b = 240, .a = 255 });

    const controls = if (is_web)
        "W/Up: thrust   A/D or Left/Right: turn   wheel: zoom   R: reset   T: theme"
    else
        "W/Up: thrust   A/D or Left/Right: turn   wheel: zoom   R: reset   T: theme   F: fullscreen";
    rl.drawText(
        controls,
        10,
        rl.getScreenHeight() - 28, // live height so it sits at the bottom in fullscreen
        18,
        .{ .r = 150, .g = 165, .b = 190, .a = 255 },
    );
}
