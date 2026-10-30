//! DDL: CREATE/DROP TABLE, INDEX, VIEW, SEQUENCE, ALTER TABLE, RENAME
//! TABLE, as tree statements: src/ir/lower.zig renders them as SQLite
//! text (src/ir/render.zig) and records the dialect and the declared
//! types in xq_catalog in the same statement; this file adds what is
//! MariaDB's (the indexes of CREATE TABLE, AUTO_INCREMENT=n, the catalog
//! keys of SHOW COLUMNS) and MariaDB's checks and messages.
//!
//!     CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY,
//!                     name VARCHAR(20) NOT NULL, KEY (name))
//!     -->
//!     CREATE TABLE "t"("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
//!                      "name" TEXT NOT NULL COLLATE NOCASE) STRICT
//!     CREATE INDEX "main"."t$name" ON "t"("name")   (run by OP_SqlExec)
//!     xq_catalog: t||dialect|mariadb, t|id|type|int(11),
//!                 t|id|mariadb.auto_increment|1, t|name|type|varchar(20)
//!
//!  - Storage types: types.Type.storageType(); the table is STRICT.
//!  - Every character column gets an explicit COLLATE (NOCASE for the
//!    default and *_ci collations, BINARY for *_bin, binary and *_cs):
//!    so do the indexes on it, and unique keys are case-insensitive as in
//!    MariaDB. Other TEXT-stored types (dates, JSON) are BINARY.
//!  - AUTO_INCREMENT is SQLite's INTEGER PRIMARY KEY AUTOINCREMENT
//!    (sqlite_sequence): the column must be the PRIMARY KEY (or a UNIQUE
//!    key of a table without one). AUTO_INCREMENT=n primes
//!    sqlite_sequence. An explicit larger value moves the counter, as in
//!    MariaDB; deleted values are not reused.
//!  - Index names are per table in MariaDB and per schema in SQLite: a
//!    MariaDB index `i` of table `t` is the SQLite index "t$i". KEY,
//!    INDEX and UNIQUE definitions become CREATE INDEX statements run
//!    (OP_SqlExec) after the table is created, in the same statement.
//!    RENAME TABLE (and ALTER TABLE ... RENAME) renames them with the
//!    table: "t$i" becomes "u$i" (renameTable()).
//!  - DEFAULT, CHECK and generated-column expressions and the query of a
//!    view are tree expressions, rendered by the IR as lowering means
//!    them (DIV, XOR, ^, INTERVAL, the dialect's functions ...). A
//!    column's CHECK is named after the column, an unnamed table CHECK
//!    CONSTRAINT_<n>, as MariaDB names them. Variables and parameters are
//!    refused there (Parser.stored).
//!  - Table options (ENGINE, CHARSET, COLLATE, COMMENT, ROW_FORMAT ...)
//!    are accepted; DEFAULT COLLATE/CHARSET set the columns' default.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const tree = @import("../../ir/tree.zig");
const render = @import("../../ir/render.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const types = @import("types.zig");
const session = @import("session.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Token = lexer.Token;
const Expr = tree.Expr;
const Name = tree.Name;
const Q = session.Q;
const Writer = std.Io.Writer;

const Column = struct {
    name: Name,
    type: types.Type,
    not_null: bool = false,
    explicit_null: bool = false,
    /// The DEFAULT expression, and how SHOW COLUMNS shows it.
    default: ?*Expr = null,
    default_shown: ?[]const u8 = null,
    autoinc: bool = false,
    primary: bool = false,
    unique: bool = false,
    /// The SQLite collation, and the MariaDB name if one was given.
    collation: ?[:0]const u8 = null,
    collation_name: ?[]const u8 = null,
    checks: std.ArrayList(Check) = .empty,
    generated: ?*Expr = null,
    stored: bool = false,
    on_update: bool = false,
    json: bool = false,
};

const Check = struct { name: ?[]const u8, e: *Expr };

const IndexDef = struct {
    name: ?[]const u8,
    unique: bool,
    cols: []const IndexCol,
};

const IndexCol = struct { name: Name, desc: bool };

const Table = struct {
    columns: std.ArrayList(Column) = .empty,
    primary: ?[]const IndexCol = null,
    indexes: std.ArrayList(IndexDef) = .empty,
    checks: std.ArrayList(Check) = .empty,
    fkeys: std.ArrayList(tree.TableConstraint) = .empty,
    default_collation: ?[:0]const u8 = null,
    default_collation_name: ?[]const u8 = null,
    auto_increment_start: ?i64 = null,
    /// The unnamed table CHECKs so far (named CONSTRAINT_<n>).
    n_unnamed_checks: usize = 0,
};

fn lowered(err: render.Error) Error {
    return parser.lowered(err);
}

// ====================================================== CREATE TABLE

pub fn createTable(s: *Parser, temp: bool, or_replace: bool) Error!void {
    try s.expectKw("TABLE");
    const if_not_exists = try s.ifNotExists();
    const q = try s.qualifiedName();
    const name = q.name.text;
    const schema: []const u8 = if (temp) "temp" else if (q.schema) |x| x.text else "main";
    if (build.findDbName(s.p.db, schema) == null) return s.fail("Unknown database '{s}'", .{schema});
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (or_replace) return s.fail("xqlite: CREATE OR REPLACE TABLE is not supported (use DROP TABLE IF EXISTS)", .{});
    const tname: tree.QName = if (temp) .{ .name = q.name } else .{ .schema = .{ .text = schema, .pos = q.name.pos }, .name = q.name };

    if (s.isKw("LIKE") or (s.isOp("(") and s.peek().isKw("LIKE"))) {
        return s.fail("xqlite: CREATE TABLE ... LIKE is not supported", .{});
    }
    if (!s.isOp("(")) {
        // CREATE TABLE t [AS] SELECT ...: SQLite's CREATE TABLE AS.
        try tableOptions(s, null);
        _ = s.eatKw("AS");
        if (!s.isSelectStart()) return s.syntaxError();
        const sel = try s.selectStmt();
        return s.lowerStmt(.{ .create_table = try s.new(tree.CreateTable, .{ .temp = temp, .if_not_exists = if_not_exists, .name = tname, .as_select = sel }) });
    }
    try s.expectOp("(");
    var t: Table = .{};
    while (true) {
        try createDefinition(s, &t);
        if (!s.eatOp(",")) break;
    }
    try s.expectOp(")");
    try tableOptions(s, &t);
    if (s.isKw("PARTITION")) return s.fail("xqlite: PARTITION BY is not supported", .{});
    if (s.isSelectStart() or s.isKw("AS")) return s.fail("xqlite: CREATE TABLE with columns and a SELECT is not supported", .{});

    if (if_not_exists and build.findTable(s.p.db, name, schema) != null) {
        // Nothing to do (MariaDB adds a note).
        s.p.db.xq.mariadb.warn(.note, 1050, "Table '{s}' already exists", .{name});
        return session.emptyStatement(s);
    }
    try finishTable(s, &t);
    const ct = try tableTree(s, &t, tname, temp);
    try s.lowerStmt(.{ .create_table = ct });
    try codeTableExtras(s, &t, schema, name);
}

fn isTableConstraintStart(s: *Parser) bool {
    if (s.tok.kind != .ident) return false;
    const kws = [_][]const u8{ "PRIMARY", "UNIQUE", "KEY", "INDEX", "FULLTEXT", "SPATIAL", "CONSTRAINT", "FOREIGN", "CHECK", "PERIOD" };
    for (kws) |k| if (s.isKw(k)) {
        // `key INT` is a column called key.
        if ((s.isKw("KEY") or s.isKw("INDEX")) and !(s.peek().is("(") or s.peek().kind == .ident or s.peek().kind == .quoted_ident)) return false;
        return true;
    };
    return false;
}

fn createDefinition(s: *Parser, t: *Table) Error!void {
    if (!isTableConstraintStart(s)) return columnDefinition(s, t);
    var constraint: ?[]const u8 = null;
    if (s.eatKw("CONSTRAINT")) {
        if (s.isName()) constraint = try s.nameText(try s.name());
    }
    if (s.eatKw("PRIMARY")) {
        try s.expectKw("KEY");
        try indexType(s);
        if (t.primary != null) return s.fail("Multiple primary key defined", .{});
        t.primary = try indexColumns(s);
        try indexOptions(s);
        return;
    }
    if (s.eatKw("UNIQUE")) {
        _ = s.eatKw("KEY") or s.eatKw("INDEX");
        var name: ?[]const u8 = constraint;
        if (s.isName()) name = try s.nameText(try s.name());
        try indexType(s);
        try t.indexes.append(s.a, .{ .name = name, .unique = true, .cols = try indexColumns(s) });
        try indexOptions(s);
        return;
    }
    if (s.eatKw("FULLTEXT") or s.eatKw("SPATIAL")) {
        _ = s.eatKw("KEY") or s.eatKw("INDEX");
        // An ordinary index (MATCH ... AGAINST is not supported).
    } else if (s.eatKw("KEY") or s.eatKw("INDEX")) {} else if (s.eatKw("FOREIGN")) {
        try s.expectKw("KEY");
        if (s.isName()) _ = try s.name();
        const cols = try s.nameList();
        const ref = try references(s);
        try t.fkeys.append(s.a, .{ .name = constraint, .kind = .{ .foreign_key = .{ .cols = cols, .ref = ref } } });
        return;
    } else if (s.eatKw("CHECK")) {
        const n = constraint orelse blk: {
            t.n_unnamed_checks += 1;
            break :blk try std.fmt.allocPrint(s.a, "CONSTRAINT_{d}", .{t.n_unnamed_checks});
        };
        try t.checks.append(s.a, .{ .name = n, .e = try checkExpr(s, n) });
        return;
    } else if (s.isKw("PERIOD")) {
        return s.fail("xqlite: PERIOD FOR is not supported", .{});
    } else return s.syntaxError();
    var name: ?[]const u8 = null;
    if (s.isName() and !s.isKw("USING")) name = try s.nameText(try s.name());
    try indexType(s);
    try t.indexes.append(s.a, .{ .name = name, .unique = false, .cols = try indexColumns(s) });
    try indexOptions(s);
}

fn indexType(s: *Parser) Error!void {
    if (s.eatKw("USING")) _ = try s.anyName();
}

fn indexOptions(s: *Parser) Error!void {
    while (true) {
        if (s.eatKw("USING")) {
            _ = try s.anyName();
        } else if (s.eatKw("COMMENT")) {
            _ = try s.stringLiteral();
        } else if (s.eatKw("KEY_BLOCK_SIZE")) {
            _ = s.eatOp("=");
            s.advance();
        } else if (s.eatKw("VISIBLE") or s.eatKw("INVISIBLE") or s.eatKw("CLUSTERING")) {} else if (s.isKw("IGNORED") or s.isKw("NOT")) {
            if (s.eatKw("NOT")) {}
            try s.expectKw("IGNORED");
        } else break;
    }
}

/// `(col [(len)] [ASC|DESC], ...)`.
fn indexColumns(s: *Parser) Error![]const IndexCol {
    try s.expectOp("(");
    var cols: std.ArrayList(IndexCol) = .empty;
    while (true) {
        const n = try s.nameOf(try s.anyName());
        if (s.eatOp("(")) {
            // A prefix length: the whole value is indexed.
            if (s.tok.kind != .integer) return s.syntaxError();
            s.advance();
            try s.expectOp(")");
        }
        var desc = false;
        if (s.eatKw("DESC")) {
            desc = true;
        } else _ = s.eatKw("ASC");
        try cols.append(s.a, .{ .name = n, .desc = desc });
        if (!s.eatOp(",")) break;
    }
    try s.expectOp(")");
    return cols.items;
}

/// REFERENCES t [(cols)] [MATCH ...] [ON DELETE a] [ON UPDATE a].
fn references(s: *Parser) Error!tree.Ref {
    try s.expectKw("REFERENCES");
    const q = try s.qualifiedName();
    if (q.schema != null) return s.fail("xqlite: a foreign key to a table of another database is not supported", .{});
    var ref: tree.Ref = .{ .table = q.name };
    if (s.isOp("(")) ref.cols = try s.nameList();
    while (true) {
        if (s.eatKw("MATCH")) {
            _ = try s.anyName();
        } else if (s.eatKw("ON")) {
            const on_delete = if (s.eatKw("DELETE")) true else if (s.eatKw("UPDATE")) false else return s.syntaxError();
            const action: tree.RefAction = if (s.eatKw("CASCADE"))
                .cascade
            else if (s.eatKw("RESTRICT"))
                .restrict
            else if (s.eatKw("SET")) blk: {
                if (s.eatKw("NULL")) break :blk .set_null;
                try s.expectKw("DEFAULT");
                break :blk .set_default;
            } else if (s.eatKw("NO")) blk: {
                try s.expectKw("ACTION");
                break :blk .none;
            } else return s.syntaxError();
            if (on_delete) ref.on_delete = action else ref.on_update = action;
        } else break;
    }
    return ref;
}

/// An expression the schema keeps, parsed with Parser.stored.
fn storedExpr(s: *Parser, clause: []const u8, name: []const u8) Error!*Expr {
    const saved = s.stored;
    defer s.stored = saved;
    s.stored = .{ .clause = clause, .name = name };
    return s.expr();
}

/// `( expr )` of CHECK.
fn checkExpr(s: *Parser, name: []const u8) Error!*Expr {
    try s.expectOp("(");
    const e = try storedExpr(s, "CHECK", name);
    try s.expectOp(")");
    return e;
}

fn columnDefinition(s: *Parser, t: *Table) Error!void {
    const name = try s.nameOf(try s.name());
    var c: Column = .{ .name = name, .type = undefined };
    c.type = try columnType(s, &c);
    if (c.type.base == .longtext and c.json) {
        const ref = try tree.expr(s.a, name.pos, name.pos, .{ .column = try s.a.dupe(Name, &.{name}) });
        try c.checks.append(s.a, .{ .name = name.text, .e = try s.func(name.pos, "json_valid", &.{ref}) });
    }
    // Attributes, in any order.
    while (true) {
        if (s.eatKw("NOT")) {
            try s.expectKw("NULL");
            c.not_null = true;
        } else if (s.eatKw("NULL")) {
            c.explicit_null = true;
        } else if (s.eatKw("DEFAULT")) {
            try defaultValue(s, &c);
        } else if (s.eatKw("AUTO_INCREMENT")) {
            c.autoinc = true;
        } else if (s.eatKw("PRIMARY")) {
            try s.expectKw("KEY");
            c.primary = true;
        } else if (s.eatKw("UNIQUE")) {
            _ = s.eatKw("KEY");
            c.unique = true;
        } else if (s.eatKw("KEY")) {
            c.primary = true;
        } else if (s.eatKw("COMMENT")) {
            _ = try s.stringLiteral();
        } else if (s.eatKw("COLLATE")) {
            const t0 = s.tok;
            c.collation = try s.collationName();
            c.collation_name = try collName(s, t0);
        } else if (s.isKw("CHARACTER") or s.isKw("CHARSET")) {
            try charsetClause(s, &c);
        } else if (s.eatKw("CONSTRAINT")) {
            var cname: []const u8 = name.text;
            if (s.isName()) cname = try s.nameText(try s.name());
            try s.expectKw("CHECK");
            try c.checks.append(s.a, .{ .name = cname, .e = try checkExpr(s, cname) });
        } else if (s.eatKw("CHECK")) {
            try c.checks.append(s.a, .{ .name = name.text, .e = try checkExpr(s, name.text) });
        } else if (s.isKw("GENERATED") or s.isKw("AS")) {
            if (s.eatKw("GENERATED")) {
                try s.expectKw("ALWAYS");
            }
            try s.expectKw("AS");
            try s.expectOp("(");
            c.generated = try storedExpr(s, "GENERATED ALWAYS AS", name.text);
            try s.expectOp(")");
            if (s.eatKw("STORED") or s.eatKw("PERSISTENT")) {
                c.stored = true;
            } else _ = s.eatKw("VIRTUAL");
        } else if (s.eatKw("ON")) {
            try s.expectKw("UPDATE");
            if (!(s.eatKw("CURRENT_TIMESTAMP") or s.eatKw("NOW") or s.eatKw("LOCALTIMESTAMP") or s.eatKw("LOCALTIME"))) return s.syntaxError();
            if (s.eatOp("(")) {
                if (s.tok.kind == .integer) s.advance();
                try s.expectOp(")");
            }
            c.on_update = true;
        } else if (s.isKw("REFERENCES")) {
            // MariaDB ignores a column's REFERENCES.
            _ = try references(s);
        } else if (s.eatKw("INVISIBLE")) {
            return s.fail("xqlite: INVISIBLE columns are not supported", .{});
        } else if (s.eatKw("COLUMN_FORMAT") or s.eatKw("STORAGE")) {
            _ = try s.anyName();
        } else if (s.eatKw("SERIAL")) {
            try s.expectKw("DEFAULT");
            try s.expectKw("VALUE");
            c.not_null = true;
            c.autoinc = true;
            c.unique = true;
        } else break;
    }
    if (c.primary or c.autoinc) c.not_null = true;
    try t.columns.append(s.a, c);
}

fn collName(s: *Parser, t: Token) Error![]const u8 {
    if (t.kind == .string) return lexer.stringValue(s.a, t, false);
    return s.nameText(t);
}

/// CHARACTER SET x / CHARSET x: the charset's default collation.
fn charsetClause(s: *Parser, c: *Column) Error!void {
    if (s.eatKw("CHARACTER")) try s.expectKw("SET") else s.advance();
    const t0 = s.tok;
    if (t0.kind != .ident and t0.kind != .quoted_ident and t0.kind != .string) return s.syntaxError();
    s.advance();
    const cs = try collName(s, t0);
    if (c.collation == null) {
        c.collation = parser.charsetCollation(cs) orelse return s.fail("Unknown character set: '{s}'", .{cs});
    }
}

/// The type of a column definition (and its type attributes).
fn columnType(s: *Parser, c: *Column) Error!types.Type {
    const t0 = s.tok;
    if (t0.kind != .ident) return s.syntaxError();
    s.advance();
    var ty: types.Type = undefined;
    const W = struct {
        fn is(t: Token, w: []const u8) bool {
            return t.isKw(w);
        }
    };
    if (W.is(t0, "SERIAL")) {
        c.autoinc = true;
        c.not_null = true;
        c.unique = true;
        return .{ .base = .bigint, .unsigned = true };
    }
    if (W.is(t0, "BOOL") or W.is(t0, "BOOLEAN")) return .{ .base = .tinyint, .len = 1 };
    if (W.is(t0, "JSON")) {
        c.json = true;
        c.collation = "BINARY";
        return .{ .base = .longtext };
    }
    const aliases = [_]struct { []const u8, types.Base }{
        .{ "INT1", .tinyint },         .{ "INT2", .smallint },    .{ "INT3", .mediumint }, .{ "MIDDLEINT", .mediumint },
        .{ "INTEGER", .int },          .{ "INT4", .int },         .{ "INT8", .bigint },    .{ "DEC", .decimal },
        .{ "NUMERIC", .decimal },      .{ "FIXED", .decimal },    .{ "NUMBER", .decimal }, .{ "REAL", .double },
        .{ "FLOAT4", .float },         .{ "FLOAT8", .double },    .{ "CHARACTER", .char }, .{ "NCHAR", .char },
        .{ "NVARCHAR", .varchar },     .{ "VARCHAR2", .varchar }, .{ "NATIONAL", .char },  .{ "LONG", .mediumtext },
        .{ "VARCHARACTER", .varchar }, .{ "CLOB", .longtext },    .{ "RAW", .varbinary },
    };
    var base: ?types.Base = null;
    for (aliases) |al| if (W.is(t0, al[0])) {
        base = al[1];
    };
    if (base == null) base = types.baseByName(t0.text);
    var b = base orelse return s.fail("xqlite: unknown data type '{s}'", .{t0.text});
    // Two-word types.
    if (W.is(t0, "DOUBLE")) _ = s.eatKw("PRECISION");
    if (W.is(t0, "NATIONAL")) {
        if (s.eatKw("VARCHAR")) {
            b = .varchar;
        } else if (!(s.eatKw("CHAR") or s.eatKw("CHARACTER"))) return s.syntaxError();
    }
    if (b == .char and (s.eatKw("VARYING"))) b = .varchar;
    if (W.is(t0, "LONG")) {
        if (s.eatKw("VARBINARY")) b = .mediumblob else _ = s.eatKw("VARCHAR");
    }
    if (b == .char and s.eatKw("BYTE")) b = .binary;
    ty = .{ .base = b };
    if (b == .@"enum" or b == .set) {
        try s.expectOp("(");
        var members: std.ArrayList([]const u8) = .empty;
        while (true) {
            try members.append(s.a, try s.stringLiteral());
            if (!s.eatOp(",")) break;
        }
        try s.expectOp(")");
        ty.members = members.items;
    } else if (s.eatOp("(")) {
        ty.len = try intArg(s);
        if (s.eatOp(",")) ty.scale = try intArg(s);
        try s.expectOp(")");
    }
    // TEXT(n) and BLOB(n) pick the smallest type that holds n bytes.
    if ((b == .text or b == .blob) and ty.len != null) {
        const n = ty.len.?;
        const small: types.Base = if (b == .text) .tinytext else .tinyblob;
        const big: types.Base = if (b == .text) .mediumtext else .mediumblob;
        const huge: types.Base = if (b == .text) .longtext else .longblob;
        ty.base = if (n <= 255) small else if (n <= 65535) b else if (n <= 16777215) big else huge;
        ty.len = null;
    }
    if (b == .float and ty.len != null and ty.scale == null) {
        // FLOAT(p): FLOAT up to 24 bits of precision, DOUBLE beyond.
        if (ty.len.? > 24) ty.base = .double;
        ty.len = null;
    }
    if (b == .varchar or b == .varbinary) {
        if (ty.len == null) return s.syntaxError();
    }
    if (b == .decimal) {
        if (ty.len) |p| if (p > 65) return s.fail("Too big precision specified for '{s}'. Maximum is 65", .{c.name.text});
        if (ty.scale) |sc| {
            if (sc > 38) return s.fail("Too big scale specified for '{s}'. Maximum is 38", .{c.name.text});
            if (sc > (ty.len orelse 10)) return s.fail("For float(M,D), double(M,D) or decimal(M,D), M must be >= D (column '{s}')", .{c.name.text});
        }
    }
    while (true) {
        if (s.eatKw("UNSIGNED")) {
            ty.unsigned = true;
        } else if (s.eatKw("SIGNED")) {} else if (s.eatKw("ZEROFILL")) {
            ty.zerofill = true;
            ty.unsigned = true;
        } else if (s.isKw("BINARY") and ty.base.isString()) {
            s.advance();
            c.collation = "BINARY";
        } else if (s.isKw("CHARACTER") or s.isKw("CHARSET")) {
            try charsetClause(s, c);
        } else if (s.eatKw("ASCII") or s.eatKw("UNICODE")) {} else break;
    }
    if (ty.base == .tinyint and b == .tinyint and W.is(t0, "BOOL")) ty.len = 1;
    return ty;
}

/// The data type of a JSON_TABLE column (json_table.zig) and whether it
/// is JSON.
pub fn dataType(s: *Parser, name: Name) Error!struct { types.Type, bool } {
    var c: Column = .{ .name = name, .type = undefined };
    const ty = try columnType(s, &c);
    if (s.eatKw("COLLATE")) _ = try s.collationName();
    return .{ ty, c.json };
}

fn intArg(s: *Parser) Error!u32 {
    if (s.tok.kind != .integer) return s.syntaxError();
    const v = std.fmt.parseInt(u32, s.tok.text, 10) catch return s.syntaxError();
    s.advance();
    return v;
}

/// DEFAULT literal | (expr) | CURRENT_TIMESTAMP[(n)] | NOW() ...
fn defaultValue(s: *Parser, c: *Column) Error!void {
    const t = s.tok;
    const pos = s.here();
    if (t.isAnyKw(&.{ "CURRENT_TIMESTAMP", "NOW", "LOCALTIMESTAMP", "LOCALTIME" })) {
        s.advance();
        if (s.eatOp("(")) {
            if (s.tok.kind == .integer) s.advance();
            try s.expectOp(")");
        }
        c.default = try s.func(pos, "datetime", &.{try s.str(pos, "now")});
        c.default_shown = "current_timestamp()";
        return;
    }
    if (t.isKw("CURRENT_DATE") or t.isKw("CURDATE")) {
        s.advance();
        if (s.eatOp("(")) try s.expectOp(")");
        c.default = try s.func(pos, "date", &.{try s.str(pos, "now")});
        c.default_shown = "curdate()";
        return;
    }
    if (t.isKw("NULL")) {
        s.advance();
        return;
    }
    if (t.isKw("TRUE") or t.isKw("FALSE")) {
        s.advance();
        const v: []const u8 = if (t.isKw("TRUE")) "1" else "0";
        c.default = try s.mk(pos, .{ .integer = v });
        c.default_shown = v;
        return;
    }
    if (t.kind == .string or (t.kind == .ident and t.text[0] == '_' and s.peek().kind == .string)) {
        const v = try s.stringLiteral();
        c.default = try s.mk(pos, .{ .string = v });
        c.default_shown = v;
        return;
    }
    if (s.isOp("(")) {
        s.advance();
        const start = s.here();
        const e = try storedExpr(s, "DEFAULT", c.name.text);
        const end = s.endPos();
        try s.expectOp(")");
        c.default = e;
        c.default_shown = s.lx.sql[start..end];
        return;
    }
    // A number, maybe signed; hex and bit literals.
    var neg = false;
    if (s.eatOp("-")) {
        neg = true;
    } else _ = s.eatOp("+");
    const n = s.tok;
    switch (n.kind) {
        .integer, .float => {
            s.advance();
            const lit = try s.mk(s.posOf(n), if (n.kind == .integer) .{ .integer = n.text } else .{ .float = n.text });
            c.default = if (neg) try s.mk(pos, .{ .unary = .{ .op = .neg, .e = lit } }) else lit;
            c.default_shown = try std.fmt.allocPrint(s.a, "{s}{s}", .{ if (neg) "-" else "", n.text });
        },
        .hex => {
            s.advance();
            const d = (try lexer.hexDigits(s.a, n)) orelse return s.syntaxErrorAt(n);
            c.default = try s.mk(pos, .{ .blob = d });
            c.default_shown = n.text;
        },
        .bit => {
            s.advance();
            const v = lexer.bitValue(n) orelse 0;
            c.default = try s.int_(pos, v);
            c.default_shown = try std.fmt.allocPrint(s.a, "{d}", .{v});
        },
        else => return s.syntaxError(),
    }
}

fn tableOptions(s: *Parser, t: ?*Table) Error!void {
    while (!s.atStmtEnd() and !s.isKw("PARTITION") and !s.isKw("AS") and !s.isSelectStart()) {
        _ = s.eatKw("DEFAULT");
        if (s.isKw("CHARACTER") or s.isKw("CHARSET")) {
            if (s.eatKw("CHARACTER")) try s.expectKw("SET") else s.advance();
            _ = s.eatOp("=");
            const t0 = s.tok;
            s.advance();
            const cs = try collName(s, t0);
            const coll = parser.charsetCollation(cs) orelse return s.fail("Unknown character set: '{s}'", .{cs});
            if (t) |tt| if (tt.default_collation_name == null) {
                tt.default_collation = coll;
            };
        } else if (s.eatKw("COLLATE")) {
            _ = s.eatOp("=");
            const t0 = s.tok;
            const coll = try s.collationName();
            if (t) |tt| {
                tt.default_collation = coll;
                tt.default_collation_name = try collName(s, t0);
            }
        } else if (s.eatKw("AUTO_INCREMENT")) {
            _ = s.eatOp("=");
            if (s.tok.kind != .integer) return s.syntaxError();
            const v = std.fmt.parseInt(i64, s.tok.text, 10) catch return s.syntaxError();
            s.advance();
            if (t) |tt| tt.auto_increment_start = v;
        } else if (s.tok.kind == .ident) {
            // ENGINE=x, COMMENT='x', ROW_FORMAT=x, ...: accepted.
            s.advance();
            _ = s.eatOp("=");
            switch (s.tok.kind) {
                .ident, .quoted_ident, .string, .integer, .float => s.advance(),
                else => return s.syntaxError(),
            }
        } else return s.syntaxError();
        _ = s.eatOp(",");
    }
}

/// Check the definition and apply the table-level defaults.
fn finishTable(s: *Parser, t: *Table) Error!void {
    if (t.columns.items.len == 0) return s.syntaxError();
    // The column-level PRIMARY KEY.
    for (t.columns.items) |*c| if (c.primary) {
        if (t.primary != null) return s.fail("Multiple primary key defined", .{});
        t.primary = try s.a.dupe(IndexCol, &.{.{ .name = c.name, .desc = false }});
    };
    for (t.columns.items) |*c| {
        if (c.collation == null and c.type.hasCollation()) c.collation = t.default_collation;
        if (c.collation == null and c.type.base.isString()) c.collation = "NOCASE";
        if (c.collation == null and c.type.storageType()[0] == 'T') c.collation = "BINARY";
        if (!c.type.hasCollation() and !c.json) c.collation_name = null;
        if (t.default_collation_name != null and c.collation_name == null and c.type.hasCollation()) {
            c.collation_name = t.default_collation_name;
        }
        if (t.primary) |pk| for (pk) |k| {
            if (std.ascii.eqlIgnoreCase(k.name.text, c.name.text)) c.not_null = true;
        };
        if (findColumn(t, c.name.text) != c) return s.fail("Duplicate column name '{s}'", .{c.name.text});
    }
    // Keys refer to existing columns.
    for (t.indexes.items) |ix| for (ix.cols) |k| {
        if (findColumn(t, k.name.text) == null) return s.fail("Key column '{s}' doesn't exist in table", .{k.name.text});
    };
    if (t.primary) |pk| for (pk) |k| {
        if (findColumn(t, k.name.text) == null) return s.fail("Key column '{s}' doesn't exist in table", .{k.name.text});
    };
    // AUTO_INCREMENT: the rowid.
    var n_auto: usize = 0;
    for (t.columns.items) |*c| {
        if (!c.autoinc) continue;
        n_auto += 1;
        if (!c.type.base.isInteger()) return s.fail("Incorrect column specifier for column '{s}'", .{c.name.text});
        const is_pk = if (t.primary) |pk| pk.len == 1 and std.ascii.eqlIgnoreCase(pk[0].name.text, c.name.text) else false;
        if (!is_pk) {
            var unique = c.unique;
            for (t.indexes.items) |ix| unique = unique or (ix.unique and ix.cols.len == 1 and std.ascii.eqlIgnoreCase(ix.cols[0].name.text, c.name.text));
            if (t.primary != null or !unique) {
                return s.fail("xqlite: an AUTO_INCREMENT column must be the PRIMARY KEY (or the only UNIQUE key of a table without one)", .{});
            }
            t.primary = try s.a.dupe(IndexCol, &.{.{ .name = c.name, .desc = false }});
            c.unique = false;
        }
    }
    if (n_auto > 1) return s.fail("Incorrect table definition; there can be only one auto column and it must be defined as a key", .{});
    // Unique columns become named unique indexes.
    for (t.columns.items) |*c| if (c.unique) {
        try t.indexes.append(s.a, .{ .name = c.name.text, .unique = true, .cols = try s.a.dupe(IndexCol, &.{.{ .name = c.name, .desc = false }}) });
    };
    // Unnamed indexes are named after their first column.
    for (t.indexes.items, 0..) |*ix, i| {
        if (ix.name != null) continue;
        const first = ix.cols[0].name.text;
        var n = first;
        var k: usize = 2;
        while (indexNameUsed(t.indexes.items[0..i], n)) : (k += 1) n = try std.fmt.allocPrint(s.a, "{s}_{d}", .{ first, k });
        ix.name = n;
    }
    for (t.indexes.items, 0..) |ix, i| {
        if (indexNameUsed(t.indexes.items[0..i], ix.name.?) or std.ascii.eqlIgnoreCase(ix.name.?, "PRIMARY")) {
            return s.fail("Duplicate key name '{s}'", .{ix.name.?});
        }
    }
}

fn indexNameUsed(ixs: []const IndexDef, n: []const u8) bool {
    for (ixs) |ix| if (ix.name) |m| if (std.ascii.eqlIgnoreCase(m, n)) return true;
    return false;
}

fn findColumn(t: *Table, n: []const u8) ?*Column {
    for (t.columns.items) |*c| if (std.ascii.eqlIgnoreCase(c.name.text, n)) return c;
    return null;
}

/// The PRIMARY KEY column if it is a single integer column (the rowid).
fn rowidColumn(t: *Table) ?*Column {
    const pk = t.primary orelse return null;
    if (pk.len != 1 or pk[0].desc) return null;
    const c = findColumn(t, pk[0].name.text) orelse return null;
    return if (c.type.base.isInteger() and c.generated == null) c else null;
}

/// The tree of the SQLite CREATE TABLE of `t`.
fn tableTree(s: *Parser, t: *Table, name: tree.QName, temp: bool) Error!*tree.CreateTable {
    const rowid = rowidColumn(t);
    var cols: std.ArrayList(tree.ColumnDef) = .empty;
    for (t.columns.items) |*c| try cols.append(s.a, try columnTree(s, c, c == rowid));
    var cons: std.ArrayList(tree.TableConstraint) = .empty;
    if (t.primary) |pk| if (rowid == null) {
        var names: std.ArrayList(Name) = .empty;
        for (pk) |k| try names.append(s.a, k.name);
        try cons.append(s.a, .{ .kind = .{ .primary_key = names.items } });
    };
    for (t.checks.items) |ck| try cons.append(s.a, .{ .name = ck.name, .kind = .{ .check = ck.e } });
    try cons.appendSlice(s.a, t.fkeys.items);
    return s.new(tree.CreateTable, .{ .temp = temp, .name = name, .columns = cols.items, .constraints = cons.items, .strict = true });
}

/// A column of the SQLite CREATE TABLE (or ALTER TABLE ADD COLUMN).
fn columnTree(s: *Parser, c: *const Column, rowid: bool) Error!tree.ColumnDef {
    var cons: std.ArrayList(tree.ColConstraint) = .empty;
    if (c.not_null) try cons.append(s.a, .{ .kind = .not_null });
    if (rowid) try cons.append(s.a, .{ .kind = .{ .primary_key = .{ .autoincrement = c.autoinc } } });
    if (c.default) |d| try cons.append(s.a, .{ .kind = .{ .default = d } });
    if (c.collation) |coll| try cons.append(s.a, .{ .kind = .{ .collate = coll } });
    for (c.checks.items) |ck| try cons.append(s.a, .{ .name = ck.name, .kind = .{ .check = ck.e } });
    if (c.generated) |g| try cons.append(s.a, .{ .kind = .{ .generated = .{ .e = g, .stored = c.stored } } });
    return .{ .name = c.name, .type = c.type.storageType(), .decl_type = try declType(s, c), .constraints = cons.items };
}

/// The declared type, as xq_catalog records it (types.Type.format()).
fn declType(s: *Parser, c: *const Column) Error![]const u8 {
    var tbuf: [512]u8 = undefined;
    var tw: Writer = .fixed(&tbuf);
    c.type.format(&tw) catch return s.fail("xqlite: column type too long", .{});
    return s.a.dupe(u8, tw.buffered());
}

/// The SQLite name of MariaDB index `index` of `table`.
pub fn sqliteIndexName(a: std.mem.Allocator, table: []const u8, index: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}${s}", .{ table, index });
}

/// The tree of the SQLite index of MariaDB index `ix` of `table`.
fn indexTree(s: *Parser, schema: []const u8, table: Name, ix: IndexDef, if_not_exists: bool) Error!*tree.CreateIndex {
    var items: std.ArrayList(tree.IndexItem) = .empty;
    for (ix.cols) |k| {
        const e = try tree.expr(s.a, k.name.pos, k.name.pos, .{ .column = try s.a.dupe(Name, &.{k.name}) });
        try items.append(s.a, .{ .expr = e, .desc = k.desc });
    }
    return s.new(tree.CreateIndex, .{
        .unique = ix.unique,
        .if_not_exists = if_not_exists,
        .name = .{ .schema = .{ .text = schema }, .name = .{ .text = try sqliteIndexName(s.a, table.text, ix.name.?), .pos = table.pos } },
        .table = table,
        .items = items.items,
    });
}

/// The indexes, the catalog entries and AUTO_INCREMENT=n of a new table,
/// when the statement runs.
fn codeTableExtras(s: *Parser, t: *Table, schema: []const u8, name: []const u8) Error!void {
    var r: render.Renderer = .{ .p = s.p, .src = s.lx.sql };
    const table: Name = .{ .text = name };
    for (t.indexes.items) |ix| {
        _ = r.createIndex(try indexTree(s, schema, table, ix, false)) catch |err| return lowered(err);
        r.put(";") catch |err| return lowered(err);
    }
    if (t.auto_increment_start) |n| if (rowidColumn(t)) |c| if (c.autoinc and n > 1) {
        r.print("INSERT INTO {f}.sqlite_sequence(name,seq) VALUES({f},{d});", .{ session.Id{ .z = schema }, Q{ .z = name }, n - 1 }) catch |err| return lowered(err);
    };
    if (r.out.items.len > 0) {
        const i_db = catalog.schemaIndex(s.p, schema) orelse return error.ParseFailed;
        catalog.codeExec(s.p, i_db, r.text() catch |err| return lowered(err));
    }
    // The catalog (lowering recorded the dialect and the types).
    for (t.columns.items) |*c| codeColumnEntries(s, schema, name, c);
    if (t.default_collation_name) |cn| catalog.codeSet(s.p, schema, name, "", catalog.Key.collation, cn);
    try s.check();
}

/// The catalog entries of column `c` but its type (lower.zig records it).
fn codeColumnEntries(s: *Parser, schema: []const u8, table: []const u8, c: *const Column) void {
    const col = c.name.text;
    if (c.collation_name) |cn| catalog.codeSet(s.p, schema, table, col, catalog.Key.collation, cn);
    if (c.default_shown) |d| catalog.codeSet(s.p, schema, table, col, catalog.Key.default, d);
    if (c.autoinc) catalog.codeSet(s.p, schema, table, col, "mariadb.auto_increment", "1");
    if (c.on_update) catalog.codeSet(s.p, schema, table, col, "mariadb.on_update", "current_timestamp()");
}

// ====================================================== CREATE INDEX

pub fn createIndex(s: *Parser, unique: bool) Error!void {
    try s.expectKw("INDEX");
    const if_not_exists = try s.ifNotExists();
    const iname = try s.nameText(try s.name());
    try indexType(s);
    try s.expectKw("ON");
    const q = try s.qualifiedName();
    const cols = try indexColumns(s);
    try indexOptions(s);
    while (s.eatKw("ALGORITHM") or s.eatKw("LOCK")) {
        _ = s.eatOp("=");
        _ = try s.anyName();
    }
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tab = build.findTable(s.p.db, q.name.text, if (q.schema) |x| x.text else null) orelse
        return s.fail("Table '{s}.{s}' doesn't exist", .{ if (q.schema) |x| x.text else "main", q.name.text });
    const schema = try s.a.dupe(u8, catalog.schemaName(s.p.db, tab));
    const table: Name = .{ .text = try s.a.dupe(u8, tab.name), .pos = q.name.pos };
    try s.lowerStmt(.{ .create_index = try indexTree(s, schema, table, .{ .name = iname, .unique = unique, .cols = cols }, if_not_exists) });
}

/// The SQLite name of index `iname` of `tab` ("t$i", or the name itself
/// for an index another dialect created); null if there is none.
fn findIndexName(s: *Parser, tab: *int.Table, iname: []const u8, schema: ?[]const u8) Error!?[]const u8 {
    const real = try sqliteIndexName(s.a, tab.name, iname);
    if (build.findIndex(s.p.db, real, schema) != null) return real;
    if (build.findIndex(s.p.db, iname, schema) != null) return iname;
    return null;
}

/// DROP INDEX [IF EXISTS] i ON t.
pub fn dropIndex(s: *Parser) Error!void {
    try s.expectKw("INDEX");
    const if_exists = try s.ifExists();
    const iname = try s.nameText(try s.anyName());
    if (!s.eatKw("ON")) return s.fail("xqlite: DROP INDEX needs ON table", .{});
    const q = try s.qualifiedName();
    const schema: ?[]const u8 = if (q.schema) |x| x.text else null;
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (std.ascii.eqlIgnoreCase(iname, "PRIMARY")) return s.fail("xqlite: dropping the PRIMARY KEY is not supported", .{});
    const tab = build.findTable(s.p.db, q.name.text, schema) orelse return s.fail("Table '{s}' doesn't exist", .{q.name.text});
    const real = (try findIndexName(s, tab, iname, schema)) orelse {
        if (!if_exists) return s.fail("Can't DROP INDEX `{s}`; check that it exists", .{iname});
        return session.emptyStatement(s);
    };
    try dropIndexNamed(s, q.schema, real);
}

fn dropIndexNamed(s: *Parser, schema: ?Name, real: []const u8) Error!void {
    try s.lowerStmt(.{ .drop = try s.new(tree.Drop, .{ .kind = .index, .if_exists = true, .name = .{ .schema = schema, .name = .{ .text = real } } }) });
}

// =============================================================== DROP

/// DROP [TEMPORARY] TABLE [IF EXISTS] t [, t2 ...] [RESTRICT|CASCADE].
pub fn dropTable(s: *Parser, view: bool) Error!void {
    s.advance(); // TABLE / VIEW
    const if_exists = try s.ifExists();
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const q = try s.qualifiedName();
    if (s.isOp(",")) return s.fail("xqlite: DROP {s} of several tables is not supported", .{if (view) "VIEW" else "TABLE"});
    _ = s.eatKw("RESTRICT") or s.eatKw("CASCADE");
    const schema: ?[]const u8 = if (q.schema) |x| x.text else null;
    if (build.findTable(s.p.db, q.name.text, schema) == null and !if_exists) {
        return s.fail("Unknown table '{s}.{s}'", .{ schema orelse "main", q.name.text });
    }
    try s.lowerStmt(.{ .drop = try s.new(tree.Drop, .{ .kind = if (view) .view else .table, .if_exists = if_exists, .name = q }) });
}

// =============================================================== VIEW

/// CREATE [OR REPLACE] [ALGORITHM=..] [DEFINER=..] [SQL SECURITY ..] VIEW
/// [IF NOT EXISTS] v [(cols)] AS select [WITH CHECK OPTION].
pub fn createView(s: *Parser, or_replace: bool, temp: bool) Error!void {
    try s.expectKw("VIEW");
    const if_not_exists = try s.ifNotExists();
    const q = try s.qualifiedName();
    var cols: []Name = &.{};
    if (s.isOp("(")) cols = try s.nameList();
    try s.expectKw("AS");
    const saved = s.stored;
    s.stored = .{};
    const sel = try s.selectStmt();
    s.stored = saved;
    if (s.eatKw("WITH")) {
        _ = s.eatKw("CASCADED") or s.eatKw("LOCAL");
        try s.expectKw("CHECK");
        try s.expectKw("OPTION");
    }
    const name: tree.QName = if (temp) .{ .name = q.name } else .{ .schema = q.schema orelse .{ .text = "main" }, .name = q.name };
    try s.lowerStmt(.{ .create_view = try s.new(tree.CreateView, .{
        .or_replace = or_replace,
        .temp = temp,
        .if_not_exists = if_not_exists,
        .name = name,
        .cols = cols,
        .select = sel,
    }) });
}

// =========================================================== SEQUENCE

/// CREATE [OR REPLACE] SEQUENCE [IF NOT EXISTS] s [options] (MariaDB 10.3).
pub fn createSequence(s: *Parser) Error!void {
    try s.expectKw("SEQUENCE");
    const if_not_exists = try s.ifNotExists();
    const q = try s.qualifiedName();
    var o: tree.SeqOpts = .{};
    while (!s.atStmtEnd()) {
        if (s.eatKw("INCREMENT")) {
            _ = s.eatKw("BY") or s.eatOp("=");
            o.increment = try signedInt(s);
        } else if (s.eatKw("MINVALUE")) {
            _ = s.eatOp("=");
            o.min = try signedInt(s);
        } else if (s.eatKw("MAXVALUE")) {
            _ = s.eatOp("=");
            o.max = try signedInt(s);
        } else if (s.eatKw("NOMINVALUE") or s.eatKw("NOMAXVALUE") or s.eatKw("NOCACHE") or s.eatKw("NOCYCLE")) {} else if (s.eatKw("NO")) {
            if (!(s.eatKw("MINVALUE") or s.eatKw("MAXVALUE") or s.eatKw("CACHE") or s.eatKw("CYCLE"))) return s.syntaxError();
        } else if (s.eatKw("START")) {
            _ = s.eatKw("WITH") or s.eatOp("=");
            o.start = try signedInt(s);
        } else if (s.eatKw("CACHE")) {
            _ = s.eatOp("=");
            _ = try signedInt(s);
        } else if (s.eatKw("CYCLE")) {
            o.cycle = true;
        } else if (s.eatKw("ENGINE")) {
            _ = s.eatOp("=");
            _ = try s.anyName();
        } else return s.syntaxError();
    }
    // MariaDB: a descending sequence's MAXVALUE defaults to -1 and its
    // MINVALUE to -9223372036854775807; PostgreSQL's (sequence.zig) are
    // the same.
    try session.emptyStatement(s);
    try s.lowerStmt(.{ .create_sequence = try s.new(tree.CreateSequence, .{ .if_not_exists = if_not_exists, .name = q, .opts = o }) });
}

fn signedInt(s: *Parser) Error!i64 {
    const neg = s.eatOp("-");
    if (!neg) _ = s.eatOp("+");
    if (s.tok.kind != .integer) return s.syntaxError();
    const v = std.fmt.parseInt(i64, s.tok.text, 10) catch return s.syntaxError();
    s.advance();
    return if (neg) -v else v;
}

/// DROP SEQUENCE [IF EXISTS] s.
pub fn dropSequence(s: *Parser) Error!void {
    try s.expectKw("SEQUENCE");
    const if_exists = try s.ifExists();
    const q = try s.qualifiedName();
    // Dropping a sequence that does not exist does nothing (MariaDB
    // fails without IF EXISTS).
    try session.emptyStatement(s);
    try s.lowerStmt(.{ .drop = try s.new(tree.Drop, .{ .kind = .sequence, .if_exists = if_exists, .name = q }) });
}

// ============================================================= ALTER

/// ALTER TABLE t ADD [COLUMN] def | ADD {INDEX|KEY|UNIQUE} ... | DROP
/// [COLUMN] c | DROP {INDEX|KEY} i | RENAME [TO|AS] n | RENAME COLUMN a
/// TO b: one change per statement.
pub fn alterTable(s: *Parser) Error!void {
    _ = s.eatKw("IGNORE");
    try s.expectKw("TABLE");
    const q = try s.qualifiedName();
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tab = build.findTable(s.p.db, q.name.text, if (q.schema) |x| x.text else null) orelse return s.fail("Table '{s}' doesn't exist", .{q.name.text});
    const real = try s.a.dupe(u8, tab.name);
    const schema = try s.a.dupe(u8, catalog.schemaName(s.p.db, tab));
    const tq: tree.QName = .{ .schema = .{ .text = schema }, .name = .{ .text = real, .pos = q.name.pos } };
    if (s.eatKw("ADD")) {
        if (s.isAnyKw(&.{ "INDEX", "KEY", "UNIQUE", "FULLTEXT", "SPATIAL" })) {
            var t: Table = .{};
            try createDefinition(s, &t);
            var ix = t.indexes.items[0];
            if (ix.name == null) ix.name = ix.cols[0].name.text;
            try s.lowerStmt(.{ .create_index = try indexTree(s, schema, .{ .text = real, .pos = q.name.pos }, ix, false) });
            return endAlter(s);
        }
        if (s.isAnyKw(&.{ "PRIMARY", "CONSTRAINT", "FOREIGN", "CHECK" })) {
            return s.fail("xqlite: ALTER TABLE ADD {s} is not supported", .{s.tok.text});
        }
        _ = s.eatKw("COLUMN");
        const if_not_exists = try s.ifNotExists();
        var t: Table = .{};
        try columnDefinition(s, &t);
        if (s.eatKw("FIRST")) {} else if (s.eatKw("AFTER")) _ = try s.anyName();
        const c = &t.columns.items[0];
        if (c.primary or c.autoinc or c.unique) return s.fail("xqlite: ALTER TABLE ADD of a key column is not supported", .{});
        try finishTable(s, &t);
        if (if_not_exists and build.columnIndex(tab, c.name.text) >= 0) return session.emptyStatement(s);
        try s.lowerStmt(.{ .alter_table = try s.new(tree.AlterTable, .{ .name = tq, .action = .{ .add_column = .{ .def = try columnTree(s, c, false) } } }) });
        catalog.codeSet(s.p, schema, real, "", catalog.Key.dialect, "mariadb");
        codeColumnEntries(s, schema, real, c);
        try s.check();
        return endAlter(s);
    }
    if (s.eatKw("DROP")) {
        if (s.eatKw("INDEX") or s.eatKw("KEY")) {
            const iname = try s.nameText(try s.anyName());
            const idx = (try findIndexName(s, tab, iname, schema)) orelse return s.fail("Can't DROP INDEX `{s}`; check that it exists", .{iname});
            try dropIndexNamed(s, tq.schema, idx);
            return endAlter(s);
        }
        if (s.isAnyKw(&.{ "PRIMARY", "FOREIGN", "CONSTRAINT", "CHECK" })) {
            return s.fail("xqlite: ALTER TABLE DROP {s} is not supported", .{s.tok.text});
        }
        _ = s.eatKw("COLUMN");
        const if_exists = try s.ifExists();
        const c = try s.nameOf(try s.anyName());
        try s.lowerStmt(.{ .alter_table = try s.new(tree.AlterTable, .{ .name = tq, .action = .{ .drop_column = .{ .if_exists = if_exists, .name = c } } }) });
        return endAlter(s);
    }
    if (s.eatKw("RENAME")) {
        if (s.eatKw("COLUMN")) {
            const a = try s.nameOf(try s.anyName());
            try s.expectKw("TO");
            const b = try s.nameOf(try s.anyName());
            try s.lowerStmt(.{ .alter_table = try s.new(tree.AlterTable, .{ .name = tq, .action = .{ .rename_column = .{ .old = a, .new = b } } }) });
            return endAlter(s);
        }
        if (s.isKw("INDEX") or s.isKw("KEY")) return s.fail("xqlite: ALTER TABLE RENAME INDEX is not supported", .{});
        _ = s.eatKw("TO") or s.eatKw("AS");
        const new = try s.qualifiedName();
        try renameTable(s, tab, tq, new.name);
        return endAlter(s);
    }
    if (s.isKw("DISABLE") or s.isKw("ENABLE")) {
        // DISABLE/ENABLE KEYS (mysqldump): nothing to do.
        s.advance();
        try s.expectKw("KEYS");
        return session.emptyStatement(s);
    }
    if (s.isAnyKw(&.{ "ENGINE", "DEFAULT", "CHARSET", "CHARACTER", "COMMENT", "AUTO_INCREMENT", "CONVERT" })) {
        if (s.isKw("CONVERT")) {
            while (!s.atStmtEnd()) s.advance();
        } else try tableOptions(s, null);
        return session.emptyStatement(s);
    }
    return s.fail("xqlite: this ALTER TABLE is not supported (ADD/DROP COLUMN, ADD/DROP INDEX, RENAME)", .{});
}

fn endAlter(s: *Parser) Error!void {
    if (s.isOp(",")) return s.fail("xqlite: ALTER TABLE with several changes is not supported", .{});
}

/// ALTER TABLE ... RENAME TO `new` (the IR renames the catalog entries),
/// and the table's MariaDB indexes "old$i" with it, so that SHOW INDEX,
/// SHOW CREATE TABLE and DROP INDEX i ON new find them: after the rename
/// the schema row of each becomes "new$i" with the text of its CREATE
/// INDEX (a nested UPDATE of sqlite_schema, as SQLite's ALTER TABLE
/// rewrites it; the index keeps its b-tree), and the schema is read
/// again.
fn renameTable(s: *Parser, tab: *int.Table, old: tree.QName, new: Name) Error!void {
    const schema = old.schema.?.text;
    const prefix = try std.fmt.allocPrint(s.a, "{s}$", .{old.name.text});
    // The indexes to rename, before the rename changes the schema.
    const Renamed = struct { old: []const u8, new: []const u8, sql: []const u8 };
    var renamed: std.ArrayList(Renamed) = .empty;
    var it = tab.index;
    while (it) |ix| : (it = ix.next) {
        if (!std.mem.startsWith(u8, ix.name, prefix) or ix.idx_type != .appdef or ix.part_idx_where != null) continue;
        var cols: std.ArrayList(IndexCol) = .empty;
        const ok = for (ix.ai_column[0..ix.n_key_col], 0..) |ci, k| {
            if (ci < 0) break false;
            try cols.append(s.a, .{ .name = .{ .text = try s.a.dupe(u8, tab.cols[@intCast(ci)].name()) }, .desc = ix.sort_order[k] != 0 });
        } else true;
        if (!ok) continue;
        const def: IndexDef = .{ .name = try s.a.dupe(u8, ix.name[prefix.len..]), .unique = ix.on_error != .None, .cols = cols.items };
        var ci = try indexTree(s, schema, new, def, false);
        // The schema keeps the name unqualified.
        ci.name.schema = null;
        const sql = render.statement(s.p, s.lx.sql, .{ .create_index = ci }) catch |err| return lowered(err);
        try renamed.append(s.a, .{ .old = try s.a.dupe(u8, ix.name), .new = ci.name.name.text, .sql = sql });
    }
    try s.lowerStmt(.{ .alter_table = try s.new(tree.AlterTable, .{ .name = old, .action = .{ .rename_to = new } }) });
    if (renamed.items.len == 0) return;
    for (renamed.items) |x| {
        build.nestedParse(s.p, "UPDATE \"%w\"." ++ int.LEGACY_SCHEMA_TABLE ++ " SET name = %Q, sql = %Q WHERE type = 'index' AND name = %Q", &.{
            .{ .str = schema }, .{ .str = x.new }, .{ .str = x.sql }, .{ .str = x.old },
        });
    }
    try s.check();
    const i_db = catalog.schemaIndex(s.p, schema) orelse return error.ParseFailed;
    const v = s.p.vdbe orelse return error.ParseFailed;
    build.changeCookie(s.p, i_db);
    @import("../../vdbe/aux.zig").addParseSchemaOp(v, @intCast(i_db), null, @import("../../sql/prepare.zig").INITFLAG_AlterRename);
}

/// RENAME TABLE a TO b.
pub fn renameTableStmt(s: *Parser) Error!void {
    try s.expectKw("TABLE");
    const q = try s.qualifiedName();
    try s.expectKw("TO");
    const m = try s.qualifiedName();
    if (s.isOp(",")) return s.fail("xqlite: RENAME TABLE of several tables is not supported", .{});
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tab = build.findTable(s.p.db, q.name.text, if (q.schema) |x| x.text else null) orelse
        return s.fail("Table '{s}' doesn't exist", .{q.name.text});
    const schema = try s.a.dupe(u8, catalog.schemaName(s.p.db, tab));
    const tq: tree.QName = .{ .schema = .{ .text = schema }, .name = .{ .text = try s.a.dupe(u8, tab.name), .pos = q.name.pos } };
    try renameTable(s, tab, tq, m.name);
}

// ================================================== SHOW CREATE TABLE

/// SHOW CREATE TABLE's text: MariaDB's form built from the catalog for a
/// table the MariaDB dialect created, else the SQLite schema text.
pub fn showCreateTable(s: *Parser, tab: *int.Table, schema: []const u8) Error![]const u8 {
    const api = @import("../../vdbe/api.zig");
    const tname = try s.a.dupe(u8, tab.name);
    var sqlite_sql: []const u8 = "";
    var types_by_col: std.StringHashMapUnmanaged([]const u8) = .empty;
    var defaults: std.StringHashMapUnmanaged([]const u8) = .empty;
    var autoinc: ?[]const u8 = null;
    {
        var q = catalog.Query.initFmt(s.p.db, "SELECT sql FROM %Q.sqlite_schema WHERE name=%Q", &.{ .{ .str = schema }, .{ .str = tname } }) catch
            return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)});
        defer q.deinit();
        if (q.step() catch false) sqlite_sql = try s.a.dupe(u8, api.columnText(q.v, 0) orelse "");
    }
    const list = catalog.entries(s.p.db, s.a, schema, tname) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)}),
    };
    for (list) |e| {
        const lc = try std.ascii.allocLowerString(s.a, e.col);
        if (std.mem.eql(u8, e.key, catalog.Key.decl_type)) try types_by_col.put(s.a, lc, e.value);
        if (std.mem.eql(u8, e.key, catalog.Key.default)) try defaults.put(s.a, lc, e.value);
        if (std.mem.eql(u8, e.key, "mariadb.auto_increment")) autoinc = e.col;
    }
    const tab2 = build.findTable(s.p.db, tname, schema) orelse return sqlite_sql;
    if (tab2.isView() or types_by_col.count() == 0) return sqlite_sql;
    var out: Writer.Allocating = .init(s.a);
    const w = &out.writer;
    const B = @import("../dialect.zig").Quoted('`');
    w.print("CREATE TABLE {f} (\n", .{B{ .z = tname }}) catch return error.OutOfMemory;
    for (tab2.cols, 0..) |*c, i| {
        if (i > 0) w.writeAll(",\n") catch return error.OutOfMemory;
        const lc = try std.ascii.allocLowerString(s.a, c.name());
        const ty = types_by_col.get(lc) orelse "text";
        w.print("  {f} {s}", .{ B{ .z = c.name() }, ty }) catch return error.OutOfMemory;
        if (c.not_null != .None) w.writeAll(" NOT NULL") catch return error.OutOfMemory;
        if (defaults.get(lc)) |d| {
            const is_num = d.len > 0 and (std.ascii.isDigit(d[0]) or d[0] == '-') or std.mem.endsWith(u8, d, ")");
            if (is_num) {
                w.print(" DEFAULT {s}", .{d}) catch return error.OutOfMemory;
            } else w.print(" DEFAULT {f}", .{Q{ .z = d }}) catch return error.OutOfMemory;
        } else if (c.not_null == .None) w.writeAll(" DEFAULT NULL") catch return error.OutOfMemory;
        if (autoinc) |a| if (std.ascii.eqlIgnoreCase(a, c.name())) w.writeAll(" AUTO_INCREMENT") catch return error.OutOfMemory;
    }
    if (tab2.i_pkey >= 0) {
        w.print(",\n  PRIMARY KEY ({f})", .{B{ .z = tab2.cols[@intCast(tab2.i_pkey)].name() }}) catch return error.OutOfMemory;
    }
    // PRIMARY, then the unique keys, then the others, each in creation
    // order (Table.index is newest first).
    var all: std.ArrayList(*int.Index) = .empty;
    var it = tab2.index;
    while (it) |ix| : (it = ix.next) try all.insert(s.a, 0, ix);
    var ordered: std.ArrayList(*int.Index) = .empty;
    for (all.items) |ix| if (ix.idx_type == .primarykey) try ordered.append(s.a, ix);
    for (all.items) |ix| if (ix.idx_type != .primarykey and ix.on_error != .None) try ordered.append(s.a, ix);
    for (all.items) |ix| if (ix.on_error == .None) try ordered.append(s.a, ix);
    for (ordered.items) |ix| {
        const prefix = try std.fmt.allocPrint(s.a, "{s}$", .{tname});
        const iname: []const u8 = if (ix.idx_type == .primarykey) "PRIMARY" else if (std.mem.startsWith(u8, ix.name, prefix)) ix.name[prefix.len..] else ix.name;
        if (ix.idx_type == .primarykey) {
            w.writeAll(",\n  PRIMARY KEY (") catch return error.OutOfMemory;
        } else w.print(",\n  {s}KEY {f} (", .{ if (ix.on_error != .None) "UNIQUE " else "", B{ .z = iname } }) catch return error.OutOfMemory;
        for (ix.ai_column[0..ix.n_key_col], 0..) |col_i, k| {
            if (k > 0) w.writeByte(',') catch return error.OutOfMemory;
            if (col_i >= 0) w.print("{f}", .{B{ .z = tab2.cols[@intCast(col_i)].name() }}) catch return error.OutOfMemory;
        }
        w.writeByte(')') catch return error.OutOfMemory;
    }
    w.writeAll("\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci") catch return error.OutOfMemory;
    return out.written();
}
