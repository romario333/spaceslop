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
    phobos: rl.Texture2D,
    deimos: rl.Texture2D,
    io: rl.Texture2D,
    europa: rl.Texture2D,
    ganymede: rl.Texture2D,
    callisto: rl.Texture2D,
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
            .phobos = try rl.loadTexture("resources/" ++ dir ++ "/phobos.png"),
            .deimos = try rl.loadTexture("resources/" ++ dir ++ "/deimos.png"),
            .io = try rl.loadTexture("resources/" ++ dir ++ "/io.png"),
            .europa = try rl.loadTexture("resources/" ++ dir ++ "/europa.png"),
            .ganymede = try rl.loadTexture("resources/" ++ dir ++ "/ganymede.png"),
            .callisto = try rl.loadTexture("resources/" ++ dir ++ "/callisto.png"),
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

    fn all(self: SpriteSet) [18]rl.Texture2D {
        return .{ self.sun, self.mercury, self.venus, self.earth, self.moon, self.mars, self.jupiter, self.saturn, self.uranus, self.neptune, self.phobos, self.deimos, self.io, self.europa, self.ganymede, self.callisto, self.ship, self.iss };
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
            9 => self.neptune,
            10 => self.phobos,
            11 => self.deimos,
            12 => self.io,
            13 => self.europa,
            14 => self.ganymede,
            else => self.callisto,
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

/// Visual layer of the asteroid belt. The rocks' kinematics — positions,
/// drift, wobble, sizes — live in sim.Belt, because they are the colliders
/// the ship actually hits; what you see is exactly what hurts. This struct
/// holds only the cosmetics, index-aligned with the sim's rock array: tumble
/// rate, tint, and a per-rock lumpy outline (radius-jittered vertices, drawn
/// as a triangle fan) so no two rocks are the same shape. Rock sizes are
/// floored in *screen* px, the starfield's trick: zoomed out the swarm
/// collapses into a speckled dust ring, and a faint annulus underlay keeps
/// the hazard band legible at any zoom.
pub const AsteroidBelt = struct {
    /// Screen-px floor for a rock (slightly under the stars' 1.5, so the
    /// belt speckle reads as a band without outshining the starfield).
    const min_px: f32 = 1.4;
    /// Culling margin: the largest rock radius times the largest vertex
    /// jitter, in world px.
    const margin: f32 = 26.0;
    const max_verts = 10;

    const Visual = struct {
        /// Tumble rate, rad/s (signed — some spin retrograde).
        spin: f32,
        nverts: u8,
        color: rl.Color,
        shadow: rl.Color,
        /// Unit outline: vertices around the origin at radius ~0.62–1.30,
        /// scaled by the sim rock's size at draw time.
        verts: [max_verts]Vec2,
    };

    visuals: [sim.Belt.rock_count]Visual = undefined,

    pub fn init(self: *AsteroidBelt, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        for (&self.visuals) |*vis| {
            const shade = 90.0 + rng.float(f32) * 75.0;
            vis.* = .{
                .spin = (rng.float(f32) - 0.5) * 2.4,
                .nverts = 7 + rng.uintLessThan(u8, 4),
                .color = .{
                    .r = @intFromFloat(shade + 30),
                    .g = @intFromFloat(shade + 8),
                    .b = @intFromFloat(shade - 12),
                    .a = 255,
                },
                .shadow = .{
                    .r = @intFromFloat((shade + 30) * 0.55),
                    .g = @intFromFloat((shade + 8) * 0.55),
                    .b = @intFromFloat((shade - 12) * 0.55),
                    .a = 255,
                },
                .verts = undefined,
            };
            // Irregular outline: evenly spread vertices, each nudged along
            // the ring (±¼ step keeps them sorted, so the polygon stays
            // simple) and jittered in radius. Star-convex from the origin,
            // which is all the triangle fan needs. Decreasing angle, because
            // raylib's y-down 2D winding culls the other direction.
            const n: f32 = @floatFromInt(vis.nverts);
            for (vis.verts[0..vis.nverts], 0..) |*vert, k| {
                const step = std.math.tau / n;
                const ang = step * @as(f32, @floatFromInt(k)) + (rng.float(f32) - 0.5) * step * 0.5;
                vert.* = Vec2.fromAngle(-ang).scale(0.62 + rng.float(f32) * 0.68);
            }
        }
    }

    pub fn draw(self: *const AsteroidBelt, belt: *const sim.Belt, center: Vec2, cam: rl.Camera2D) void {
        // Dusty annulus underlay: marks the hazard band at every zoom and
        // gives the speckle something to sit on. Stacked concentric rings,
        // each pulled in from both edges, so the accumulated alpha steps up
        // toward mid-belt roughly like the sim's density bump — no hard rim
        // where dust meets space.
        const dust: rl.Color = .{ .r = 170, .g = 145, .b = 115, .a = 6 };
        const width = sim.Belt.outer - sim.Belt.inner;
        var layer: f32 = 0;
        while (layer < 4) : (layer += 1) {
            const inset = width * layer / 9.0;
            rl.drawRing(v(center), sim.Belt.inner + inset, sim.Belt.outer - inset, 0, 360, 360, dust);
        }

        const view_w = @as(f32, @floatFromInt(rl.getScreenWidth())) / cam.zoom;
        const view_h = @as(f32, @floatFromInt(rl.getScreenHeight())) / cam.zoom;
        const left = cam.target.x - view_w / 2.0 - margin;
        const right = cam.target.x + view_w / 2.0 + margin;
        const top = cam.target.y - view_h / 2.0 - margin;
        const bottom = cam.target.y + view_h / 2.0 + margin;

        std.debug.assert(belt.rocks.len <= self.visuals.len);
        const px = min_px / cam.zoom;
        for (belt.rocks, 0..) |rock, i| {
            const pos = sim.Belt.rockState(rock, center, belt.time).pos;
            if (pos.x < left or pos.x > right or pos.y < top or pos.y > bottom) continue;
            const vis = &self.visuals[i];
            if (rock.size <= px) {
                // Sub-pixel at this zoom: a flat rect, same as the starfield.
                rl.drawRectangleV(.{ .x = pos.x - px / 2.0, .y = pos.y - px / 2.0 }, .{ .x = px, .y = px }, vis.color);
                continue;
            }
            // Tumble the unit outline and scale it up to the rock's size.
            const spin_ang = rock.wob_phase + vis.spin * belt.time;
            const c = @cos(spin_ang);
            const s = @sin(spin_ang);
            var world_verts: [max_verts]Vec2 = undefined;
            for (vis.verts[0..vis.nverts], world_verts[0..vis.nverts]) |vert, *w| {
                w.* = .{
                    .x = (c * vert.x - s * vert.y) * rock.size,
                    .y = (s * vert.x + c * vert.y) * rock.size,
                };
            }
            // Fan from the centroid: [centre, v0..vn, v0] closes the loop.
            var pts: [max_verts + 2]rl.Vector2 = undefined;
            pts[0] = v(pos);
            for (world_verts[0..vis.nverts], 0..) |w, k| pts[k + 1] = v(pos.add(w));
            pts[vis.nverts + 1] = pts[1];
            rl.drawTriangleFan(pts[0 .. @as(usize, vis.nverts) + 2], vis.color);
            // Fake lighting: the same outline at 0.5 scale, pushed away from
            // the sun by 0.28·size — stays inside the 0.62 minimum vertex
            // radius, so the shadow never pokes out of the silhouette.
            const away = pos.sub(center).normalized().scale(rock.size * 0.28);
            const spos = pos.add(away);
            pts[0] = v(spos);
            for (world_verts[0..vis.nverts], 0..) |w, k| pts[k + 1] = v(spos.add(w.scale(0.5)));
            pts[vis.nverts + 1] = pts[1];
            rl.drawTriangleFan(pts[0 .. @as(usize, vis.nverts) + 2], vis.shadow);
        }
    }
};

/// Cheap deterministic 0..1 hash, the shader's fract(sin(n)·43758…) trick.
fn hash(n: f32) f32 {
    const x = @sin(n) * 43758.5453;
    return x - @floor(x);
}

/// Impact sparks just after a rock strike (keyed off ship.hit_timer): hot
/// flecks jittering around the ship, re-rolled a few times a second off the
/// sim clock so pause/step hold the picture still. Like the exhaust flame,
/// this belongs to the physics and draws in every theme.
pub fn drawBeltImpacts(ship_pos: Vec2, time: f32) void {
    const slot = @floor(time * 8.0);
    var i: f32 = 0;
    while (i < 4) : (i += 1) {
        const a = hash(slot * 17.31 + i * 7.97) * std.math.tau;
        const d = 12.0 + 20.0 * hash(slot * 5.13 + i * 3.71);
        const p = ship_pos.add(Vec2.fromAngle(a).scale(d));
        const s = 1.5 + 2.5 * hash(slot * 9.77 + i * 11.3);
        rl.drawCircleV(v(p), s, .{ .r = 255, .g = 190, .b = 90, .a = 230 });
    }
}

/// Faint line tracing a body's scripted Kepler ellipse (see `orbits` in
/// main.zig): semi-major axis `a`, eccentricity `e`, periapsis direction
/// `peri`, with the parent's current position at `focus`. Drawn under
/// everything else, so it reads as background structure: the shape of the
/// system at a glance, and where a planet's path will take it while you fly
/// to it.
///
/// Always drawn at the same strength, whatever the zoom: a path that dims and
/// brightens as you scroll draws the eye to the zooming rather than to the
/// system, and any zoom level where it looked right made another look wrong.
pub fn drawOrbitPath(focus: Vec2, a: f32, e: f32, peri: f32, body_idx: usize, cam: rl.Camera2D) void {
    const r_px = a * cam.zoom;

    // Hairline in screen space: a world-thickness line disappears zoomed out
    // and swells into a fat band zoomed in.
    const thickness = 1.5 / cam.zoom;
    // Segments from the apparent size — a path that fills the window shouldn't
    // read as a polygon, and a small one shouldn't cost hundreds of quads.
    const segments: usize = @intFromFloat(std.math.clamp(r_px * 0.5, 48, 512));
    var color = edge_colors[body_idx];
    color.a = orbit_alpha;

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

/// The one alpha every orbit path is drawn at. Faint on purpose — the paths
/// are there to be noticed when you look for them, not to compete with the
/// bodies — but strong enough to read on the zoomed-in black background.
const orbit_alpha: u8 = 46;

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
    .{ .r = 165, .g = 140, .b = 120, .a = 220 }, // phobos
    .{ .r = 195, .g = 175, .b = 150, .a = 220 }, // deimos
    .{ .r = 235, .g = 205, .b = 90, .a = 220 }, // io
    .{ .r = 200, .g = 225, .b = 240, .a = 220 }, // europa
    .{ .r = 170, .g = 180, .b = 195, .a = 220 }, // ganymede
    .{ .r = 140, .g = 125, .b = 110, .a = 220 }, // callisto
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

    // One arrow per off-screen body. No filtering yet — moons cluster their
    // arrows next to their parent's, but the edge stays readable.
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

const hud_y = 34;
const hud_font = 20;
const hud_gap = 26; // space between status columns, in px
const hud_color: rl.Color = .{ .r = 200, .g = 220, .b = 240, .a = 255 };
/// Fuel readout turns amber below this, to nudge you toward planning a
/// return or a cheaper route while there's still fuel to do it with.
const fuel_warn = 50.0;
/// ...and red below this, where only a short trim burn is left.
const fuel_low = 20.0;

/// Draw one status-line column and advance `x` past it. The column is as
/// wide as `widest` — the longest string this field can ever hold — so a
/// value that gains a digit (speed ticking past 999, a longer SOI name)
/// grows into its own slack instead of shoving every later field sideways.
fn hudColumn(x: *i32, text: [:0]const u8, widest: [:0]const u8, color: rl.Color) void {
    rl.drawText(text, x.*, hud_y, hud_font, color);
    x.* += rl.measureText(widest, hud_font) + hud_gap;
}

pub fn drawHud(world: sim.World, theme: Theme, followed: ?usize) void {
    const ship = world.ship;
    const speed = ship.vel.len();
    const soi_idx = world.dominantIndex(ship.pos);
    const soi_name: [:0]const u8 = if (soi_idx) |i| cfg.names[i] else "deep space";

    rl.drawFPS(10, 10);

    const follow: [:0]const u8 = if (followed) |i| cfg.names[i] else "ship";
    var x: i32 = 10;

    // Each column formats into the shared buffer and is drawn before the
    // next one reuses it.
    // Hull turns red while a hazard is actively damaging the ship — rock
    // strikes have no telegraph, so the readout is the "you got hit" cue.
    const in_flare = if (world.flare) |fl| !fl.warning() and fl.contains(ship.pos) else false;
    const hull_color: rl.Color = if (ship.hit_timer > 0 or in_flare)
        .{ .r = 255, .g = 90, .b = 80, .a = 255 }
    else
        hud_color;
    const hull_txt = std.fmt.bufPrintZ(&hud_buf, "hull: {d:.0}", .{ship.health}) catch "";
    hudColumn(&x, hull_txt, "hull: 100", hull_color);

    const speed_txt = std.fmt.bufPrintZ(&hud_buf, "speed: {d:.1}", .{speed}) catch "";
    hudColumn(&x, speed_txt, "speed: 99999.9", hud_color);

    const fuel_color: rl.Color = if (ship.fuel < fuel_low)
        .{ .r = 255, .g = 90, .b = 80, .a = 255 }
    else if (ship.fuel < fuel_warn)
        .{ .r = 255, .g = 190, .b = 70, .a = 255 }
    else
        hud_color;
    const fuel_txt = std.fmt.bufPrintZ(&hud_buf, "fuel: {d:.0}/{d:.0}", .{ ship.fuel, sim.Ship.max_fuel }) catch "";
    hudColumn(&x, fuel_txt, "fuel: 100/100", fuel_color);

    const soi_txt = std.fmt.bufPrintZ(&hud_buf, "soi: {s}", .{soi_name}) catch "";
    hudColumn(&x, soi_txt, "soi: deep space", hud_color);

    const theme_txt = std.fmt.bufPrintZ(&hud_buf, "theme: {s}", .{theme.label()}) catch "";
    hudColumn(&x, theme_txt, "theme: scifi-60s", hud_color);

    const follow_txt = std.fmt.bufPrintZ(&hud_buf, "follow: {s}", .{follow}) catch "";
    hudColumn(&x, follow_txt, "follow: deep space", hud_color);

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
