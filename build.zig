const std = @import("std");

const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const md = b.addModule("md", .{
        .root_source_file = b.path("src/md.zig")
    });

    const options = b.addOptions();
    md.addOptions("build", options);

    const exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize
    });

    exe.root_module.addImport("md", md);

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Test minimal functionality");
    run_step.dependOn(&run_exe.step);
}