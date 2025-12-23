const std = @import("std");
const testing = std.testing;

const lib = @import("lib.zig");

test "Dependency Parsing" {
    const alc = testing.allocator;
    const zon_dep_literal =
        \\{
        \\    .one = .{
        \\        // one
        \\        .url = "https://some.url.com/one-0.0.1-12345_10.tar.gz",
        \\        .hash = "one-0.0.1-12345_10",
        \\        .lazy = true,
        \\    },
        \\    .two = .{
        \\        // two
        \\        .url = "https://some.url.org/two-67890.tar.bz2",
        \\        .hash = "two-0.2.0-some_long_hash_two",
        \\        .lazy = true,
        \\    },
        \\    .three = .{
        \\        // three
        \\        .url = "https://some.url.net/three-ABCDE.tar.xz",
        \\        .hash = "three-3.0.0-some_long_hash_three",
        \\        .lazy = true,
        \\    },
        \\}
    ;
    var dep_iter = lib.DependencyIterator.init(zon_dep_literal);
    var dep = dep_iter.next() orelse return error.CannotFindDep1;
    var url = try dep.url(alc) orelse return error.NullUrl1;
    var hash = dep.hash orelse return error.NullHash1;
    try testing.expectEqualStrings(url, "some.url.com/one-0.0.1-12345_10.tar.gz");
    try testing.expectEqualStrings(hash, "one-0.0.1-12345_10");
    alc.free(url);

    dep = dep_iter.next() orelse return error.CannotFindDep2;
    url = try dep.url(alc) orelse return error.NullUrl2;
    hash = dep.hash orelse return error.NullHash2;
    try testing.expectEqualStrings(url, "some.url.org/two-67890.tar.bz2");
    try testing.expectEqualStrings(hash, "two-0.2.0-some_long_hash_two");
    alc.free(url);

    dep = dep_iter.next() orelse return error.CannotFindDep3;
    url = try dep.url(alc) orelse return error.NullUrl3;
    hash = dep.hash orelse return error.NullHash3;
    try testing.expectEqualStrings(url, "some.url.net/three-ABCDE.tar.xz");
    try testing.expectEqualStrings(hash, "three-3.0.0-some_long_hash_three");
    alc.free(url);
}
