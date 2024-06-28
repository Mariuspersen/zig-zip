const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("zip",.{
        .root_source_file = b.path("src/zip.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unzip = b.addExecutable(.{
        .name = "unzip",
        .root_source_file = b.path("examples/unzip.zig"),
        .target = target,
        .optimize = optimize,
    });

    unzip.root_module.addImport("zip", lib);

    b.installArtifact(unzip);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/zip.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
