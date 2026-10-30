//! Function calls in T-SQL expressions: the special syntaxes (CAST,
//! CONVERT with a style, TRY_CAST, the date functions' datepart words,
//! STRING_AGG ... WITHIN GROUP, IIF, CHOOSE), @@functions, and the
//! functions SQL Server names or defines differently from SQLite, as tree
//! nodes: SQLite's built-ins, engine functions (xq_tsql_*, frontend.zig)
//! or functions of the dialect's table (runtime.zig, a Func of .mssql).
//! Any other name is called as written.

const std = @import("std");
const ctype = @import("../../util/ctype.zig");
const tree = @import("../../ir/tree.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const lexer = @import("lexer.zig");
const frontend = @import("frontend.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;
const Token = lexer.Token;

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// `name ( ... )` at the current token.
pub fn call(s: *Parser) Error!*Expr {
    const name_tok = s.tok;
    const pos = s.posOf(name_tok);
    s.advance();
    try s.expectOp("(");
    const n = name_tok.text;
    if (try @import("json_sql.zig").call(s, n, pos)) |e| return e;

    if (eq(n, "CAST") or eq(n, "TRY_CAST") or eq(n, "PARSE") or eq(n, "TRY_PARSE")) {
        const e = try s.expr();
        try s.expectKw("AS");
        const ty = try typeName(s);
        if (s.eatKw("USING")) _ = try s.expr();
        try s.expectOp(")");
        return castTo(s, pos, e, ty, eq(n, "TRY_CAST") or eq(n, "TRY_PARSE"));
    }
    if (eq(n, "CONVERT") or eq(n, "TRY_CONVERT")) {
        const ty = try typeName(s);
        try s.expectOp(",");
        const e = try s.expr();
        var style: ?i64 = null;
        if (s.eatOp(",")) {
            if (s.tok.kind != .integer) return s.fail("xqlite: CONVERT needs a constant style", .{});
            style = std.fmt.parseInt(i64, s.tok.text, 10) catch return s.syntaxError();
            s.advance();
        }
        try s.expectOp(")");
        if (style) |st| if (ty.t.isChar()) {
            if (dateStyle(st)) |fmt| {
                const f = try s.func(pos, "strftime", &.{ try s.str(pos, fmt), e });
                const len = ty.t.maxLength() orelse return f;
                return s.mk(pos, .{ .cast = .{ .e = f, .target_type = ty.text, .mode = .{ .truncate = len } } });
            }
        };
        return castTo(s, pos, e, ty, eq(n, "TRY_CONVERT"));
    }
    if (eq(n, "DATEADD") or eq(n, "DATEDIFF") or eq(n, "DATEDIFF_BIG") or eq(n, "DATEPART") or eq(n, "DATENAME")) {
        const part = try datePart(s);
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(s.a, try s.str(pos, part));
        while (s.eatOp(",")) try args.append(s.a, try dateArg(s));
        try s.expectOp(")");
        const want: usize = if (eq(n, "DATEPART") or eq(n, "DATENAME")) 2 else 3;
        if (args.items.len != want) return argCount(s, n);
        const fname: []const u8 = if (eq(n, "DATEADD")) "dateadd" else if (eq(n, "DATEPART")) "datepart" else if (eq(n, "DATENAME")) "datename" else "datediff";
        return s.func(pos, fname, args.items);
    }
    if (eq(n, "TRIM")) {
        // TRIM([chars FROM] s)
        const first = try s.expr();
        if (s.eatKw("FROM")) {
            const str = try s.expr();
            try s.expectOp(")");
            return s.func(pos, "trim", &.{ str, first });
        }
        try s.expectOp(")");
        return s.func(pos, "trim", &.{ first, try s.str(pos, " ") });
    }
    if (eq(n, "STRING_AGG")) {
        const e = try s.expr();
        try s.expectOp(",");
        const sep = try s.expr();
        try s.expectOp(")");
        var order: []tree.SortItem = &.{};
        if (s.eatKw("WITHIN")) {
            try s.expectKw("GROUP");
            try s.expectOp("(");
            try s.expectKw("ORDER");
            try s.expectKw("BY");
            order = try s.sortList();
            try s.expectOp(")");
        }
        const over = try s.overClause();
        return s.funcNode(pos, .{ .name = .{ .text = "group_concat", .pos = pos }, .args = try s.a.dupe(*Expr, &.{ e, sep }), .order_by = order, .over = over });
    }

    // An ordinary call: [DISTINCT|ALL] args, or *.
    var distinct = false;
    var args: []*Expr = &.{};
    var star = false;
    if (s.eatOp("*")) {
        star = true;
    } else {
        if (s.eatKw("DISTINCT")) {
            distinct = true;
        } else _ = s.eatKw("ALL");
        if (!s.isOp(")")) args = try s.exprList();
    }
    try s.expectOp(")");
    const over = try s.overClause();
    if (star or distinct or over != null) {
        // An aggregate or a window function.
        var fname: []const u8 = name_tok.text;
        if (aggregates.get(fname)) |to| fname = to;
        if (over == null and eq(fname, "avg")) fname = "xq_tsql_avg";
        return s.funcNode(pos, .{ .name = .{ .text = fname, .pos = pos }, .args = args, .star = star, .distinct = distinct, .over = over });
    }
    return byName(s, n, args, pos);
}

/// The aggregates SQL Server spells differently.
const aggregates = std.StaticStringMapWithEql([]const u8, ctype.eqlNoCase).initComptime(.{
    .{ "count_big", "count" },
    .{ "stdev", "xq_stddev_samp" },
    .{ "stdevp", "xq_stddev_pop" },
    .{ "var", "xq_var_samp" },
    .{ "varp", "xq_var_pop" },
    .{ "checksum_agg", "total" },
});

fn argCount(s: *Parser, n: []const u8) Error {
    return s.fail("The {s} function requires a different number of arguments.", .{n});
}

/// A datepart word of DATEADD/DATEDIFF/DATEPART/DATENAME, its canonical
/// name.
fn datePart(s: *Parser) Error![]const u8 {
    const t = s.tok;
    if (t.kind != .ident and t.kind != .quoted_ident and t.kind != .string) return s.syntaxError();
    const w = if (t.kind == .string) try lexer.stringValue(s.a, t) else try s.nameText(t);
    s.advance();
    return canonicalPart(w) orelse s.fail("'{s}' is not a recognized datepart option.", .{w});
}

/// The canonical name of a datepart or its abbreviation.
pub fn canonicalPart(w: []const u8) ?[]const u8 {
    const parts = [_]struct { []const u8, []const []const u8 }{
        .{ "year", &.{ "year", "yy", "yyyy" } },
        .{ "quarter", &.{ "quarter", "qq", "q" } },
        .{ "month", &.{ "month", "mm", "m" } },
        .{ "dayofyear", &.{ "dayofyear", "dy", "y" } },
        .{ "day", &.{ "day", "dd", "d" } },
        .{ "week", &.{ "week", "wk", "ww" } },
        .{ "weekday", &.{ "weekday", "dw", "w" } },
        .{ "hour", &.{ "hour", "hh" } },
        .{ "minute", &.{ "minute", "mi", "n" } },
        .{ "second", &.{ "second", "ss", "s" } },
        .{ "millisecond", &.{ "millisecond", "ms" } },
        .{ "microsecond", &.{ "microsecond", "mcs" } },
        .{ "nanosecond", &.{ "nanosecond", "ns" } },
        .{ "iso_week", &.{ "iso_week", "isowk", "isoww" } },
        .{ "tzoffset", &.{ "tzoffset", "tz" } },
    };
    for (parts) |p| for (p[1]) |a| if (eq(a, w)) return p[0];
    return null;
}

/// A date argument: a string constant is a datetime (as SQL Server
/// converts it), so that the result has its format.
fn dateArg(s: *Parser) Error!*Expr {
    const e = try s.expr();
    if (e.kind != .string) return e;
    return s.mk(e.pos, .{ .cast = .{ .e = e, .target_type = "datetime", .mode = .{ .typed = .{ .func = "xq_tsql_cast", .type_arg = "datetime" } } } });
}

/// The strftime() format of a CONVERT style for dates, null for a style
/// xqlite does not know (the value is converted as by CAST).
fn dateStyle(style: i64) ?[]const u8 {
    return switch (style) {
        1 => "%m/%d/%y",
        101 => "%m/%d/%Y",
        2 => "%y.%m.%d",
        102 => "%Y.%m.%d",
        3 => "%d/%m/%y",
        103 => "%d/%m/%Y",
        4 => "%d.%m.%y",
        104 => "%d.%m.%Y",
        5 => "%d-%m-%y",
        105 => "%d-%m-%Y",
        8, 24, 108 => "%H:%M:%S",
        10 => "%m-%d-%y",
        110 => "%m-%d-%Y",
        11 => "%y/%m/%d",
        111 => "%Y/%m/%d",
        12 => "%y%m%d",
        112 => "%Y%m%d",
        20, 120 => "%Y-%m-%d %H:%M:%S",
        21, 25, 121 => "%Y-%m-%d %H:%M:%f",
        23 => "%Y-%m-%d",
        126, 127 => "%Y-%m-%dT%H:%M:%f",
        else => null,
    };
}

/// A type name as written in CAST/CONVERT/DECLARE: the type and its
/// canonical spelling.
pub const TypeName = struct { t: types.Type, text: []const u8, written: []const u8 };

/// `type [(n [, s]) | (max)]` at the current token. `column`: the
/// defaults of a column definition (char is char(1)), else of CAST
/// (char is char(30)).
pub fn typeNameOf(s: *Parser, column: bool) Error!TypeName {
    const t = s.tok;
    if (t.kind != .ident and t.kind != .quoted_ident) return s.syntaxError();
    var tname = try s.nameText(t);
    s.advance();
    // dbo.type / sys.type
    if (s.isOp(".") and (std.ascii.eqlIgnoreCase(tname, "dbo") or std.ascii.eqlIgnoreCase(tname, "sys"))) {
        s.advance();
        tname = try s.nameText(try s.anyName());
    }
    // char varying, national character varying, double precision.
    if (eq(tname, "NATIONAL")) {
        tname = try s.nameText(try s.anyName());
        tname = if (eq(tname, "TEXT")) "ntext" else "nchar";
    }
    if (s.eatKw("VARYING")) tname = if (eq(tname, "nchar")) "nvarchar" else "varchar";
    if (eq(tname, "DOUBLE")) {
        try s.expectKw("PRECISION");
        tname = "float";
    }
    const base = types.baseByName(tname) orelse return s.fail("Column, parameter, or variable #1: Cannot find data type {s}.", .{tname});
    var ty: types.Type = .{ .base = base };
    if (s.eatOp("(")) {
        if (s.eatKw("MAX")) {
            ty.len = types.max_len;
        } else {
            ty.len = try intArg(s);
            if (s.eatOp(",")) ty.scale = try intArg(s);
        }
        try s.expectOp(")");
    }
    ty = types.columnDefaults(tname, ty);
    if (!column and ty.len == null and (ty.isChar() or ty.isBinary())) {
        switch (ty.base) {
            .text, .ntext, .image => {},
            else => ty.len = 30,
        }
    }
    if (ty.base == .decimal or ty.base == .numeric) {
        const p = ty.len orelse 18;
        if (p < 1 or p > 38 or (ty.scale orelse 0) > p or (ty.scale orelse 0) < 0) return s.fail("The scale must be less than or equal to the precision.", .{});
    }
    return .{ .t = ty, .text = try types.format(s.a, ty), .written = tname };
}

fn typeName(s: *Parser) Error!TypeName {
    return typeNameOf(s, false);
}

fn intArg(s: *Parser) Error!i64 {
    if (s.tok.kind != .integer) return s.syntaxError();
    const v = std.fmt.parseInt(i64, s.tok.text, 10) catch return s.syntaxError();
    s.advance();
    return v;
}

/// CAST(e AS type) (TRY_CAST if `try_`): SQLite's conversion where it
/// means the same (character and binary strings, floats), else
/// xq_tsql_cast() (xq_tsql_try_cast()), which converts and fails as
/// SQL Server does.
pub fn castTo(s: *Parser, pos: u32, e: *Expr, ty: TypeName, try_: bool) Error!*Expr {
    const t = ty.t;
    if (t.isChar()) {
        if (t.maxLength()) |n| return s.mk(pos, .{ .cast = .{ .e = e, .target_type = ty.text, .mode = .{ .truncate = n } } });
        return s.mk(pos, .{ .cast = .{ .e = e, .target_type = ty.text, .mode = .{ .affinity = "TEXT" } } });
    }
    if (t.isBinary()) {
        const blob = try s.mk(pos, .{ .cast = .{ .e = e, .target_type = ty.text, .mode = .{ .affinity = "BLOB" } } });
        if (t.maxLength()) |n| return s.func(pos, "substr", &.{ blob, try s.int_(pos, 1), try s.int_(pos, n) });
        return blob;
    }
    if ((t.base == .float or t.base == .real) and !try_) {
        return s.mk(pos, .{ .cast = .{ .e = e, .target_type = ty.text, .mode = .{ .affinity = "REAL" } } });
    }
    if (t.base == .xml or t.base == .sql_variant) return e;
    const f: []const u8 = if (try_) "xq_tsql_try_cast" else "xq_tsql_cast";
    return s.mk(pos, .{ .cast = .{ .e = e, .target_type = ty.text, .mode = .{ .typed = .{ .func = f, .type_arg = ty.text } } } });
}

/// @@name: a session value or a constant.
pub fn systemFunction(s: *Parser, t: Token, pos: u32) Error!*Expr {
    const n = t.text[2..];
    if (eq(n, "ROWCOUNT")) return s.func(pos, "changes", &.{});
    if (eq(n, "IDENTITY")) return s.func(pos, "scope_identity", &.{});
    if (eq(n, "TRANCOUNT")) return s.func(pos, "xq_tsql_trancount", &.{});
    if (eq(n, "VERSION")) return s.str(pos, frontend.version);
    const ints = [_]struct { []const u8, i64 }{
        .{ "SPID", 51 },         .{ "ERROR", 0 },               .{ "DATEFIRST", 7 },     .{ "MAX_PRECISION", 38 },
        .{ "FETCH_STATUS", -1 }, .{ "NESTLEVEL", 0 },           .{ "LOCK_TIMEOUT", -1 }, .{ "TEXTSIZE", 4096 },
        .{ "OPTIONS", 5496 },    .{ "MAX_CONNECTIONS", 32767 }, .{ "LANGID", 0 },
    };
    for (ints) |x| if (eq(n, x[0])) return s.int_(pos, x[1]);
    const strs = [_]struct { []const u8, []const u8 }{
        .{ "SERVERNAME", "xqlite" }, .{ "SERVICENAME", "MSSQLSERVER" }, .{ "LANGUAGE", "us_english" },
    };
    for (strs) |x| if (eq(n, x[0])) return s.str(pos, x[1]);
    return s.fail("Must declare the scalar variable \"{s}\".", .{t.text});
}

/// Functions with SQLite's semantics under another name.
const renames = std.StaticStringMapWithEql([]const u8, ctype.eqlNoCase).initComptime(.{
    .{ "substring", "substr" },
    .{ "isnull", "ifnull" },
    .{ "datalength", "octet_length" },
    .{ "nchar", "char" },
    .{ "count_big", "count" },
    .{ "stdev", "xq_stddev_samp" },
    .{ "stdevp", "xq_stddev_pop" },
    .{ "var", "xq_var_samp" },
    .{ "varp", "xq_var_pop" },
    .{ "ceiling", "ceiling" },
    .{ "newid", "xq_tsql_newid" },
    .{ "newsequentialid", "xq_tsql_newid" },
    .{ "rand", "xq_rand" },
    .{ "avg", "xq_tsql_avg" },
    .{ "log10", "log10" },
    .{ "replicate", "replicate" },
});

/// The function `n` (as written) with `args`, at `pos`.
pub fn byName(s: *Parser, n: []const u8, args_in: []const *Expr, pos: u32) Error!*Expr {
    const args = try s.a.dupe(*Expr, args_in);
    const k = args.len;
    if (renames.get(n)) |to| return s.func(pos, to, args);
    if (eq(n, "len") and k == 1) {
        return s.func(pos, "length", &.{try s.func(pos, "rtrim", &.{args[0]})});
    }
    if (eq(n, "getdate") or eq(n, "current_timestamp") or eq(n, "getutcdate")) {
        if (k != 0) return argCount(s, n);
        return s.func(pos, "strftime", &.{ try s.str(pos, "%Y-%m-%d %H:%M:%f"), try s.str(pos, "now") });
    }
    if (eq(n, "sysdatetime") or eq(n, "sysutcdatetime") or eq(n, "sysdatetimeoffset")) {
        if (k != 0) return argCount(s, n);
        const now = try s.func(pos, "strftime", &.{ try s.str(pos, "%Y-%m-%d %H:%M:%f"), try s.str(pos, "now") });
        const tail: []const u8 = if (eq(n, "sysdatetimeoffset")) "0000 +00:00" else "0000";
        return s.mk(pos, .{ .concat = .{ .args = try s.a.dupe(*Expr, &.{ now, try s.str(pos, tail) }), .null_policy = .propagate } });
    }
    if (eq(n, "current_date")) return s.func(pos, "date", &.{try s.str(pos, "now")});
    if (eq(n, "iif")) {
        if (k != 3) return argCount(s, n);
        return s.mk(pos, .{ .case = .{ .operand = null, .whens = try s.a.dupe(*Expr, &.{ args[0], args[1] }), .@"else" = args[2] } });
    }
    if (eq(n, "choose")) {
        if (k < 2) return argCount(s, n);
        var whens: std.ArrayList(*Expr) = .empty;
        for (args[1..], 1..) |x, i| {
            try whens.append(s.a, try s.int_(pos, @intCast(i)));
            try whens.append(s.a, x);
        }
        return s.mk(pos, .{ .case = .{ .operand = args[0], .whens = whens.items, .@"else" = null } });
    }
    if (eq(n, "concat")) {
        if (k < 2) return s.fail("The concat function requires 2 to 254 arguments.", .{});
        return s.mk(pos, .{ .concat = .{ .args = args, .null_policy = .skip } });
    }
    if (eq(n, "square") and k == 1) return s.bin(.mul, args[0], args[0]);
    if (eq(n, "log") and k == 2) return s.func(pos, "log", &.{ args[1], args[0] });
    if (eq(n, "log") and k == 1) return s.func(pos, "ln", args);
    if (eq(n, "round") and k == 3) {
        // ROUND(x, n, f): truncates unless f is 0.
        const trunc = try s.func(pos, "truncate", &.{ args[0], args[1] });
        const rnd = try s.func(pos, "round", &.{ args[0], args[1] });
        const zero = try s.mk(pos, .{ .compare = .{ .op = .eq, .l = args[2], .r = try s.int_(pos, 0) } });
        return s.mk(pos, .{ .case = .{ .operand = null, .whens = try s.a.dupe(*Expr, &.{ zero, rnd }), .@"else" = trunc } });
    }
    if ((eq(n, "year") or eq(n, "month") or eq(n, "day")) and k == 1) {
        return s.func(pos, "datepart", &.{ try s.str(pos, try std.ascii.allocLowerString(s.a, n)), args[0] });
    }
    if (eq(n, "db_name") or eq(n, "original_db_name")) return s.str(pos, "main");
    if (eq(n, "schema_name")) return s.str(pos, "dbo");
    if (eq(n, "user_name") or eq(n, "suser_sname") or eq(n, "suser_name") or eq(n, "current_user") or eq(n, "session_user") or eq(n, "user")) {
        return s.str(pos, "dbo");
    }
    if (eq(n, "system_user")) return s.str(pos, "sa");
    if (eq(n, "host_name") or eq(n, "app_name")) return s.str(pos, "xqlite");
    if (eq(n, "object_id")) return objectId(s, pos, args);
    if (eq(n, "quotename") and (k == 1 or k == 2)) {
        // [name] with ] doubled (QUOTENAME(s, '"') and the like too).
        var open: []const u8 = "[";
        var close: []const u8 = "]";
        if (k == 2) {
            if (args[1].kind != .string) return s.fail("xqlite: QUOTENAME needs a constant quote character", .{});
            const q = args[1].kind.string;
            if (std.mem.eql(u8, q, "\"")) {
                open = "\"";
                close = "\"";
            } else if (std.mem.eql(u8, q, "'")) {
                open = "'";
                close = "'";
            } else if (!std.mem.eql(u8, q, "[") and !std.mem.eql(u8, q, "]")) return s.mk(pos, .null);
        }
        const doubled = try std.mem.concat(s.a, u8, &.{ close, close });
        const rep = try s.funcNode(pos, .{ .name = .{ .text = "replace", .pos = pos }, .args = try s.a.dupe(*Expr, &.{ args[0], try s.str(pos, close), try s.str(pos, doubled) }) });
        return s.mk(pos, .{ .concat = .{ .args = try s.a.dupe(*Expr, &.{ try s.str(pos, open), rep, try s.str(pos, close) }), .null_policy = .propagate } });
    }
    if (eq(n, "format") or eq(n, "string_split") or eq(n, "openjson")) {
        if (eq(n, "openjson")) return s.fail("xqlite: OPENJSON is a table source (FROM, CROSS APPLY)", .{});
        return s.fail("xqlite: {s}() is not supported", .{n});
    }
    // As written: a function of the dialect's table, a SQLite built-in
    // or an application function.
    return s.func(pos, n, args);
}

/// OBJECT_ID('[schema.]name' [, type]): the rowid of the table or view
/// in sqlite_schema (sys.tables shows the same), NULL if there is none.
fn objectId(s: *Parser, pos: u32, args: []const *Expr) Error!*Expr {
    if (args.len < 1 or args.len > 2) return argCount(s, "object_id");
    if (args[0].kind != .string) return s.fail("xqlite: OBJECT_ID needs a constant name", .{});
    var z = args[0].kind.string;
    var schema: []const u8 = "main";
    // tempdb..#t, dbo.t, [dbo].[t]
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, z, '.');
    while (it.next()) |part| try parts.append(s.a, std.mem.trim(u8, part, "[]\""));
    z = parts.items[parts.items.len - 1];
    if (parts.items.len >= 2) {
        const first = parts.items[0];
        if (std.ascii.eqlIgnoreCase(first, "tempdb")) schema = "temp";
    }
    if (z.len > 0 and z[0] == '#') schema = "temp";
    const text = try std.fmt.allocPrintSentinel(s.a, "(SELECT rowid FROM {s}.sqlite_schema WHERE type IN ('table', 'view') AND name = {f} COLLATE NOCASE)", .{ schema, @import("../dialect.zig").Quoted('\''){ .z = z } }, 0);
    var sub: Parser = .init(s.p, text);
    sub.depth = 1;
    const e = try sub.expr();
    if (sub.tok.kind != .eof) return sub.syntaxError();
    const sel = e.kind.subquery;
    sel.src = text;
    return s.mk(pos, .{ .subquery = sel });
}
