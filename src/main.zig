const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const ArrayList = std.ArrayList;

const lib = @import("lib.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alc = arena.allocator();

    var lines = try ArrayList([]const u8).initCapacity(alc, 32);
    defer lines.deinit(alc);

    var zon_json_iter = try lib.ZonFileIterator.init(alc, .zon_json);
    defer zon_json_iter.deinit();

    var zon_iter = try lib.ZonFileIterator.init(alc, .zon);
    defer zon_iter.deinit();

    var deps = try std.ArrayList(lib.Dependency).initCapacity(alc, 8);
    defer deps.deinit(alc);

    // Detecting .zon.json files first because they seem to have consistent
    // dependency data (such as the commit hashes) than .zon files
    while (try zon_json_iter.next()) |file| {
        var dep_iter = try lib.ZonJsonDependencyIterator.init(alc, &file);
        while (dep_iter.next()) |dep| {
            try deps.append(alc, dep);
        }
    }
    while (try zon_iter.next()) |file| {
        var dep_iter = try lib.ZonDependencyIterator.init(alc, &file) orelse continue;
        while (dep_iter.next()) |dep| {
            for (deps.items) |existing_dep| {
                const hash = dep.hash orelse continue;
                const existing_hash = existing_dep.hash orelse continue;
                if (mem.eql(u8, hash, existing_hash)) {
                    continue;
                }
            }
            try deps.append(alc, dep);
        }
    }

    for (deps.items) |dep| {
        const url = try dep.url(alc) orelse continue;
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
    var stdout_writer = fs.File.stdout().writer(&stdout_buffer);
    var stdout = &stdout_writer.interface;
    try stdout.print("ZIG_TUPLE=\t{s}", .{lines.items[0]});
    for (lines.items[1..]) |line| {
        try stdout.print(" \\\n\t\t{s}", .{line});
    }
    try stdout.print("\n", .{});
    try stdout.flush();
}
