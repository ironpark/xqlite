//! Building and running programs (port of the first half of vdbeaux.c):
//! adding instructions and labels, preparing a program to run, halting
//! with commit or rollback, and resetting and deleting statements.
//!
//! As in C, the instruction builders do not fail: running out of memory
//! sets `db.malloc_failed`, which the caller checks when the program is
//! complete.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const main_mod = @import("../sql/main.zig");
const btree = @import("../btree/btree.zig");
const opcodes = vi.opcodes;

const Vdbe = vi.Vdbe;
const Op = vi.Op;
const P4 = vi.P4;
const Mem = vi.Mem;
const MEM = vi.MEM;
const OP = vi.OP;
const VdbeCursor = vi.VdbeCursor;
const VdbeFrame = vi.VdbeFrame;
const Parse = int.Parse;
const Sqlite3 = int.Sqlite3;
const RC = int.RC;
const OE = int.OE;

/// Port of sqlite3VdbeCreate(): a new program for `p`, starting with
/// OP_Init.
pub fn create(p: *Parse) error{OutOfMemory}!*Vdbe {
    const db = p.db;
    const v = try db.gpa.create(Vdbe);
    v.* = .{ .db = db, .arena = std.heap.ArenaAllocator.init(db.gpa) };
    if (db.vdbe) |first| first.prev = v;
    v.next = db.vdbe;
    db.vdbe = v;
    v.parse = p;
    p.vdbe = v;
    std.debug.assert(p.labels.items.len == 0 and p.n_label == 0);
    _ = addOp2(v, OP.Init, 0, 1);
    return v;
}

/// Port of sqlite3VdbeError(): set the error message of `v`.
pub fn vdbeError(v: *Vdbe, comptime fmt: []const u8, args: anytype) void {
    v.err_msg = std.fmt.allocPrintSentinel(v.alloc(), fmt, args, 0) catch null;
}

/// Port of sqlite3VdbeSetSql().
pub fn setSql(v: *Vdbe, z: []const u8, prep_flags: u8) void {
    v.prep_flags = prep_flags;
    if (prep_flags & PREPARE_SAVESQL == 0) {
        v.expmask = 0;
        v.smimask = 0;
    }
    v.sql = v.alloc().dupeSentinel(u8, z, 0) catch null;
}

/// SQLITE_PREPARE_* flags.
pub const PREPARE_PERSISTENT: u8 = 0x01;
pub const PREPARE_NORMALIZE: u8 = 0x02;
pub const PREPARE_NO_VTAB: u8 = 0x04;
pub const PREPARE_DONT_LOG: u8 = 0x10;
pub const PREPARE_FROM_DDL: u8 = 0x20;
pub const PREPARE_SAVESQL: u8 = 0x80;
pub const PREPARE_MASK: u8 = 0x3f;

/// A placeholder returned by `getOp` after an allocation failure: readable
/// but never written.
var dummy_op: Op = .{ .opcode = 0 };

/// Port of sqlite3VdbeAddOp3(): append an instruction; returns its
/// address.
pub fn addOp3(v: *Vdbe, op: u8, p1: i32, p2: i32, p3: i32) i32 {
    std.debug.assert(v.e_vdbe_state == .init);
    const i = v.nOp();
    if (v.ops.items.len >= @as(usize, @intCast(v.db.limit(.vdbe_op)))) {
        v.db.malloc_failed = true;
        return i;
    }
    v.ops.append(v.alloc(), .{ .opcode = op, .p1 = p1, .p2 = p2, .p3 = p3 }) catch {
        v.db.malloc_failed = true;
    };
    return i;
}

pub fn addOp0(v: *Vdbe, op: u8) i32 {
    return addOp3(v, op, 0, 0, 0);
}

pub fn addOp1(v: *Vdbe, op: u8, p1: i32) i32 {
    return addOp3(v, op, p1, 0, 0);
}

pub fn addOp2(v: *Vdbe, op: u8, p1: i32, p2: i32) i32 {
    return addOp3(v, op, p1, p2, 0);
}

/// Port of sqlite3VdbeAddOp4Int(): P4 is a 32-bit integer.
pub fn addOp4Int(v: *Vdbe, op: u8, p1: i32, p2: i32, p3: i32, p4: i32) i32 {
    const addr = addOp3(v, op, p1, p2, p3);
    if (!v.db.malloc_failed) v.ops.items[@intCast(addr)].p4 = .{ .int32 = p4 };
    return addr;
}

/// Port of sqlite3VdbeAddOp4() with a pointer operand.
pub fn addOp4(v: *Vdbe, op: u8, p1: i32, p2: i32, p3: i32, p4: P4) i32 {
    const addr = addOp3(v, op, p1, p2, p3);
    changeP4(v, addr, p4);
    return addr;
}

/// Port of sqlite3VdbeAddOp4() with a string operand (P4_DYNAMIC): the
/// string is copied.
pub fn addOp4Str(v: *Vdbe, op: u8, p1: i32, p2: i32, p3: i32, z: ?[]const u8) i32 {
    const addr = addOp3(v, op, p1, p2, p3);
    changeP4Str(v, addr, z);
    return addr;
}

/// Port of sqlite3VdbeAddInt64(): OP_Int64 with the value in P1 and P3.
pub fn addInt64(v: *Vdbe, dest: i32, val: i64) i32 {
    const u: u64 = @bitCast(val);
    return addOp3(v, OP.Int64, @bitCast(@as(u32, @truncate(u))), dest, @bitCast(@as(u32, @truncate(u >> 32))));
}

/// Port of sqlite3VdbeAddDouble(): OP_Real with the bits in P1 and P3.
pub fn addDouble(v: *Vdbe, dest: i32, val: f64) i32 {
    const u: u64 = @bitCast(val);
    return addOp3(v, OP.Real, @bitCast(@as(u32, @truncate(u))), dest, @bitCast(@as(u32, @truncate(u >> 32))));
}

/// Port of sqlite3VdbeGoto().
pub fn goto_(v: *Vdbe, dest: i32) i32 {
    return addOp3(v, OP.Goto, 0, dest, 0);
}

/// Port of sqlite3VdbeLoadString().
pub fn loadString(v: *Vdbe, dest: i32, z: []const u8) i32 {
    return addOp4Str(v, OP.String8, 0, dest, 0, z);
}

/// One value of `multiLoad`.
pub const LoadValue = union(enum) { s: ?[]const u8, i: i32 };

/// Port of sqlite3VdbeMultiLoad(): load consecutive registers from `dest`
/// and, unless `no_result_row`, emit OP_ResultRow for them.
pub fn multiLoad(v: *Vdbe, dest: i32, values: []const LoadValue, no_result_row: bool) void {
    for (values, 0..) |val, i| {
        const reg = dest + @as(i32, @intCast(i));
        switch (val) {
            .s => |z| _ = if (z) |s| addOp4Str(v, OP.String8, 0, reg, 0, s) else addOp2(v, OP.Null, 0, reg),
            .i => |n| _ = addOp2(v, OP.Integer, n, reg),
        }
    }
    if (!no_result_row) _ = addOp2(v, OP.ResultRow, dest, @intCast(values.len));
}

/// NC_SelfRef: the call context bit kept in P5 of OP_PureFunc.
pub const NC_SelfRef: i32 = 0x00002e;

/// Port of sqlite3VdbeAddFunctionCall(): OP_Function, or OP_PureFunc when
/// `e_call_ctx` is set, with a context for `func`.
pub fn addFunctionCall(p: *Parse, p1: i32, p2: i32, p3: i32, n_arg: i32, func: *int.FuncDef, e_call_ctx: i32) i32 {
    const v = p.vdbe.?;
    const a = v.alloc();
    const ctx = a.create(vi.Context) catch {
        p.db.malloc_failed = true;
        return 0;
    };
    const argv = a.alloc(*vi.Mem, @intCast(n_arg)) catch {
        p.db.malloc_failed = true;
        return 0;
    };
    ctx.* = .{ .out = undefined, .func = func, .argc = @intCast(n_arg), .argv = argv, .i_op = currentAddr(v) };
    const addr = addOp4(v, if (e_call_ctx != 0) OP.PureFunc else OP.Function, p1, p2, p3, .{ .funcctx = ctx });
    changeP5(v, @intCast(e_call_ctx & NC_SelfRef));
    main_mod.mayAbort(p);
    return addr;
}

/// Port of sqlite3VdbeExplainParent(): the current EXPLAIN QUERY PLAN
/// node, or 0.
pub fn explainParent(p: *Parse) i32 {
    if (p.addr_explain == 0) return 0;
    return getOp(p.vdbe.?, p.addr_explain).p2;
}

/// Port of sqlite3VdbeExplain(): an OP_Explain line for EXPLAIN QUERY PLAN,
/// made the parent of later lines if `push`. Only when EXPLAIN QUERY PLAN
/// is running.
pub fn explain(p: *Parse, push: bool, comptime fmt: []const u8, args: anytype) i32 {
    if (p.explain != 2) return 0;
    const v = p.vdbe.?;
    const msg = std.fmt.allocPrintSentinel(v.alloc(), fmt, args, 0) catch {
        p.db.malloc_failed = true;
        return 0;
    };
    const this = v.nOp();
    const addr = addOp4(v, OP.Explain, this, p.addr_explain, 0, .{ .z = msg });
    if (push) p.addr_explain = this;
    return addr;
}

/// Port of sqlite3VdbeExplainPop().
pub fn explainPop(p: *Parse) void {
    p.addr_explain = explainParent(p);
}

/// Port of sqlite3VdbeAddParseSchemaOp(): reread the schema entries
/// matching `where` (all if null).
pub fn addParseSchemaOp(v: *Vdbe, i_db: i32, where: ?[]const u8, p5: u16) void {
    _ = addOp4Str(v, OP.ParseSchema, i_db, 0, 0, where);
    changeP5(v, p5);
    for (0..v.db.dbs.items.len) |j| usesBtree(v, @intCast(j));
    main_mod.mayAbort(v.parse.?);
}

/// Port of sqlite3VdbeEndCoroutine(): end a co-routine; it gets its own
/// temporary registers.
pub fn endCoroutine(v: *Vdbe, reg_yield: i32) void {
    _ = addOp1(v, OP.EndCoroutine, reg_yield);
    v.parse.?.n_temp_reg = 0;
    v.parse.?.n_range_reg = 0;
}

/// Port of sqlite3VdbeMakeLabel(): a new label, a negative number until
/// resolved.
pub fn makeLabel(p: *Parse) i32 {
    p.n_label -= 1;
    return p.n_label;
}

/// Port of sqlite3VdbeResolveLabel(): `label` is the address of the next
/// instruction.
pub fn resolveLabel(v: *Vdbe, label: i32) void {
    const p = v.parse.?;
    const j: usize = @intCast(~label);
    std.debug.assert(j < -p.n_label);
    while (p.labels.items.len <= j) {
        p.labels.append(p.arena, -1) catch {
            p.db.malloc_failed = true;
            return;
        };
    }
    std.debug.assert(p.labels.items[j] == -1);
    p.labels.items[j] = v.nOp();
}

/// Port of sqlite3VdbeRunOnlyOnce().
pub fn runOnlyOnce(v: *Vdbe) void {
    _ = addOp2(v, OP.Expire, 1, 1);
}

/// Port of sqlite3VdbeReusable(): undo `runOnlyOnce`.
pub fn reusable(v: *Vdbe) void {
    for (v.ops.items[1..]) |op| {
        if (op.opcode == OP.Expire) {
            v.ops.items[1].opcode = OP.Noop;
            break;
        }
    }
}

/// Port of resolveP2Values(): replace labels in jump operands by
/// addresses, and work out whether the program reads or writes.
fn resolveP2Values(v: *Vdbe, max_vtab_args: *i32) void {
    const p = v.parse.?;
    v.read_only = true;
    v.is_reader = false;
    var i = v.ops.items.len;
    while (i > 0) {
        i -= 1;
        const op = &v.ops.items[i];
        if (op.opcode > opcodes.max_jump_opcode) continue;
        switch (op.opcode) {
            OP.Transaction => {
                if (op.p2 != 0) v.read_only = false;
                v.is_reader = true;
            },
            OP.AutoCommit, OP.Savepoint => v.is_reader = true,
            OP.Checkpoint, OP.Vacuum, OP.JournalMode => {
                v.read_only = false;
                v.is_reader = true;
            },
            OP.Init => break,
            OP.VUpdate => max_vtab_args.* = @max(max_vtab_args.*, op.p2),
            else => {
                if (op.opcode == OP.VFilter) {
                    max_vtab_args.* = @max(max_vtab_args.*, v.ops.items[i - 1].p1);
                }
                if (op.p2 < 0) {
                    std.debug.assert(opcodes.properties[op.opcode] & opcodes.OPFLG.JUMP != 0);
                    op.p2 = p.labels.items[@intCast(~op.p2)];
                }
            },
        }
    }
    p.labels.clearRetainingCapacity();
    p.n_label = 0;
}

/// Port of sqlite3VdbeCurrentAddr(): the address of the next instruction.
pub fn currentAddr(v: *Vdbe) i32 {
    std.debug.assert(v.e_vdbe_state == .init);
    return v.nOp();
}

/// An entry of `addOpList` (VdbeOpList).
pub const OpListItem = struct { opcode: u8, p1: i8 = 0, p2: i8 = 0, p3: i8 = 0 };

/// Port of sqlite3VdbeAddOpList(): append instructions; nonzero jump
/// targets are relative to the first. Returns the first, or null.
pub fn addOpList(v: *Vdbe, items: []const OpListItem) ?[]Op {
    std.debug.assert(v.e_vdbe_state == .init);
    const first = v.ops.items.len;
    for (items) |item| {
        var p2: i32 = item.p2;
        if (opcodes.properties[item.opcode] & opcodes.OPFLG.JUMP != 0 and item.p2 > 0) p2 += @intCast(first);
        v.ops.append(v.alloc(), .{ .opcode = item.opcode, .p1 = item.p1, .p2 = p2, .p3 = item.p3 }) catch {
            v.db.malloc_failed = true;
            return null;
        };
    }
    return v.ops.items[first..];
}

/// Port of sqlite3VdbeReprepareOnBind() (without the smimask
/// refinement): the plan depends on the value bound to ?`i_var`.
pub fn reprepareOnBind(v: *Vdbe, i_var: i32) void {
    std.debug.assert(i_var > 0);
    v.expmask |= if (i_var >= 32) 0x80000000 else @as(u32, 1) << @intCast(i_var - 1);
}

pub fn changeOpcode(v: *Vdbe, addr: i32, opcode: u8) void {
    getOp(v, addr).opcode = opcode;
}

pub fn changeP1(v: *Vdbe, addr: i32, val: i32) void {
    getOp(v, addr).p1 = val;
}

pub fn changeP2(v: *Vdbe, addr: i32, val: i32) void {
    getOp(v, addr).p2 = val;
}

pub fn changeP3(v: *Vdbe, addr: i32, val: i32) void {
    getOp(v, addr).p3 = val;
}

/// Port of sqlite3VdbeChangeP5(): P5 of the last instruction.
pub fn changeP5(v: *Vdbe, p5: u16) void {
    if (v.ops.items.len > 0) v.ops.items[v.ops.items.len - 1].p5 = p5;
}

/// OPFLAG_TYPEOFARG: OP_Column only needs the type.
pub const OPFLAG_TYPEOFARG: u16 = 0x80;

/// Port of sqlite3VdbeTypeofColumn().
pub fn typeofColumn(v: *Vdbe, dest: i32) void {
    const op = getLastOp(v);
    if (op.p3 == dest and op.opcode == OP.Column) op.p5 |= OPFLAG_TYPEOFARG;
}

/// Port of sqlite3VdbeJumpHere(): make the jump at `addr` land on the
/// next instruction.
pub fn jumpHere(v: *Vdbe, addr: i32) void {
    changeP2(v, addr, v.nOp());
}

/// Port of sqlite3VdbeJumpHereOrPopInst(): like `jumpHere`, but drop the
/// jump if it was the last instruction.
pub fn jumpHereOrPopInst(v: *Vdbe, addr: i32) void {
    if (addr == v.nOp() - 1) {
        std.debug.assert(v.ops.items[@intCast(addr)].opcode == OP.Once or
            v.ops.items[@intCast(addr)].opcode == OP.If or
            v.ops.items[@intCast(addr)].opcode == OP.FkIfZero);
        v.ops.items.len -= 1;
    } else {
        changeP2(v, addr, v.nOp());
    }
}

/// Port of sqlite3VdbeTakeOpArray(): the finished instructions of `v` go
/// to `program`, with the arena that holds them and their operands.
pub fn takeProgram(v: *Vdbe, program: *vi.SubProgram, max_arg: *i32) void {
    resolveP2Values(v, max_arg);
    program.ops = v.ops.items;
    v.ops = .empty;
    program.mem = v.arena;
    v.arena = .init(v.db.gpa);
}

/// Port of sqlite3VdbeHasSubProgram().
pub fn hasSubProgram(v: *const Vdbe) bool {
    return v.program != null;
}

/// Port of sqlite3VdbeLinkSubProgram().
pub fn linkSubProgram(v: *Vdbe, sub: *vi.SubProgram) void {
    sub.next = v.program;
    v.program = sub;
}

/// Port of sqlite3VdbeChangeToNoop().
pub fn changeToNoop(v: *Vdbe, addr: i32) bool {
    if (v.db.malloc_failed) return false;
    const op = &v.ops.items[@intCast(addr)];
    op.p4 = .notused;
    op.opcode = OP.Noop;
    return true;
}

/// Port of sqlite3VdbeDeletePriorOpcode(): drop the last instruction if
/// it is `op`.
pub fn deletePriorOpcode(v: *Vdbe, op: u8) bool {
    const n = v.ops.items.len;
    if (n > 0 and v.ops.items[n - 1].opcode == op) return changeToNoop(v, @intCast(n - 1));
    return false;
}

/// Port of sqlite3VdbeChangeP4() for pointer operands; `addr` -1 means
/// the last instruction.
pub fn changeP4(v: *Vdbe, addr_arg: i32, p4: P4) void {
    if (v.db.malloc_failed) return;
    const addr = if (addr_arg < 0) v.nOp() - 1 else addr_arg;
    v.ops.items[@intCast(addr)].p4 = p4;
}

/// Port of sqlite3VdbeChangeP4() with a string (copied, P4_DYNAMIC).
pub fn changeP4Str(v: *Vdbe, addr: i32, z: ?[]const u8) void {
    const s = z orelse return;
    if (v.db.malloc_failed) return;
    const copy = v.alloc().dupeSentinel(u8, s, 0) catch {
        v.db.malloc_failed = true;
        return;
    };
    changeP4(v, addr, .{ .z = copy });
}

/// Port of sqlite3VdbeSetP4KeyInfo(): P4 of the last instruction is the
/// KeyInfo of `idx`.
pub fn setP4KeyInfo(p: *Parse, idx: *int.Index) void {
    const v = p.vdbe.?;
    if (@import("../sql/build.zig").keyInfoOfIndex(p, idx)) |k| appendP4(v, .{ .keyinfo = k });
}

/// Port of sqlite3VdbeAppendP4(): P4 of the last instruction, which has
/// none yet.
pub fn appendP4(v: *Vdbe, p4: P4) void {
    if (v.db.malloc_failed) return;
    const op = &v.ops.items[v.ops.items.len - 1];
    std.debug.assert(op.p4 == .notused);
    op.p4 = p4;
}

/// Port of sqlite3VdbeComment(): only kept with
/// SQLITE_ENABLE_EXPLAIN_COMMENTS, which this port does not enable.
pub fn comment(v: *Vdbe, comptime fmt: []const u8, args: anytype) void {
    _ = .{ v, fmt, args };
}

/// Port of sqlite3VdbeNoopComment().
pub fn noopComment(v: *Vdbe, comptime fmt: []const u8, args: anytype) void {
    _ = .{ v, fmt, args };
}

/// Port of sqlite3VdbeGetOp().
pub fn getOp(v: *Vdbe, addr: i32) *Op {
    std.debug.assert(v.e_vdbe_state == .init);
    if (v.db.malloc_failed) {
        dummy_op = .{ .opcode = 0 };
        return &dummy_op;
    }
    return &v.ops.items[@intCast(addr)];
}

/// Port of sqlite3VdbeGetLastOp().
pub fn getLastOp(v: *Vdbe) *Op {
    return getOp(v, v.nOp() - 1);
}

/// Port of sqlite3VdbeDisplayP4(): the P4 column of EXPLAIN.
pub fn displayP4(a: std.mem.Allocator, op: *const Op) error{OutOfMemory}![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    (switch (op.p4) {
        .keyinfo => |ki| blk: {
            w.print("k({d}", .{ki.n_key_field}) catch break :blk error.WriteFailed;
            for (0..ki.n_key_field) |j| {
                var coll: []const u8 = if (ki.coll[j]) |c| c.name else "";
                if (std.mem.eql(u8, coll, "BINARY")) coll = "B";
                w.print(",{s}{s}{s}", .{
                    if (ki.sort_flags[j] & int.KeyInfoOrder.desc != 0) "-" else "",
                    if (ki.sort_flags[j] & int.KeyInfoOrder.bignull != 0) "N." else "",
                    coll,
                }) catch break :blk error.WriteFailed;
            }
            break :blk w.writeAll(")");
        },
        .collseq => |c| blk: {
            const encnames = [_][]const u8{ "?", "8", "16LE", "16BE" };
            break :blk w.print("{s}-{s}", .{ c.name[0..@min(c.name.len, 18)], encnames[c.enc] });
        },
        .funcdef => |f| w.print("{s}({d})", .{ f.name, f.n_arg }),
        .funcctx => |ctx| w.print("{s}({d})", .{ ctx.func.name, ctx.func.n_arg }),
        .int32 => |i| w.print("{d}", .{i}),
        .mem => |m| blk: {
            if (m.flags & MEM.Str != 0) break :blk w.writeAll(m.bytes());
            if (m.flags & (MEM.Int | MEM.IntReal) != 0) break :blk w.print("{d}", .{m.u.i});
            if (m.flags & MEM.Real != 0) {
                const printf = @import("../sql/printf.zig");
                const s = printf.mprintf(a, "%.16g", &.{.{ .double = m.u.r }}) catch break :blk error.WriteFailed;
                defer a.free(s);
                break :blk w.writeAll(s);
            }
            if (m.flags & MEM.Null != 0) break :blk w.writeAll("NULL");
            break :blk w.writeAll("(blob)");
        },
        .intarray => |ai| blk: {
            const n = ai[0];
            for (1..n + 1) |i| w.print("{c}{d}", .{ @as(u8, if (i == 1) '[' else ','), ai[i] }) catch break :blk error.WriteFailed;
            break :blk w.writeAll("]");
        },
        .subprogram => w.writeAll("program"),
        .table, .tableref => |t| w.writeAll(t.name),
        .index => |idx| w.writeAll(idx.name),
        .subrtnsig => |s| w.print("subrtnsig:{d},{s}", .{ s.sel_id, s.aff orelse "" }),
        .z => |z| w.writeAll(z),
        .notused => {},
    }) catch return error.OutOfMemory;
    return out.toOwnedSliceSentinel(0) catch error.OutOfMemory;
}

/// Port of sqlite3VdbeUsesBtree(): the program uses database `i`.
pub fn usesBtree(v: *Vdbe, i: u5) void {
    v.btree_mask |= @as(u32, 1) << i;
}

/// Port of initMemArray().
pub fn initMemArray(cells: []Mem, db: *Sqlite3, flags: u16) void {
    for (cells) |*m| m.* = .{ .flags = flags, .db = db };
}

/// Port of releaseMemArray(): free what the cells hold; freed cells
/// become MEM_Undefined.
pub fn releaseMemArray(cells: []Mem) void {
    for (cells) |*m| {
        if (m.flags & (MEM.Agg | MEM.Dyn) != 0) {
            mem.release(m);
            m.flags = MEM.Undefined;
        } else if (m.z_malloc.len > 0) {
            m.db.?.gpa.free(m.z_malloc);
            m.z_malloc = &.{};
            m.flags = MEM.Undefined;
        }
    }
}

/// Port of sqlite3VdbeNextOpcode() for the main program (trigger
/// programs are not listed yet): the next instruction to show for EXPLAIN
/// (`eqp` false) or EXPLAIN QUERY PLAN. Returns null when done.
fn nextOpcode(v: *Vdbe, eqp: bool) ?usize {
    while (true) {
        const i: usize = @intCast(v.pc);
        v.pc += 1;
        if (i >= v.ops.items.len) {
            v.rc = RC.OK;
            return null;
        }
        if (!eqp) return i;
        const op = v.ops.items[i].opcode;
        if (op == OP.Explain) return i;
        if (op == OP.Init and v.pc > 1) return i;
    }
}

/// Port of sqlite3VdbeList(): the next row of EXPLAIN or EXPLAIN QUERY
/// PLAN. Returns RC.ROW, RC.DONE or RC.ERROR.
pub fn list(v: *Vdbe) i32 {
    const db = v.db;
    std.debug.assert(v.explain != 0 and v.e_vdbe_state == .run);
    const cells = v.mem[1..9];
    releaseMemArray(cells);
    if (v.rc == RC.NOMEM) {
        db.malloc_failed = true;
        return RC.ERROR;
    }
    const i = nextOpcode(v, v.explain == 2) orelse return RC.DONE;
    const op = &v.ops.items[i];
    if (db.is_interrupted.load(.monotonic)) {
        v.rc = RC.INTERRUPT;
        vdbeError(v, "{s}", .{util.errStr(v.rc)});
        return RC.ERROR;
    }
    const p4 = displayP4(db.gpa, op) catch {
        v.rc = RC.NOMEM;
        return RC.ERROR;
    };
    if (v.explain == 2) {
        mem.setInt64(&cells[0], op.p1);
        mem.setInt64(&cells[1], op.p2);
        mem.setInt64(&cells[2], op.p3);
        mem.setTextZ(&cells[3], p4, .dynamic) catch {};
    } else {
        mem.setInt64(&cells[0], @intCast(i));
        mem.setTextZ(&cells[1], @ptrCast(opcodes.names[op.opcode].name), .static) catch {};
        mem.setInt64(&cells[2], op.p1);
        mem.setInt64(&cells[3], op.p2);
        mem.setInt64(&cells[4], op.p3);
        mem.setInt64(&cells[6], op.p5);
        mem.setNull(&cells[7]);
        mem.setTextZ(&cells[5], p4, .dynamic) catch {};
    }
    v.result_row = cells.ptr;
    v.rc = RC.OK;
    return RC.ROW;
}

/// Port of sqlite3VdbeRewind(): back to the start, ready to run again.
pub fn rewind(v: *Vdbe) void {
    std.debug.assert(v.e_vdbe_state == .init or v.e_vdbe_state == .ready or v.e_vdbe_state == .halt);
    std.debug.assert(v.ops.items.len > 0);
    v.e_vdbe_state = .ready;
    v.pc = -1;
    v.rc = RC.OK;
    v.error_action = OE.Abort;
    v.n_change = 0;
    v.cache_ctr = 1;
    v.min_write_file_format = 255;
    v.i_statement = 0;
    v.n_fk_constraint = 0;
}

/// Port of sqlite3VdbeMakeReady(): resolve labels and allocate registers,
/// parameters and cursors. The program can no longer be changed.
pub fn makeReady(v: *Vdbe, p: *Parse) void {
    std.debug.assert(v.e_vdbe_state == .init and p == v.parse.?);
    const db = v.db;
    const a = v.alloc();
    v.vlist = copyVList(a, p.vlist.items) catch return oom(v);
    const n_var: usize = @intCast(p.n_var);
    var n_mem: usize = @intCast(p.n_mem);
    const n_cursor: usize = @intCast(p.n_tab);
    var n_arg = p.n_max_arg;
    // Registers are numbered from 1; mem[0] is unused.
    n_mem += 1;
    resolveP2Values(v, &n_arg);
    v.uses_stmt_journal = p.is_multi_write and p.may_abort;
    if (p.explain != 0) {
        if (n_mem < 10) n_mem = 10;
        v.explain = @intCast(p.explain);
        v.n_res_column = 12 - 4 * @as(u16, p.explain);
    }
    v.expired = 0;
    v.mem = a.alloc(Mem, n_mem) catch return oom(v);
    v.vars = a.alloc(Mem, n_var) catch return oom(v);
    v.csr = a.alloc(?*VdbeCursor, n_cursor) catch return oom(v);
    v.n_var = @intCast(n_var);
    initMemArray(v.vars, db, MEM.Null);
    initMemArray(v.mem, db, MEM.Undefined);
    @memset(v.csr, null);
    rewind(v);
}

/// Copy the variable names into the program, which outlives the Parse.
fn copyVList(a: std.mem.Allocator, src: []const int.VListEntry) error{OutOfMemory}![]const int.VListEntry {
    const out = try a.alloc(int.VListEntry, src.len);
    for (src, out) |e, *o| o.* = .{ .name = try a.dupe(u8, e.name), .num = e.num };
    return out;
}

fn oom(v: *Vdbe) void {
    v.db.malloc_failed = true;
    v.mem = &.{};
    v.vars = &.{};
    v.csr = &.{};
    v.n_var = 0;
}

/// Port of sqlite3VdbeFreeCursor().
pub fn freeCursor(v: *Vdbe, cx: ?*VdbeCursor) void {
    if (cx) |c| freeCursorNN(v, c);
}

/// Port of sqlite3VdbeFreeCursorNN(): close the cursor's b-tree cursor or
/// sorter and free the cursor.
pub fn freeCursorNN(v: *Vdbe, cx: *VdbeCursor) void {
    switch (cx.uc) {
        .sorter => @import("sorter.zig").close(v.db, cx),
        .cursor => |c| c.close(),
        else => {},
    }
    const box: *vi.CursorBox = @fieldParentPtr("vc", cx);
    v.db.gpa.free(cx.types.ptr[0 .. cx.types.len + cx.offsets.len]);
    v.db.gpa.destroy(box);
}

/// Port of closeCursorsInFrame().
fn closeCursorsInFrame(v: *Vdbe) void {
    for (v.csr) |*slot| {
        if (slot.*) |c| {
            freeCursorNN(v, c);
            slot.* = null;
        }
    }
}

/// Port of sqlite3VdbeFrameRestore(): return from a trigger program to its
/// caller. Returns the caller's program counter.
pub fn frameRestore(frame: *VdbeFrame) i32 {
    const v = frame.v;
    closeCursorsInFrame(v);
    v.ops.items = frame.ops;
    v.mem = frame.mem;
    v.csr = frame.csr;
    v.db.last_rowid = frame.last_rowid;
    v.n_change = frame.n_change;
    v.db.n_change = frame.n_db_change;
    deleteAuxData(v.db, &v.aux_data, -1, 0);
    v.aux_data = frame.aux_data;
    frame.aux_data = null;
    return frame.pc;
}

/// Port of sqlite3VdbeFrameDelete().
pub fn frameDelete(frame: *VdbeFrame) void {
    for (frame.child_csr) |c| if (c) |cur| freeCursorNN(frame.v, cur);
    releaseMemArray(frame.child_mem);
    deleteAuxData(frame.v.db, &frame.aux_data, -1, 0);
    const gpa = frame.v.db.gpa;
    gpa.free(frame.child_mem);
    gpa.free(frame.child_csr);
    gpa.free(frame.once);
    gpa.destroy(frame);
}

/// Port of closeAllCursors(): close every cursor and free what the
/// registers hold.
fn closeAllCursors(v: *Vdbe) void {
    if (v.frame) |f| {
        _ = frameRestore(vi.rootFrame(f));
        v.frame = null;
        v.n_frame = 0;
    }
    closeCursorsInFrame(v);
    releaseMemArray(v.mem);
    while (v.del_frame) |del| {
        v.del_frame = del.parent;
        frameDelete(del);
    }
    if (v.aux_data != null) deleteAuxData(v.db, &v.aux_data, -1, 0);
}

/// Port of sqlite3VdbeSetNumCols().
pub fn setNumCols(v: *Vdbe, n: u16) void {
    if (v.n_res_alloc != 0) releaseMemArray(v.col_names);
    v.n_res_column = n;
    v.n_res_alloc = n;
    v.col_names = v.alloc().alloc(Mem, @as(usize, n) * vi.COLNAME_N) catch {
        v.db.malloc_failed = true;
        v.col_names = &.{};
        return;
    };
    initMemArray(v.col_names, v.db, MEM.Null);
}

/// Port of sqlite3VdbeSetColName(): name `var` (COLNAME_*) of column
/// `idx`. The name is copied.
pub fn setColName(v: *Vdbe, idx: usize, var_: usize, name: [:0]const u8) void {
    if (v.db.malloc_failed) return;
    const m = &v.col_names[idx + var_ * v.n_res_alloc];
    mem.setTextZ(m, name, .transient) catch {
        v.db.malloc_failed = true;
    };
}

/// Port of vdbeCommit(): commit the open transactions. Only one database
/// file can be written (no ATTACH yet), so no super-journal is needed.
fn vdbeCommit(db: *Sqlite3) i32 {
    var need_xcommit = false;
    for (db.dbs.items) |d| {
        const bt = d.bt orelse continue;
        if (bt.txnState() == .write) need_xcommit = true;
    }
    if (need_xcommit) {
        for (db.dbs.items) |d| {
            const bt = d.bt orelse continue;
            if (bt.txnState() == .write) bt.commitPhaseOne() catch |err| return main_mod.errorCode(err);
        }
    }
    for (db.dbs.items) |d| {
        const bt = d.bt orelse continue;
        if (bt.txnState() != .none) bt.commitPhaseTwo(false) catch |err| return main_mod.errorCode(err);
    }
    return RC.OK;
}

/// sqlite3VdbeError(p, "%s", sqlite3_value_text(m)): the error message
/// a function left in `m`.
pub fn vdbeErrorFromMem(v: *Vdbe, m: *Mem) void {
    const z = mem.valueText(m, vi.ENC.UTF8) catch {
        v.db.malloc_failed = true;
        return;
    };
    vdbeError(v, "{s}", .{if (z != null) m.bytes() else ""});
}

/// SAVEPOINT_* operations.
pub const SAVEPOINT_BEGIN = 0;
pub const SAVEPOINT_RELEASE = 1;
pub const SAVEPOINT_ROLLBACK = 2;

/// Port of sqlite3VdbeCloseStatement(). Statement transactions are not
/// ported yet, so there is never one to close.
pub fn closeStatement(v: *Vdbe, e_op: i32) i32 {
    if (v.db.n_statement != 0 and v.i_statement != 0) return closeStatementImpl(v, e_op);
    return RC.OK;
}

/// Port of vdbeCloseStatement(): release statement transaction
/// i_statement, first rolling it back for SAVEPOINT_ROLLBACK.
fn closeStatementImpl(v: *Vdbe, e_op: i32) i32 {
    const db = v.db;
    var rc: i32 = RC.OK;
    const i_savepoint = v.i_statement - 1;
    for (db.dbs.items) |d| {
        const bt = d.bt orelse continue;
        var rc2: i32 = RC.OK;
        if (e_op == SAVEPOINT_ROLLBACK) {
            bt.savepoint(.rollback, i_savepoint) catch |err| {
                rc2 = main_mod.errorCode(err);
            };
        }
        if (rc2 == RC.OK) {
            bt.savepoint(.release, i_savepoint) catch |err| {
                rc2 = main_mod.errorCode(err);
            };
        }
        if (rc == RC.OK) rc = rc2;
    }
    db.n_statement -= 1;
    v.i_statement = 0;
    if (e_op == SAVEPOINT_ROLLBACK) {
        db.n_deferred_cons = v.n_stmt_def_cons;
        db.n_deferred_imm_cons = v.n_stmt_def_imm_cons;
    }
    return rc;
}

/// Port of sqlite3VdbeCheckFkImmediate().
pub fn checkFkImmediate(v: *Vdbe) i32 {
    if (v.n_fk_constraint == 0) return RC.OK;
    return fkError(v);
}

/// Port of sqlite3VdbeCheckFkDeferred().
pub fn checkFkDeferred(v: *Vdbe) i32 {
    const db = v.db;
    if (db.n_deferred_cons + db.n_deferred_imm_cons == 0) return RC.OK;
    return fkError(v);
}

/// SQLITE_CONSTRAINT_FOREIGNKEY.
pub const CONSTRAINT_FOREIGNKEY: i32 = RC.CONSTRAINT | (3 << 8);

fn fkError(v: *Vdbe) i32 {
    v.rc = CONSTRAINT_FOREIGNKEY;
    v.error_action = OE.Abort;
    vdbeError(v, "FOREIGN KEY constraint failed", .{});
    if (v.prep_flags & PREPARE_SAVESQL == 0) return RC.ERROR;
    return CONSTRAINT_FOREIGNKEY;
}


/// Port of sqlite3VdbeHalt(): the program stops. In autocommit mode the
/// transaction is committed (or rolled back on error); otherwise the
/// statement transaction is released or rolled back. Returns BUSY if the
/// commit must be retried.
pub fn halt(v: *Vdbe) i32 {
    const db = v.db;
    std.debug.assert(v.e_vdbe_state == .run);
    if (db.malloc_failed) v.rc = RC.NOMEM;
    closeAllCursors(v);

    if (v.is_reader) {
        var e_statement_op: i32 = 0;
        var is_special_error = false;
        var mrc: i32 = 0;
        if (v.rc != 0) {
            mrc = v.rc & 0xff;
            is_special_error = mrc == RC.NOMEM or mrc == RC.IOERR or mrc == RC.INTERRUPT or mrc == RC.FULL;
        }
        if (is_special_error) {
            // A rollback restores a consistent state, even if read-only.
            if (!v.read_only or mrc != RC.INTERRUPT) {
                if ((mrc == RC.NOMEM or mrc == RC.FULL) and v.uses_stmt_journal) {
                    e_statement_op = SAVEPOINT_ROLLBACK;
                } else {
                    main_mod.rollbackAll(db, RC.ABORT_ROLLBACK);
                    main_mod.closeSavepoints(db);
                    db.auto_commit = true;
                    v.n_change = 0;
                }
            }
        }

        if (v.rc == RC.OK or (v.error_action == OE.Fail and !is_special_error)) {
            _ = checkFkImmediate(v);
        }

        if (db.auto_commit and db.n_vdbe_write == @intFromBool(!v.read_only)) {
            if (v.rc == RC.OK or (v.error_action == OE.Fail and !is_special_error)) {
                var rc = checkFkDeferred(v);
                if (rc != RC.OK) {
                    if (v.read_only) return RC.ERROR;
                    rc = CONSTRAINT_FOREIGNKEY;
                } else if (db.flags & int.DbFlag.CorruptRdOnly != 0) {
                    rc = RC.CORRUPT;
                    db.flags &= ~int.DbFlag.CorruptRdOnly;
                } else {
                    rc = vdbeCommit(db);
                }
                if (rc == RC.BUSY and v.read_only) {
                    return RC.BUSY;
                } else if (rc != RC.OK) {
                    v.rc = rc;
                    main_mod.rollbackAll(db, RC.OK);
                    v.n_change = 0;
                } else {
                    db.n_deferred_cons = 0;
                    db.n_deferred_imm_cons = 0;
                    db.flags &= ~int.DbFlag.DeferFKs;
                    main_mod.commitInternalChanges(db);
                }
            } else if (v.rc == RC.SCHEMA and db.n_vdbe_active > 1) {
                v.n_change = 0;
            } else {
                main_mod.rollbackAll(db, RC.OK);
                v.n_change = 0;
            }
            db.n_statement = 0;
        } else if (e_statement_op == 0) {
            if (v.rc == RC.OK or v.error_action == OE.Fail) {
                e_statement_op = SAVEPOINT_RELEASE;
            } else if (v.error_action == OE.Abort) {
                e_statement_op = SAVEPOINT_ROLLBACK;
            } else {
                main_mod.rollbackAll(db, RC.ABORT_ROLLBACK);
                main_mod.closeSavepoints(db);
                db.auto_commit = true;
                v.n_change = 0;
            }
        }

        if (e_statement_op != 0) {
            const rc = closeStatement(v, e_statement_op);
            if (rc != 0) {
                if (v.rc == RC.OK or v.rc & 0xff == RC.CONSTRAINT) {
                    v.rc = rc;
                    v.err_msg = null;
                }
                main_mod.rollbackAll(db, RC.ABORT_ROLLBACK);
                main_mod.closeSavepoints(db);
                db.auto_commit = true;
                v.n_change = 0;
            }
        }

        if (v.change_cnt_on) {
            setChanges(db, if (e_statement_op != SAVEPOINT_ROLLBACK) v.n_change else 0);
            v.n_change = 0;
        }
    }

    db.n_vdbe_active -= 1;
    if (!v.read_only) db.n_vdbe_write -= 1;
    if (v.is_reader) db.n_vdbe_read -= 1;
    v.e_vdbe_state = .halt;
    if (db.malloc_failed) v.rc = RC.NOMEM;
    return if (v.rc == RC.BUSY) RC.BUSY else RC.OK;
}

/// Port of sqlite3VdbeSwap(): exchange the programs of two statements,
/// keeping each in its place in the connection's list. Used by
/// sqlite3Reprepare(): `a` is the new statement, `b` the old one.
pub fn swap(a: *Vdbe, b: *Vdbe) void {
    std.mem.swap(Vdbe, a, b);
    std.mem.swap(?*Vdbe, &a.next, &b.next);
    std.mem.swap(?*Vdbe, &a.prev, &b.prev);
    b.expmask = a.expmask;
    b.prep_flags = a.prep_flags;
    b.counters = a.counters;
    b.counters[vi.STMTSTATUS.REPREPARE] += 1;
}

/// Port of sqlite3TransferBindings(): move the parameter values of `from`
/// to `to`.
pub fn transferBindings(from: *Vdbe, to: *Vdbe) void {
    std.debug.assert(to.n_var == from.n_var);
    for (from.vars, to.vars) |*f, *t| mem.move(t, f);
}

/// Port of sqlite3VdbeResetStepResult().
pub fn resetStepResult(v: *Vdbe) void {
    v.rc = RC.OK;
}

/// Port of sqlite3VdbeTransferError(): copy the error of `v` to the
/// connection.
pub fn transferError(v: *Vdbe) i32 {
    const db = v.db;
    const rc = v.rc;
    main_mod.setErrorMessage(db, v.err_msg);
    db.err_code = rc;
    db.err_byte_offset = -1;
    return rc;
}

/// Port of sqlite3VdbeReset(): halt if running, report the result to the
/// connection, and be ready to run again. Returns the result code.
pub fn reset(v: *Vdbe) i32 {
    const db = v.db;
    if (v.e_vdbe_state == .run) _ = halt(v);
    if (v.pc >= 0) {
        if (db.err != null or v.err_msg != null) {
            _ = transferError(v);
        } else {
            db.err_code = v.rc;
        }
    }
    v.err_msg = null;
    v.result_row = null;
    return v.rc & db.err_mask;
}

/// Port of sqlite3VdbeFinalize().
pub fn finalize(v: *Vdbe) i32 {
    var rc: i32 = RC.OK;
    if (@intFromEnum(v.e_vdbe_state) >= @intFromEnum(vi.VdbeState.ready)) rc = reset(v);
    delete(v);
    return rc;
}

/// Port of sqlite3VdbeDeleteAuxData(): run the destructors of auxiliary
/// data: all of it if `i_op` < 0, else that of the OP_Function at `i_op`
/// for arguments not in `mask`.
pub fn deleteAuxData(db: *Sqlite3, pp_arg: *?*vi.AuxData, i_op: i32, mask: u32) void {
    var pp = pp_arg;
    while (pp.*) |aux| {
        if (i_op < 0 or (aux.i_aux_op == i_op and aux.i_aux_arg >= 0 and
            (aux.i_aux_arg > 31 or mask & (@as(u32, 1) << @intCast(aux.i_aux_arg)) == 0)))
        {
            if (aux.x_delete_aux) |del| del(aux.aux);
            pp.* = aux.next_aux;
            db.gpa.destroy(aux);
        } else {
            pp = &aux.next_aux;
        }
    }
}

/// Port of sqlite3VdbeDelete(): free the statement.
pub fn delete(v: *Vdbe) void {
    const db = v.db;
    if (v.col_names.len > 0) releaseMemArray(v.col_names);
    if (v.e_vdbe_state != .init) releaseMemArray(v.vars);
    if (v.prev) |prev| {
        prev.next = v.next;
    } else {
        db.vdbe = v.next;
    }
    if (v.next) |next| next.prev = v.prev;
    // The values of P4_MEM operands (column defaults) may own buffers.
    releaseP4Mems(v.ops.items);
    var sub = v.program;
    while (sub) |s| {
        sub = s.next;
        releaseP4Mems(s.ops);
        if (s.mem) |*m| m.deinit();
    }
    v.arena.deinit();
    db.gpa.destroy(v);
}

/// The part of freeP4() for P4_MEM: release the values of `ops`.
fn releaseP4Mems(ops: []Op) void {
    for (ops) |*op| if (op.p4 == .mem) mem.release(op.p4.mem);
}

/// Port of sqlite3VdbeSetChanges().
pub fn setChanges(db: *Sqlite3, n: i64) void {
    db.n_change = n;
    db.n_total_change += n;
}

/// Port of sqlite3VdbeCountChanges().
pub fn countChanges(v: *Vdbe) void {
    v.change_cnt_on = true;
}

/// Port of sqlite3ExpirePreparedStatements(): make statements reprepare
/// (`code` 1) or recompile when convenient (2).
pub fn expirePreparedStatements(db: *Sqlite3, code: u2) void {
    var it = db.vdbe;
    while (it) |v| : (it = v.next) v.expired = code + 1;
}
