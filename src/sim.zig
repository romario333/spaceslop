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
};

pub const Ship = struct {
    pos: Vec2,
    vel: Vec2,
    /// Facing direction in radians; thrust pushes along this heading.
    angle: f32 = 0,
    thrusting: bool = false,
};

/// Per-frame control input, produced by the renderer/input layer.
pub const Input = struct {
    /// -1 = turn left, +1 = turn right, 0 = hold heading.
    turn: f32 = 0,
    thrust: bool = false,
};

pub const World = struct {
    /// Gameplay gravitational constant — tuned for pixels, not real-world units.
    /// Kept low so orbital speeds stay arcade-slow and steerable.
    pub const g: f32 = 1200.0;
    /// Engine acceleration while thrusting, in px/s².
    pub const thrust_accel: f32 = 70.0;
    /// Turn speed in radians/second.
    pub const turn_rate: f32 = 2.8;

    planets: []const Planet,
    ship: Ship,

    /// Net gravitational acceleration felt at `point` from every planet.
    /// Distance is clamped to each planet's radius so the force stays finite
    /// (and orbits stay pure inverse-square everywhere outside the surface).
    pub fn gravityAt(self: World, point: Vec2) Vec2 {
        var acc: Vec2 = .{};
        for (self.planets) |p| {
            const d = p.pos.sub(point);
            const dist = @max(d.len(), p.radius);
            const mag = g * p.mass / (dist * dist);
            acc = acc.add(d.normalized().scale(mag));
        }
        return acc;
    }

    /// Advance the ship by `dt` seconds using semi-implicit Euler, which keeps
    /// closed orbits stable (energy oscillates rather than spiralling out).
    pub fn step(self: *World, dt: f32, input: Input) void {
        self.ship.angle += input.turn * turn_rate * dt;

        var acc = self.gravityAt(self.ship.pos);
        self.ship.thrusting = input.thrust;
        if (input.thrust) {
            acc = acc.add(Vec2.fromAngle(self.ship.angle).scale(thrust_accel));
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
