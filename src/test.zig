const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const lib = @import("lib.zig");

fn expectDep(alc: Allocator, dep: lib.Dependency, url: []const u8, hash: []const u8) !void {
    const format_url = try dep.formatUrl(alc) orelse return error.UrlNotFound;
    const dep_hash = dep.hash orelse return error.HashNotFound;
    try testing.expectEqualStrings(url, format_url);
    try testing.expectEqualStrings(hash, dep_hash);
    alc.free(format_url);
}

test "Dependency Parsing" {
    const alc = testing.allocator;

    const file = try std.fs.cwd().openFile("src/test_examples/build.zig.zon", .{});
    defer file.close();

    var dep_iter = try lib.ZonDependencyIterator.init(alc, &file) orelse return error.InvalidExample;
    defer dep_iter.deinit(alc);

    var dep = dep_iter.next() orelse return error.CannotFindDep1;
    try expectDep(
        alc,
        dep,
        "github.com/foo2/bar/archive/012345689abcdef0123456789abcdef012345678.tar.gz",
        "bar-0.0.0-ABCDEFGHIJKLMNOPQRSTUVWXYZ-abcdefghijklmnopq",
    );

    dep = dep_iter.next() orelse return error.CannotFindDep2;
    try expectDep(
        alc,
        dep,
        "one.two/three/four/archive/012345689abcdef0123456789abcdef012345678.tar.gz",
        "four-0.0.0-ABCDEFGHIJKLMNOPQRSTUVWXYZ-abcdefghijklmnopq",
    );

    dep = dep_iter.next() orelse return error.CannotFindDep3;
    try expectDep(
        alc,
        dep,
        "one.two/three/four/archive/CaseSensitive-Dep.tar.gz",
        "four-0.1.0-ABCDEFGHIJKLMNOPQRSTUVWXYZ-abcdefghijklmnopq",
    );
}
