//! Debug bridge: a line-based command protocol for driving the running game
//! from outside — dump simulation state, inject synthetic input, pause and
//! single-step the physics, capture screenshots. One dispatcher, two thin
//! transports:
//!
//!  - native: run with `--debug [port]` and it listens on 127.0.0.1, on the
//!    first free port at or above the requested one (default 4444). The port
//!    it settled on is written to `.debug-bridge-port` in cwd, so concurrent
//!    instances from different worktrees never share one:
//!    `echo state | nc localhost $(cat .debug-bridge-port)`
//!  - web: the dispatcher is exported as `space_slop_debug` and wrapped by
//!    `spaceSlopDebug('...')` in web/shell.html
//!
//! Synthetic input goes through input.zig, upstream of the code paths real
//! input takes. `pause` + `step` advance exactly one fixed physics step per
//! rendered frame, so input timing that real devices only produce
//! occasionally (a press and release inside one frame, say) can be
//! constructed deliberately.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const sim = @import("sim.zig");
const cfg = @import("config.zig");
const input = @import("input.zig");
const render = @import("render.zig");
const DetailPanel = @import("detail_panel.zig").DetailPanel;

const is_web = builtin.target.os.tag == .emscripten;

/// Pointers into the game state that lives in main.run's frame; wired up
/// once before the main loop starts.
pub const Hooks = struct {
    world: *sim.World,
    planets: []sim.Planet,
    cam: *rl.Camera2D,
    detail: *DetailPanel,
    pan_offset: *sim.Vec2,
    theme: *render.Theme,
};

var hooks: ?Hooks = null;

// --- Simulation control, read and written by the main loop -----------------

pub var paused = false;
pub var steps_pending: u32 = 0;
/// Fixed physics steps since launch — the clock deterministic runs count in.
pub var step_count: u64 = 0;

// --- Native transport: TCP server thread <-> main thread handoff -----------
// The server thread parks a request in `req_buf` and spins (1 ms sleeps) on
// `phase` until the main loop's pump() has dispatched it during a frame and
// left the answer in `rsp_buf`. One client and one command in flight at a
// time, which is all a debugging session needs.

const Phase = enum(u8) {
    /// No request in flight; the server thread owns the buffers.
    idle,
    /// Request parked; the main thread will dispatch it in pump().
    request,
    /// Dispatched but the answer needs end-of-frame work (screenshot).
    working,
    /// Answer parked in rsp_buf; the server thread copies it out.
    response,
};

var phase: Phase = .idle;
var req_buf: [512]u8 = undefined;
var req_len: usize = 0;
var rsp_buf: [8192]u8 = undefined;
var rsp_len: usize = 0;

// Screenshot requests are answered only after the frame is composed (see
// finishFrame), so the client learns the file actually exists.
var shot_path: [512]u8 = undefined;
var shot_len: usize = 0;
var shot_pending = false;

pub fn init(h: Hooks) void {
    hooks = h;
}

/// Start the native TCP listener on the first free port at or above `port`.
/// No-op on the web build, where the page calls the exported dispatcher
/// directly.
pub fn serve(port: u16) void {
    if (is_web) {
        return;
    } else {
        const t = std.Thread.spawn(.{}, serverMain, .{port}) catch |err| {
            rl.traceLog(.warning, "debug: server thread failed: %s", .{@errorName(err).ptr});
            return;
        };
        t.detach();
    }
}

/// Called by the main loop once per frame, before input sampling, so a
/// command's effects (injected input, pause state) land this very frame.
pub fn pump() void {
    if (is_web) {
        return;
    } else {
        if (@atomicLoad(Phase, &phase, .acquire) != .request) return;
        var w = std.Io.Writer.fixed(&rsp_buf);
        const result = dispatch(req_buf[0..req_len], &w) catch .done; // buffer full: answer truncated
        if (result == .deferred) {
            @atomicStore(Phase, &phase, .working, .release);
            return;
        }
        rsp_len = w.buffered().len;
        @atomicStore(Phase, &phase, .response, .release);
    }
}

/// rlgl's batch flush, not re-exported by raylib-zig's `rl` namespace; we link
/// raylib itself, so the C symbol is right there.
extern "c" fn rlDrawRenderBatchActive() void;

/// Called by the main loop after the frame is drawn but before the buffer
/// swap, which is where raylib's takeScreenshot reads consistent pixels.
pub fn finishFrame() void {
    if (is_web) {
        return;
    } else {
        if (!shot_pending) return;
        shot_pending = false;
        shot_path[shot_len] = 0;
        const path = shot_path[0..shot_len :0];
        // The capture reads the framebuffer, so anything still sitting in
        // rlgl's batch (typically the topmost layer: HUD text, edge arrows)
        // would be missing. endDrawing would flush it, but that also swaps —
        // flush explicitly instead.
        rlDrawRenderBatchActive();
        var w = std.Io.Writer.fixed(&rsp_buf);
        // Deliberately not rl.takeScreenshot: it prepends the working
        // directory, so an absolute path turns into "<cwd>//tmp/shot.png"
        // and fails. loadImageFromScreen + exportImage read the same
        // framebuffer pixels but write to the path exactly as given.
        if (rl.loadImageFromScreen()) |img| {
            defer rl.unloadImage(img);
            if (rl.exportImage(img, path)) {
                w.print("ok {s}", .{path}) catch {};
            } else {
                w.print("err could not write {s}", .{path}) catch {};
            }
        } else |_| {
            w.writeAll("err could not read the framebuffer") catch {};
        }
        rsp_len = w.buffered().len;
        @atomicStore(Phase, &phase, .response, .release);
    }
}

// --- Command dispatch -------------------------------------------------------

const Result = enum { done, deferred };

fn dispatch(line: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!Result {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    const cmd = it.next() orelse {
        try w.writeAll("err empty command");
        return .done;
    };
    const eq = std.mem.eql;

    if (eq(u8, cmd, "help")) {
        try w.writeAll("commands: state | screenshot <path> | click <x> <y> [hold] | " ++
            "clickw <wx> <wy> [hold] | key <name> [frames] | wheel <dx> <dy> | " ++
            "zoom <dy> | pause | resume | step [n] | help");
    } else if (eq(u8, cmd, "state")) {
        try writeState(w);
    } else if (eq(u8, cmd, "pause")) {
        paused = true;
        try w.writeAll("ok paused");
    } else if (eq(u8, cmd, "resume")) {
        paused = false;
        steps_pending = 0;
        try w.writeAll("ok running");
    } else if (eq(u8, cmd, "step")) {
        const n = parseInt(it.next() orelse "1") orelse {
            try w.writeAll("err step wants a count");
            return .done;
        };
        paused = true;
        steps_pending += n;
        try w.print("ok stepping {d}", .{n});
    } else if (eq(u8, cmd, "click") or eq(u8, cmd, "clickw")) {
        const x = parseFloat(it.next()) orelse {
            try w.writeAll("err click wants: x y [hold_frames]");
            return .done;
        };
        const y = parseFloat(it.next()) orelse {
            try w.writeAll("err click wants: x y [hold_frames]");
            return .done;
        };
        const hold = parseInt(it.next() orelse "1") orelse {
            try w.writeAll("err bad hold count");
            return .done;
        };
        var px = x;
        var py = y;
        if (eq(u8, cmd, "clickw")) {
            const h = hooks orelse {
                try w.writeAll("err not wired");
                return .done;
            };
            const s = rl.getWorldToScreen2D(.{ .x = x, .y = y }, h.cam.*);
            px = s.x;
            py = s.y;
        }
        if (!input.injectClick(px, py, hold)) {
            try w.writeAll("err click queue full");
            return .done;
        }
        try w.print("ok click {d:.0} {d:.0} hold {d}", .{ px, py, hold });
    } else if (eq(u8, cmd, "key")) {
        const name = it.next() orelse {
            try w.writeAll("err key wants: name [frames]");
            return .done;
        };
        const frames = parseInt(it.next() orelse "1") orelse {
            try w.writeAll("err bad frame count");
            return .done;
        };
        if (!input.injectKey(name, frames)) {
            try w.writeAll("err unknown key (w/a/s/d/up/down/left/right/thrust/brake/r/t/o/f)");
            return .done;
        }
        try w.print("ok key {s} frames {d}", .{ name, frames });
    } else if (eq(u8, cmd, "wheel")) {
        const dx = parseFloat(it.next()) orelse {
            try w.writeAll("err wheel wants: dx dy");
            return .done;
        };
        const dy = parseFloat(it.next()) orelse {
            try w.writeAll("err wheel wants: dx dy");
            return .done;
        };
        input.injectWheel(dx, dy);
        try w.writeAll("ok wheel");
    } else if (eq(u8, cmd, "zoom")) {
        const dy = parseFloat(it.next()) orelse {
            try w.writeAll("err zoom wants: dy");
            return .done;
        };
        input.injectZoom(dy);
        try w.writeAll("ok zoom");
    } else if (eq(u8, cmd, "screenshot")) {
        if (is_web) {
            try w.writeAll("err no screenshots on web (snapshot the canvas instead)");
        } else {
            const path = it.next() orelse {
                try w.writeAll("err screenshot wants a path");
                return .done;
            };
            if (path.len >= shot_path.len) {
                try w.writeAll("err path too long");
                return .done;
            }
            @memcpy(shot_path[0..path.len], path);
            shot_len = path.len;
            shot_pending = true;
            return .deferred;
        }
    } else {
        try w.print("err unknown command '{s}' (try help)", .{cmd});
    }
    return .done;
}

fn parseFloat(tok: ?[]const u8) ?f32 {
    return std.fmt.parseFloat(f32, tok orelse return null) catch null;
}

fn parseInt(tok: []const u8) ?u32 {
    return std.fmt.parseInt(u32, tok, 10) catch null;
}

fn writeVec(w: *std.Io.Writer, p: sim.Vec2) std.Io.Writer.Error!void {
    try w.print("[{d:.2},{d:.2}]", .{ p.x, p.y });
}

/// The whole observable game state as one line of JSON.
fn writeState(w: *std.Io.Writer) std.Io.Writer.Error!void {
    const h = hooks orelse {
        try w.writeAll("err not wired");
        return;
    };
    const ship = h.world.ship;
    try w.print("{{\"step\":{d},\"paused\":{},\"steps_pending\":{d}", .{ step_count, paused, steps_pending });

    try w.writeAll(",\"ship\":{\"pos\":");
    try writeVec(w, ship.pos);
    try w.writeAll(",\"vel\":");
    try writeVec(w, ship.vel);
    try w.print(",\"speed\":{d:.2},\"angle\":{d:.4},\"thrusting\":{},\"braking\":{}}}", .{ ship.vel.len(), ship.angle, ship.thrusting, ship.braking });

    const soi_idx = h.world.dominantIndex(ship.pos);
    if (soi_idx) |i| {
        try w.print(",\"soi\":{d}", .{i});
    } else {
        try w.writeAll(",\"soi\":null");
    }

    try w.writeAll(",\"planets\":[");
    for (h.planets, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        const name: []const u8 = cfg.names[i];
        try w.print("{{\"name\":\"{s}\",\"pos\":", .{name});
        try writeVec(w, p.pos);
        try w.writeAll(",\"vel\":");
        try writeVec(w, p.vel);
        try w.print(",\"mass\":{d:.1},\"radius\":{d:.1},\"soi\":{d:.1}}}", .{ p.mass, p.radius, p.soi });
    }
    try w.writeAll("]");

    try w.writeAll(",\"camera\":{\"target\":");
    try writeVec(w, .{ .x = h.cam.target.x, .y = h.cam.target.y });
    try w.print(",\"zoom\":{d:.4}}}", .{h.cam.zoom});

    if (h.detail.selected) |s| {
        try w.print(",\"selected\":{d}", .{s});
    } else {
        try w.writeAll(",\"selected\":null");
    }
    try w.writeAll(",\"pan_offset\":");
    try writeVec(w, h.pan_offset.*);

    try w.print(",\"screen\":[{d},{d}],\"theme\":\"{s}\"}}", .{ rl.getScreenWidth(), rl.getScreenHeight(), h.theme.label() });
}

// --- Native TCP server thread -----------------------------------------------

/// Where the bound port is published, relative to cwd. Several worktrees of
/// this repo are often driven at once; each instance claims the first free
/// port from the requested one upward and writes it here, so a driver reads
/// the port of the instance it launched instead of guessing a shared one.
const port_file = ".debug-bridge-port";
/// How many ports to try before giving up.
const port_scan = 16;

fn serverMain(first_port: u16) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: std.Io.net.Server = undefined;
    var port = first_port;
    const last_port = first_port +| (port_scan - 1);
    while (true) : (port += 1) {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
        // No `reuse_address`: it sets SO_REUSEPORT as well, which lets a
        // second instance bind a port another one is already listening on —
        // the two then split incoming connections at random.
        server = addr.listen(io, .{}) catch |err| {
            if (port < last_port) continue;
            rl.traceLog(.warning, "debug: listen failed: %s", .{@errorName(err).ptr});
            return;
        };
        break;
    }
    defer server.deinit(io);

    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{port}) catch unreachable;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = port_file, .data = text }) catch |err| {
        rl.traceLog(.warning, "debug: writing " ++ port_file ++ " failed: %s", .{@errorName(err).ptr});
    };
    rl.traceLog(.info, "debug: listening on 127.0.0.1:%d", .{@as(c_int, port)});

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
        serveClient(stream, io);
    }
}

fn serveClient(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);
    var rbuf: [req_buf.len]u8 = undefined;
    var wbuf: [1024]u8 = undefined;
    var out: [rsp_buf.len]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);

    while (true) {
        const maybe_line = reader.interface.takeDelimiter('\n') catch return;
        const line = maybe_line orelse return; // clean EOF
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const rsp = submit(trimmed, io, &out);
        writer.interface.writeAll(rsp) catch return;
        writer.interface.writeByte('\n') catch return;
        writer.interface.flush() catch return;
    }
}

/// Park one command for the main thread and wait for its answer.
fn submit(line: []const u8, io: std.Io, out: []u8) []const u8 {
    req_len = @min(line.len, req_buf.len);
    @memcpy(req_buf[0..req_len], line[0..req_len]);
    @atomicStore(Phase, &phase, .request, .release);
    while (@atomicLoad(Phase, &phase, .acquire) != .response) {
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    const len = rsp_len;
    @memcpy(out[0..len], rsp_buf[0..len]);
    @atomicStore(Phase, &phase, .idle, .release);
    return out[0..len];
}

// --- Web transport ----------------------------------------------------------
// The page calls the exported dispatcher directly (via Module.ccall, wrapped
// as spaceSlopDebug in web/shell.html). ASYNCIFY parks the wasm main loop
// between frames while JS runs, so the call sees consistent state.

comptime {
    if (is_web) @export(&webDispatch, .{ .name = "space_slop_debug" });
}

fn webDispatch(cmd: [*:0]const u8) callconv(.c) [*:0]const u8 {
    var w = std.Io.Writer.fixed(rsp_buf[0 .. rsp_buf.len - 1]);
    _ = dispatch(std.mem.span(cmd), &w) catch {};
    const len = w.buffered().len;
    rsp_buf[len] = 0;
    return rsp_buf[0..len :0].ptr;
}
