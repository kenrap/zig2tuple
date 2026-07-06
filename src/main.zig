const std = @import("std");
const fmt = std.fmt;
const File = std.Io.File;
const mem = std.mem;

const lib = @import("lib.zig");
const Tuple = lib.Tuple;

pub fn main(init: std.process.Init) !void {
    const alc = init.arena.allocator();
    const args = init.minimal.args;
    const io = init.io;

    var args_iter = args.iterate();
    _ = args_iter.skip();
    const dir_path = args_iter.next() orelse return error.MissingDirPathArgument;

    var zon_iter = try lib.ZonFileIterator.init(alc, dir_path, io);
    defer zon_iter.deinit(io);

    var tuples: std.ArrayList(Tuple) = .empty;

    while (try zon_iter.next(alc, io)) |zon_file| {
        var diag: std.zon.parse.Diagnostics = .{};
        defer diag.deinit(alc);
        var dep_iter = try lib.ZonDependencyIterator.init(alc, zon_file.contents, &diag) orelse {
            if (diag.zoir.hasCompileErrors())
                std.debug.print("{s}: {f}", .{ zon_file.path, diag });
            continue;
        };
        while (dep_iter.next()) |dep| {
            const url = try dep.formatUrl(alc) orelse continue;
            const hash = dep.hash orelse continue;
            const line = try fmt.allocPrint(alc, "{s}:{s}:{s}", .{ dep.name, url, hash });
            try tuples.append(alc, .{ .hash = hash, .line = line });
        }
    }

    if (tuples.items.len == 0)
        return error.CannotFindDependencies;

    // Sort so duplicate hashes are adjacent, keep the first of each run,
    // then restore alphabetical order for display.
    mem.sortUnstable(Tuple, tuples.items, {}, Tuple.byHashThenLine);
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(alc, tuples.items[0].line);
    for (tuples.items[1..], 1..) |tuple, i| {
        if (mem.eql(u8, tuple.hash, tuples.items[i - 1].hash))
            continue;
        try lines.append(alc, tuple.line);
    }
    mem.sortUnstable([]const u8, lines.items, {}, lib.stringLessThan);

    var stdout_buffer: [1024 * 8]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &stdout_buffer);
    var stdout = &stdout_writer.interface;
    try stdout.print("ZIG_TUPLE=\t{s}", .{lines.items[0]});
    for (lines.items[1..]) |line| {
        try stdout.print(" \\\n\t\t{s}", .{line});
    }
    try stdout.writeByte('\n');
    try stdout.flush();
}
