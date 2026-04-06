const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev, x11, wayland, or macos") orelse "fbdev";
    const is_x11 = std.mem.eql(u8, backend_opt, "x11");
    const is_wayland = std.mem.eql(u8, backend_opt, "wayland");
    const is_macos = std.mem.eql(u8, backend_opt, "macos");

    const keymap_opt = b.option([]const u8, "keymap", "Keyboard layout: us or jp (default: us)") orelse "us";
    const use_jp_keymap = std.mem.eql(u8, keymap_opt, "jp");

    const scale_opt = b.option(u32, "scale", "Pixel scale factor: 1, 2, or 4 (default: 1)") orelse 1;
    const max_fps_opt = b.option(u32, "max_fps", "Maximum frame rate: 0 = unlimited (default: 120)") orelse 120;
    const pty_buf_kb_opt = b.option(u32, "pty_buf_kb", "PTY read buffer size in KB (default: 1024)") orelse 1024;
    const shell_opt_raw = b.option([]const u8, "shell", "Shell path (default: /bin/sh)") orelse "/bin/sh";
    const shell_opt: [:0]const u8 = b.allocator.dupeZ(u8, shell_opt_raw) catch @panic("OOM");

    const options = b.addOptions();
    options.addOption(bool, "use_x11", is_x11);
    options.addOption(bool, "use_wayland", is_wayland);
    options.addOption(bool, "use_macos", is_macos);
    options.addOption(bool, "use_jp_keymap", use_jp_keymap);
    options.addOption(u32, "scale", scale_opt);
    options.addOption(u32, "max_fps", max_fps_opt);
    options.addOption(u32, "pty_buf_kb", pty_buf_kb_opt);
    options.addOption([:0]const u8, "shell", shell_opt);

    const config_mod = b.createModule(.{
        .root_source_file = b.path("config.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const strip_opt = b.option(bool, "strip", "Strip debug info and symbols (default: false)") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip_opt) true else null,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zt",
        .root_module = exe_mod,
    });

    if (is_x11) {
        exe.linkSystemLibrary("xcb");
        exe.linkSystemLibrary("xcb-shm");
        exe.linkSystemLibrary("xcb-xkb");
        exe.linkSystemLibrary("xcb-imdkit");
        exe.linkSystemLibrary("xcb-util");
        exe.linkSystemLibrary("xkbcommon");
        exe.linkSystemLibrary("xkbcommon-x11");
        // Allow cross-compilation against shared libs with newer glibc
        exe.linker_allow_shlib_undefined = true;
        exe.linkLibC();
    } else if (is_wayland) {
        exe.linkSystemLibrary("xkbcommon");
        exe.linkLibC();
    } else if (is_macos) {
        exe.linkFramework("Cocoa");
        exe.linkFramework("QuartzCore");
        exe.linkLibC();
    }

    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    if (is_x11) {
        unit_tests.linkSystemLibrary("xcb");
        unit_tests.linkSystemLibrary("xcb-shm");
        unit_tests.linkSystemLibrary("xcb-xkb");
        unit_tests.linkSystemLibrary("xcb-imdkit");
        unit_tests.linkSystemLibrary("xcb-util");
        unit_tests.linkSystemLibrary("xkbcommon");
        unit_tests.linkSystemLibrary("xkbcommon-x11");
        unit_tests.linkLibC();
    } else if (is_wayland) {
        unit_tests.linkSystemLibrary("xkbcommon");
        unit_tests.linkLibC();
    } else if (is_macos) {
        unit_tests.linkFramework("Cocoa");
        unit_tests.linkFramework("QuartzCore");
        unit_tests.linkLibC();
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
