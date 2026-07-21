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
    if (comptime is_web) return;
    chained = glfwSetMouseButtonCallback(glfwGetCurrentContext(), onMouseButton);
}

// --- Synthetic event state --------------------------------------------------
// Written by debug.zig's dispatcher and consumed by sample(); both run on the
// main thread (the dispatcher runs inside debug.pump / the web export), so no
// synchronisation is needed.

const Click = struct { pos: rl.Vector2, hold: u32 };

/// Remaining frames each held key stays down. Ship keys only tick while the
/// simulation actually steps (see `sample`), so "thrust for 3 frames" means
/// three physics-advancing frames even when the sim is paused between steps.
var syn_left: u32 = 0;
var syn_right: u32 = 0;
var syn_thrust: u32 = 0;
var syn_brake: u32 = 0;
var syn_reset = false;
var syn_fullscreen = false;
var syn_theme = false;
var syn_soi = false;
var syn_flare = false;
var syn_wheel: rl.Vector2 = .{ .x = 0, .y = 0 };
var syn_zoom: f32 = 0;
var clicks: [8]Click = undefined;
var clicks_len: usize = 0;
var active_click: ?Click = null;

/// Sample this frame's input: real raylib state (with latched click edges
/// folded in) and synthetic events merged on top. `advancing` is whether a
/// physics step will run this frame; held ship keys (turn/thrust/brake) only
/// apply and tick down on advancing frames, so injected sequences stay
/// deterministic under pause/step. Call exactly once per frame.
pub fn sample(advancing: bool) Frame {
    var f: Frame = .{
        .thrust = rl.isKeyDown(.w) or rl.isKeyDown(.up),
        .brake = rl.isKeyDown(.s) or rl.isKeyDown(.down),
        .reset = rl.isKeyPressed(.r),
        .fullscreen = rl.isKeyPressed(.f),
        .cycle_theme = rl.isKeyPressed(.t),
        .toggle_soi = rl.isKeyPressed(.o),
        .flare = rl.isKeyPressed(.x),
        .wheel = rl.getMouseWheelMoveV(),
        .zoom_modifier = rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super),
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

/// One frame of scroll-wheel movement (pans the view).
pub fn injectWheel(dx: f32, dy: f32) void {
    syn_wheel.x += dx;
    syn_wheel.y += dy;
}

/// One frame of cmd+scroll (zooms the view); dy > 0 zooms in.
pub fn injectZoom(dy: f32) void {
    syn_zoom = dy;
}
