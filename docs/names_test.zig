//! Checks that the names docs/zig-api.md writes (`xqlite.Value`,
//! `Db.lastError`, `OpenOptions.diagnostics` ...) exist in the xqlite
//! module, as a user of the module sees it. Run by `zig build test`,
//! which also builds examples/, so their names are checked too.

const std = @import("std");
const xqlite = @import("xqlite");

const doc = @embedFile("zig-api.md");

/// The names the doc may qualify: `xqlite` itself and these of its types.
const roots = [_][]const u8{ "xqlite", "Db", "Stmt", "Savepoint", "ResultCode", "OpenOptions", "Diagnostics", "Value", "Args", "FilterArgs" };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Every qualified name of `text`: a root, a dot and identifiers joined
/// by dots (`xqlite.malloc.configMalloc`), as the list of its parts.
/// File names (`src/xqlite.zig`, `api/Db.zig`) are skipped.
fn qualifiedNames(comptime text: []const u8) []const []const []const u8 {
    @setEvalBranchQuota(10_000_000);
    var names: []const []const []const u8 = &.{};
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (i > 0 and (isIdent(text[i - 1]) or text[i - 1] == '.' or text[i - 1] == '/')) continue;
        const root = for (roots) |r| {
            if (std.mem.startsWith(u8, text[i..], r) and i + r.len < text.len and text[i + r.len] == '.') break r;
        } else continue;
        var parts: []const []const u8 = &.{root};
        var j = i + root.len;
        while (j < text.len and text[j] == '.') {
            const start = j + 1;
            var end = start;
            while (end < text.len and isIdent(text[end])) end += 1;
            if (end == start) break;
            parts = parts ++ [_][]const u8{text[start..end]};
            j = end;
        }
        if (parts.len > 1 and !std.mem.eql(u8, parts[parts.len - 1], "zig")) names = names ++ [_][]const []const u8{parts};
        i = j;
    }
    return names;
}

/// Whether `parts` resolves in the module: each part a declaration of
/// the type before it, or (last) a field of it. Resolution stops at a
/// value that is not a type (a function such as `Db.open`).
fn resolves(comptime parts: []const []const u8) bool {
    var cur: type = if (std.mem.eql(u8, parts[0], "xqlite")) xqlite else @field(xqlite, parts[0]);
    for (parts[1..], 1..) |p, k| {
        if (@hasDecl(cur, p)) {
            const next = @field(cur, p);
            if (@TypeOf(next) != type) return true;
            cur = next;
        } else {
            return k == parts.len - 1 and switch (@typeInfo(cur)) {
                .@"struct", .@"union" => @hasField(cur, p),
                else => false,
            };
        }
    }
    return true;
}

test "zig api: every name in docs/zig-api.md exists" {
    const names = comptime qualifiedNames(doc);
    comptime std.debug.assert(names.len > 20);
    inline for (names) |parts| {
        comptime if (!resolves(parts)) {
            var msg: []const u8 = "docs/zig-api.md names `" ++ parts[0];
            for (parts[1..]) |p| msg = msg ++ "." ++ p;
            @compileError(msg ++ "`, which the xqlite module does not have");
        };
    }
}
