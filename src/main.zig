const std = @import("std");
const fmt = std.fmt;
const File = std.Io.File;
const mem = std.mem;
const ArrayList = std.ArrayList;

const lib = @import("lib.zig");

pub fn main(init: std.process.Init) !void {
    const alc = init.arena.allocator();
    const args = init.minimal.args;
    const io = init.io;

    var zon_iter = try lib.ZonFileIterator.init(alc, args, io);
    defer zon_iter.deinit(io);

    var deps = try std.ArrayList(lib.Dependency).initCapacity(alc, 8);
    defer deps.deinit(alc);

    while (try zon_iter.next(io)) |file| {
        defer file.close(io);
        var dep_iter = try lib.ZonDependencyIterator.init(alc, &file, io) orelse continue;
        while (dep_iter.next()) |dep| {
            try deps.append(alc, dep);
        }
    }

    var lines = try ArrayList([]const u8).initCapacity(alc, 16);
    defer lines.deinit(alc);

    for (deps.items) |dep| {
        const url = try dep.formatUrl(alc) orelse continue;
        const hash = dep.hash orelse continue;
        defer alc.free(url);
        const line = try fmt.allocPrint(alc, "{s}:{s}:{s}", .{ dep.name, url, hash });
        if (lib.hasSameItem([]const u8, lines.items, line))
            continue;
        try lines.append(alc, line);
    }

    if (lines.items.len == 0)
        return error.CannotFindDependencies;

    mem.sort([]const u8, lines.items, {}, lib.stringLessThan);
    var stdout_buffer: [1024 * 8]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &stdout_buffer);
    var stdout = &stdout_writer.interface;
    try stdout.print("ZIG_TUPLE=\t{s}", .{lines.items[0]});
    for (lines.items[1..]) |line| {
        try stdout.print(" \\\n\t\t{s}", .{line});
    }
    try stdout.print("\n", .{});
    try stdout.flush();
}
