//! Input seam between raylib and the game loop. The loop samples one `Frame`
//! per rendered frame here instead of calling raylib directly, which buys two
//! things:
//!
//!  - Click edges survive faster-than-a-frame clicks. raylib's
//!    IsMouseButtonPressed/Released compare a per-frame snapshot of the button
//!    state, and its GLFW callback overwrites that state in place. A press and
//!    release that arrive in the same event poll — which is exactly what a
//!    macOS trackpad tap-to-click delivers — therefore cancel out and the
//!    click is never observable through raylib's API (raysan5/raylib#1017,
//!    #4749). Workaround: chain our own GLFW mouse-button callback in front of
//!    raylib's (the bundled GLFW is statically linked, so its symbols are
//!    reachable) and latch each press/release edge until `sample` consumes it
//!    once per frame. raylib's own polling is OR-ed in as a fallback, so
//!    nothing changes on platforms where the chaining doesn't apply.
//!
//!  - The debug bridge (debug.zig) can inject synthetic events upstream of
//!    the exact same code paths real input takes — what gets tested is what
//!    users hit.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");

const is_web = builtin.target.os.tag == .emscripten;

/// Left-button mouse state for one frame. `pressed` and `released` may both
/// be true in the same frame: that is a tap shorter than a frame, which real
/// trackpads produce (via the latch below) and the debug bridge can produce
/// on demand.
pub const Mouse = struct {
    pos: rl.Vector2 = .{ .x = 0, .y = 0 },
    pressed: bool = false,
    released: bool = false,
};

/// Everything the game reads from the player in one frame.
pub const Frame = struct {
    /// -1 = turn left, +1 = turn right, 0 = hold heading.
    turn: f32 = 0,
    thrust: bool = false,
    brake: bool = false,
    reset: bool = false,
    /// Debug: refill the fuel tank (G).
    refuel: bool = false,
    fullscreen: bool = false,
    cycle_theme: bool = false,
    toggle_soi: bool = false,
    flare: bool = false,
    wheel: rl.Vector2 = .{ .x = 0, .y = 0 },
    zoom_modifier: bool = false,
    mouse: Mouse = .{},
};

// --- GLFW click-edge latch ---------------------------------------------------

const GlfwWindow = opaque {};
const MouseButtonFn = ?*const fn (?*GlfwWindow, c_int, c_int, c_int) callconv(.c) void;

extern fn glfwGetCurrentContext() ?*GlfwWindow;
extern fn glfwSetMouseButtonCallback(window: ?*GlfwWindow, callback: MouseButtonFn) MouseButtonFn;

const glfw_mouse_button_left = 0;
const glfw_press = 1;

var chained: MouseButtonFn = null;
var press_latch: bool = false;
var release_latch: bool = false;

fn onMouseButton(window: ?*GlfwWindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (button == glfw_mouse_button_left) {
        if (action == glfw_press) press_latch = true else release_latch = true;
    }
    if (chained) |cb| cb(window, button, action, mods);
}

/// Hook the GLFW callback. Call once, after rl.initWindow.
pub fn init() void {
    // The web backend routes input through emscripten's html5 callbacks, so
    // there is nothing to chain into; sample() falls back to plain raylib.
    if (comptime is_web) {
        _ = emscripten_set_wheel_callback_on_thread(
            "#canvas",
            null,
            false,
            onWheel,
            em_callback_thread_context_calling_thread,
        );
        return;
    }
    chained = glfwSetMouseButtonCallback(glfwGetCurrentContext(), onMouseButton);
}

// --- Web scroll normalisation ------------------------------------------------
// raylib gets its wheel deltas from GLFW on both platforms, but the two GLFWs
// hand it wildly different numbers for the same trackpad flick:
//
//  - native (glfw cocoa_window.m): precise scrolling deltas in pixels, scaled
//    by 0.1 on both axes.
//  - web (emscripten's libglfw.js shim): the vertical axis is deltaY/100 but
//    then *quantised away from zero to a minimum magnitude of 1*, so the
//    gentlest two-finger nudge reports a whole wheel notch. The horizontal
//    axis skips the normalisation entirely and forwards raw deltaX pixels,
//    with the browser's sign — ~100x native and inverted.
//
// That is the sensitivity gap. Rather than tune a fudge factor per platform,
// listen to the DOM wheel event ourselves and convert to the units native GLFW
// produces; sample() then ignores raylib's value on web. Our listener is on the
// bubble phase, so the shim's capture-phase handler (which preventDefaults the
// page scroll for us) still runs first.

const EmMouseEvent = extern struct {
    timestamp: f64,
    screen_x: c_int,
    screen_y: c_int,
    client_x: c_int,
    client_y: c_int,
    ctrl_key: bool,
    shift_key: bool,
    alt_key: bool,
    meta_key: bool,
    button: c_ushort,
    buttons: c_ushort,
    movement_x: c_int,
    movement_y: c_int,
    target_x: c_int,
    target_y: c_int,
    canvas_x: c_int,
    canvas_y: c_int,
    padding: c_int,
};

const EmWheelEvent = extern struct {
    mouse: EmMouseEvent,
    delta_x: f64,
    delta_y: f64,
    delta_z: f64,
    delta_mode: c_uint,
};

const WheelFn = *const fn (c_int, *const EmWheelEvent, ?*anyopaque) callconv(.c) bool;

extern fn emscripten_set_wheel_callback_on_thread(
    target: [*:0]const u8,
    user_data: ?*anyopaque,
    use_capture: bool,
    callback: ?WheelFn,
    target_thread: ?*anyopaque,
) c_int;

const em_callback_thread_context_calling_thread: ?*anyopaque = @ptrFromInt(0x2);

const dom_delta_pixel: c_uint = 0;
const dom_delta_line: c_uint = 1;
const dom_delta_page: c_uint = 2;

var web_wheel: rl.Vector2 = .{ .x = 0, .y = 0 };
var web_zoom_modifier = false;

/// One axis of a DOM wheel event in GLFW wheel units (one unit = one notch of
/// a discrete mouse wheel), sign not yet flipped.
fn wheelSteps(delta: f64, mode: c_uint) f32 {
    if (delta == 0) return 0;
    switch (mode) {
        dom_delta_line => return @floatCast(delta / 3.0), // 3 lines per notch
        dom_delta_page => return @floatCast(delta),
        else => {},
    }
    // Discrete wheels report whole notches in pixel mode: 100px in Chrome,
    // 120px in Safari/Firefox. One notch should stay one unit, as on native.
    const mag = @abs(delta);
    inline for (.{ 100.0, 120.0 }) |notch| {
        if (@mod(mag, notch) == 0) return @floatCast(delta / notch);
    }
    // Otherwise these are precise (trackpad) pixels: same 0.1 native uses.
    return @floatCast(delta * 0.1);
}

fn onWheel(event_type: c_int, e: *const EmWheelEvent, user_data: ?*anyopaque) callconv(.c) bool {
    _ = event_type;
    _ = user_data;
    // DOM deltas point the opposite way to GLFW's (positive deltaY scrolls the
    // page down; positive GLFW yoffset is a scroll up).
    web_wheel.x -= wheelSteps(e.delta_x, e.delta_mode);
    web_wheel.y -= wheelSteps(e.delta_y, e.delta_mode);
    // Browsers deliver a trackpad pinch as a wheel event with ctrlKey set, and
    // ⌘+scroll with metaKey. Both mean "zoom" here.
    if (e.mouse.ctrl_key or e.mouse.meta_key) web_zoom_modifier = true;
    return true;
}

// --- Synthetic event state --------------------------------------------------
// Written by debug.zig's dispatcher and consumed by sample(); both run on the
// main thread (the dispatcher runs inside debug.pump / the web export), so no
// synchronisation is needed.

const Click = struct { pos: rl.Vector2, hold: u32 };
const Drag = struct { from: rl.Vector2, to: rl.Vector2, frames: u32, elapsed: u32 };

/// Remaining frames each held key stays down. Ship keys only tick while the
/// simulation actually steps (see `sample`), so "thrust for 3 frames" means
/// three physics-advancing frames even when the sim is paused between steps.
var syn_left: u32 = 0;
var syn_right: u32 = 0;
var syn_thrust: u32 = 0;
var syn_brake: u32 = 0;
var syn_reset = false;
var syn_refuel = false;
var syn_fullscreen = false;
var syn_theme = false;
var syn_soi = false;
var syn_flare = false;
var syn_wheel: rl.Vector2 = .{ .x = 0, .y = 0 };
var syn_zoom: f32 = 0;
var clicks: [8]Click = undefined;
var clicks_len: usize = 0;
var active_click: ?Click = null;
var active_drag: ?Drag = null;

/// Sample this frame's input: real raylib state (with latched click edges
/// folded in) and synthetic events merged on top. `advancing` is whether a
/// physics step will run this frame; held ship keys (turn/thrust/brake) only
/// apply and tick down on advancing frames, so injected sequences stay
/// deterministic under pause/step. Call exactly once per frame.
pub fn sample(advancing: bool) Frame {
    // On web our own DOM listener owns the wheel (see onWheel); raylib's value
    // comes out of emscripten's GLFW shim with the wrong scale on both axes.
    const wheel = if (comptime is_web) blk: {
        defer web_wheel = .{ .x = 0, .y = 0 };
        break :blk web_wheel;
    } else rl.getMouseWheelMoveV();
    const zoom_mod = if (comptime is_web) blk: {
        defer web_zoom_modifier = false;
        break :blk web_zoom_modifier;
    } else false;

    var f: Frame = .{
        .thrust = rl.isKeyDown(.w) or rl.isKeyDown(.up),
        .brake = rl.isKeyDown(.s) or rl.isKeyDown(.down),
        .reset = rl.isKeyPressed(.r),
        .refuel = rl.isKeyPressed(.g),
        .fullscreen = rl.isKeyPressed(.f),
        .cycle_theme = rl.isKeyPressed(.t),
        .toggle_soi = rl.isKeyPressed(.o),
        .flare = rl.isKeyPressed(.x),
        .wheel = wheel,
        .zoom_modifier = zoom_mod or rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super),
        .mouse = .{
            .pos = rl.getMousePosition(),
            .pressed = press_latch or rl.isMouseButtonPressed(.left),
            .released = release_latch or rl.isMouseButtonReleased(.left),
        },
    };
    press_latch = false;
    release_latch = false;
    if (rl.isKeyDown(.a) or rl.isKeyDown(.left)) f.turn -= 1;
    if (rl.isKeyDown(.d) or rl.isKeyDown(.right)) f.turn += 1;

    if (advancing) {
        if (syn_left > 0) {
            syn_left -= 1;
            f.turn -= 1;
        }
        if (syn_right > 0) {
            syn_right -= 1;
            f.turn += 1;
        }
        if (syn_thrust > 0) {
            syn_thrust -= 1;
            f.thrust = true;
        }
        if (syn_brake > 0) {
            syn_brake -= 1;
            f.brake = true;
        }
    }
    f.turn = std.math.clamp(f.turn, -1, 1);

    if (syn_reset) {
        syn_reset = false;
        f.reset = true;
    }
    if (syn_refuel) {
        syn_refuel = false;
        f.refuel = true;
    }
    if (syn_fullscreen) {
        syn_fullscreen = false;
        f.fullscreen = true;
    }
    if (syn_theme) {
        syn_theme = false;
        f.cycle_theme = true;
    }
    if (syn_soi) {
        syn_soi = false;
        f.toggle_soi = true;
    }
    if (syn_flare) {
        syn_flare = false;
        f.flare = true;
    }
    if (syn_wheel.x != 0 or syn_wheel.y != 0) {
        f.wheel.x += syn_wheel.x;
        f.wheel.y += syn_wheel.y;
        syn_wheel = .{ .x = 0, .y = 0 };
    }
    if (syn_zoom != 0) {
        f.zoom_modifier = true;
        f.wheel.y = syn_zoom;
        syn_zoom = 0;
    }

    // A synthetic drag owns the cursor for its whole span: press at `from`,
    // glide linearly to `to`, release there. Exercises the click-vs-drag
    // arbitration in main.zig the way a real mouse drag does.
    if (active_drag) |*d| {
        if (d.elapsed == 0) f.mouse.pressed = true;
        const t = @as(f32, @floatFromInt(d.elapsed)) / @as(f32, @floatFromInt(d.frames));
        f.mouse.pos = .{
            .x = d.from.x + (d.to.x - d.from.x) * t,
            .y = d.from.y + (d.to.y - d.from.y) * t,
        };
        if (d.elapsed == d.frames) {
            f.mouse.released = true;
            active_drag = null;
        } else {
            d.elapsed += 1;
        }
        return f;
    }

    // Synthetic clicks own the cursor while active. hold = 0 is the flaky
    // trackpad tap: press and release delivered in the same frame.
    if (active_click) |*c| {
        f.mouse.pos = c.pos;
        c.hold -= 1;
        if (c.hold == 0) {
            f.mouse.released = true;
            active_click = null;
        }
    } else if (clicks_len > 0) {
        const c = clicks[0];
        std.mem.copyForwards(Click, clicks[0 .. clicks_len - 1], clicks[1..clicks_len]);
        clicks_len -= 1;
        f.mouse.pos = c.pos;
        f.mouse.pressed = true;
        if (c.hold == 0) {
            f.mouse.released = true;
        } else {
            active_click = c;
        }
    }

    return f;
}

/// Queue a synthetic left click at screen position (x, y), held down for
/// `hold` frames (0 = press and release within a single frame). Returns
/// false if the click queue is full.
pub fn injectClick(x: f32, y: f32, hold: u32) bool {
    if (clicks_len == clicks.len) return false;
    clicks[clicks_len] = .{ .pos = .{ .x = x, .y = y }, .hold = hold };
    clicks_len += 1;
    return true;
}

/// Hold a named key for `frames` frames (one-shot keys ignore the count).
/// Returns false for unknown names.
pub fn injectKey(name: []const u8, frames: u32) bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "a") or eq(name, "left")) {
        syn_left = frames;
    } else if (eq(name, "d") or eq(name, "right")) {
        syn_right = frames;
    } else if (eq(name, "w") or eq(name, "up") or eq(name, "thrust")) {
        syn_thrust = frames;
    } else if (eq(name, "s") or eq(name, "down") or eq(name, "brake")) {
        syn_brake = frames;
    } else if (eq(name, "r")) {
        syn_reset = true;
    } else if (eq(name, "g") or eq(name, "refuel")) {
        syn_refuel = true;
    } else if (eq(name, "f")) {
        syn_fullscreen = true;
    } else if (eq(name, "t")) {
        syn_theme = true;
    } else if (eq(name, "o")) {
        syn_soi = true;
    } else if (eq(name, "x") or eq(name, "flare")) {
        syn_flare = true;
    } else {
        return false;
    }
    return true;
}

/// Queue a synthetic left-button drag: press at (x0, y0), move linearly to
/// (x1, y1) over `frames` frames, release there. Returns false while another
/// drag is still in flight.
pub fn injectDrag(x0: f32, y0: f32, x1: f32, y1: f32, frames: u32) bool {
    if (active_drag != null) return false;
    active_drag = .{
        .from = .{ .x = x0, .y = y0 },
        .to = .{ .x = x1, .y = y1 },
        .frames = @max(1, frames),
        .elapsed = 0,
    };
    return true;
}

/// One frame of scroll-wheel movement (pans the view).
pub fn injectWheel(dx: f32, dy: f32) void {
    syn_wheel.x += dx;
    syn_wheel.y += dy;
}

/// One frame of cmd+scroll (zooms the view); dy > 0 zooms in.
pub fn injectZoom(dy: f32) void {
    syn_zoom = dy;
}
