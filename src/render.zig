//! Drawing layer: themes, sprite sets, the ship trail, and the screen-space
//! HUD. Everything raylib-visual that isn't the detail panel lives here.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const sim = @import("sim.zig");
const Vec2 = sim.Vec2;
const cfg = @import("config.zig");

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
    sun: rl.Texture2D,
    mercury: rl.Texture2D,
    venus: rl.Texture2D,
    earth: rl.Texture2D,
    moon: rl.Texture2D,
    mars: rl.Texture2D,
    jupiter: rl.Texture2D,
    saturn: rl.Texture2D,
    uranus: rl.Texture2D,
    neptune: rl.Texture2D,
    ship: rl.Texture2D,
    iss: rl.Texture2D,
    px_scale: f32,

    pub fn load(comptime dir: []const u8, px_scale: f32, filter: rl.TextureFilter) !SpriteSet {
        const set: SpriteSet = .{
            .sun = try rl.loadTexture("resources/" ++ dir ++ "/sun.png"),
            .mercury = try rl.loadTexture("resources/" ++ dir ++ "/mercury.png"),
            .venus = try rl.loadTexture("resources/" ++ dir ++ "/venus.png"),
            .earth = try rl.loadTexture("resources/" ++ dir ++ "/earth.png"),
            .moon = try rl.loadTexture("resources/" ++ dir ++ "/moon.png"),
            .mars = try rl.loadTexture("resources/" ++ dir ++ "/mars.png"),
            .jupiter = try rl.loadTexture("resources/" ++ dir ++ "/jupiter.png"),
            .saturn = try rl.loadTexture("resources/" ++ dir ++ "/saturn.png"),
            .uranus = try rl.loadTexture("resources/" ++ dir ++ "/uranus.png"),
            .neptune = try rl.loadTexture("resources/" ++ dir ++ "/neptune.png"),
            .ship = try rl.loadTexture("resources/" ++ dir ++ "/ship.png"),
            .iss = try rl.loadTexture("resources/" ++ dir ++ "/iss.png"),
            .px_scale = px_scale,
        };
        for (set.all()) |t| rl.setTextureFilter(t, filter);
        return set;
    }

    pub fn unload(self: SpriteSet) void {
        for (self.all()) |t| rl.unloadTexture(t);
    }

    fn all(self: SpriteSet) [12]rl.Texture2D {
        return .{ self.sun, self.mercury, self.venus, self.earth, self.moon, self.mars, self.jupiter, self.saturn, self.uranus, self.neptune, self.ship, self.iss };
    }

    /// Texture of the world's body at `idx` — canonical body order (cfg.names).
    pub fn body(self: *const SpriteSet, idx: usize) rl.Texture2D {
        return switch (idx) {
            0 => self.sun,
            1 => self.mercury,
            2 => self.venus,
            3 => self.earth,
            4 => self.moon,
            5 => self.mars,
            6 => self.jupiter,
            7 => self.saturn,
            8 => self.uranus,
            else => self.neptune,
        };
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

/// Repeating starfield. A single static field spanning the whole solar system
/// (~50k px across) would need tens of thousands of stars, so instead one tile
/// is generated with a fixed seed and stamped across the view: every copy that
/// intersects the camera is drawn.
///
/// The tile's *world* size doubles as you zoom out, so the number of copies on
/// screen — and hence the stars drawn per frame — stays bounded at every zoom
/// level. Without that, the fully zoomed-out view (zoom 0.02, ~50k px across)
/// stamps ~9x9 tiles, i.e. >100k stars per frame, and the frame rate collapses.
pub const Starfield = struct {
    const count = 1500;
    /// World size of one tile at zoom 1.
    const base_tile: f32 = 7000.0;

    points: [count]rl.Vector2 = undefined,

    pub fn init(seed: u64) Starfield {
        var self: Starfield = .{};
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        for (&self.points) |*s| {
            s.* = .{
                .x = rng.float(f32) * base_tile - base_tile / 2.0,
                .y = rng.float(f32) * base_tile - base_tile / 2.0,
            };
        }
        return self;
    }

    pub fn draw(self: *const Starfield, cam: rl.Camera2D) void {
        const view_w = @as(f32, @floatFromInt(rl.getScreenWidth())) / cam.zoom;
        const view_h = @as(f32, @floatFromInt(rl.getScreenHeight())) / cam.zoom;

        // Grow the tile in powers of two until one copy covers the view; that
        // caps the stamp grid at 2x2 (plus edges) whatever the zoom. Powers of
        // two keep the choice stable, so the field only reshuffles on the rare
        // frame that crosses a doubling.
        var tile = base_tile;
        while (tile < @max(view_w, view_h)) tile *= 2.0;
        const spread = tile / base_tile; // stretch tile-local coords to match
        const half = tile / 2.0;

        // Stars are points, not world-scale objects: size them in screen px so
        // they stay visible zoomed out. Rectangles, not circles — at 1-2 px the
        // shapes are indistinguishable and a rect is two triangles, not 36.
        const px = 1.5 / cam.zoom;
        const color: rl.Color = .{ .r = 170, .g = 170, .b = 200, .a = 255 };

        const tx0: i32 = @intFromFloat(@ceil((cam.target.x - view_w / 2.0 - half) / tile));
        const tx1: i32 = @intFromFloat(@floor((cam.target.x + view_w / 2.0 + half) / tile));
        const ty0: i32 = @intFromFloat(@ceil((cam.target.y - view_h / 2.0 - half) / tile));
        const ty1: i32 = @intFromFloat(@floor((cam.target.y + view_h / 2.0 + half) / tile));
        var ty = ty0;
        while (ty <= ty1) : (ty += 1) {
            var tx = tx0;
            while (tx <= tx1) : (tx += 1) {
                const ox = @as(f32, @floatFromInt(tx)) * tile;
                const oy = @as(f32, @floatFromInt(ty)) * tile;
                for (self.points) |s| rl.drawRectangleV(
                    .{ .x = s.x * spread + ox - px / 2.0, .y = s.y * spread + oy - px / 2.0 },
                    .{ .x = px, .y = px },
                    color,
                );
            }
        }
    }
};

/// Faint line tracing a body's scripted Kepler ellipse (see `orbits` in
/// main.zig): semi-major axis `a`, eccentricity `e`, periapsis direction
/// `peri`, with the parent's current position at `focus`. Drawn under
/// everything else, so it reads as background structure: the shape of the
/// system at a glance, and where a planet's path will take it while you fly
/// to it.
///
/// Only drawn while the ellipse is actually legible on screen — see
/// `orbitFade`. Flying around Earth you get the moon's path and nothing else;
/// zoomed right out you get the heliocentric orbits and not the moon's knot.
pub fn drawOrbitPath(focus: Vec2, a: f32, e: f32, peri: f32, body_idx: usize, cam: rl.Camera2D) void {
    // A path is only worth drawing while it reads *as an orbit*, which is a
    // question about its size on screen, not in the world. `orbitFade` gives
    // the strength for the current apparent radius; zero means skip it.
    const r_px = a * cam.zoom;
    const fade = orbitFade(r_px);
    if (fade <= 0) return;

    // Hairline in screen space: a world-thickness line disappears zoomed out
    // and swells into a fat band zoomed in.
    const thickness = 1.5 / cam.zoom;
    // Segments from the apparent size — a path that fills the window shouldn't
    // read as a polygon, and a small one shouldn't cost hundreds of quads.
    const segments: usize = @intFromFloat(std.math.clamp(r_px * 0.5, 48, 512));
    var color = edge_colors[body_idx];
    color.a = @intFromFloat(orbit_alpha * fade);

    // The parent sits at a focus, so the ellipse's geometric centre is offset
    // a·e toward apoapsis; sweep the ellipse in its own frame and rotate out.
    const minor = a * @sqrt(1 - e * e);
    const center = focus.add(Vec2.fromAngle(peri).scale(-a * e));
    var prev: Vec2 = undefined;
    var s: usize = 0;
    while (s <= segments) : (s += 1) {
        const t = std.math.tau * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments));
        const pt = center.add((Vec2{ .x = a * @cos(t), .y = minor * @sin(t) }).rotated(peri));
        if (s > 0) rl.drawLineEx(v(prev), v(pt), thickness, color);
        prev = pt;
    }
}

/// Alpha at full strength. Faint on purpose — the paths are there to be
/// noticed when you look for them, not to compete with the bodies.
const orbit_alpha: f32 = 42.0;
/// Apparent radius (screen px) at which a path is an indistinguishable knot
/// around its parent, and the size it must reach to draw at full strength.
const orbit_tiny_px: f32 = 55.0;
const orbit_small_px: f32 = 120.0;
/// The same two points at the other end, as multiples of the view's
/// half-diagonal: once the circle is much larger than the window, all that's
/// on screen is a faintly bent line crossing it, which tells you nothing about
/// the orbit and just adds clutter to a zoomed-in view.
const orbit_wide_view: f32 = 1.2;
const orbit_huge_view: f32 = 2.0;

/// How strongly to draw an orbit whose on-screen radius is `r_px`: 1 inside
/// the useful band, 0 outside it, ramping between so paths fade in and out as
/// you zoom rather than popping.
fn orbitFade(r_px: f32) f32 {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    const view = @sqrt(sw * sw + sh * sh) / 2.0; // corner-to-centre distance
    const small = std.math.clamp((r_px - orbit_tiny_px) / (orbit_small_px - orbit_tiny_px), 0, 1);
    const huge = std.math.clamp((orbit_huge_view * view - r_px) / ((orbit_huge_view - orbit_wide_view) * view), 0, 1);
    return @min(small, huge);
}

/// Fixed-size ring buffer of recent ship positions, drawn as a fading trail.
/// Each point is stored relative to the SOI body that dominated it when it was
/// recorded (absolute when in deep space), so the trail rides along with the
/// moving planet instead of being left behind in world space. Points keep
/// their anchor forever, so crossing an SOI boundary never snaps the trail.
/// In the outer band of an SOI a point is stored in the enclosing frame too
/// and the two are blended, so the seam deforms as a smooth curve instead of
/// kinking at the segment where the anchor switches.
pub const Trail = struct {
    const cap = 4000;
    /// Fraction of the SOI radius where blending toward the enclosing frame
    /// begins; at the edge itself a point rides the enclosing frame entirely,
    /// which matches the first point recorded on the other side.
    const blend_band = 0.8;

    const Point = struct {
        /// Offset from the anchor body (absolute position when anchor is null).
        off: Vec2,
        /// Offset from the enclosing body (absolute when enclosing is null).
        off_outer: Vec2,
        anchor: ?usize,
        enclosing: ?usize,
        /// 1 = fully anchor frame, 0 = fully enclosing frame.
        blend: f32,
    };

    points: [cap]Point = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *Trail, p: Vec2, world: *const sim.World) void {
        var pt = Point{ .off = p, .off_outer = p, .anchor = null, .enclosing = null, .blend = 1 };
        if (world.dominantIndex(p)) |a| {
            const body = world.planets[a];
            pt.anchor = a;
            pt.off = p.sub(body.pos);
            const edge = p.sub(body.pos).len() / body.soi;
            const raw = std.math.clamp((1.0 - edge) / (1.0 - blend_band), 0.0, 1.0);
            pt.blend = raw * raw * (3.0 - 2.0 * raw);
            if (pt.blend < 1.0) {
                pt.enclosing = world.enclosingIndex(p, a);
                if (pt.enclosing) |e| pt.off_outer = p.sub(world.planets[e].pos);
            }
        }
        self.points[self.head] = pt;
        self.head = (self.head + 1) % cap;
        if (self.len < cap) self.len += 1;
    }

    pub fn clear(self: *Trail) void {
        self.head = 0;
        self.len = 0;
    }

    fn worldPos(self: *const Trail, idx: usize, planets: []const sim.Planet) Vec2 {
        const pt = self.points[idx];
        const inner = if (pt.anchor) |a| planets[a].pos.add(pt.off) else pt.off;
        if (pt.blend >= 1.0) return inner;
        const outer = if (pt.enclosing) |e| planets[e].pos.add(pt.off_outer) else pt.off_outer;
        return outer.add(inner.sub(outer).scale(pt.blend));
    }

    pub fn draw(self: *const Trail, planets: []const sim.Planet) void {
        if (self.len < 2) return;
        var i: usize = 1;
        var a = self.worldPos((self.head + cap - self.len) % cap, planets);
        while (i < self.len) : (i += 1) {
            // Walk from oldest to newest so alpha ramps up along the tail.
            const b_idx = (self.head + cap - self.len + i) % cap;
            const b = self.worldPos(b_idx, planets);
            const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(self.len));
            const alpha: u8 = @intFromFloat(t * 160.0);
            rl.drawLineV(v(a), v(b), .{ .r = 120, .g = 200, .b = 255, .a = alpha });
            a = b;
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

// Fragment shader for the flare front: procedural plasma inside the travelling
// band — angular filaments that writhe over the flare's lifetime plus ripples
// racing outward — instead of a solid shape. Fragment world position is
// reconstructed from the quad's texcoords, so it works at any camera zoom.
// Animated by the sim clock (u_age), so pause/step hold the picture still.
const flare_fs_body =
    \\uniform vec2 u_origin;
    \\uniform vec2 u_quad_min;
    \\uniform vec2 u_quad_size;
    \\uniform float u_angle;
    \\uniform float u_half;
    \\uniform float u_inner;
    \\uniform float u_outer;
    \\uniform float u_age;
    \\
    \\float hash(float n) { return fract(sin(n) * 43758.5453123); }
    \\float vnoise(float x) {
    \\    float i = floor(x);
    \\    float f = fract(x);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    return mix(hash(i), hash(i + 1.0), f);
    \\}
    \\
    \\vec4 flareColor(vec2 tc) {
    \\    vec2 world = u_quad_min + tc * u_quad_size;
    \\    vec2 d = world - u_origin;
    \\    float r = length(d);
    \\    float dth = atan(sin(atan(d.y, d.x) - u_angle), cos(atan(d.y, d.x) - u_angle));
    \\    float an = abs(dth) / u_half;                    // 0 centre .. 1 wedge edge
    \\    if (an > 1.0 || r < u_inner || r > u_outer) discard;
    \\    float u = (r - u_inner) / (u_outer - u_inner);   // 0 trailing .. 1 leading
    \\
    \\    // Plasma filaments: two octaves of angular value noise drifting in
    \\    // opposite directions so the streaks writhe rather than rotate; the
    \\    // second octave shears with radius so filaments slant outward.
    \\    float streak = 0.65 * vnoise(dth * 28.0 + u_age * 1.7)
    \\                 + 0.35 * vnoise(dth * 71.0 + r * 0.0006 - u_age * 2.9);
    \\    streak = pow(streak, 1.5);
    \\
    \\    // Energy ripples racing outward through the band, faster than the
    \\    // front itself, skewed by angle so they read as bursts, not rings.
    \\    float ripple = 0.65 + 0.35 * sin(r * 0.012 - u_age * 14.0 + dth * 6.0);
    \\
    \\    float edge = smoothstep(1.0, 0.55, an);          // soften wedge edges
    \\    float tail = smoothstep(0.0, 0.45, u);           // fade in from the back
    \\    float lead = 0.9 * pow(smoothstep(0.6, 1.0, u), 1.4); // brighter crest
    \\
    \\    float body = 0.55 * ripple * (0.25 + 0.75 * streak);
    \\    float glow = clamp(edge * tail * (body + lead * (0.6 + 0.8 * streak)) * 1.8, 0.0, 1.0);
    \\    vec3 col = mix(vec3(1.0, 0.55, 0.2), vec3(1.0, 0.95, 0.7), clamp(0.5 * streak + lead, 0.0, 1.0));
    \\    return vec4(col, glow);
    \\}
    \\
;

const flare_fs = if (is_web)
    "#version 100\nprecision highp float;\nvarying vec2 fragTexCoord;\n" ++ flare_fs_body ++
        "void main() { gl_FragColor = flareColor(fragTexCoord); }\n"
else
    "#version 330\nin vec2 fragTexCoord;\nout vec4 finalColor;\n" ++ flare_fs_body ++
        "void main() { finalColor = flareColor(fragTexCoord); }\n";

/// GPU state for the flare front: the plasma shader plus a 1×1 white texture
/// (drawTexturePro maps its texcoords 0..1 across the quad, which the shader
/// turns back into world coordinates — the shapes texture can't do that).
pub const FlareFx = struct {
    shader: rl.Shader,
    white: rl.Texture2D,
    loc_origin: i32,
    loc_quad_min: i32,
    loc_quad_size: i32,
    loc_angle: i32,
    loc_half: i32,
    loc_inner: i32,
    loc_outer: i32,
    loc_age: i32,

    pub fn init() !FlareFx {
        const shader = try rl.loadShaderFromMemory(null, flare_fs);
        const img = rl.genImageColor(1, 1, rl.Color.white);
        defer rl.unloadImage(img);
        return .{
            .shader = shader,
            .white = try rl.loadTextureFromImage(img),
            .loc_origin = rl.getShaderLocation(shader, "u_origin"),
            .loc_quad_min = rl.getShaderLocation(shader, "u_quad_min"),
            .loc_quad_size = rl.getShaderLocation(shader, "u_quad_size"),
            .loc_angle = rl.getShaderLocation(shader, "u_angle"),
            .loc_half = rl.getShaderLocation(shader, "u_half"),
            .loc_inner = rl.getShaderLocation(shader, "u_inner"),
            .loc_outer = rl.getShaderLocation(shader, "u_outer"),
            .loc_age = rl.getShaderLocation(shader, "u_age"),
        };
    }

    pub fn unload(self: FlareFx) void {
        rl.unloadShader(self.shader);
        rl.unloadTexture(self.white);
    }
};

/// Solar flare: a faint telegraph wedge over the whole affected sector with
/// hairline edges (visible from eruption onward, so the pilot knows where is
/// unsafe), plus — once the warning ends — the plasma front travelling outward.
/// Like the exhaust flame, it belongs to the physics, so every theme draws it.
pub fn drawFlare(flare: sim.Flare, sun_radius: f32, fx: *const FlareFx) void {
    const rad_to_deg = 180.0 / std.math.pi;
    const a0 = (flare.angle - sim.Flare.half_angle) * rad_to_deg;
    const a1 = (flare.angle + sim.Flare.half_angle) * rad_to_deg;
    const tint: rl.Color = .{ .r = 255, .g = 210, .b = 110, .a = 255 }; // sun tint
    // Flicker off the sim clock, not wall time, so pause/step frames hold still.
    const pulse = 0.75 + 0.25 * @sin(flare.age * 9.0);

    // Telegraph wedge — pulses bright during the warning, then drops to a
    // faint reminder while the front is in flight.
    const wedge_alpha: u8 = if (flare.warning()) @intFromFloat(30.0 * pulse) else 14;
    rl.drawRing(v(flare.origin), sun_radius, sim.Flare.max_range, a0, a1, 64, .{ .r = tint.r, .g = tint.g, .b = tint.b, .a = wedge_alpha });
    for ([_]f32{ -1, 1 }) |s| {
        const dir = Vec2.fromAngle(flare.angle + s * sim.Flare.half_angle);
        rl.drawLineEx(
            v(flare.origin.add(dir.scale(sun_radius))),
            v(flare.origin.add(dir.scale(sim.Flare.max_range))),
            2.0,
            .{ .r = tint.r, .g = tint.g, .b = tint.b, .a = 70 },
        );
    }

    // The travelling band — the only part that damages — as shader plasma on
    // a quad covering the front, blended additively so it reads as energy.
    if (!flare.warning()) {
        const outer = flare.frontOuter();
        const quad_min: [2]f32 = .{ flare.origin.x - outer, flare.origin.y - outer };
        const quad_size: [2]f32 = .{ outer * 2.0, outer * 2.0 };
        const origin: [2]f32 = .{ flare.origin.x, flare.origin.y };
        const uniforms = [_]struct { loc: i32, val: f32 }{
            .{ .loc = fx.loc_angle, .val = flare.angle },
            .{ .loc = fx.loc_half, .val = sim.Flare.half_angle },
            .{ .loc = fx.loc_inner, .val = flare.frontInner() },
            .{ .loc = fx.loc_outer, .val = outer },
            .{ .loc = fx.loc_age, .val = flare.age },
        };
        rl.setShaderValue(fx.shader, fx.loc_origin, &origin, .vec2);
        rl.setShaderValue(fx.shader, fx.loc_quad_min, &quad_min, .vec2);
        rl.setShaderValue(fx.shader, fx.loc_quad_size, &quad_size, .vec2);
        for (uniforms) |u| rl.setShaderValue(fx.shader, u.loc, &u.val, .float);

        rl.beginShaderMode(fx.shader);
        rl.beginBlendMode(.additive);
        rl.drawTexturePro(
            fx.white,
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .x = quad_min[0], .y = quad_min[1], .width = quad_size[0], .height = quad_size[1] },
            .{ .x = 0, .y = 0 },
            0,
            rl.Color.white,
        );
        rl.endBlendMode();
        rl.endShaderMode();
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

/// Screen-edge pointers to off-screen bodies: one small arrow per body that is
/// outside the viewport. Zoomed in on one planet the rest of the system is
/// invisible, and these say which way each of them is.
/// Inset of the arrow band from each screen edge. Top and bottom clear the
/// HUD's two text lines so an arrow never lands on top of them.
const edge_inset_x: f32 = 22.0;
const edge_inset_top: f32 = 74.0;
const edge_inset_bottom: f32 = 44.0;
const edge_arrow_size: f32 = 9.0;
const edge_label_size: i32 = 14;

/// Per-body tint — canonical body order (cfg.names), matching each body's own
/// colour so the name and its markers reinforce each other. Used by the edge
/// arrows and, faded right down, by the orbit paths.
const edge_colors = [_]rl.Color{
    .{ .r = 255, .g = 210, .b = 110, .a = 220 }, // sun
    .{ .r = 180, .g = 175, .b = 170, .a = 220 }, // mercury
    .{ .r = 230, .g = 195, .b = 140, .a = 220 }, // venus
    .{ .r = 110, .g = 175, .b = 255, .a = 220 }, // earth
    .{ .r = 215, .g = 215, .b = 225, .a = 220 }, // moon
    .{ .r = 235, .g = 120, .b = 90, .a = 220 }, // mars
    .{ .r = 225, .g = 170, .b = 120, .a = 220 }, // jupiter
    .{ .r = 240, .g = 215, .b = 160, .a = 220 }, // saturn
    .{ .r = 150, .g = 215, .b = 225, .a = 220 }, // uranus
    .{ .r = 95, .g = 130, .b = 235, .a = 220 }, // neptune
};

pub fn drawEdgeArrows(planets: []const sim.Planet, cam: rl.Camera2D) void {
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());
    // The band the arrows sit on, and the box a body must leave to get one.
    const left = edge_inset_x;
    const right = sw - edge_inset_x;
    const top = edge_inset_top;
    const bottom = sh - edge_inset_bottom;
    const cx = sw / 2.0;
    const cy = sh / 2.0;
    if (right <= cx or left >= cx or bottom <= cy or top >= cy) return; // tiny window

    // One arrow per off-screen body. No filtering yet — with ten bodies the
    // edge never gets crowded enough to need it.
    for (planets, 0..) |p, i| {
        const sp = rl.getWorldToScreen2D(v(p.pos), cam);
        // A body with any part of its disc inside the box needs no arrow.
        const r = p.radius * cam.zoom;
        if (sp.x + r > left and sp.x - r < right and sp.y + r > top and sp.y - r < bottom) continue;
        const dx = sp.x - cx;
        const dy = sp.y - cy;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist <= 0.0001) continue;

        // Where the ray from the screen centre leaves the box. One of the two
        // ratios may be infinite (a purely axis-aligned direction); @min
        // discards it.
        const tx = (if (dx > 0) right - cx else left - cx) / dx;
        const ty = (if (dy > 0) bottom - cy else top - cy) / dy;
        const t = @min(tx, ty);
        const pos: Vec2 = .{ .x = cx + dx * t, .y = cy + dy * t };
        const deg = std.math.atan2(dy, dx) * 180.0 / std.math.pi;
        rl.drawPoly(v(pos), 3, edge_arrow_size, deg, edge_colors[i]);
        rl.drawPolyLines(v(pos), 3, edge_arrow_size, deg, .{ .r = 20, .g = 25, .b = 40, .a = 180 });

        // Name, just inside the arrow (the arrow points outward, so the label
        // goes the other way) and clamped to stay fully on screen.
        const label = cfg.names[i];
        const lw: f32 = @floatFromInt(rl.measureText(label, edge_label_size));
        const lh: f32 = @floatFromInt(edge_label_size);
        // Step back by the arrow plus half the label's own extent along the
        // pointing direction, so text and arrow never overlap on any edge.
        const ux = dx / dist;
        const uy = dy / dist;
        const gap = edge_arrow_size + 6.0 + (lw / 2.0) * @abs(ux) + (lh / 2.0) * @abs(uy);
        const anchor_x = pos.x - ux * gap - lw / 2.0;
        const anchor_y = pos.y - uy * gap - lh / 2.0;
        const lx = std.math.clamp(anchor_x, 4.0, @max(4.0, sw - lw - 4.0));
        const ly = std.math.clamp(anchor_y, 4.0, @max(4.0, sh - lh - 4.0));
        var tint = edge_colors[i];
        tint.a = 220;
        // Dark drop shadow: a tint like Mars' rust would otherwise vanish
        // against a bright sprite the label happens to land on.
        rl.drawText(label, @as(i32, @intFromFloat(lx)) + 1, @as(i32, @intFromFloat(ly)) + 1, edge_label_size, .{ .r = 10, .g = 12, .b = 20, .a = 200 });
        rl.drawText(label, @intFromFloat(lx), @intFromFloat(ly), edge_label_size, tint);
    }
}

/// Name tag for the body under the cursor, drawn in screen space beside the
/// pointer. It reuses the edge-arrow tints so a body reads the same whether
/// you meet it as an off-screen arrow or under the mouse.
const hover_text_size: i32 = 16;
const hover_pad: f32 = 6.0;
/// Offset from the cursor's hotspot, far enough down-right to clear the arrow.
const hover_cursor_dx: f32 = 16.0;
const hover_cursor_dy: f32 = 18.0;

pub fn drawHoverLabel(idx: usize, mouse: rl.Vector2) void {
    const label = cfg.names[idx];
    const tw: f32 = @floatFromInt(rl.measureText(label, hover_text_size));
    const th: f32 = @floatFromInt(hover_text_size);
    const box_w = tw + 2 * hover_pad;
    const box_h = th + 2 * hover_pad;
    const sw: f32 = @floatFromInt(rl.getScreenWidth());
    const sh: f32 = @floatFromInt(rl.getScreenHeight());

    // Flip to the other side of the cursor rather than letting the tag slide
    // under it when it would run off the right/bottom edge.
    var x = mouse.x + hover_cursor_dx;
    if (x + box_w > sw - 4.0) x = mouse.x - hover_cursor_dx - box_w;
    var y = mouse.y + hover_cursor_dy;
    if (y + box_h > sh - 4.0) y = mouse.y - hover_cursor_dy - box_h;
    x = std.math.clamp(x, 4.0, @max(4.0, sw - box_w - 4.0));
    y = std.math.clamp(y, 4.0, @max(4.0, sh - box_h - 4.0));

    const box: rl.Rectangle = .{ .x = x, .y = y, .width = box_w, .height = box_h };
    rl.drawRectangleRec(box, .{ .r = 12, .g = 16, .b = 30, .a = 225 });
    rl.drawRectangleLinesEx(box, 1, edge_colors[idx]);
    rl.drawText(label, @intFromFloat(x + hover_pad), @intFromFloat(y + hover_pad), hover_text_size, edge_colors[idx]);
}

var hud_buf: [192]u8 = undefined;

pub fn drawHud(world: sim.World, theme: Theme, followed: ?usize) void {
    const ship = world.ship;
    const speed = ship.vel.len();
    // Altitude above the surface of whichever body's SOI the ship is in;
    // relative to the sun when coasting through gravity-free deep space.
    const soi_idx = world.dominantIndex(ship.pos);
    const soi_name: [:0]const u8 = if (soi_idx) |i| cfg.names[i] else "deep space";
    const soi_body = world.planets[soi_idx orelse 0];
    const altitude = ship.pos.sub(soi_body.pos).len() - soi_body.radius;

    rl.drawFPS(10, 10);

    const follow: [:0]const u8 = if (followed) |i| cfg.names[i] else "ship";
    const speed_txt = std.fmt.bufPrintZ(&hud_buf, "hull: {d:.0}   speed: {d:.1}   altitude: {d:.0}   soi: {s}   theme: {s}   follow: {s}", .{ ship.health, speed, altitude, soi_name, theme.label(), follow }) catch "";
    rl.drawText(speed_txt, 10, 34, 20, .{ .r = 200, .g = 220, .b = 240, .a = 255 });

    const controls = if (is_web)
        "W/Up: thrust   S/Down: brake   A/D or Left/Right: turn   wheel: zoom   drag: pan   O: SOI   R: reset   T: theme   X: solar flare   click a planet: details + follow it"
    else
        "W/Up: thrust   S/Down: brake   A/D or Left/Right: turn   wheel: zoom   drag: pan   O: SOI   R: reset   T: theme   X: solar flare   F: fullscreen   click a planet: details + follow it";
    rl.drawText(
        controls,
        10,
        rl.getScreenHeight() - 28, // live height so it sits at the bottom in fullscreen
        18,
        .{ .r = 150, .g = 165, .b = 190, .a = 255 },
    );
}
