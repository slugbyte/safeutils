const std = @import("std");
const build_pkg = @import("./src/build/root.zig");

pub fn build(b: *std.Build) void {
    const config = build_pkg.BuildConfig.init(b);

    const util_mod = b.addModule("util", .{
        .root_source_file = b.path("src/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    const exe_list = [_][]const u8{
        "move",
        "copy",
        "trash",
    };

    var copy_exe: ?*std.Build.Step.Compile = null;
    var move_exe: ?*std.Build.Step.Compile = null;
    var trash_exe: ?*std.Build.Step.Compile = null;
    for (exe_list) |exe_name| {
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
        if (std.mem.eql(u8, exe_name, "copy")) {
            copy_exe = exe;
        }
        if (std.mem.eql(u8, exe_name, "move")) {
            move_exe = exe;
        }
        if (std.mem.eql(u8, exe_name, "trash")) {
            trash_exe = exe;
        }
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step(b.fmt("{s}", .{exe_name}), b.fmt("Run {s} util.", .{exe_name}));
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run integration tests");

    // Integration tests for copy
    {
        var test_options = b.addOptions();
        test_options.addOptionPath("copy_exe_path", copy_exe.?.getEmittedBin());

        const copy_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/copy_cli_test.zig"),
                .target = config.target,
                .optimize = config.optimize,
            }),
        });
        copy_test.root_module.addOptions("test_config", test_options);
        const run_copy_test = b.addRunArtifact(copy_test);
        test_step.dependOn(&run_copy_test.step);
    }

    // Integration tests for move
    {
        var test_options = b.addOptions();
        test_options.addOptionPath("move_exe_path", move_exe.?.getEmittedBin());

        const move_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/move_cli_test.zig"),
                .target = config.target,
                .optimize = config.optimize,
            }),
        });
        move_test.root_module.addOptions("test_config", test_options);
        const run_move_test = b.addRunArtifact(move_test);
        test_step.dependOn(&run_move_test.step);
    }

    // Integration tests for trash
    {
        var test_options = b.addOptions();
        test_options.addOptionPath("trash_exe_path", trash_exe.?.getEmittedBin());

        const trash_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/trash_cli_test.zig"),
                .target = config.target,
                .optimize = config.optimize,
            }),
        });
        trash_test.root_module.addOptions("test_config", test_options);
        const run_trash_test = b.addRunArtifact(trash_test);
        test_step.dependOn(&run_trash_test.step);
    }

    var update_readme = build_pkg.UpdateReadme.init(b);
    b.getInstallStep().dependOn(&update_readme.step);
}
