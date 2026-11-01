//! Function calls in MariaDB expressions: the special syntaxes (CAST,
//! CONVERT, TRIM, SUBSTRING ... FROM, EXTRACT, GROUP_CONCAT ...
//! SEPARATOR, DATE_ADD with INTERVAL, VALUES(col) of ON DUPLICATE KEY
//! UPDATE) and the functions MariaDB names or defines differently from
//! SQLite, as tree nodes: SQLite's built-ins, engine functions (xq_*) or
//! functions of the dialect's table (runtime.zig, a Func of .mariadb).
//! Any other name is called as written. The tree is the same for a
//! query and for what the schema keeps, so a renamed function means the
//! same in both.

const std = @import("std");
const ctype = @import("xqlite_base").ctype;
const tree = @import("../../ir/tree.zig");
const parser = @import("parser.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Expr = tree.Expr;

/// `name ( ... )` at the current token.
pub fn call(s: *Parser) Error!*Expr {
    const name_tok = s.tok;
    const pos = s.posOf(name_tok);
    s.advance();
    try s.expectOp("(");
    var lname_buf: [64]u8 = undefined;
    const lname = if (name_tok.text.len <= lname_buf.len) std.ascii.lowerString(&lname_buf, name_tok.text) else name_tok.text;

    if (eq(lname, "cast")) {
        const e = try s.expr();
        try s.expectKw("AS");
        const r = try castTo(s, pos, e);
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
        const r = try castTo(s, pos, e);
        try s.expectOp(")");
        return r;
    }
    if (eq(lname, "trim")) return trim(s, pos);
    if (eq(lname, "substring") or eq(lname, "substr") or eq(lname, "mid")) {
        var args: std.ArrayList(*Expr) = .empty;
        try args.append(s.a, try s.expr());
        if (s.eatKw("FROM")) {
            try args.append(s.a, try s.expr());
            if (s.eatKw("FOR")) try args.append(s.a, try s.expr());
        } else {
            while (s.eatOp(",")) try args.append(s.a, try s.expr());
        }
        try s.expectOp(")");
        return s.func(pos, "substr", args.items);
    }
    if (eq(lname, "position")) {
        // POSITION(substr IN str): the IN is not an operator here.
        const sub = try s.bitOr();
        try s.expectKw("IN");
        const str = try s.expr();
        try s.expectOp(")");
        return s.func(pos, "instr", &.{ str, sub });
    }
    if (eq(lname, "extract")) {
        if (s.tok.kind != .ident) return s.syntaxError();
        const unit = try std.ascii.allocUpperString(s.a, s.tok.text);
        s.advance();
        try s.expectKw("FROM");
        const e = try s.expr();
        try s.expectOp(")");
        return s.func(pos, "xq_extract", &.{ try s.str(pos, unit), e });
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
            r = try s.dateAdd(pos, d, n, unit, minus);
        } else {
            r = try s.dateAdd(pos, d, try s.expr(), "DAY", minus);
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
        if (eq(lname, "timestampadd")) return s.dateAdd(pos, b, a, unit, false);
        return s.func(pos, "xq_timestampdiff", &.{ try s.str(pos, try std.ascii.allocUpperString(s.a, unit)), a, b });
    }
    if (eq(lname, "group_concat")) return groupConcat(s, pos);
    if ((eq(lname, "values") or eq(lname, "value")) and s.in_odku) {
        // VALUES(col) in ON DUPLICATE KEY UPDATE: the value the INSERT
        // would have stored.
        const col = try s.nameOf(try s.anyName());
        try s.expectOp(")");
        return s.mk(pos, .{ .column = try s.a.dupe(tree.Name, &.{ .{ .text = "excluded", .pos = pos }, col }) });
    }
    if (eq(lname, "nextval") or eq(lname, "lastval") or eq(lname, "setval")) {
        // MariaDB passes the sequence as a name, not a string.
        var args: std.ArrayList(*Expr) = .empty;
        if (s.tok.kind == .ident or s.tok.kind == .quoted_ident) {
            const n = try s.qualifiedName();
            try args.append(s.a, try s.str(n.name.pos, try s.sequenceName(n)));
        } else try args.append(s.a, try s.expr());
        while (s.eatOp(",")) try args.append(s.a, try s.expr());
        try s.expectOp(")");
        return s.func(pos, lname_lit(lname), args.items);
    }
    if (eq(lname, "char")) {
        const args = try s.exprList();
        if (s.eatKw("USING")) _ = try s.anyName();
        try s.expectOp(")");
        return s.func(pos, "char", args);
    }
    if (eq(lname, "match")) {
        return s.fail("xqlite: {s}() is not supported", .{name_tok.text});
    }
    // JSON_TABLE is a FROM item only (json_table.zig).
    if (eq(lname, "json_table")) return s.syntaxErrorAt(name_tok);
    if (eq(lname, "json_arrayagg") or eq(lname, "json_objectagg")) return jsonAgg(s, pos, name_tok.text, eq(lname, "json_objectagg"));

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
    if (distinct and args.len > 1) {
        return s.fail("xqlite: {s}(DISTINCT ...) with several arguments is not supported", .{name_tok.text});
    }
    const over = try s.overClause();
    if (star or distinct or over != null) {
        // An aggregate or window function: as written (or renamed).
        const n: []const u8 = renames.get(lname) orelse name_tok.text;
        const name_pos: u32 = pos;
        return s.funcNode(pos, .{ .name = .{ .text = n, .pos = name_pos }, .args = args, .star = star, .distinct = distinct, .over = over });
    }
    return byNameAs(s, lname, args, pos, name_tok.text);
}

/// The static spelling of a lower-case name of call() (lname lives in a
/// stack buffer).
fn lname_lit(lname: []const u8) []const u8 {
    for ([_][]const u8{ "nextval", "lastval", "setval" }) |n| if (eq(lname, n)) return n;
    unreachable;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// MariaDB functions that are SQLite's (or an engine function) under
/// another name, taking the same arguments (case-insensitive).
pub const renames = std.StaticStringMapWithEql([]const u8, ctype.eqlNoCase).initComptime(.{
    .{ "ucase", "upper" },
    .{ "lcase", "lower" },
    .{ "length", "octet_length" },
    .{ "char_length", "length" },
    .{ "character_length", "length" },
    .{ "mid", "substr" },
    .{ "substring", "substr" },
    .{ "row_count", "changes" },
    .{ "std", "xq_stddev_pop" },
    .{ "stddev", "xq_stddev_pop" },
    .{ "stddev_pop", "xq_stddev_pop" },
    .{ "stddev_samp", "xq_stddev_samp" },
    .{ "variance", "xq_var_pop" },
    .{ "var_pop", "xq_var_pop" },
    .{ "var_samp", "xq_var_samp" },
    .{ "bit_length", "xq_bit_length" },
    .{ "rand", "xq_rand" },
    .{ "random", "xq_rand" },
    .{ "uuid", "xq_uuid" },
    .{ "uuid_short", "xq_uuid" },
    .{ "sys_guid", "xq_uuid" },
});

/// A function of MariaDB called `lname` (lower case) with `args`, at
/// `pos` (a niladic function).
pub fn byName(s: *Parser, lname: []const u8, args: []const *Expr, pos: u32) Error!*Expr {
    return byNameAs(s, lname, args, pos, lname);
}

fn isZero(e: *const Expr) bool {
    return e.kind == .integer and std.mem.eql(u8, e.kind.integer, "0");
}

/// byName(); `written` is the name as written (called as such when it
/// is nothing MariaDB-specific).
fn byNameAs(s: *Parser, lname: []const u8, args_in: []const *Expr, pos: u32, written: []const u8) Error!*Expr {
    const args = try s.a.dupe(*Expr, args_in);
    const n = args.len;
    if (renames.get(lname)) |to| return s.func(pos, to, args);
    if (std.mem.startsWith(u8, lname, "json_")) try jsonArgs(s, lname, args, written);
    if (eq(lname, "now") or eq(lname, "sysdate") or eq(lname, "current_timestamp") or
        eq(lname, "localtime") or eq(lname, "localtimestamp") or eq(lname, "utc_timestamp"))
    {
        if (n > 0 and !isZero(args[0])) {
            return s.func(pos, "strftime", &.{ try s.str(pos, "%Y-%m-%d %H:%M:%f"), try s.str(pos, "now") });
        }
        return s.func(pos, "datetime", &.{try s.str(pos, "now")});
    }
    if (eq(lname, "curdate") or eq(lname, "current_date") or eq(lname, "utc_date")) {
        return s.func(pos, "date", &.{try s.str(pos, "now")});
    }
    if (eq(lname, "curtime") or eq(lname, "current_time") or eq(lname, "utc_time")) {
        return s.func(pos, "time", &.{try s.str(pos, "now")});
    }
    if (eq(lname, "unix_timestamp")) {
        if (n == 0) return s.func(pos, "unixepoch", &.{try s.str(pos, "now")});
        return s.func(pos, "unixepoch", args);
    }
    if (eq(lname, "from_unixtime") and n == 1) {
        return s.func(pos, "datetime", &.{ args[0], try s.str(pos, "unixepoch") });
    }
    if (eq(lname, "last_insert_id") and n == 0) return s.func(pos, "last_insert_rowid", &.{});
    if (eq(lname, "database") or eq(lname, "schema")) {
        // The current database when the statement is compiled (USE
        // expires the prepared statements).
        const d = s.p.db.xq.mariadb.currentDatabase() orelse return s.mk(pos, .null);
        return s.str(pos, try s.a.dupe(u8, d));
    }
    if (eq(lname, "user") or eq(lname, "current_user") or eq(lname, "session_user") or eq(lname, "system_user")) {
        return s.str(pos, "root@localhost");
    }
    if (eq(lname, "connection_id")) return s.int_(pos, 1);
    if ((eq(lname, "greatest") or eq(lname, "least")) and n >= 2) {
        return s.func(pos, if (eq(lname, "greatest")) "max" else "min", args);
    }
    if (eq(lname, "isnull") and n == 1) return s.mk(pos, .{ .is_null = .{ .e = args[0], .not = false } });
    if (eq(lname, "locate") and n == 2) return s.func(pos, "instr", &.{ args[1], args[0] });
    if ((eq(lname, "date") or eq(lname, "time") or eq(lname, "timestamp")) and n == 1) {
        const to: []const u8 = if (eq(lname, "timestamp")) "datetime" else if (eq(lname, "date")) "date" else "time";
        return s.mk(pos, .{ .cast = .{ .e = args[0], .target_type = to, .mode = .{ .typed = .{ .func = "xq_cast", .type_arg = to } } } });
    }
    if (eq(lname, "mod") and n == 2) return s.mk(pos, .{ .binary = .{ .op = .rem, .l = args[0], .r = args[1] } });
    if (eq(lname, "concat") and n >= 2) {
        // NULL if an argument is.
        return s.mk(pos, .{ .concat = .{ .args = args, .null_policy = .propagate } });
    }
    // As written: a function of the dialect's table, a SQLite built-in
    // or an application function.
    return s.func(pos, written, args);
}

/// CAST/CONVERT's target type at the current token, applied to `e`.
fn castTo(s: *Parser, pos: u32, e: *Expr) Error!*Expr {
    if (s.tok.kind != .ident) return s.syntaxError();
    const t = s.tok;
    s.advance();
    var len: ?i64 = null;
    var scale: ?i64 = null;
    if (t.isKw("DOUBLE")) _ = s.eatKw("PRECISION");
    if (t.isKw("SIGNED") or t.isKw("UNSIGNED")) _ = s.eatKw("INTEGER") or s.eatKw("INT");
    if (t.isKw("CHARACTER") or t.isKw("NATIONAL")) _ = s.eatKw("CHAR") or s.eatKw("VARYING");
    if (s.eatOp("(")) {
        len = try intArg(s);
        if (s.eatOp(",")) scale = try intArg(s);
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
        const ty = k[1];
        if (len) |n| {
            if (std.mem.eql(u8, ty, "TEXT")) return s.mk(pos, .{ .cast = .{ .e = e, .target_type = t.text, .mode = .{ .truncate = n } } });
            if (std.mem.eql(u8, ty, "BLOB")) {
                const blob = try s.mk(pos, .{ .cast = .{ .e = e, .target_type = t.text, .mode = .{ .affinity = "BLOB" } } });
                return s.func(pos, "substr", &.{ blob, try s.int_(pos, 1), try s.int_(pos, n) });
            }
        }
        return s.mk(pos, .{ .cast = .{ .e = e, .target_type = t.text, .mode = .{ .affinity = ty } } });
    };
    if (t.isAnyKw(&.{ "DECIMAL", "DEC", "NUMERIC", "FIXED" })) {
        // round(e, scale), an integer without a scale.
        const real = try s.mk(pos, .{ .cast = .{ .e = e, .target_type = "DOUBLE", .mode = .{ .affinity = "REAL" } } });
        // The cast (a REAL already) keeps the type for the column
        // (ExprListItem.xq_type: 2.50, not 2.5).
        if (scale) |sc| if (sc > 0) {
            const spelling = try std.fmt.allocPrint(s.a, "DECIMAL({d},{d})", .{ len orelse 10, sc });
            return s.mk(pos, .{ .cast = .{ .e = try s.func(pos, "round", &.{ real, try s.int_(pos, sc) }), .target_type = spelling, .mode = .{ .affinity = "REAL" } } });
        };
        const r = try s.func(pos, "round", &.{real});
        return s.mk(pos, .{ .cast = .{ .e = r, .target_type = t.text, .mode = .{ .affinity = "INTEGER" } } });
    }
    if (t.isAnyKw(&.{ "DATE", "DATETIME", "TIME", "TIMESTAMP" })) {
        const to: []const u8 = if (t.isKw("DATE")) "date" else if (t.isKw("TIME")) "time" else "datetime";
        return s.mk(pos, .{ .cast = .{ .e = e, .target_type = t.text, .mode = .{ .typed = .{ .func = "xq_cast", .type_arg = to } } } });
    }
    return s.fail("xqlite: CAST to {s} is not supported", .{t.text});
}

fn intArg(s: *Parser) Error!i64 {
    if (s.tok.kind != .integer) return s.syntaxError();
    const v = std.fmt.parseInt(i64, s.tok.text, 10) catch return s.syntaxError();
    s.advance();
    return v;
}

/// TRIM([[BOTH|LEADING|TRAILING] [remstr] FROM] str).
fn trim(s: *Parser, pos: u32) Error!*Expr {
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
    return s.func(pos, func, &.{ str, rem orelse try s.str(pos, " ") });
}

/// GROUP_CONCAT([DISTINCT] expr [, expr ...] [ORDER BY ...]
/// [SEPARATOR str] [LIMIT n]): SQLite's group_concat() of the
/// concatenation of the expressions (NULL, so left out, if one is).
fn groupConcat(s: *Parser, pos: u32) Error!*Expr {
    var distinct = false;
    if (s.eatKw("DISTINCT")) distinct = true else _ = s.eatKw("ALL");
    const items = try s.exprList();
    var order: []tree.SortItem = &.{};
    if (s.isKw("ORDER")) {
        s.advance();
        try s.expectKw("BY");
        order = try s.sortList();
    }
    var sep: ?[]const u8 = null;
    if (s.eatKw("SEPARATOR")) sep = try s.stringLiteral();
    if (s.isKw("LIMIT")) return s.fail("xqlite: GROUP_CONCAT(... LIMIT) is not supported", .{});
    try s.expectOp(")");
    const value = if (items.len == 1) items[0] else try s.mk(pos, .{ .concat = .{ .args = items, .null_policy = .propagate } });
    var args: std.ArrayList(*Expr) = .empty;
    try args.append(s.a, value);
    if (sep) |z| {
        if (distinct and !std.mem.eql(u8, z, ",")) {
            return s.fail("xqlite: GROUP_CONCAT(DISTINCT ... SEPARATOR) is only supported with ','", .{});
        }
        if (!distinct) try args.append(s.a, try s.str(pos, z));
    }
    const over = try s.overClause();
    return s.funcNode(pos, .{ .name = .{ .text = "group_concat", .pos = pos }, .args = args.items, .distinct = distinct, .order_by = order, .over = over });
}

// ================================================================ JSON

/// The argument counts MariaDB allows its JSON functions: at least
/// `min`, at most `max` (null: any), and an odd or even count.
const JsonArity = struct { min: u8, max: ?u8 = null, parity: enum { any, odd, even } = .any };

const json_arity = std.StaticStringMap(JsonArity).initComptime(.{
    .{ "json_extract", JsonArity{ .min = 2 } },
    .{ "json_value", JsonArity{ .min = 2, .max = 2 } },
    .{ "json_query", JsonArity{ .min = 2, .max = 2 } },
    .{ "json_unquote", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_quote", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_object", JsonArity{ .min = 0, .parity = .even } },
    .{ "json_array", JsonArity{ .min = 0 } },
    .{ "json_contains", JsonArity{ .min = 2, .max = 3 } },
    .{ "json_contains_path", JsonArity{ .min = 3 } },
    .{ "json_exists", JsonArity{ .min = 2, .max = 2 } },
    .{ "json_keys", JsonArity{ .min = 1, .max = 2 } },
    .{ "json_length", JsonArity{ .min = 1, .max = 2 } },
    .{ "json_depth", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_type", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_valid", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_set", JsonArity{ .min = 3, .parity = .odd } },
    .{ "json_insert", JsonArity{ .min = 3, .parity = .odd } },
    .{ "json_replace", JsonArity{ .min = 3, .parity = .odd } },
    .{ "json_remove", JsonArity{ .min = 2 } },
    .{ "json_array_append", JsonArity{ .min = 3, .parity = .odd } },
    .{ "json_array_insert", JsonArity{ .min = 3, .parity = .odd } },
    .{ "json_merge", JsonArity{ .min = 2 } },
    .{ "json_merge_preserve", JsonArity{ .min = 2 } },
    .{ "json_merge_patch", JsonArity{ .min = 2 } },
    .{ "json_search", JsonArity{ .min = 3 } },
    .{ "json_compact", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_loose", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_detailed", JsonArity{ .min = 1, .max = 2 } },
    .{ "json_pretty", JsonArity{ .min = 1, .max = 2 } },
    .{ "json_equals", JsonArity{ .min = 2, .max = 2 } },
    .{ "json_normalize", JsonArity{ .min = 1, .max = 1 } },
    .{ "json_overlaps", JsonArity{ .min = 2, .max = 2 } },
});

/// Check the argument count of JSON function `lname` and mark the
/// arguments it takes as values (jsonValue()).
fn jsonArgs(s: *Parser, lname: []const u8, args: []*Expr, written: []const u8) Error!void {
    const ar = json_arity.get(lname) orelse return;
    const n = args.len;
    const ok = n >= ar.min and (ar.max == null or n <= ar.max.?) and switch (ar.parity) {
        .any => true,
        .odd => n % 2 == 1,
        .even => n % 2 == 0,
    };
    if (!ok) return s.failState(.numbered("42883", 1582), "Incorrect parameter count in the call to native function '{s}'", .{written});
    if (eq(lname, "json_array")) {
        for (args) |*a| try jsonValue(s, a);
    } else if (eq(lname, "json_object")) {
        var i: usize = 1;
        while (i < n) : (i += 2) try jsonValue(s, &args[i]);
    } else if (eq(lname, "json_set") or eq(lname, "json_insert") or eq(lname, "json_replace") or
        eq(lname, "json_array_append") or eq(lname, "json_array_insert"))
    {
        var i: usize = 2;
        while (i < n) : (i += 2) try jsonValue(s, &args[i]);
    }
}

/// A value a JSON function stores (JSON_OBJECT's values, JSON_ARRAY's
/// items ...): a boolean expression becomes true/false
/// (xq_maria_json_bool()), a column reference may be a JSON column
/// (Parser.json_args, json_table.markJsonColumns()).
fn jsonValue(s: *Parser, slot: **Expr) Error!void {
    const e = slot.*;
    if (e.kind == .func and e.kind.func.dialect != null and e.kind.func.args.len > 0 and isFormat(e.kind.func.name.text)) {
        // JSON_COMPACT(x) and the like give x itself, as written, to a
        // JSON function.
        slot.* = try s.func(e.pos, "xq_maria_json_col", &.{e.kind.func.args[0]});
        return;
    }
    if (isBoolean(e)) {
        slot.* = try s.func(e.pos, "xq_maria_json_bool", &.{e});
    } else if (e.kind == .column) {
        try s.json_args.append(s.a, e);
    } else if (e.kind == .subquery and returnsJson(e.kind.subquery)) {
        // The value of a subquery has lost the JSON subtype.
        slot.* = try s.func(e.pos, "xq_maria_json_col", &.{e});
    }
}

/// Whether the single column of query `sel` is a JSON function's.
fn returnsJson(sel: *const tree.Select) bool {
    const core = switch (sel.body.*) {
        .core => |c| c,
        else => return false,
    };
    if (core.cols.len != 1) return false;
    const e = switch (core.cols[0]) {
        .expr => |x| x.e,
        else => return false,
    };
    if (e.kind != .func or e.kind.func.dialect == null) return false;
    const returning = [_][]const u8{
        "json_extract",  "json_query",          "json_object",      "json_array",        "json_set",
        "json_insert",   "json_replace",        "json_remove",      "json_array_append", "json_array_insert",
        "json_merge",    "json_merge_preserve", "json_merge_patch", "json_compact",      "json_loose",
        "json_detailed", "json_pretty",         "json_normalize",   "json_arrayagg",     "json_objectagg",
        "json_search",
    };
    for (returning) |n| if (std.ascii.eqlIgnoreCase(e.kind.func.name.text, n)) return true;
    return false;
}

fn isFormat(name: []const u8) bool {
    for ([_][]const u8{ "json_compact", "json_loose", "json_detailed", "json_pretty" }) |f| {
        if (std.ascii.eqlIgnoreCase(name, f)) return true;
    }
    return false;
}

fn isBoolean(e: *const Expr) bool {
    return switch (e.kind) {
        .boolean, .compare, .like, .in_list, .in_select, .between, .is_null, .is_bool, .exists => true,
        .unary => |u| u.op == .not,
        .binary => |b| b.op == .@"and" or b.op == .@"or",
        else => false,
    };
}

/// An operand of a comparison: JSON_EXTRACT's value compares as its
/// SQL value (a string without its quotes), as in MariaDB.
pub fn jsonCompared(s: *Parser, e: *Expr) Error!*Expr {
    if (e.kind != .func) return e;
    const f = e.kind.func;
    if (f.dialect == null or !std.ascii.eqlIgnoreCase(f.name.text, "json_extract")) return e;
    return s.func(e.pos, "xq_maria_json_cmp", &.{e});
}

/// JSON_ARRAYAGG([DISTINCT] expr [ORDER BY ...]) and
/// JSON_OBJECTAGG(key, value).
fn jsonAgg(s: *Parser, pos: u32, written: []const u8, object: bool) Error!*Expr {
    var distinct = false;
    if (s.eatKw("DISTINCT")) distinct = true else _ = s.eatKw("ALL");
    const args = try s.exprList();
    if (args.len != @as(usize, if (object) 2 else 1)) return s.failState(.numbered("42883", 1582), "Incorrect parameter count in the call to native function '{s}'", .{written});
    var order: []tree.SortItem = &.{};
    if (!object and s.isKw("ORDER")) {
        s.advance();
        try s.expectKw("BY");
        order = try s.sortList();
    }
    var limit: ?*Expr = null;
    if (!object and s.eatKw("LIMIT")) limit = try s.expr();
    try s.expectOp(")");
    if (s.isKw("OVER")) {
        return s.failState(.numbered("0A000", 1235), "This version of MariaDB doesn't yet support '{s}() aggregate as window function'", .{if (object) "JSON_OBJECTAGG" else "JSON_ARRAYAGG"});
    }
    try jsonValue(s, &args[args.len - 1]);
    const name: []const u8 = if (object) "json_objectagg" else "json_arrayagg";
    // LIMIT n: json_arrayagg(value, n).
    const all = if (limit) |l| try s.a.dupe(*Expr, &.{ args[0], l }) else args;
    return s.funcNode(pos, .{ .name = .{ .text = name, .pos = pos }, .args = all, .distinct = distinct, .order_by = order });
}
