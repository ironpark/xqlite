//! The bytecode() and tables_used() table-valued functions (port of
//! vdbevtab.c, SQLITE_ENABLE_BYTECODE_VTAB): the instructions of a
//! statement, and the tables and indexes it opens.
//!
//!     SELECT * FROM bytecode('SELECT ...');
//!     SELECT * FROM tables_used('SELECT ...');
//!
//! The argument is SQL text or a statement pointer of type "stmt-pointer".

const std = @import("std");
const int = @import("../sql/sqlite_int.zig");
const vi = @import("vdbe_int.zig");
const aux = @import("aux.zig");
const mem = @import("mem.zig");
const api = @import("api.zig");
const vtab = @import("../sql/vtab.zig");
const prepare = @import("../sql/prepare.zig");

const Sqlite3 = int.Sqlite3;
const Vdbe = vi.Vdbe;
const Op = vi.Op;
const Mem = vi.Mem;
const OP = vi.OP;
const RC = int.RC;

/// An instance of bytecode() or tables_used() (bytecodevtab).
const BytecodeVtab = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
    /// 2 for tables_used(), 0 for bytecode().
    b_tables_used: u8,

    fn of(p: *vtab.Vtab) *BytecodeVtab {
        return @fieldParentPtr("base", p);
    }
};

/// A cursor over the bytecode (bytecodevtab_cursor).
const BytecodeCursor = struct {
    base: vtab.VtabCursor = .{},
    /// The statement whose bytecode is shown.
    stmt: ?*Vdbe = null,
    /// The rowid of the output table.
    i_rowid: i32 = 0,
    /// Address.
    i_addr: usize = 0,
    /// The cursor owns `stmt` and must finalize it.
    need_finalize: bool = false,
    /// List the trigger programs too.
    show_subprograms: bool = false,
    /// The instructions; null at the end.
    a_op: ?[]Op = null,
    /// P4 as text.
    z_p4: ?[:0]u8 = null,
    /// tables_used.type, .schema and .name.
    z_type: ?[:0]const u8 = null,
    z_schema: ?[:0]const u8 = null,
    z_name: ?[:0]const u8 = null,
    /// The trigger programs seen (see aux.nextOpcode()).
    sub: Mem,

    fn of(cur: *vtab.VtabCursor) *BytecodeCursor {
        return @fieldParentPtr("base", cur);
    }
};

const schemas = [2][:0]const u8{
    // bytecode()
    "CREATE TABLE x(" ++
        "addr INT," ++
        "opcode TEXT," ++
        "p1 INT," ++
        "p2 INT," ++
        "p3 INT," ++
        "p4 TEXT," ++
        "p5 INT," ++
        "comment TEXT," ++
        "subprog TEXT," ++
        "nexec INT," ++
        "ncycle INT," ++
        "stmt HIDDEN" ++
        ");",
    // tables_used()
    "CREATE TABLE x(" ++
        "type TEXT," ++
        "schema TEXT," ++
        "name TEXT," ++
        "wr INT," ++
        "subprog TEXT," ++
        "stmt HIDDEN" ++
        ");",
};

/// Port of bytecodevtabConnect(). A non-null `aux_data` makes
/// tables_used().
fn bytecodevtabConnect(db: *Sqlite3, aux_data: ?*anyopaque, _: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const is_tab_used = aux_data != null;
    const rc = vtab.declareVtab(db, schemas[@intFromBool(is_tab_used)]);
    if (rc == RC.OK) {
        const new = db.gpa.create(BytecodeVtab) catch return RC.NOMEM;
        new.* = .{ .db = db, .b_tables_used = @as(u8, @intFromBool(is_tab_used)) * 2 };
        pp_vtab.* = &new.base;
    }
    return rc;
}

/// Port of bytecodevtabDisconnect().
fn bytecodevtabDisconnect(p: *vtab.Vtab) i32 {
    const t = BytecodeVtab.of(p);
    t.db.gpa.destroy(t);
    return RC.OK;
}

/// Port of bytecodevtabOpen().
fn bytecodevtabOpen(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t = BytecodeVtab.of(p);
    const c = t.db.gpa.create(BytecodeCursor) catch return RC.NOMEM;
    c.* = .{ .sub = Mem.init(t.db, vi.MEM.Null) };
    pp_cursor.* = &c.base;
    return RC.OK;
}

/// Port of bytecodevtabCursorClear().
fn cursorClear(c: *BytecodeCursor, db: *Sqlite3) void {
    if (c.z_p4) |z| db.gpa.free(z);
    c.z_p4 = null;
    mem.release(&c.sub);
    mem.setNull(&c.sub);
    if (c.need_finalize) {
        if (c.stmt) |s| _ = api.finalize(s);
    }
    c.stmt = null;
    c.need_finalize = false;
    c.z_type = null;
    c.z_schema = null;
    c.z_name = null;
}

/// Port of bytecodevtabClose().
fn bytecodevtabClose(cur: *vtab.VtabCursor) i32 {
    const c = BytecodeCursor.of(cur);
    const db = BytecodeVtab.of(cur.vtab).db;
    cursorClear(c, db);
    db.gpa.destroy(c);
    return RC.OK;
}

/// Port of bytecodevtabNext().
fn bytecodevtabNext(cur: *vtab.VtabCursor) i32 {
    const c = BytecodeCursor.of(cur);
    const t = BytecodeVtab.of(cur.vtab);
    if (c.z_p4) |z| {
        t.db.gpa.free(z);
        c.z_p4 = null;
    }
    if (c.z_name != null) {
        c.z_name = null;
        c.z_type = null;
        c.z_schema = null;
    }
    var ops: []Op = &.{};
    const rc = aux.nextOpcode(c.stmt.?, if (c.show_subprograms) &c.sub else null, t.b_tables_used, &c.i_rowid, &c.i_addr, &ops);
    if (rc != RC.OK) {
        mem.setNull(&c.sub);
        c.a_op = null;
    } else {
        c.a_op = ops;
    }
    return RC.OK;
}

/// Port of bytecodevtabEof().
fn bytecodevtabEof(cur: *vtab.VtabCursor) bool {
    return BytecodeCursor.of(cur).a_op == null;
}

/// Port of bytecodevtabColumn().
fn bytecodevtabColumn(cur: *vtab.VtabCursor, ctx: *vi.Context, i_arg: i32) i32 {
    const c = BytecodeCursor.of(cur);
    const t = BytecodeVtab.of(cur.vtab);
    const a_op = c.a_op.?;
    const op = &a_op[c.i_addr];
    var i = i_arg;
    if (t.b_tables_used != 0) {
        if (i == 4) {
            i = 8;
        } else {
            if (i <= 2 and c.z_type == null) {
                const i_db: usize = @intCast(op.p3);
                const root: int.Pgno = @intCast(op.p2);
                const db = t.db;
                const schema = db.dbs.items[i_db].schema;
                c.z_schema = db.dbs.items[i_db].name;
                var it = schema.tbl_hash.valueIterator();
                while (it.next()) |tp| {
                    const tab = tp.*;
                    if (!tab.isVirtual() and tab.tnum == root) {
                        c.z_name = tab.name;
                        c.z_type = "table";
                        break;
                    }
                }
                if (c.z_name == null) {
                    var ii = schema.idx_hash.valueIterator();
                    while (ii.next()) |ip| {
                        const idx = ip.*;
                        if (idx.tnum == root) {
                            c.z_name = idx.name;
                            c.z_type = "index";
                        }
                    }
                }
            }
            i += 20;
        }
    }
    switch (i) {
        // addr
        0 => api.resultInt(ctx, @intCast(c.i_addr)),
        // opcode
        1 => api.resultText(ctx, vi.opcodes.names[op.opcode].name, .static),
        2 => api.resultInt(ctx, op.p1),
        3 => api.resultInt(ctx, op.p2),
        4 => api.resultInt(ctx, op.p3),
        // p4 and comment
        5, 7 => {
            if (c.z_p4 == null) {
                c.z_p4 = aux.displayP4(t.db.gpa, op) catch return RC.NOMEM;
            }
            // The comment is NULL without SQLITE_ENABLE_EXPLAIN_COMMENTS.
            if (i == 5) api.resultText(ctx, c.z_p4.?, .static);
        },
        6 => api.resultInt(ctx, op.p5),
        // subprog
        8 => {
            std.debug.assert(a_op[0].opcode == OP.Init);
            if (c.i_rowid == @as(i32, @intCast(c.i_addr)) + 1) {
                // NULL for the main program.
            } else if (a_op[0].p4type == .z) {
                api.resultText(ctx, std.mem.span(a_op[0].p4.z + 3), .static);
            } else {
                api.resultText(ctx, "(FK)", .static);
            }
        },
        // nexec and ncycle, without SQLITE_ENABLE_STMT_SCANSTATUS.
        9, 10 => api.resultInt(ctx, 0),
        20 => api.resultText(ctx, c.z_type, .static),
        21 => api.resultText(ctx, c.z_schema, .static),
        22 => api.resultText(ctx, c.z_name, .static),
        23 => api.resultInt(ctx, @intFromBool(op.opcode == OP.OpenWrite)),
        else => {},
    }
    return RC.OK;
}

/// Port of bytecodevtabRowid().
fn bytecodevtabRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    rowid.* = BytecodeCursor.of(cur).i_rowid;
    return RC.OK;
}

/// Port of bytecodevtabFilter(): idx_num 0 lists the trigger programs
/// too, 1 only the main program.
fn bytecodevtabFilter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const c = BytecodeCursor.of(cur);
    const t = BytecodeVtab.of(cur.vtab);
    var rc: i32 = RC.OK;
    cursorClear(c, t.db);
    c.i_rowid = 0;
    c.i_addr = 0;
    c.show_subprograms = idx_num == 0;
    std.debug.assert(argv.len == 1);
    if (api.valueType(argv[0]) == vi.SQLITE_TEXT) {
        if (api.valueText(argv[0])) |sql| {
            rc = prepare.prepareV2(t.db, sql, &c.stmt, null);
            c.need_finalize = true;
        } else {
            rc = RC.NOMEM;
        }
    } else {
        c.stmt = @ptrCast(@alignCast(api.valuePointer(argv[0], "stmt-pointer")));
    }
    if (c.stmt == null) {
        vtab.setErrMsg(t.db, &t.base, "argument to {s}() is not a valid SQL statement", .{if (t.b_tables_used != 0) "tables_used" else "bytecode"});
        rc = RC.ERROR;
    } else {
        _ = bytecodevtabNext(cur);
    }
    return rc;
}

/// Port of bytecodevtabBestIndex(): a stmt=? constraint is required;
/// "subprog IS NULL" omits the trigger programs.
fn bytecodevtabBestIndex(p: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    var rc: i32 = RC.CONSTRAINT;
    const t = BytecodeVtab.of(p);
    const i_base_col: i32 = if (t.b_tables_used != 0) 4 else 10;
    info.estimated_cost = 100;
    info.estimated_rows = 100;
    info.idx_num = 0;
    for (info.constraints, 0..) |cons, i| {
        if (!cons.usable) continue;
        if (cons.op == vtab.INDEX_CONSTRAINT.EQ and cons.i_column == i_base_col + 1) {
            rc = RC.OK;
            info.usage[i].omit = true;
            info.usage[i].argv_index = 1;
        }
        if (cons.op == vtab.INDEX_CONSTRAINT.ISNULL and cons.i_column == i_base_col) {
            info.usage[i].omit = true;
            info.idx_num = 1;
        }
    }
    return rc;
}

/// The module of both functions (bytecodevtabModule).
const bytecodevtab_module: vtab.Module = .{
    .i_version = 0,
    .x_connect = bytecodevtabConnect,
    .x_best_index = bytecodevtabBestIndex,
    .x_disconnect = bytecodevtabDisconnect,
    .x_open = bytecodevtabOpen,
    .x_close = bytecodevtabClose,
    .x_filter = bytecodevtabFilter,
    .x_next = bytecodevtabNext,
    .x_eof = bytecodevtabEof,
    .x_column = bytecodevtabColumn,
    .x_rowid = bytecodevtabRowid,
};

/// Port of sqlite3VdbeBytecodeVtabInit(): register bytecode() and
/// tables_used() on `db`.
pub fn init(db: *Sqlite3) i32 {
    var rc = vtab.createModule(db, "bytecode", &bytecodevtab_module, null);
    if (rc == RC.OK) {
        // Any non-null pointer marks tables_used().
        rc = vtab.createModule(db, "tables_used", &bytecodevtab_module, @ptrCast(db));
    }
    return rc;
}
