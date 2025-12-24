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
    var zon_iter = try lib.ZonIterator.init(allocator);
    defer lines.deinit(allocator);
    defer zon_iter.deinit();
    while (try zon_iter.next()) |zon_file| {
        switch (zon_file) {
            .orig => |file| {
                const stat = try file.stat();
                const contents = try file.readToEndAlloc(allocator, stat.size);
                defer allocator.free(contents);

                const dep_index = mem.indexOf(u8, contents, ".dependencies") orelse continue;
                const start = mem.indexOf(u8, contents[dep_index..], "{") orelse continue;
                const deps = contents[dep_index + start ..];

                var dep_iter = lib.DependencyIterator.init(deps);
                while (dep_iter.next()) |dep| {
                    const url = try dep.url(allocator) orelse continue;
                    const hash = dep.hash orelse continue;
                    defer allocator.free(url);
                    const line = try fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ dep.name, url, hash });
                    if (lib.hasSameItem([]const u8, lines.items, line))
                        continue;
                    try lines.append(allocator, line);
                }
            },
            .json => |file| {
                _ = file;
            },
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
