//! Click-a-planet detail panel: everything about the selected body lives here.
//! It is laid out as a stack of titled sections; today the only one is "debug"
//! (live sliders for mass, sphere of influence and visual size), with room for
//! object info and game actions below it later.
//!
//! The sliders write straight into the `planets` array the simulation reads, so
//! every change takes effect on the next physics step.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const sim = @import("sim.zig");
const Vec2 = sim.Vec2;
const config = @import("config.zig");
const v = @import("render.zig").v;

const is_web = builtin.target.os.tag == .emscripten;

var text_buf: [64]u8 = undefined;

pub const DetailPanel = struct {
    const w: f32 = 250;
    const pad: f32 = 12;
    const head_h: f32 = 32;
    /// Height of a section's own title strip, above its content.
    const sect_h: f32 = 26;
    const row_h: f32 = 46;
    const track_h: f32 = 6;
    const knob_r: f32 = 7;
    const btn_h: f32 = 28;

    const Field = struct { name: [:0]const u8, min: f32, max: f32 };
    /// `size` is Planet.radius: it drives both the drawn sprite size and the
    /// distance at which gravity stops growing, which is what "how big is this
    /// planet" means here.
    const fields = [_]Field{
        .{ .name = "mass", .min = 0, .max = 40000 },
        .{ .name = "soi", .min = 50, .max = 6000 },
        .{ .name = "size", .min = 5, .max = 600 },
    };

    /// Cap on how far the view can pan from the followed body, in world px —
    /// far enough to survey Earth's whole SOI, near enough to never lose the
    /// starfield (which spans ±3500).
    pub const max_pan: f32 = 3500;

    selected: ?usize = null,
    /// Which slider owns the mouse right now, so a drag keeps control even
    /// once the cursor wanders off the (thin) track.
    dragging: ?usize = null,
    /// Set by the save button; the main loop consumes it and does the file IO.
    save_requested: bool = false,
    /// Seconds left showing the save result on the button; <0 = save failed.
    save_flash: f32 = 0,
    save_ok: bool = true,

    /// Height of the debug section, title strip included. Sections stack top
    /// to bottom, so a new one just adds its own height here and starts at the
    /// running offset.
    fn debugH() f32 {
        const btn: f32 = if (is_web) 0 else btn_h + 8;
        return sect_h + fields.len * row_h + btn;
    }

    /// Y of the debug section's content, i.e. just below its title strip.
    fn debugTop() f32 {
        return panelRect().y + head_h + sect_h;
    }

    fn panelRect() rl.Rectangle {
        const h = head_h + debugH() + pad;
        return .{
            .x = @as(f32, @floatFromInt(rl.getScreenWidth())) - w - pad,
            .y = pad,
            .width = w,
            .height = h,
        };
    }

    fn closeRect() rl.Rectangle {
        const r = panelRect();
        return .{ .x = r.x + w - 28, .y = r.y + 6, .width = 22, .height = 22 };
    }

    fn trackRect(i: usize) rl.Rectangle {
        const r = panelRect();
        const row_y = debugTop() + @as(f32, @floatFromInt(i)) * row_h;
        return .{ .x = r.x + pad, .y = row_y + 24, .width = w - 2 * pad, .height = track_h };
    }

    fn saveRect() rl.Rectangle {
        const r = panelRect();
        return .{
            .x = r.x + pad,
            .y = debugTop() + fields.len * row_h + 4,
            .width = w - 2 * pad,
            .height = btn_h,
        };
    }

    fn fieldPtr(p: *sim.Planet, i: usize) *f32 {
        return switch (i) {
            0 => &p.mass,
            1 => &p.soi,
            else => &p.radius,
        };
    }

    fn fieldVal(p: sim.Planet, i: usize) f32 {
        return switch (i) {
            0 => p.mass,
            1 => p.soi,
            else => p.radius,
        };
    }

    pub fn handleMouse(self: *DetailPanel, planets: []sim.Planet, cam: rl.Camera2D, pan_offset: *Vec2) void {
        const m = rl.getMousePosition();
        if (rl.isMouseButtonReleased(.left)) self.dragging = null;

        if (self.selected) |idx| {
            if (rl.isMouseButtonPressed(.left)) {
                if (rl.checkCollisionPointRec(m, closeRect())) {
                    self.selected = null;
                    pan_offset.* = .{};
                    return;
                }
                if (!is_web and rl.checkCollisionPointRec(m, saveRect())) {
                    self.save_requested = true;
                    return;
                }
                for (fields, 0..) |_, i| {
                    const t = trackRect(i);
                    // Generous hit box so the 6 px track is easy to grab.
                    const hit: rl.Rectangle = .{
                        .x = t.x - knob_r,
                        .y = t.y - 14,
                        .width = t.width + 2 * knob_r,
                        .height = 32,
                    };
                    if (rl.checkCollisionPointRec(m, hit)) self.dragging = i;
                }
            }
            if (self.dragging) |i| {
                const t = trackRect(i);
                const frac = std.math.clamp((m.x - t.x) / t.width, 0, 1);
                fieldPtr(&planets[idx], i).* = fields[i].min + frac * (fields[i].max - fields[i].min);
                return;
            }
            // A click anywhere on the panel is the panel's, never the world's.
            if (rl.isMouseButtonPressed(.left) and rl.checkCollisionPointRec(m, panelRect())) return;
        }

        // A click in the world selects the planet under it, which also makes
        // it the camera's frame of reference; clicking it again, or empty
        // space, deselects and returns the view to the ship.
        if (rl.isMouseButtonPressed(.left)) {
            const wp = rl.getScreenToWorld2D(m, cam);
            const world_m: Vec2 = .{ .x = wp.x, .y = wp.y };
            const was = self.selected;
            self.selected = null;
            pan_offset.* = .{};
            for (planets, 0..) |p, i| {
                // Small bodies stay clickable at any zoom: at least ~24 screen px.
                const hit = @max(p.radius, 24.0 / cam.zoom);
                if (world_m.sub(p.pos).len() <= hit) {
                    if (was != i) {
                        self.selected = i;
                        // Selecting must not yank the view to the planet:
                        // keep the camera centre where it is, re-expressed
                        // as an offset from the newly followed body.
                        pan_offset.* = (Vec2{ .x = cam.target.x, .y = cam.target.y }).sub(p.pos);
                    }
                    break;
                }
            }
        }
    }

    /// Ring around the body being edited. Drawn inside the camera transform.
    pub fn drawSelection(self: DetailPanel, planets: []const sim.Planet) void {
        const idx = self.selected orelse return;
        const p = planets[idx];
        rl.drawCircleLinesV(v(p.pos), p.radius + 6, .{ .r = 255, .g = 210, .b = 90, .a = 200 });
        rl.drawCircleLinesV(v(p.pos), p.radius + 9, .{ .r = 255, .g = 210, .b = 90, .a = 90 });
    }

    /// The panel itself. Drawn in screen space, after the world.
    pub fn draw(self: DetailPanel, planets: []const sim.Planet) void {
        const idx = self.selected orelse return;
        const r = panelRect();

        rl.drawRectangleRec(r, .{ .r = 12, .g = 16, .b = 30, .a = 230 });
        rl.drawRectangleLinesEx(r, 1, .{ .r = 90, .g = 110, .b = 150, .a = 255 });

        const name: [:0]const u8 = if (idx == 0) "earth" else "moon";
        rl.drawText(name, @intFromFloat(r.x + pad), @intFromFloat(r.y + 8), 18, .{ .r = 255, .g = 210, .b = 90, .a = 255 });

        const close = closeRect();
        rl.drawText("x", @intFromFloat(close.x + 7), @intFromFloat(close.y + 2), 18, .{ .r = 180, .g = 195, .b = 220, .a = 255 });

        self.drawDebugSection(planets[idx]);
    }

    /// Title strip for a section: its name and a rule across the panel.
    fn drawSectionTitle(name: [:0]const u8, top: f32) void {
        const r = panelRect();
        rl.drawText(name, @intFromFloat(r.x + pad), @intFromFloat(top + 4), 14, .{ .r = 130, .g = 150, .b = 185, .a = 255 });
        const line_y = top + sect_h - 6;
        rl.drawLineV(
            .{ .x = r.x + pad, .y = line_y },
            .{ .x = r.x + w - pad, .y = line_y },
            .{ .r = 60, .g = 75, .b = 105, .a = 255 },
        );
    }

    /// Live tuning sliders plus (on desktop) the save-to-config button.
    fn drawDebugSection(self: DetailPanel, p: sim.Planet) void {
        drawSectionTitle("debug", panelRect().y + head_h);

        for (fields, 0..) |f, i| {
            const t = trackRect(i);
            const val = fieldVal(p, i);
            const frac = std.math.clamp((val - f.min) / (f.max - f.min), 0, 1);
            const fill = t.width * frac;

            const label = std.fmt.bufPrintZ(&text_buf, "{s}: {d:.0}", .{ f.name, val }) catch "";
            rl.drawText(label, @intFromFloat(t.x), @intFromFloat(t.y - 20), 18, .{ .r = 200, .g = 220, .b = 240, .a = 255 });

            rl.drawRectangleRec(t, .{ .r = 40, .g = 50, .b = 70, .a = 255 });
            rl.drawRectangleRec(
                .{ .x = t.x, .y = t.y, .width = fill, .height = t.height },
                .{ .r = 120, .g = 170, .b = 240, .a = 255 },
            );
            rl.drawCircleV(
                .{ .x = t.x + fill, .y = t.y + track_h / 2.0 },
                knob_r,
                .{ .r = 220, .g = 235, .b = 255, .a = 255 },
            );
        }

        if (!is_web) {
            const b = saveRect();
            const flashing = self.save_flash > 0;
            const border: rl.Color = if (!flashing)
                .{ .r = 90, .g = 110, .b = 150, .a = 255 }
            else if (self.save_ok)
                .{ .r = 90, .g = 230, .b = 120, .a = 255 }
            else
                .{ .r = 240, .g = 90, .b = 90, .a = 255 };
            const label: [:0]const u8 = if (!flashing)
                "save to " ++ config.path
            else if (self.save_ok)
                "saved"
            else
                "save failed";
            rl.drawRectangleRec(b, .{ .r = 30, .g = 45, .b = 70, .a = 255 });
            rl.drawRectangleLinesEx(b, 1, border);
            const tx = b.x + (b.width - @as(f32, @floatFromInt(rl.measureText(label, 16)))) / 2.0;
            rl.drawText(label, @intFromFloat(tx), @intFromFloat(b.y + 6), 16, .{ .r = 200, .g = 220, .b = 240, .a = 255 });
        }
    }
};
