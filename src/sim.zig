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
    /// `a` rotated by `radians` (same handedness as `fromAngle`).
    pub fn rotated(a: Vec2, radians: f32) Vec2 {
        const c = @cos(radians);
        const s = @sin(radians);
        return .{ .x = c * a.x - s * a.y, .y = s * a.x + c * a.y };
    }
};

/// Position and velocity on a Kepler ellipse, in the orbit's own frame: the
/// focus (parent body) at the origin, periapsis on the +x axis.
pub const KeplerState = struct { pos: Vec2, vel: Vec2 };

/// State on a Kepler ellipse with semi-major axis `a`, eccentricity `e` and
/// mean motion `n` (average rad/s), at mean anomaly `m`. Kepler's equation
/// m = E − e·sinE has no closed form; Newton's method from E = m reaches
/// f32 precision in a few steps for any e well below 1. The velocity falls
/// out of the same eccentric anomaly: dE/dt = n / (1 − e·cosE), fast at
/// periapsis and slow at apoapsis — Kepler's second law.
pub fn keplerState(a: f32, e: f32, n: f32, m: f32) KeplerState {
    var ea = m;
    var iter: usize = 0;
    while (iter < 6) : (iter += 1) {
        ea -= (ea - e * @sin(ea) - m) / (1 - e * @cos(ea));
    }
    const minor = @sqrt(1 - e * e); // semi-minor axis as a fraction of `a`
    const cos_ea = @cos(ea);
    const sin_ea = @sin(ea);
    const ea_dot = n / (1 - e * cos_ea);
    return .{
        .pos = .{ .x = a * (cos_ea - e), .y = a * minor * sin_ea },
        .vel = .{ .x = -a * sin_ea * ea_dot, .y = a * minor * cos_ea * ea_dot },
    };
}

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
    /// Hull integrity, 0–100. Damaged by hazards (solar flares); clamped at
    /// zero — no destruction mechanic yet.
    health: f32 = 100,
};

/// A solar flare: erupts from the sun in one direction, telegraphs a wedge
/// during a warning phase, then a hot band travels outward through the wedge.
/// Only the moving band damages the ship, so a warned pilot can dodge it.
pub const Flare = struct {
    /// Telegraph phase: the wedge is visible but harmless, giving the pilot
    /// time to burn out of the zone before the front launches.
    pub const warning_duration: f32 = 2.5;
    /// Angular half-width of the wedge, radians (~17°) — ~8600 px wide at
    /// Earth orbit, dodgeable but not trivially so.
    pub const half_angle: f32 = 0.30;
    /// Outward speed of the hot front, px/s — reaches Earth orbit ~5.8 s
    /// after the warning ends, slow enough to watch it cross the system.
    pub const front_speed: f32 = 2500;
    /// Radial thickness of the damaging band, px.
    pub const thickness: f32 = 2500;
    /// The flare dies at the sun's SOI edge; beyond is deep space.
    pub const max_range: f32 = 26000;
    /// Hull lost per second inside the band; a full stationary pass lasts
    /// thickness/front_speed = 1 s, so it costs ~17 hull.
    pub const damage_per_sec: f32 = 17;

    origin: Vec2,
    /// Direction of travel in radians (same convention as Vec2.fromAngle).
    angle: f32,
    age: f32 = 0,

    pub fn warning(self: Flare) bool {
        return self.age < warning_duration;
    }
    /// Leading edge of the hot band, distance from origin.
    pub fn frontOuter(self: Flare) f32 {
        return @max(0, self.age - warning_duration) * front_speed;
    }
    /// Trailing edge of the hot band.
    pub fn frontInner(self: Flare) f32 {
        return @max(0, self.frontOuter() - thickness);
    }
    pub fn expired(self: Flare) bool {
        return self.frontInner() > max_range;
    }
    /// Is `p` inside the damaging band right now?
    pub fn contains(self: Flare, p: Vec2) bool {
        const d = p.sub(self.origin);
        const dist = d.len();
        if (dist < self.frontInner() or dist > self.frontOuter()) return false;
        const delta = std.math.atan2(d.y, d.x) - self.angle;
        // Wrap to (-pi, pi] without branching so the ±pi seam just works.
        const wrapped = std.math.atan2(@sin(delta), @cos(delta));
        return @abs(wrapped) <= half_angle;
    }
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
    /// At most one flare at a time; null when the sun is quiet.
    flare: ?Flare = null,

    /// Erupt a flare from the root body (planets[0], the sun) toward `angle`.
    /// The caller picks the angle so the sim stays free of randomness.
    pub fn triggerFlare(self: *World, angle: f32) void {
        const origin = if (self.planets.len > 0) self.planets[0].pos else Vec2{};
        self.flare = .{ .origin = origin, .angle = angle };
    }

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

        if (self.flare) |*fl| {
            fl.age += dt;
            if (fl.expired()) {
                self.flare = null;
            } else if (!fl.warning() and fl.contains(self.ship.pos)) {
                self.ship.health = @max(0, self.ship.health - Flare.damage_per_sec * dt);
            }
        }
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

test "Vec2.rotated turns counter-clockwise from +x" {
    const r = (Vec2{ .x = 1, .y = 0 }).rotated(std.math.pi / 2.0);
    try testing.expectApproxEqAbs(@as(f32, 0), r.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), r.y, 1e-6);
}

test "keplerState with zero eccentricity is a uniform circle" {
    const a: f32 = 1500;
    const n: f32 = 0.008;
    var m: f32 = 0;
    while (m < std.math.tau) : (m += 0.37) {
        const s = keplerState(a, 0, n, m);
        try testing.expectApproxEqRel(a, s.pos.len(), 1e-5);
        try testing.expectApproxEqRel(n * a, s.vel.len(), 1e-5);
        // Velocity is tangential: no radial component.
        try testing.expectApproxEqAbs(@as(f32, 0), s.pos.dot(s.vel), a * a * n * 1e-4);
    }
}

test "keplerState ellipse: periapsis to apoapsis, fast to slow" {
    const a: f32 = 5500;
    const e: f32 = 0.15;
    const n: f32 = 0.0027;
    const peri = keplerState(a, e, n, 0);
    const apo = keplerState(a, e, n, std.math.pi);
    try testing.expectApproxEqRel(a * (1 - e), peri.pos.len(), 1e-4);
    try testing.expectApproxEqRel(a * (1 + e), apo.pos.len(), 1e-4);
    try testing.expect(peri.vel.len() > apo.vel.len());

    // Kepler's second law: the angular momentum x·vy − y·vx is the same
    // everywhere on the orbit.
    const h0 = peri.pos.x * peri.vel.y - peri.pos.y * peri.vel.x;
    var m: f32 = 0.3;
    while (m < std.math.tau) : (m += 0.9) {
        const s = keplerState(a, e, n, m);
        const h = s.pos.x * s.vel.y - s.pos.y * s.vel.x;
        try testing.expectApproxEqRel(h0, h, 1e-3);
    }
}

test "keplerState velocity matches the derivative of position" {
    const a: f32 = 1500;
    const e: f32 = 0.055;
    const n: f32 = 0.008;
    const dm: f32 = 1e-3;
    var m: f32 = 0.1;
    while (m < std.math.tau) : (m += 1.1) {
        const s = keplerState(a, e, n, m);
        const ahead = keplerState(a, e, n, m + dm);
        const behind = keplerState(a, e, n, m - dm);
        const dt = 2.0 * dm / n; // central difference over ±dm of mean anomaly
        try testing.expectApproxEqAbs(s.vel.x, (ahead.pos.x - behind.pos.x) / dt, n * a * 0.01);
        try testing.expectApproxEqAbs(s.vel.y, (ahead.pos.y - behind.pos.y) / dt, n * a * 0.01);
    }
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

/// Step `world` for `seconds` of sim time in 0.01 s increments.
fn stepFor(world: *World, seconds: f32) void {
    const dt: f32 = 0.01;
    var t: f32 = 0;
    while (t < seconds) : (t += dt) world.step(dt, .{});
}

test "flare warning phase deals no damage" {
    var world: World = .{ .planets = &.{}, .ship = .{ .pos = .{ .x = 1000, .y = 0 }, .vel = .{} } };
    world.triggerFlare(0);
    stepFor(&world, 1.0);
    try testing.expectEqual(@as(f32, 100), world.ship.health);
    try testing.expect(world.flare != null);
    try testing.expect(world.flare.?.warning());
}

test "flare front damages the ship as it passes" {
    var world: World = .{ .planets = &.{}, .ship = .{ .pos = .{ .x = 1000, .y = 0 }, .vel = .{} } };
    world.triggerFlare(0);
    // Step past the band's full transit of x=1000 (trailing edge clears it at
    // age = warning + (1000 + thickness) / front_speed = 3.9 s).
    stepFor(&world, 4.0);
    // Exposure is the time the band covers the ship: thickness / front_speed.
    const expected = 100.0 - Flare.damage_per_sec * (Flare.thickness / Flare.front_speed);
    try testing.expectApproxEqRel(expected, world.ship.health, 2e-2);
    // The front has moved on — no further damage.
    const after_pass = world.ship.health;
    stepFor(&world, 1.0);
    try testing.expectEqual(after_pass, world.ship.health);
}

test "ship outside the wedge is untouched and the flare expires" {
    // Bearing pi/2 from the origin, flare aimed along +x: well outside 0.30 rad.
    var world: World = .{ .planets = &.{}, .ship = .{ .pos = .{ .x = 0, .y = 1000 }, .vel = .{} } };
    world.triggerFlare(0);
    stepFor(&world, 14.0);
    try testing.expectEqual(@as(f32, 100), world.ship.health);
    try testing.expectEqual(@as(?Flare, null), world.flare);
}

test "flare hit test wraps across the pi seam" {
    // Flare at pi-0.1, ship bearing -pi+0.1: naive delta is ~2pi-0.2, but the
    // true angular distance is 0.2 < half_angle, so the ship must be hit.
    const pos = Vec2.fromAngle(-std.math.pi + 0.1).scale(1000);
    var world: World = .{ .planets = &.{}, .ship = .{ .pos = pos, .vel = .{} } };
    world.triggerFlare(std.math.pi - 0.1);
    stepFor(&world, 4.0);
    try testing.expect(world.ship.health < 100);
}

test "flare damage clamps health at zero" {
    var world: World = .{ .planets = &.{}, .ship = .{ .pos = .{ .x = 1000, .y = 0 }, .vel = .{}, .health = 5 } };
    world.triggerFlare(0);
    stepFor(&world, 4.0);
    try testing.expectEqual(@as(f32, 0), world.ship.health);
}
