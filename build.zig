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
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step(b.fmt("{s}", .{exe_name}), b.fmt("Run {s} util.", .{exe_name}));
        run_step.dependOn(&run_cmd.step);
    }

    var update_readme = build_pkg.UpdateReadme.init(b);
    b.getInstallStep().dependOn(&update_readme.step);
}
