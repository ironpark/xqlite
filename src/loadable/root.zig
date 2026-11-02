//! The xqlite loadable extension (`zig build ext`: libxqlite_ext.so or
//! .dylib; docs/extension.md): the engine functions and collations that
//! the schema text of a dialect calls, registered on a real sqlite3
//! connection, so that sqlite3 and every program on the system SQLite
//! can read and write a database xqlite made in a dialect.
//!
//! An adapter, not a fork. The functions are xqlite's own FuncDefs
//! (dialect/abi.zig's catalogue), compiled from the same sources: each
//! call is a call of the very same implementation with a real Context
//! and real Mems of the engine. The adapter
//!
//!  - keeps a private xqlite connection per sqlite3 connection (an
//!    in-memory database nothing is stored in): the Mems' connection,
//!    whose allocator, limits and PRNG the implementations use through
//!    api.contextDbHandle() and dfunc.gpa();
//!  - turns each sqlite3_value into a Mem of the same type, the text and
//!    blobs pointing at sqlite3's bytes (MEM_Static), with its subtype;
//!  - calls the implementation (x_sfunc, x_finalize, x_value, x_inverse)
//!    with a Context on a stand-in statement (Conn.vdbe), and the
//!    aggregate's accumulator Mem in sqlite3_aggregate_context();
//!  - turns the result Mem (value, subtype, error message and code) into
//!    the sqlite3_result_*() calls.
//!
//! Why this and not a second value-API backend behind api.zig's names:
//! the implementations use more than the value API. They allocate from
//! the connection (dfunc.gpa()), keep aggregate state in the engine's
//! aggregate Mem (dfunc.aggState()), cache parsed arguments as auxiliary
//! data, read the PRNG and the statement time, compare Mems with the
//! engine's memCompare(), format numbers with the engine's printf, raise
//! errors with an SQLSTATE (resultErrorState()), and run SQLite's own
//! conversions (text of a REAL, numeric affinity of a text) on the Mems.
//! A sqlite3_value backend would have to re-implement or fork every one
//! of those, and two implementations of the conversions could disagree on
//! a corner (an expression index is then corrupt); here there is one.
//! The statement of a call is a stand-in (Conn.vdbe): auxiliary data
//! lives for the call (xq_coerce() parses its type each call, SQLite's
//! JSON functions their argument), and the time of 'now' is read per
//! call, not once per statement.
//!
//! Left out, by dialect/abi.zig's `Unportable`: what reads the xqlite
//! session or catalog (current_setting(), pg_get_viewdef(), SQL Server's
//! SCOPE_IDENTITY() ...) and what is direct-only. The sequence functions
//! (nextval() ...) are sequence.zig's, over SQL on the sqlite3
//! connection, with catalog/sequence.zig's semantics and table. The
//! engine's table-valued functions (JSON_TABLE, OPENJSON, pg_catalog's
//! tables) are not registered (docs/extension.md).

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const vi = @import("../vdbe/vdbe_int.zig");
const mem = @import("../vdbe/mem.zig");
const api = @import("../vdbe/api.zig");
const main_mod = @import("../sql/main.zig");
const aux = @import("../vdbe/aux.zig");
const malloc = @import("../sql/malloc.zig");
const abi = @import("../dialect/abi.zig");
const sequence = @import("sequence.zig");
pub const c = @import("c.zig");

const FuncDef = int.FuncDef;
const CollSeq = int.CollSeq;
const Mem = vi.Mem;
const Context = vi.Context;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;

comptime {
    @export(&register, .{ .name = "xqe_register", .visibility = .hidden });
}

/// The functions the extension registers: the portable entries of the
/// catalogue, and the sequence functions (sequence.zig).
pub const functions: []const abi.Entry = blk: {
    @setEvalBranchQuota(1_000_000);
    var all: []const abi.Entry = &.{};
    for (abi.catalogue) |e| {
        if (e.unportable == null and e.sequence == null) all = all ++ &[_]abi.Entry{e};
    }
    break :blk all;
};

// ============================================================ connection

/// What the extension keeps for one sqlite3 connection: freed when the
/// last of its functions is (sqlite3_close(), or every one replaced).
pub const Conn = struct {
    host: *c.sqlite3,
    /// The private connection of the Mems.
    db: *Sqlite3,
    mem_vfs: @import("xqlite_vfs").mem.MemVfs,
    /// One per registered function: its pApp.
    binds: []Bind,
    /// Functions still registered with this as their state.
    refs: usize = 0,
    /// currval() and lastval() of the sequences (sequence.zig).
    seq: sequence.Session = .{},
    /// The statement of every call (Context.vdbe): a program of one
    /// OP_Function, for what the implementations ask of the statement
    /// running them. Its auxiliary data (sqlite3_set_auxdata()) is kept
    /// for the call only: SQLite's JSON functions cache a parse in it
    /// and read it back at once; a cache across calls would be keyed on
    /// a statement the extension cannot see.
    vdbe: vi.Vdbe,

    fn destroy(conn: *Conn) void {
        conn.seq.deinit(gpa);
        aux.deleteAuxData(conn.db, &conn.vdbe.aux_data, -1, 0);
        conn.vdbe.arena.deinit();
        _ = main_mod.close(conn.db);
        conn.mem_vfs.deinit();
        gpa.free(conn.binds);
        gpa.destroy(conn);
    }
};

/// The pApp of a function: its connection and its definition.
pub const Bind = struct {
    conn: *Conn,
    entry: *const abi.Entry,
};

const gpa = std.heap.c_allocator;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn openConn(host: *c.sqlite3) error{ OutOfMemory, CantOpen }!*Conn {
    const conn = try gpa.create(Conn);
    errdefer gpa.destroy(conn);
    conn.* = .{ .host = host, .db = undefined, .mem_vfs = .init(gpa, io()), .binds = &.{}, .vdbe = undefined };
    errdefer conn.mem_vfs.deinit();
    var h: ?*Sqlite3 = null;
    const rc = main_mod.open(conn.mem_vfs.interface(), ":memory:", .{}, &h);
    if (rc != RC.OK) {
        if (h) |d| _ = main_mod.close(d);
        return if (rc == RC.NOMEM) error.OutOfMemory else error.CantOpen;
    }
    conn.db = h.?;
    conn.vdbe = .{ .db = conn.db, .arena = .init(conn.db.gpa) };
    _ = aux.addOp3(&conn.vdbe, vi.OP.Function, 0, 0, 0);
    return conn;
}

/// The Context of a call of `b`'s function, on its connection's statement.
fn context(b: *Bind, out: *Mem, acc: ?*Mem, args: []*Mem) Context {
    return .{ .out = out, .func = b.entry.def, .mem = acc, .vdbe = &b.conn.vdbe, .i_op = 0, .argv = args, .argc = @intCast(args.len) };
}

/// After a call: what the statement of a call (OP_Function, the end of
/// sqlite3_step()) clears: the auxiliary data, the statement time, an
/// out-of-memory state of the connection.
fn endCall(conn: *Conn) void {
    aux.deleteAuxData(conn.db, &conn.vdbe.aux_data, -1, 0);
    conn.vdbe.i_current_time = 0;
    malloc.oomClear(conn.db);
}

// =========================================================== registration

/// The entry point's work (entry.c's sqlite3_xqliteext_init()): register
/// every function and collation on `host`.
fn register(host: *c.sqlite3, pz_err: ?*?[*:0]u8) callconv(.c) c_int {
    if (c.xqe_libversion_number() < min_version) {
        c.xqe_set_errmsg(pz_err, "xqlite extension: needs SQLite 3.31.0 or later");
        return c.SQLITE_ERROR;
    }
    const conn = openConn(host) catch |err| {
        c.xqe_set_errmsg(pz_err, if (err == error.OutOfMemory) "xqlite extension: out of memory" else "xqlite extension: cannot open its private connection");
        return if (err == error.OutOfMemory) c.SQLITE_NOMEM else c.SQLITE_ERROR;
    };
    conn.binds = gpa.alloc(Bind, functions.len + sequence.functions.len) catch {
        conn.destroy();
        return c.SQLITE_NOMEM;
    };
    // Each registration holds a reference, and the destructor of the
    // last frees the connection; this one keeps it alive meanwhile.
    conn.refs = 1;
    defer release(conn);
    for (functions, 0..) |*e, i| {
        conn.binds[i] = .{ .conn = conn, .entry = e };
        const rc = registerFunction(host, &conn.binds[i]);
        if (rc != c.SQLITE_OK) return failed(pz_err, host, e.name, rc);
    }
    inline for (&sequence.functions, functions.len..) |*e, i| {
        conn.binds[i] = .{ .conn = conn, .entry = e };
        conn.refs += 1;
        const rc = c.xqe_create_function(host, e.name.ptr, e.def.n_arg, flagsOf(e.def), &conn.binds[i], sequence.thunk(e), null, null, destroyBind);
        if (rc != c.SQLITE_OK) return failed(pz_err, host, e.name, rc);
    }
    for (abi.collations) |*k| {
        const rc = c.xqe_create_collation(host, k.coll.name.ptr, @constCast(k.coll), collate);
        if (rc != c.SQLITE_OK) return failed(pz_err, host, k.coll.name, rc);
    }
    return c.SQLITE_OK;
}

/// sqlite3_create_window_function() is 3.25.0, SQLITE_DIRECTONLY 3.30.0,
/// SQLITE_INNOCUOUS 3.31.0.
const min_version = 3031000;

fn failed(pz_err: ?*?[*:0]u8, host: *c.sqlite3, name: []const u8, rc: c_int) c_int {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "xqlite extension: cannot register {s}: {s}", .{ name, std.mem.span(c.xqe_errmsg(host)) }, 0) catch "xqlite extension: cannot register a function";
    c.xqe_set_errmsg(pz_err, msg.ptr);
    return rc;
}

fn registerFunction(host: *c.sqlite3, b: *Bind) c_int {
    const d = b.entry.def;
    b.conn.refs += 1;
    const flags = flagsOf(d);
    // SQLite's built-ins of 1 or more arguments (-3) and 2 or more (-4)
    // take any number here; scalarCall() checks the least.
    const n_arg: c_int = if (d.n_arg < -1) -1 else d.n_arg;
    if (d.x_finalize == null) {
        return c.xqe_create_function(host, b.entry.name.ptr, n_arg, flags, b, scalarCall, null, null, destroyBind);
    }
    if (d.x_value != null and d.x_inverse != null) {
        return c.xqe_create_window_function(host, b.entry.name.ptr, n_arg, flags, b, stepCall, finalCall, valueCall, inverseCall, destroyBind);
    }
    return c.xqe_create_function(host, b.entry.name.ptr, n_arg, flags, b, null, stepCall, finalCall, destroyBind);
}

/// The sqlite3_create_function() flags of `d`, as the engine treats it:
/// deterministic, innocuous unless UNSAFE (as xqlite's built-ins and
/// engine functions are usable from the schema with trusted_schema off),
/// direct-only, and the subtype flags.
pub fn flagsOf(d: *const FuncDef) c_int {
    const f = d.func_flags;
    var r: c_int = c.SQLITE_UTF8;
    if (f.CONSTANT) r |= c.SQLITE_DETERMINISTIC;
    if (!f.UNSAFE) r |= c.SQLITE_INNOCUOUS;
    if (f.DIRECT) r |= c.SQLITE_DIRECTONLY;
    if (f.SUBTYPE) r |= c.SQLITE_SUBTYPE;
    if (f.RESULT_SUBTYPE) r |= c.SQLITE_RESULT_SUBTYPE;
    return r;
}

fn destroyBind(p: ?*anyopaque) callconv(.c) void {
    const b: *Bind = @ptrCast(@alignCast(p.?));
    release(b.conn);
}

fn release(conn: *Conn) void {
    conn.refs -= 1;
    if (conn.refs == 0) conn.destroy();
}

// ================================================================ calls

/// The arguments of a call as Mems of the private connection.
const Args = struct {
    mems: []Mem,
    ptrs: []*Mem,
    buf_mems: [8]Mem = undefined,
    buf_ptrs: [8]*Mem = undefined,
    heap: bool = false,

    fn init(a: *Args, db: *Sqlite3, argc: c_int, argv: ?[*]?*c.sqlite3_value) error{OutOfMemory}!void {
        const n: usize = @intCast(argc);
        if (n <= a.buf_mems.len) {
            a.mems = a.buf_mems[0..n];
            a.ptrs = a.buf_ptrs[0..n];
        } else {
            a.mems = try gpa.alloc(Mem, n);
            a.ptrs = gpa.alloc(*Mem, n) catch |e| {
                gpa.free(a.mems);
                return e;
            };
            a.heap = true;
        }
        for (a.mems, a.ptrs, 0..) |*m, *p, i| {
            m.* = fromValue(db, argv.?[i].?);
            p.* = m;
        }
    }

    fn deinit(a: *Args) void {
        for (a.mems) |*m| mem.release(m);
        if (a.heap) {
            gpa.free(a.mems);
            gpa.free(a.ptrs);
        }
    }
};

/// The Mem of `v`: its type and value, text and blobs pointing at the
/// bytes sqlite3 holds (valid for the call), and its subtype.
pub fn fromValue(db: *Sqlite3, v: *c.sqlite3_value) Mem {
    var m: Mem = .{ .db = db };
    switch (c.xqe_value_type(v)) {
        c.SQLITE_INTEGER => mem.setInt64(&m, c.xqe_value_int64(v)),
        c.SQLITE_FLOAT => mem.setDouble(&m, c.xqe_value_double(v)),
        c.SQLITE_TEXT => {
            const z = c.xqe_value_text(v);
            const n = c.xqe_value_bytes(v);
            if (z) |p| {
                m.z = @constCast(p);
                m.n = n;
                m.flags = .{ .Str = true, .Static = true, .Term = true };
                m.enc = vi.ENC.UTF8;
            } else {
                // Out of memory converting it: as SQLite, a NULL.
                m.flags = .{ .Null = true };
            }
        },
        c.SQLITE_BLOB => {
            const n = c.xqe_value_bytes(v);
            const z = c.xqe_value_blob(v);
            m.z = if (n > 0) @ptrCast(@constCast(z)) else null;
            m.n = if (z != null) n else 0;
            m.flags = .{ .Blob = true, .Static = true };
            m.enc = vi.ENC.UTF8;
        },
        else => m.flags = .{ .Null = true },
    }
    const st = c.xqe_value_subtype(v);
    if (st != 0) {
        m.flags.Subtype = true;
        m.e_subtype = @truncate(st);
    }
    return m;
}

/// Give sqlite3 the result of a call: `out`'s value and subtype, or the
/// error `is_error` (an SQLite result code) with `out`'s message.
pub fn toResult(ctx: *c.sqlite3_context, d: *const FuncDef, out: *Mem, is_error: i32) void {
    if (is_error > 0) {
        switch (is_error) {
            RC.NOMEM => return c.xqe_result_error_nomem(ctx),
            RC.TOOBIG => return c.xqe_result_error_toobig(ctx),
            else => {},
        }
        const msg: []const u8 = if (out.flags.Str) out.bytes() else "";
        c.xqe_result_error(ctx, msg.ptr, @intCast(msg.len));
        if (is_error != RC.ERROR) c.xqe_result_error_code(ctx, is_error);
        return;
    }
    switch (api.valueType(out)) {
        vi.SQLITE_INTEGER => c.xqe_result_int64(ctx, api.valueInt64(out)),
        vi.SQLITE_FLOAT => c.xqe_result_double(ctx, api.valueDouble(out)),
        vi.SQLITE_TEXT => {
            const z = api.valueText(out) orelse return c.xqe_result_error_nomem(ctx);
            c.xqe_result_text(ctx, z.ptr, z.len);
        },
        vi.SQLITE_BLOB => {
            if (out.flags.Zero and out.n == 0) return c.xqe_result_zeroblob(ctx, @intCast(out.u.n_zero));
            const z = api.valueBlob(out) orelse "";
            c.xqe_result_blob(ctx, z.ptr, z.len);
        },
        else => c.xqe_result_null(ctx),
    }
    // A subtype only where the engine's would survive: sqlite3 built with
    // SQLITE_STRICT_SUBTYPE fails a function without
    // SQLITE_RESULT_SUBTYPE that sets one.
    if (out.flags.Subtype and out.e_subtype != 0 and d.func_flags.RESULT_SUBTYPE) {
        c.xqe_result_subtype(ctx, out.e_subtype);
    }
}

fn bindOf(ctx: *c.sqlite3_context) *Bind {
    return @ptrCast(@alignCast(c.xqe_user_data(ctx).?));
}

fn scalarCall(ctx_c: ?*c.sqlite3_context, argc: c_int, argv: ?[*]?*c.sqlite3_value) callconv(.c) void {
    const cc = ctx_c.?;
    const b = bindOf(cc);
    const db = b.conn.db;
    if (b.entry.def.n_arg < -2 and argc < -2 - @as(c_int, b.entry.def.n_arg)) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wrong number of arguments to function {s}()", .{b.entry.name}) catch "wrong number of arguments";
        return c.xqe_result_error(cc, msg.ptr, @intCast(msg.len));
    }
    var args: Args = .{ .mems = &.{}, .ptrs = &.{} };
    args.init(db, argc, argv) catch return c.xqe_result_error_nomem(cc);
    defer args.deinit();
    var out: Mem = .{ .db = db };
    defer mem.release(&out);
    defer endCall(b.conn);
    var ctx = context(b, &out, null, args.ptrs);
    b.entry.def.x_sfunc.?(&ctx, args.ptrs);
    toResult(cc, b.entry.def, &out, ctx.is_error);
}

/// The aggregate context of a call: the engine's accumulator Mem
/// (Context.mem), made on the first call.
const AggSlot = struct {
    acc: Mem,
    live: bool,
};

fn aggSlot(cc: *c.sqlite3_context, db: *Sqlite3) ?*AggSlot {
    const p = c.xqe_aggregate_context(cc, @sizeOf(AggSlot)) orelse return null;
    const slot: *AggSlot = @ptrCast(@alignCast(p));
    if (!slot.live) {
        slot.* = .{ .acc = .{ .db = db, .flags = .{ .Null = true } }, .live = true };
    }
    return slot;
}

fn stepOrInverse(ctx_c: ?*c.sqlite3_context, argc: c_int, argv: ?[*]?*c.sqlite3_value, inverse: bool) void {
    const cc = ctx_c.?;
    const b = bindOf(cc);
    const db = b.conn.db;
    const slot = aggSlot(cc, db) orelse return c.xqe_result_error_nomem(cc);
    var args: Args = .{ .mems = &.{}, .ptrs = &.{} };
    args.init(db, argc, argv) catch return c.xqe_result_error_nomem(cc);
    defer args.deinit();
    var out: Mem = .{ .db = db };
    defer mem.release(&out);
    defer endCall(b.conn);
    var ctx = context(b, &out, &slot.acc, args.ptrs);
    const f = if (inverse) b.entry.def.x_inverse.? else b.entry.def.x_sfunc.?;
    f(&ctx, args.ptrs);
    if (ctx.is_error > 0) toResult(cc, b.entry.def, &out, ctx.is_error);
}

fn stepCall(ctx_c: ?*c.sqlite3_context, argc: c_int, argv: ?[*]?*c.sqlite3_value) callconv(.c) void {
    stepOrInverse(ctx_c, argc, argv, false);
}

fn inverseCall(ctx_c: ?*c.sqlite3_context, argc: c_int, argv: ?[*]?*c.sqlite3_value) callconv(.c) void {
    stepOrInverse(ctx_c, argc, argv, true);
}

/// The aggregate's result: mem.finalize() as OP_AggFinal runs it, which
/// frees the accumulator and leaves the result in it.
fn finalCall(ctx_c: ?*c.sqlite3_context) callconv(.c) void {
    const cc = ctx_c.?;
    const b = bindOf(cc);
    const slot = aggSlot(cc, b.conn.db) orelse return c.xqe_result_error_nomem(cc);
    const r = mem.finalize(&slot.acc, b.entry.def);
    defer {
        mem.release(&slot.acc);
        slot.live = false;
        endCall(b.conn);
    }
    toResult(cc, b.entry.def, &slot.acc, r.rc);
}

/// A window aggregate's current value (OP_AggValue).
fn valueCall(ctx_c: ?*c.sqlite3_context) callconv(.c) void {
    const cc = ctx_c.?;
    const b = bindOf(cc);
    const slot = aggSlot(cc, b.conn.db) orelse return c.xqe_result_error_nomem(cc);
    var out: Mem = .{ .db = b.conn.db };
    defer mem.release(&out);
    defer endCall(b.conn);
    const r = mem.aggValue(&slot.acc, &out, b.entry.def);
    toResult(cc, b.entry.def, &out, r.rc);
}

// ============================================================ collations

fn collate(user: ?*anyopaque, n1: c_int, p1: ?*const anyopaque, n2: c_int, p2: ?*const anyopaque) callconv(.c) c_int {
    const coll: *const CollSeq = @ptrCast(@alignCast(user.?));
    const a: []const u8 = if (p1) |p| @as([*]const u8, @ptrCast(p))[0..@intCast(n1)] else "";
    const b: []const u8 = if (p2) |p| @as([*]const u8, @ptrCast(p))[0..@intCast(n2)] else "";
    return switch (coll.cmp.?(coll.user, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

test {
    _ = sequence;
}
