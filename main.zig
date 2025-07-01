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
    hash: []const u8,
    _url: []const u8,
    _indexOffset: usize,

    pub fn init(slice: []const u8) ?Self {
        const dot = mem.indexOf(u8, slice, ".") orelse return null;
        const afterName = (mem.indexOf(u8, slice[dot..], " ") orelse return null) + dot;

        const start = (mem.indexOf(u8, slice[afterName + 1..], "{") orelse return null) + afterName + 1;
        const end = (mem.indexOf(u8, slice[start..], "}") orelse return null) + start;
        const contents = slice[start..end];

        return Self {
            .name = slice[dot + 1..afterName],
            .hash = entry(contents, ".hash") orelse return null,
            ._url = entry(contents, ".url") orelse return null,
            ._indexOffset = end,
        };
    }

    pub fn url(self: *const Self, allocator: mem.Allocator) ![]const u8 {
        var index = mem.indexOf(u8, self._url, "://") orelse 0;
        if (index != 0)
            index += 3;
        const baseUrl = fs.path.dirname(self._url[index..]).?;
        const file = try self.distfile(allocator);
        defer allocator.free(file);
        return try fmt.allocPrint(allocator, "{s}/{s}", .{baseUrl, file});
    }

    fn entry(contents: []const u8, key: []const u8) ?[]const u8 {
        const index: usize = mem.indexOf(u8, contents, key) orelse return null;
        const start: usize = (mem.indexOf(u8, contents[index..], "\"") orelse return null) + index + 1;
        const end: usize = (mem.indexOf(u8, contents[start..], "\"") orelse return null) + start;
        return contents[start..end];
    }

    fn distfile(self: *const Self, allocator: mem.Allocator) ![]const u8 {
        const base = fs.path.basename(self._url);
        const tarIndex = mem.lastIndexOf(u8, base, ".tar") orelse base.len;
        var ext = base[tarIndex..];
        if (ext.len == 0)
            ext = ".tar.gz";
        var start: usize = 0;
        if (mem.indexOf(u8, base, "#")) |hashOffset|
            start = hashOffset + 1;
        return try fmt.allocPrint(allocator, "{s}{s}", .{base[start..base.len - ext.len], ext});
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
    dirIter: fs.Dir.Iterator,

    pub fn init() !Self {
        var args = std.process.args();
        _ = args.skip();
        const path = args.next() orelse return ProjectError.MissingDirPathArgument;
        var dir = try std.fs.cwd().openDir(path, .{});
        return .{
            .dir = dir,
            .dirIter = dir.iterate(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.dir.close();
    }

    pub fn next(self: *Self) !?fs.File {
        while (try self.dirIter.next()) |entry| {
            if (entry.kind != std.fs.File.Kind.file)
                continue;
            if (!mem.eql(u8, fs.path.extension(entry.name), ".zon"))
                continue;
            return try self.dir.openFile(entry.name, .{});
        }
        return null;
    }
};

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var lines = ArrayList([]const u8).init(allocator);
    var zonIter = try ZonIterator.init();
    defer lines.deinit();
    defer zonIter.deinit();
    while (try zonIter.next()) |file| {
        const stat = try file.stat();
        const contents = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(contents);

        const depindex = mem.indexOf(u8, contents, ".dependencies") orelse return ProjectError.CannotFindDependencies;
        const start = mem.indexOf(u8, contents[depindex..], "{") orelse return ProjectError.CannotFindDependencies;
        const deps = contents[depindex + start..];

        var depIter = DependencyIterator.init(deps);
        while (depIter.next()) |dep| {
            const url = try dep.url(allocator);
            defer allocator.free(url);
            const line = try fmt.allocPrint(allocator, "{s}:{s}:{s}", .{dep.name, url, dep.hash});
            try lines.append(line);
        }
    }

    if (lines.items.len == 0)
        return;

    mem.sort([]const u8, lines.items, {}, stringLessThan);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("ZIG_TUPLE=\t{s}", .{lines.items[0]});
    for (lines.items[1..]) |line| {
        try stdout.print(" \\\n\t\t{s}", .{line});
    }
    try stdout.print("\n", .{});
}
