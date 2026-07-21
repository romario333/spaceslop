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

    // Sprites ship as WebP (≈¼ the size of quantized PNG), which raylib's
    // stb_image can't read, so the decode half of libwebp is vendored and
    // compiled straight into the game (see vendor/libwebp/README.md).
    // render.zig calls WebPDecodeRGBA through an extern. For the web build,
    // emccStep adds the emscripten sysroot include path to this module.
    exe_mod.addIncludePath(b.path("vendor/libwebp"));
    exe_mod.addCSourceFiles(.{
        .root = b.path("vendor/libwebp"),
        // Zig compiles C with UBSan traps in Debug; keep third-party code out
        // of that so an upstream benign UB can't abort the game.
        .flags = &.{"-fno-sanitize=undefined"},
        .files = &.{
            "src/dec/alpha_dec.c",
            "src/dec/buffer_dec.c",
            "src/dec/frame_dec.c",
            "src/dec/idec_dec.c",
            "src/dec/io_dec.c",
            "src/dec/quant_dec.c",
            "src/dec/tree_dec.c",
            "src/dec/vp8_dec.c",
            "src/dec/vp8l_dec.c",
            "src/dec/webp_dec.c",
            "src/dsp/alpha_processing.c",
            "src/dsp/alpha_processing_mips_dsp_r2.c",
            "src/dsp/alpha_processing_neon.c",
            "src/dsp/alpha_processing_sse2.c",
            "src/dsp/alpha_processing_sse41.c",
            "src/dsp/cpu.c",
            "src/dsp/dec.c",
            "src/dsp/dec_clip_tables.c",
            "src/dsp/dec_mips32.c",
            "src/dsp/dec_mips_dsp_r2.c",
            "src/dsp/dec_msa.c",
            "src/dsp/dec_neon.c",
            "src/dsp/dec_sse2.c",
            "src/dsp/dec_sse41.c",
            "src/dsp/filters.c",
            "src/dsp/filters_mips_dsp_r2.c",
            "src/dsp/filters_msa.c",
            "src/dsp/filters_neon.c",
            "src/dsp/filters_sse2.c",
            "src/dsp/lossless.c",
            "src/dsp/lossless_mips_dsp_r2.c",
            "src/dsp/lossless_msa.c",
            "src/dsp/lossless_neon.c",
            "src/dsp/lossless_sse2.c",
            "src/dsp/lossless_sse41.c",
            "src/dsp/rescaler.c",
            "src/dsp/rescaler_mips32.c",
            "src/dsp/rescaler_mips_dsp_r2.c",
            "src/dsp/rescaler_msa.c",
            "src/dsp/rescaler_neon.c",
            "src/dsp/rescaler_sse2.c",
            "src/dsp/upsampling.c",
            "src/dsp/upsampling_mips_dsp_r2.c",
            "src/dsp/upsampling_msa.c",
            "src/dsp/upsampling_neon.c",
            "src/dsp/upsampling_sse2.c",
            "src/dsp/upsampling_sse41.c",
            "src/dsp/yuv.c",
            "src/dsp/yuv_mips32.c",
            "src/dsp/yuv_mips_dsp_r2.c",
            "src/dsp/yuv_neon.c",
            "src/dsp/yuv_sse2.c",
            "src/dsp/yuv_sse41.c",
            "src/utils/bit_reader_utils.c",
            "src/utils/bit_writer_utils.c",
            "src/utils/color_cache_utils.c",
            "src/utils/filters_utils.c",
            "src/utils/huffman_utils.c",
            "src/utils/palette.c",
            "src/utils/quant_levels_dec_utils.c",
            "src/utils/random_utils.c",
            "src/utils/rescaler_utils.c",
            "src/utils/thread_utils.c",
            "src/utils/utils.c",
        },
    });

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
        // Emscripten defaults to a 64 KB stack, which image decoding blows
        // straight through (originally stb_image's PNG decoder; sprites are
        // WebP now, but libwebp needs stack room too). Native has an 8 MB
        // stack, which is why this only ever showed up in the browser.
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
