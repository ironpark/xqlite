//! Typed virtual table modules: a Zig type `T` describing a read-only
//! table becomes an sqlite3_module (see Db.createModule()).
//!
//! `T` declares:
//!
//! ```zig
//! const Range = struct {
//!     /// The columns (sqlite3_declare_vtab()). HIDDEN columns listed in
//!     /// `arg_columns` act as table-valued function arguments.
//!     pub const schema = "CREATE TABLE x(value INTEGER, lo HIDDEN, hi HIDDEN)";
//!     /// Optional: columns whose `=` constraints are passed to filter(),
//!     /// so that `SELECT * FROM range(1, 10)` works.
//!     pub const arg_columns = [_]usize{ 1, 2 };
//!
//!     // Table state, made by connect() for each CREATE VIRTUAL TABLE, or
//!     // once for the eponymous table `SELECT * FROM <module name>`.
//!     // `args` are the module arguments of CREATE VIRTUAL TABLE.
//!     pub fn connect(gpa: Allocator, [context: Ctx,] args: []const []const u8) !Range
//!     pub fn deinit(self: *Range, gpa: Allocator) void        // optional
//!
//!     pub const Cursor = struct {
//!         pub fn open(table: *Range) !Cursor
//!         pub fn deinit(self: *Cursor) void                    // optional
//!         /// Start a scan; `args.get(T, k)` is arg_columns[k], if constrained.
//!         pub fn filter(self: *Cursor, args: xqlite.FilterArgs) !void
//!         pub fn next(self: *Cursor) !void
//!         pub fn eof(self: *const Cursor) bool
//!         /// Any type a function may return (see value.zig).
//!         pub fn column(self: *Cursor, i: usize) T
//!         pub fn rowid(self: *Cursor) !i64                     // optional
//!     };
//! };
//! ```
//!
//! Every method may return an error union; the error name becomes the
//! statement's error message. Other constraints are not pushed down: the
//! engine filters the rows that the table returns.

const std = @import("std");
const engine = @import("engine.zig");
const errors = @import("errors.zig");
const value = @import("value.zig");
const func = @import("func.zig");
const Conn = @import("conn.zig").Conn;

const Allocator = std.mem.Allocator;
const OK = engine.RC.OK;
const ERROR = engine.RC.ERROR;
const NOMEM = engine.RC.NOMEM;

/// The values of the `arg_columns` constraints, passed to filter().
pub const FilterArgs = struct {
    /// Bit k is set if arg_columns[k] is constrained.
    mask: u32,
    argv: []*engine.Mem,

    /// Whether arg_columns[k] is constrained by the query.
    pub fn has(a: FilterArgs, k: usize) bool {
        return a.mask & (@as(u32, 1) << @intCast(k)) != 0;
    }

    /// The value of arg_columns[k] as `T`, or null if the query does not
    /// constrain it. Text and blobs are borrowed for the filter() call.
    pub fn get(a: FilterArgs, comptime T: type, k: usize) value.ReadError!?T {
        if (!a.has(k)) return null;
        const below = a.mask & ((@as(u32, 1) << @intCast(k)) - 1);
        return try value.read(T, value.MemSource{ .m = a.argv[@popCount(below)] });
    }
};

/// Report `err` (from a method) on `vt`.
fn report(vt: *engine.Vtab, h: *engine.Handle, err: anyerror) i32 {
    if (err == error.OutOfMemory) return NOMEM;
    engine.setVtabError(h, vt, @errorName(err));
    return ERROR;
}

/// Register `T` as module `name` (see Db.createModule()).
pub fn create(conn: Conn, gpa: Allocator, name: []const u8, comptime T: type, context: anytype) errors.Error!void {
    const Ctx = @TypeOf(context);
    func.checkContext(Ctx);
    if (!@hasDecl(T, "schema") or !@hasDecl(T, "connect") or !@hasDecl(T, "Cursor")) {
        @compileError("xqlite: a virtual table type needs `schema`, `connect` and `Cursor` (see src/api/module.zig)");
    }
    const C = T.Cursor;
    const arg_columns: []const usize = if (@hasDecl(T, "arg_columns")) &T.arg_columns else &.{};
    if (arg_columns.len > 32) @compileError("xqlite: at most 32 arg_columns");

    // The pAux of the module.
    const B = func.Box(Ctx);

    const Table = struct {
        base: engine.Vtab = .{},
        h: *engine.Handle,
        gpa: Allocator,
        user: T,
    };

    const Cur = struct {
        base: engine.VtabCursor = .{},
        user: C,

        fn of(cur: *engine.VtabCursor) *@This() {
            return @alignCast(@fieldParentPtr("base", cur));
        }
        fn table(cur: *engine.VtabCursor) *Table {
            return @alignCast(@fieldParentPtr("base", cur.vtab));
        }
    };

    const W = struct {
        fn xConnect(h_: *engine.Handle, a: *B, argv: []const [:0]const u8, out: *?*engine.Vtab, err: *?[:0]u8) i32 {
            engine.declareVtab(h_, T.schema) catch |e| return engine.errorCode(e);
            // argv: module name, database name, table name, then the
            // module arguments.
            const args = a.gpa.alloc([]const u8, argv.len -| 3) catch return NOMEM;
            defer a.gpa.free(args);
            for (args, argv[argv.len - args.len ..]) |*arg, z| arg.* = z;
            const t = a.gpa.create(Table) catch return NOMEM;
            const res = if (Ctx == void)
                T.connect(a.gpa, args)
            else
                T.connect(a.gpa, a.context, args);
            const user = if (@typeInfo(@TypeOf(res)) == .error_union) res catch |e| {
                a.gpa.destroy(t);
                if (e == error.OutOfMemory) return NOMEM;
                err.* = std.fmt.allocPrintSentinel(engine.connAllocator(h_), "{s}", .{@errorName(e)}, 0) catch null;
                return ERROR;
            } else res;
            t.* = .{ .h = h_, .gpa = a.gpa, .user = user };
            out.* = &t.base;
            return OK;
        }

        fn xDisconnect(vt: *engine.Vtab) i32 {
            const t: *Table = @alignCast(@fieldParentPtr("base", vt));
            if (@hasDecl(T, "deinit")) t.user.deinit(t.gpa);
            t.gpa.destroy(t);
            return OK;
        }

        fn xBestIndex(_: *engine.Vtab, info: *engine.IndexInfo) i32 {
            var which: [32]usize = undefined;
            var mask: u32 = 0;
            var unusable: u32 = 0;
            for (info.constraints, 0..) |c, ci| {
                if (c.op != engine.index_constraint_eq) continue;
                for (arg_columns, 0..) |col, k| {
                    const bit = @as(u32, 1) << @intCast(k);
                    if (c.i_column != @as(i32, @intCast(col))) continue;
                    if (!c.usable) {
                        unusable |= bit;
                    } else if (mask & bit == 0) {
                        mask |= bit;
                        which[k] = ci;
                    }
                }
            }
            // An argument given by the query but not available in this
            // plan (it comes from a table joined later): refuse the plan,
            // as series.c does, rather than scan with a default.
            if (unusable & ~mask != 0) return engine.RC.CONSTRAINT;
            var n: i32 = 0;
            for (0..arg_columns.len) |k| {
                if (mask & (@as(u32, 1) << @intCast(k)) == 0) continue;
                n += 1;
                info.usage[which[k]] = .{ .argv_index = n, .omit = true };
            }
            info.idx_num = @bitCast(mask);
            // Plans that pass more arguments are cheaper.
            info.estimated_cost = 1e6 / @as(f64, @floatFromInt(@as(u32, 1) << @intCast(n)));
            info.estimated_rows = 1000;
            return OK;
        }

        fn xOpen(vt: *engine.Vtab, out: *?*engine.VtabCursor) i32 {
            const t: *Table = @alignCast(@fieldParentPtr("base", vt));
            const cur = t.gpa.create(Cur) catch return NOMEM;
            const res = C.open(&t.user);
            const user = if (@typeInfo(@TypeOf(res)) == .error_union) res catch |e| {
                t.gpa.destroy(cur);
                return report(vt, t.h, e);
            } else res;
            cur.* = .{ .user = user };
            out.* = &cur.base;
            return OK;
        }

        fn xClose(cur: *engine.VtabCursor) i32 {
            const c = Cur.of(cur);
            const t = Cur.table(cur);
            if (@hasDecl(C, "deinit")) c.user.deinit();
            t.gpa.destroy(c);
            return OK;
        }

        fn status(cur: *engine.VtabCursor, r: anytype) i32 {
            if (@typeInfo(@TypeOf(r)) == .error_union) {
                _ = r catch |e| return report(cur.vtab, Cur.table(cur).h, e);
            }
            return OK;
        }

        fn xFilter(cur: *engine.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*engine.Mem) i32 {
            return status(cur, Cur.of(cur).user.filter(.{ .mask = @bitCast(idx_num), .argv = argv }));
        }

        fn xNext(cur: *engine.VtabCursor) i32 {
            return status(cur, Cur.of(cur).user.next());
        }

        fn xEof(cur: *engine.VtabCursor) bool {
            return Cur.of(cur).user.eof();
        }

        fn xColumn(cur: *engine.VtabCursor, ctx: *engine.Context, i: i32) i32 {
            value.setResult(ctx, Cur.of(cur).user.column(@intCast(i)));
            return OK;
        }

        fn xRowid(cur: *engine.VtabCursor, rowid: *i64) i32 {
            if (!@hasDecl(C, "rowid")) {
                engine.setVtabError(Cur.table(cur).h, cur.vtab, "this virtual table has no rowid");
                return ERROR;
            }
            const res = Cur.of(cur).user.rowid();
            rowid.* = if (@typeInfo(@TypeOf(res)) == .error_union) res catch |e| return report(cur.vtab, Cur.table(cur).h, e) else res;
            return OK;
        }

        const module: engine.Module = .{
            .x_create = engine.Module.constructor(xConnect),
            .x_connect = engine.Module.constructor(xConnect),
            .x_best_index = xBestIndex,
            .x_disconnect = xDisconnect,
            .x_destroy = xDisconnect,
            .x_open = xOpen,
            .x_close = xClose,
            .x_filter = xFilter,
            .x_next = xNext,
            .x_eof = xEof,
            .x_column = xColumn,
            .x_rowid = xRowid,
        };
    };

    const box = try B.create(conn, gpa, context);
    return conn.check(engine.createModule(conn.h, name, &W.module, engine.Module.auxFor(W.xConnect, box), B.x_destroy));
}
