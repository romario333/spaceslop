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

/// A scripted Kepler ellipse tying one body to a parent body: the shape of
/// the orbit plus where along it the body starts. The world's planets are
/// pure kinematics riding these (see updateOrbits) — nothing perturbs them,
/// which is what lets the trajectory prediction know exactly where every
/// body will be at any future time.
pub const Orbit = struct {
    parent: usize,
    /// Semi-major axis in world px.
    semi_major: f32,
    /// Mean motion: average angular rate over one revolution, rad/s.
    omega: f32,
    /// Mean anomaly at t = 0 — where along the orbit the body starts.
    phase: f32,
    /// Eccentricity of the ellipse; the parent sits at a focus, not the centre.
    ecc: f32,
    /// Argument of periapsis: world angle of the closest-approach direction.
    peri: f32,
};

/// Advance every scripted orbit by `dt` and refresh each body's kinematic
/// state: position on its ellipse, world velocity, and frame acceleration
/// (the parent's acceleration plus the Kepler pull toward it). The
/// acceleration is what lets ships inside a moving SOI ride along with the
/// body (see Planet.acc). `specs` is index-aligned with `planets` (null =
/// a static root body); parents must precede their children so one pass
/// reads fresh parent state. `angles` holds each body's mean anomaly, which
/// grows uniformly; keplerState turns it into the unevenly-paced true motion.
pub fn updateOrbits(specs: []const ?Orbit, planets: []Planet, angles: []f32, dt: f32) void {
    for (specs, 0..) |maybe_orbit, i| {
        const o = maybe_orbit orelse continue;
        angles[i] = @mod(angles[i] + o.omega * dt, std.math.tau);
        const parent = planets[o.parent];
        const local = keplerState(o.semi_major, o.ecc, o.omega, angles[i]);
        const rel = local.pos.rotated(o.peri);
        planets[i].pos = parent.pos.add(rel);
        planets[i].vel = parent.vel.add(local.vel.rotated(o.peri));
        // Exact gravitational acceleration of the scripted ellipse: toward
        // the focus with μ = n²a³ (Kepler's third law), so riding ships see
        // a consistent frame at periapsis and apoapsis alike.
        const dist = rel.len();
        const mu = o.omega * o.omega * o.semi_major * o.semi_major * o.semi_major;
        planets[i].acc = parent.acc.add(rel.scale(-mu / (dist * dist * dist)));
    }
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
    /// Whether the body offers orbital services (refuel, hull repair — see
    /// World.serviceTarget). False for the gas giants: nothing to land on,
    /// nothing in orbit to dock with.
    services: bool = true,
};

pub const Ship = struct {
    /// Base tank unit, in fuel units: the size of one tank section. The HUD
    /// bar draws one unit at normal width, and the debug tank-upgrade action
    /// grows `tank` in steps of this.
    pub const max_fuel: f32 = 100.0;
    /// Collision radius, px — roughly the sprite's half-length. Shared by
    /// rock hits and the surface-impact check.
    pub const radius: f32 = 15;
    /// Full hull: the spawn value, and the ceiling orbital repairs restore to.
    pub const max_health: f32 = 100;
    /// Tank capacity at spawn — one base section.
    pub const start_tank: f32 = 100.0;

    pos: Vec2,
    vel: Vec2,
    /// Facing direction in radians; thrust pushes along this heading.
    angle: f32 = 0,
    /// Current tank capacity. The HUD fuel bar scales its width by
    /// `tank / max_fuel`, so an upgraded tank is visibly bigger.
    tank: f32 = start_tank,
    /// Propellant left in the tank. Each firing thruster burns
    /// `World.fuel_burn` per second; at zero the engines cut out.
    fuel: f32 = start_tank,
    thrusting: bool = false,
    /// Retro thrusters firing: the pair of small nose thrusters that push
    /// the ship backwards along its heading.
    braking: bool = false,
    /// Hull integrity, 0–100. Damaged by hazards (solar flares, asteroid
    /// collisions); clamped at zero. Flying into a planet's surface skips
    /// the hull entirely and destroys the ship outright (see `crash`).
    health: f32 = max_health,
    /// Taking on propellant / patching the hull this step, while parked near
    /// a body (see World.serviceTarget). Same role as `thrusting`:
    /// they say what actually happened, not what was asked for, so the
    /// renderer can light up only the service that is really running.
    refuelling: bool = false,
    repairing: bool = false,
    /// Seconds since the last rock hit still counting down (see
    /// hit_cooldown). Set on every collision, decays in step. Double duty:
    /// the renderer keys the impact sparks and the red hull readout off it,
    /// and no new hit lands while it runs — collisions don't deflect the
    /// ship, so this is what turns an overlap into one hit instead of
    /// damage on every step of the transit.
    hit_timer: f32 = 0,
    /// Set when the ship is destroyed by hitting a body's surface: the index
    /// of the planet it crashed into. The wreck stays pinned to the crash
    /// site (riding along if the body moves) and ignores all input until an
    /// outside reset builds a fresh Ship. Null while flying.
    crash: ?usize = null,
    /// Wreck position relative to the crash planet's centre, world frame.
    crash_offset: Vec2 = .{},

    pub fn alive(self: Ship) bool {
        return self.crash == null;
    }

    /// How long hit_timer runs after an impact: i-frames and feedback time.
    pub const hit_cooldown: f32 = 0.6;
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

/// A debris belt: an annulus of rocks centred on the sun. Every rock is a
/// real collider — the same kinematics the renderer draws — so damage comes
/// from actually hitting one, not from a fuzzy damage field. Each rock rides
/// a slow heliocentric circle with a radial wobble; on contact the ship takes
/// one arcade hit (scaled by impact speed and rock size) and flies on
/// undeflected — the hit cooldown plus the approaching-only check keep a
/// single pass through a rock from re-triggering every step. The world has
/// two of these: the rocky asteroid belt between Mars and Jupiter and the icy
/// Kuiper belt beyond Neptune; which is which is a `Band` of tuning numbers.
pub const Belt = struct {
    /// Collision radius of the ship (see Ship.radius).
    pub const ship_radius: f32 = Ship.radius;
    /// Ship-to-belt distance gate: beyond every rock's reach (max wobble +
    /// max rock size + ship radius), the whole collision pass is skipped.
    pub const gate_margin: f32 = 120;

    /// Geometry and pacing of one belt. The named constants below are the
    /// two bands the game ships with; `count` sets each band's hit odds
    /// (expected hits for a straight radial crossing ≈
    /// count · width · ~42 px combined collision width / band area).
    pub const Band = struct {
        /// Edge radii from the sun, px.
        inner: f32,
        outer: f32,
        /// Heliocentric drift rate mid-band, rad/s; fillRocks shears the
        /// swarm around it by Kepler's third law.
        mid_omega: f32,
        /// How many rocks fillRocks seeds the band with.
        count: usize,

        /// The classic belt, at its real place between Mars and Jupiter:
        /// 2.2–3.2 AU with Earth's orbit as 1 AU = 14500 px (see `orbits` in
        /// main.zig). Both edges have clear water at real spacing — Mars
        /// tops out near 25200, Jupiter's periapsis-minus-SOI begins around
        /// 66800. mid_omega matches the planets' arcade rate at r=39000
        /// (between Mars' 0.00032 and Jupiter's 0.000051). At 9000 rocks a
        /// 14500-px crossing expects ~1.5 hits: dodging is possible,
        /// complacency is punished.
        pub const asteroid: Band = .{ .inner = 31900, .outer = 46400, .mid_omega = 0.00014, .count = 9000 };
        /// The Kuiper belt at its real 30–50 AU, past Neptune's
        /// apoapsis-plus-SOI (~444600) and deep into the sun's outer SOI.
        /// Even 12000 rocks over this vast an annulus is sparse like the real thing: a
        /// straight crossing expects only ~0.14 hits. mid_omega is the same
        /// arcade Kepler rate carried out to r=580000.
        pub const kuiper: Band = .{ .inner = 435000, .outer = 725000, .mid_omega = 0.0000024, .count = 12000 };
    };

    pub const Rock = struct {
        /// Mean orbit radius from the sun; the wobble oscillates around it.
        orbit_r: f32,
        /// Collision radius — also the renderer's base size for the outline.
        size: f32,
        phase: f32 = 0,
        omega: f32 = 0,
        wob_amp: f32 = 0,
        wob_freq: f32 = 0,
        wob_phase: f32 = 0,
    };

    pub const State = struct { pos: Vec2, vel: Vec2 };

    band: Band = .asteroid,
    rocks: []const Rock,
    /// Belt clock, advanced by World.step — rock positions are a pure
    /// function of it, so a paused sim holds every rock still.
    time: f32 = 0,

    /// Where a rock is and how it's moving at belt time `t`, around `center`
    /// (the sun). Velocity is the analytic derivative: tangential drift plus
    /// the radial wobble rate — it feeds the impact-speed damage, so a rock
    /// jiggling toward the ship hits harder than one drifting away.
    pub fn rockState(rock: Rock, center: Vec2, t: f32) State {
        const wob = rock.wob_phase + rock.wob_freq * t;
        const r = rock.orbit_r + rock.wob_amp * @sin(wob);
        const dir = Vec2.fromAngle(rock.phase + rock.omega * t);
        const tangent: Vec2 = .{ .x = -dir.y, .y = dir.x };
        return .{
            .pos = center.add(dir.scale(r)),
            .vel = tangent.scale(rock.omega * r).add(dir.scale(rock.wob_amp * rock.wob_freq * @cos(wob))),
        };
    }

    /// Position-only rockState, for the render layer's zoomed-out speckle
    /// path where velocity is never used: skips the extra cos and the
    /// tangent/radial blend. Must stay in lockstep with rockState — the
    /// "rockPos matches rockState" test pins them together.
    pub fn rockPos(rock: Rock, center: Vec2, t: f32) Vec2 {
        const r = rock.orbit_r + rock.wob_amp * @sin(rock.wob_phase + rock.wob_freq * t);
        return center.add(Vec2.fromAngle(rock.phase + rock.omega * t).scale(r));
    }

    /// Hull cost of an impact: a speed term (hit hard, hurt more) plus a
    /// size term (boulders always cost something), clamped so a feather
    /// graze still stings and no single rock one-shots a full hull.
    pub fn hitDamage(impact_speed: f32, size: f32) f32 {
        return std.math.clamp(0.06 * impact_speed + 0.7 * size, 3, 30);
    }

    /// Seed `rocks` with `band`'s swarm. Radii follow a triangular
    /// distribution peaked mid-belt (mean of two uniforms), so the belt is
    /// thickest — and most dangerous — in the middle. Deterministic from
    /// `seed`; the renderer rolls its cosmetic attributes (shape, colour,
    /// spin) from its own stream, index-aligned with this array.
    pub fn fillRocks(rocks: []Rock, seed: u64, band: Band) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random();
        const width = band.outer - band.inner;
        const mid = (band.inner + band.outer) / 2.0;
        for (rocks) |*rock| {
            const u = (rng.float(f32) + rng.float(f32)) / 2.0;
            const orbit_r = band.inner + u * width;
            rock.* = .{
                .orbit_r = orbit_r,
                .phase = rng.float(f32) * std.math.tau,
                // Keplerian shear around the band's arcade rate, so inner
                // rocks visibly outpace outer ones over a long watch.
                .omega = band.mid_omega * std.math.pow(f32, mid / orbit_r, 1.5) * (0.9 + rng.float(f32) * 0.2),
                .wob_amp = 15.0 + rng.float(f32) * 60.0,
                .wob_freq = 0.15 + rng.float(f32) * 0.45,
                .wob_phase = rng.float(f32) * std.math.tau,
                // Squared: mostly gravel, the occasional boulder.
                .size = 2.5 + 16.0 * rng.float(f32) * rng.float(f32),
            };
        }
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
    /// Hold to take on propellant, and to patch the hull, from the body the
    /// ship is parked near. Ignored anywhere else (see World.serviceTarget);
    /// the two are independent, so both can run at once.
    refuel: bool = false,
    repair: bool = false,
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
    /// Propellant burned per second by each firing thruster — the main
    /// engine and the retro pair each cost this, so holding both burns
    /// double. This is one fifth of the original burn rate, making each unit
    /// of fuel five times as effective.
    pub const fuel_burn: f32 = 11.0;
    /// Propellant taken on per second while parked at a body (see
    /// serviceTarget).
    pub const refuel_rate: f32 = 12.0;
    /// Hull points repaired per second in the same situation.
    pub const repair_rate: f32 = 4.0;
    /// Services are only offered close in: within one of the body's own
    /// diameters (2× its radius, or its softened core where that is bigger).
    /// An SOI is far too generous a range on its own — Earth's reaches out
    /// past the moon, so parking near the moon would offer a top-up from an
    /// Earth 1500 px away.
    pub const service_range_factor: f32 = 2.5;
    /// The relative-speed window for services, as multiples of the circular
    /// orbit speed at the ship's current distance. Inside this band a stable
    /// orbit is likely: the ceiling stays below escape speed (√2 ≈ 1.414 of
    /// circular, so anything in-band is on a bound orbit that won't leave the
    /// body), and the floor rules out speeds so far under circular that the
    /// trajectory is a fall toward the surface rather than an orbit.
    pub const service_speed_min_factor: f32 = 0.75;
    pub const service_speed_max_factor: f32 = 1.3;

    /// How far out a body still services a ship: one of its diameters, never
    /// more than its own SOI (which is the smaller of the two for the tiny
    /// moons, whose bubbles barely clear their cores).
    pub fn serviceRange(p: Planet) f32 {
        return @min(service_range_factor * @max(p.radius, p.core), p.soi);
    }

    planets: []const Planet,
    ship: Ship,
    /// At most one flare at a time; null when the sun is quiet.
    flare: ?Flare = null,
    /// The asteroid belt, if this world has one (tests mostly don't).
    belt: ?Belt = null,
    /// The Kuiper belt — same machinery as `belt`, icy band beyond Neptune.
    kuiper: ?Belt = null,

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

    /// Shape of the ship's orbit around one body, in that body's frame: the
    /// two elements that say whether it is parked there or merely passing
    /// through. On an escape trajectory `bound` is false and the radii are
    /// meaningless (the conic is a hyperbola, with no apoapsis).
    pub const OrbitShape = struct {
        peri: f32 = 0,
        apo: f32 = 0,
        bound: bool = false,
    };

    /// The ship's orbit around planet `idx`, from the vis-viva energy and the
    /// angular momentum of its relative motion. Kepler elements, so they only
    /// describe the real trajectory while the ship stays in this body's SOI
    /// and outside its softened core (see Planet.core).
    pub fn orbitAround(self: World, idx: usize) OrbitShape {
        const p = self.planets[idx];
        const rel = self.ship.pos.sub(p.pos);
        const r = @max(rel.len(), 0.001);
        const rel_vel = self.ship.vel.sub(p.vel);
        const mu = g * p.mass;
        const energy = rel_vel.lenSq() / 2.0 - mu / r;
        if (energy >= 0 or mu <= 0) return .{}; // unbound: no closed orbit
        const a = -mu / (2.0 * energy);
        const h = rel.x * rel_vel.y - rel.y * rel_vel.x;
        const e = @sqrt(@max(0.0, 1.0 - h * h / (mu * a)));
        return .{ .peri = a * (1 - e), .apo = a * (1 + e), .bound = true };
    }

    /// The body whose orbital services (refuel, hull repair) the ship can use
    /// right now, or null if it isn't parked anywhere. "Parked" means two
    /// things, both judged from the ship's state right now rather than from
    /// full Kepler elements (which rejected slightly eccentric orbits and made
    /// the prompt feel flaky): the ship is close — within one of the body's
    /// diameters (see serviceRange) — and its relative speed sits in a band
    /// around the local circular-orbit speed where a stable orbit is likely
    /// (see service_speed_min_factor / service_speed_max_factor). The body
    /// must offer services at all (see Planet.services — gas giants don't),
    /// and the root body never serves — you don't dock with the sun.
    pub fn serviceTarget(self: World) ?usize {
        if (!self.ship.alive()) return null;
        const idx = self.dominantIndex(self.ship.pos) orelse return null;
        if (idx == 0) return null;
        const p = self.planets[idx];
        if (!p.services) return null;
        const dist = self.ship.pos.sub(p.pos).len();
        if (dist > serviceRange(p)) return null;
        // Clamped like gravityAt, so the reference speed stays finite even if
        // the ship somehow samples inside the body's surface.
        const v_circ = circularOrbitSpeed(p.mass, @max(dist, @max(p.radius, p.core)));
        const v_rel = self.ship.vel.sub(p.vel).len();
        if (v_rel < service_speed_min_factor * v_circ) return null;
        if (v_rel > service_speed_max_factor * v_circ) return null;
        return idx;
    }

    /// Advance the ship by `dt` seconds using semi-implicit Euler, which keeps
    /// closed orbits stable (energy oscillates rather than spiralling out).
    pub fn step(self: *World, dt: f32, input: Input) void {
        // Ambient clocks tick first, alive or not — the world doesn't
        // pause for a wreck.
        if (self.flare) |*fl| {
            fl.age += dt;
            if (fl.expired()) self.flare = null;
        }
        self.ship.hit_timer = @max(0, self.ship.hit_timer - dt);
        // Cleared up front so they stay false on every path that returns
        // early (a wreck services nothing).
        self.ship.refuelling = false;
        self.ship.repairing = false;

        // A wreck doesn't fly: pin it to the crash site (riding along if
        // the body moves), ignore all input, and skip every hazard.
        if (self.ship.crash) |idx| {
            const p = self.planets[idx];
            self.ship.pos = p.pos.add(self.ship.crash_offset);
            self.ship.vel = p.vel;
            if (self.belt) |*b| b.time += dt;
            if (self.kuiper) |*b| b.time += dt;
            return;
        }

        self.ship.angle += input.turn * turn_rate * dt;

        var acc = self.ballisticAccel(self.ship.pos, self.ship.vel);
        // Thrusters only fire with propellant in the tank. The flags track
        // what actually fires, so engine flames die with the fuel.
        const has_fuel = self.ship.fuel > 0;
        self.ship.thrusting = input.thrust and has_fuel;
        self.ship.braking = input.brake and has_fuel;
        var burn: f32 = 0;
        if (self.ship.thrusting) {
            acc = acc.add(Vec2.fromAngle(self.ship.angle).scale(thrust_accel));
            burn += fuel_burn;
        }
        // Two small nose thrusters, same total power as the main engine.
        if (self.ship.braking) {
            acc = acc.add(Vec2.fromAngle(self.ship.angle).scale(-thrust_accel));
            burn += fuel_burn;
        }
        self.ship.fuel = @max(0, self.ship.fuel - burn * dt);

        self.ship.vel = self.ship.vel.add(acc.scale(dt)); // velocity first...
        self.ship.pos = self.ship.pos.add(self.ship.vel.scale(dt)); // ...then position

        // Flare damage (the flare itself was aged at the top of the step).
        if (self.flare) |fl| {
            if (!fl.warning() and fl.contains(self.ship.pos)) {
                self.ship.health = @max(0, self.ship.health - Flare.damage_per_sec * dt);
            }
        }

        // Belts: collide the ship against the actual rock swarms. The shared
        // hit cooldown means at most one strike lands per step across both.
        if (self.belt) |*belt| self.collideBelt(belt, dt);
        if (self.kuiper) |*belt| self.collideBelt(belt, dt);

        // Surface impact: touching the ground destroys the ship. Only the
        // SOI owner is checked — every body sits well inside its own SOI,
        // so nothing else can be close enough to hit.
        if (self.dominantIndex(self.ship.pos)) |idx| {
            const p = self.planets[idx];
            const off = self.ship.pos.sub(p.pos);
            if (off.len() < p.radius + Ship.radius) {
                self.ship.crash = idx;
                // Pin the wreck at the surface so it doesn't render sunk.
                self.ship.crash_offset = off.normalized().scale(p.radius + Ship.radius);
                self.ship.pos = p.pos.add(self.ship.crash_offset);
                self.ship.vel = p.vel;
                self.ship.health = 0;
                self.ship.thrusting = false;
                self.ship.braking = false;
                self.ship.hit_timer = Ship.hit_cooldown; // impact flash + sparks
            }
        }

        // Orbital services. Last in the step, on the state the player will
        // actually see this frame: a burn that breaks the orbit stops the
        // pumps in the same step it happens, and a crash above has already
        // ruled the ship out.
        if (self.serviceTarget() != null) {
            if (input.refuel and self.ship.fuel < self.ship.tank) {
                self.ship.fuel = @min(self.ship.tank, self.ship.fuel + refuel_rate * dt);
                self.ship.refuelling = true;
            }
            if (input.repair and self.ship.health < Ship.max_health) {
                self.ship.health = @min(Ship.max_health, self.ship.health + repair_rate * dt);
                self.ship.repairing = true;
            }
        }
    }

    /// Advance one belt's clock and collide the ship against its swarm.
    fn collideBelt(self: *World, belt: *Belt, dt: f32) void {
        belt.time += dt;
        const center = if (self.planets.len > 0) self.planets[0].pos else Vec2{};
        const rel = self.ship.pos.sub(center);
        const ship_r = rel.len();
        // Radial gate: skip the whole pass unless the ship is within any
        // rock's possible reach of the annulus. The cooldown gate keeps
        // the hits discrete — the ship isn't deflected by a collision,
        // so without it an overlap would deal damage every step.
        if (self.ship.hit_timer <= 0 and
            ship_r > belt.band.inner - Belt.gate_margin and ship_r < belt.band.outer + Belt.gate_margin)
        {
            const ship_ang = std.math.atan2(rel.y, rel.x);
            for (belt.rocks) |rock| {
                // Bearing prefilter: the arc between the ship's and the
                // rock's bearings lower-bounds their distance (radii are
                // within reach of orbit_r or the radial gate failed), so
                // ~everything skips before paying for the rock's sincos.
                const reach = rock.size + Belt.ship_radius + rock.wob_amp;
                const dang = @mod(rock.phase + rock.omega * belt.time - ship_ang + std.math.pi, std.math.tau) - std.math.pi;
                if (@abs(dang) * (rock.orbit_r - 200.0) > reach + 10.0) continue;

                const st = Belt.rockState(rock, center, belt.time);
                const d = self.ship.pos.sub(st.pos);
                const dist = d.len();
                const min_dist = rock.size + Belt.ship_radius;
                if (dist >= min_dist) continue;
                const n = if (dist > 0.001) d.scale(1.0 / dist) else Vec2{ .x = 1 };
                const vn = self.ship.vel.sub(st.vel).dot(n);
                if (vn >= 0) continue; // overlapping but already separating

                // Crunch: damage from the closing speed. The ship's
                // trajectory is untouched — it punches straight through,
                // and the cooldown plus the separating check above stop
                // the same rock from hitting again on the way out.
                self.ship.health = @max(0, self.ship.health - Belt.hitDamage(-vn, rock.size));
                self.ship.hit_timer = Ship.hit_cooldown;
                break;
            }
        }
    }

    /// Acceleration a coasting ship feels at `pos` moving at `vel`:
    /// patched-conic gravity, the SOI owner's frame acceleration, and
    /// capture-assist drag — every force except thrust. Split out of `step`
    /// so the trajectory prediction integrates exactly what the live sim
    /// applies to a ballistic ship.
    pub fn ballisticAccel(self: World, pos: Vec2, vel: Vec2) Vec2 {
        var acc = self.gravityAt(pos);
        if (self.dominantIndex(pos)) |idx| {
            const p = self.planets[idx];
            // Ride along with a moving SOI owner (see Planet.acc).
            acc = acc.add(p.acc);
            // Capture assist — satellites only (planets[0] is the root body;
            // dragging inside its SOI would decay every heliocentric orbit).
            // Applies only to ships that are bound to the body (negative
            // relative energy) in the outer SOI; fast hyperbolic flybys keep
            // full slingshot behaviour.
            if (idx > 0) {
                const dist = pos.sub(p.pos).len();
                if (dist > capture_zone * p.soi) {
                    const v_rel = vel.sub(p.vel);
                    const energy = v_rel.lenSq() / 2.0 - g * p.mass / @max(dist, @max(p.radius, p.core));
                    if (energy < 0) acc = acc.add(v_rel.scale(-capture_drag));
                }
            }
        }
        return acc;
    }

    /// Speed needed for a circular orbit at `radius` around a planet of `mass`.
    /// Handy for placing the ship in a stable starting orbit.
    pub fn circularOrbitSpeed(mass: f32, radius: f32) f32 {
        return @sqrt(g * mass / radius);
    }
};

/// A position remembered in the reference frame that owned it: stored as an
/// offset from the dominant SOI body (absolute in deep space), so it rides
/// along with that body instead of staying pinned where the body used to be
/// — or, for predicted points, where it will be. In the outer band of an SOI
/// the point also keeps an offset in the enclosing frame and the two are
/// blended, so a path crossing an SOI boundary deforms as a smooth curve
/// instead of kinking where the anchor switches. Shared by the ship trail
/// (past positions) and the trajectory prediction (future positions).
pub const FramePoint = struct {
    /// Fraction of the SOI radius where blending toward the enclosing frame
    /// begins; at the edge itself a point rides the enclosing frame entirely,
    /// which matches the first point captured on the other side.
    pub const blend_band = 0.8;

    /// Offset from the anchor body (absolute position when anchor is null).
    off: Vec2,
    /// Offset from the enclosing body (absolute when enclosing is null).
    off_outer: Vec2,
    anchor: ?usize,
    enclosing: ?usize,
    /// 1 = fully anchor frame, 0 = fully enclosing frame.
    blend: f32,

    /// Record world position `p` relative to whatever body dominates it in
    /// `world` — for the trail that is the live world, for a prediction the
    /// scratch world advanced into the future.
    pub fn capture(world: *const World, p: Vec2) FramePoint {
        var pt = FramePoint{ .off = p, .off_outer = p, .anchor = null, .enclosing = null, .blend = 1 };
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
        return pt;
    }

    /// The point mapped back to world space against wherever its anchor
    /// bodies sit in `planets` now — usually not where they were (or will
    /// be) at capture time. That relocation is the whole trick: an orbit
    /// predicted around a moving moon draws as an ellipse around the moon's
    /// current position.
    pub fn resolve(self: FramePoint, planets: []const Planet) Vec2 {
        const inner = if (self.anchor) |a| planets[a].pos.add(self.off) else self.off;
        if (self.blend >= 1.0) return inner;
        const outer = if (self.enclosing) |e| planets[e].pos.add(self.off_outer) else self.off_outer;
        return outer.add(inner.sub(outer).scale(self.blend));
    }
};

/// The ship's predicted coast: where it goes from here with the engines off.
/// `predict` forward-integrates a scratch copy of the world — same
/// semi-implicit Euler, same forces (ballisticAccel), planets advanced along
/// their scripted ellipses — and stores the path as FramePoints, so the
/// renderer can draw each future position relative to where its dominant
/// body is *now*. Recomputed every frame; cheap enough because the timestep
/// adapts to the local orbital timescale (see the `dyn_divisor` comment).
pub const Trajectory = struct {
    /// Path resolution cap. Sampling is time-based (`horizon / max_points`),
    /// so a short orbit gets densely spaced points and a long transfer
    /// spreads the same budget thin — where it is drawn zoomed out anyway.
    pub const max_points = 1024;
    /// Upper bound on world size, so predict needs no allocator or caller
    /// scratch space.
    pub const max_bodies = 32;
    /// How far ahead an unbound (escape / deep space) coast is integrated,
    /// sim-seconds. Sized to cover a heliocentric hop to a neighbouring
    /// planet (a Mars transfer half-ellipse is ~6.6 min of sim time).
    pub const max_horizon: f32 = 420.0;
    /// A bound orbit is predicted for just over one revolution: enough to
    /// close the loop on screen without moiré from overdrawn precessing laps.
    const loop_fraction: f32 = 1.1;
    /// The integration step is the local dynamical time sqrt(r³/μ) divided
    /// by this. 240 matches the live sim's own accuracy — the spawn orbit
    /// runs at r³/μ ≈ 2 s against the 1/120 s fixed step — so deep in a well
    /// the prediction steps exactly like the sim, and in the slow far field
    /// it takes strides up to `max_dt_factor` bigger for the same phase
    /// error per orbit.
    const dyn_divisor: f32 = 240.0;
    const max_dt_factor: f32 = 16.0;
    /// Between exact Kepler resyncs the planets coast on their stored
    /// velocity. The fastest bodies move ~20 px/s with centripetal
    /// acceleration under 0.5 px/s², so a second of linear drift stays
    /// well under a pixel — and the resync recomputes positions absolutely
    /// from the mean anomalies, so error never accumulates.
    const resync_interval: f32 = 1.0;

    points: [max_points]FramePoint = undefined,
    /// Sim-seconds into the future of each point; times[0] = 0, the ship now.
    times: [max_points]f32 = undefined,
    count: usize = 0,
    /// Body the coast ends on when the path hits a surface, else null.
    impact: ?usize = null,

    /// Integrate the ship's engines-off future from the live `world` state.
    /// `specs`/`angles` are the scripted-orbit table and current mean
    /// anomalies (see updateOrbits); `base_dt` is the sim's fixed timestep.
    pub fn predict(self: *Trajectory, world: *const World, specs: []const ?Orbit, angles: []const f32, base_dt: f32) void {
        self.count = 0;
        self.impact = null;
        if (!world.ship.alive()) return;
        std.debug.assert(world.planets.len <= max_bodies);

        // Scratch copies to march into the future; the caller's world is
        // untouched.
        var planets: [max_bodies]Planet = undefined;
        var ang: [max_bodies]f32 = undefined;
        const n = world.planets.len;
        @memcpy(planets[0..n], world.planets);
        @memcpy(ang[0..n], angles[0..n]);
        var w: World = .{ .planets = planets[0..n], .ship = world.ship };

        // Horizon: just over one lap of a bound orbit, else the transfer cap.
        var horizon: f32 = max_horizon;
        if (world.dominantIndex(world.ship.pos)) |i| {
            const shape = world.orbitAround(i);
            if (shape.bound) {
                const a = (shape.peri + shape.apo) / 2.0;
                const period = std.math.tau * @sqrt(a * a * a / (World.g * world.planets[i].mass));
                horizon = @min(loop_fraction * period, max_horizon);
            }
        }
        const sample_dt = horizon / @as(f32, @floatFromInt(max_points - 1));

        var pos = world.ship.pos;
        var vel = world.ship.vel;
        self.push(&w, pos, 0);
        var t: f32 = 0;
        var next_sample = sample_dt;
        var since_resync: f32 = 0;
        while (t < horizon and self.count < max_points) {
            // Step size from the local dynamical time (see dyn_divisor).
            var dt = base_dt * max_dt_factor;
            if (w.dominantIndex(pos)) |i| {
                const p = planets[i];
                const r = @max(pos.sub(p.pos).len(), @max(p.radius, p.core));
                const t_dyn = @sqrt(r * r * r / (World.g * p.mass));
                dt = std.math.clamp(t_dyn / dyn_divisor, base_dt, base_dt * max_dt_factor);
            }

            // Planets first, then the ship — the order the live loop uses.
            since_resync += dt;
            if (since_resync >= resync_interval) {
                updateOrbits(specs, planets[0..n], ang[0..n], since_resync);
                since_resync = 0;
            } else {
                for (planets[0..n]) |*p| p.pos = p.pos.add(p.vel.scale(dt));
            }

            const acc = w.ballisticAccel(pos, vel);
            vel = vel.add(acc.scale(dt)); // velocity first...
            pos = pos.add(vel.scale(dt)); // ...then position, like step()
            t += dt;

            // A coast that meets a surface ends there, like the ship would.
            if (w.dominantIndex(pos)) |i| {
                const p = planets[i];
                if (pos.sub(p.pos).len() < p.radius + Ship.radius) {
                    self.impact = i;
                    self.push(&w, pos, t);
                    return;
                }
            }

            if (t >= next_sample) {
                self.push(&w, pos, t);
                next_sample += sample_dt;
            }
        }
    }

    fn push(self: *Trajectory, w: *const World, p: Vec2, t: f32) void {
        if (self.count == max_points) return;
        self.points[self.count] = FramePoint.capture(w, p);
        self.times[self.count] = t;
        self.count += 1;
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

test "flying into a planet destroys the ship" {
    var world: World = .{
        .planets = &.{.{ .pos = .{}, .mass = 1000, .radius = 100 }},
        // Head-on dive from 200 px out; contact at 115 px.
        .ship = .{ .pos = .{ .x = 200, .y = 0 }, .vel = .{ .x = -150, .y = 0 } },
    };
    stepFor(&world, 1.0);
    try testing.expect(!world.ship.alive());
    try testing.expectEqual(@as(f32, 0), world.ship.health);
    // The wreck sits pinned at the surface, not sunk inside the planet.
    try testing.expectApproxEqRel(100.0 + Ship.radius, world.ship.pos.len(), 1e-3);

    // Dead ships don't fly: input is ignored and the wreck stays put.
    const pos = world.ship.pos;
    var t: f32 = 0;
    while (t < 1.0) : (t += 0.01) world.step(0.01, .{ .thrust = true, .turn = 1 });
    try testing.expectEqual(pos.x, world.ship.pos.x);
    try testing.expectEqual(pos.y, world.ship.pos.y);
    try testing.expect(!world.ship.thrusting);
    try testing.expectEqual(Ship.start_tank, world.ship.fuel);
}

test "the wreck rides a moving planet" {
    var planets = [_]Planet{.{ .pos = .{}, .mass = 1000, .radius = 100 }};
    var world: World = .{
        .planets = &planets,
        .ship = .{ .pos = .{ .x = 110, .y = 0 }, .vel = .{ .x = -50, .y = 0 } },
    };
    world.step(0.01, .{});
    try testing.expect(!world.ship.alive());

    // The kinematic driver moves the planet; the wreck must move with it.
    planets[0].pos = .{ .x = 500, .y = 300 };
    planets[0].vel = .{ .x = 10, .y = 0 };
    world.step(0.01, .{});
    try testing.expectApproxEqRel(500.0 + 100.0 + Ship.radius, world.ship.pos.x, 1e-4);
    try testing.expectEqual(@as(f32, 300), world.ship.pos.y);
    try testing.expectEqual(@as(f32, 10), world.ship.vel.x);
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

// A lone stationary boulder mid-belt (omega and wobble zero), at bearing 0:
// its centre sits at (39150, 0). Contact happens at distance size+ship_radius.
const test_rock = [_]Belt.Rock{.{ .orbit_r = 39150, .size = 20 }};

test "flying through a rock: one hit, trajectory untouched" {
    var world: World = .{
        .planets = &.{},
        .belt = .{ .rocks = &test_rock },
        // 100 px/s straight at the rock from 60 px out (contact at 35 px).
        // The 70 px contact zone takes 0.7 s to transit — longer than the
        // 0.6 s cooldown, so the separating check must carry the last leg.
        .ship = .{ .pos = .{ .x = 39150 - 60, .y = 0 }, .vel = .{ .x = 100, .y = 0 } },
    };
    stepFor(&world, 2.0);
    // Head-on at 100 px/s into a size-20 rock: one hit of exactly hitDamage.
    try testing.expectApproxEqRel(100.0 - Belt.hitDamage(100, 20), world.ship.health, 1e-4);
    // No deflection: same velocity, and the ship came out the far side.
    try testing.expectEqual(@as(f32, 100), world.ship.vel.x);
    try testing.expectEqual(@as(f32, 0), world.ship.vel.y);
    try testing.expect(world.ship.pos.x > 39150 + 35);

    // Well past the rock: no further hits, and the hit flash has decayed.
    const after = world.ship.health;
    stepFor(&world, 1.0);
    try testing.expectEqual(after, world.ship.health);
    try testing.expectEqual(@as(f32, 0), world.ship.hit_timer);
}

test "a hit raises the hit flash timer" {
    var world: World = .{
        .planets = &.{},
        .belt = .{ .rocks = &test_rock },
        .ship = .{ .pos = .{ .x = 39150 - 40, .y = 0 }, .vel = .{ .x = 100, .y = 0 } },
    };
    stepFor(&world, 0.1);
    try testing.expect(world.ship.health < 100);
    try testing.expect(world.ship.hit_timer > 0);
}

test "passing clear of every rock costs nothing" {
    var world: World = .{
        .planets = &.{},
        .belt = .{ .rocks = &test_rock },
        // Same crossing, offset 100 px sideways: clears the 35 px contact
        // radius. Radial gate and bearing prefilter must not create hits.
        .ship = .{ .pos = .{ .x = 39050, .y = 100 }, .vel = .{ .x = 100, .y = 0 } },
    };
    stepFor(&world, 2.0);
    try testing.expectEqual(@as(f32, 100), world.ship.health);
    try testing.expectEqual(@as(f32, 0), world.ship.hit_timer);
}

test "rock collision damage clamps health at zero" {
    var world: World = .{
        .planets = &.{},
        .belt = .{ .rocks = &test_rock },
        .ship = .{ .pos = .{ .x = 39150 - 40, .y = 0 }, .vel = .{ .x = 100, .y = 0 }, .health = 0.5 },
    };
    stepFor(&world, 0.5);
    try testing.expectEqual(@as(f32, 0), world.ship.health);
}

test "rockState: wobble and drift produce matching analytic velocity" {
    const rock: Belt.Rock = .{ .orbit_r = 24000, .size = 5, .phase = 1.0, .omega = 0.0003, .wob_amp = 40, .wob_freq = 0.3, .wob_phase = 0.7 };
    const t: f32 = 100;
    // Positions are ~24000 px, so a tiny dt would difference away all the
    // f32 mantissa; 0.2 s keeps the delta well above rounding noise while
    // truncation error stays ~0.01 px/s.
    const dt: f32 = 0.2;
    const s = Belt.rockState(rock, .{}, t);
    const ahead = Belt.rockState(rock, .{}, t + dt);
    const behind = Belt.rockState(rock, .{}, t - dt);
    try testing.expectApproxEqAbs(s.vel.x, (ahead.pos.x - behind.pos.x) / (2 * dt), 0.1);
    try testing.expectApproxEqAbs(s.vel.y, (ahead.pos.y - behind.pos.y) / (2 * dt), 0.1);
}

test "each firing thruster burns fuel; both together burn double" {
    var one: World = .{ .planets = &.{}, .ship = .{ .pos = .{}, .vel = .{} } };
    one.step(0.1, .{ .thrust = true });
    try testing.expectApproxEqRel(Ship.start_tank - World.fuel_burn * 0.1, one.ship.fuel, 1e-5);

    var both: World = .{ .planets = &.{}, .ship = .{ .pos = .{}, .vel = .{} } };
    both.step(0.1, .{ .thrust = true, .brake = true });
    try testing.expectApproxEqRel(Ship.start_tank - 2.0 * World.fuel_burn * 0.1, both.ship.fuel, 1e-5);

    // Coasting is free.
    var coast: World = .{ .planets = &.{}, .ship = .{ .pos = .{}, .vel = .{} } };
    coast.step(0.1, .{ .turn = 1 });
    try testing.expectEqual(Ship.start_tank, coast.ship.fuel);
}

test "empty tank kills thrust and never goes negative" {
    // Almost-dry tank: the last sliver burns away and clamps at exactly zero.
    var world: World = .{ .planets = &.{}, .ship = .{ .pos = .{}, .vel = .{}, .fuel = 0.01 } };
    world.step(0.1, .{ .thrust = true });
    try testing.expectEqual(@as(f32, 0), world.ship.fuel);

    // Dry: engines refuse to fire and the ship keeps coasting unchanged.
    const vel_before = world.ship.vel;
    world.step(0.1, .{ .thrust = true, .brake = true });
    try testing.expect(!world.ship.thrusting);
    try testing.expect(!world.ship.braking);
    try testing.expectEqual(vel_before.x, world.ship.vel.x);
    try testing.expectEqual(vel_before.y, world.ship.vel.y);
}

// Sun plus one Earth-like body 15000 px out, with the ship on a circular
// 250-px orbit around it — comfortably inside the body's 280-px service
// range (one diameter of its 140-px radius).
fn parkedWorld() World {
    const planets = struct {
        const list = [_]Planet{
            .{ .pos = .{}, .mass = 100000, .radius = 600, .soi = 40000 },
            .{ .pos = .{ .x = 15000, .y = 0 }, .mass = 8000, .radius = 140, .soi = 2500 },
        };
    }.list;
    const r: f32 = 250;
    return .{
        .planets = &planets,
        .ship = .{
            .pos = .{ .x = 15000 + r, .y = 0 },
            .vel = .{ .x = 0, .y = World.circularOrbitSpeed(planets[1].mass, r) },
        },
    };
}

test "a stable orbit around a body offers its services" {
    var world = parkedWorld();
    try testing.expectEqual(@as(?usize, 1), world.serviceTarget());
    const orbit = world.orbitAround(1);
    try testing.expect(orbit.bound);
    try testing.expectApproxEqRel(@as(f32, 250), orbit.peri, 1e-3);
    try testing.expectApproxEqRel(@as(f32, 250), orbit.apo, 1e-3);

    // A moderately eccentric orbit close in qualifies too: the prompt keys
    // off distance and relative speed, not a perfectly contained ellipse
    // (the old apoapsis check rejected this one and made the prompt flaky).
    var eccentric = parkedWorld();
    eccentric.ship.vel = .{ .x = 0, .y = 1.2 * World.circularOrbitSpeed(eccentric.planets[1].mass, 250) };
    try testing.expect(eccentric.orbitAround(1).apo > World.serviceRange(eccentric.planets[1]));
    try testing.expectEqual(@as(?usize, 1), eccentric.serviceTarget());

    // The root body is never a service target, however tidy the orbit is.
    var solar = parkedWorld();
    solar.ship = .{
        .pos = .{ .x = 15000, .y = 0 },
        .vel = .{ .y = World.circularOrbitSpeed(solar.planets[0].mass, 15000) },
    };
    // Sitting on the planet's own position would hand the SOI to the planet;
    // check from clear water between the two SOIs instead.
    solar.ship.pos = .{ .x = 10000, .y = 0 };
    solar.ship.vel = .{ .y = World.circularOrbitSpeed(solar.planets[0].mass, 10000) };
    try testing.expectEqual(@as(?usize, 0), solar.dominantIndex(solar.ship.pos));
    try testing.expectEqual(@as(?usize, null), solar.serviceTarget());
}

test "unstable trajectories offer nothing" {
    // Hyperbolic flyby: relative speed far above the service band.
    var flyby = parkedWorld();
    flyby.ship.vel = .{ .x = 0, .y = 400 };
    try testing.expect(!flyby.orbitAround(1).bound);
    try testing.expectEqual(@as(?usize, null), flyby.serviceTarget());

    // Technically bound (just under escape, ~277), but far enough over the
    // circular-orbit speed (~196) that the ship is about to swing away from
    // the body, not park at it.
    var leaky = parkedWorld();
    leaky.ship.vel = .{ .x = 0, .y = 260 };
    try testing.expect(leaky.orbitAround(1).bound);
    try testing.expectEqual(@as(?usize, null), leaky.serviceTarget());

    // A perfectly circular orbit, but out past two of the body's diameters:
    // that's cruising near the body, not parked at it, however stable.
    var high = parkedWorld();
    const far: f32 = 800;
    try testing.expect(far > World.serviceRange(high.planets[1]));
    try testing.expect(far < high.planets[1].soi);
    high.ship.pos = .{ .x = 15000 + far, .y = 0 };
    high.ship.vel = .{ .x = 0, .y = World.circularOrbitSpeed(high.planets[1].mass, far) };
    try testing.expect(high.orbitAround(1).bound);
    try testing.expectEqual(@as(?usize, null), high.serviceTarget());

    // Close in but crawling, far below circular speed: that's a fall toward
    // the surface, not a parking orbit.
    var falling = parkedWorld();
    falling.ship.vel = .{ .x = 0, .y = 40 };
    const falling_orbit = falling.orbitAround(1);
    try testing.expect(falling_orbit.bound and falling_orbit.peri < falling.planets[1].radius);
    try testing.expectEqual(@as(?usize, null), falling.serviceTarget());

    // A wreck is beyond help.
    var dead = parkedWorld();
    dead.ship.crash = 1;
    try testing.expectEqual(@as(?usize, null), dead.serviceTarget());
}

test "a body without services offers nothing however well parked" {
    // Same parked shape as parkedWorld, but the body is marked serviceless
    // (a gas giant): a perfect low circular orbit still gets no prompt.
    const planets = struct {
        const list = [_]Planet{
            .{ .pos = .{}, .mass = 100000, .radius = 600, .soi = 40000 },
            .{ .pos = .{ .x = 15000, .y = 0 }, .mass = 8000, .radius = 140, .soi = 2500, .services = false },
        };
    }.list;
    const r: f32 = 250;
    var world: World = .{
        .planets = &planets,
        .ship = .{
            .pos = .{ .x = 15000 + r, .y = 0 },
            .vel = .{ .x = 0, .y = World.circularOrbitSpeed(planets[1].mass, r) },
        },
    };
    try testing.expectEqual(@as(?usize, null), world.serviceTarget());
}

test "parked services refill the tank and the hull, and stop when full" {
    var world = parkedWorld();
    world.ship.fuel = 25;
    world.ship.health = 40;
    const dt: f32 = 0.01;
    world.step(dt, .{ .refuel = true, .repair = true });
    try testing.expectApproxEqRel(25 + World.refuel_rate * dt, world.ship.fuel, 1e-4);
    try testing.expectApproxEqRel(40 + World.repair_rate * dt, world.ship.health, 1e-4);
    try testing.expect(world.ship.refuelling and world.ship.repairing);

    // Held long enough, both top out exactly at their caps and the flags
    // drop — nothing keeps running against a full tank.
    var t: f32 = 0;
    while (t < 60) : (t += dt) world.step(dt, .{ .refuel = true, .repair = true });
    try testing.expectEqual(Ship.start_tank, world.ship.fuel);
    try testing.expectEqual(Ship.max_health, world.ship.health);
    try testing.expect(!world.ship.refuelling and !world.ship.repairing);

    // Asking for nothing changes nothing.
    world.ship.fuel = 10;
    world.step(dt, .{});
    try testing.expectEqual(@as(f32, 10), world.ship.fuel);
    try testing.expect(!world.ship.refuelling);
}

test "services do nothing off a stable orbit" {
    var flyby = parkedWorld();
    flyby.ship.vel = .{ .x = 0, .y = 400 };
    flyby.ship.fuel = 100;
    flyby.ship.health = 40;
    flyby.step(0.01, .{ .refuel = true, .repair = true });
    try testing.expectEqual(@as(f32, 100), flyby.ship.fuel);
    try testing.expectEqual(@as(f32, 40), flyby.ship.health);
    try testing.expect(!flyby.ship.refuelling and !flyby.ship.repairing);
}

test "rockPos matches rockState position" {
    var rocks: [64]Belt.Rock = undefined;
    Belt.fillRocks(&rocks, 0xDEAD_BEEF, .asteroid);
    const center: Vec2 = .{ .x = 12.5, .y = -3.75 };
    for (rocks) |rock| {
        for ([_]f32{ 0, 1.7, 300.0, 12345.6 }) |t| {
            const full = Belt.rockState(rock, center, t).pos;
            const fast = Belt.rockPos(rock, center, t);
            try testing.expectEqual(full.x, fast.x);
            try testing.expectEqual(full.y, fast.y);
        }
    }
}

test "updateOrbits keeps a scripted body on its ellipse" {
    var planets = [_]Planet{
        .{ .pos = .{}, .mass = 100000, .radius = 600 }, // static root
        .{ .pos = .{}, .mass = 8000, .radius = 140 },
    };
    const specs = [_]?Orbit{
        null,
        .{ .parent = 0, .semi_major = 1000, .omega = 0.01, .phase = 0, .ecc = 0, .peri = 0 },
    };
    var angles = [_]f32{ 0, specs[1].?.phase };
    updateOrbits(&specs, &planets, &angles, 0); // initial placement
    try testing.expectApproxEqRel(@as(f32, 1000), planets[1].pos.x, 1e-5);

    // A circular orbit paces uniformly: after dt the body sits at mean
    // anomaly omega*dt on the circle, moving tangentially at omega*a.
    updateOrbits(&specs, &planets, &angles, 25);
    try testing.expectApproxEqRel(1000 * @cos(0.25), planets[1].pos.x, 1e-4);
    try testing.expectApproxEqRel(1000 * @sin(0.25), planets[1].pos.y, 1e-4);
    try testing.expectApproxEqRel(@as(f32, 10), planets[1].vel.len(), 1e-4);
    // Frame acceleration points back at the parent with mu = n^2 a^3.
    try testing.expectApproxEqRel(@as(f32, 0.1), planets[1].acc.len(), 1e-4);
    try testing.expect(planets[1].acc.dot(planets[1].pos) < 0);
}

test "trajectory prediction matches the live sim while coasting" {
    // One static planet, ship deep in the well: the adaptive step clamps to
    // base_dt there, so predict and the live loop run identical arithmetic.
    const specs = [_]?Orbit{null};
    var angles = [_]f32{0};
    var planets = [_]Planet{.{ .pos = .{}, .mass = 8000, .radius = 140 }};
    const r: f32 = 300;
    var world: World = .{
        .planets = &planets,
        .ship = .{ .pos = .{ .x = r, .y = 0 }, .vel = .{ .x = 0, .y = World.circularOrbitSpeed(8000, r) } },
    };

    const base_dt: f32 = 1.0 / 120.0;
    var traj: Trajectory = .{};
    traj.predict(&world, &specs, &angles, base_dt);
    try testing.expect(traj.count > 100);
    try testing.expectEqual(@as(?usize, null), traj.impact);
    try testing.expectEqual(@as(f32, 0), traj.times[0]);

    // Replay the same span live, checking each sampled point as its time
    // comes up. Same accumulation order as predict, so times land exactly.
    var t: f32 = 0;
    var k: usize = 1;
    while (k < traj.count) {
        world.step(base_dt, .{});
        t += base_dt;
        if (t >= traj.times[k]) {
            const p = traj.points[k].resolve(&planets);
            try testing.expectApproxEqAbs(world.ship.pos.x, p.x, 1e-2);
            try testing.expectApproxEqAbs(world.ship.pos.y, p.y, 1e-2);
            k += 1;
        }
    }

    // The horizon covers just over one revolution, so the loop closes: the
    // last point comes back near the first.
    const first = traj.points[0].resolve(&planets);
    const last = traj.points[traj.count - 1].resolve(&planets);
    try testing.expect(last.sub(first).len() < r);
}

test "trajectory prediction ends on a surface impact" {
    const specs = [_]?Orbit{null};
    var angles = [_]f32{0};
    var planets = [_]Planet{.{ .pos = .{}, .mass = 8000, .radius = 140 }};
    const world: World = .{
        .planets = &planets,
        // Free fall straight down from 400 px out.
        .ship = .{ .pos = .{ .x = 400, .y = 0 }, .vel = .{} },
    };
    var traj: Trajectory = .{};
    traj.predict(&world, &specs, &angles, 1.0 / 120.0);
    try testing.expectEqual(@as(?usize, 0), traj.impact);
    const end = traj.points[traj.count - 1].resolve(&planets);
    try testing.expectApproxEqAbs(140.0 + Ship.radius, end.len(), 5.0);
}

test "trajectory prediction rides a moving body" {
    // A moon on a scripted circle; the ship orbits inside its SOI. If
    // predict failed to advance the moon, the path would trail behind it and
    // the moon-relative offsets would balloon by the moon's travel (~70 px
    // over the horizon against a 150 px orbit).
    const specs = [_]?Orbit{
        null,
        .{ .parent = 0, .semi_major = 1500, .omega = 0.008, .phase = 0.9, .ecc = 0, .peri = 0 },
    };
    var planets = [_]Planet{
        .{ .pos = .{}, .mass = 0, .radius = 10 }, // massless static root
        .{ .pos = .{}, .mass = 4000, .radius = 40, .soi = 400 },
    };
    var angles = [_]f32{ 0, specs[1].?.phase };
    updateOrbits(&specs, &planets, &angles, 0);

    const r: f32 = 150;
    const moon = planets[1];
    const world: World = .{
        .planets = &planets,
        .ship = .{
            .pos = moon.pos.add(.{ .x = r }),
            .vel = moon.vel.add(.{ .y = World.circularOrbitSpeed(moon.mass, r) }),
        },
    };
    var traj: Trajectory = .{};
    traj.predict(&world, &specs, &angles, 1.0 / 120.0);
    try testing.expect(traj.count > 100);
    for (traj.points[0..traj.count]) |pt| {
        try testing.expectEqual(@as(?usize, 1), pt.anchor);
        try testing.expect(@abs(pt.off.len() - r) < r * 0.1);
    }
}
