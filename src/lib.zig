const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const print = std.debug.print;

const ArrayList = std.ArrayList;

pub const ProjectError = error {
    MissingDirPathArgument,
    CannotFindDependencies,
};

pub const Dependency = struct {
    const Self = @This();

    name: []const u8,
    hash: ?[]const u8,
    _url: ?[]const u8,

    pub fn init(slice: []const u8) struct { value: ?Self, indexOffset: ?usize } {
        const entryOpen = mem.indexOf(u8, slice, ".{") orelse return .{ .value = null, .indexOffset = null };
        const start = entryOpen + 2;
        const end = (mem.indexOf(u8, slice[start..], "}") orelse return .{ .value = null, .indexOffset = null }) + start;

        const priorNewline = mem.lastIndexOf(u8, slice[0..entryOpen], "\n") orelse return .{ .value = null, .indexOffset = end };
        const lineComment = mem.lastIndexOf(u8, slice[priorNewline..entryOpen], "//");
        if (lineComment != null) {
            return .{ .value = null, .indexOffset = end };
        }

        const contents = slice[start..end];
        const beforeName = mem.lastIndexOf(u8, slice[0..entryOpen], ".") orelse return .{ .value = null, .indexOffset = end };
        const afterName = (mem.indexOf(u8, slice[beforeName..], " ") orelse return .{ .value = null, .indexOffset = end }) + beforeName;

        const value = Self {
            .name = slice[beforeName + 1..afterName],
            .hash = entry(contents, ".hash"),
            ._url = entry(contents, ".url"),
        };
        return .{ .value = value, .indexOffset = end };
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

pub const DependencyIterator = struct {
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
        var slice = self.buffer[self.index + 1..];
        var dep = Dependency.init(slice);

        if (dep.value == null) {
            self.index += dep.indexOffset orelse return null;
            while (dep.value == null) {
                slice = self.buffer[self.index + 1..];
                dep = Dependency.init(slice);
                if (dep.value == null and dep.indexOffset == null) return null;
                self.index += dep.indexOffset.?;
            }
        }
        else {
            self.index += dep.indexOffset orelse return null;
        }

        return dep.value orelse return null;
    }
};

pub const ZonIterator = struct {
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

pub fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

pub fn hasSameItem(comptime T: type, list: []T, query: T) bool {
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
