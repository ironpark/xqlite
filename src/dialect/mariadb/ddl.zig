//! DDL: CREATE/DROP TABLE, INDEX, VIEW, SEQUENCE, ALTER TABLE, RENAME
//! TABLE.
//!
//! What is in sqlite_schema must be SQLite text, so a MariaDB CREATE
//! TABLE is parsed into a description (Table below) and rendered as an
//! SQLite CREATE TABLE, lowered with ir.stmt.lowerSqliteText(); what
//! SQLite's schema cannot hold goes to xq_catalog in the same statement:
//!
//!     CREATE TABLE t (id INT AUTO_INCREMENT PRIMARY KEY,
//!                     name VARCHAR(20) NOT NULL, KEY (name))
//!     -->
//!     CREATE TABLE "t"("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
//!                      "name" TEXT NOT NULL COLLATE NOCASE) STRICT
//!     CREATE INDEX "t$name" ON "t"("name")       (run by OP_SqlExec)
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
//!  - DEFAULT, CHECK and generated-column expressions and the SELECT of
//!    a view are stored as SQLite text by translateRange(), a token-level
//!    translation (quoting, operators, function names) of what was
//!    parsed: MariaDB syntax that has no token-level SQLite equivalent
//!    (DIV, XOR, ^, user variables, INTERVAL) is refused there.
//!  - Table options (ENGINE, CHARSET, COLLATE, COMMENT, ROW_FORMAT ...)
//!    are accepted; DEFAULT COLLATE/CHARSET set the columns' default.

const std = @import("std");
const int = @import("../../sql/sqlite_int.zig");
const ir = @import("../../ir/ir.zig");
const build = @import("../../sql/build.zig");
const catalog = @import("../../catalog/catalog.zig");
const sequence = catalog.sequence;
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const types = @import("types.zig");
const session = @import("session.zig");

const Parser = parser.Parser;
const Error = parser.Error;
const Token = lexer.Token;
const Q = session.Q;
const Id = session.Id;
const Writer = std.Io.Writer;

const Column = struct {
    name: []const u8,
    type: types.Type,
    not_null: bool = false,
    explicit_null: bool = false,
    /// SQLite text of the DEFAULT expression, and how SHOW COLUMNS shows it.
    default_sql: ?[]const u8 = null,
    default_shown: ?[]const u8 = null,
    autoinc: bool = false,
    primary: bool = false,
    unique: bool = false,
    /// The SQLite collation, and the MariaDB name if one was given.
    collation: ?[:0]const u8 = null,
    collation_name: ?[]const u8 = null,
    checks: std.ArrayList([]const u8) = .empty,
    generated: ?[]const u8 = null,
    stored: bool = false,
    on_update: bool = false,
    json: bool = false,
};

const IndexDef = struct {
    name: ?[]const u8,
    unique: bool,
    cols: []const IndexCol,
};

const IndexCol = struct { name: []const u8, desc: bool };

const ForeignKey = struct {
    constraint: ?[]const u8,
    cols: []const []const u8,
    ref_table: []const u8,
    ref_cols: []const []const u8,
    actions: []const u8,
};

const Table = struct {
    columns: std.ArrayList(Column) = .empty,
    primary: ?[]const IndexCol = null,
    indexes: std.ArrayList(IndexDef) = .empty,
    checks: std.ArrayList(struct { ?[]const u8, []const u8 }) = .empty,
    fkeys: std.ArrayList(ForeignKey) = .empty,
    default_collation: ?[:0]const u8 = null,
    default_collation_name: ?[]const u8 = null,
    auto_increment_start: ?i64 = null,
};

// ====================================================== CREATE TABLE

pub fn createTable(s: *Parser, temp: bool, or_replace: bool) Error!void {
    try s.expectKw("TABLE");
    var if_not_exists = false;
    if (s.isKw("IF")) {
        s.advance();
        try s.expectKw("NOT");
        try s.expectKw("EXISTS");
        if_not_exists = true;
    }
    const n1, const n2 = try s.qualifiedName();
    const name = try s.tokName(if (n2.n != 0) n2 else n1);
    const schema: []const u8 = if (temp) "temp" else if (n2.n != 0) try s.tokName(n1) else "main";
    if (build.findDbName(s.p.db, schema) == null) return s.fail("Unknown database '{s}'", .{schema});
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (or_replace) return s.fail("xqlite: CREATE OR REPLACE TABLE is not supported (use DROP TABLE IF EXISTS)", .{});

    if (s.isKw("LIKE") or (s.isOp("(") and s.peek().isKw("LIKE"))) {
        return s.fail("xqlite: CREATE TABLE ... LIKE is not supported", .{});
    }
    if (!s.isOp("(")) {
        // CREATE TABLE t [AS] SELECT ...: SQLite's CREATE TABLE AS.
        try tableOptions(s, null);
        _ = s.eatKw("AS");
        if (!s.isSelectStart()) return s.syntaxError();
        const sel = try s.selectStmt();
        ir.ddl.beginCreate(s.p);
        ir.ddl.startTable(s.p, n1, n2, temp, false, false, if_not_exists);
        ir.ddl.endTable(s.p, null, null, .{}, sel);
        try s.check();
        catalog.codeSet(s.p, schema, name, "", catalog.Key.dialect, "mariadb");
        return;
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
    const text = try renderTable(s, &t, schema, name, temp, if_not_exists);
    try session.lowerText(s, text);
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
        const cols = try nameList(s);
        const ref = try references(s);
        try t.fkeys.append(s.a, .{ .constraint = constraint, .cols = cols, .ref_table = ref.table, .ref_cols = ref.cols, .actions = ref.actions });
        return;
    } else if (s.eatKw("CHECK")) {
        try t.checks.append(s.a, .{ constraint, try checkExpr(s) });
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
        const n = try s.nameText(try s.anyName());
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

fn nameList(s: *Parser) Error![]const []const u8 {
    try s.expectOp("(");
    var out: std.ArrayList([]const u8) = .empty;
    while (true) {
        try out.append(s.a, try s.nameText(try s.anyName()));
        if (!s.eatOp(",")) break;
    }
    try s.expectOp(")");
    return out.items;
}

const Ref = struct { table: []const u8, cols: []const []const u8, actions: []const u8 };

/// REFERENCES t [(cols)] [MATCH ...] [ON DELETE a] [ON UPDATE a] as
/// SQLite text for the actions.
fn references(s: *Parser) Error!Ref {
    try s.expectKw("REFERENCES");
    const r1, const r2 = try s.qualifiedName();
    if (r2.n != 0) return s.fail("xqlite: a foreign key to a table of another database is not supported", .{});
    const table = try s.tokName(r1);
    var cols: []const []const u8 = &.{};
    if (s.isOp("(")) cols = try nameList(s);
    var actions: std.ArrayList(u8) = .empty;
    while (true) {
        if (s.eatKw("MATCH")) {
            _ = try s.anyName();
        } else if (s.eatKw("ON")) {
            const what = if (s.eatKw("DELETE")) "DELETE" else if (s.eatKw("UPDATE")) "UPDATE" else return s.syntaxError();
            const action = if (s.eatKw("CASCADE"))
                "CASCADE"
            else if (s.eatKw("RESTRICT"))
                "RESTRICT"
            else if (s.eatKw("SET")) blk: {
                if (s.eatKw("NULL")) break :blk "SET NULL";
                try s.expectKw("DEFAULT");
                break :blk "SET DEFAULT";
            } else if (s.eatKw("NO")) blk: {
                try s.expectKw("ACTION");
                break :blk "NO ACTION";
            } else return s.syntaxError();
            try actions.print(s.a, " ON {s} {s}", .{ what, action });
        } else break;
    }
    return .{ .table = table, .cols = cols, .actions = actions.items };
}

/// `( expr )` of CHECK: SQLite text.
fn checkExpr(s: *Parser) Error![]const u8 {
    try s.expectOp("(");
    const start = s.tok.text.ptr;
    _ = try s.expr();
    const end = s.prev_end;
    try s.expectOp(")");
    return translateRange(s, start, end);
}

fn columnDefinition(s: *Parser, t: *Table) Error!void {
    const name = try s.nameText(try s.name());
    var c: Column = .{ .name = name, .type = undefined };
    c.type = try columnType(s, &c);
    if (c.type.base == .longtext and c.json) {
        try c.checks.append(s.a, try std.fmt.allocPrint(s.a, "json_valid({f})", .{Id{ .z = name }}));
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
            if (s.isName()) _ = try s.name();
            try s.expectKw("CHECK");
            try c.checks.append(s.a, try checkExpr(s));
        } else if (s.eatKw("CHECK")) {
            try c.checks.append(s.a, try checkExpr(s));
        } else if (s.isKw("GENERATED") or s.isKw("AS")) {
            if (s.eatKw("GENERATED")) {
                try s.expectKw("ALWAYS");
            }
            try s.expectKw("AS");
            try s.expectOp("(");
            const start = s.tok.text.ptr;
            _ = try s.expr();
            const end = s.prev_end;
            try s.expectOp(")");
            c.generated = try translateRange(s, start, end);
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
        if (ty.len) |p| if (p > 65) return s.fail("Too big precision {d} specified for '{s}'. Maximum is 65", .{ p, c.name });
        if (ty.scale) |sc| if (sc > 38 or sc > (ty.len orelse 10)) return s.fail("Too big scale {d} specified for '{s}'. Maximum is 38", .{ sc, c.name });
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

fn intArg(s: *Parser) Error!u32 {
    if (s.tok.kind != .integer) return s.syntaxError();
    const v = std.fmt.parseInt(u32, s.tok.text, 10) catch return s.syntaxError();
    s.advance();
    return v;
}

/// DEFAULT literal | (expr) | CURRENT_TIMESTAMP[(n)] | NOW() ...
fn defaultValue(s: *Parser, c: *Column) Error!void {
    const t = s.tok;
    if (t.isKw("CURRENT_TIMESTAMP") or t.isKw("NOW") or t.isKw("LOCALTIMESTAMP") or t.isKw("LOCALTIME")) {
        s.advance();
        if (s.eatOp("(")) {
            if (s.tok.kind == .integer) s.advance();
            try s.expectOp(")");
        }
        c.default_sql = "CURRENT_TIMESTAMP";
        c.default_shown = "current_timestamp()";
        return;
    }
    if (t.isKw("CURRENT_DATE") or t.isKw("CURDATE")) {
        s.advance();
        if (s.eatOp("(")) try s.expectOp(")");
        c.default_sql = "CURRENT_DATE";
        c.default_shown = "curdate()";
        return;
    }
    if (t.isKw("NULL")) {
        s.advance();
        return;
    }
    if (t.isKw("TRUE") or t.isKw("FALSE")) {
        s.advance();
        c.default_sql = if (t.isKw("TRUE")) "1" else "0";
        c.default_shown = c.default_sql;
        return;
    }
    if (t.kind == .string or (t.kind == .ident and t.text[0] == '_' and s.peek().kind == .string)) {
        const v = try s.stringLiteral();
        c.default_sql = try std.fmt.allocPrint(s.a, "{f}", .{Q{ .z = v }});
        c.default_shown = v;
        return;
    }
    if (s.isOp("(")) {
        s.advance();
        const start = s.tok.text.ptr;
        _ = try s.expr();
        const end = s.prev_end;
        try s.expectOp(")");
        const sql = try translateRange(s, start, end);
        c.default_sql = try std.fmt.allocPrint(s.a, "({s})", .{sql});
        c.default_shown = start[0 .. @intFromPtr(end) - @intFromPtr(start)];
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
            c.default_sql = try std.fmt.allocPrint(s.a, "{s}{s}", .{ if (neg) "-" else "", n.text });
            c.default_shown = c.default_sql;
        },
        .hex => {
            s.advance();
            const d = (try lexer.hexDigits(s.a, n)) orelse return s.syntaxErrorAt(n);
            c.default_sql = try std.fmt.allocPrint(s.a, "x'{s}'", .{d});
            c.default_shown = n.text;
        },
        .bit => {
            s.advance();
            c.default_sql = try std.fmt.allocPrint(s.a, "{d}", .{lexer.bitValue(n) orelse 0});
            c.default_shown = c.default_sql;
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
        const cols = try s.a.alloc(IndexCol, 1);
        cols[0] = .{ .name = c.name, .desc = false };
        t.primary = cols;
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
            if (std.ascii.eqlIgnoreCase(k.name, c.name)) c.not_null = true;
        };
        if (findColumn(t, c.name) != c) return s.fail("Duplicate column name '{s}'", .{c.name});
    }
    // Keys refer to existing columns.
    for (t.indexes.items) |ix| for (ix.cols) |k| {
        if (findColumn(t, k.name) == null) return s.fail("Key column '{s}' doesn't exist in table", .{k.name});
    };
    if (t.primary) |pk| for (pk) |k| {
        if (findColumn(t, k.name) == null) return s.fail("Key column '{s}' doesn't exist in table", .{k.name});
    };
    // AUTO_INCREMENT: the rowid.
    var n_auto: usize = 0;
    for (t.columns.items) |*c| {
        if (!c.autoinc) continue;
        n_auto += 1;
        if (!c.type.base.isInteger()) return s.fail("Incorrect column specifier for column '{s}'", .{c.name});
        const is_pk = if (t.primary) |pk| pk.len == 1 and std.ascii.eqlIgnoreCase(pk[0].name, c.name) else false;
        if (!is_pk) {
            var unique = c.unique;
            for (t.indexes.items) |ix| unique = unique or (ix.unique and ix.cols.len == 1 and std.ascii.eqlIgnoreCase(ix.cols[0].name, c.name));
            if (t.primary != null or !unique) {
                return s.fail("xqlite: an AUTO_INCREMENT column must be the PRIMARY KEY (or the only UNIQUE key of a table without one)", .{});
            }
            const cols = try s.a.alloc(IndexCol, 1);
            cols[0] = .{ .name = c.name, .desc = false };
            t.primary = cols;
            c.unique = false;
        }
    }
    if (n_auto > 1) return s.fail("Incorrect table definition; there can be only one auto column and it must be defined as a key", .{});
    // Unique columns become named unique indexes.
    for (t.columns.items) |*c| if (c.unique) {
        const cols = try s.a.alloc(IndexCol, 1);
        cols[0] = .{ .name = c.name, .desc = false };
        try t.indexes.append(s.a, .{ .name = c.name, .unique = true, .cols = cols });
    };
    // Unnamed indexes are named after their first column.
    for (t.indexes.items, 0..) |*ix, i| {
        if (ix.name != null) continue;
        var n = ix.cols[0].name;
        var k: usize = 2;
        while (indexNameUsed(t.indexes.items[0..i], n)) : (k += 1) n = try std.fmt.allocPrint(s.a, "{s}_{d}", .{ ix.cols[0].name, k });
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
    for (t.columns.items) |*c| if (std.ascii.eqlIgnoreCase(c.name, n)) return c;
    return null;
}

/// Whether the PRIMARY KEY is a single integer column (the rowid).
fn rowidColumn(t: *Table) ?*Column {
    const pk = t.primary orelse return null;
    if (pk.len != 1 or pk[0].desc) return null;
    const c = findColumn(t, pk[0].name) orelse return null;
    return if (c.type.base.isInteger() and c.generated == null) c else null;
}

fn renderTable(s: *Parser, t: *Table, schema: []const u8, name: []const u8, temp: bool, if_not_exists: bool) Error![:0]const u8 {
    var out: Writer.Allocating = .init(s.a);
    const w = &out.writer;
    renderTableTo(w, t, schema, name, temp, if_not_exists) catch return error.OutOfMemory;
    return out.toOwnedSliceSentinel(0);
}

fn renderTableTo(w: *Writer, t: *Table, schema: []const u8, name: []const u8, temp: bool, if_not_exists: bool) Writer.Error!void {
    try w.print("CREATE {s}TABLE {s}{f}.{f}(", .{ if (temp) "TEMP " else "", if (if_not_exists) "IF NOT EXISTS " else "", Id{ .z = schema }, Id{ .z = name } });
    const rowid = rowidColumn(t);
    for (t.columns.items, 0..) |*c, i| {
        if (i > 0) try w.writeByte(',');
        try renderColumn(w, c, c == rowid);
    }
    if (t.primary) |pk| if (rowid == null) {
        try w.writeAll(",PRIMARY KEY(");
        for (pk, 0..) |k, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{f}", .{Id{ .z = k.name }});
        }
        try w.writeByte(')');
    };
    for (t.checks.items) |ck| {
        try w.writeByte(',');
        if (ck[0]) |cn| try w.print("CONSTRAINT {f} ", .{Id{ .z = cn }});
        try w.print("CHECK({s})", .{ck[1]});
    }
    for (t.fkeys.items) |fk| {
        try w.writeByte(',');
        if (fk.constraint) |cn| try w.print("CONSTRAINT {f} ", .{Id{ .z = cn }});
        try w.writeAll("FOREIGN KEY(");
        for (fk.cols, 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{f}", .{Id{ .z = c }});
        }
        try w.print(") REFERENCES {f}", .{Id{ .z = fk.ref_table }});
        if (fk.ref_cols.len > 0) {
            try w.writeByte('(');
            for (fk.ref_cols, 0..) |c, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{f}", .{Id{ .z = c }});
            }
            try w.writeByte(')');
        }
        try w.writeAll(fk.actions);
    }
    try w.writeAll(") STRICT");
}

fn renderColumn(w: *Writer, c: *const Column, rowid: bool) Writer.Error!void {
    try w.print("{f} {s}", .{ Id{ .z = c.name }, c.type.storageType() });
    if (c.not_null) try w.writeAll(" NOT NULL");
    if (rowid) {
        try w.writeAll(" PRIMARY KEY");
        if (c.autoinc) try w.writeAll(" AUTOINCREMENT");
    }
    if (c.default_sql) |d| try w.print(" DEFAULT {s}", .{d});
    if (c.collation) |coll| try w.print(" COLLATE {s}", .{coll});
    for (c.checks.items) |ck| try w.print(" CHECK({s})", .{ck});
    if (c.generated) |g| try w.print(" GENERATED ALWAYS AS ({s}) {s}", .{ g, if (c.stored) "STORED" else "VIRTUAL" });
}

/// The SQLite name of MariaDB index `index` of `table`.
pub fn sqliteIndexName(a: std.mem.Allocator, table: []const u8, index: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}${s}", .{ table, index });
}

/// The indexes, the catalog entries and AUTO_INCREMENT=n of a new table,
/// when the statement runs.
fn codeTableExtras(s: *Parser, t: *Table, schema: []const u8, name: []const u8) Error!void {
    var sql: Writer.Allocating = .init(s.a);
    const w = &sql.writer;
    for (t.indexes.items) |ix| {
        w.print("CREATE {s}INDEX {f}.{f} ON {f}(", .{
            if (ix.unique) "UNIQUE " else "",
            Id{ .z = schema },
            Id{ .z = try sqliteIndexName(s.a, name, ix.name.?) },
            Id{ .z = name },
        }) catch return error.OutOfMemory;
        for (ix.cols, 0..) |k, i| {
            if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
            w.print("{f}{s}", .{ Id{ .z = k.name }, if (k.desc) " DESC" else "" }) catch return error.OutOfMemory;
        }
        w.writeAll(");") catch return error.OutOfMemory;
    }
    if (t.auto_increment_start) |n| if (rowidColumn(t)) |c| if (c.autoinc and n > 1) {
        w.print("INSERT INTO {f}.sqlite_sequence(name,seq) VALUES({f},{d});", .{ Id{ .z = schema }, Q{ .z = name }, n - 1 }) catch return error.OutOfMemory;
    };
    // The catalog.
    w.print(catalog_ddl ++ ";INSERT OR REPLACE INTO {f}.xq_catalog VALUES({f},'','dialect','mariadb')", .{ Id{ .z = schema }, Id{ .z = schema }, Q{ .z = name } }) catch return error.OutOfMemory;
    for (t.columns.items) |c| {
        try catalogColumn(s, w, schema, name, &c);
    }
    if (t.default_collation_name) |cn| {
        w.print(",({f},'','collation',{f})", .{ Q{ .z = name }, Q{ .z = cn } }) catch return error.OutOfMemory;
    }
    w.writeByte(';') catch return error.OutOfMemory;
    const text = try sql.toOwnedSliceSentinel(0);
    const i_db = catalog.schemaIndex(s.p, schema) orelse return error.ParseFailed;
    catalog.codeExec(s.p, i_db, text);
}

const catalog_ddl = "CREATE TABLE IF NOT EXISTS {f}.xq_catalog(tbl TEXT NOT NULL,col TEXT NOT NULL,key TEXT NOT NULL,value,PRIMARY KEY(tbl,col,key))WITHOUT ROWID";

fn catalogColumn(s: *Parser, w: *Writer, schema: []const u8, table: []const u8, c: *const Column) Error!void {
    _ = schema;
    var tbuf: [512]u8 = undefined;
    var tw: Writer = .fixed(&tbuf);
    c.type.format(&tw) catch return s.fail("xqlite: column type too long", .{});
    const ty = tw.buffered();
    const T = Q{ .z = table };
    const C = Q{ .z = c.name };
    w.print(",({f},{f},'type',{f})", .{ T, C, Q{ .z = ty } }) catch return error.OutOfMemory;
    if (c.collation_name) |cn| w.print(",({f},{f},'collation',{f})", .{ T, C, Q{ .z = cn } }) catch return error.OutOfMemory;
    if (c.default_shown) |d| w.print(",({f},{f},'default',{f})", .{ T, C, Q{ .z = d } }) catch return error.OutOfMemory;
    if (c.autoinc) w.print(",({f},{f},'mariadb.auto_increment','1')", .{ T, C }) catch return error.OutOfMemory;
    if (c.on_update) w.print(",({f},{f},'mariadb.on_update','current_timestamp()')", .{ T, C }) catch return error.OutOfMemory;
}

// ====================================================== CREATE INDEX

pub fn createIndex(s: *Parser, unique: bool) Error!void {
    try s.expectKw("INDEX");
    var if_not_exists = false;
    if (s.isKw("IF")) {
        s.advance();
        try s.expectKw("NOT");
        try s.expectKw("EXISTS");
        if_not_exists = true;
    }
    const iname = try s.nameText(try s.name());
    try indexType(s);
    try s.expectKw("ON");
    const n1, const n2 = try s.qualifiedName();
    const tname = try s.tokName(if (n2.n != 0) n2 else n1);
    const schema: []const u8 = if (n2.n != 0) try s.tokName(n1) else "main";
    const cols = try indexColumns(s);
    try indexOptions(s);
    while (s.eatKw("ALGORITHM") or s.eatKw("LOCK")) {
        _ = s.eatOp("=");
        _ = try s.anyName();
    }
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tab = build.findTable(s.p.db, tname, if (n2.n != 0) schema else null) orelse
        return s.fail("Table '{s}.{s}' doesn't exist", .{ schema, tname });
    var out: Writer.Allocating = .init(s.a);
    const w = &out.writer;
    w.print("CREATE {s}INDEX {s}{f}.{f} ON {f}(", .{
        if (unique) "UNIQUE " else "",
        if (if_not_exists) "IF NOT EXISTS " else "",
        Id{ .z = tableSchema(s, tab) },
        Id{ .z = try sqliteIndexName(s.a, tab.name, iname) },
        Id{ .z = tab.name },
    }) catch return error.OutOfMemory;
    for (cols, 0..) |k, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.print("{f}{s}", .{ Id{ .z = k.name }, if (k.desc) " DESC" else "" }) catch return error.OutOfMemory;
    }
    w.writeByte(')') catch return error.OutOfMemory;
    try session.lowerText(s, try out.toOwnedSliceSentinel(0));
}

fn tableSchema(s: *Parser, tab: *int.Table) []const u8 {
    const sch = tab.schema orelse return "main";
    return s.p.db.dbs.items[@intCast(@import("../../sql/prepare.zig").schemaToIndex(s.p.db, sch))].name;
}

/// DROP INDEX [IF EXISTS] i ON t.
pub fn dropIndex(s: *Parser) Error!void {
    try s.expectKw("INDEX");
    var if_exists = false;
    if (s.isKw("IF")) {
        s.advance();
        try s.expectKw("EXISTS");
        if_exists = true;
    }
    const iname = try s.nameText(try s.anyName());
    if (!s.eatKw("ON")) return s.fail("xqlite: DROP INDEX needs ON table", .{});
    const n1, const n2 = try s.qualifiedName();
    const tname = try s.tokName(if (n2.n != 0) n2 else n1);
    const schema: ?[]const u8 = if (n2.n != 0) try s.tokName(n1) else null;
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (std.ascii.eqlIgnoreCase(iname, "PRIMARY")) return s.fail("xqlite: dropping the PRIMARY KEY is not supported", .{});
    const tab = build.findTable(s.p.db, tname, schema) orelse return s.fail("Table '{s}' doesn't exist", .{tname});
    var real = try sqliteIndexName(s.a, tab.name, iname);
    if (build.findIndex(s.p.db, real, schema) == null and build.findIndex(s.p.db, iname, schema) != null) real = iname;
    if (build.findIndex(s.p.db, real, schema) == null and !if_exists) {
        return s.fail("Can't DROP INDEX `{s}`; check that it exists", .{iname});
    }
    const name_tok = int.Token.init(try std.fmt.allocPrint(s.a, "{f}", .{Id{ .z = real }}));
    const src = if (schema) |sch|
        try ir.from.fullName(s.p, int.Token.init(try std.fmt.allocPrint(s.a, "{f}", .{Id{ .z = sch }})), name_tok, .{})
    else
        try ir.from.fullName(s.p, name_tok, .{}, .{});
    ir.ddl.dropIndex(s.p, src, true);
}

// =============================================================== DROP

/// DROP [TEMPORARY] TABLE [IF EXISTS] t [, t2 ...] [RESTRICT|CASCADE].
pub fn dropTable(s: *Parser, view: bool) Error!void {
    s.advance(); // TABLE / VIEW
    var if_exists = false;
    if (s.isKw("IF")) {
        s.advance();
        try s.expectKw("EXISTS");
        if_exists = true;
    }
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    var n: usize = 0;
    while (true) {
        const n1, const n2 = try s.qualifiedName();
        const tname = try s.tokName(if (n2.n != 0) n2 else n1);
        const schema: ?[]const u8 = if (n2.n != 0) try s.tokName(n1) else null;
        if (n > 0) return s.fail("xqlite: DROP {s} of several tables is not supported", .{if (view) "VIEW" else "TABLE"});
        const tab = build.findTable(s.p.db, tname, schema);
        if (tab == null and !if_exists) {
            return s.fail("Unknown table '{s}.{s}'", .{ schema orelse "main", tname });
        }
        const src = try ir.from.fullName(s.p, n1, n2, .{});
        ir.ddl.dropTable(s.p, src, view, if_exists);
        try s.check();
        if (tab) |x| catalog.codeDeleteTable(s.p, tableSchema(s, x), try s.a.dupe(u8, x.name));
        n += 1;
        if (!s.eatOp(",")) break;
    }
    _ = s.eatKw("RESTRICT") or s.eatKw("CASCADE");
}

// =============================================================== VIEW

/// CREATE [OR REPLACE] [ALGORITHM=..] [DEFINER=..] [SQL SECURITY ..] VIEW
/// [IF NOT EXISTS] v [(cols)] AS select [WITH CHECK OPTION].
pub fn createView(s: *Parser, or_replace: bool, temp: bool) Error!void {
    try s.expectKw("VIEW");
    var if_not_exists = false;
    if (s.isKw("IF")) {
        s.advance();
        try s.expectKw("NOT");
        try s.expectKw("EXISTS");
        if_not_exists = true;
    }
    const n1, const n2 = try s.qualifiedName();
    const vname = try s.tokName(if (n2.n != 0) n2 else n1);
    const schema: []const u8 = if (temp) "temp" else if (n2.n != 0) try s.tokName(n1) else "main";
    var cols: []const []const u8 = &.{};
    if (s.isOp("(")) cols = try nameList(s);
    try s.expectKw("AS");
    const start = s.tok.text.ptr;
    _ = try s.selectStmt();
    const end = s.prev_end;
    if (s.eatKw("WITH")) {
        _ = s.eatKw("CASCADED") or s.eatKw("LOCAL");
        try s.expectKw("CHECK");
        try s.expectKw("OPTION");
    }
    const body = try translateRange(s, start, end);
    var out: Writer.Allocating = .init(s.a);
    const w = &out.writer;
    w.print("CREATE {s}VIEW {s}{f}.{f}", .{ if (temp) "TEMP " else "", if (if_not_exists) "IF NOT EXISTS " else "", Id{ .z = schema }, Id{ .z = vname } }) catch return error.OutOfMemory;
    if (cols.len > 0) {
        w.writeByte('(') catch return error.OutOfMemory;
        for (cols, 0..) |c, i| {
            if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
            w.print("{f}", .{Id{ .z = c }}) catch return error.OutOfMemory;
        }
        w.writeByte(')') catch return error.OutOfMemory;
    }
    w.print(" AS {s}", .{body}) catch return error.OutOfMemory;
    const text = try out.toOwnedSliceSentinel(0);
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    if (or_replace and build.findTable(s.p.db, vname, schema) != null) {
        // The view exists: replace it when the statement runs.
        const i_db = catalog.schemaIndex(s.p, schema) orelse return error.ParseFailed;
        const sql = try std.fmt.allocPrintSentinel(s.a, "DROP VIEW {f}.{f};{s}", .{ Id{ .z = schema }, Id{ .z = vname }, text }, 0);
        catalog.codeExec(s.p, i_db, sql);
        return;
    }
    try session.lowerText(s, text);
}

// =========================================================== SEQUENCE

/// CREATE [OR REPLACE] SEQUENCE [IF NOT EXISTS] s [options] (MariaDB 10.3).
pub fn createSequence(s: *Parser) Error!void {
    try s.expectKw("SEQUENCE");
    var if_not_exists = false;
    if (s.isKw("IF")) {
        s.advance();
        try s.expectKw("NOT");
        try s.expectKw("EXISTS");
        if_not_exists = true;
    }
    const n1, const n2 = try s.qualifiedName();
    const name = try s.tokName(if (n2.n != 0) n2 else n1);
    const schema: []const u8 = if (n2.n != 0) try s.tokName(n1) else "main";
    var o: sequence.Options = .{};
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
    sequence.codeCreate(s.p, schema, name, o, if_not_exists);
    try s.check();
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
    var if_exists = false;
    if (s.isKw("IF")) {
        s.advance();
        try s.expectKw("EXISTS");
        if_exists = true;
    }
    const n1, const n2 = try s.qualifiedName();
    const name = try s.tokName(if (n2.n != 0) n2 else n1);
    const schema: []const u8 = if (n2.n != 0) try s.tokName(n1) else "main";
    // Dropping a sequence that does not exist does nothing (MariaDB
    // fails without IF EXISTS).
    if (!if_exists) {}
    try session.emptyStatement(s);
    sequence.codeDrop(s.p, schema, name);
    try s.check();
}

// ============================================================= ALTER

/// ALTER TABLE t ADD [COLUMN] def | ADD {INDEX|KEY|UNIQUE} ... | DROP
/// [COLUMN] c | DROP {INDEX|KEY} i | RENAME [TO|AS] n | RENAME COLUMN a
/// TO b: one change per statement.
pub fn alterTable(s: *Parser) Error!void {
    _ = s.eatKw("IGNORE");
    try s.expectKw("TABLE");
    const n1, const n2 = try s.qualifiedName();
    const tname = try s.tokName(if (n2.n != 0) n2 else n1);
    const schema_q: ?[]const u8 = if (n2.n != 0) try s.tokName(n1) else null;
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tab = build.findTable(s.p.db, tname, schema_q) orelse return s.fail("Table '{s}' doesn't exist", .{tname});
    const real = try s.a.dupe(u8, tab.name);
    const schema = tableSchema(s, tab);
    const T = Id{ .z = real };
    const S = Id{ .z = schema };
    if (s.eatKw("ADD")) {
        if (s.isKw("INDEX") or s.isKw("KEY") or s.isKw("UNIQUE") or s.isKw("FULLTEXT") or s.isKw("SPATIAL")) {
            var t: Table = .{};
            try createDefinition(s, &t);
            const ix = t.indexes.items[0];
            const iname = ix.name orelse ix.cols[0].name;
            var out: Writer.Allocating = .init(s.a);
            const w = &out.writer;
            w.print("CREATE {s}INDEX {f}.{f} ON {f}(", .{ if (ix.unique) "UNIQUE " else "", S, Id{ .z = try sqliteIndexName(s.a, real, iname) }, T }) catch return error.OutOfMemory;
            for (ix.cols, 0..) |k, i| {
                if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
                w.print("{f}{s}", .{ Id{ .z = k.name }, if (k.desc) " DESC" else "" }) catch return error.OutOfMemory;
            }
            w.writeByte(')') catch return error.OutOfMemory;
            try session.lowerText(s, try out.toOwnedSliceSentinel(0));
            return endAlter(s);
        }
        if (s.isKw("PRIMARY") or s.isKw("CONSTRAINT") or s.isKw("FOREIGN") or s.isKw("CHECK")) {
            return s.fail("xqlite: ALTER TABLE ADD {s} is not supported", .{s.tok.text});
        }
        _ = s.eatKw("COLUMN");
        if (s.isKw("IF")) {
            s.advance();
            try s.expectKw("NOT");
            try s.expectKw("EXISTS");
        }
        var t: Table = .{};
        try columnDefinition(s, &t);
        if (s.eatKw("FIRST")) {} else if (s.eatKw("AFTER")) _ = try s.anyName();
        const c = &t.columns.items[0];
        if (c.primary or c.autoinc or c.unique) return s.fail("xqlite: ALTER TABLE ADD of a key column is not supported", .{});
        try finishTable(s, &t);
        var out: Writer.Allocating = .init(s.a);
        const w = &out.writer;
        w.print("ALTER TABLE {f}.{f} ADD COLUMN ", .{ S, T }) catch return error.OutOfMemory;
        renderColumn(w, c, false) catch return error.OutOfMemory;
        try session.lowerText(s, try out.toOwnedSliceSentinel(0));
        var cat: Writer.Allocating = .init(s.a);
        cat.writer.print(catalog_ddl ++ ";INSERT OR REPLACE INTO {f}.xq_catalog VALUES({f},'','dialect','mariadb')", .{ S, S, Q{ .z = real } }) catch return error.OutOfMemory;
        try catalogColumn(s, &cat.writer, schema, real, c);
        cat.writer.writeByte(';') catch return error.OutOfMemory;
        catalog.codeExec(s.p, catalog.schemaIndex(s.p, schema) orelse return error.ParseFailed, try cat.toOwnedSliceSentinel(0));
        return endAlter(s);
    }
    if (s.eatKw("DROP")) {
        if (s.eatKw("INDEX") or s.eatKw("KEY")) {
            const iname = try s.nameText(try s.anyName());
            var idx = try sqliteIndexName(s.a, real, iname);
            if (build.findIndex(s.p.db, idx, schema) == null) idx = iname;
            try session.lowerText(s, try std.fmt.allocPrintSentinel(s.a, "DROP INDEX {f}.{f}", .{ S, Id{ .z = idx } }, 0));
            return endAlter(s);
        }
        if (s.isKw("PRIMARY") or s.isKw("FOREIGN") or s.isKw("CONSTRAINT") or s.isKw("CHECK")) {
            return s.fail("xqlite: ALTER TABLE DROP {s} is not supported", .{s.tok.text});
        }
        _ = s.eatKw("COLUMN");
        const c = try s.nameText(try s.anyName());
        try session.lowerText(s, try std.fmt.allocPrintSentinel(s.a, "ALTER TABLE {f}.{f} DROP COLUMN {f}", .{ S, T, Id{ .z = c } }, 0));
        if (catalog.exists(s.p.db, schema)) {
            catalog.codeExecFmt(s.p, schema, "DELETE FROM %Q.xq_catalog WHERE tbl=%Q AND col=%Q", &.{ .{ .str = schema }, .{ .str = real }, .{ .str = c } });
        }
        return endAlter(s);
    }
    if (s.eatKw("RENAME")) {
        if (s.eatKw("COLUMN")) {
            const a = try s.nameText(try s.anyName());
            try s.expectKw("TO");
            const b = try s.nameText(try s.anyName());
            try session.lowerText(s, try std.fmt.allocPrintSentinel(s.a, "ALTER TABLE {f}.{f} RENAME COLUMN {f} TO {f}", .{ S, T, Id{ .z = a }, Id{ .z = b } }, 0));
            if (catalog.exists(s.p.db, schema)) {
                catalog.codeExecFmt(s.p, schema, "UPDATE %Q.xq_catalog SET col=%Q WHERE tbl=%Q AND col=%Q", &.{ .{ .str = schema }, .{ .str = b }, .{ .str = real }, .{ .str = a } });
            }
            return endAlter(s);
        }
        if (s.isKw("INDEX") or s.isKw("KEY")) return s.fail("xqlite: ALTER TABLE RENAME INDEX is not supported", .{});
        _ = s.eatKw("TO") or s.eatKw("AS");
        const new = try s.nameText(try s.anyName());
        try renameTable(s, schema, real, new);
        return endAlter(s);
    }
    if (s.isKw("DISABLE") or s.isKw("ENABLE")) {
        // DISABLE/ENABLE KEYS (mysqldump): nothing to do.
        s.advance();
        try s.expectKw("KEYS");
        return session.emptyStatement(s);
    }
    if (s.isKw("ENGINE") or s.isKw("DEFAULT") or s.isKw("CHARSET") or s.isKw("CHARACTER") or s.isKw("COMMENT") or s.isKw("AUTO_INCREMENT") or s.isKw("CONVERT")) {
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

fn renameTable(s: *Parser, schema: []const u8, old: []const u8, new: []const u8) Error!void {
    try session.lowerText(s, try std.fmt.allocPrintSentinel(s.a, "ALTER TABLE {f}.{f} RENAME TO {f}", .{ Id{ .z = schema }, Id{ .z = old }, Id{ .z = new } }, 0));
    catalog.codeRenameTable(s.p, schema, old, new);
}

/// RENAME TABLE a TO b.
pub fn renameTableStmt(s: *Parser) Error!void {
    try s.expectKw("TABLE");
    const n1, const n2 = try s.qualifiedName();
    try s.expectKw("TO");
    const m1, const m2 = try s.qualifiedName();
    if (s.isOp(",")) return s.fail("xqlite: RENAME TABLE of several tables is not supported", .{});
    ir.stmt.readSchema(s.p) catch return error.ParseFailed;
    const tname = try s.tokName(if (n2.n != 0) n2 else n1);
    const tab = build.findTable(s.p.db, tname, if (n2.n != 0) try s.tokName(n1) else null) orelse
        return s.fail("Table '{s}' doesn't exist", .{tname});
    const new = try s.tokName(if (m2.n != 0) m2 else m1);
    try renameTable(s, tableSchema(s, tab), try s.a.dupe(u8, tab.name), new);
}

// ======================================================= translation

/// SQLite text for the MariaDB text from `start` to `end` (an
/// expression or a SELECT the parser accepted): tokens re-quoted and
/// operators/functions spelled as SQLite spells them.
pub fn translateRange(s: *Parser, start: [*]const u8, end: [*]const u8) Error![]const u8 {
    const sql = s.lx.sql;
    var lx = s.lx;
    lx.pos = @intFromPtr(start) - @intFromPtr(sql.ptr);
    lx.exec_depth = 0;
    const stop = @intFromPtr(end) - @intFromPtr(sql.ptr);
    var out: std.ArrayList(u8) = .empty;
    const escapes = !s.mode.has(.NO_BACKSLASH_ESCAPES);
    var prev: ?Token = null;
    var paren_func: std.ArrayList(bool) = .empty;
    while (lx.pos < stop) {
        const t = lx.next();
        if (t.kind == .eof or @intFromPtr(t.text.ptr) >= @intFromPtr(end)) break;
        const next_tok = blk: {
            var c = lx;
            break :blk c.next();
        };
        if (out.items.len > 0) try out.append(s.a, ' ');
        switch (t.kind) {
            .string => {
                const v = try lexer.stringValue(s.a, t, escapes);
                try out.print(s.a, "{f}", .{Q{ .z = v }});
            },
            .quoted_ident => try out.print(s.a, "{f}", .{Id{ .z = try lexer.identValue(s.a, t) }}),
            .hex => try out.print(s.a, "x'{s}'", .{(try lexer.hexDigits(s.a, t)) orelse return s.syntaxErrorAt(t)}),
            .bit => try out.print(s.a, "{d}", .{lexer.bitValue(t) orelse 0}),
            .integer, .float, .param => try out.appendSlice(s.a, t.text),
            .user_var, .sys_var => return s.fail("xqlite: variables are not supported in stored expressions", .{}),
            .op => {
                if (t.is("&&")) {
                    try out.appendSlice(s.a, "AND");
                } else if (t.is("||")) {
                    try out.appendSlice(s.a, if (s.mode.has(.PIPES_AS_CONCAT)) "||" else "OR");
                } else if (t.is("!")) {
                    try out.appendSlice(s.a, "NOT");
                } else if (t.is("<=>")) {
                    try out.appendSlice(s.a, "IS");
                } else if (t.is("/")) {
                    try out.appendSlice(s.a, "*1.0/");
                } else if (t.is("^") or t.is(":=")) {
                    return s.fail("xqlite: operator {s} is not supported in stored expressions", .{t.text});
                } else if (t.is("(")) {
                    try paren_func.append(s.a, prev != null and prev.?.kind == .ident);
                    try out.appendSlice(s.a, t.text);
                } else if (t.is(")")) {
                    _ = paren_func.pop();
                    try out.appendSlice(s.a, t.text);
                } else try out.appendSlice(s.a, t.text);
            },
            .ident => {
                if (next_tok.is("(")) {
                    try out.appendSlice(s.a, functionName(t.text));
                } else if (t.isKw("DIV") or t.isKw("XOR") or t.isKw("INTERVAL")) {
                    return s.fail("xqlite: {s} is not supported in stored expressions", .{t.text});
                } else if (t.isKw("MOD")) {
                    try out.appendSlice(s.a, "%");
                } else if (t.isKw("SEPARATOR")) {
                    try out.appendSlice(s.a, ",");
                } else if (t.isKw("SIGNED") or t.isKw("UNSIGNED")) {
                    try out.appendSlice(s.a, "INTEGER");
                    if (next_tok.isKw("INTEGER") or next_tok.isKw("INT")) _ = lx.next();
                } else if (t.isKw("STRAIGHT_JOIN")) {
                    try out.appendSlice(s.a, if (prev != null and prev.?.isKw("SELECT")) "" else "CROSS JOIN");
                } else if (t.isKw("DISTINCTROW")) {
                    try out.appendSlice(s.a, "DISTINCT");
                } else if (t.isKw("SQL_CALC_FOUND_ROWS") or t.isKw("SQL_NO_CACHE") or t.isKw("SQL_CACHE") or
                    t.isKw("HIGH_PRIORITY") or t.isKw("SQL_SMALL_RESULT") or t.isKw("SQL_BIG_RESULT") or t.isKw("SQL_BUFFER_RESULT"))
                {} else if (t.isKw("FROM") and next_tok.isKw("DUAL")) {
                    _ = lx.next();
                } else if (t.isKw("TRUE") or t.isKw("FALSE")) {
                    try out.appendSlice(s.a, if (t.isKw("TRUE")) "1" else "0");
                } else if ((t.isKw("CURRENT_TIMESTAMP") or t.isKw("LOCALTIMESTAMP") or t.isKw("LOCALTIME")) and !next_tok.is("(")) {
                    try out.appendSlice(s.a, "CURRENT_TIMESTAMP");
                } else if (t.text[0] == '_' and next_tok.kind == .string) {
                    // A character set introducer.
                } else try out.appendSlice(s.a, t.text);
            },
            else => return s.syntaxErrorAt(t),
        }
        prev = t;
    }
    return out.items;
}

/// SQLite's name for a MariaDB function in stored text.
fn functionName(n: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "ucase", "upper" },        .{ "lcase", "lower" },                      .{ "length", "octet_length" },
        .{ "char_length", "length" }, .{ "character_length", "length" },          .{ "mid", "substr" },
        .{ "substring", "substr" },   .{ "now", "datetime" },                     .{ "greatest", "max" },
        .{ "least", "min" },          .{ "last_insert_id", "last_insert_rowid" }, .{ "curdate", "date" },
        .{ "curtime", "time" },       .{ "sysdate", "datetime" },                 .{ "utc_timestamp", "datetime" },
        .{ "utc_date", "date" },      .{ "utc_time", "time" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(n, m[0])) return m[1];
    return n;
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
    if (catalog.exists(s.p.db, schema)) {
        var q = catalog.Query.initFmt(s.p.db, "SELECT col, key, value FROM %Q.xq_catalog WHERE tbl=%Q", &.{ .{ .str = schema }, .{ .str = tname } }) catch
            return s.fail("{s}", .{@import("../../sql/main.zig").errmsg(s.p.db)});
        defer q.deinit();
        while (q.step() catch false) {
            const col = try s.a.dupe(u8, api.columnText(q.v, 0) orelse "");
            const key = api.columnText(q.v, 1) orelse "";
            const val = try s.a.dupe(u8, api.columnText(q.v, 2) orelse "");
            const lc = try std.ascii.allocLowerString(s.a, col);
            if (std.mem.eql(u8, key, "type")) try types_by_col.put(s.a, lc, val);
            if (std.mem.eql(u8, key, "default")) try defaults.put(s.a, lc, val);
            if (std.mem.eql(u8, key, "mariadb.auto_increment")) autoinc = col;
        }
    }
    const tab2 = build.findTable(s.p.db, tname, schema) orelse return sqlite_sql;
    if (tab2.isView() or types_by_col.count() == 0) return sqlite_sql;
    var out: Writer.Allocating = .init(s.a);
    const w = &out.writer;
    const B = struct {
        z: []const u8,
        pub fn format(b: @This(), wr: *Writer) Writer.Error!void {
            try wr.writeByte('`');
            for (b.z) |c| {
                if (c == '`') try wr.writeByte('`');
                try wr.writeByte(c);
            }
            try wr.writeByte('`');
        }
    };
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
