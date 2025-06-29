const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const mem = std.mem;

const ProjectError = error {
    MissingCommandArgument,
    CannotFindDependencies,
};

const Dependency = struct {
    const Self = @This();

    name: []const u8,
    url: []const u8,
    hash: []const u8,
    _indexOffset: usize,

    pub fn init(slice: []const u8) ?Self {
        const dot = mem.indexOf(u8, slice, ".") orelse return null;
        const afterName = (mem.indexOf(u8, slice[dot..], " ") orelse return null) + dot;

        const start = (mem.indexOf(u8, slice[afterName + 1..], "{") orelse return null) + afterName + 1;
        const end = mem.indexOf(u8, slice[start..], "}") orelse return null;
        const contents = slice[start..start + end];

        return Self {
            .name = slice[dot + 1..afterName],
            .url = entry(contents, ".url") orelse return null,
            .hash = entry(contents, ".hash") orelse return null,
            ._indexOffset = start + end,
        };
    }

    fn entry(contents: []const u8, key: []const u8) ?[]const u8 {
        const index: usize = mem.indexOf(u8, contents, key) orelse return null;
        const start: usize = (mem.indexOf(u8, contents[index..], "\"") orelse return null) + index + 1;
        const end: usize = (mem.indexOf(u8, contents[start..], "\"") orelse return null) + start;
        return contents[start..end];
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

pub fn fileContents(allocator: mem.Allocator) ![]const u8 {
    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse return ProjectError.MissingCommandArgument;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(allocator, stat.size);
}

pub fn tarExtension(path: []const u8) []const u8 {
    const index = mem.lastIndexOf(u8, path, ".tar") orelse path.len;
    return path[index..];
}

pub fn findDistfile(allocator: mem.Allocator, url: []const u8) ![]const u8 {
    const base = std.fs.path.basename(url);
    var ext = tarExtension(base);
    if (ext.len == 0) {
        ext = ".tar.gz";
    }
    const index = mem.indexOf(u8, base, "#");
    var start: usize = 0;
    if (index) |value| {
        start = value + 1;
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{base[start..base.len - ext.len], ext});
}

pub fn processUrl(allocator: mem.Allocator, url: []const u8) ![]const u8 {
    var index = mem.indexOf(u8, url, "://") orelse 0;
    if (index != 0) index += 3;
    const baseUrl = std.fs.path.dirname(url[index..]).?;
    const distfile = try findDistfile(allocator, url);
    defer allocator.free(distfile);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{baseUrl, distfile});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const contents = try fileContents(allocator);
    defer allocator.free(contents);

    const depindex = mem.indexOf(u8, contents, ".dependencies") orelse return ProjectError.CannotFindDependencies;
    const start = mem.indexOf(u8, contents[depindex..], "{") orelse return ProjectError.CannotFindDependencies;
    const dependencies = contents[depindex + start..];

    print("ZIG_TUPLE=\t", .{});
    var newline = false;
    var iter = DependencyIterator.init(dependencies);
    while (iter.next()) |dep| {
        const url = try processUrl(allocator, dep.url);
        defer allocator.free(url);
        if (newline) {
            print(" \\\n\t\t{s}:{s}:{s}", .{dep.name, url, dep.hash});
        }
        else {
            print("{s}:{s}:{s}", .{dep.name, url, dep.hash});
        }
        newline = true;
    }
    print("\n", .{});
}
