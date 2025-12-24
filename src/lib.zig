const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const json = std.json;
const mem = std.mem;

const print = std.debug.print;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const File = std.fs.File;
const Dir = std.fs.Dir;

pub const Dependency = struct {
    const Self = @This();

    name: []const u8,
    hash: ?[]const u8,
    _url: ?[]const u8,

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
            ._url = entry(contents, ".url"),
        };
        return .{ .value = value, .index_offset = end };
    }

    fn findDistfile(self: *const Self) ?struct{ base: []const u8, ext: []const u8} {
        const _url = self._url orelse return null;
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
        var len: usize = base.len;
        if (len > ext.len) {
            len -= ext.len;
        }
        return .{ .base = base[0 .. len], .ext = ext };
    }

    fn findHostUrl(self: *const Self) ?[]const u8 {
        const _url = self._url orelse return null;
        var index = mem.indexOf(u8, _url, "://") orelse 0;
        if (index != 0)
            index += 3;
        return fs.path.dirname(_url[index..]);
    }

    fn parseForProject(base: []const u8) struct { name: []const u8, hash: ?[]const u8 } {
        var name = base;
        var hash: ?[]const u8 = null;
        if (mem.indexOf(u8, name, "#")) |i| {
            name = name[0..i];
            hash = base[i + 1 ..];
        }
        if (mem.indexOf(u8, name, "?")) |i| {
            name = name[0..i];
        }
        return .{ .name = name, .hash = hash };
    }

    pub fn url(self: *const Self, alc: Allocator) !?[]const u8 {
        const file = self.findDistfile() orelse return null;
        const project = parseForProject(file.base);
        const host_url = self.findHostUrl() orelse return null;
        if (project.hash) |hash| {
            return try fmt.allocPrint(alc, "{s}/{s}/archive/{s}{s}", .{ host_url, project.name, hash, file.ext });
        }
        return try fmt.allocPrint(alc, "{s}/{s}{s}", .{ host_url, project.name, file.ext });
    }

    fn entry(contents: []const u8, key: []const u8) ?[]const u8 {
        const index: usize = mem.indexOf(u8, contents, key) orelse return null;
        const start: usize = (mem.indexOf(u8, contents[index..], "\"") orelse return null) + index + 1;
        const end: usize = (mem.indexOf(u8, contents[start..], "\"") orelse return null) + start;
        return contents[start..end];
    }
};

pub const ZonDependencyIterator = struct {
    const Self = @This();

    inner_contents: []const u8,
    buffer: []const u8,
    index: usize,

    pub fn init(alc: Allocator, file: *const File) !?Self {
        const stat = try file.stat();
        const contents = try file.readToEndAlloc(alc, stat.size);
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

const ZonJsonValue = struct {
    name: []const u8,
    url: []const u8,
    hash: []const u8,
};

const ZonJsonMap = std.json.ArrayHashMap(ZonJsonValue);
const ZonJsonMapIterator = std.StringArrayHashMapUnmanaged(ZonJsonValue).Iterator;

const ZonFile = enum {
    zon,
    zon_json,
};

pub fn parseJson(alc: Allocator, json_file: *const File) !ZonJsonMap {
    const stat = try json_file.stat();
    const json_text = try json_file.readToEndAlloc(alc, stat.size);
    defer alc.free(json_text);

    const parsed = try std.json.parseFromSlice(std.json.Value, alc, json_text, .{});
    defer parsed.deinit();

    return try ZonJsonMap.jsonParseFromValue(alc, parsed.value, .{});
}

pub const ZonJsonDependencyIterator = struct {
    const Self = @This();

    json_zon_map: ZonJsonMap,
    inner_iter: ZonJsonMapIterator,

    pub fn init(alc: Allocator, file: *const File) !Self {
        const json_map = try parseJson(alc, file);
        return .{
            .json_zon_map = json_map,
            .inner_iter = json_map.map.iterator(),
        };
    }

    pub fn deinit(self: *Self, alc: Allocator) void {
        self.json_map.deinit(alc);
    }

    pub fn next(self: *Self) ?Dependency {
        while (self.inner_iter.next()) |entry| {
            const value = entry.value_ptr;
            const dep = Dependency {
                .name = value.name,
                .hash = entry.key_ptr.*,
                ._url = value.url,
            };
            return dep;
        }
        return null;
    }
};

pub const ZonFileIterator = struct {
    const Self = @This();

    dir: Dir,
    inner_iter: Dir.Walker,
    zon_file: ZonFile,

    pub fn init(alc: Allocator, zon_file: ZonFile) !Self {
        var args = std.process.args();
        _ = args.skip();
        const path = args.next() orelse return error.MissingDirPathArgument;
        var dir = try std.fs.cwd().openDir(path, .{});
        return .{
            .dir = dir,
            .inner_iter = try dir.walk(alc),
            .zon_file = zon_file,
        };
    }

    pub fn deinit(self: *Self) void {
        self.dir.close();
        self.inner_iter.deinit();
    }

    pub fn next(self: *Self) !?File {
        while (try self.inner_iter.next()) |entry| {
            if (entry.kind != File.Kind.file)
                continue;
            const ext = switch (self.zon_file) {
                .zon => ".zon",
                .zon_json => ".zon.json",
            };
            if (mem.endsWith(u8, entry.path, ext))
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
