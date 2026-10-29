//! Function calls in MariaDB expressions: the special syntaxes (CAST,
//! CONVERT, TRIM, SUBSTRING ... FROM, EXTRACT, GROUP_CONCAT ...
//! SEPARATOR, DATE_ADD with INTERVAL, VALUES(col) of ON DUPLICATE KEY
//! UPDATE) and the functions MariaDB names or defines differently from
//! SQLite, lowered to SQLite's built-ins or to the dialect's functions
//! (runtime.zig). Any other name is called as written: SQLite's
//! built-ins and the dialect table resolve it.

const std = @import("std");
const ctype = @import("../../util/ctype.zig");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const parser = @import("parser.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Token = parser.Token;
const Expr = int.Expr;
const ExprList = int.ExprList;
const TK = int.TK;
const SF = int.SF;
const irTok = parser.irTok;

/// `name ( ... )` at the current token.
pub fn call(s: *Parser) Error!*Expr {
    const name_tok = s.tok;
    s.advance();
    try s.expectOp("(");
    var lname_buf: [64]u8 = undefined;
    const lname = if (name_tok.text.len <= lname_buf.len) std.ascii.lowerString(&lname_buf, name_tok.text) else name_tok.text;

    if (eq(lname, "cast")) {
        const e = try s.expr();
        try s.expectKw("AS");
        const r = try castTo(s, e);
        try s.expectOp(")");
        return r;
    }
    if (eq(lname, "convert")) {
        const e = try s.expr();
        if (s.eatKw("USING")) {
            _ = try s.anyName();
            try s.expectOp(")");
            return e;
        }
        try s.expectOp(",");
        const r = try castTo(s, e);
        try s.expectOp(")");
        return r;
    }
    if (eq(lname, "trim")) return trim(s);
    if (eq(lname, "substring") or eq(lname, "substr") or eq(lname, "mid")) {
        const str = try s.expr();
        var args = try ir.list.append(s.p, null, str);
        if (s.eatKw("FROM")) {
            args = try ir.list.append(s.p, args, try s.expr());
            if (s.eatKw("FOR")) args = try ir.list.append(s.p, args, try s.expr());
        } else {
            while (s.eatOp(",")) args = try ir.list.append(s.p, args, try s.expr());
        }
        try s.expectOp(")");
        return ir.expr.functionCall(s.p, "substr", args);
    }
    if (eq(lname, "position")) {
        // POSITION(substr IN str): the IN is not an operator here.
        const sub = try s.bitOr();
        try s.expectKw("IN");
        const str = try s.expr();
        try s.expectOp(")");
        return s.call("instr", &.{ str, sub });
    }
    if (eq(lname, "extract")) {
        if (s.tok.kind != .ident) return s.syntaxError();
        const unit = try std.ascii.allocUpperString(s.a, s.tok.text);
        s.advance();
        try s.expectKw("FROM");
        const e = try s.expr();
        try s.expectOp(")");
        return s.call("xq_extract", &.{ try s.stringExpr(unit), e });
    }
    if (eq(lname, "date_add") or eq(lname, "date_sub") or eq(lname, "adddate") or eq(lname, "subdate")) {
        const d = try s.expr();
        try s.expectOp(",");
        const minus = eq(lname, "date_sub") or eq(lname, "subdate");
        var r: *Expr = undefined;
        if (s.eatKw("INTERVAL")) {
            const n = try s.expr();
            if (s.tok.kind != .ident) return s.syntaxError();
            const unit = s.tok.text;
            s.advance();
            r = try s.dateAdd(d, n, unit, minus);
        } else {
            r = try s.dateAdd(d, try s.expr(), "DAY", minus);
        }
        try s.expectOp(")");
        return r;
    }
    if (eq(lname, "timestampadd") or eq(lname, "timestampdiff")) {
        if (s.tok.kind != .ident) return s.syntaxError();
        const unit = s.tok.text;
        s.advance();
        try s.expectOp(",");
        const a = try s.expr();
        try s.expectOp(",");
        const b = try s.expr();
        try s.expectOp(")");
        if (eq(lname, "timestampadd")) return s.dateAdd(b, a, unit, false);
        return s.call("xq_timestampdiff", &.{ try s.stringExpr(try std.ascii.allocUpperString(s.a, unit)), a, b });
    }
    if (eq(lname, "group_concat")) return groupConcat(s, name_tok);
    if ((eq(lname, "values") or eq(lname, "value")) and s.in_odku) {
        // VALUES(col) in ON DUPLICATE KEY UPDATE: the value the INSERT
        // would have stored.
        const col = try s.anyName();
        try s.expectOp(")");
        const left = try ir.expr.token(s.p, TK.ID, int.Token.init("excluded"));
        return ir.expr.binary(s.p, TK.DOT, left, try s.idExpr(col));
    }
    if (eq(lname, "nextval") or eq(lname, "lastval") or eq(lname, "setval")) {
        // MariaDB passes the sequence as a name, not a string.
        var args: ?*ExprList = null;
        if (s.tok.kind == .ident or s.tok.kind == .quoted_ident) {
            const n = try s.anyName();
            args = try ir.list.append(s.p, args, try s.stringExpr(try s.nameText(n)));
        } else args = try ir.list.append(s.p, args, try s.expr());
        while (s.eatOp(",")) args = try ir.list.append(s.p, args, try s.expr());
        try s.expectOp(")");
        return ir.expr.functionCall(s.p, lname, args);
    }
    if (eq(lname, "char")) {
        const args = try s.exprList();
        if (s.eatKw("USING")) _ = try s.anyName();
        try s.expectOp(")");
        return ir.expr.functionCall(s.p, "char", args);
    }
    if (eq(lname, "match") or eq(lname, "json_table")) {
        return s.fail("xqlite: {s}() is not supported", .{name_tok.text});
    }

    // An ordinary call: [DISTINCT|ALL] args, or *.
    var sf: SF = .{};
    var args: ?*ExprList = null;
    var star = false;
    if (s.isOp("*")) {
        s.advance();
        star = true;
    } else {
        if (s.eatKw("DISTINCT")) {
            sf = .{ .Distinct = true };
        } else _ = s.eatKw("ALL");
        if (!s.isOp(")")) args = try s.exprList();
    }
    try s.expectOp(")");
    if (sf.Distinct and args != null and args.?.len() > 1) {
        return s.fail("xqlite: {s}(DISTINCT ...) with several arguments is not supported", .{name_tok.text});
    }
    const e = if (star)
        try ir.expr.function(s.p, null, irTok(name_tok), .{})
    else
        try byNameFlags(s, lname, args, name_tok, sf);
    if (e.op == TK.FUNCTION) try s.overClause(e);
    return e;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A function of MariaDB called `lname` (lower case) with `args`.
pub fn byName(s: *Parser, lname: []const u8, args: ?*ExprList, t: Token) Error!*Expr {
    return byNameFlags(s, lname, args, t, .{});
}

fn nargs(args: ?*ExprList) usize {
    return if (args) |l| l.len() else 0;
}

/// MariaDB functions that are SQLite's (or the dialect's) under another
/// name, taking the same arguments (case-insensitive): renamed in queries
/// (byNameFlags()) and in the stored text of DDL (ddl.functionName()).
pub const renames = std.StaticStringMapWithEql([]const u8, ctype.eqlNoCase).initComptime(.{
    .{ "ucase", "upper" },
    .{ "lcase", "lower" },
    .{ "length", "octet_length" },
    .{ "char_length", "length" },
    .{ "character_length", "length" },
    .{ "mid", "substr" },
    .{ "substring", "substr" },
    .{ "row_count", "changes" },
    .{ "json_value", "json_extract" },
    .{ "std", "xq_stddev_pop" },
    .{ "stddev", "xq_stddev_pop" },
    .{ "stddev_pop", "xq_stddev_pop" },
    .{ "stddev_samp", "xq_stddev_samp" },
    .{ "variance", "xq_var_pop" },
    .{ "var_pop", "xq_var_pop" },
    .{ "var_samp", "xq_var_samp" },
    .{ "bit_length", "xq_bit_length" },
});

fn arg(args: ?*ExprList, i: usize) *Expr {
    return args.?.at(i).expr.?;
}

fn byNameFlags(s: *Parser, lname: []const u8, args: ?*ExprList, t: Token, sf: SF) Error!*Expr {
    const n = nargs(args);
    if (renames.get(lname)) |to| return renamed(s, to, args, sf);
    if (eq(lname, "now") or eq(lname, "sysdate") or eq(lname, "current_timestamp") or
        eq(lname, "localtime") or eq(lname, "localtimestamp") or eq(lname, "utc_timestamp"))
    {
        if (n > 0 and !isZero(arg(args, 0))) {
            return s.call("strftime", &.{ try s.stringExpr("%Y-%m-%d %H:%M:%f"), try s.stringExpr("now") });
        }
        return s.call("datetime", &.{try s.stringExpr("now")});
    }
    if (eq(lname, "curdate") or eq(lname, "current_date") or eq(lname, "utc_date")) {
        return s.call("date", &.{try s.stringExpr("now")});
    }
    if (eq(lname, "curtime") or eq(lname, "current_time") or eq(lname, "utc_time")) {
        return s.call("time", &.{try s.stringExpr("now")});
    }
    if (eq(lname, "unix_timestamp")) {
        if (n == 0) return s.call("unixepoch", &.{try s.stringExpr("now")});
        return renamed(s, "unixepoch", args, sf);
    }
    if (eq(lname, "from_unixtime") and n == 1) {
        return s.call("datetime", &.{ arg(args, 0), try s.stringExpr("unixepoch") });
    }
    if (eq(lname, "last_insert_id") and n == 0) return s.call("last_insert_rowid", &.{});
    if (eq(lname, "database") or eq(lname, "schema")) return s.stringExpr("main");
    if (eq(lname, "user") or eq(lname, "current_user") or eq(lname, "session_user") or eq(lname, "system_user")) {
        return s.stringExpr("root@localhost");
    }
    if (eq(lname, "connection_id")) return s.intExpr(1);
    if ((eq(lname, "greatest") or eq(lname, "least")) and n >= 2) {
        return renamed(s, if (eq(lname, "greatest")) "max" else "min", args, sf);
    }
    if (eq(lname, "isnull") and n == 1) return ir.expr.isNull(s.p, TK.ISNULL, arg(args, 0));
    if (eq(lname, "locate") and n == 2) return s.call("instr", &.{ arg(args, 1), arg(args, 0) });
    if ((eq(lname, "date") or eq(lname, "time") or eq(lname, "timestamp")) and n == 1) {
        const to = if (eq(lname, "timestamp")) "datetime" else lname;
        return s.call("xq_cast", &.{ arg(args, 0), try s.stringExpr(to) });
    }
    if (eq(lname, "if") and n == 3) return renamed(s, "if", args, sf);
    if (eq(lname, "rand") or eq(lname, "random")) return renamed(s, "xq_rand", args, sf);
    if (eq(lname, "mod") and n == 2) return ir.expr.binary(s.p, TK.REM, arg(args, 0), arg(args, 1));
    if (eq(lname, "uuid") or eq(lname, "uuid_short") or eq(lname, "sys_guid")) return renamed(s, "xq_uuid", args, sf);
    if (eq(lname, "format") or eq(lname, "hex") or eq(lname, "left") or eq(lname, "right") or
        eq(lname, "repeat") or eq(lname, "reverse") or eq(lname, "lpad") or eq(lname, "rpad") or
        eq(lname, "space") or eq(lname, "insert") or eq(lname, "replace"))
    {
        // Same name in the dialect table or SQLite (replace).
        return renamed(s, lname, args, sf);
    }
    // As written.
    return ir.expr.function(s.p, args, irTok(t), sf);
}

fn isZero(e: *Expr) bool {
    return e.flags.IntValue and e.u.value == 0;
}

fn renamed(s: *Parser, to: []const u8, args: ?*ExprList, sf: SF) Error!*Expr {
    const e = try ir.expr.function(s.p, args, int.Token.init(to), sf);
    return e;
}

/// CAST/CONVERT's target type at the current token, applied to `e`.
fn castTo(s: *Parser, e: *Expr) Error!*Expr {
    if (s.tok.kind != .ident) return s.syntaxError();
    const t = s.tok;
    s.advance();
    var len: ?*Expr = null;
    var scale: ?*Expr = null;
    if (t.isKw("DOUBLE")) _ = s.eatKw("PRECISION");
    if (t.isKw("SIGNED") or t.isKw("UNSIGNED")) _ = s.eatKw("INTEGER") or s.eatKw("INT");
    if (t.isKw("CHARACTER") or t.isKw("NATIONAL")) _ = s.eatKw("CHAR") or s.eatKw("VARYING");
    if (s.eatOp("(")) {
        len = try s.expr();
        if (s.eatOp(",")) scale = try s.expr();
        try s.expectOp(")");
    }
    // CHAR(n) CHARACTER SET x / COLLATE / BINARY.
    while (true) {
        if (s.isKw("CHARACTER") or s.isKw("CHARSET")) {
            s.advance();
            _ = s.eatKw("SET");
            _ = try s.anyName();
        } else if (s.eatKw("COLLATE")) {
            _ = try s.collationName();
        } else if (s.eatKw("BINARY") or s.eatKw("ASCII") or s.eatKw("UNICODE")) {} else break;
    }
    const kinds = [_]struct { []const u8, []const u8 }{
        .{ "SIGNED", "INTEGER" }, .{ "UNSIGNED", "INTEGER" }, .{ "INTEGER", "INTEGER" }, .{ "INT", "INTEGER" },
        .{ "CHAR", "TEXT" },      .{ "VARCHAR", "TEXT" },     .{ "NCHAR", "TEXT" },      .{ "CHARACTER", "TEXT" },
        .{ "NATIONAL", "TEXT" },  .{ "TEXT", "TEXT" },        .{ "BINARY", "BLOB" },     .{ "VARBINARY", "BLOB" },
        .{ "DOUBLE", "REAL" },    .{ "FLOAT", "REAL" },       .{ "REAL", "REAL" },       .{ "JSON", "" },
    };
    for (kinds) |k| if (t.isKw(k[0])) {
        if (k[1].len == 0) return e;
        var r = try ir.expr.cast(s.p, e, int.Token.init(k[1]));
        if (len) |l| if (std.mem.eql(u8, k[1], "TEXT") or std.mem.eql(u8, k[1], "BLOB")) {
            r = try s.call("substr", &.{ r, try s.intExpr(1), l });
        };
        return r;
    };
    if (t.isAnyKw(&.{ "DECIMAL", "DEC", "NUMERIC", "FIXED" })) {
        const real = try ir.expr.cast(s.p, e, int.Token.init("REAL"));
        if (scale) |sc| return s.call("round", &.{ real, sc });
        return ir.expr.cast(s.p, try s.call("round", &.{real}), int.Token.init("INTEGER"));
    }
    if (t.isAnyKw(&.{ "DATE", "DATETIME", "TIME", "TIMESTAMP" })) {
        const to = try std.ascii.allocLowerString(s.a, if (t.isKw("TIMESTAMP")) "DATETIME" else t.text);
        return s.call("xq_cast", &.{ e, try s.stringExpr(to) });
    }
    return s.fail("xqlite: CAST to {s} is not supported", .{t.text});
}

/// TRIM([[BOTH|LEADING|TRAILING] [remstr] FROM] str).
fn trim(s: *Parser) Error!*Expr {
    var func: []const u8 = "trim";
    var explicit = false;
    if (s.eatKw("BOTH")) {
        explicit = true;
    } else if (s.eatKw("LEADING")) {
        func = "ltrim";
        explicit = true;
    } else if (s.eatKw("TRAILING")) {
        func = "rtrim";
        explicit = true;
    }
    var rem: ?*Expr = null;
    var str: *Expr = undefined;
    if (explicit and s.eatKw("FROM")) {
        str = try s.expr();
    } else {
        const first = try s.expr();
        if (s.eatKw("FROM")) {
            rem = first;
            str = try s.expr();
        } else str = first;
    }
    try s.expectOp(")");
    // MariaDB trims spaces only by default (SQLite: spaces).
    if (rem) |r| return s.call(func, &.{ str, r });
    return s.call(func, &.{ str, try s.stringExpr(" ") });
}

/// GROUP_CONCAT([DISTINCT] expr [, expr ...] [ORDER BY ...]
/// [SEPARATOR str] [LIMIT n]): SQLite's group_concat() of the
/// concatenation of the expressions.
fn groupConcat(s: *Parser, name_tok: Token) Error!*Expr {
    _ = name_tok;
    var sf: SF = .{};
    if (s.eatKw("DISTINCT")) sf = .{ .Distinct = true } else _ = s.eatKw("ALL");
    const items = try s.exprList();
    var order: ?*ExprList = null;
    if (s.isKw("ORDER")) {
        s.advance();
        try s.expectKw("BY");
        order = try s.sortList();
    }
    var sep: ?[]const u8 = null;
    if (s.eatKw("SEPARATOR")) sep = try s.stringLiteral();
    if (s.isKw("LIMIT")) return s.fail("xqlite: GROUP_CONCAT(... LIMIT) is not supported", .{});
    try s.expectOp(")");
    const value = if (items.len() == 1) items.at(0).expr.? else try ir.expr.functionCall(s.p, "concat", items);
    var args = try ir.list.append(s.p, null, value);
    if (sep) |z| {
        if (sf.Distinct and !std.mem.eql(u8, z, ",")) {
            return s.fail("xqlite: GROUP_CONCAT(DISTINCT ... SEPARATOR) is only supported with ','", .{});
        }
        if (!sf.Distinct) args = try ir.list.append(s.p, args, try s.stringExpr(z));
    }
    const e = try ir.expr.function(s.p, args, int.Token.init("group_concat"), sf);
    if (order) |ob| try ir.expr.addFunctionOrderBy(s.p, e, ob);
    try s.overClause(e);
    return e;
}
