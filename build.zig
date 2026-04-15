const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev, x11, wayland, or macos") orelse "fbdev";
    const is_x11 = std.mem.eql(u8, backend_opt, "x11");
    const is_wayland = std.mem.eql(u8, backend_opt, "wayland");
    const is_macos = std.mem.eql(u8, backend_opt, "macos");
    if (!is_x11 and !is_wayland and !is_macos and !std.mem.eql(u8, backend_opt, "fbdev")) {
        std.debug.panic("invalid -Dbackend='{s}'; expected fbdev, x11, wayland, or macos", .{backend_opt});
    }

    const keymap_opt = b.option([]const u8, "keymap", "Keyboard layout: us or jp (default: us)") orelse "us";
    const use_jp_keymap = std.mem.eql(u8, keymap_opt, "jp");
    if (!use_jp_keymap and !std.mem.eql(u8, keymap_opt, "us")) {
        std.debug.panic("invalid -Dkeymap='{s}'; expected us or jp", .{keymap_opt});
    }

    const scale_opt = b.option(u32, "scale", "Pixel scale factor: 1, 2, or 4 (default: 1)") orelse 1;
    const max_fps_opt = b.option(u32, "max_fps", "Maximum frame rate: 0 = unlimited (default: 120)") orelse 120;
    const pty_buf_kb_opt = b.option(u32, "pty_buf_kb", "PTY read buffer size in KB (default: 1024)") orelse 1024;
    if (pty_buf_kb_opt == 0) {
        @panic("invalid -Dpty_buf_kb=0; expected a positive buffer size");
    }
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
    options.addOption([:0]const u8, "version", b.allocator.dupeZ(u8, "0.7.0") catch @panic("OOM"));

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
        exe_mod.linkSystemLibrary("xcb", .{});
        exe_mod.linkSystemLibrary("xcb-shm", .{});
        exe_mod.linkSystemLibrary("xcb-xkb", .{});
        exe_mod.linkSystemLibrary("xcb-imdkit", .{});
        exe_mod.linkSystemLibrary("xcb-util", .{});
        exe_mod.linkSystemLibrary("xkbcommon", .{});
        exe_mod.linkSystemLibrary("xkbcommon-x11", .{});
        // Allow cross-compilation against shared libs with newer glibc
        exe.linker_allow_shlib_undefined = true;
        exe_mod.link_libc = true;
    } else if (is_wayland) {
        exe_mod.linkSystemLibrary("xkbcommon", .{});
        exe_mod.link_libc = true;
    } else if (is_macos) {
        exe_mod.linkFramework("Cocoa", .{});
        exe_mod.linkFramework("QuartzCore", .{});
        exe_mod.link_libc = true;
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
        test_mod.linkSystemLibrary("xcb", .{});
        test_mod.linkSystemLibrary("xcb-shm", .{});
        test_mod.linkSystemLibrary("xcb-xkb", .{});
        test_mod.linkSystemLibrary("xcb-imdkit", .{});
        test_mod.linkSystemLibrary("xcb-util", .{});
        test_mod.linkSystemLibrary("xkbcommon", .{});
        test_mod.linkSystemLibrary("xkbcommon-x11", .{});
        test_mod.link_libc = true;
    } else if (is_wayland) {
        test_mod.linkSystemLibrary("xkbcommon", .{});
        test_mod.link_libc = true;
    } else if (is_macos) {
        test_mod.linkFramework("Cocoa", .{});
        test_mod.linkFramework("QuartzCore", .{});
        test_mod.link_libc = true;
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
