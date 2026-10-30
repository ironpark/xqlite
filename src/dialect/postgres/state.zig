//! The PostgreSQL session of a connection (dialect.ConnState.postgres):
//! the run-time parameters SET changes (search_path and the few others
//! session.zig knows). Values are owned by the connection's allocator.

const std = @import("std");

/// search_path as PostgreSQL's default shows it.
pub const default_search_path = "\"$user\", public";

/// The role $user stands for in search_path (current_user).
pub const user = "postgres";

pub const State = struct {
    /// Parameters set in this session, by name (lower case), as SHOW
    /// prints them; a parameter not here has its default.
    params: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        var it = s.params.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        s.params.deinit(gpa);
        s.* = .{};
    }

    /// The value of parameter `name` set in this session, or null.
    pub fn get(s: *const State, name: []const u8) ?[]const u8 {
        return s.params.get(name);
    }

    /// Set (or with null, reset) parameter `name`.
    pub fn set(s: *State, gpa: std.mem.Allocator, name: []const u8, value: ?[]const u8) error{OutOfMemory}!void {
        const v = value orelse {
            if (s.params.fetchRemove(name)) |kv| {
                gpa.free(kv.key);
                gpa.free(kv.value);
            }
            return;
        };
        const copy = try gpa.dupe(u8, v);
        errdefer gpa.free(copy);
        const gop = try s.params.getOrPut(gpa, name);
        if (gop.found_existing) {
            gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = gpa.dupe(u8, name) catch |err| {
                s.params.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = copy;
    }

    /// search_path as SHOW prints it.
    pub fn searchPath(s: *const State) []const u8 {
        return s.get("search_path") orelse default_search_path;
    }
};

/// The schema names of search_path text (PostgreSQL's
/// SplitIdentifierString: comma-separated, a "quoted" name kept, others
/// folded to lower case), "$user" replaced by `user`; in `a`.
pub fn splitPath(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (std.ascii.isWhitespace(text[i]) or text[i] == ',')) i += 1;
        if (i >= text.len) break;
        var name: std.ArrayList(u8) = .empty;
        if (text[i] == '"') {
            i += 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '"') {
                    if (i + 1 < text.len and text[i + 1] == '"') {
                        try name.append(a, '"');
                        i += 1;
                        continue;
                    }
                    i += 1;
                    break;
                }
                try name.append(a, text[i]);
            }
        } else {
            while (i < text.len and text[i] != ',' and !std.ascii.isWhitespace(text[i])) : (i += 1) {
                try name.append(a, std.ascii.toLower(text[i]));
            }
        }
        while (i < text.len and text[i] != ',') i += 1;
        const n = name.items;
        try out.append(a, if (std.mem.eql(u8, n, "$user")) user else n);
    }
    return out.items;
}

test "splitPath" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = try splitPath(arena.allocator(), "\"$user\", public, Sales,\"My \"\"S\"\"\"");
    try std.testing.expectEqual(@as(usize, 4), p.len);
    try std.testing.expectEqualStrings("postgres", p[0]);
    try std.testing.expectEqualStrings("public", p[1]);
    try std.testing.expectEqualStrings("sales", p[2]);
    try std.testing.expectEqualStrings("My \"S\"", p[3]);
}
