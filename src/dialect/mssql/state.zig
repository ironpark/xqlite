//! The per-connection state of the T-SQL dialect (dialect.ConnState.mssql):
//! the session's variables (DECLARE @x), SET IDENTITY_INSERT, the last
//! identity value (SCOPE_IDENTITY(), @@IDENTITY), the nesting of BEGIN
//! TRANSACTION, and the rows a MERGE has dealt with.
//!
//! The state is changed when statements run (by the dialect's functions,
//! runtime.zig and session.zig), and read when statements are compiled:
//! the declared type of a variable, the table with IDENTITY_INSERT on and
//! the transaction nesting shape the statements compiled after them, as
//! in SQL Server, where a batch is compiled after the statements before
//! it ran.

const std = @import("std");
const vi = @import("../../vdbe/vdbe_int.zig");
const api = @import("../../vdbe/api.zig");

/// A variable (@name): its declared type as written (lower case) and
/// its value (null for NULL).
pub const Var = struct {
    type: []u8,
    value: ?*vi.Mem = null,
};

pub const State = struct {
    /// Variables by name (without the @, lower case); names and types
    /// from the connection's allocator, values from api.valueDup().
    vars: std.StringHashMapUnmanaged(Var) = .empty,
    /// The table (lower case, "schema.table") SET IDENTITY_INSERT is on
    /// for: only one at a time, as in SQL Server.
    identity_insert: ?[]u8 = null,
    /// The identity value the session inserted last.
    last_identity: ?i64 = null,
    /// BEGIN TRANSACTION inside a transaction: how deep (@@TRANCOUNT is
    /// 1 + this while a transaction is open).
    tran_nest: u32 = 0,
    /// The name of the outermost BEGIN TRANSACTION (lower case).
    tran_name: ?[]u8 = null,
    /// The MERGE being run: the source rows it inserted (by number) and
    /// the target rows its WHEN NOT MATCHED BY SOURCE clauses changed (by
    /// rowid), which its WHEN MATCHED clauses leave alone.
    merge_src: std.AutoHashMapUnmanaged(i64, void) = .empty,
    merge_tgt: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// ALTER USER ... WITH DEFAULT_SCHEMA = s: the schema (of CREATE
    /// SCHEMA) unqualified names resolve in before dbo, and where they
    /// are created; null for dbo. The session's, as xqlite has no users.
    default_schema: ?[]u8 = null,
    /// CREATE SCHEMA s CREATE TABLE ... : the schema the elements that
    /// follow (CREATE TABLE/VIEW up to the end of the statement) go in.
    schema_element: ?[]u8 = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        var it = s.vars.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            freeVar(gpa, e.value_ptr.*);
        }
        s.vars.deinit(gpa);
        if (s.identity_insert) |z| gpa.free(z);
        if (s.tran_name) |z| gpa.free(z);
        if (s.default_schema) |z| gpa.free(z);
        if (s.schema_element) |z| gpa.free(z);
        s.merge_src.deinit(gpa);
        s.merge_tgt.deinit(gpa);
        s.* = .{};
    }

    fn freeVar(gpa: std.mem.Allocator, v: Var) void {
        gpa.free(v.type);
        if (v.value) |m| api.valueFree(m);
    }

    /// DECLARE @name type: (re)declare it, NULL.
    pub fn declare(s: *State, gpa: std.mem.Allocator, name: []const u8, ty: []const u8) error{OutOfMemory}!void {
        const t = try gpa.dupe(u8, ty);
        errdefer gpa.free(t);
        if (s.vars.getPtr(name)) |v| {
            freeVar(gpa, v.*);
            v.* = .{ .type = t };
            return;
        }
        const key = try gpa.dupe(u8, name);
        errdefer gpa.free(key);
        try s.vars.put(gpa, key, .{ .type = t });
    }

    /// The variable called `name`, null if not declared.
    pub fn get(s: *const State, name: []const u8) ?*Var {
        return s.vars.getPtr(name);
    }

    /// Give variable `name` (declared) a copy of `v`.
    pub fn assign(s: *State, name: []const u8, v: *vi.Mem) error{ OutOfMemory, Undeclared }!void {
        const x = s.vars.getPtr(name) orelse return error.Undeclared;
        const copy: ?*vi.Mem = if (api.valueType(v) == vi.SQLITE_NULL) null else (api.valueDup(v) orelse return error.OutOfMemory);
        if (x.value) |old| api.valueFree(old);
        x.value = copy;
    }

    /// Replace an owned optional string.
    pub fn setText(gpa: std.mem.Allocator, slot: *?[]u8, z: ?[]const u8) error{OutOfMemory}!void {
        const copy: ?[]u8 = if (z) |x| try gpa.dupe(u8, x) else null;
        if (slot.*) |old| gpa.free(old);
        slot.* = copy;
    }
};
