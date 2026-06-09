const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as `@import("gitmeta")`.
    const mod = b.addModule("gitmeta", .{
        .root_source_file = b.path("src/gitmeta.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test` — compiles and runs every `test {}` block reachable
    // from the module root (gitmeta.zig pulls in the test files).
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build example [-- <repo>]` — runnable demo of the API.
    const example = b.addExecutable(.{
        .name = "gitmeta-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/usage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gitmeta", .module = mod }},
        }),
    });
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run the usage example");
    example_step.dependOn(&run_example.step);
}
