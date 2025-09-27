const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const print = std.debug.print;

const ArrayList = std.ArrayList;

const ProjectError = error {
    MissingDirPathArgument,
    CannotFindDependencies,
};

const Dependency = struct {
    const Self = @This();

    name: []const u8,
    hash: ?[]const u8,
    _url: ?[]const u8,
    _indexOffset: usize,

    pub fn init(slice: []const u8) ?Self {
        const entryOpen = mem.indexOf(u8, slice, ".{") orelse return null;
        const beforeName = mem.lastIndexOf(u8, slice[0..entryOpen], ".") orelse return null;
        const afterName = (mem.indexOf(u8, slice[beforeName..], " ") orelse return null) + beforeName;

        const start = entryOpen + 2;
        const end = (mem.indexOf(u8, slice[start..], "}") orelse return null) + start;
        const contents = slice[start..end];

        return Self {
            .name = slice[beforeName + 1..afterName],
            .hash = entry(contents, ".hash"),
            ._url = entry(contents, ".url"),
            ._indexOffset = end,
        };
    }

    pub fn url(self: *const Self, allocator: mem.Allocator) !?[]const u8 {
        const _url = self._url orelse return null;
        var index = mem.indexOf(u8, _url, "://") orelse 0;
        if (index != 0)
            index += 3;
        const baseUrl = fs.path.dirname(_url[index..]).?;
        const file = try distfile(allocator, _url);
        defer allocator.free(file);
        return try fmt.allocPrint(allocator, "{s}/{s}", .{baseUrl, file});
    }

    fn entry(contents: []const u8, key: []const u8) ?[]const u8 {
        const index: usize = mem.indexOf(u8, contents, key) orelse return null;
        const start: usize = (mem.indexOf(u8, contents[index..], "\"") orelse return null) + index + 1;
        const end: usize = (mem.indexOf(u8, contents[start..], "\"") orelse return null) + start;
        return contents[start..end];
    }

    fn distfile(allocator: mem.Allocator, _url: []const u8) ![]const u8 {
        const base = fs.path.basename(_url);
        const tarball_checks = [_][]const u8{
            ".tar",
            ".gz",
            ".xz",
            ".bz2",
            ".tgz",
            ".txz",
            ".tbz",
        };
        var ext: []const u8 = ".tar.gz"; // Default extension
        for (tarball_checks[0..]) |tarball| {
            if (mem.lastIndexOf(u8, base, tarball)) |index| {
                ext = base[index..];
                break;
            }
        }
        if (mem.indexOf(u8, base, "#")) |hash|
            return try fmt.allocPrint(allocator, "{s}/archive/{s}{s}", .{base[0..hash], base[hash + 1..base.len - ext.len], ext});
        return try fmt.allocPrint(allocator, "{s}{s}", .{base[0..base.len - ext.len], ext});
    }
};

const DependencyIterator = struct {
    const Self = @This();

    buffer: []const u8,
    index: usize,

    pub fn init(buffer: []const u8) Self {
        return .{
            .buffer = buffer[0..],
            .index = 0,
        };
    }

    pub fn next(self: *Self) ?Dependency {
        const slice = self.buffer[self.index + 1..];
        const dep = Dependency.init(slice) orelse return null;
        self.index += dep._indexOffset;
        return dep;
    }
};

const ZonIterator = struct {
    const Self = @This();

    dir: fs.Dir,
    _iter: fs.Dir.Walker,

    pub fn init(allocator: mem.Allocator) !Self {
        var args = std.process.args();
        _ = args.skip();
        const path = args.next() orelse return ProjectError.MissingDirPathArgument;
        var dir = try std.fs.cwd().openDir(path, .{});
        return .{
            .dir = dir,
            ._iter = try dir.walk(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.dir.close();
        self._iter.deinit();
    }

    pub fn next(self: *Self) !?fs.File {
        while (try self._iter.next()) |entry| {
            if (entry.kind != std.fs.File.Kind.file)
                continue;
            if (!mem.eql(u8, fs.path.extension(entry.path), ".zon"))
                continue;
            return try self.dir.openFile(entry.path, .{});
        }
        return null;
    }
};

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn hasSameItem(comptime T: type, list: []T, query: T) bool {
    for (list[0..]) |item| {
        const typeInfo = @typeInfo(T);
        if (comptime typeInfo.pointer.size == .slice) {
            if (mem.eql(typeInfo.pointer.child, item, query))
                return true;
        }
        else if (item == query)
            return true;
    }
    return false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var lines = try ArrayList([]const u8).initCapacity(allocator, 32);
    var zonIter = try ZonIterator.init(allocator);
    defer lines.deinit(allocator);
    defer zonIter.deinit();
    while (try zonIter.next()) |file| {
        const stat = try file.stat();
        const contents = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(contents);

        const depindex = mem.indexOf(u8, contents, ".dependencies") orelse continue;
        const start = mem.indexOf(u8, contents[depindex..], "{") orelse continue;
        const deps = contents[depindex + start..];

        var depIter = DependencyIterator.init(deps);
        while (depIter.next()) |dep| {
            const url = try dep.url(allocator) orelse continue;
            const hash = dep.hash orelse continue;
            defer allocator.free(url);
            const line = try fmt.allocPrint(allocator, "{s}:{s}:{s}", .{dep.name, url, hash});
            if (hasSameItem([]const u8, lines.items, line))
                continue;
            try lines.append(allocator, line);
        }
    }

    if (lines.items.len == 0)
        return ProjectError.CannotFindDependencies;

    mem.sort([]const u8, lines.items, {}, stringLessThan);
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
