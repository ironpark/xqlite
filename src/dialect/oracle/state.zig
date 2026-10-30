//! The Oracle session of a connection (dialect.ConnState.oracle): the
//! current schema of ALTER SESSION SET CURRENT_SCHEMA. The name is owned
//! by the connection's allocator.

const std = @import("std");

/// The connected user, whose schema is SQLite's main (USER,
/// SYS_CONTEXT('USERENV', 'SESSION_USER'), OWNER of main's objects).
pub const user = "MAIN";

pub const State = struct {
    /// The current schema when it is not the user's: a schema of the
    /// registry (catalog/schema.zig), spelled as registered.
    current_schema: ?[]u8 = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.current_schema) |z| gpa.free(z);
        s.* = .{};
    }

    /// The current schema: `user` or a registered schema.
    pub fn currentSchema(s: *const State) []const u8 {
        return s.current_schema orelse user;
    }

    /// Make `name` the current schema (null: the user's).
    pub fn setCurrentSchema(s: *State, gpa: std.mem.Allocator, name: ?[]const u8) error{OutOfMemory}!void {
        const copy: ?[]u8 = if (name) |n| try gpa.dupe(u8, n) else null;
        if (s.current_schema) |z| gpa.free(z);
        s.current_schema = copy;
    }
};
