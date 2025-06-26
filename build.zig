const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{
        .name = "zig2tuple",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
