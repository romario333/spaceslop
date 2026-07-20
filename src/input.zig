//! Left-mouse click edges that survive faster-than-a-frame clicks.
//!
//! raylib's IsMouseButtonPressed/Released compare a per-frame snapshot of the
//! button state, and its GLFW callback overwrites that state in place. A press
//! and release that arrive in the same event poll — which is exactly what a
//! macOS trackpad tap-to-click delivers — therefore cancel out and the click
//! is never observable through raylib's API (raysan5/raylib#1017, #4749).
//!
//! Workaround: chain our own GLFW mouse-button callback in front of raylib's
//! (the bundled GLFW is statically linked, so its symbols are reachable) and
//! latch each press/release edge until the game loop consumes it once per
//! frame. raylib's own polling is OR-ed in as a fallback, so nothing changes
//! on platforms where the chaining doesn't apply.

const builtin = @import("builtin");
const rl = @import("raylib");

const is_web = builtin.target.os.tag == .emscripten;

/// One frame's worth of left-button edges, consumed via `poll`.
pub const Mouse = struct {
    pressed: bool,
    released: bool,
};

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
    // there is nothing to chain into; poll() falls back to plain raylib.
    if (comptime is_web) return;
    chained = glfwSetMouseButtonCallback(glfwGetCurrentContext(), onMouseButton);
}

/// Consume this frame's click edges. Call exactly once per frame, before any
/// code that acts on clicks.
pub fn poll() Mouse {
    const m: Mouse = .{
        .pressed = press_latch or rl.isMouseButtonPressed(.left),
        .released = release_latch or rl.isMouseButtonReleased(.left),
    };
    press_latch = false;
    release_latch = false;
    return m;
}
