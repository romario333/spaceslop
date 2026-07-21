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
pub const names = [_][:0]const u8{ "sun", "mercury", "venus", "earth", "moon", "mars", "jupiter", "saturn", "uranus", "neptune", "phobos", "deimos", "io", "europa", "ganymede", "callisto" };

pub const Config = struct {
    // The sun's SOI must contain every heliocentric orbit (see `orbits` in
    // main.zig): Neptune tops out near 57000, so 60000 keeps the whole system
    // inside the sun's gravity with deep space beyond it.
    sun: PlanetConfig = .{ .mass = 100000, .radius = 600, .soi = 60000 },
    mercury: PlanetConfig = .{ .mass = 2500, .radius = 50, .soi = 900, .core = 90 },
    venus: PlanetConfig = .{ .mass = 7000, .radius = 130, .soi = 2000, .core = 145 },
    earth: PlanetConfig = .{ .mass = 8000, .radius = 140, .soi = 2500 },
    moon: PlanetConfig = .{ .mass = 4000, .radius = 40, .soi = 770, .core = 110 },
    mars: PlanetConfig = .{ .mass = 4000, .radius = 80, .soi = 1500, .core = 110 },
    jupiter: PlanetConfig = .{ .mass = 30000, .radius = 300, .soi = 5000 },
    saturn: PlanetConfig = .{ .mass = 22000, .radius = 250, .soi = 4200 },
    uranus: PlanetConfig = .{ .mass = 12000, .radius = 180, .soi = 3200 },
    neptune: PlanetConfig = .{ .mass = 13000, .radius = 175, .soi = 3200 },
    // Moons. Small SOI bubbles so each moon's gravity stays a local affair
    // inside its parent's SOI; cores larger than the rendered radius keep
    // close flybys integrable, same trick as Earth's moon.
    phobos: PlanetConfig = .{ .mass = 600, .radius = 16, .soi = 90, .core = 45 },
    deimos: PlanetConfig = .{ .mass = 400, .radius = 12, .soi = 70, .core = 35 },
    io: PlanetConfig = .{ .mass = 2600, .radius = 36, .soi = 170, .core = 100 },
    europa: PlanetConfig = .{ .mass = 2400, .radius = 31, .soi = 150, .core = 90 },
    ganymede: PlanetConfig = .{ .mass = 3600, .radius = 46, .soi = 200, .core = 110 },
    callisto: PlanetConfig = .{ .mass = 3000, .radius = 42, .soi = 210, .core = 105 },

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
            else => &self.callisto,
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
        var buf: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try std.zon.stringify.serialize(self, .{}, &w);
        try w.writeByte('\n');
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() });
    }
};
