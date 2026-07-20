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

pub const Config = struct {
    earth: PlanetConfig = .{ .mass = 8000, .radius = 140, .soi = 2500 },
    moon: PlanetConfig = .{ .mass = 3000, .radius = 40, .soi = 400, .core = 110 },

    pub fn planet(self: *Config, idx: usize) *PlanetConfig {
        return if (idx == 0) &self.earth else &self.moon;
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
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try std.zon.stringify.serialize(self, .{}, &w);
        try w.writeByte('\n');
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = w.buffered() });
    }
};
