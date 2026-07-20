//! Drawing layer: themes, sprite sets, the ship trail, and the screen-space
//! HUD. Everything raylib-visual that isn't the detail panel lives here.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const sim = @import("sim.zig");
const Vec2 = sim.Vec2;

const is_web = builtin.target.os.tag == .emscripten;

/// Convert a simulation Vec2 into a raylib Vector2.
pub fn v(p: Vec2) rl.Vector2 {
    return .{ .x = p.x, .y = p.y };
}

/// Visual theme, cycled with `T`. The texture themes load sprites from
/// `resources/<dir>/`; `classic` is the original flat-shape rendering.
pub const Theme = enum {
    pixelart,
    scifi_60s,
    classic,

    pub fn next(self: Theme) Theme {
        return switch (self) {
            .pixelart => .scifi_60s,
            .scifi_60s => .classic,
            .classic => .pixelart,
        };
    }

    pub fn label(self: Theme) [:0]const u8 {
        return switch (self) {
            .pixelart => "pixelart",
            .scifi_60s => "scifi-60s",
            .classic => "classic",
        };
    }
};

/// One theme's sprites. `px_scale` is world pixels per texture pixel, i.e.
/// 1 / `art/<theme>/SCALE.txt`: scifi-60s exports at world size (scale 1),
/// pixelart at 2× (scale 2 → 0.5 world px per texel). With that applied a
/// planet texture spans exactly its physics diameter — Earth renders at its
/// full 280 px world diameter and collisions line up.
pub const SpriteSet = struct {
    earth: rl.Texture2D,
    moon: rl.Texture2D,
    ship: rl.Texture2D,
    iss: rl.Texture2D,
    px_scale: f32,

    pub fn load(comptime dir: []const u8, px_scale: f32, filter: rl.TextureFilter) !SpriteSet {
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

    pub fn unload(self: SpriteSet) void {
        rl.unloadTexture(self.earth);
        rl.unloadTexture(self.moon);
        rl.unloadTexture(self.ship);
        rl.unloadTexture(self.iss);
    }

    /// Draw `tex` centred on `pos`, rotated by `rotation_deg` (0 = facing +x,
    /// matching the sprites' right-facing convention). `extra_scale` enlarges
    /// a sprite beyond the theme's base scale (used to keep the ship readable).
    pub fn drawSprite(self: SpriteSet, tex: rl.Texture2D, pos: Vec2, rotation_deg: f32, extra_scale: f32) void {
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

/// Extra scale that makes `tex` span `radius * 2` world pixels.
pub fn spriteScale(s: *const SpriteSet, tex: rl.Texture2D, radius: f32) f32 {
    return radius * 2.0 / (@as(f32, @floatFromInt(tex.width)) * s.px_scale);
}

/// Fixed-size ring buffer of recent ship positions, drawn as a fading trail.
pub const Trail = struct {
    const cap = 4000;
    points: [cap]Vec2 = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *Trail, p: Vec2) void {
        self.points[self.head] = p;
        self.head = (self.head + 1) % cap;
        if (self.len < cap) self.len += 1;
    }

    pub fn clear(self: *Trail) void {
        self.head = 0;
        self.len = 0;
    }

    pub fn draw(self: *const Trail) void {
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

/// The ship renders larger than the theme's base scale so it stays readable
/// against the (much bigger) planets.
const ship_extra_scale: f32 = 1.5;

pub fn drawShip(ship: sim.Ship, sprites: ?*const SpriteSet) void {
    const deg = ship.angle * 180.0 / std.math.pi;

    // Exhaust flame behind the ship while thrusting. The flame belongs to the
    // engine, not the sprites (see art/README.md), so it's drawn for every theme.
    const fwd = Vec2.fromAngle(ship.angle);
    if (ship.thrusting) {
        const back = ship.pos.sub(fwd.scale(30.0));
        rl.drawCircleV(v(back), 9.0, .{ .r = 255, .g = 170, .b = 40, .a = 255 });
    }

    // Retro burn: two small thrusters either side of the nose, firing forward.
    if (ship.braking) {
        const side: Vec2 = .{ .x = -fwd.y, .y = fwd.x };
        const nose = ship.pos.add(fwd.scale(24.0));
        for ([_]f32{ -1, 1 }) |s| {
            const jet = nose.add(side.scale(s * 7.0));
            rl.drawCircleV(v(jet), 5.0, .{ .r = 120, .g = 200, .b = 255, .a = 255 });
        }
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
/// Footprint roughly matches the sprite versions' world size.
pub fn drawIssClassic(pos: Vec2, rotation_deg: f32) void {
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

var hud_buf: [192]u8 = undefined;

pub fn drawHud(world: sim.World, theme: Theme, followed: ?usize) void {
    const ship = world.ship;
    const speed = ship.vel.len();
    // Altitude above the surface of whichever body's SOI the ship is in;
    // relative to Earth when coasting through gravity-free deep space.
    const soi_idx = world.dominantIndex(ship.pos);
    const soi_name: [:0]const u8 = if (soi_idx) |i| (if (i == 0) "earth" else "moon") else "deep space";
    const soi_body = world.planets[soi_idx orelse 0];
    const altitude = ship.pos.sub(soi_body.pos).len() - soi_body.radius;

    rl.drawFPS(10, 10);

    const follow: [:0]const u8 = if (followed) |i| (if (i == 0) "earth" else "moon") else "ship";
    const speed_txt = std.fmt.bufPrintZ(&hud_buf, "speed: {d:.1}   altitude: {d:.0}   soi: {s}   theme: {s}   follow: {s}", .{ speed, altitude, soi_name, theme.label(), follow }) catch "";
    rl.drawText(speed_txt, 10, 34, 20, .{ .r = 200, .g = 220, .b = 240, .a = 255 });

    const controls = if (is_web)
        "W/Up: thrust   S/Down: brake   A/D or Left/Right: turn   wheel: zoom   drag: pan   O: SOI   R: reset   T: theme   click a planet: details + follow it"
    else
        "W/Up: thrust   S/Down: brake   A/D or Left/Right: turn   wheel: zoom   drag: pan   O: SOI   R: reset   T: theme   F: fullscreen   click a planet: details + follow it";
    rl.drawText(
        controls,
        10,
        rl.getScreenHeight() - 28, // live height so it sits at the bottom in fullscreen
        18,
        .{ .r = 150, .g = 165, .b = 190, .a = 255 },
    );
}
