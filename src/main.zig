const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const ArrayList = std.ArrayList;

const lib = @import("lib.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lines = try ArrayList([]const u8).initCapacity(allocator, 32);
    var zonIter = try lib.ZonIterator.init(allocator);
    defer lines.deinit(allocator);
    defer zonIter.deinit();
    while (try zonIter.next()) |file| {
        const stat = try file.stat();
        const contents = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(contents);

        const depindex = mem.indexOf(u8, contents, ".dependencies") orelse continue;
        const start = mem.indexOf(u8, contents[depindex..], "{") orelse continue;
        const deps = contents[depindex + start..];

        var depIter = lib.DependencyIterator.init(deps);
        while (depIter.next()) |dep| {
            const url = try dep.url(allocator) orelse continue;
            const hash = dep.hash orelse continue;
            defer allocator.free(url);
            const line = try fmt.allocPrint(allocator, "{s}:{s}:{s}", .{dep.name, url, hash});
            if (lib.hasSameItem([]const u8, lines.items, line))
                continue;
            try lines.append(allocator, line);
        }
    }

    if (lines.items.len == 0)
        return lib.ProjectError.CannotFindDependencies;

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
