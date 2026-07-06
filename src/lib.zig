const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Zoir = std.zig.Zoir;

pub const Dependency = struct {
    const Self = @This();

    name: []const u8,
    hash: ?[]const u8,
    url: ?[]const u8,

    /// Zig manifests use exactly two url forms, distinguished by scheme:
    ///   - `git+<transport>://host/path#<commit>` is a *repository* at a
    ///     commit. It is not directly downloadable. We point at the
    ///     forge's archive tarball for that commit.
    ///   - Any other url is already a direct link to an archive, emitted
    ///     verbatim (minus scheme). We do not inspect its extension: the
    ///     manifest guarantees it is a distfile, whatever the suffix.
    pub fn formatUrl(self: *const Self, alc: Allocator) !?[]const u8 {
        const url = self.url orelse return null;

        const git_prefix = "git+";
        if (!mem.startsWith(u8, url, git_prefix))
            return try alc.dupe(u8, stripScheme(url));

        // Repository ref: split off "#commit" (and any "?query"), drop a
        // trailing ".git", and target the forge archive endpoint.
        var repo = stripScheme(url[git_prefix.len..]);
        const commit = if (mem.indexOfScalar(u8, repo, '#')) |i| blk: {
            defer repo = repo[0..i];
            break :blk repo[i + 1 ..];
        }
        else return error.GitUrlMissingCommit;
        if (mem.indexOfScalar(u8, repo, '?')) |i| repo = repo[0..i];
        if (mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - ".git".len];

        return try fmt.allocPrint(alc, "{s}/archive/{s}.tar.gz", .{ repo, commit });
    }

    /// Drops a leading "scheme://", leaving "host/path...". Returns the
    /// input unchanged if there is no scheme.
    fn stripScheme(url: []const u8) []const u8 {
        const sep = "://";
        return if (mem.indexOf(u8, url, sep)) |i| url[i + sep.len ..] else url;
    }
};

pub const ZonDependencyIterator = struct {
    const Self = @This();

    zoir: Zoir,
    names: []const Zoir.NullTerminatedString,
    vals: Zoir.Node.Index.Range,
    index: u32,

    /// Returns null if `source` is not valid ZON or has no top-level
    /// `.dependencies` struct literal.
    ///
    /// `diag` may be null to ignore parse errors. Otherwise, when `source`
    /// is malformed, the parse results are moved into `diag` for error
    /// reporting: printing it with the "{f}" format specifier writes one
    /// "line:col: error: message" line per error. The caller must deinit
    /// `diag`, which is safe even if no error occurred.
    pub fn init(
        alc: Allocator,
        source: [:0]const u8,
        diag: ?*std.zon.parse.Diagnostics,
    ) !?Self {
        var ast = try std.zig.Ast.parse(alc, source, .zon);
        var ast_owned = true;
        defer if (ast_owned) ast.deinit(alc);
        var zoir = try std.zig.ZonGen.generate(alc, ast, .{});

        if (zoir.hasCompileErrors()) {
            if (diag) |d| {
                d.ast = ast;
                d.zoir = zoir;
                ast_owned = false;
            }
            else {
                zoir.deinit(alc);
            }
            return null;
        }

        const root = Zoir.Node.Index.root.get(zoir);
        if (root == .struct_literal) {
            const fields = root.struct_literal;
            for (fields.names, 0..) |field_name, i| {
                if (!mem.eql(u8, field_name.get(zoir), "dependencies"))
                    continue;
                const deps = fields.vals.at(@intCast(i)).get(zoir);
                if (deps != .struct_literal) break;
                return .{
                    .zoir = zoir,
                    .names = deps.struct_literal.names,
                    .vals = deps.struct_literal.vals,
                    .index = 0,
                };
            }
        }
        zoir.deinit(alc);
        return null;
    }

    pub fn deinit(self: *Self, alc: Allocator) void {
        self.zoir.deinit(alc);
    }

    pub fn next(self: *Self) ?Dependency {
        while (self.index < self.vals.len) {
            defer self.index += 1;
            const name = self.names[self.index].get(self.zoir);
            const val = self.vals.at(self.index).get(self.zoir);
            if (val != .struct_literal) continue;

            var dep = Dependency{ .name = name, .hash = null, .url = null };
            const fields = val.struct_literal;
            for (fields.names, 0..) |field_name, i| {
                const value = fields.vals.at(@intCast(i)).get(self.zoir);
                if (value != .string_literal) continue;
                const key = field_name.get(self.zoir);
                if (mem.eql(u8, key, "url")) {
                    dep.url = value.string_literal;
                }
                else if (mem.eql(u8, key, "hash")) {
                    dep.hash = value.string_literal;
                }
            }
            return dep;
        }
        return null;
    }
};

pub const ZonFile = struct {
    path: []const u8,
    contents: [:0]u8,
};

pub const ZonFileIterator = struct {
    const Self = @This();

    dir: Io.Dir,
    inner_iter: Io.Dir.Walker,

    pub fn init(alc: Allocator, path: []const u8, io: Io) !Self {
        var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        return .{
            .dir = dir,
            .inner_iter = try dir.walk(alc),
        };
    }

    pub fn deinit(self: *Self, io: Io) void {
        self.dir.close(io);
        self.inner_iter.deinit();
    }

    pub fn next(self: *Self, alc: Allocator, io: Io) !?ZonFile {
        while (try self.inner_iter.next(io)) |entry| {
            if (entry.kind != .file)
                continue;
            if (mem.endsWith(u8, entry.path, ".zon")) {
                return .{
                    // entry.path is invalidated by the walker's next step.
                    .path = try alc.dupe(u8, entry.path),
                    .contents = try self.dir.readFileAllocOptions(io, entry.path, alc, .unlimited, .of(u8), 0),
                };
            }
        }
        return null;
    }
};

pub fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return mem.lessThan(u8, lhs, rhs);
}

/// One ZIG_TUPLE output line, carrying its package hash for deduping:
/// the same dependency can appear in several .zon files across the tree
/// under different mirror URLs, and the hash names the content.
pub const Tuple = struct {
    hash: []const u8,
    line: []const u8,

    /// Groups duplicate hashes together. Within a group, lines sort
    /// smallest-first, so we keep the first of each group the same line no
    /// matter what order the entries were found in.
    pub fn byHashThenLine(_: void, lhs: Tuple, rhs: Tuple) bool {
        return switch (mem.order(u8, lhs.hash, rhs.hash)) {
            .lt => true,
            .gt => false,
            .eq => stringLessThan({}, lhs.line, rhs.line),
        };
    }
};
