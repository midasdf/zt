const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend_opt = b.option([]const u8, "backend", "Rendering backend: fbdev or x11") orelse "fbdev";
    const is_x11 = std.mem.eql(u8, backend_opt, "x11");

    const options = b.addOptions();
    options.addOption(bool, "use_x11", is_x11);

    const config_mod = b.createModule(.{
        .root_source_file = b.path("config.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zt",
        .root_module = exe_mod,
    });

    if (std.mem.eql(u8, backend_opt, "x11")) {
        exe.linkSystemLibrary("xcb");
        exe.linkSystemLibrary("xcb-shm");
        exe.linkSystemLibrary("xcb-xkb");
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

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
