const std = @import("std");
const build_pkg = @import("./root.zig");

const BuildConfig = @This();

target: std.Build.ResolvedTarget,
optimize: std.builtin.OptimizeMode,
build: *std.Build,

version: []const u8,
change_id: []const u8,
commit_id: []const u8,
description: []const u8,
date: []const u8,

pub fn init(b: *std.Build) BuildConfig {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    //
    const commit_id = build_pkg.run(b, .Pipe, .Ignore, &.{
        "jj",
        "--no-graph",
        "-r",
        "@",
        "-T",
        "commit_id",
    }).stdout orelse "no_git_hash";

    const change_id = build_pkg.run(b, .Pipe, .Ignore, &.{
        "jj",
        "--no-graph",
        "-r",
        "@",
        "-T",
        "change_id",
    }).stdout orelse "no_git_hash";

    const maybe_description = b.option(
        []const u8,
        "desc",
        "Short feature description for the build (required for release).",
    );

    const is_release = optimize != .Debug;
    if (is_release and maybe_description == null) {
        @panic("release builds require -Ddesc=\"...\"");
    }

    const description = maybe_description orelse "dev";

    // TODO: make my own date formatter
    const date = build_pkg.run(b, .Pipe, .Ignore, &.{
        "date",
        "+%y.%m.%d %H:%M",
    }).stdout orelse "yy.mm.dd hh:mm";

    const build_zon = @import("../../build.zig.zon");

    return .{
        .build = b,
        .target = target,
        .optimize = optimize,
        .version = build_zon.version,
        .date = std.mem.trim(u8, date, "\n\t "),
        .commit_id = std.mem.trim(u8, commit_id, "\n\t "),
        .change_id = std.mem.trim(u8, change_id, "\n\t "),
        .description = std.mem.trim(u8, description, "\n\t "),
    };
}

pub fn createBuildOptionModule(self: BuildConfig) *std.Build.Module {
    var config = self.build.addOptions();
    config.addOption([]const u8, "date", self.date);
    config.addOption([]const u8, "commit_id", self.commit_id);
    config.addOption([]const u8, "change_id", self.change_id);
    config.addOption([]const u8, "version", self.version);
    config.addOption([]const u8, "description", self.description);
    return config.createModule();
}
