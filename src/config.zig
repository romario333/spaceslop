//! Planet tuning lives in `planets.zon` next to the binary's working directory
//! (the project root — same place the resources are loaded from). ZON because
//! it round-trips through std.zon straight into the Config struct: no parser
//! code, no dependency, and the file is plain Zig syntax. Missing or broken
//! file falls back to the defaults; the web build has no persistent
//! filesystem, so it always uses the defaults and hides the save button.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const is_web = builtin.target.os.tag == .emscripten;

pub const path = "planets.zon";

pub const PlanetConfig = struct {
    mass: f32,
    radius: f32,
    soi: f32,
    core: f32 = 0,
};

/// Display name of each body, in the canonical body order used everywhere a
/// body is looked up by index: the planets array in main.zig, Config.planet,
/// and render.SpriteSet.body all follow it.
pub const names = [_][:0]const u8{ "sun", "mercury", "venus", "earth", "moon", "mars", "jupiter", "saturn", "uranus", "neptune", "phobos", "deimos", "io", "europa", "ganymede", "callisto", "pluto", "haumea", "makemake", "eris" };

/// Whether the body at `idx` (canonical order, see `names`) offers orbital
/// refuel/repair services. The gas giants don't — no surface to lift
/// propellant from; park at one of their moons instead.
pub fn hasServices(idx: usize) bool {
    return switch (idx) {
        6, 7, 8, 9 => false, // jupiter, saturn, uranus, neptune
        else => true,
    };
}

pub const Config = struct {
    // The sun's SOI must contain every heliocentric orbit (see `orbits` in
    // main.zig): Eris tops out near 135700. It reaches beyond that
    // (150000) on purpose: crossing it is the point of no return (deep space,
    // zero gravity), so the farther out it sits the closer "reach the edge"
    // is to true escape velocity — one full tank must NOT be enough to leave
    // the system (see World.fuel_burn for the budget math).
    //
    // Masses are tuned as a set: the sun is heavy enough that solar escape
    // costs more delta-v than a full tank, planets are scaled to match so
    // arriving transfers stay slow enough for capture assist to grab, and
    // the Earth system is deliberately lighter than the rest — a shallower
    // home well weakens the Oberth discount on departure burns, which is
    // what separates the cost of "reach Mars" from the cost of "leave
    // forever" in the first place.
    sun: PlanetConfig = .{ .mass = 320000, .radius = 600, .soi = 150000 },
    mercury: PlanetConfig = .{ .mass = 2500, .radius = 50, .soi = 900, .core = 90 },
    venus: PlanetConfig = .{ .mass = 7000, .radius = 130, .soi = 2000, .core = 145 },
    earth: PlanetConfig = .{ .mass = 8000, .radius = 140, .soi = 2500 },
    moon: PlanetConfig = .{ .mass = 4000, .radius = 40, .soi = 770, .core = 110 },
    // Mars is lighter than Earth (as in reality) but its SOI is pulled in
    // tight so the well at the boundary stays deep enough to bind (and
    // capture-assist) a Hohmann arrival from Earth: capture needs
    // mass/soi ≳ 6, and both moons must orbit inside the SOI (see the
    // phobos/deimos entries in main.zig's `orbits`).
    mars: PlanetConfig = .{ .mass = 6500, .radius = 80, .soi = 1000, .core = 110 },
    jupiter: PlanetConfig = .{ .mass = 60000, .radius = 300, .soi = 5000 },
    saturn: PlanetConfig = .{ .mass = 44000, .radius = 250, .soi = 4200 },
    uranus: PlanetConfig = .{ .mass = 24000, .radius = 180, .soi = 3200 },
    neptune: PlanetConfig = .{ .mass = 26000, .radius = 175, .soi = 3200 },
    // Moons. Small SOI bubbles so each moon's gravity stays a local affair
    // inside its parent's SOI; cores larger than the rendered radius keep
    // close flybys integrable, same trick as Earth's moon.
    phobos: PlanetConfig = .{ .mass = 1200, .radius = 16, .soi = 90, .core = 45 },
    deimos: PlanetConfig = .{ .mass = 800, .radius = 12, .soi = 70, .core = 35 },
    io: PlanetConfig = .{ .mass = 5200, .radius = 36, .soi = 170, .core = 100 },
    europa: PlanetConfig = .{ .mass = 4800, .radius = 31, .soi = 150, .core = 90 },
    ganymede: PlanetConfig = .{ .mass = 7200, .radius = 46, .soi = 200, .core = 110 },
    callisto: PlanetConfig = .{ .mass = 6000, .radius = 42, .soi = 210, .core = 105 },
    // Kuiper dwarfs, riding eccentric ellipses through the Kuiper belt (see
    // `orbits` in main.zig). Moon-class lightweights with tight SOI bubbles;
    // mass/soi stays ≳ 6 so capture assist can still bind the (slow, this far
    // out) arrivals. Eris outweighs Pluto, as in reality.
    pluto: PlanetConfig = .{ .mass = 4500, .radius = 45, .soi = 700, .core = 110 },
    haumea: PlanetConfig = .{ .mass = 3500, .radius = 30, .soi = 550, .core = 90 },
    makemake: PlanetConfig = .{ .mass = 3200, .radius = 34, .soi = 520, .core = 95 },
    eris: PlanetConfig = .{ .mass = 4800, .radius = 44, .soi = 720, .core = 110 },

    pub fn planet(self: *Config, idx: usize) *PlanetConfig {
        return switch (idx) {
            0 => &self.sun,
            1 => &self.mercury,
            2 => &self.venus,
            3 => &self.earth,
            4 => &self.moon,
            5 => &self.mars,
            6 => &self.jupiter,
            7 => &self.saturn,
            8 => &self.uranus,
            9 => &self.neptune,
            10 => &self.phobos,
            11 => &self.deimos,
            12 => &self.io,
            13 => &self.europa,
            14 => &self.ganymede,
            15 => &self.callisto,
            16 => &self.pluto,
            17 => &self.haumea,
            18 => &self.makemake,
            else => &self.eris,
        };
    }

    pub fn load() Config {
        if (is_web) return .{};
        const gpa = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const src = std.Io.Dir.cwd().readFileAllocOptions(
            io,
            path,
            gpa,
            .limited(64 * 1024),
            .of(u8),
            0, // zon parsing wants a null-terminated source
        ) catch return .{}; // no file yet: defaults
        defer gpa.free(src);
        return std.zon.parse.fromSlice(Config, gpa, src, null, .{}) catch blk: {
            rl.traceLog(.warning, "%s: parse error, using default planets", .{path.ptr});
            break :blk .{};
        };
    }

    pub fn save(self: Config) !void {
        if (is_web) return;
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try std.zon.stringify.serialize(self, .{}, &w);
        try w.writeByte('\n');
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() });
    }
};
