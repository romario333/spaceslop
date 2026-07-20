const std = @import("std");
const rlz = @import("raylib_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const requested_optimize = b.standardOptimizeOption(.{});

    // Zig 0.16.0's std lib fails to compile for wasm32-emscripten in Debug
    // (the panic/IO path pulls in child-process code the target can't build).
    // Transparently bump the web build to ReleaseSmall so `zig build
    // -Dtarget=wasm32-emscripten` just works.
    const is_web = target.query.os_tag == .emscripten;
    const optimize: std.builtin.OptimizeMode =
        if (is_web and requested_optimize == .Debug) .ReleaseSmall else requested_optimize;
    if (is_web and requested_optimize == .Debug) {
        std.log.info("web build: forcing ReleaseSmall (Debug is broken for emscripten on Zig 0.16)", .{});
    }

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    // The game module. Rendering (main.zig) imports raylib; the simulation
    // (sim.zig) stays dependency-free so it can be unit-tested on its own.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("raylib", raylib);

    const run_step = b.step("run", "Run the game");

    // Web builds go through Emscripten and are completely separate from native.
    if (target.query.os_tag == .emscripten) {
        const emsdk = rlz.emsdk;
        const wasm = b.addLibrary(.{
            .name = "space_slop",
            .root_module = exe_mod,
        });

        const install_dir: std.Build.InstallDir = .{ .custom = "web" };
        const emcc_flags = emsdk.emccDefaultFlags(b.allocator, .{ .optimize = optimize });
        var emcc_settings = emsdk.emccDefaultSettings(b.allocator, .{ .optimize = optimize });
        // Emscripten defaults to a 64 KB stack, which stb_image's PNG decoder
        // (used by raylib's LoadImage) blows straight through — every texture
        // load failed with a corrupt-PNG error on the web build. Native has an
        // 8 MB stack, which is why this only ever showed up in the browser.
        emcc_settings.put("STACK_SIZE", "4194304") catch unreachable;
        // Keep the debug-bridge dispatcher callable from the page via
        // Module.ccall (see src/debug.zig and web/shell.html).
        try emcc_settings.put("EXPORTED_FUNCTIONS", "_main,_space_slop_debug");

        const emcc_step = emsdk.emccStep(b, raylib_artifact, wasm, .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .shell_file_path = b.path("web/shell.html"),
            .install_dir = install_dir,
            .embed_paths = &.{.{ .src_path = "resources/" }},
        });
        b.getInstallStep().dependOn(emcc_step);

        const html_filename = try std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name});
        const emrun_step = emsdk.emrunStep(
            b,
            b.getInstallPath(install_dir, html_filename),
            &.{},
        );
        emrun_step.dependOn(emcc_step);
        run_step.dependOn(emrun_step);
    } else {
        const exe = b.addExecutable(.{
            .name = "space-slop",
            .root_module = exe_mod,
        });
        exe.root_module.linkLibrary(raylib_artifact);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // `zig build test` — runs the dependency-free simulation tests.
    const sim_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_sim_tests = b.addRunArtifact(sim_tests);
    const test_step = b.step("test", "Run simulation unit tests");
    test_step.dependOn(&run_sim_tests.step);
}
