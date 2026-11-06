//! pg_input_is_valid(text, type) and pg_input_error_info(text, type):
//! whether a string is valid input of a type, and the error its input
//! would raise, without raising it.
//!
//! The type is read as a type name of the dialect ('int4', 'numeric(7,4)',
//! 'varchar(4)'); a type there is not is the error ("type "x" does not
//! exist"). The string goes through what a cast to the type calls
//! (types.castPlan(): xq_pg_int4(), xq_dec(), xq_pg_iv(), xq_pg_uuid()
//! ...), in a call of its own whose error is caught, so each type's
//! messages and SQLSTATEs are its input's; numeric(p, s) adds the DETAIL
//! of apply_typmod(). The types whose cast is SQLite's own are read here:
//! real and double precision (float4in(), float8in(): builtins.zig),
//! bytea (byteain()'s hex and escape formats), varchar(n) and char(n)
//! (too long unless the excess is spaces), int2vector and oidvector
//! (integers separated by spaces, integer.zig). Other types (text, name
//! ...) take any string. The type is resolved once per statement.
//!
//! pg_input_error_info() in FROM is the parser's json_each() of
//! xq_pg_rows_input_error(), one row [message, detail, hint,
//! sql_error_code] (NULLs for valid input).

const std = @import("std");
const dfunc = @import("../func.zig");
const api = @import("../../vdbe/api.zig");
const vi = @import("../../vdbe/vdbe_int.zig");
const mem = @import("../../vdbe/mem.zig");
const int = @import("../../sql/sqlite_int.zig");
const callback = @import("../../sql/callback.zig");
const util = @import("../../sql/util.zig");
const types = @import("types.zig");
const decimal_sql = @import("../decimal_sql.zig");
const json_text = @import("json").text;
const json = @import("json.zig");
const integer = @import("integer.zig");
const builtins = @import("builtins.zig");

const Context = dfunc.Context;
const Mem = dfunc.Mem;
const Allocator = std.mem.Allocator;

const det: dfunc.Options = .{ .deterministic = true };

pub const functions = [_]int.FuncDef{
    dfunc.scalar("pg_input_is_valid", 2, det, dfunc.bind(inputFunc, .{false})),
};

pub const engine_functions = [_]int.FuncDef{
    dfunc.scalar("xq_pg_rows_input_error", 2, det, dfunc.bind(inputFunc, .{true})),
};

/// The error of an input: PostgreSQL's message, DETAIL and SQLSTATE.
const Info = struct {
    msg: []const u8,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    state: [5]u8,
};

const Fail = error{ OutOfMemory, Reported };

fn inputFunc(ctx: *Context, argv: []*Mem, comptime rows: bool) void {
    if (dfunc.anyNull(argv)) return api.resultNull(ctx);
    var arena: std.heap.ArenaAllocator = .init(dfunc.gpa(ctx));
    defer arena.deinit();
    const a = arena.allocator();
    const value = dfunc.text(ctx, argv[0]) orelse return;
    const type_text = dfunc.text(ctx, argv[1]) orelse return;
    const info = run(ctx, a, value, type_text) catch |err| switch (err) {
        error.OutOfMemory => return api.resultErrorNomem(ctx),
        error.Reported => return,
    };
    if (!rows) return api.resultInt64(ctx, @intFromBool(info == null));
    var out: std.ArrayList(u8) = .empty;
    rowJson(a, &out, info) catch return api.resultErrorNomem(ctx);
    api.resultText(ctx, out.items, .transient);
}

/// [[message, detail, hint, sql_error_code]] as JSON.
fn rowJson(a: Allocator, out: *std.ArrayList(u8), info: ?Info) Allocator.Error!void {
    const i = info orelse return out.appendSlice(a, "[[null,null,null,null]]");
    const str = json_text.appendQuoted;
    try out.appendSlice(a, "[[");
    try str(.{}, a, out, i.msg);
    try out.append(a, ',');
    if (i.detail) |d| try str(.{}, a, out, d) else try out.appendSlice(a, "null");
    try out.append(a, ',');
    if (i.hint) |h| try str(.{}, a, out, h) else try out.appendSlice(a, "null");
    try out.append(a, ',');
    try str(.{}, a, out, &i.state);
    try out.appendSlice(a, "]]");
}

/// How the input of a type is checked: types.castPlan() of the type,
/// with its input function found.
const Check = union(enum) {
    /// Any string is valid.
    any,
    /// The input function, of the string alone.
    call: *const int.FuncDef,
    /// xq_dec(x, p, s).
    numeric: [2]i64,
    /// xq_pg_iv_in(x, typmod).
    interval: struct { def: *const int.FuncDef, typmod: i64 },
    /// varchar(n), char(n): at most n characters but spaces.
    truncate: struct { n: i64, name: []const u8 },
    /// real (`true`), double precision.
    float: bool,
    bytea,
    /// int2vector, oidvector: integers of the width, separated by spaces.
    vector: integer.Width,
};

/// The check of type `type_text`; null if there is no such type.
fn resolve(ctx: *Context, a: Allocator, type_text: []const u8) ?Check {
    const ty = typeName(a, type_text) orelse return null;
    const plan = types.castPlan(ty) catch return null;
    const eql = std.mem.eql;
    const db = api.contextDbHandle(ctx);
    return switch (plan) {
        // timetz is SQLite's time(), which reads anything.
        .func => |name| if (eql(u8, name, "time")) .any else if (callback.findFunction(db, name, 1, vi.ENC.UTF8, false)) |def| .{ .call = def } else .any,
        .numeric => |pm| .{ .numeric = pm },
        .interval => |typmod| if (callback.findFunction(db, "xq_pg_iv_in", 2, vi.ENC.UTF8, false)) |def| .{ .interval = .{ .def = def, .typmod = typmod } } else .any,
        .truncate => |n| .{ .truncate = .{ .n = n, .name = if (eql(u8, ty.name, "character")) "character" else "character varying" } },
        .round => .any,
        .sqlite => if (eql(u8, ty.name, "real") or eql(u8, ty.name, "double precision"))
            .{ .float = ty.name[0] == 'r' }
        else if (eql(u8, ty.name, "bytea"))
            .bytea
        else if (eql(u8, ty.name, "int2vector"))
            .{ .vector = .int2 }
        else if (eql(u8, ty.name, "oidvector"))
            .{ .vector = .int8 }
        else
            .any,
    };
}

/// The check of the type (argument type_arg) resolved once per
/// statement: the caller passes a constant.
const Cached = struct {
    gpa: Allocator,
    text: []const u8,
    check: Check,

    fn destroy(c: *Cached) void {
        c.gpa.free(c.text);
        c.gpa.destroy(c);
    }
};

const type_arg = 1;

/// The check of `type_text`, kept with the statement (sqlite3_set_auxdata())
/// for the rows after the first; error.Reported if there is no such type.
fn cachedCheck(ctx: *Context, a: Allocator, type_text: []const u8) Fail!Check {
    if (api.getAuxdataTyped(ctx, type_arg, Cached.destroy)) |c| {
        if (std.mem.eql(u8, c.text, type_text)) return c.check;
    }
    const check = resolve(ctx, a, type_text) orelse {
        const msg = try std.fmt.allocPrint(a, "type \"{s}\" does not exist", .{type_text});
        api.resultErrorState(ctx, .of("42704"), msg);
        return error.Reported;
    };
    // A check holds no memory of `a` but its truncate name, a literal.
    const gpa = dfunc.gpa(ctx);
    const c = gpa.create(Cached) catch return check;
    c.* = .{ .gpa = gpa, .text = gpa.dupe(u8, type_text) catch {
        gpa.destroy(c);
        return check;
    }, .check = check };
    api.setAuxdataTyped(ctx, type_arg, Cached.destroy, c);
    return check;
}

/// The error input `value` of type `type_text` raises, null if none.
fn run(ctx: *Context, a: Allocator, value: []const u8, type_text: []const u8) Fail!?Info {
    switch (try cachedCheck(ctx, a, type_text)) {
        .any => return null,
        .call => |def| return callInput(ctx, a, def, &.{.{ .text = value }}),
        // xq_dec() makes apply_typmod()'s DETAIL.
        .numeric => |pm| return callInput(ctx, a, decimal_sql.def("xq_dec", 3), &.{ .{ .text = value }, .{ .int = pm[0] }, .{ .int = pm[1] } }),
        .interval => |iv| return callInput(ctx, a, iv.def, &.{ .{ .text = value }, .{ .int = iv.typmod } }),
        .truncate => |t| {
            // Too long unless the excess is spaces.
            const view = std.unicode.Utf8View.init(value) catch return null;
            var it = view.iterator();
            var count: i64 = 0;
            while (it.nextCodepointSlice()) |cp| : (count += 1) {
                if (count >= t.n and !(cp.len == 1 and cp[0] == ' ')) {
                    return .{ .msg = try std.fmt.allocPrint(a, "value too long for type {s}({d})", .{ t.name, t.n }), .state = "22001".* };
                }
            }
            return null;
        },
        .float => |real| {
            var buf: [1024]u8 = undefined;
            return switch (builtins.floatInput(value, real, &buf)) {
                .value => null,
                .failed => |e| .{ .msg = try a.dupe(u8, e.msg), .state = e.state.sqlstate },
            };
        },
        .bytea => return byteaInput(a, value),
        .vector => |w| {
            var words = std.mem.tokenizeAny(u8, value, " \t\r\n");
            while (words.next()) |word| {
                _ = integer.parse(word, w) catch |err| {
                    var buf: [1024]u8 = undefined;
                    const e = integer.inputError(err, w, word, &buf);
                    return .{ .msg = try a.dupe(u8, e.msg), .state = e.state.sqlstate };
                };
            }
            return null;
        },
    }
}

/// The type name `z` spells, as a cast reads it; null if it is none.
fn typeName(a: Allocator, z: []const u8) ?types.TypeName {
    const Parser = @import("parser.zig").Parser;
    const src = a.dupeSentinel(u8, z, 0) catch return null;
    var p = Parser.init(a, src, 0, null, .{}) catch return null;
    const ty = p.typeName() catch return null;
    if (p.c.peek().kind != .eof) return null;
    _ = types.info(ty) catch return null;
    return ty;
}

const Arg = union(enum) { text: []const u8, int: i64 };

/// Call input function `def` on `args`; its error, null if it has none.
fn callInput(ctx: *Context, a: Allocator, def: *const int.FuncDef, args: []const Arg) Fail!?Info {
    const db = api.contextDbHandle(ctx);
    var mems: [3]Mem = undefined;
    var ptrs: [3]*Mem = undefined;
    for (args, 0..) |x, i| {
        mems[i] = .{ .db = db };
        switch (x) {
            .text => |s| mem.setStr(&mems[i], s, vi.ENC.UTF8, .static) catch return error.OutOfMemory,
            .int => |v| mem.setInt64(&mems[i], v),
        }
        ptrs[i] = &mems[i];
    }
    defer for (mems[0..args.len]) |*m| mem.release(m);
    var out: Mem = .{ .db = db };
    defer mem.release(&out);
    var sub: Context = .{ .out = &out, .func = def, .argc = @intCast(args.len), .argv = ptrs[0..args.len] };
    def.x_sfunc.?(&sub, ptrs[0..args.len]);
    if (sub.is_error == 0) return null;
    if (sub.is_error == int.RC.NOMEM) return error.OutOfMemory;
    // The message may carry its DETAIL and HINT lines, where its
    // ErrorState says (util.splitFields()).
    const f = util.splitFields(try a.dupe(u8, api.valueText(&out) orelse ""), if (sub.err_state) |s| s.fields else .{});
    const state: [5]u8 = if (sub.err_state) |s| s.sqlstate else "XX000".*;
    return .{ .msg = f.message, .detail = f.detail, .hint = f.hint, .state = state };
}

/// byteain(): \x and hex digits (spaces between pairs), or the escape
/// format (\\, \ooo).
fn byteaInput(a: Allocator, s: []const u8) Fail!?Info {
    if (s.len >= 2 and s[0] == '\\' and s[1] == 'x') {
        var i: usize = 2;
        while (i < s.len) {
            const c = s[i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                i += 1;
                continue;
            }
            if (std.fmt.charToDigit(c, 16)) |_| {} else |_| {
                return .{ .msg = try std.fmt.allocPrint(a, "invalid hexadecimal digit: \"{s}\"", .{s[i .. i + json.charLen(s, i)]}), .state = "22023".* };
            }
            if (i + 1 >= s.len) return .{ .msg = "invalid hexadecimal data: odd number of digits", .state = "22023".* };
            if (std.fmt.charToDigit(s[i + 1], 16)) |_| {} else |_| {
                return .{ .msg = try std.fmt.allocPrint(a, "invalid hexadecimal digit: \"{s}\"", .{s[i + 1 .. i + 1 + json.charLen(s, i + 1)]}), .state = "22023".* };
            }
            i += 2;
        }
        return null;
    }
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            i += 1;
            continue;
        }
        if (i + 1 < s.len and s[i + 1] == '\\') {
            i += 2;
        } else if (i + 3 < s.len and isOct(s[i + 1], '3') and isOct(s[i + 2], '7') and isOct(s[i + 3], '7')) {
            i += 4;
        } else {
            return .{ .msg = "invalid input syntax for type bytea", .state = "22P02".* };
        }
    }
    return null;
}

fn isOct(c: u8, max: u8) bool {
    return c >= '0' and c <= max;
}
