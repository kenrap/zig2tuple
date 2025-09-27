const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const exe = b.addExecutable(.{
        .name = "zig2tuple",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
