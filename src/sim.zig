//! Pure-Zig orbital simulation. No raylib, no I/O — just math and state, so it
//! can be unit-tested with `zig build test` and later reused behind any renderer.

const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn lenSq(a: Vec2) f32 {
        return a.dot(a);
    }
    pub fn len(a: Vec2) f32 {
        return @sqrt(a.lenSq());
    }
    pub fn normalized(a: Vec2) Vec2 {
        const l = a.len();
        return if (l == 0) .{} else a.scale(1.0 / l);
    }
    /// Unit vector pointing along `radians` (0 = +x, growing clockwise on screen).
    pub fn fromAngle(radians: f32) Vec2 {
        return .{ .x = @cos(radians), .y = @sin(radians) };
    }
};

pub const Planet = struct {
    pos: Vec2,
    mass: f32,
    radius: f32,
    /// Sphere-of-influence radius: this planet's gravity only applies within
    /// it (see World.gravityAt). Set explicitly per body — it deliberately
    /// does NOT follow from mass, so a moon can pull hard inside a small
    /// bubble without perturbing orbits around the primary. Defaults to
    /// infinite (single-body worlds just work).
    soi: f32 = std.math.inf(f32),
    /// Gravity stops growing inside max(radius, core): needed when a body is
    /// rendered much smaller than its mass warrants — without it, a close
    /// flyby produces accelerations the fixed timestep can't integrate and
    /// the ship gets a spurious energy kick that can eject it from orbit.
    core: f32 = 0,
    /// Frame acceleration of a scripted moving body (e.g. a moon on a
    /// kinematic circle). Ships inside this body's SOI are carried along by
    /// it, which makes energy relative to the body conserved — orbits ride
    /// with the moon instead of leaking out as it moves away (Kerbal-style
    /// integration in the moon's frame, expressed in world coordinates).
    acc: Vec2 = .{},
    /// World velocity of a scripted moving body. Used to judge whether a
    /// ship inside the SOI is bound to the body or on a fast flyby (capture
    /// assist applies only to the former, so slingshots stay untouched).
    vel: Vec2 = .{},
};

pub const Ship = struct {
    pos: Vec2,
    vel: Vec2,
    /// Facing direction in radians; thrust pushes along this heading.
    angle: f32 = 0,
    thrusting: bool = false,
    /// Retro thrusters firing: the pair of small nose thrusters that push
    /// the ship backwards along its heading.
    braking: bool = false,
};

/// Per-frame control input, produced by the renderer/input layer.
pub const Input = struct {
    /// -1 = turn left, +1 = turn right, 0 = hold heading.
    turn: f32 = 0,
    thrust: bool = false,
    /// Retro burn — same magnitude as `thrust`, opposite direction. Holding
    /// both at once simply cancels out.
    brake: bool = false,
};

pub const World = struct {
    /// Gameplay gravitational constant — tuned for pixels, not real-world units.
    /// Kept low so orbital speeds stay arcade-slow and steerable.
    pub const g: f32 = 1200.0;
    /// Engine acceleration while thrusting, in px/s².
    pub const thrust_accel: f32 = 70.0;
    /// Turn speed in radians/second.
    pub const turn_rate: f32 = 2.8;
    /// Capture assist (arcade): bound ships in the outer part of a moon's
    /// SOI feel a gentle drag on their moon-relative velocity, fraction/s.
    /// Pulls a ballistic arrival's apoapsis off the SOI boundary within a
    /// revolution or two so it settles into orbit with no braking burn.
    pub const capture_drag: f32 = 0.12;
    /// Capture drag only acts beyond this fraction of the SOI radius, so
    /// parked orbits deeper inside feel nothing and never decay.
    pub const capture_zone: f32 = 0.6;

    planets: []const Planet,
    ship: Ship,

    /// Index of the planet whose sphere of influence contains `point`.
    /// SOIs nest (moon inside Earth's, planets inside the sun's), so of all
    /// the bodies whose SOI covers the point the one with the *smallest* SOI
    /// is the innermost — that body owns the point. Null means the point is
    /// outside every SOI: deep space, no gravity at all.
    pub fn dominantIndex(self: World, point: Vec2) ?usize {
        var best: ?usize = null;
        for (self.planets, 0..) |p, i| {
            if (point.sub(p.pos).len() < p.soi) {
                if (best == null or p.soi < self.planets[best.?].soi) best = i;
            }
        }
        return best;
    }

    /// Like `dominantIndex`, but ignoring `excluded`: the body that would own
    /// `point` if it were just outside `excluded`'s SOI. This is the enclosing
    /// reference frame (moon → Earth → sun → deep space), used to blend the
    /// trail between frames near an SOI edge.
    pub fn enclosingIndex(self: World, point: Vec2, excluded: usize) ?usize {
        var best: ?usize = null;
        for (self.planets, 0..) |p, i| {
            if (i == excluded) continue;
            if (point.sub(p.pos).len() < p.soi) {
                if (best == null or p.soi < self.planets[best.?].soi) best = i;
            }
        }
        return best;
    }

    /// Gravitational acceleration at `point` — arcade patched conics: only
    /// the body whose sphere of influence contains the point pulls, so orbits
    /// around every body are clean two-body ellipses with no third-body
    /// drift (a summed field pumps eccentricity until the ship crashes).
    /// Distance is clamped to the planet's radius so the force stays finite.
    pub fn gravityAt(self: World, point: Vec2) Vec2 {
        const idx = self.dominantIndex(point) orelse return .{};
        const p = self.planets[idx];
        const d = p.pos.sub(point);
        const dist = @max(d.len(), @max(p.radius, p.core));
        const mag = g * p.mass / (dist * dist);
        return d.normalized().scale(mag);
    }

    /// Advance the ship by `dt` seconds using semi-implicit Euler, which keeps
    /// closed orbits stable (energy oscillates rather than spiralling out).
    pub fn step(self: *World, dt: f32, input: Input) void {
        self.ship.angle += input.turn * turn_rate * dt;

        var acc = self.gravityAt(self.ship.pos);
        if (self.dominantIndex(self.ship.pos)) |idx| {
            const p = self.planets[idx];
            // Ride along with a moving SOI owner (see Planet.acc).
            acc = acc.add(p.acc);
            // Capture assist — satellites only (planets[0] is the root body;
            // dragging inside its SOI would decay every heliocentric orbit).
            // Applies only to ships that are bound to the body (negative
            // relative energy) in the outer SOI; fast hyperbolic flybys keep
            // full slingshot behaviour.
            if (idx > 0) {
                const dist = self.ship.pos.sub(p.pos).len();
                if (dist > capture_zone * p.soi) {
                    const v_rel = self.ship.vel.sub(p.vel);
                    const energy = v_rel.lenSq() / 2.0 - g * p.mass / @max(dist, @max(p.radius, p.core));
                    if (energy < 0) acc = acc.add(v_rel.scale(-capture_drag));
                }
            }
        }
        self.ship.thrusting = input.thrust;
        self.ship.braking = input.brake;
        if (input.thrust) {
            acc = acc.add(Vec2.fromAngle(self.ship.angle).scale(thrust_accel));
        }
        // Two small nose thrusters, same total power as the main engine.
        if (input.brake) {
            acc = acc.add(Vec2.fromAngle(self.ship.angle).scale(-thrust_accel));
        }

        self.ship.vel = self.ship.vel.add(acc.scale(dt)); // velocity first...
        self.ship.pos = self.ship.pos.add(self.ship.vel.scale(dt)); // ...then position
    }

    /// Speed needed for a circular orbit at `radius` around a planet of `mass`.
    /// Handy for placing the ship in a stable starting orbit.
    pub fn circularOrbitSpeed(mass: f32, radius: f32) f32 {
        return @sqrt(g * mass / radius);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Vec2 arithmetic" {
    const a: Vec2 = .{ .x = 3, .y = 4 };
    try testing.expectEqual(@as(f32, 5), a.len());
    try testing.expectEqual(@as(f32, 25), a.lenSq());

    const b = a.add(.{ .x = 1, .y = 1 });
    try testing.expectEqual(@as(f32, 4), b.x);
    try testing.expectEqual(@as(f32, 5), b.y);

    const n = a.normalized();
    try testing.expectApproxEqAbs(@as(f32, 1), n.len(), 1e-6);
}

test "gravity points toward the planet" {
    const world: World = .{
        .planets = &.{.{ .pos = .{ .x = 0, .y = 0 }, .mass = 1000, .radius = 20 }},
        .ship = .{ .pos = .{ .x = 100, .y = 0 }, .vel = .{} },
    };
    const acc = world.gravityAt(.{ .x = 100, .y = 0 });
    // Ship is on the +x side of the planet, so gravity pulls back toward -x.
    try testing.expect(acc.x < 0);
    try testing.expectApproxEqAbs(@as(f32, 0), acc.y, 1e-4);
}

test "circular orbit keeps a roughly constant radius" {
    const mass: f32 = 5000;
    const r: f32 = 220;
    const speed = World.circularOrbitSpeed(mass, r);

    var world: World = .{
        .planets = &.{.{ .pos = .{ .x = 0, .y = 0 }, .mass = mass, .radius = 24 }},
        // Start on +x moving +y => counter-clockwise circular orbit.
        .ship = .{ .pos = .{ .x = r, .y = 0 }, .vel = .{ .x = 0, .y = speed } },
    };

    const dt: f32 = 1.0 / 600.0;
    var i: usize = 0;
    while (i < 6000) : (i += 1) { // ~10 simulated seconds
        world.step(dt, .{});
        const radius = world.ship.pos.len();
        try testing.expect(radius > r * 0.9 and radius < r * 1.1);
    }
}

test "spheres of influence partition gravity" {
    const world: World = .{
        .planets = &.{
            .{ .pos = .{ .x = 0, .y = 0 }, .mass = 8000, .radius = 140, .soi = 2500 },
            .{ .pos = .{ .x = 1500, .y = 0 }, .mass = 3000, .radius = 40, .soi = 400 },
        },
        .ship = .{ .pos = .{}, .vel = .{} },
    };

    // Inside the moon's SOI: pulled toward the moon (+x), Earth ignored.
    const p: Vec2 = .{ .x = 1200, .y = 0 };
    try testing.expectEqual(@as(?usize, 1), world.dominantIndex(p));
    try testing.expect(world.gravityAt(p).x > 0);

    // Between the SOIs: pulled toward Earth (-x), moon ignored.
    const q: Vec2 = .{ .x = 1000, .y = 0 };
    try testing.expectEqual(@as(?usize, 0), world.dominantIndex(q));
    try testing.expect(world.gravityAt(q).x < 0);

    // Beyond Earth's SOI (and outside the moon's): deep space, zero gravity.
    const far: Vec2 = .{ .x = 0, .y = 3000 };
    try testing.expectEqual(@as(?usize, null), world.dominantIndex(far));
    try testing.expectEqual(@as(f32, 0), world.gravityAt(far).len());
}

test "nested SOIs resolve to the innermost body regardless of order" {
    // Sun ⊃ Earth ⊃ Moon, deliberately listed parent-first so the test
    // fails if dominantIndex ever falls back to first-match ordering.
    const world: World = .{
        .planets = &.{
            .{ .pos = .{}, .mass = 100000, .radius = 600, .soi = 26000 }, // sun
            .{ .pos = .{ .x = 14500, .y = 0 }, .mass = 8000, .radius = 140, .soi = 2500 }, // earth
            .{ .pos = .{ .x = 16000, .y = 0 }, .mass = 4000, .radius = 40, .soi = 770 }, // moon
        },
        .ship = .{ .pos = .{}, .vel = .{} },
    };

    // Near the moon all three SOIs contain the point; the moon's is smallest.
    try testing.expectEqual(@as(?usize, 2), world.dominantIndex(.{ .x = 16100, .y = 0 }));
    // Inside Earth's SOI but outside the moon's.
    try testing.expectEqual(@as(?usize, 1), world.dominantIndex(.{ .x = 14000, .y = 0 }));
    // Interplanetary space belongs to the sun.
    try testing.expectEqual(@as(?usize, 0), world.dominantIndex(.{ .x = 7000, .y = 0 }));
    // Beyond the sun's SOI: deep space.
    try testing.expectEqual(@as(?usize, null), world.dominantIndex(.{ .x = 41000, .y = 0 }));

    // enclosingIndex climbs one level up the same hierarchy.
    try testing.expectEqual(@as(?usize, 1), world.enclosingIndex(.{ .x = 16100, .y = 0 }, 2));
    try testing.expectEqual(@as(?usize, 0), world.enclosingIndex(.{ .x = 14000, .y = 0 }, 1));
    try testing.expectEqual(@as(?usize, null), world.enclosingIndex(.{ .x = 7000, .y = 0 }, 0));
}

test "capture assist drags bound ships in the outer SOI but not flybys" {
    const planets = [_]Planet{
        .{ .pos = .{}, .mass = 8000, .radius = 140, .soi = 2500 },
        .{ .pos = .{ .x = 1500, .y = 0 }, .mass = 3000, .radius = 40, .soi = 400, .core = 110 },
    };
    const dt: f32 = 0.01;
    // 350 px from the moon (outer SOI; gravity there is pure +x, so any
    // y-velocity change comes from the drag alone).
    const pos: Vec2 = .{ .x = 1150, .y = 0 };

    // Slow ship: bound to the moon => y-velocity gets damped.
    var bound: World = .{ .planets = &planets, .ship = .{ .pos = pos, .vel = .{ .x = 0, .y = 40 } } };
    bound.step(dt, .{});
    try testing.expectApproxEqRel(40.0 * (1.0 - World.capture_drag * dt), bound.ship.vel.y, 1e-4);

    // Fast ship: hyperbolic flyby => no drag, y-velocity untouched.
    var flyby: World = .{ .planets = &planets, .ship = .{ .pos = pos, .vel = .{ .x = 0, .y = 200 } } };
    flyby.step(dt, .{});
    try testing.expectApproxEqRel(@as(f32, 200), flyby.ship.vel.y, 1e-5);
}

test "thrust along heading increases speed" {
    // No planets, so only the engine acts on the ship.
    var world: World = .{
        .planets = &.{},
        .ship = .{ .pos = .{}, .vel = .{}, .angle = 0 },
    };
    world.step(0.1, .{ .thrust = true });
    try testing.expect(world.ship.vel.x > 0); // pushed along +x heading
    try testing.expectApproxEqAbs(@as(f32, 0), world.ship.vel.y, 1e-4);
}

test "brake pushes opposite the heading with the same power" {
    var fwd: World = .{ .planets = &.{}, .ship = .{ .pos = .{}, .vel = .{}, .angle = 0 } };
    var back: World = .{ .planets = &.{}, .ship = .{ .pos = .{}, .vel = .{}, .angle = 0 } };
    fwd.step(0.1, .{ .thrust = true });
    back.step(0.1, .{ .brake = true });
    try testing.expectApproxEqRel(-fwd.ship.vel.x, back.ship.vel.x, 1e-6);
    try testing.expect(back.ship.braking);

    // Holding both cancels out exactly.
    var both: World = .{ .planets = &.{}, .ship = .{ .pos = .{}, .vel = .{}, .angle = 0 } };
    both.step(0.1, .{ .thrust = true, .brake = true });
    try testing.expectEqual(@as(f32, 0), both.ship.vel.len());
}
