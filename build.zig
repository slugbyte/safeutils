const std = @import("std");
const build_pkg = @import("./src/build/root.zig");

pub fn build(b: *std.Build) void {
    const config = build_pkg.BuildConfig.init(b);

    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    const exe_names = [_][]const u8{ "copy", "move", "trash", "repo-open" };
    var executables: [exe_names.len]*std.Build.Step.Compile = undefined;

    for (exe_names, 0..) |exe_name, i| {
        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/exec/{s}.zig", .{exe_name})),
                .target = config.target,
                .optimize = config.optimize,
                .imports = &.{
                    .{ .name = "util", .module = util_mod },
                    .{ .name = "build_option", .module = config.createBuildOptionModule() },
                },
            }),
        });
        b.installArtifact(exe);
        executables[i] = exe;

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step(b.fmt("{s}", .{exe_name}), b.fmt("Run {s} util.", .{exe_name}));
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run integration tests");

    for (exe_names, 0..) |exe_name, i| {
        var test_options = b.addOptions();
        test_options.addOptionPath(
            b.fmt("{s}_exe_path", .{exe_name}),
            executables[i].getEmittedBin(),
        );

        const integration_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/{s}_cli_test.zig", .{exe_name})),
                .target = config.target,
                .optimize = config.optimize,
            }),
        });
        integration_test.root_module.addOptions("test_config", test_options);
        const run_test = b.addRunArtifact(integration_test);
        test_step.dependOn(&run_test.step);
    }

    var update_readme = build_pkg.UpdateReadme.init(b);
    b.getInstallStep().dependOn(&update_readme.step);
}
