//! The loadable extension (`zig build ext`, docs/extension.md) in sqlite3:
//! a database xqlite writes in a dialect, whose schema calls engine
//! functions and names dialect collations, read and written by sqlite3
//! with the extension loaded (`.load`), and the extension's functions
//! against xqlite's on the same calls.
//!
//! For each dialect built in, on a database its script builds:
//!
//!  - integrity: sqlite3 with the extension passes PRAGMA integrity_check
//!    (which recomputes every expression index and checks every CHECK);
//!    sqlite3 alone cannot;
//!  - reads: CHECKs, generated columns, views and defaults evaluate in
//!    sqlite3 as in xqlite (the SQLite dialect, and the dialect for what
//!    only it reads: the dialect collations);
//!  - rejects: a row that breaks a dialect CHECK fails in sqlite3 with
//!    xqlite's error;
//!  - writes: rows sqlite3 writes (jsonb, arrays, intervals, numerics,
//!    booleans, identities from xq_sequence) pass xqlite's integrity
//!    check (xqlite recomputes the index entries sqlite3 made) and read
//!    back in the dialect.
//!
//! And for the functions themselves:
//!
//!  - abi: tools/ext/abi-*.sql give the recorded tools/ext/abi-*.out, in
//!    xqlite and in sqlite3 with the extension: a function the schema
//!    may call never changes meaning (src/dialect/abi.zig). With
//!    XQT_EXT_RECORD=1 the outputs are recorded instead (from xqlite);
//!  - generated calls: every deterministic xq_* function sqlite3 lists
//!    (pragma_function_list) called with arguments from a pool of edge
//!    values (NULLs, extreme integers, reals, texts, blobs, JSON, arrays,
//!    intervals, dates ...), in both engines: the same values and the
//!    same errors. XQT_SEED chooses the seed (default fixed).

const std = @import("std");
const xqt = @import("xqt");
const xqlite_config = @import("xqlite_config");
const Check = xqt.Check;
const BaseDb = @import("base_db.zig");

pub const name = "ext";
pub const about = "the loadable extension in sqlite3: dialect schemas, ABI cases, generated calls";

pub fn register(s: *xqt.Suite) !void {
    const a = s.arena.allocator();
    // The long ones first.
    for (0..call_shards) |i| try s.add(try std.fmt.allocPrint(a, "generated calls ({d}/{d})", .{ i + 1, call_shards }), generatedCalls, .{i});
    inline for (specs) |sp| {
        if (comptime @field(xqlite_config, "dialect_" ++ sp.dialect)) {
            const base = try a.create(BaseDb);
            base.* = .{ .build = struct {
                fn f(c: *Check, file: []const u8) !void {
                    _ = try c.runOk(&.{ c.cfg.xq, "sql", file }, .{ .stdin = sp.script });
                }
            }.f };
            try s.add(sp.tag ++ ": integrity", integrity, .{ base, &sp });
            try s.add(sp.tag ++ ": reads", reads, .{ base, &sp });
            for (sp.rejects) |stmt| try s.add(try std.fmt.allocPrint(a, sp.tag ++ ": sqlite3 rejects: {s}", .{stmt}), rejects, .{ base, &sp, stmt });
            try s.add(sp.tag ++ ": writes", writes, .{ base, &sp });
            try s.add(sp.tag ++ ": Python's sqlite3", python, .{ base, &sp });
            for (sp.abi) |t| try s.add(try std.fmt.allocPrint(a, "abi cases {s}", .{t}), abiCases, .{t});
        }
    }
    try s.add("abi cases core", abiCases, .{"core"});
    try s.add("load and version", loadVersion, .{});
}

// ============================================================ the dialects

const Spec = struct {
    tag: []const u8,
    /// The -Ddialects name.
    dialect: []const u8,
    db: []const u8,
    /// Builds the database, in xqlite.
    script: []const u8,
    /// Queries both engines read the same (xqlite in the SQLite dialect).
    reads: []const u8,
    /// Queries xqlite runs in the dialect (they name dialect collations,
    /// which xqlite finds in that dialect only) and sqlite3 as written.
    dialect_reads: []const u8 = "",
    /// Statements both engines reject with the same error.
    rejects: []const []const u8,
    /// What sqlite3 writes (it must succeed).
    writes: []const u8,
    /// Then xqlite reads, in the dialect ...
    read_back: []const u8,
    /// ... and prints this.
    want: []const u8,
    /// tools/ext/abi-NAME.sql of the dialect.
    abi: []const []const u8,
};

const specs = [_]Spec{ pg, maria, mssql, oracle };

const pg: Spec = .{
    .tag = "pg",
    .dialect = "postgres",
    .abi = &.{ "pg", "pg-dialect" },
    .db = "ext-pg.db",
    .script =
    \\.dialect postgres
    \\CREATE TABLE doc (
    \\  id serial PRIMARY KEY,
    \\  k int NOT NULL,
    \\  body jsonb NOT NULL CHECK (body ? 'kind'),
    \\  tags text[] DEFAULT '{a,b}',
    \\  nums int[],
    \\  span interval,
    \\  price numeric(10,2) CHECK (price >= 0),
    \\  active boolean DEFAULT true,
    \\  name text CHECK (name ~ '^[a-z]+$'),
    \\  title varchar(10),
    \\  seen date,
    \\  at timestamptz,
    \\  kind text GENERATED ALWAYS AS (body ->> 'kind') STORED,
    \\  half int GENERATED ALWAYS AS (k / 2) STORED,
    \\  pat text CHECK (pat LIKE 'p%' OR pat ILIKE 'Q%')
    \\);
    \\CREATE TABLE item (doc_id int, id int GENERATED BY DEFAULT AS IDENTITY, note text, PRIMARY KEY (doc_id, id));
    \\CREATE INDEX doc_kind ON doc ((body ->> 'kind'));
    \\CREATE INDEX doc_body ON doc (body);
    \\CREATE INDEX doc_tags ON doc (tags);
    \\CREATE INDEX doc_span ON doc (span);
    \\CREATE INDEX doc_span2 ON doc ((span + interval '1 day'));
    \\CREATE INDEX doc_nums1 ON doc ((nums[1]));
    \\CREATE INDEX doc_seen ON doc ((seen + 7));
    \\CREATE INDEX doc_price ON doc (price);
    \\CREATE INDEX doc_price2 ON doc ((price * 2 + 1));
    \\CREATE INDEX doc_path ON doc ((body #>> '{a,b}'));
    \\CREATE INDEX doc_contains ON doc ((body @> '{"kind":"a"}'), (tags && '{x,c}'));
    \\CREATE VIEW doc_v AS SELECT id, body -> 'kind' AS kind_json, body @> '{"kind":"a"}' AS is_a, tags[1] AS tag1, array_length(nums, 1) AS n, (span * 2)::text AS span2, (price / 3)::text AS third, left(name, 2) AS l2, seen + interval '1 month' AS next_month, jsonb_typeof(body) AS t, 7 / 2 AS idiv, name ILIKE 'A%' AS ia, jsonb_set(body, '{z}', '5') AS z5 FROM doc;
    \\CREATE VIEW doc_order AS SELECT id FROM doc ORDER BY body, span, tags, nums, id;
    \\CREATE VIEW kinds AS SELECT kind, count(*) AS n, array_agg(id ORDER BY id) AS ids, jsonb_agg(body ORDER BY id) AS bodies, string_agg(name, ',' ORDER BY name) AS names FROM doc GROUP BY kind;
    \\INSERT INTO doc (k, body, tags, nums, span, price, name, title, seen, at, pat) VALUES
    \\ (1, '{"kind":"a","a":{"b":"x"},"z":[1,2]}', '{x,y}', '{3,1,2}', '1 day 2 hours', 10.5, 'abc', 'first', '2024-02-29', '2024-02-29 10:00:00+00', 'p1'),
    \\ (2, '{"kind":"b","n":1.50}', '{"a b",NULL}', '{10}', '-1 mon', 0, 'zed', 'second', '2023-12-31', '2023-12-31 23:59:59+02', 'Qx'),
    \\ (5, '{"kind":"a"}', DEFAULT, '{}', '1 year 2 mons 3 days 04:05:06.5', 1.25, 'mm', NULL, '2000-01-01', NULL, NULL),
    \\ (7, '{"kind":"c","a":{"b":"y"}}', '{c}', '{-1,5}', '00:00:30', 99.99, 'q', 't', '1999-12-31', '1999-12-31 12:00:00+00', 'pp');
    \\INSERT INTO item (doc_id, note) VALUES (1, 'n1'), (1, 'n2'), (2, 'n3');
    \\CREATE TABLE tok (u uuid PRIMARY KEY DEFAULT gen_random_uuid(), v uuid UNIQUE CHECK (v <> '00000000-0000-0000-0000-000000000000'), t uuid DEFAULT uuidv7());
    \\CREATE INDEX tok_text ON tok ((v::text));
    \\INSERT INTO tok (v) VALUES ('A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11'), ('{11111111111111111111111111111111}');
    \\
    ,
    .reads =
    \\PRAGMA integrity_check;
    \\SELECT id, json(kind_json), is_a, tag1, n, span2, third, l2, next_month, t, idiv, ia, json(z5) FROM doc_v ORDER BY id;
    \\SELECT * FROM kinds ORDER BY kind;
    \\SELECT id, kind, half, tags, active FROM doc ORDER BY id;
    \\SELECT id FROM doc INDEXED BY doc_span2 WHERE xq_pg_iv_interval_pl(span, xq_pg_iv('1 day')) > xq_pg_iv_high('1 day') ORDER BY id;
    \\SELECT id FROM doc INDEXED BY doc_kind WHERE xq_pg_jsonb_get_text(body, 'kind') = 'a' ORDER BY id;
    \\SELECT id, xq_dec_text(price, 2) FROM doc INDEXED BY doc_price WHERE price > xq_dec_key('1.25') AND price <= xq_dec_key(99.99) ORDER BY price;
    \\SELECT id FROM doc INDEXED BY doc_price2 WHERE xq_dec_key(xq_dec_add(xq_dec_mul(xq_dec(price, 1000, 2), 2), 1)) = xq_dec_key(22) ORDER BY id;
    \\SELECT doc_id, id, note FROM item ORDER BY 1, 2;
    \\SELECT xq_pg_jsonb_exists(body, 'kind'), xq_pg_regex(name, '^[a-z]+$', ''), xq_pg_array_valid(tags) FROM doc ORDER BY id;
    \\SELECT hex(v), length(u), xq_postgres_uuid_extract_version(u), xq_postgres_uuid_extract_version(t) FROM tok ORDER BY v;
    \\SELECT hex(v) FROM tok INDEXED BY tok_text WHERE xq_pg_uuid_text(v) = 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11';
    \\
    ,
    .dialect_reads =
    \\SELECT id FROM doc_order;
    \\SELECT id FROM doc ORDER BY span COLLATE xq_pg_interval, id;
    \\SELECT id FROM doc ORDER BY body COLLATE xq_pg_jsonb, id;
    \\SELECT id FROM doc ORDER BY nums COLLATE xq_pg_array_num, id;
    \\
    ,
    .rejects = &.{
        "INSERT INTO doc (k, body) VALUES (1, xq_pg_jsonb_bin('{\"no\":1}'))",
        "INSERT INTO doc (k, body, name) VALUES (1, jsonb('{\"kind\":1}'), 'ABC')",
        "INSERT INTO doc (k, body, tags) VALUES (1, jsonb('{\"kind\":1}'), '{a,')",
        "INSERT INTO doc (k, body, pat) VALUES (1, jsonb('{\"kind\":1}'), 'zz')",
        "INSERT INTO doc (k, body, price) VALUES (1, jsonb('{\"kind\":1}'), -1)",
        "UPDATE doc SET k = 3000000000 WHERE id = 1",
        "INSERT INTO tok (v) VALUES (x'0102')",
        "INSERT INTO tok (v) VALUES (x'00000000000000000000000000000000')",
    },
    .writes =
    \\INSERT INTO doc (id, k, body, tags, nums, span, price, active, name, title, seen, at, pat) VALUES
    \\ (11, 11, xq_pg_jsonb_bin('{"z":0,"kind":"w","a":{"b":"q"}}'), '{w,"x y"}', '{9,8}', xq_pg_iv('3 days 1 hour'), xq_dec_key(7.25), 0, 'www', 'sq', '2024-03-01', '2024-03-01 00:00:00', 'pz');
    \\INSERT INTO doc (id, k, body, nums, span) VALUES (12, 12, jsonb('{"kind":"v","a":{"b":"r"}}'), '{-3}', xq_pg_iv('-2 days'));
    \\UPDATE doc SET span = xq_pg_iv_interval_pl(span, xq_pg_iv('1 hour')), tags = xq_pg_array_append(tags, 'n') WHERE id = 1;
    \\INSERT INTO item (doc_id, note) VALUES (11, 'by sqlite3'), (11, 'again');
    \\SELECT nextval('item_id_seq'), currval('item_id_seq'), lastval();
    \\INSERT INTO tok (v) VALUES (xq_pg_uuid('22222222-2222-2222-2222-222222222222'));
    \\
    ,
    .read_back =
    \\.dialect postgres
    \\SELECT id, body -> 'kind', kind, tags[1], tags, nums[1], span, span + interval '1 day', price, active, half FROM doc WHERE id IN (1, 11, 12) ORDER BY id;
    \\SELECT doc_id, id, note FROM item ORDER BY doc_id, id;
    \\INSERT INTO item (doc_id, note) VALUES (12, 'xqlite') RETURNING id;
    \\SELECT id FROM doc WHERE body @> '{"kind":"w"}';
    \\SELECT v, uuid_extract_version(u) FROM tok WHERE v > '1fffffff-ffff-ffff-ffff-ffffffffffff' ORDER BY v;
    \\
    ,
    .want =
    \\1|"a"|a|x|{x,y,n}|3|1 day 03:00:00|2 days 03:00:00|10.50|t|0
    \\11|"w"|w|w|{w,"x y"}|9|3 days 01:00:00|4 days 01:00:00|7.25|f|5
    \\12|"v"|v|a|{a,b}|-3|-2 days|-1 days||t|6
    \\1|1|n1
    \\1|2|n2
    \\2|3|n3
    \\11|4|by sqlite3
    \\11|5|again
    \\7
    \\11
    \\22222222-2222-2222-2222-222222222222|4
    \\a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11|4
    \\
    ,
};

const maria: Spec = .{
    .tag = "mariadb",
    .dialect = "mariadb",
    .abi = &.{"mariadb"},
    .db = "ext-maria.db",
    .script =
    \\.dialect mariadb
    \\CREATE TABLE t (
    \\  id int AUTO_INCREMENT PRIMARY KEY,
    \\  k int NOT NULL,
    \\  x varchar(8) CHECK (x LIKE 'a%'),
    \\  d datetime,
    \\  j json,
    \\  half int AS (k DIV 2) STORED,
    \\  bits int AS (k XOR 3) VIRTUAL,
    \\  jv varchar(20) AS (JSON_VALUE(j, '$.a')) VIRTUAL,
    \\  nd datetime AS (DATE_ADD(d, INTERVAL 1 DAY)) VIRTUAL,
    \\  e enum('red','green') DEFAULT 'red',
    \\  b bool DEFAULT false,
    \\  f decimal(6,2),
    \\  c char(3)
    \\);
    \\CREATE INDEX t_k ON t (k);
    \\CREATE INDEX t_half ON t (half);
    \\CREATE INDEX t_jv ON t (jv);
    \\CREATE INDEX t_nd ON t (nd, bits);
    \\CREATE SEQUENCE s1 START WITH 10;
    \\CREATE VIEW v AS SELECT id, k DIV 3 AS k3, k MOD 4 AS k4, x XOR 1 AS xx, DATE_ADD(d, INTERVAL 1 MONTH) AS dm, EXTRACT(YEAR FROM d) AS y, TIMESTAMPDIFF(DAY, d, '2025-01-01') AS td, JSON_EXTRACT(j, '$.a') AS ja, JSON_UNQUOTE(JSON_EXTRACT(j, '$.s')) AS js, CONCAT(x, '-', c) AS xc, LEFT(x, 2) AS l, LPAD(c, 5, '*') AS lp, ROUND(f, 1) AS r, CAST(k AS CHAR) AS kc, IF(b, 'yes', 'no') AS yn, JSON_LENGTH(j) AS jl, DATE_FORMAT(d, '%Y/%m/%d %H') AS df FROM t;
    \\CREATE VIEW agg AS SELECT e, COUNT(*) AS n, STDDEV_POP(k) AS sd, VAR_SAMP(k) AS vs, JSON_ARRAYAGG(k) AS ks FROM t GROUP BY e;
    \\INSERT INTO t (k, x, d, j, e, b, f, c) VALUES
    \\ (1, 'abc', '2024-02-29 10:11:12', '{"a": 1, "s": "q"}', 'green', true, 12.345, 'zz'),
    \\ (4, 'aa', '2023-12-31 23:59:59', '{"a": [1,2], "s": "r"}', 'red', false, -1.5, 'y'),
    \\ (9, 'ab', '2000-01-01 00:00:00', '{"b": null}', 'red', true, 0, 'xyz');
    \\SELECT NEXTVAL(s1);
    \\
    ,
    .reads =
    \\PRAGMA integrity_check;
    \\SELECT * FROM v ORDER BY id;
    \\SELECT * FROM agg ORDER BY e;
    \\SELECT id, half, bits, jv, nd FROM t ORDER BY id;
    \\SELECT id FROM t INDEXED BY "t$t_nd" WHERE nd > '2001-01-01' ORDER BY id;
    \\SELECT * FROM xq_sequence;
    \\
    ,
    .rejects = &.{
        "INSERT INTO t (k, x) VALUES (1, 'zz')",
        "INSERT INTO t (k, j) VALUES (1, '{')",
        "INSERT INTO t (k, half) VALUES (1, 2)",
    },
    .writes =
    \\INSERT INTO t (k, x, d, j, e, b, f, c) VALUES (21, 'az', '2024-12-31 23:00:00', '{"a": "w", "s": "t"}', 'green', 1, 3.5, 'q');
    \\INSERT INTO t (k, j) VALUES (-7, '[1,2,3]');
    \\UPDATE t SET k = k + 10, d = xq_date_add(d, 2, 'DAY') WHERE id = 1;
    \\SELECT xq_mariadb_nextval('s1'), xq_mariadb_lastval('s1'), xq_mariadb_setval('s1', 50);
    \\
    ,
    .read_back =
    \\.dialect mariadb
    \\SELECT id, k, half, bits, jv, nd, e, b, f FROM t ORDER BY id;
    \\SELECT NEXTVAL(s1);
    \\SELECT id FROM t WHERE jv = 'w';
    \\
    ,
    .want =
    \\1|11|5|0|1|2024-03-03 10:11:12|green|1|12.35
    \\2|4|2|0||2024-01-01 23:59:59|red|0|-1.50
    \\3|9|4|0||2000-01-02 00:00:00|red|1|0.00
    \\4|21|10|0|w|2025-01-01 23:00:00|green|1|3.50
    \\5|-7|-3|0|||red|0|
    \\51
    \\4
    \\
    ,
};

const mssql: Spec = .{
    .tag = "mssql",
    .dialect = "mssql",
    .abi = &.{"mssql"},
    .db = "ext-mssql.db",
    .script =
    \\.dialect mssql
    \\CREATE TABLE t (
    \\  id int IDENTITY(1,1) PRIMARY KEY,
    \\  k int NOT NULL,
    \\  s nvarchar(10) CHECK (s LIKE 'a%'),
    \\  d datetime2 CHECK (DATEPART(year, d) > 1990),
    \\  m money,
    \\  j nvarchar(200) CHECK (ISJSON(j) = 1),
    \\  g AS (k * 2) PERSISTED,
    \\  jv AS (JSON_VALUE(j, '$.a')) PERSISTED,
    \\  l3 AS (LEFT(s, 3)) PERSISTED,
    \\  dd AS (DATEADD(day, 1, d)) PERSISTED,
    \\  b bit DEFAULT 1
    \\);
    \\CREATE TABLE item (a int NOT NULL, id int IDENTITY(5,5), PRIMARY KEY (a));
    \\CREATE INDEX t_jv ON t (jv);
    \\CREATE INDEX t_l3 ON t (l3, dd);
    \\CREATE VIEW v AS SELECT id, k + 1 AS k1, LEFT(s, 2) AS l, DATEADD(day, 1, d) AS dd, DATEDIFF(day, d, '2025-01-01') AS ddiff, DATEPART(year, d) AS y, JSON_VALUE(j, '$.a') AS jv, JSON_QUERY(j, '$.b') AS jq, CHARINDEX('b', s) AS ci, REPLICATE(s, 2) AS rep, STUFF(s, 1, 1, 'Z') AS st, CAST(k AS varchar(5)) AS kc, TRY_CAST(s AS int) AS ti, ROUND(m, 1) AS r, k / 2 AS half, CONVERT(varchar(10), d, 23) AS cv FROM t;
    \\CREATE VIEW agg AS SELECT b, COUNT(*) AS n, AVG(k) AS av FROM t GROUP BY b;
    \\INSERT INTO t (k, s, d, m, j) VALUES (1, 'abc', '2024-02-29 10:11:12', 12.3456, '{"a": 1, "b": [1]}'), (4, 'ab', '2023-12-31', -1.5, '{"a": "x"}'), (9, 'a', '2000-01-01', 0, NULL);
    \\INSERT INTO item (a) VALUES (1), (2);
    \\
    ,
    .reads =
    \\PRAGMA integrity_check;
    \\SELECT * FROM v ORDER BY id;
    \\SELECT * FROM agg ORDER BY b;
    \\SELECT id, g, jv, l3, dd FROM t ORDER BY id;
    \\SELECT id FROM t INDEXED BY t_jv WHERE jv = 'x';
    \\SELECT * FROM item ORDER BY a;
    \\
    ,
    .rejects = &.{
        "INSERT INTO t (k, s) VALUES (1, 'zz')",
        "INSERT INTO t (k, j) VALUES (1, '\"just a string\"')",
        "INSERT INTO t (k, s) VALUES (1, 'a23456789012')",
        "INSERT INTO t (k, d) VALUES (1, '1980-01-01')",
    },
    .writes =
    \\INSERT INTO t (id, k, s, d, m, j) VALUES (100, 21, 'axyz', '2024-12-31 23:00:00', 2.5, '{"a": "w"}');
    \\INSERT INTO item (a) VALUES (3), (4);
    \\
    ,
    .read_back =
    \\.dialect mssql
    \\SELECT id, k, g, jv, l3, dd FROM t WHERE id = 100;
    \\SELECT a, id FROM item ORDER BY a;
    \\INSERT INTO item (a) VALUES (5);
    \\SELECT a, id FROM item WHERE a = 5;
    \\
    ,
    .want =
    \\100|21|42|w|axy|2025-01-01 23:00:00
    \\1|5
    \\2|10
    \\3|15
    \\4|20
    \\5|25
    \\
    ,
};

const oracle: Spec = .{
    .tag = "oracle",
    .dialect = "oracle",
    .abi = &.{"oracle"},
    .db = "ext-oracle.db",
    .script =
    \\.dialect oracle
    \\CREATE TABLE t (
    \\  id NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    \\  k NUMBER(5) NOT NULL,
    \\  s VARCHAR2(10) CHECK (s LIKE 'a%'),
    \\  d DATE,
    \\  n NUMBER(8,2),
    \\  j CLOB CHECK (j IS JSON),
    \\  g NUMBER GENERATED ALWAYS AS (k * 2) VIRTUAL,
    \\  sub VARCHAR2(10) GENERATED ALWAYS AS (SUBSTR(s, 2)) VIRTUAL
    \\);
    \\CREATE TABLE item (a NUMBER PRIMARY KEY, id NUMBER GENERATED BY DEFAULT AS IDENTITY);
    \\CREATE INDEX t_sub ON t (SUBSTR(s, 1, 2));
    \\CREATE INDEX t_jv ON t (JSON_VALUE(j, '$.a'));
    \\CREATE INDEX t_up ON t (UPPER(s), TRUNC(n));
    \\CREATE INDEX t_am ON t (ADD_MONTHS(d, 1));
    \\CREATE VIEW v AS SELECT id, k / 3 AS k3, SUBSTR(s, 2) AS ss, INSTR(s, 'b') AS ib, ADD_MONTHS(d, 1) AS am, MONTHS_BETWEEN(DATE '2025-01-01', d) AS mb, LAST_DAY(d) AS ld, TO_CHAR(d, 'YYYY-MM-DD') AS tc, TO_CHAR(n, '9990.99') AS tn, JSON_VALUE(j, '$.a') AS jv, JSON_QUERY(j, '$.b') AS jq, NVL(s, 'x') AS nv, LPAD(s, 5, '*') AS lp, TRUNC(n) AS tr, MOD(k, 4) AS md, INITCAP(s) AS ic, TRANSLATE(s, 'ab', 'xy') AS tl FROM t;
    \\CREATE VIEW agg AS SELECT MOD(k, 2) AS par, COUNT(*) AS cnt, JSON_ARRAYAGG(k) AS ks FROM t GROUP BY MOD(k, 2);
    \\INSERT INTO t (k, s, d, n, j) VALUES (1, 'abc', DATE '2024-02-29', 12.34, '{"a": 1, "b": [1]}');
    \\INSERT INTO t (k, s, d, n, j) VALUES (4, 'ab', DATE '2023-12-31', -1.5, '{"a": "x"}');
    \\INSERT INTO t (k, s, d, n, j) VALUES (9, 'a', DATE '2000-01-01', 0, NULL);
    \\INSERT INTO item (a) VALUES (1);
    \\INSERT INTO item (a) VALUES (2);
    \\COMMIT;
    \\
    ,
    .reads =
    \\PRAGMA integrity_check;
    \\SELECT * FROM v ORDER BY id;
    \\SELECT * FROM agg ORDER BY par;
    \\SELECT ID, G, SUB FROM T ORDER BY ID;
    \\SELECT ID FROM T INDEXED BY T_AM WHERE xq_oracle_add_months(D, 1) > '2001-01-01' ORDER BY ID;
    \\SELECT * FROM item ORDER BY a;
    \\
    ,
    .rejects = &.{
        "INSERT INTO T (K, S) VALUES (1, 'zz')",
        "INSERT INTO T (K, J) VALUES (1, '{x')",
        "INSERT INTO T (K) VALUES (123456)",
    },
    .writes =
    \\INSERT INTO T (ID, K, S, D, N, J) VALUES (100, 21, 'axyz', '2024-01-31 00:00:00', 2.5, '{"a": "w"}');
    \\INSERT INTO ITEM (A) VALUES (3);
    \\INSERT INTO ITEM (A) VALUES (4);
    \\
    ,
    .read_back =
    \\.dialect oracle
    \\SELECT id, k, g, sub, ADD_MONTHS(d, 1) FROM t WHERE id = 100;
    \\SELECT a, id FROM item ORDER BY a;
    \\INSERT INTO item (a) VALUES (5);
    \\SELECT id FROM item WHERE a = 5;
    \\SELECT id FROM t WHERE JSON_VALUE(j, '$.a') = 'w';
    \\
    ,
    .want =
    \\100|21|42|xyz|2024-02-29 00:00:00
    \\1|1
    \\2|2
    \\3|3
    \\4|4
    \\5
    \\100
    \\
    ,
};

fn integrity(c: *Check, base: *BaseDb, sp: *const Spec) !void {
    try base.get(c, sp.db);
    const ok = std.mem.trimEnd(u8, try c.sqlite3Ext(sp.db, "PRAGMA integrity_check"), "\n");
    _ = c.expect(std.mem.eql(u8, ok, "ok"), "integrity_check with the extension: {s}", .{ok});
    // Without it, sqlite3 cannot compute the expression indexes.
    const r = try c.run(&.{ c.cfg.sqlite3, sp.db, "PRAGMA integrity_check" }, .{});
    _ = c.expect(!r.ok() or !std.mem.eql(u8, std.mem.trimEnd(u8, r.stdout, "\n"), "ok"), "sqlite3 alone passed integrity_check (the database needs no extension?)", .{});
}

fn reads(c: *Check, base: *BaseDb, sp: *const Spec) !void {
    try base.get(c, sp.db);
    const x = try c.xqSql(sp.db, sp.reads);
    const s = try c.sqlite3Ext(sp.db, sp.reads);
    _ = c.expectSame("reads", "xqlite", x, "sqlite3+ext", s);
    if (sp.dialect_reads.len > 0) {
        const xd = try c.runOk(&.{ c.cfg.xq, "sql", sp.db }, .{ .stdin = try std.mem.concat(c.arena, u8, &.{ ".dialect ", sp.dialect, "\n", sp.dialect_reads }) });
        const sd = try c.sqlite3Ext(sp.db, sp.dialect_reads);
        _ = c.expectSame("reads in the dialect", "xqlite", xd, "sqlite3+ext", sd);
    }
}

fn rejects(c: *Check, base: *BaseDb, sp: *const Spec, stmt: []const u8) !void {
    try base.get(c, sp.db);
    const s = try c.run(try c.sqlite3ExtArgv(sp.db, stmt), .{});
    if (!c.expect(!s.ok(), "sqlite3 with the extension accepted: {s}", .{stmt})) return;
    const x = try c.run(&.{ c.cfg.xq, "sql", sp.db, stmt }, .{});
    if (!c.expect(!x.ok(), "xqlite accepted: {s}", .{stmt})) return;
    _ = c.expectSame("the error", "xqlite", try errors(c, x.stderr), "sqlite3+ext", try errors(c, s.stderr));
}

fn writes(c: *Check, base: *BaseDb, sp: *const Spec) !void {
    try base.get(c, sp.db);
    // nextval() of a DEFAULT writes (it is not innocuous): as in xqlite,
    // the schema may call it only with trusted_schema on, which the
    // sqlite3 shell turns off (and Python's sqlite3 leaves on).
    _ = try c.sqlite3Ext(sp.db, try std.mem.concat(c.arena, u8, &.{ "PRAGMA trusted_schema=ON;\n", sp.writes }));
    const s_ok = std.mem.trimEnd(u8, try c.sqlite3Ext(sp.db, "PRAGMA integrity_check"), "\n");
    _ = c.expect(std.mem.eql(u8, s_ok, "ok"), "sqlite3 integrity_check after its writes: {s}", .{s_ok});
    // xqlite computes the index entries sqlite3 made again.
    const x_ok = std.mem.trimEnd(u8, try c.xqSql(sp.db, "PRAGMA integrity_check"), "\n");
    _ = c.expect(std.mem.eql(u8, x_ok, "ok"), "xqlite integrity_check after sqlite3's writes: {s}", .{x_ok});
    const got = try c.runOk(&.{ c.cfg.xq, "sql", sp.db }, .{ .stdin = sp.read_back });
    _ = c.expectSame("read back", "want", sp.want, "xqlite", got);
}

/// The error lines of a shell's standard error, without the shells'
/// differences: "Error near line 3: msg" and "Parse error near line 3:
/// msg" are "line 3: msg", the lines that point at the error go, the
/// DETAIL, HINT and CONTEXT lines stay.
fn errors(c: *Check, stderr: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == ' ') continue;
        // The lines a message says more in (DETAIL, HINT, CONTEXT) as
        // they are.
        const field = for ([_][]const u8{ "DETAIL:  ", "HINT:  ", "CONTEXT:  " }) |f| {
            if (std.mem.startsWith(u8, line, f)) break true;
        } else false;
        var z = if (field) line else if (std.mem.indexOf(u8, line, "line ")) |i| line[i..] else if (std.mem.indexOf(u8, line, "argument: ")) |i| line[i + "argument: ".len ..] else line;
        // sqlite3 keeps a message up to a NUL (a C string), xqlite whole.
        if (std.mem.indexOfScalar(u8, z, 0)) |i| z = z[0..i];
        try out.appendSlice(c.arena, z);
        try out.append(c.arena, '\n');
    }
    return out.items;
}

/// Python's sqlite3 module (the system SQLite) loads the extension and
/// reads what sqlite3 reads; skipped without a python3 whose sqlite3 can
/// load extensions, or whose SQLite is older than 3.48: the schemas call
/// if() (3.48), and before 3.47 a REAL's text had 15 digits, not 17.
fn python(c: *Check, base: *BaseDb, sp: *const Spec) !void {
    try base.get(c, sp.db);
    const script =
        \\import sqlite3, sys
        \\if sqlite3.sqlite_version_info < (3, 48, 0):
        \\    print("SKIP system SQLite " + sqlite3.sqlite_version + " is older than 3.48"); sys.exit(0)
        \\con = sqlite3.connect(sys.argv[2])
        \\if not hasattr(con, "enable_load_extension"):
        \\    print("SKIP no enable_load_extension"); sys.exit(0)
        \\con.enable_load_extension(True)
        \\con.load_extension(sys.argv[1])
        \\con.enable_load_extension(False)
        \\def show(v):
        \\    if v is None: return ""
        \\    if isinstance(v, float): return con.execute("SELECT CAST(? AS TEXT)", (v,)).fetchone()[0]
        \\    return str(v)
        \\for stmt in sys.stdin.read().split(";\n"):
        \\    if stmt.strip():
        \\        for row in con.execute(stmt):
        \\            print("|".join(show(v) for v in row))
    ;
    const r = c.run(&.{ "python3", "-I", "-c", script, c.cfg.ext, sp.db }, .{ .stdin = sp.reads }) catch return c.skip("no python3", .{});
    if (std.mem.startsWith(u8, r.stdout, "SKIP")) return c.skip("{s}", .{std.mem.trimEnd(u8, r.stdout, "\n")});
    if (!r.ok()) {
        if (std.mem.indexOf(u8, r.stderr, "not authorized") != null or std.mem.indexOf(u8, r.stderr, "ModuleNotFoundError") != null) return c.skip("python3 cannot load extensions", .{});
        return c.abort("python3: {f}: {s}", .{ r, r.stderr });
    }
    const s = try c.sqlite3Ext(sp.db, sp.reads);
    _ = c.expectSame("reads", "sqlite3+ext", s, "python3", r.stdout);
}

// ================================================================ the ABI

/// tools/ext/abi-NAME.sql in both engines, against abi-NAME.out.
fn abiCases(c: *Check, tag: []const u8) !void {
    const sql_path = try std.fmt.allocPrint(c.arena, "{s}/tools/ext/abi-{s}.sql", .{ c.cfg.root, tag });
    const out_path = try std.fmt.allocPrint(c.arena, "{s}/tools/ext/abi-{s}.out", .{ c.cfg.root, tag });
    const sql = try std.Io.Dir.cwd().readFileAlloc(c.io, sql_path, c.arena, .unlimited);
    // A file that starts with ".dialect NAME" runs in that dialect in
    // xqlite (what only the dialect finds there: its collations, the
    // sequence functions by their plain names); sqlite3 reads the line
    // as a comment, so that the line numbers of the errors agree.
    const s_sql = if (std.mem.startsWith(u8, sql, ".dialect ")) try std.mem.concat(c.arena, u8, &.{ "--", sql }) else sql;
    const x = try c.run(&.{ c.cfg.xq, "sql", ":memory:" }, .{ .stdin = sql });
    const s = try c.run(try c.sqlite3ExtArgv(":memory:", null), .{ .stdin = s_sql });
    const xo = try transcript(c, x);
    const so = try transcript(c, s);
    if (c.cfg.environ.get("XQT_EXT_RECORD") != null) {
        try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = out_path, .data = xo });
    }
    const want = std.Io.Dir.cwd().readFileAlloc(c.io, out_path, c.arena, .unlimited) catch |err| {
        return c.abort("{s}: {t} (XQT_EXT_RECORD=1 records it)", .{ out_path, err });
    };
    _ = c.expectSame("xqlite's results", "recorded", want, "xqlite", xo);
    _ = c.expectSame("the extension's results", "recorded", want, "sqlite3+ext", so);
}

/// A shell's output and its errors (errors()), in one text.
fn transcript(c: *Check, r: anytype) ![]const u8 {
    return std.mem.concat(c.arena, u8, &.{ r.stdout, "-- errors\n", try errors(c, r.stderr) });
}

fn loadVersion(c: *Check) !void {
    const s = std.mem.trimEnd(u8, try c.sqlite3Ext(":memory:", "SELECT xq_ext_version()"), "\n");
    const x = std.mem.trimEnd(u8, try c.xqSql(":memory:", "SELECT xq_ext_version()"), "\n");
    _ = c.expectSame("xq_ext_version()", "xqlite", x, "sqlite3+ext", s);
    // The entry point by its name, and loading it twice.
    const load = try std.fmt.allocPrint(c.arena, ".load \"{s}\" sqlite3_xqliteext_init", .{c.cfg.ext});
    const twice = try c.runOk(&.{ c.cfg.sqlite3, "-cmd", load, "-cmd", load, ":memory:", "SELECT xq_like('a%', 'abc'), xq_ilike('A%', 'abc')" }, .{});
    _ = c.expect(std.mem.startsWith(u8, twice, "1|"), "loaded twice: {s}", .{twice});
}

// ======================================================= generated calls

const call_shards = 4;
/// Calls per function and argument count.
const calls_per_arity = 6;

/// SQL literals the calls take their arguments from.
const pool = [_][]const u8{
    "NULL",         "0",                                                "1",                               "-1",
    "2",            "7",                                                "9223372036854775807",             "-9223372036854775808",
    "1.5",          "-0.0",                                             "1e308",                           "0.1",
    "''",           "'abc'",                                            "' 12 '",                          "'12'",
    "'1.5e3'",      "'NaN'",                                            "'-Infinity'",                     "x''",
    "x'00ff10'",    "'{\"a\":1,\"b\":[1,2,null],\"c\":{\"d\":\"e\"}}'", "'[1,\"two\",3.5,null,true]'",     "'\"s\"'",
    "'{1,2,3}'",    "'{{1,2},{3,4}}'",                                  "'{a,NULL,\"b c\"}'",              "'{}'",
    "'1 day'",      "'1 year 2 mons 3 days 04:05:06.5'",                "'-1 hour'",                       "'P1Y2M'",
    "'2024-02-29'", "'2024-02-29 12:34:56'",                            "'2024-02-29T12:34:56.789+02:00'", "'12:34:56'",
    "'yes'",        "'off'",                                            "'t'",                             "'$.a'",
    "'$.b[1]'",     "'strict $.c.d'",                                   "'{c,d}'",                         "'a%'",
    "'%b_'",        "'^a.*$'",                                          "'i'",                             "'int'",
    "'varchar(5)'", "'NUMBER(5,2)'",                                    "'decimal(6,2)'",                  "'DAY'",
    "'MONTH'",      "'YYYY-MM-DD HH24:MI'",                             "'%Y-%m-%d'",                      "'a''b'",
    "'é ü 漢'",
    "'datetime2'",  "'uniqueidentifier'",                               "3",
};

const Rng = std.Random.DefaultPrng;

fn seed(c: *Check) u64 {
    const z = c.cfg.environ.get("XQT_SEED") orelse return 0x5eed_e47;
    return std.fmt.parseUnsigned(u64, z, 10) catch 0x5eed_e47;
}

/// Shard `shard` of the deterministic xq_* functions (by name), each
/// called with generated arguments in xqlite and in sqlite3 with the
/// extension.
fn generatedCalls(c: *Check, shard: usize) !void {
    const list = try c.sqlite3Ext(":memory:",
        \\SELECT DISTINCT name, narg, type FROM pragma_function_list
        \\WHERE name LIKE 'xq\_%' ESCAPE '\' AND flags & 0x800 AND type IN ('s', 'a')
        \\ORDER BY name, narg
    );
    var sql: std.ArrayList(u8) = .empty;
    var rng = Rng.init(seed(c) +% shard);
    const r = rng.random();
    var n_calls: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '|');
        const fname = f.next() orelse continue;
        const narg = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const kind = f.next() orelse continue;
        if (std.hash.Wyhash.hash(0, fname) % call_shards != shard) continue;
        const arities: []const i32 = if (narg >= 0) &.{narg} else &.{ 0, 1, 2, 3 };
        for (arities) |n| {
            for (0..calls_per_arity) |_| {
                try sql.appendSlice(c.arena, "SELECT ");
                if (kind[0] == 'a') {
                    // An aggregate over three rows of one argument each.
                    try sql.print(c.arena, "quote({s}(", .{fname});
                    for (0..@intCast(n)) |i| {
                        if (i > 0) try sql.appendSlice(c.arena, ", ");
                        try sql.print(c.arena, "column{d}", .{i + 1});
                    }
                    try sql.appendSlice(c.arena, ")) FROM (VALUES ");
                    for (0..3) |row| {
                        if (row > 0) try sql.appendSlice(c.arena, ", ");
                        try sql.append(c.arena, '(');
                        for (0..@intCast(@max(n, 1))) |i| {
                            if (i > 0) try sql.appendSlice(c.arena, ", ");
                            try sql.appendSlice(c.arena, pool[r.uintLessThan(usize, pool.len)]);
                        }
                        try sql.append(c.arena, ')');
                    }
                    try sql.appendSlice(c.arena, ");\n");
                } else {
                    try sql.print(c.arena, "quote({s}(", .{fname});
                    for (0..@intCast(n)) |i| {
                        if (i > 0) try sql.appendSlice(c.arena, ", ");
                        try sql.appendSlice(c.arena, pool[r.uintLessThan(usize, pool.len)]);
                    }
                    try sql.appendSlice(c.arena, "));\n");
                }
                n_calls += 1;
            }
        }
    }
    if (n_calls == 0) return c.skip("no function of this shard", .{});
    try c.writeFile("calls.sql", sql.items);
    const x = try c.run(&.{ c.cfg.xq, "sql", ":memory:" }, .{ .stdin = sql.items, .timeout_ms = 300_000 });
    const s = try c.run(try c.sqlite3ExtArgv(":memory:", null), .{ .stdin = sql.items, .timeout_ms = 300_000 });
    if (x.exitCode() == null or s.exitCode() == null) return c.abort("a shell crashed or timed out: xqlite {f}, sqlite3 {f}", .{ x, s });
    c.print("{d} calls (seed {d}, calls.sql)", .{ n_calls, seed(c) });
    _ = c.expectSame("results", "xqlite", x.stdout, "sqlite3+ext", s.stdout);
    _ = c.expectSame("errors", "xqlite", try errors(c, x.stderr), "sqlite3+ext", try errors(c, s.stderr));
}
