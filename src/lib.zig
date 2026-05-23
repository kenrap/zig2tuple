const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;

const Allocator = std.mem.Allocator;
const Args = std.process.Args;

const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;

const print = std.debug.print;

pub const Dependency = struct {
    const Self = @This();
    const tarball_types = [_][]const u8{
        ".tar",
        ".gz",
        ".xz",
        ".bz2",
        ".tgz",
        ".txz",
        ".tbz",
    };

    name: []const u8,
    hash: ?[]const u8,
    url: ?[]const u8,

    pub fn init(slice: []const u8) struct { value: ?Self, index_offset: ?usize } {
        const entry_open = mem.indexOf(u8, slice, ".{") orelse return .{ .value = null, .index_offset = null };
        const start = entry_open + 2;
        const end = (mem.indexOf(u8, slice[start..], "}") orelse return .{ .value = null, .index_offset = null }) + start;

        const prior_newline = mem.lastIndexOf(u8, slice[0..entry_open], "\n") orelse return .{ .value = null, .index_offset = end };
        const comment = mem.lastIndexOf(u8, slice[prior_newline..entry_open], "//");
        if (comment != null) {
            return .{ .value = null, .index_offset = end };
        }

        const contents = slice[start..end];
        const before_name = mem.lastIndexOf(u8, slice[0..entry_open], ".") orelse return .{ .value = null, .index_offset = end };
        const after_name = (mem.indexOf(u8, slice[before_name..], " ") orelse return .{ .value = null, .index_offset = end }) + before_name;

        const value = Self{
            .name = slice[before_name + 1 .. after_name],
            .hash = entry(contents, ".hash"),
            .url = entry(contents, ".url"),
        };
        return .{ .value = value, .index_offset = end };
    }

    pub fn formatUrl(self: *const Self, alc: Allocator) !?[]const u8 {
        const url = self.url orelse return null;
        var base = fs.path.basename(url);
        var ext: []const u8 = ".tar.gz"; // Default extension
        for (tarball_types[0..]) |tarball| {
            if (mem.lastIndexOf(u8, base, tarball)) |index| {
                ext = base[index..];
                break;
            }
        }
        var len: usize = base.len;
        if (len > ext.len) {
            len -= ext.len;
        }

        base = base[0 .. len];
        var name = base;
        var hash_opt: ?[]const u8 = null;
        if (mem.indexOf(u8, name, "#")) |i| {
            name = name[0..i];
            hash_opt = base[i + 1 ..];
        }
        if (mem.indexOf(u8, name, "?")) |i|
            name = name[0..i];
        if (mem.lastIndexOf(u8, name, ".git")) |i|
            name = name[0..i];

        var index = mem.indexOf(u8, url, "://") orelse 0;
        if (index != 0)
            index += 3;
        const host_url = fs.path.dirname(url[index..]) orelse return null;
        if (hash_opt) |hash| {
            return try fmt.allocPrint(alc, "{s}/{s}/archive/{s}{s}", .{ host_url, name, hash, ext });
        }
        return try fmt.allocPrint(alc, "{s}/{s}{s}", .{ host_url, name, ext });
    }

    fn findKey(contents: []const u8, key: []const u8) ?[]const u8 {
        const index: usize = mem.indexOf(u8, contents, key) orelse return null;
        if (mem.lastIndexOf(u8, contents[0..index], "\n")) |line_begin| {
            if (mem.indexOf(u8, contents[line_begin..index], "//")) |_| {
                if (mem.indexOf(u8, contents[index..], "\n")) |line_end| {
                    return findKey(contents[index + line_end + 1..], key);
                }
            }
        }
        return contents[index..];
    }

    fn findOpenQuote(contents: []const u8) ?[]const u8 {
        const index: usize = mem.indexOf(u8, contents, "\"") orelse return null;
        return contents[index + 1..];
    }

    fn findEndQuote(contents: []const u8) ?[]const u8 {
        const index: usize = mem.indexOf(u8, contents, "\"") orelse return null;
        return contents[0..index];
    }

    fn entry(contents: []const u8, key: []const u8) ?[]const u8 {
        const step1 = findKey(contents, key) orelse return null;
        const step2 = findOpenQuote(step1) orelse return null;
        const step3 = findEndQuote(step2) orelse return null;
        return step3;
    }
};

pub const ZonDependencyIterator = struct {
    const Self = @This();

    inner_contents: []const u8,
    buffer: []const u8,
    index: usize,

    pub fn init(alc: Allocator, file: *const File, io: Io) !?Self {
        const stat = try file.stat(io);
        var file_reader = file.reader(io, &.{});
        const contents = try file_reader.interface.allocRemaining(alc, .limited(stat.size + 1));
        const dep_index = mem.indexOf(u8, contents, ".dependencies") orelse return null;
        const start = mem.indexOf(u8, contents[dep_index..], "{") orelse return null;

        return .{
            .inner_contents = contents,
            .buffer = contents[dep_index + start ..],
            .index = 0,
        };
    }

    pub fn deinit(self: *Self, alc: Allocator) void {
        alc.free(self.inner_contents);
    }

    pub fn next(self: *Self) ?Dependency {
        var slice = self.buffer[self.index + 1 ..];
        var dep = Dependency.init(slice);

        if (dep.value == null) {
            self.index += dep.index_offset orelse return null;
            while (dep.value == null) {
                slice = self.buffer[self.index + 1 ..];
                dep = Dependency.init(slice);
                if (dep.value == null and dep.index_offset == null) return null;
                self.index += dep.index_offset.?;
            }
        }
        else {
            self.index += dep.index_offset orelse return null;
        }

        return dep.value orelse return null;
    }
};

pub const ZonFileIterator = struct {
    const Self = @This();

    dir: Dir,
    inner_iter: Dir.Walker,

    pub fn init(alc: Allocator, args: Args, io: Io) !Self {
        var args_iter = args.iterate();
        _ = args_iter.skip();
        const path = args_iter.next() orelse return error.MissingDirPathArgument;
        var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
        return .{
            .dir = dir,
            .inner_iter = try dir.walk(alc),
        };
    }

    pub fn deinit(self: *Self, io: Io) void {
        self.dir.close(io);
        self.inner_iter.deinit();
    }

    pub fn next(self: *Self, io: Io) !?File {
        while (try self.inner_iter.next(io)) |entry| {
            if (entry.kind != File.Kind.file)
                continue;
            if (mem.endsWith(u8, entry.path, ".zon"))
                return try self.dir.openFile(io, entry.path, .{});
        }
        return null;
    }
};

pub fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

pub fn hasSameItem(comptime T: type, list: []T, query: T) bool {
    for (list[0..]) |item| {
        const type_info = @typeInfo(T);
        if (comptime type_info.pointer.size == .slice) {
            if (mem.eql(type_info.pointer.child, item, query))
                return true;
        }
        else if (item == query)
            return true;
    }
    return false;
}
