//! The JSON SQL functions (port of json.c): the JSON and JSON5 text
//! parser, the JSONB binary encoding, the renderer, path lookup and edit,
//! the per-statement parse cache, and the scalar and aggregate functions
//! json(), jsonb(), json_extract(), ->, ->>, json_set() and friends,
//! json_group_array() and json_group_object().
//!
//! JSON text is parsed into JSONB, the binary format of json.c: every
//! element is a header of 1 to 9 bytes (the low 4 bits of the first byte
//! the JSONB.* type, the high 4 bits the payload size or the size of the
//! size field that follows) and a payload. The payload of numbers and
//! strings is their text (without quotes); that of arrays and objects the
//! elements they contain. Generated JSON text is always canonical
//! RFC-8259, while input may use JSON5 extensions.
//!
//! The table-valued functions json_each(), json_tree(), jsonb_each() and
//! jsonb_tree() are the eponymous virtual tables of jsonEachModule,
//! registered on first use by build.locateTable(). The SQLITE_DEBUG
//! json_parse() function is compiled out by default and so is omitted.

const std = @import("std");
const int = @import("sqlite_int.zig");
const callback = @import("callback.zig");
const printf = @import("printf.zig");
const numeric = @import("xqlite_base").numeric;
const util = @import("util.zig");
const func = @import("func.zig");
const ctype = @import("xqlite_base").ctype;
const vi = @import("../vdbe/vdbe_int.zig");
const api = @import("../vdbe/api.zig");
const vtab = @import("vtab.zig");
const malloc = @import("malloc.zig");

const Allocator = std.mem.Allocator;
const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const Context = vi.Context;
const Mem = vi.Mem;
const MEM = vi.MEM;
const ENC = vi.ENC;
const FUNC = callback.FUNC;
const RC = int.RC;

const SQLITE_INTEGER = vi.SQLITE_INTEGER;
const SQLITE_FLOAT = vi.SQLITE_FLOAT;
const SQLITE_TEXT = vi.SQLITE_TEXT;
const SQLITE_BLOB = vi.SQLITE_BLOB;
const SQLITE_NULL = vi.SQLITE_NULL;

/// JSONB element types (JSONB_*).
const JSONB = struct {
    /// "null"
    const NULL: u8 = 0;
    /// "true"
    const TRUE: u8 = 1;
    /// "false"
    const FALSE: u8 = 2;
    /// Integer acceptable to JSON and SQL.
    const INT: u8 = 3;
    /// Integer in 0x000 notation.
    const INT5: u8 = 4;
    /// Float acceptable to JSON and SQL.
    const FLOAT: u8 = 5;
    /// Float with JSON5 extensions.
    const FLOAT5: u8 = 6;
    /// Text compatible with both JSON and SQL.
    const TEXT: u8 = 7;
    /// Text with JSON escapes.
    const TEXTJ: u8 = 8;
    /// Text with JSON-5 escapes.
    const TEXT5: u8 = 9;
    /// SQL text that needs escaping for JSON.
    const TEXTRAW: u8 = 10;
    const ARRAY: u8 = 11;
    const OBJECT: u8 = 12;
};

/// jsonbType[]: human-readable names of the JSONB types.
const jsonb_type = [_][:0]const u8{
    "null", "true",  "false",  "integer", "integer",
    "real", "real",  "text",   "text",    "text",
    "text", "array", "object", "",        "",
    "",     "",
};

/// jsonIsSpace[]: the JSON whitespace characters.
const json_is_space: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for ("\x09\x0a\x0d\x20") |c| t[c] = true;
    break :blk t;
};

/// jsonIsspace().
fn jsonIsspace(c: u8) bool {
    return json_is_space[c];
}

/// strspn(z, jsonSpaces): the number of JSON whitespace characters at the
/// start of `z`.
fn jsonSpaces(z: [*]const u8) u32 {
    var n: u32 = 0;
    while (jsonIsspace(z[n])) n += 1;
    return n;
}

/// jsonIsOk[]: characters that are not special to JSON. Control
/// characters, '"', '\\' and '\'' (special in JSON-5) are not ok.
const json_is_ok: [256]bool = blk: {
    var t: [256]bool = @splat(true);
    for (0..0x20) |c| t[c] = false;
    t['"'] = false;
    t['\''] = false;
    t['\\'] = false;
    break :blk t;
};

/// Magic number of the JSON parse cache in sqlite3_get_auxdata()
/// (JSON_CACHE_ID).
const json_cache_id: i32 = -429938;
/// Most entries in the cache (JSON_CACHE_SIZE).
const json_cache_size = 4;

/// The invalid code point jsonUnescapeOneChar() returns on a syntax error
/// (JSON_INVALID_CHAR).
const json_invalid_char: u32 = 0x99999;

/// JsonString.e_err values (JSTRING_*).
const JSTRING = struct {
    /// Out of memory.
    const OOM: u8 = 0x01;
    /// Malformed JSONB.
    const MALFORMED: u8 = 0x02;
    /// JSON nested too deep.
    const TOODEEP: u8 = 0x04;
    /// Error already sent to sqlite3_result.
    const ERR: u8 = 0x08;
};

/// The subtype of text JSON values (JSON_SUBTYPE: ASCII "J").
pub const json_subtype: u32 = 74;

/// Bits of the sqlite3_user_data() of the SQL functions (JSON_*).
const JSON = struct {
    /// The result is always JSON.
    const JSON: usize = 0x01;
    /// The result is always SQL.
    const SQL: usize = 0x02;
    /// Allow abbreviated JSON path specs.
    const ABPATH: usize = 0x03;
    /// json_set(), not json_insert().
    const ISSET: usize = 0x04;
    /// json_array_insert(), not json_insert().
    const AINS: usize = 0x08;
    /// Use the BLOB output format.
    const BLOB: usize = 0x10;
};

/// JSON_INSERT_TYPE().
fn jsonInsertType(x: usize) usize {
    return (x & 0xC) >> 2;
}

/// JsonParse.e_edit values (JEDIT_*), numbered as in C, where 0 is no
/// edit (null here).
const JEDIT = enum(u8) {
    /// Delete if exists.
    DEL = 1,
    /// Overwrite if exists.
    REPL = 2,
    /// Insert if not exists.
    INS = 3,
    /// Insert or overwrite.
    SET = 4,
    /// json_array_insert().
    AINS = 5,

    /// Whether the edit may insert: INS, SET and AINS, which come last (C:
    /// `eEdit>=JEDIT_INS`).
    fn mayInsert(e: JEDIT) bool {
        return @backingInt(e) >= @backingInt(JEDIT.INS);
    }
};

/// Maximum nesting depth of JSON (JSON_MAX_DEPTH), which keeps the
/// recursive descent parser from overflowing the stack.
const json_max_depth = 1000;

/// Flags of jsonParseFuncArg().
const JSON_EDITABLE: u32 = 0x01;
/// Return non-null even if there is an error.
const JSON_KEEPERROR: u32 = 0x02;
/// Do not use the JSON cache.
const JSON_NOCACHE: u32 = 0x04;

/// The user data of the function as flags.
fn userFlags(ctx: *const Context) usize {
    return func.ptrToInt(api.userData(ctx));
}

/// Port of sqlite3StrNICmp() for a pattern of plain characters: 0 if the
/// first `pat.len` characters of `z` match `pat` ignoring case.
fn strNICmp(z: [*]const u8, pat: []const u8) i32 {
    for (pat, 0..) |c, i| {
        const d = @as(i32, ctype.toLower(z[i])) - ctype.toLower(c);
        if (d != 0) return d;
        if (z[i] == 0) return 0;
    }
    return 0;
}

/// Port of sqlite3Utf8ReadLimited() (utf.c): decode the UTF-8 character
/// at the start of the `n` bytes of `z` into `out`; returns its length.
fn utf8ReadLimited(z: [*]const u8, n_arg: u32, out: *u32) u32 {
    var n = n_arg;
    var i: u32 = 1;
    std.debug.assert(n > 0);
    var c: u32 = z[0];
    if (c >= 0xc0) {
        c = func.utf8_trans1[c - 0xc0];
        if (n > 4) n = 4;
        while (i < n and z[i] & 0xc0 == 0x80) {
            c = (c << 6) + (0x3f & z[i]);
            i += 1;
        }
    }
    out.* = c;
    return i;
}

/// sqlite3JsonId1(): may start a JSON5 identifier.
fn jsonId1(c: u8) bool {
    return ctype.map[c] & 0x42 != 0;
}

// ================================================================= RCStr

/// The header in front of an RCStr (printf.c): a reference-counted string
/// that the JSON cache can share with function results. It lives in
/// memory from sqlite3_malloc(), whose free needs only the pointer.
const RCStr = struct {
    n_rc_ref: u64,
};

fn rcstrHeader(z: [*]u8) *RCStr {
    return @ptrCast(@alignCast(z - @sizeOf(RCStr)));
}

/// Port of sqlite3RCStrNew(): room for `n` bytes and a terminator, with
/// one reference.
fn rcstrNew(n: u64) ?[*]u8 {
    const p = malloc.malloc(n + @sizeOf(RCStr) + 1) orelse return null;
    const h: *RCStr = @ptrCast(@alignCast(p));
    h.n_rc_ref = 1;
    return p + @sizeOf(RCStr);
}

/// Port of sqlite3RCStrRef(): add a reference.
fn rcstrRef(z: [*]u8) [*]u8 {
    rcstrHeader(z).n_rc_ref += 1;
    return z;
}

/// Port of sqlite3RCStrUnref(): drop a reference, freeing the string
/// with the last one. Usable as a destructor.
fn rcstrUnref(z: [*]u8) void {
    const h = rcstrHeader(z);
    std.debug.assert(h.n_rc_ref > 0);
    if (h.n_rc_ref >= 2) {
        h.n_rc_ref -= 1;
    } else {
        malloc.free(h);
    }
}

/// Port of sqlite3RCStrResize(): room for `n` bytes and a terminator; the
/// string must have a single reference. On OOM the string is freed and
/// the result is null.
fn rcstrResize(z: [*]u8, n: u64) ?[*]u8 {
    const h = rcstrHeader(z);
    std.debug.assert(h.n_rc_ref == 1);
    const new = malloc.realloc(h, n + @sizeOf(RCStr) + 1) orelse {
        malloc.free(h);
        return null;
    };
    return new + @sizeOf(RCStr);
}

/// Port of sqlite3ValueIsOfClass() (vdbemem.c): `m` is a string or blob
/// freed by `x_free`.
fn valueIsOfClass(m: *const Mem, x_free: int.DestructorFn) bool {
    return m.flags.intersects(.{ .Str = true, .Blob = true }) and m.flags.Dyn and m.x_del == x_free;
}

// ================================================================ objects

/// A cache mapping JSON text to JSONB blobs (JsonCache). Each entry is
/// read-only, owns its a_blob and has an RCStr as z_json.
const JsonCache = struct {
    db: *Sqlite3,
    /// Active entries, oldest first.
    n_used: usize,
    a: [json_cache_size]*JsonParse,
};

/// A JSON string under construction (JsonString): a generic string
/// accumulator. Text that outgrows z_space becomes an RCStr, which helps
/// caching. The object must not move while z_buf points to z_space.
const JsonString = struct {
    /// Error messages go here.
    ctx: ?*Context = null,
    /// The content so far; null for a zeroed aggregate context.
    z_buf: ?[*]u8 = null,
    n_alloc: u64 = 0,
    n_used: u64 = 0,
    /// z_buf is z_space.
    b_static: bool = false,
    /// JSTRING.* errors seen.
    e_err: u8 = 0,
    z_space: [100]u8 = undefined,

    fn buf(p: *const JsonString) [*]u8 {
        return p.z_buf.?;
    }
};

/// A parsed JSON value (JsonParse). Text JSON is parsed into JSONB in
/// a_blob (or the JSONB argument is used as is), searched with a path,
/// maybe edited, and rendered back to text unless the function returns
/// JSONB.
const JsonParse = struct {
    /// JSONB representation of the value.
    a_blob: ?[*]u8 = null,
    /// Bytes of a_blob used.
    n_blob: u32 = 0,
    /// Bytes allocated to a_blob; 0 if a_blob is external.
    n_blob_alloc: u32 = 0,
    /// The JSON text parsed, NUL-terminated.
    z_json: ?[*]const u8 = null,
    db: ?*Sqlite3 = null,
    n_json: i32 = 0,
    /// References to this object.
    n_jp_ref: u32 = 0,
    /// Error location in z_json.
    i_err: u32 = 0,
    /// Nesting depth. Updated with wrapping arithmetic, as the u16 of C
    /// wraps: jsonCreateEditSubstructure() decrements a depth it never
    /// incremented (it incremented that of the substructure).
    i_depth: u16 = 0,
    /// Errors seen.
    n_err: u8 = 0,
    oom: bool = false,
    /// z_json is an RCStr.
    b_json_is_rcstr: bool = false,
    /// The input uses non-standard features like JSON5.
    has_nonstd: bool = false,
    /// Do not modify.
    b_read_only: bool = false,
    // Search and edit information; see jsonLookupStep().
    /// JEDIT.* operation to apply, if any.
    e_edit: ?JEDIT = null,
    /// Size change due to the edit.
    delta: i32 = 0,
    /// Bytes to insert.
    n_ins: u32 = 0,
    /// Location of the label if the search landed on an object value.
    i_label: u32 = 0,
    /// Content to insert.
    a_ins: ?[*]const u8 = null,

    fn blob(p: *const JsonParse) [*]u8 {
        return p.a_blob.?;
    }

    fn gpa(p: *const JsonParse) Allocator {
        return p.db.?.gpa;
    }
};

// ======================================================= JsonCache

/// Port of jsonCacheDelete().
fn jsonCacheDelete(p: *JsonCache) void {
    for (p.a[0..p.n_used]) |x| jsonParseFree(x);
    p.db.gpa.destroy(p);
}

/// Port of jsonCacheInsert(): add `parse` to the cache of the statement,
/// expelling the least recently used entry if it is full.
fn jsonCacheInsert(ctx: *Context, parse: *JsonParse) i32 {
    std.debug.assert(parse.z_json != null);
    std.debug.assert(parse.b_json_is_rcstr);
    std.debug.assert(parse.delta == 0);
    var p = api.getAuxdataTyped(ctx, json_cache_id, jsonCacheDelete);
    if (p == null) {
        const db = api.contextDbHandle(ctx);
        const new = db.gpa.create(JsonCache) catch return RC.NOMEM;
        new.* = .{ .db = db, .n_used = 0, .a = undefined };
        api.setAuxdataTyped(ctx, json_cache_id, jsonCacheDelete, new);
        p = api.getAuxdataTyped(ctx, json_cache_id, jsonCacheDelete);
        if (p == null) return RC.NOMEM;
    }
    const c = p.?;
    if (c.n_used >= json_cache_size) {
        jsonParseFree(c.a[0]);
        std.mem.copyForwards(*JsonParse, c.a[0 .. json_cache_size - 1], c.a[1..]);
        c.n_used = json_cache_size - 1;
    }
    std.debug.assert(parse.n_blob_alloc > 0);
    parse.e_edit = null;
    parse.n_jp_ref += 1;
    parse.b_read_only = true;
    c.a[c.n_used] = parse;
    c.n_used += 1;
    return RC.OK;
}

/// Port of jsonCacheSearch(): the cached parse of the JSON text in `arg`,
/// made the most recently used entry; null if there is none. The result
/// still belongs to the cache.
fn jsonCacheSearch(ctx: *Context, arg: *Mem) ?*JsonParse {
    if (api.valueType(arg) != SQLITE_TEXT) return null;
    const z_json = api.valueText(arg) orelse return null;
    const n_json = api.valueBytes(arg);

    const p = api.getAuxdataTyped(ctx, json_cache_id, jsonCacheDelete) orelse return null;
    var i: usize = 0;
    while (i < p.n_used) : (i += 1) {
        if (p.a[i].z_json == z_json.ptr) break;
    }
    if (i >= p.n_used) {
        i = 0;
        while (i < p.n_used) : (i += 1) {
            if (p.a[i].n_json != n_json) continue;
            if (std.mem.eql(u8, p.a[i].z_json.?[0..n_json], z_json[0..n_json])) break;
        }
    }
    if (i < p.n_used) {
        if (i < p.n_used - 1) {
            // Make the matching entry the most recently used.
            const tmp = p.a[i];
            std.mem.copyForwards(*JsonParse, p.a[i .. p.n_used - 1], p.a[i + 1 .. p.n_used]);
            p.a[p.n_used - 1] = tmp;
            i = p.n_used - 1;
        }
        std.debug.assert(p.a[i].delta == 0);
        return p.a[i];
    }
    return null;
}

// ====================================================== JsonString

/// Port of jsonStringZero(): an empty string in the static space.
fn jsonStringZero(p: *JsonString) void {
    p.z_buf = &p.z_space;
    p.n_alloc = p.z_space.len;
    p.n_used = 0;
    p.b_static = true;
}

/// Port of jsonStringInit().
fn jsonStringInit(p: *JsonString, ctx: ?*Context) void {
    p.ctx = ctx;
    p.e_err = 0;
    jsonStringZero(p);
}

/// Port of jsonStringReset(): free the buffer and empty the string.
fn jsonStringReset(p: *JsonString) void {
    if (!p.b_static) rcstrUnref(p.z_buf.?);
    jsonStringZero(p);
}

/// Port of jsonStringOom(): report an out-of-memory condition.
fn jsonStringOom(p: *JsonString) void {
    p.e_err |= JSTRING.OOM;
    if (p.ctx) |ctx| api.resultErrorNomem(ctx);
    jsonStringReset(p);
}

/// Port of jsonStringTooDeep(): report JSON nested too deep.
fn jsonStringTooDeep(p: *JsonString) void {
    p.e_err |= JSTRING.TOODEEP;
    api.resultError(p.ctx.?, "JSON nested too deep");
    jsonStringReset(p);
}

/// Port of jsonStringGrow(): room for at least `n` more bytes. Non-zero
/// on OOM.
fn jsonStringGrow(p: *JsonString, n: u32) i32 {
    const n_total: u64 = if (n < p.n_alloc) p.n_alloc * 2 else p.n_alloc + n + 10;
    if (p.b_static) {
        if (p.e_err != 0) return 1;
        const z_new = rcstrNew(n_total) orelse {
            jsonStringOom(p);
            return RC.NOMEM;
        };
        @memcpy(z_new[0..@intCast(p.n_used)], p.buf()[0..@intCast(p.n_used)]);
        p.z_buf = z_new;
        p.b_static = false;
    } else {
        p.z_buf = rcstrResize(p.buf(), n_total);
        if (p.z_buf == null) {
            p.e_err |= JSTRING.OOM;
            jsonStringZero(p);
            return RC.NOMEM;
        }
    }
    p.n_alloc = n_total;
    return RC.OK;
}

/// Port of jsonStringExpandAndAppend().
fn jsonStringExpandAndAppend(p: *JsonString, z_in: []const u8) void {
    std.debug.assert(z_in.len > 0);
    if (jsonStringGrow(p, @intCast(z_in.len)) != 0) return;
    @memcpy(p.buf()[@intCast(p.n_used)..][0..z_in.len], z_in);
    p.n_used += z_in.len;
}

/// Port of jsonAppendRaw(): append `z_in`.
fn jsonAppendRaw(p: *JsonString, z_in: []const u8) void {
    if (z_in.len == 0) return;
    jsonAppendRawNZ(p, z_in);
}

/// Port of jsonAppendRawNZ(): append the non-empty `z_in`.
fn jsonAppendRawNZ(p: *JsonString, z_in: []const u8) void {
    std.debug.assert(z_in.len > 0);
    if (z_in.len + p.n_used >= p.n_alloc) {
        jsonStringExpandAndAppend(p, z_in);
    } else {
        @memcpy(p.buf()[@intCast(p.n_used)..][0..z_in.len], z_in);
        p.n_used += z_in.len;
    }
}

/// Port of jsonPrintf(): append formatted text of at most `n` - 1 bytes.
fn jsonPrintf(n: u32, p: *JsonString, fmt: []const u8, args: []const printf.Arg) void {
    if (p.n_used + n >= p.n_alloc and jsonStringGrow(p, n) != 0) return;
    // sqlite3_vsnprintf()
    var acc = printf.StrAccum.init(null, p.buf()[@intCast(p.n_used)..][0..n], 0);
    acc.appendf(fmt, args);
    p.n_used += acc.n_char;
}

/// Port of jsonAppendCharExpand().
fn jsonAppendCharExpand(p: *JsonString, c: u8) void {
    if (jsonStringGrow(p, 1) != 0) return;
    p.buf()[@intCast(p.n_used)] = c;
    p.n_used += 1;
}

/// Port of jsonAppendChar(): append one character.
fn jsonAppendChar(p: *JsonString, c: u8) void {
    if (p.n_used >= p.n_alloc) {
        jsonAppendCharExpand(p, c);
    } else {
        p.buf()[@intCast(p.n_used)] = c;
        p.n_used += 1;
    }
}

/// Port of jsonStringTrimOneChar(): remove the last character.
fn jsonStringTrimOneChar(p: *JsonString) void {
    if (p.e_err == 0) {
        std.debug.assert(p.n_used > 0);
        p.n_used -= 1;
    }
}

/// Port of jsonStringTerminate(): make sure the text is NUL-terminated;
/// false on OOM.
fn jsonStringTerminate(p: *JsonString) bool {
    jsonAppendChar(p, 0);
    jsonStringTrimOneChar(p);
    return p.e_err == 0;
}

/// Port of jsonAppendSeparator(): append a comma unless the previous
/// character is '[' or '{'.
fn jsonAppendSeparator(p: *JsonString) void {
    if (p.n_used == 0) return;
    const c = p.buf()[@intCast(p.n_used - 1)];
    if (c == '[' or c == '{') return;
    jsonAppendChar(p, ',');
}

/// Port of jsonAppendControlChar(): append the canonical JSON form of the
/// control character `c`. The buffer must have room for 7 more bytes.
fn jsonAppendControlChar(p: *JsonString, c: u8) void {
    const a_special = [32]u8{
        0, 0, 0, 0, 0, 0, 0, 0, 'b', 't', 'n', 0, 'f', 'r', 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0,   0,   0,   0, 0,   0,   0, 0,
    };
    std.debug.assert(c < a_special.len);
    std.debug.assert(p.n_used + 7 <= p.n_alloc);
    const z = p.buf() + @as(usize, @intCast(p.n_used));
    if (a_special[c] != 0) {
        z[0] = '\\';
        z[1] = a_special[c];
        p.n_used += 2;
    } else {
        z[0] = '\\';
        z[1] = 'u';
        z[2] = '0';
        z[3] = '0';
        z[4] = "0123456789abcdef"[c >> 4];
        z[5] = "0123456789abcdef"[c & 0xf];
        p.n_used += 6;
    }
}

/// Port of jsonAppendString(): append `z_in` as a JSON string literal:
/// in double quotes, with '"', '\\' and control characters escaped.
fn jsonAppendString(p: *JsonString, z_in: ?[]const u8) void {
    const zs = z_in orelse return;
    var z = zs.ptr;
    var n: u32 = @intCast(zs.len);
    if (n + p.n_used + 2 >= p.n_alloc and jsonStringGrow(p, n + 2) != 0) return;
    p.buf()[@intCast(p.n_used)] = '"';
    p.n_used += 1;
    while (true) {
        var k: u32 = 0;
        // The 4-way unwound equivalent of
        //     while (k < n and json_is_ok[z[k]]) k += 1;
        while (true) {
            if (k + 3 >= n) {
                while (k < n and json_is_ok[z[k]]) k += 1;
                break;
            }
            if (!json_is_ok[z[k]]) break;
            if (!json_is_ok[z[k + 1]]) {
                k += 1;
                break;
            }
            if (!json_is_ok[z[k + 2]]) {
                k += 2;
                break;
            }
            if (!json_is_ok[z[k + 3]]) {
                k += 3;
                break;
            } else {
                k += 4;
            }
        }
        if (k >= n) {
            if (k > 0) {
                @memcpy(p.buf()[@intCast(p.n_used)..][0..k], z[0..k]);
                p.n_used += k;
            }
            break;
        }
        if (k > 0) {
            @memcpy(p.buf()[@intCast(p.n_used)..][0..k], z[0..k]);
            p.n_used += k;
            z += k;
            n -= k;
        }
        const c = z[0];
        if (c == '"' or c == '\\') {
            if (p.n_used + n + 3 > p.n_alloc and jsonStringGrow(p, n + 3) != 0) return;
            p.buf()[@intCast(p.n_used)] = '\\';
            p.buf()[@intCast(p.n_used + 1)] = c;
            p.n_used += 2;
        } else if (c == '\'') {
            p.buf()[@intCast(p.n_used)] = c;
            p.n_used += 1;
        } else {
            if (p.n_used + n + 7 > p.n_alloc and jsonStringGrow(p, n + 7) != 0) return;
            jsonAppendControlChar(p, c);
        }
        z += 1;
        n -= 1;
    }
    p.buf()[@intCast(p.n_used)] = '"';
    p.n_used += 1;
    std.debug.assert(p.n_used < p.n_alloc);
}

/// Port of jsonAppendSqlValue(): append the SQL value `value` (such as a
/// function argument) as JSON.
fn jsonAppendSqlValue(p: *JsonString, value: *Mem) void {
    switch (api.valueType(value)) {
        SQLITE_NULL => jsonAppendRawNZ(p, "null"),
        SQLITE_FLOAT => jsonPrintf(100, p, "%!0.17g", &.{.{ .double = api.valueDouble(value) }}),
        SQLITE_INTEGER => {
            const z = api.valueText(value) orelse "";
            jsonAppendRaw(p, z[0..api.valueBytes(value)]);
        },
        SQLITE_TEXT => {
            const z = api.valueText(value);
            const n = api.valueBytes(value);
            if (api.valueSubtype(value) == json_subtype) {
                if (z) |s| jsonAppendRaw(p, s[0..n]);
            } else {
                jsonAppendString(p, if (z) |s| s[0..n] else null);
            }
        },
        else => {
            var px: JsonParse = .{};
            if (jsonArgIsJsonb(value, &px)) {
                _ = jsonTranslateBlobToText(&px, 0, p);
            } else if (p.e_err == 0) {
                api.resultError(p.ctx.?, "JSON cannot hold BLOB values");
                p.e_err = JSTRING.ERR;
                jsonStringReset(p);
            }
        },
    }
}

/// Port of jsonReturnString(): make the text in `p` (probably generated
/// JSON) the result of the function, and reset `p`. With `parse` and
/// `ctx`, the text also becomes the z_json of `parse` and `parse` goes
/// into the cache.
fn jsonReturnString(p: *JsonString, parse: ?*JsonParse, ctx: ?*Context) void {
    std.debug.assert((parse != null) == (ctx != null));
    std.debug.assert(ctx == null or ctx == p.ctx);
    _ = jsonStringTerminate(p);
    if (p.e_err == 0) {
        const flags = userFlags(p.ctx.?);
        if (flags & JSON.BLOB != 0) {
            jsonReturnStringAsBlob(p);
        } else if (p.b_static) {
            api.resultText64(p.ctx.?, p.buf()[0..@intCast(p.n_used)], .transient);
        } else {
            if (parse) |px| {
                if (!px.b_json_is_rcstr and px.n_blob_alloc > 0) {
                    px.z_json = rcstrRef(p.buf());
                    px.n_json = @intCast(p.n_used);
                    px.b_json_is_rcstr = true;
                    const rc = jsonCacheInsert(ctx.?, px);
                    if (rc == RC.NOMEM) {
                        api.resultErrorNomem(ctx.?);
                        jsonStringReset(p);
                        return;
                    }
                }
            }
            const z = rcstrRef(p.buf());
            api.resultTextZ(p.ctx.?, z[0..@intCast(p.n_used) :0], .{ .func = int.destructor(rcstrUnref) });
        }
    } else if (p.e_err & JSTRING.OOM != 0) {
        api.resultErrorNomem(p.ctx.?);
    } else if (p.e_err & JSTRING.TOODEEP != 0) {
        // The error is already in p.ctx.
    } else if (p.e_err & JSTRING.MALFORMED != 0) {
        api.resultError(p.ctx.?, "malformed JSON");
    }
    jsonStringReset(p);
}

// ======================================================= JsonParse

/// Port of jsonParseReset(): free the memory of `parse`, but not the
/// object itself.
fn jsonParseReset(parse: *JsonParse) void {
    std.debug.assert(parse.n_jp_ref <= 1);
    if (parse.b_json_is_rcstr) {
        rcstrUnref(@constCast(parse.z_json.?));
        parse.z_json = null;
        parse.n_json = 0;
        parse.b_json_is_rcstr = false;
    }
    if (parse.n_blob_alloc != 0) {
        parse.gpa().free(parse.blob()[0..parse.n_blob_alloc]);
        parse.a_blob = null;
        parse.n_blob = 0;
        parse.n_blob_alloc = 0;
    }
}

/// Port of jsonParseFree(): drop a reference to `parse`, freeing it with
/// the last one.
fn jsonParseFree(parse_arg: ?*JsonParse) void {
    const parse = parse_arg orelse return;
    if (parse.n_jp_ref > 1) {
        parse.n_jp_ref -= 1;
    } else {
        jsonParseReset(parse);
        parse.gpa().destroy(parse);
    }
}

// ================================================== text parser

/// Port of jsonHexToInt(): the value of a hex digit (correct only for
/// hex digits).
fn jsonHexToInt(h_arg: u8) u8 {
    var h: u32 = h_arg;
    h += 9 * (1 & (h >> 6));
    return @truncate(h & 0xf);
}

/// Port of jsonHexToInt4(): the value of 4 hex digits.
fn jsonHexToInt4(z: [*]const u8) u32 {
    return (@as(u32, jsonHexToInt(z[0])) << 12) +
        (@as(u32, jsonHexToInt(z[1])) << 8) +
        (@as(u32, jsonHexToInt(z[2])) << 4) +
        jsonHexToInt(z[3]);
}

/// Port of jsonIs2Hex(): `z` starts with 2 hex digits.
fn jsonIs2Hex(z: [*]const u8) bool {
    return ctype.isXdigit(z[0]) and ctype.isXdigit(z[1]);
}

/// Port of jsonIs4Hex(): `z` starts with 4 hex digits.
fn jsonIs4Hex(z: [*]const u8) bool {
    return jsonIs2Hex(z) and jsonIs2Hex(z + 2);
}

/// Port of json5Whitespace(): bytes of JSON5 whitespace (including
/// comments) at the start of `z`.
fn json5Whitespace(z: [*]const u8) u32 {
    var n: u32 = 0;
    while (true) {
        switch (z[n]) {
            0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20 => n += 1,
            '/' => {
                if (z[n + 1] == '*' and z[n + 2] != 0) {
                    var j: u32 = n + 3;
                    while (z[j] != '/' or z[j - 1] != '*') : (j += 1) {
                        if (z[j] == 0) return n;
                    }
                    n = j + 1;
                } else if (z[n + 1] == '/') {
                    var j: u32 = n + 2;
                    while (true) : (j += 1) {
                        const c = z[j];
                        if (c == 0) break;
                        if (c == '\n' or c == '\r') break;
                        if (0xe2 == c and 0x80 == z[j + 1] and (0xa8 == z[j + 2] or 0xa9 == z[j + 2])) {
                            j += 2;
                            break;
                        }
                    }
                    n = j;
                    if (z[n] != 0) n += 1;
                } else {
                    return n;
                }
            },
            0xc2 => {
                if (z[n + 1] == 0xa0) {
                    n += 2;
                } else return n;
            },
            0xe1 => {
                if (z[n + 1] == 0x9a and z[n + 2] == 0x80) {
                    n += 3;
                } else return n;
            },
            0xe2 => {
                if (z[n + 1] == 0x80) {
                    const c = z[n + 2];
                    if (c < 0x80) return n;
                    if (c <= 0x8a or c == 0xa8 or c == 0xa9 or c == 0xaf) {
                        n += 3;
                    } else return n;
                } else if (z[n + 1] == 0x81 and z[n + 2] == 0x9f) {
                    n += 3;
                } else return n;
            },
            0xe3 => {
                if (z[n + 1] == 0x80 and z[n + 2] == 0x80) {
                    n += 3;
                } else return n;
            },
            0xef => {
                if (z[n + 1] == 0xbb and z[n + 2] == 0xbf) {
                    n += 3;
                } else return n;
            },
            else => return n,
        }
    }
}

/// aNanInfName[]: extra floating-point literals allowed in JSON.
const NanInfName = struct {
    c1: u8,
    c2: u8,
    n: u8,
    e_type: u8,
    z_match: []const u8,
    z_repl: []const u8,
};

const a_nan_inf_name = [_]NanInfName{
    .{ .c1 = 'i', .c2 = 'I', .n = 3, .e_type = JSONB.FLOAT, .z_match = "inf", .z_repl = "9.0e999" },
    .{ .c1 = 'i', .c2 = 'I', .n = 8, .e_type = JSONB.FLOAT, .z_match = "infinity", .z_repl = "9.0e999" },
    .{ .c1 = 'n', .c2 = 'N', .n = 3, .e_type = JSONB.NULL, .z_match = "NaN", .z_repl = "null" },
    .{ .c1 = 'q', .c2 = 'Q', .n = 4, .e_type = JSONB.NULL, .z_match = "QNaN", .z_repl = "null" },
    .{ .c1 = 's', .c2 = 'S', .n = 4, .e_type = JSONB.NULL, .z_match = "SNaN", .z_repl = "null" },
};

/// Port of jsonWrongNumArgs(): the error of json_insert(), json_replace()
/// or json_set() with an even number of arguments.
fn jsonWrongNumArgs(ctx: *Context, z_func_name: []const u8) void {
    const gpa = api.contextDbHandle(ctx).gpa;
    const msg = printf.mprintf(gpa, "json_%s() needs an odd number of arguments", &.{.{ .str = z_func_name }}) catch {
        api.resultErrorNomem(ctx);
        return;
    };
    defer gpa.free(msg);
    api.resultError(ctx, msg);
}

// ================================================ JSONB utilities

/// The failures of turning an argument into JSONB: out of memory (also
/// recorded in JsonParse.oom), or not JSON.
const ToBlobError = error{ OutOfMemory, Malformed };

/// Port of jsonBlobExpand(): make a_blob hold at least `n` bytes. On OOM
/// (C: an error count of 1) JsonParse.oom is set too.
fn jsonBlobExpand(parse: *JsonParse, n: u64) error{OutOfMemory}!void {
    std.debug.assert(n > parse.n_blob_alloc);
    var t: u64 = if (parse.n_blob_alloc == 0) 100 else @as(u64, parse.n_blob_alloc) * 2;
    if (t < n) t = n + 100;
    const gpa = parse.gpa();
    const new = if (parse.n_blob_alloc == 0)
        gpa.alloc(u8, @intCast(t))
    else
        gpa.realloc(parse.blob()[0..parse.n_blob_alloc], @intCast(t));
    const a_new = new catch |err| {
        parse.oom = true;
        return err;
    };
    std.debug.assert(t < 0x7fffffff);
    parse.a_blob = a_new.ptr;
    parse.n_blob_alloc = @intCast(t);
}

/// Port of jsonBlobMakeEditable(): copy an external a_blob (from
/// sqlite3_value_blob()) into memory of its own, with `n_extra` more
/// bytes. False on OOM.
fn jsonBlobMakeEditable(parse: *JsonParse, n_extra: u32) bool {
    std.debug.assert(!parse.b_read_only);
    if (parse.oom) return false;
    if (parse.n_blob_alloc > 0) return true;
    const a_old = parse.a_blob;
    const n_size: u64 = @as(u64, parse.n_blob) + n_extra;
    parse.a_blob = null;
    jsonBlobExpand(parse, n_size) catch return false;
    std.debug.assert(parse.n_blob_alloc >= parse.n_blob + n_extra);
    if (parse.n_blob > 0) @memcpy(parse.blob()[0..parse.n_blob], a_old.?[0..parse.n_blob]);
    return true;
}

/// Port of jsonBlobExpandAndAppendOneByte().
fn jsonBlobExpandAndAppendOneByte(parse: *JsonParse, c: u8) void {
    jsonBlobExpand(parse, @as(u64, parse.n_blob) + 1) catch {};
    if (!parse.oom) {
        std.debug.assert(parse.n_blob + 1 <= parse.n_blob_alloc);
        parse.blob()[parse.n_blob] = c;
        parse.n_blob += 1;
    }
}

/// Port of jsonBlobAppendOneByte().
fn jsonBlobAppendOneByte(parse: *JsonParse, c: u8) void {
    if (parse.n_blob >= parse.n_blob_alloc) {
        jsonBlobExpandAndAppendOneByte(parse, c);
    } else {
        parse.blob()[parse.n_blob] = c;
        parse.n_blob += 1;
    }
}

/// Port of jsonBlobExpandAndAppendNode().
fn jsonBlobExpandAndAppendNode(parse: *JsonParse, e_type: u8, sz_payload: u64, a_payload: ?[*]const u8) void {
    jsonBlobExpand(parse, @as(u64, parse.n_blob) + sz_payload + 9) catch return;
    jsonBlobAppendNode(parse, e_type, sz_payload, a_payload);
}

/// Port of jsonBlobAppendNode(): append a node header of type `e_type`
/// and payload size `sz_payload`, and the payload if `a_payload` is
/// given. Without it, a_blob is made big enough for the payload and
/// n_blob is left where the payload will go.
fn jsonBlobAppendNode(parse: *JsonParse, e_type: u8, sz_payload: u64, a_payload: ?[*]const u8) void {
    if (parse.n_blob + sz_payload + 9 > parse.n_blob_alloc) {
        jsonBlobExpandAndAppendNode(parse, e_type, sz_payload, a_payload);
        return;
    }
    const a = parse.blob() + parse.n_blob;
    if (sz_payload <= 11) {
        a[0] = e_type | @as(u8, @intCast(sz_payload << 4));
        parse.n_blob += 1;
    } else if (sz_payload <= 0xff) {
        a[0] = e_type | 0xc0;
        a[1] = @truncate(sz_payload);
        parse.n_blob += 2;
    } else if (sz_payload <= 0xffff) {
        a[0] = e_type | 0xd0;
        a[1] = @truncate(sz_payload >> 8);
        a[2] = @truncate(sz_payload);
        parse.n_blob += 3;
    } else {
        a[0] = e_type | 0xe0;
        a[1] = @truncate(sz_payload >> 24);
        a[2] = @truncate(sz_payload >> 16);
        a[3] = @truncate(sz_payload >> 8);
        a[4] = @truncate(sz_payload);
        parse.n_blob += 5;
    }
    if (a_payload) |pl| {
        const n: u32 = @intCast(sz_payload);
        parse.n_blob += n;
        @memcpy(parse.blob()[parse.n_blob - n ..][0..n], pl[0..n]);
    }
}

/// Port of jsonBlobChangePayloadSize(): make the payload size of the node
/// at `i` be `sz_payload`, resizing its header. Returns the change in
/// the header size.
fn jsonBlobChangePayloadSize(parse: *JsonParse, i: u32, sz_payload: u32) i32 {
    if (parse.oom) return 0;
    var a = parse.blob() + i;
    const sz_type = a[0] >> 4;
    const n_extra: i32 = if (sz_type <= 11) 0 else if (sz_type == 12) 1 else if (sz_type == 13) 2 else if (sz_type == 14) 4 else 8;
    const n_needed: i32 = if (sz_payload <= 11) 0 else if (sz_payload <= 0xff) 1 else if (sz_payload <= 0xffff) 2 else 4;
    const delta = n_needed - n_extra;
    if (delta != 0) {
        const new_size: u64 = @intCast(@as(i64, parse.n_blob) + delta);
        if (delta > 0) {
            if (new_size > parse.n_blob_alloc) {
                jsonBlobExpand(parse, new_size) catch return 0; // recorded in parse.oom
            }
            a = parse.blob() + i;
            const n = parse.n_blob - (i + 1);
            @memmove((a + 1 + @as(usize, @intCast(delta)))[0..n], (a + 1)[0..n]);
        } else {
            const d: u32 = @intCast(-delta);
            const n = parse.n_blob - (i + 1 + d);
            @memmove((a + 1)[0..n], (a + 1 + d)[0..n]);
        }
        parse.n_blob = @intCast(new_size);
    }
    if (n_needed == 0) {
        a[0] = (a[0] & 0x0f) | @as(u8, @intCast(sz_payload << 4));
    } else if (n_needed == 1) {
        a[0] = (a[0] & 0x0f) | 0xc0;
        a[1] = @truncate(sz_payload);
    } else if (n_needed == 2) {
        a[0] = (a[0] & 0x0f) | 0xd0;
        a[1] = @truncate(sz_payload >> 8);
        a[2] = @truncate(sz_payload);
    } else {
        a[0] = (a[0] & 0x0f) | 0xe0;
        a[1] = @truncate(sz_payload >> 24);
        a[2] = @truncate(sz_payload >> 16);
        a[3] = @truncate(sz_payload >> 8);
        a[4] = @truncate(sz_payload);
    }
    return delta;
}

/// Port of jsonIs4HexB(): if `z` is 'u' and 4 hex digits, set `op` to
/// JSONB.TEXTJ and return true.
fn jsonIs4HexB(z: [*]const u8, op: *u8) bool {
    if (z[0] != 'u') return false;
    if (!jsonIs4Hex(z + 1)) return false;
    op.* = JSONB.TEXTJ;
    return true;
}

/// Port of jsonbValidityCheck(): check the element at a_blob[i] that
/// must end just before `i_end`. Returns 0 if it is correct, else the
/// 1-based byte offset of the error.
fn jsonbValidityCheck(parse: *const JsonParse, i: u32, i_end: u32, i_depth: u32) u32 {
    if (i_depth > json_max_depth) return i + 1;
    var sz: u32 = 0;
    var n = jsonbPayloadSize(parse, i, &sz);
    if (n == 0) return i + 1; // Checked by caller
    if (i + n + sz != i_end) return i + 1; // Checked by caller
    const z = parse.blob();
    var x = z[i] & 0x0f;
    var j: u32 = undefined;
    var k: u32 = undefined;
    switch (x) {
        JSONB.NULL, JSONB.TRUE, JSONB.FALSE => return if (n + sz == 1) 0 else i + 1,
        JSONB.INT => {
            if (sz < 1) return i + 1;
            j = i + n;
            if (z[j] == '-') {
                j += 1;
                if (sz < 2) return i + 1;
            }
            k = i + n + sz;
            while (j < k) {
                if (ctype.isDigit(z[j])) {
                    j += 1;
                } else {
                    return j + 1;
                }
            }
            return 0;
        },
        JSONB.INT5 => {
            if (sz < 3) return i + 1;
            j = i + n;
            if (z[j] == '-') {
                if (sz < 4) return i + 1;
                j += 1;
            }
            if (z[j] != '0') return i + 1;
            if (z[j + 1] != 'x' and z[j + 1] != 'X') return j + 2;
            j += 2;
            k = i + n + sz;
            while (j < k) {
                if (ctype.isXdigit(z[j])) {
                    j += 1;
                } else {
                    return j + 1;
                }
            }
            return 0;
        },
        JSONB.FLOAT, JSONB.FLOAT5 => {
            // 0: initial. 1: '.' seen. 2: 'e' seen.
            var seen: u8 = 0;
            if (sz < 2) return i + 1;
            j = i + n;
            k = j + sz;
            if (z[j] == '-') {
                j += 1;
                if (sz < 3) return i + 1;
            }
            if (z[j] == '.') {
                if (x == JSONB.FLOAT) return j + 1;
                if (!ctype.isDigit(z[j + 1])) return j + 1;
                j += 2;
                seen = 1;
            } else if (z[j] == '0' and x == JSONB.FLOAT) {
                if (j + 3 > k) return j + 1;
                if (z[j + 1] != '.' and z[j + 1] != 'e' and z[j + 1] != 'E') return j + 1;
                j += 1;
            }
            while (j < k) : (j += 1) {
                if (ctype.isDigit(z[j])) continue;
                if (z[j] == '.') {
                    if (seen > 0) return j + 1;
                    if (x == JSONB.FLOAT and (j == k - 1 or !ctype.isDigit(z[j + 1]))) {
                        return j + 1;
                    }
                    seen = 1;
                    continue;
                }
                if (z[j] == 'e' or z[j] == 'E') {
                    if (seen == 2) return j + 1;
                    if (j == k - 1) return j + 1;
                    if (z[j + 1] == '+' or z[j + 1] == '-') {
                        j += 1;
                        if (j == k - 1) return j + 1;
                    }
                    seen = 2;
                    continue;
                }
                return j + 1;
            }
            if (seen == 0) return i + 1;
            return 0;
        },
        JSONB.TEXT => {
            j = i + n;
            k = j + sz;
            while (j < k) {
                if (!json_is_ok[z[j]] and z[j] != '\'') return j + 1;
                j += 1;
            }
            return 0;
        },
        JSONB.TEXTJ, JSONB.TEXT5 => {
            j = i + n;
            k = j + sz;
            while (j < k) {
                if (!json_is_ok[z[j]] and z[j] != '\'') {
                    if (z[j] == '"') {
                        if (x == JSONB.TEXTJ) return j + 1;
                    } else if (z[j] <= 0x1f) {
                        // Control characters in JSON5 string literals are ok.
                        if (x == JSONB.TEXTJ) return j + 1;
                    } else if (z[j] != '\\' or j + 1 >= k) {
                        return j + 1;
                    } else if (std.mem.indexOfScalar(u8, "\"\\/bfnrt\x00", z[j + 1]) != null) {
                        j += 1;
                    } else if (z[j + 1] == 'u') {
                        if (j + 5 >= k) return j + 1;
                        if (!jsonIs4Hex(z + j + 2)) return j + 1;
                        j += 1;
                    } else if (x != JSONB.TEXT5) {
                        return j + 1;
                    } else {
                        var c: u32 = 0;
                        const sz_c = jsonUnescapeOneChar(z + j, k - j, &c);
                        if (c == json_invalid_char) return j + 1;
                        j += sz_c - 1;
                    }
                }
                j += 1;
            }
            return 0;
        },
        JSONB.TEXTRAW => return 0,
        JSONB.ARRAY => {
            j = i + n;
            k = j + sz;
            while (j < k) {
                sz = 0;
                n = jsonbPayloadSize(parse, j, &sz);
                if (n == 0) return j + 1;
                if (j + n + sz > k) return j + 1;
                const sub = jsonbValidityCheck(parse, j, j + n + sz, i_depth + 1);
                if (sub != 0) return sub;
                j += n + sz;
            }
            std.debug.assert(j == k);
            return 0;
        },
        JSONB.OBJECT => {
            var cnt: u32 = 0;
            j = i + n;
            k = j + sz;
            while (j < k) {
                sz = 0;
                n = jsonbPayloadSize(parse, j, &sz);
                if (n == 0) return j + 1;
                if (j + n + sz > k) return j + 1;
                if (cnt & 1 == 0) {
                    x = z[j] & 0x0f;
                    if (x < JSONB.TEXT or x > JSONB.TEXTRAW) return j + 1;
                }
                const sub = jsonbValidityCheck(parse, j, j + n + sz, i_depth + 1);
                if (sub != 0) return sub;
                cnt += 1;
                j += n + sz;
            }
            std.debug.assert(j == k);
            if (cnt & 1 != 0) return j + 1;
            return 0;
        },
        else => return i + 1,
    }
}

/// Where jsonParseNumber() starts: at parse_number or parse_number_2.
const NumberEntry = enum { number, number_2 };

/// The number-parsing part of jsonTranslateTextToBlob() (from the
/// parse_number label): `t` bit 0x01 is JSON5, bit 0x02 FLOAT.
fn jsonParseNumber(parse: *JsonParse, i_arg: u32, t_arg: u8, entry: NumberEntry) i32 {
    const z = parse.z_json.?;
    var i = i_arg;
    var t = t_arg;
    var seen_e = false;
    var j: u32 = undefined;
    finish: {
        if (entry == .number) {
            const c = z[i];
            if (c <= '0') {
                if (c == '0') {
                    if ((z[i + 1] == 'x' or z[i + 1] == 'X') and ctype.isXdigit(z[i + 2])) {
                        std.debug.assert(t == 0x00);
                        parse.has_nonstd = true;
                        t = 0x01;
                        j = i + 3;
                        while (ctype.isXdigit(z[j])) j += 1;
                        break :finish;
                    } else if (ctype.isDigit(z[i + 1])) {
                        parse.i_err = i + 1;
                        return -1;
                    }
                } else {
                    if (!ctype.isDigit(z[i + 1])) {
                        // JSON5 allows "+Infinity" and "-Infinity" in exactly
                        // that case. SQLite also allows any case, and "+inf"
                        // and "-inf".
                        if ((z[i + 1] == 'I' or z[i + 1] == 'i') and strNICmp(z + i + 1, "inf") == 0) {
                            parse.has_nonstd = true;
                            if (z[i] == '-') {
                                jsonBlobAppendNode(parse, JSONB.FLOAT, 6, "-9e999");
                            } else {
                                jsonBlobAppendNode(parse, JSONB.FLOAT, 5, "9e999");
                            }
                            return @intCast(i + @as(u32, if (strNICmp(z + i + 4, "inity") == 0) 9 else 4));
                        }
                        if (z[i + 1] == '.') {
                            parse.has_nonstd = true;
                            t |= 0x01;
                        } else {
                            parse.i_err = i;
                            return -1;
                        }
                    } else if (z[i + 1] == '0') {
                        if (ctype.isDigit(z[i + 2])) {
                            parse.i_err = i + 1;
                            return -1;
                        } else if ((z[i + 2] == 'x' or z[i + 2] == 'X') and ctype.isXdigit(z[i + 3])) {
                            parse.has_nonstd = true;
                            t |= 0x01;
                            j = i + 4;
                            while (ctype.isXdigit(z[j])) j += 1;
                            break :finish;
                        }
                    }
                }
            }
        }

        // parse_number_2:
        j = i + 1;
        while (true) : (j += 1) {
            var c = z[j];
            if (ctype.isDigit(c)) continue;
            if (c == '.') {
                if (t & 0x02 != 0) {
                    parse.i_err = j;
                    return -1;
                }
                t |= 0x02;
                continue;
            }
            if (c == 'e' or c == 'E') {
                if (z[j - 1] < '0') {
                    if (z[j - 1] == '.' and j >= i + 2 and ctype.isDigit(z[j - 2])) {
                        parse.has_nonstd = true;
                        t |= 0x01;
                    } else {
                        parse.i_err = j;
                        return -1;
                    }
                }
                if (seen_e) {
                    parse.i_err = j;
                    return -1;
                }
                t |= 0x02;
                seen_e = true;
                c = z[j + 1];
                if (c == '+' or c == '-') {
                    j += 1;
                    c = z[j + 1];
                }
                if (c < '0' or c > '9') {
                    parse.i_err = j;
                    return -1;
                }
                continue;
            }
            break;
        }
        if (z[j - 1] < '0') {
            if (z[j - 1] == '.' and j >= i + 2 and ctype.isDigit(z[j - 2])) {
                parse.has_nonstd = true;
                t |= 0x01;
            } else {
                parse.i_err = j;
                return -1;
            }
        }
    }
    // parse_number_finish:
    if (z[i] == '+') i += 1;
    jsonBlobAppendNode(parse, JSONB.INT + t, j - i, z + i);
    return @intCast(j);
}

/// The string-parsing part of jsonTranslateTextToBlob() (from the
/// parse_string label).
fn jsonParseString(parse: *JsonParse, i: u32, opcode_arg: u8) i32 {
    const z = parse.z_json.?;
    var opcode = opcode_arg;
    const c_delim = z[i];
    var j: u32 = i + 1;
    while (true) {
        if (json_is_ok[z[j]]) {
            if (!json_is_ok[z[j + 1]]) {
                j += 1;
            } else if (!json_is_ok[z[j + 2]]) {
                j += 2;
            } else {
                j += 3;
                continue;
            }
        }
        var c = z[j];
        if (c == c_delim) {
            break;
        } else if (c == '\\') {
            j += 1;
            c = z[j];
            if (c == '"' or c == '\\' or c == '/' or c == 'b' or c == 'f' or
                c == 'n' or c == 'r' or c == 't' or
                (c == 'u' and jsonIs4Hex(z + j + 1)))
            {
                if (opcode == JSONB.TEXT) opcode = JSONB.TEXTJ;
            } else if (c == '\'' or c == 'v' or c == '\n' or
                (c == '0' and !ctype.isDigit(z[j + 1])) or
                (0xe2 == c and 0x80 == z[j + 1] and (0xa8 == z[j + 2] or 0xa9 == z[j + 2])) or
                (c == 'x' and jsonIs2Hex(z + j + 1)))
            {
                opcode = JSONB.TEXT5;
                parse.has_nonstd = true;
            } else if (c == '\r') {
                if (z[j + 1] == '\n') j += 1;
                opcode = JSONB.TEXT5;
                parse.has_nonstd = true;
            } else {
                parse.i_err = j;
                return -1;
            }
        } else if (c <= 0x1f) {
            if (c == 0) {
                parse.i_err = j;
                return -1;
            }
            // Control characters are not allowed in canonical JSON string
            // literals, but are allowed in JSON5 string literals.
            opcode = JSONB.TEXT5;
            parse.has_nonstd = true;
        } else if (c == '"') {
            opcode = JSONB.TEXT5;
        }
        j += 1;
    }
    jsonBlobAppendNode(parse, opcode, j - 1 - i, z + i + 1);
    return @intCast(j + 1);
}

/// Port of jsonTranslateTextToBlob(): translate the JSON element at
/// z_json[i] into JSONB appended to a_blob. Returns the index of the
/// first character past the element, or 0 at the end of input, -1 for a
/// syntax error or OOM, and -2, -3, -4 or -5 if '}', ']', ',' or ':' was
/// seen (with i_err its index).
fn jsonTranslateTextToBlob(parse: *JsonParse, i_arg: u32) i32 {
    const z = parse.z_json.?;
    var i = i_arg;
    while (true) {
        switch (z[i]) {
            '{' => {
                // Parse object
                const i_this = parse.n_blob;
                jsonBlobAppendNode(parse, JSONB.OBJECT, @intCast(@as(i64, parse.n_json) - i), null);
                parse.i_depth +%= 1;
                if (parse.i_depth > json_max_depth) {
                    parse.i_err = i;
                    return -1;
                }
                const i_start = parse.n_blob;
                var j: u32 = i + 1;
                while (true) : (j += 1) {
                    const i_blob = parse.n_blob;
                    var x = jsonTranslateTextToBlob(parse, j);
                    if (x <= 0) {
                        if (x == -2) {
                            j = parse.i_err;
                            if (parse.n_blob != i_start) parse.has_nonstd = true;
                            break;
                        }
                        j += json5Whitespace(z + j);
                        var op: u8 = JSONB.TEXT;
                        if (jsonId1(z[j]) or (z[j] == '\\' and jsonIs4HexB(z + j + 1, &op))) {
                            var k: u32 = j + 1;
                            while ((ctype.isIdChar(z[k]) and json5Whitespace(z + k) == 0) or
                                (z[k] == '\\' and jsonIs4HexB(z + k + 1, &op)))
                            {
                                k += 1;
                            }
                            std.debug.assert(i_blob == parse.n_blob);
                            jsonBlobAppendNode(parse, op, k - j, z + j);
                            parse.has_nonstd = true;
                            x = @intCast(k);
                        } else {
                            if (x != -1) parse.i_err = j;
                            return -1;
                        }
                    }
                    if (parse.oom) return -1;
                    const t = parse.blob()[i_blob] & 0x0f;
                    if (t < JSONB.TEXT or t > JSONB.TEXTRAW) {
                        parse.i_err = j;
                        return -1;
                    }
                    j = @intCast(x);
                    value: {
                        if (z[j] == ':') {
                            j += 1;
                        } else {
                            if (jsonIsspace(z[j])) {
                                // strspn() is not helpful here
                                j += 1;
                                while (jsonIsspace(z[j])) j += 1;
                                if (z[j] == ':') {
                                    j += 1;
                                    break :value;
                                }
                            }
                            x = jsonTranslateTextToBlob(parse, j);
                            if (x != -5) {
                                if (x != -1) parse.i_err = j;
                                return -1;
                            }
                            j = parse.i_err + 1;
                        }
                    }
                    // parse_object_value:
                    x = jsonTranslateTextToBlob(parse, j);
                    if (x <= 0) {
                        if (x != -1) parse.i_err = j;
                        return -1;
                    }
                    j = @intCast(x);
                    if (z[j] == ',') {
                        continue;
                    } else if (z[j] == '}') {
                        break;
                    } else {
                        if (jsonIsspace(z[j])) {
                            j += 1 + jsonSpaces(z + j + 1);
                            if (z[j] == ',') {
                                continue;
                            } else if (z[j] == '}') {
                                break;
                            }
                        }
                        x = jsonTranslateTextToBlob(parse, j);
                        if (x == -4) {
                            j = parse.i_err;
                            continue;
                        }
                        if (x == -2) {
                            j = parse.i_err;
                            break;
                        }
                    }
                    parse.i_err = j;
                    return -1;
                }
                _ = jsonBlobChangePayloadSize(parse, i_this, parse.n_blob - i_start);
                parse.i_depth -%= 1;
                return @intCast(j + 1);
            },
            '[' => {
                // Parse array
                const i_this = parse.n_blob;
                std.debug.assert(i <= parse.n_json);
                jsonBlobAppendNode(parse, JSONB.ARRAY, @intCast(@as(i64, parse.n_json) - i), null);
                const i_start = parse.n_blob;
                if (parse.oom) return -1;
                parse.i_depth +%= 1;
                if (parse.i_depth > json_max_depth) {
                    parse.i_err = i;
                    return -1;
                }
                var j: u32 = i + 1;
                while (true) : (j += 1) {
                    var x = jsonTranslateTextToBlob(parse, j);
                    if (x <= 0) {
                        if (x == -3) {
                            j = parse.i_err;
                            if (parse.n_blob != i_start) parse.has_nonstd = true;
                            break;
                        }
                        if (x != -1) parse.i_err = j;
                        return -1;
                    }
                    j = @intCast(x);
                    if (z[j] == ',') {
                        continue;
                    } else if (z[j] == ']') {
                        break;
                    } else {
                        if (jsonIsspace(z[j])) {
                            j += 1 + jsonSpaces(z + j + 1);
                            if (z[j] == ',') {
                                continue;
                            } else if (z[j] == ']') {
                                break;
                            }
                        }
                        x = jsonTranslateTextToBlob(parse, j);
                        if (x == -4) {
                            j = parse.i_err;
                            continue;
                        }
                        if (x == -3) {
                            j = parse.i_err;
                            break;
                        }
                    }
                    parse.i_err = j;
                    return -1;
                }
                _ = jsonBlobChangePayloadSize(parse, i_this, parse.n_blob - i_start);
                parse.i_depth -%= 1;
                return @intCast(j + 1);
            },
            '\'' => {
                parse.has_nonstd = true;
                return jsonParseString(parse, i, JSONB.TEXT);
            },
            '"' => return jsonParseString(parse, i, JSONB.TEXT),
            't' => {
                if (strNCmp(z + i, "true") and !ctype.isAlnum(z[i + 4])) {
                    jsonBlobAppendOneByte(parse, JSONB.TRUE);
                    return @intCast(i + 4);
                }
                parse.i_err = i;
                return -1;
            },
            'f' => {
                if (strNCmp(z + i, "false") and !ctype.isAlnum(z[i + 5])) {
                    jsonBlobAppendOneByte(parse, JSONB.FALSE);
                    return @intCast(i + 5);
                }
                parse.i_err = i;
                return -1;
            },
            '+' => {
                parse.has_nonstd = true;
                return jsonParseNumber(parse, i, 0x00, .number);
            },
            '.' => {
                if (ctype.isDigit(z[i + 1])) {
                    parse.has_nonstd = true;
                    return jsonParseNumber(parse, i, 0x03, .number_2);
                }
                parse.i_err = i;
                return -1;
            },
            '-', '0'...'9' => return jsonParseNumber(parse, i, 0x00, .number),
            '}' => {
                parse.i_err = i;
                return -2; // End of {...}
            },
            ']' => {
                parse.i_err = i;
                return -3; // End of [...]
            },
            ',' => {
                parse.i_err = i;
                return -4; // List separator
            },
            ':' => {
                parse.i_err = i;
                return -5; // Object label/value separator
            },
            0 => return 0, // End of file
            0x09, 0x0a, 0x0d, 0x20 => {
                i += 1 + jsonSpaces(z + i + 1);
                continue;
            },
            0x0b, 0x0c, '/', 0xc2, 0xe1, 0xe2, 0xe3, 0xef => {
                const j = json5Whitespace(z + i);
                if (j > 0) {
                    i += j;
                    parse.has_nonstd = true;
                    continue;
                }
                parse.i_err = i;
                return -1;
            },
            else => |c| {
                if (c == 'n' and strNCmp(z + i, "null") and !ctype.isAlnum(z[i + 4])) {
                    jsonBlobAppendOneByte(parse, JSONB.NULL);
                    return @intCast(i + 4);
                }
                // Fall through to the check for NaN and Inf.
                for (a_nan_inf_name) |info| {
                    if (c != info.c1 and c != info.c2) continue;
                    const nn = info.n;
                    if (strNICmp(z + i, info.z_match) != 0) continue;
                    if (ctype.isAlnum(z[i + nn])) continue;
                    if (info.e_type == JSONB.FLOAT) {
                        jsonBlobAppendNode(parse, JSONB.FLOAT, 5, "9e999");
                    } else {
                        jsonBlobAppendOneByte(parse, JSONB.NULL);
                    }
                    parse.has_nonstd = true;
                    return @intCast(i + nn);
                }
                parse.i_err = i;
                return -1; // Syntax error
            },
        }
    }
}

/// strncmp(z, lit, lit.len) == 0, for a NUL-terminated `z`.
fn strNCmp(z: [*]const u8, lit: []const u8) bool {
    for (lit, 0..) |c, k| {
        if (z[k] != c) return false;
    }
    return true;
}

/// Port of jsonConvertTextToBlob(): parse the complete JSON text in
/// z_json. On an error (C: non-zero) the memory of `parse` (not the
/// object) is freed and, with `ctx`, an error set.
fn jsonConvertTextToBlob(parse: *JsonParse, ctx: ?*Context) ToBlobError!void {
    const z_json = parse.z_json.?;
    var i = jsonTranslateTextToBlob(parse, 0);
    if (parse.oom) i = -1;
    if (i > 0) {
        var k: u32 = @intCast(i);
        while (jsonIsspace(z_json[k])) k += 1;
        if (z_json[k] != 0) {
            k += json5Whitespace(z_json + k);
            if (z_json[k] != 0) {
                if (ctx) |c| api.resultError(c, "malformed JSON");
                jsonParseReset(parse);
                return error.Malformed;
            }
            parse.has_nonstd = true;
        }
    }
    if (i <= 0) {
        if (ctx) |c| {
            if (parse.oom) {
                api.resultErrorNomem(c);
            } else {
                api.resultError(c, "malformed JSON");
            }
        }
        const oom = parse.oom;
        jsonParseReset(parse);
        return if (oom) error.OutOfMemory else error.Malformed;
    }
}

/// Port of jsonReturnStringAsBlob(): convert the well-formed JSON text in
/// `str` to JSONB and make that the result.
fn jsonReturnStringAsBlob(str: *JsonString) void {
    std.debug.assert(str.e_err == 0);
    const ctx = str.ctx.?;
    var px: JsonParse = .{ .z_json = str.buf(), .n_json = @intCast(str.n_used), .db = api.contextDbHandle(ctx) };
    _ = jsonTranslateTextToBlob(&px, 0);
    if (px.oom) {
        if (px.n_blob_alloc > 0) px.gpa().free(px.blob()[0..px.n_blob_alloc]);
        api.resultErrorNomem(ctx);
    } else {
        std.debug.assert(px.n_blob_alloc > 0);
        std.debug.assert(!px.b_read_only);
        func.resultOwnedBlob(ctx, px.blob()[0..px.n_blob_alloc], px.n_blob);
    }
}

/// The payload-size checks of jsonbPayloadSize(): the element at `i`
/// with header `n` and payload `sz` must fit in a_blob, or in what a_blob
/// was before an edit changed its size by delta.
fn jsonbFits(parse: *const JsonParse, i: u32, n: u32, sz: u32) bool {
    const end = @as(i64, i) + sz + n;
    return !(end > parse.n_blob and end > @as(i64, parse.n_blob -% @as(u32, @bitCast(parse.delta))));
}

/// Port of jsonbPayloadSizeWide(): jsonbPayloadSize() for the 2, 4 and 8
/// byte payload sizes.
fn jsonbPayloadSizeWide(parse: *const JsonParse, i: u32, p_sz: *u32, x: u8) u32 {
    std.debug.assert(i < parse.n_blob);
    std.debug.assert(x >= 13);
    const a = parse.blob();
    var sz: u32 = undefined;
    var n: u32 = undefined;
    if (x == 13) {
        if (i + 2 >= parse.n_blob) {
            p_sz.* = 0;
            return 0;
        }
        sz = (@as(u32, a[i + 1]) << 8) + a[i + 2];
        n = 3;
    } else if (x == 14) {
        if (i + 4 >= parse.n_blob) {
            p_sz.* = 0;
            return 0;
        }
        sz = (@as(u32, a[i + 1]) << 24) + (@as(u32, a[i + 2]) << 16) +
            (@as(u32, a[i + 3]) << 8) + a[i + 4];
        n = 5;
    } else {
        if (i + 8 >= parse.n_blob or a[i + 1] != 0 or a[i + 2] != 0 or a[i + 3] != 0 or a[i + 4] != 0) {
            p_sz.* = 0;
            return 0;
        }
        sz = (@as(u32, a[i + 5]) << 24) + (@as(u32, a[i + 6]) << 16) +
            (@as(u32, a[i + 7]) << 8) + a[i + 8];
        n = 9;
    }
    if (!jsonbFits(parse, i, n, sz)) {
        p_sz.* = 0;
        return 0;
    }
    p_sz.* = sz;
    return n;
}

/// Port of jsonbPayloadSize(): the payload size of the node at a_blob[i]
/// goes to `p_sz`; returns the size of its header (the offset of the
/// payload), or 0 on an error. (jsonbPayloadSizeInline() and
/// jsonbPayloadSizeSemiInline() are the same.)
fn jsonbPayloadSize(parse: *const JsonParse, i: u32, p_sz: *u32) u32 {
    if (i >= parse.n_blob) {
        p_sz.* = 0;
        return 0;
    }
    const a = parse.blob();
    const x = a[i] >> 4;
    var sz: u32 = undefined;
    var n: u32 = undefined;
    if (x <= 11) {
        sz = x;
        n = 1;
    } else if (x == 12) {
        if (i + 1 >= parse.n_blob) {
            p_sz.* = 0;
            return 0;
        }
        sz = a[i + 1];
        n = 2;
    } else {
        return jsonbPayloadSizeWide(parse, i, p_sz, x);
    }
    if (!jsonbFits(parse, i, n, sz)) {
        p_sz.* = 0;
        return 0;
    }
    p_sz.* = sz;
    return n;
}

/// Port of jsonTranslateBlobToText(): append the JSON text of the JSONB
/// element at a_blob[i] to `out`. Returns the index past the element.
/// Some errors in the blob set JSTRING.MALFORMED; others may just give
/// incorrect JSON.
fn jsonTranslateBlobToText(parse: *JsonParse, i: u32, out: *JsonString) u32 {
    var sz: u32 = undefined;
    const n = jsonbPayloadSize(parse, i, &sz);
    if (n == 0) {
        out.e_err |= JSTRING.MALFORMED;
        return parse.n_blob + 1;
    }
    const a = parse.blob();
    malformed: {
        switch (a[i] & 0x0f) {
            JSONB.NULL => {
                jsonAppendRawNZ(out, "null");
                return i + 1;
            },
            JSONB.TRUE => {
                jsonAppendRawNZ(out, "true");
                return i + 1;
            },
            JSONB.FALSE => {
                jsonAppendRawNZ(out, "false");
                return i + 1;
            },
            JSONB.INT, JSONB.FLOAT => {
                if (sz == 0) break :malformed;
                jsonAppendRaw(out, a[i + n ..][0..sz]);
            },
            JSONB.INT5 => {
                // Integer literal in hexadecimal notation.
                var k: u32 = 2;
                var u: u64 = 0;
                const z_in = a + i + n;
                var b_overflow = false;
                if (sz == 0) break :malformed;
                if (z_in[0] == '-') {
                    jsonAppendChar(out, '-');
                    k += 1;
                } else if (z_in[0] == '+') {
                    k += 1;
                }
                while (k < sz) : (k += 1) {
                    if (!ctype.isXdigit(z_in[k])) {
                        out.e_err |= JSTRING.MALFORMED;
                        break;
                    } else if (u >> 60 != 0) {
                        b_overflow = true;
                    } else {
                        u = u * 16 + util.hexToInt(z_in[k]);
                    }
                }
                if (b_overflow) {
                    jsonPrintf(100, out, "9.0e999", &.{});
                } else {
                    jsonPrintf(100, out, "%llu", &.{.{ .int = @bitCast(u) }});
                }
            },
            JSONB.FLOAT5 => {
                // Float literal missing digits beside ".".
                var k: u32 = 0;
                const z_in = a + i + n;
                if (sz == 0) break :malformed;
                if (z_in[0] == '-') {
                    jsonAppendChar(out, '-');
                    if (sz <= 1) break :malformed;
                    k = 1;
                }
                if (z_in[k] == '.') jsonAppendChar(out, '0');
                while (k < sz) : (k += 1) {
                    jsonAppendChar(out, z_in[k]);
                    if (z_in[k] == '.' and (k + 1 == sz or !ctype.isDigit(z_in[k + 1]))) {
                        jsonAppendChar(out, '0');
                    }
                }
            },
            JSONB.TEXT, JSONB.TEXTJ => {
                if (out.n_used + sz + 2 <= out.n_alloc or jsonStringGrow(out, sz + 2) == 0) {
                    const o = out.buf() + @as(usize, @intCast(out.n_used));
                    o[0] = '"';
                    @memcpy(o[1..][0..sz], a[i + n ..][0..sz]);
                    o[sz + 1] = '"';
                    out.n_used += sz + 2;
                }
            },
            JSONB.TEXT5 => {
                var z_in = a + i + n;
                var sz2 = sz;
                jsonAppendChar(out, '"');
                while (sz2 > 0) {
                    var k: u32 = 0;
                    while (k < sz2 and (json_is_ok[z_in[k]] or z_in[k] == '\'')) k += 1;
                    if (k > 0) {
                        jsonAppendRawNZ(out, z_in[0..k]);
                        if (k >= sz2) break;
                        z_in += k;
                        sz2 -= k;
                    }
                    if (z_in[0] == '"') {
                        jsonAppendRawNZ(out, "\\\"");
                        z_in += 1;
                        sz2 -= 1;
                        continue;
                    }
                    if (z_in[0] <= 0x1f) {
                        if (out.n_used + 7 > out.n_alloc and jsonStringGrow(out, 7) != 0) break;
                        jsonAppendControlChar(out, z_in[0]);
                        z_in += 1;
                        sz2 -= 1;
                        continue;
                    }
                    std.debug.assert(z_in[0] == '\\');
                    std.debug.assert(sz2 >= 1);
                    if (sz2 < 2) {
                        out.e_err |= JSTRING.MALFORMED;
                        break;
                    }
                    switch (z_in[1]) {
                        '\'' => jsonAppendChar(out, '\''),
                        'v' => jsonAppendRawNZ(out, "\\u000b"),
                        'x' => {
                            if (sz2 < 4) {
                                out.e_err |= JSTRING.MALFORMED;
                                sz2 = 2;
                            } else {
                                jsonAppendRawNZ(out, "\\u00");
                                jsonAppendRawNZ(out, z_in[2..4]);
                                z_in += 2;
                                sz2 -= 2;
                            }
                        },
                        '0' => jsonAppendRawNZ(out, "\\u0000"),
                        '\r' => {
                            if (sz2 > 2 and z_in[2] == '\n') {
                                z_in += 1;
                                sz2 -= 1;
                            }
                        },
                        '\n' => {},
                        0xe2 => {
                            // '\' followed by U+2028 or U+2029 is ignored as
                            // whitespace. In UTF8, U+2028 is 0xe2 0x80 0xa8 and
                            // U+2029 the same but for the last byte.
                            if (sz2 < 4 or 0x80 != z_in[2] or (0xa8 != z_in[3] and 0xa9 != z_in[3])) {
                                out.e_err |= JSTRING.MALFORMED;
                                sz2 = 2;
                            } else {
                                z_in += 2;
                                sz2 -= 2;
                            }
                        },
                        else => jsonAppendRawNZ(out, z_in[0..2]),
                    }
                    std.debug.assert(sz2 >= 2);
                    z_in += 2;
                    sz2 -= 2;
                }
                jsonAppendChar(out, '"');
            },
            JSONB.TEXTRAW => jsonAppendString(out, a[i + n ..][0..sz]),
            JSONB.ARRAY => {
                jsonAppendChar(out, '[');
                var j = i + n;
                const i_end = j + sz;
                parse.i_depth +%= 1;
                if (parse.i_depth > json_max_depth) jsonStringTooDeep(out);
                while (j < i_end and out.e_err == 0) {
                    j = jsonTranslateBlobToText(parse, j, out);
                    jsonAppendChar(out, ',');
                }
                parse.i_depth -%= 1;
                if (j > i_end) out.e_err |= JSTRING.MALFORMED;
                if (sz > 0) jsonStringTrimOneChar(out);
                jsonAppendChar(out, ']');
            },
            JSONB.OBJECT => {
                var x: u32 = 0;
                jsonAppendChar(out, '{');
                var j = i + n;
                const i_end = j + sz;
                parse.i_depth +%= 1;
                if (parse.i_depth > json_max_depth) jsonStringTooDeep(out);
                while (j < i_end and out.e_err == 0) {
                    j = jsonTranslateBlobToText(parse, j, out);
                    jsonAppendChar(out, if (x & 1 != 0) ',' else ':');
                    x += 1;
                }
                parse.i_depth -%= 1;
                if (x & 1 != 0 or j > i_end) out.e_err |= JSTRING.MALFORMED;
                if (sz > 0) jsonStringTrimOneChar(out);
                jsonAppendChar(out, '}');
            },
            else => break :malformed,
        }
        return i + n + sz;
    }
    // malformed_jsonb:
    out.e_err |= JSTRING.MALFORMED;
    return i + n + sz;
}

/// The context of the recursion of json_pretty() (JsonPretty).
const JsonPretty = struct {
    /// The BLOB being rendered.
    parse: *JsonParse,
    /// The pretty output goes here.
    out: *JsonString,
    /// Text for one level of indentation.
    z_indent: []const u8,
    /// Current level of indentation.
    n_indent: u32 = 0,
};

/// Port of jsonPrettyIndent(): append the indentation.
fn jsonPrettyIndent(pretty: *JsonPretty) void {
    for (0..pretty.n_indent) |_| jsonAppendRaw(pretty.out, pretty.z_indent);
}

/// Port of jsonTranslateBlobToPrettyText(): jsonTranslateBlobToText()
/// with extra whitespace that makes the JSON easier to read.
fn jsonTranslateBlobToPrettyText(pretty: *JsonPretty, i_arg: u32) u32 {
    var i = i_arg;
    const parse = pretty.parse;
    const out = pretty.out;
    var sz: u32 = undefined;
    const n = jsonbPayloadSize(parse, i, &sz);
    if (n == 0) {
        out.e_err |= JSTRING.MALFORMED;
        return parse.n_blob + 1;
    }
    switch (parse.blob()[i] & 0x0f) {
        JSONB.ARRAY => {
            var j = i + n;
            const i_end = j + sz;
            jsonAppendChar(out, '[');
            if (j < i_end) {
                jsonAppendChar(out, '\n');
                pretty.n_indent += 1;
                if (pretty.n_indent >= json_max_depth) jsonStringTooDeep(out);
                while (out.e_err == 0) {
                    jsonPrettyIndent(pretty);
                    j = jsonTranslateBlobToPrettyText(pretty, j);
                    if (j >= i_end) {
                        if (j > i_end) out.e_err |= JSTRING.MALFORMED;
                        break;
                    }
                    jsonAppendRawNZ(out, ",\n");
                }
                jsonAppendChar(out, '\n');
                pretty.n_indent -= 1;
                jsonPrettyIndent(pretty);
            }
            jsonAppendChar(out, ']');
            i = i_end;
        },
        JSONB.OBJECT => {
            var j = i + n;
            const i_end = j + sz;
            jsonAppendChar(out, '{');
            if (j < i_end) {
                jsonAppendChar(out, '\n');
                pretty.n_indent += 1;
                if (pretty.n_indent >= json_max_depth) jsonStringTooDeep(out);
                parse.i_depth = @intCast(pretty.n_indent);
                while (out.e_err == 0) {
                    jsonPrettyIndent(pretty);
                    j = jsonTranslateBlobToText(parse, j, out);
                    if (j > i_end) {
                        out.e_err |= JSTRING.MALFORMED;
                        break;
                    }
                    jsonAppendRawNZ(out, ": ");
                    j = jsonTranslateBlobToPrettyText(pretty, j);
                    if (j >= i_end) break;
                    jsonAppendRawNZ(out, ",\n");
                }
                jsonAppendChar(out, '\n');
                pretty.n_indent -= 1;
                jsonPrettyIndent(pretty);
            }
            jsonAppendChar(out, '}');
            i = i_end;
        },
        else => i = jsonTranslateBlobToText(parse, i, out),
    }
    return i;
}

/// Port of jsonbArrayCount(): the number of entries of the JSONB.ARRAY at
/// `i_root`.
fn jsonbArrayCount(parse: *JsonParse, i_root: u32) u32 {
    var sz: u32 = undefined;
    var n = jsonbPayloadSize(parse, i_root, &sz);
    const i_end = i_root + n + sz;
    var k: u32 = 0;
    var i = i_root + n;
    while (n > 0 and i < i_end) {
        n = jsonbPayloadSize(parse, i, &sz);
        i += sz + n;
        k += 1;
    }
    return k;
}

/// Port of jsonAfterEditSizeAdjust(): change the payload size of the
/// element at `i_root` by delta.
fn jsonAfterEditSizeAdjust(parse: *JsonParse, i_root: u32) void {
    var sz: u32 = 0;
    std.debug.assert(parse.delta != 0);
    std.debug.assert(parse.n_blob_alloc >= parse.n_blob);
    const n_blob = parse.n_blob;
    parse.n_blob = parse.n_blob_alloc;
    _ = jsonbPayloadSize(parse, i_root, &sz);
    parse.n_blob = n_blob;
    sz +%= @bitCast(parse.delta);
    parse.delta += jsonBlobChangePayloadSize(parse, i_root, sz);
}

/// Port of jsonBlobOverwrite(): if the JSONB in a_ins[0..n_ins] can be
/// made `d` bytes larger (1 to 8) by a less compact size field, write
/// that to a_out and return true. This makes an overwrite keep the size
/// of the JSONB. False if that cannot be done (easily).
fn jsonBlobOverwrite(a_out: [*]u8, a_ins: [*]const u8, n_ins: u32, d: u32) bool {
    // The upper 4 bits of the first byte of the expanded a_ins, by the
    // size of the expanded header:   2     3  4     5  6  7  8     9
    const a_type = [_]u8{ 0xc0, 0xd0, 0, 0xe0, 0, 0, 0, 0xf0 };
    var i: u32 = undefined;
    var sz_hdr: u32 = undefined;
    if (a_ins[0] & 0x0f <= 2) return false; // Cannot enlarge NULL, true, false
    switch (a_ins[0] >> 4) {
        12 => {
            // a_ins header size is 2: d must be 1, 3 or 7.
            if ((@as(u32, 1) << @intCast(d)) & 0x8a == 0) return false;
            i = d + 2;
            sz_hdr = 2;
        },
        13 => {
            // a_ins header size is 3: d must be 2 or 6.
            if (d != 2 and d != 6) return false;
            i = d + 3;
            sz_hdr = 3;
        },
        14 => {
            // a_ins header size is 5: d must be 4.
            if (d != 4) return false;
            i = 9;
            sz_hdr = 5;
        },
        15 => return false, // a_ins header size is 9: no solution
        else => {
            // a_ins header size 1: d must be 1, 2, 4 or 8.
            if ((@as(u32, 1) << @intCast(d)) & 0x116 == 0) return false;
            i = d + 1;
            sz_hdr = 1;
        },
    }
    std.debug.assert(i >= 2 and i <= 9 and a_type[i - 2] != 0);
    a_out[0] = (a_ins[0] & 0x0f) | a_type[i - 2];
    @memmove((a_out + i)[0 .. n_ins - sz_hdr], (a_ins + sz_hdr)[0 .. n_ins - sz_hdr]);
    var sz_payload = n_ins - sz_hdr;
    while (true) {
        i -= 1;
        a_out[i] = @truncate(sz_payload);
        if (i == 1) break;
        sz_payload >>= 8;
    }
    std.debug.assert(sz_payload >> 8 == 0);
    return true;
}

/// Port of jsonBlobEdit(): replace the `n_del` bytes of a_blob at `i_del`
/// with the `n_ins` bytes of `a_ins`. Without `a_ins` the space is made
/// but left uninitialized. Sets oom on OOM.
fn jsonBlobEdit(parse: *JsonParse, i_del: u32, n_del: u32, a_ins: ?[*]const u8, n_ins: u32) void {
    const d: i64 = @as(i64, n_ins) - @as(i64, n_del);
    std.debug.assert(parse.n_blob >= @as(u64, i_del) + n_del);
    if (d < 0 and d >= -8 and a_ins != null and
        jsonBlobOverwrite(parse.blob() + i_del, a_ins.?, n_ins, @intCast(-d)))
    {
        return;
    }
    if (d != 0) {
        if (parse.n_blob + d > parse.n_blob_alloc) {
            jsonBlobExpand(parse, @intCast(parse.n_blob + d)) catch return;
        }
        const a = parse.blob();
        {
            const n = parse.n_blob - (i_del + n_del);
            @memmove((a + i_del + n_ins)[0..n], (a + i_del + n_del)[0..n]);
        }
        parse.n_blob = @intCast(parse.n_blob + d);
        parse.delta += @intCast(d);
    }
    if (n_ins != 0) {
        if (a_ins) |ins| @memmove((parse.blob() + i_del)[0..n_ins], ins[0..n_ins]);
    }
}

/// Port of jsonBytesToBypass(): the bytes of escaped newlines to ignore
/// at the start of z[0..n]. An escaped newline is 0x5c followed by 0x0a,
/// 0x0d, 0x0d 0x0a, 0xe2 0x80 0xa8 or 0xe2 0x80 0xa9.
fn jsonBytesToBypass(z: [*]const u8, n: u32) u32 {
    var i: u32 = 0;
    while (i + 1 < n) {
        if (z[i] != '\\') return i;
        if (z[i + 1] == '\n') {
            i += 2;
            continue;
        }
        if (z[i + 1] == '\r') {
            if (i + 2 < n and z[i + 2] == '\n') {
                i += 3;
            } else {
                i += 2;
            }
            continue;
        }
        if (0xe2 == z[i + 1] and i + 3 < n and 0x80 == z[i + 2] and (0xa8 == z[i + 3] or 0xa9 == z[i + 3])) {
            i += 4;
            continue;
        }
        break;
    }
    return i;
}

/// Port of jsonUnescapeOneChar(): decode the JSON escape sequence (with
/// its leading '\\') in z[0..n] into `out`; returns its length. A syntax
/// error gives json_invalid_char.
fn jsonUnescapeOneChar(z: [*]const u8, n: u32, out: *u32) u32 {
    std.debug.assert(n > 0);
    std.debug.assert(z[0] == '\\');
    if (n < 2) {
        out.* = json_invalid_char;
        return n;
    }
    switch (z[1]) {
        'u' => {
            if (n < 6) {
                out.* = json_invalid_char;
                return n;
            }
            const v = jsonHexToInt4(z + 2);
            if (v & 0xfc00 == 0xd800 and n >= 12 and z[6] == '\\' and z[7] == 'u') {
                const vlo = jsonHexToInt4(z + 8);
                if (vlo & 0xfc00 == 0xdc00) {
                    out.* = ((v & 0x3ff) << 10) + (vlo & 0x3ff) + 0x10000;
                    return 12;
                }
            }
            out.* = v;
            return 6;
        },
        'b' => {
            out.* = 0x08;
            return 2;
        },
        'f' => {
            out.* = 0x0c;
            return 2;
        },
        'n' => {
            out.* = '\n';
            return 2;
        },
        'r' => {
            out.* = '\r';
            return 2;
        },
        't' => {
            out.* = '\t';
            return 2;
        },
        'v' => {
            out.* = 0x0b;
            return 2;
        },
        '0' => {
            // JSON5 requires that \0 not be followed by a digit (not
            // enforced by 3.42.0 through 3.49.2, SQLITE_BUG_COMPATIBLE_20250510).
            out.* = if (n > 2 and ctype.isDigit(z[2])) json_invalid_char else 0;
            return 2;
        },
        '\'', '"', '/', '\\' => {
            out.* = z[1];
            return 2;
        },
        'x' => {
            if (n < 4) {
                out.* = json_invalid_char;
                return n;
            }
            out.* = (@as(u32, jsonHexToInt(z[2])) << 4) | jsonHexToInt(z[3]);
            return 4;
        },
        0xe2, '\r', '\n' => {
            const n_skip = jsonBytesToBypass(z, n);
            if (n_skip == 0) {
                out.* = json_invalid_char;
                return n;
            } else if (n_skip == n) {
                out.* = 0;
                return n;
            } else if (z[n_skip] == '\\') {
                return n_skip + jsonUnescapeOneChar(z + n_skip, n - n_skip, out);
            } else {
                const sz = utf8ReadLimited(z + n_skip, n - n_skip, out);
                return n_skip + sz;
            }
        },
        else => {
            out.* = json_invalid_char;
            return 2;
        },
    }
}

/// Port of jsonLabelCompareEscaped(): the labels are equal, where one or
/// both contain escapes.
fn jsonLabelCompareEscaped(z_left_arg: [*]const u8, n_left_arg: u32, raw_left: bool, z_right_arg: [*]const u8, n_right_arg: u32, raw_right: bool) bool {
    var z_left = z_left_arg;
    var n_left = n_left_arg;
    var z_right = z_right_arg;
    var n_right = n_right_arg;
    std.debug.assert(!raw_left or !raw_right);
    while (true) {
        var c_left: u32 = undefined;
        var c_right: u32 = undefined;
        if (n_left == 0) {
            c_left = 0;
        } else if (raw_left or z_left[0] != '\\') {
            c_left = z_left[0];
            if (c_left >= 0xc0) {
                const sz = utf8ReadLimited(z_left, n_left, &c_left);
                z_left += sz;
                n_left -= sz;
            } else {
                z_left += 1;
                n_left -= 1;
            }
        } else {
            const n = jsonUnescapeOneChar(z_left, n_left, &c_left);
            z_left += n;
            std.debug.assert(n <= n_left);
            n_left -= n;
        }
        if (n_right == 0) {
            c_right = 0;
        } else if (raw_right or z_right[0] != '\\') {
            c_right = z_right[0];
            if (c_right >= 0xc0) {
                const sz = utf8ReadLimited(z_right, n_right, &c_right);
                z_right += sz;
                n_right -= sz;
            } else {
                z_right += 1;
                n_right -= 1;
            }
        } else {
            const n = jsonUnescapeOneChar(z_right, n_right, &c_right);
            z_right += n;
            std.debug.assert(n <= n_right);
            n_right -= n;
        }
        if (c_left != c_right) return false;
        if (c_left == 0) return true;
    }
}

/// Port of jsonLabelCompare(): the two object labels are equal.
fn jsonLabelCompare(z_left: [*]const u8, n_left: u32, raw_left: bool, z_right: [*]const u8, n_right: u32, raw_right: bool) bool {
    if (raw_left and raw_right) {
        // Neither label contains escapes: memcmp() is enough.
        if (n_left != n_right) return false;
        return std.mem.eql(u8, z_left[0..n_left], z_right[0..n_right]);
    }
    return jsonLabelCompareEscaped(z_left, n_left, raw_left, z_right, n_right, raw_right);
}

/// Error returns of jsonLookupStep() (JSON_LOOKUP_*).
const JSON_LOOKUP = struct {
    const ERROR: u32 = 0xffffffff;
    const NOTFOUND: u32 = 0xfffffffe;
    const NOTARRAY: u32 = 0xfffffffd;
    const TOODEEP: u32 = 0xfffffffc;
    const PATHERROR: u32 = 0xfffffffb;
};

/// JSON_LOOKUP_ISERROR().
fn jsonLookupIsError(x: u32) bool {
    return x >= JSON_LOOKUP.PATHERROR;
}

/// Port of jsonCreateEditSubstructure(): fill `ins` with the JSONB to
/// insert into `parse`: parse.a_ins itself, or, if the path continues
/// past where the search stopped (`z_tail`), the substructure the rest
/// of the path needs. For json_insert('{}', '$.a.b.c', 123), the search
/// stops at '$.a' and `ins` gets the JSONB of {"b":{"c":123}}. The caller
/// resets `ins`. Returns a JSON_LOOKUP error code, or another value.
fn jsonCreateEditSubstructure(parse: *JsonParse, ins: *JsonParse, z_tail: [*:0]const u8) u32 {
    const S = struct {
        const empty_object = [_]u8{ JSONB.ARRAY, JSONB.OBJECT };
    };
    var rc: u32 = undefined;
    ins.* = .{ .db = parse.db };
    if (z_tail[0] == 0) {
        // No substructure: just insert what is given in parse.
        ins.a_blob = @constCast(parse.a_ins);
        ins.n_blob = parse.n_ins;
        rc = 0;
    } else {
        // Construct the binary substructure.
        ins.n_blob = 1;
        ins.a_blob = @as([*]u8, @constCast(&S.empty_object)) + @intFromBool(z_tail[0] == '.');
        ins.e_edit = parse.e_edit;
        ins.n_ins = parse.n_ins;
        ins.a_ins = parse.a_ins;
        ins.i_depth = parse.i_depth +% 1;
        if (ins.i_depth >= json_max_depth) return JSON_LOOKUP.TOODEEP;
        rc = jsonLookupStep(ins, 0, z_tail, 0);
        // As in C, which decrements the depth of `parse`, not `ins`, and so
        // may wrap it below zero.
        parse.i_depth -%= 1;
        parse.oom = parse.oom or ins.oom;
    }
    return rc; // Error code only
}

/// The character before `z` (zPath[-1]).
fn charBefore(z: [*:0]const u8) u8 {
    const p: [*]const u8 = z;
    return (p - 1)[0];
}

/// Port of jsonLookupStep(): search along `z_path` from the element at
/// `i_root` (a value of an object with its label at `i_label` if that is
/// not 0). Returns the index of the element found, with i_label set to
/// the start of its label if it is an object value, or a JSON_LOOKUP
/// error code.
///
/// With e_edit one of JEDIT.*, the blob is edited at the element; then
/// the result only tells whether there was an error.
fn jsonLookupStep(parse: *JsonParse, i_root_arg: u32, z_path_arg: [*:0]const u8, i_label: u32) u32 {
    var i_root = i_root_arg;
    var z_path = z_path_arg;
    var sz: u32 = undefined;
    var n: u32 = undefined;
    var rc: u32 = undefined;

    if (z_path[0] == 0) {
        if (parse.e_edit != null and jsonBlobMakeEditable(parse, parse.n_ins)) {
            n = jsonbPayloadSize(parse, i_root, &sz);
            sz += n;
            if (parse.e_edit == JEDIT.DEL) {
                if (i_label > 0) {
                    sz += i_root - i_label;
                    i_root = i_label;
                }
                jsonBlobEdit(parse, i_root, sz, null, 0);
            } else if (parse.e_edit == JEDIT.INS) {
                // Already exists, so json_insert() is a no-op.
            } else if (parse.e_edit == JEDIT.AINS) {
                // json_array_insert()
                if (charBefore(z_path) != ']') {
                    return JSON_LOOKUP.NOTARRAY;
                } else {
                    jsonBlobEdit(parse, i_root, 0, parse.a_ins, parse.n_ins);
                }
            } else {
                // json_set() or json_replace()
                jsonBlobEdit(parse, i_root, sz, parse.a_ins, parse.n_ins);
            }
        }
        parse.i_label = i_label;
        return i_root;
    }
    if (z_path[0] == '.') {
        var raw_key = true;
        var x = parse.blob()[i_root];
        z_path += 1;
        var z_key: [*]const u8 = undefined;
        var n_key: u32 = undefined;
        var i: u32 = undefined;
        if (z_path[0] == '"') {
            z_key = z_path + 1;
            i = 1;
            while (z_path[i] != 0 and z_path[i] != '"') : (i += 1) {
                if (z_path[i] == '\\' and z_path[i + 1] != 0) i += 1;
            }
            n_key = i - 1;
            if (z_path[i] != 0) {
                i += 1;
            } else {
                return JSON_LOOKUP.PATHERROR;
            }
            raw_key = std.mem.indexOfScalar(u8, z_key[0..n_key], '\\') == null;
        } else {
            z_key = z_path;
            i = 0;
            while (z_path[i] != 0 and z_path[i] != '.' and z_path[i] != '[') i += 1;
            n_key = i;
            if (n_key == 0) return JSON_LOOKUP.PATHERROR;
        }
        if (x & 0x0f != JSONB.OBJECT) return JSON_LOOKUP.NOTFOUND;
        n = jsonbPayloadSize(parse, i_root, &sz);
        var j = i_root + n; // j is the index of a label
        const i_end = j + sz;
        while (j < i_end) {
            x = parse.blob()[j] & 0x0f;
            if (x < JSONB.TEXT or x > JSONB.TEXTRAW) return JSON_LOOKUP.ERROR;
            n = jsonbPayloadSize(parse, j, &sz);
            if (n == 0) return JSON_LOOKUP.ERROR;
            const k = j + n; // k is the index of the label text
            if (k + sz >= i_end) return JSON_LOOKUP.ERROR;
            const z_label = parse.blob() + k;
            const raw_label = x == JSONB.TEXT or x == JSONB.TEXTRAW;
            if (jsonLabelCompare(z_key, n_key, raw_key, z_label, sz, raw_label)) {
                const v = k + sz; // v is the index of the value
                if (parse.blob()[v] & 0x0f > JSONB.OBJECT) return JSON_LOOKUP.ERROR;
                n = jsonbPayloadSize(parse, v, &sz);
                if (n == 0 or v + n + sz > i_end) return JSON_LOOKUP.ERROR;
                std.debug.assert(j > 0);
                parse.i_depth +%= 1;
                if (parse.i_depth >= json_max_depth) return JSON_LOOKUP.TOODEEP;
                rc = jsonLookupStep(parse, v, z_path + i, j);
                parse.i_depth -%= 1;
                if (parse.delta != 0) jsonAfterEditSizeAdjust(parse, i_root);
                return rc;
            }
            j = k + sz;
            if (parse.blob()[j] & 0x0f > JSONB.OBJECT) return JSON_LOOKUP.ERROR;
            n = jsonbPayloadSize(parse, j, &sz);
            if (n == 0) return JSON_LOOKUP.ERROR;
            j += n + sz;
        }
        if (j > i_end) return JSON_LOOKUP.ERROR;
        if (parse.e_edit != null and parse.e_edit.?.mayInsert()) {
            // BLOB encoding of the value to be inserted.
            var v: JsonParse = undefined;
            // Header of the label to be inserted.
            var ix: JsonParse = .{ .db = parse.db };
            if (parse.e_edit == JEDIT.AINS and func.strglob("*]", z_path + i) != 0) {
                return JSON_LOOKUP.NOTARRAY;
            }
            jsonBlobAppendNode(&ix, if (raw_key) JSONB.TEXTRAW else JSONB.TEXT5, n_key, null);
            parse.oom = parse.oom or ix.oom;
            rc = jsonCreateEditSubstructure(parse, &v, z_path + i);
            if (!jsonLookupIsError(rc) and jsonBlobMakeEditable(parse, ix.n_blob + n_key + v.n_blob)) {
                std.debug.assert(!parse.oom);
                // Total bytes to insert (label+value).
                const n_ins = ix.n_blob + n_key + v.n_blob;
                jsonBlobEdit(parse, j, 0, null, n_ins);
                if (!parse.oom) {
                    const a = parse.blob();
                    @memcpy(a[j..][0..ix.n_blob], ix.blob()[0..ix.n_blob]);
                    var k = j + ix.n_blob;
                    @memcpy(a[k..][0..n_key], z_key[0..n_key]);
                    k += n_key;
                    if (v.n_blob > 0) @memcpy(a[k..][0..v.n_blob], v.blob()[0..v.n_blob]);
                    if (parse.delta != 0) jsonAfterEditSizeAdjust(parse, i_root);
                }
            }
            jsonParseReset(&v);
            jsonParseReset(&ix);
            return rc;
        }
    } else if (z_path[0] == '[') {
        var kk: u64 = 0;
        const x = parse.blob()[i_root] & 0x0f;
        if (x != JSONB.ARRAY) return JSON_LOOKUP.NOTFOUND;
        n = jsonbPayloadSize(parse, i_root, &sz);
        var i: u32 = 1;
        while (ctype.isDigit(z_path[i])) {
            // Let kk be bigger than any JSON array so that the result is
            // NOTFOUND instead of PATHERROR, without overflowing kk.
            if (kk < 0xffffffff) kk = kk * 10 + z_path[i] - '0';
            i += 1;
        }
        if (i < 2 or z_path[i] != ']') {
            if (z_path[1] == '#') {
                kk = jsonbArrayCount(parse, i_root);
                i = 2;
                if (z_path[2] == '-' and ctype.isDigit(z_path[3])) {
                    var nn: u64 = 0;
                    i = 3;
                    while (true) {
                        if (nn < 0xffffffff) nn = nn * 10 + z_path[i] - '0';
                        i += 1;
                        if (!ctype.isDigit(z_path[i])) break;
                    }
                    if (nn > kk) return JSON_LOOKUP.NOTFOUND;
                    kk -= nn;
                }
                if (z_path[i] != ']') return JSON_LOOKUP.PATHERROR;
            } else {
                return JSON_LOOKUP.PATHERROR;
            }
        }
        var j = i_root + n;
        const i_end = j + sz;
        while (j < i_end) {
            if (kk == 0) {
                parse.i_depth +%= 1;
                if (parse.i_depth >= json_max_depth) return JSON_LOOKUP.TOODEEP;
                rc = jsonLookupStep(parse, j, z_path + i + 1, 0);
                parse.i_depth -%= 1;
                if (parse.delta != 0) jsonAfterEditSizeAdjust(parse, i_root);
                return rc;
            }
            kk -= 1;
            n = jsonbPayloadSize(parse, j, &sz);
            if (n == 0) return JSON_LOOKUP.ERROR;
            j += n + sz;
        }
        if (j > i_end) return JSON_LOOKUP.ERROR;
        if (kk > 0) return JSON_LOOKUP.NOTFOUND;
        if (parse.e_edit != null and parse.e_edit.?.mayInsert()) {
            var v: JsonParse = undefined;
            rc = jsonCreateEditSubstructure(parse, &v, z_path + i + 1);
            if (!jsonLookupIsError(rc) and jsonBlobMakeEditable(parse, v.n_blob)) {
                std.debug.assert(!parse.oom);
                jsonBlobEdit(parse, j, 0, v.a_blob, v.n_blob);
            }
            jsonParseReset(&v);
            if (parse.delta != 0) jsonAfterEditSizeAdjust(parse, i_root);
            return rc;
        }
    } else {
        return JSON_LOOKUP.PATHERROR;
    }
    return JSON_LOOKUP.NOTFOUND;
}

/// Port of jsonReturnTextJsonFromBlob(): the JSON text of the JSONB in
/// `a_blob` as the result.
fn jsonReturnTextJsonFromBlob(ctx: *Context, a_blob: [*]const u8, n_blob: u32) void {
    var x: JsonParse = .{ .a_blob = @constCast(a_blob), .n_blob = n_blob };
    var s: JsonString = undefined;
    jsonStringInit(&s, ctx);
    _ = jsonTranslateBlobToText(&x, 0, &s);
    jsonReturnString(&s, null, null);
}

/// Port of jsonReturnFromBlob(): the value of the node at a_blob[i] as
/// the result: primitives as SQL values, arrays and objects as JSON text
/// or JSONB as `e_mode` says (0: JSONB if the function has JSON.BLOB,
/// else text; 1: text; 2: JSONB).
fn jsonReturnFromBlob(parse: *JsonParse, i: u32, ctx: *Context, e_mode_arg: u8) void {
    var e_mode = e_mode_arg;
    const db = api.contextDbHandle(ctx);
    std.debug.assert(e_mode <= 2);
    var sz: u32 = undefined;
    var n = jsonbPayloadSize(parse, i, &sz);
    if (n == 0) {
        api.resultError(ctx, "malformed JSON");
        return;
    }
    const a = parse.blob();
    malformed: {
        to_double: {
            switch (a[i] & 0x0f) {
                JSONB.NULL => {
                    if (sz != 0) break :malformed;
                    api.resultNull(ctx);
                },
                JSONB.TRUE => {
                    if (sz != 0) break :malformed;
                    api.resultInt(ctx, 1);
                },
                JSONB.FALSE => {
                    if (sz != 0) break :malformed;
                    api.resultInt(ctx, 0);
                },
                JSONB.INT5, JSONB.INT => {
                    var i_res: i64 = 0;
                    var b_neg = false;
                    if (sz == 0) break :malformed;
                    const x = a[i + n];
                    if (x == '-') {
                        if (sz < 2) break :malformed;
                        n += 1;
                        sz -= 1;
                        b_neg = true;
                    }
                    const z = db.gpa.dupeSentinel(u8, a[i + n ..][0..sz], 0) catch {
                        api.resultErrorNomem(ctx);
                        return;
                    };
                    const rc = util.decOrHexToI64(z, &i_res);
                    db.gpa.free(z);
                    if (rc == .ok) {
                        if (i_res < 0) {
                            // A hexadecimal literal of 16 significant digits
                            // with the high bit set is a negative integer in
                            // SQLite but positive in JSON. It is too large for
                            // an SQLite integer, so it becomes a double.
                            const r: f64 = @floatFromInt(@as(u64, @bitCast(i_res)));
                            api.resultDouble(ctx, if (b_neg) -r else r);
                        } else {
                            api.resultInt64(ctx, if (b_neg) -i_res else i_res);
                        }
                    } else if (rc == .min_magnitude and b_neg) {
                        api.resultInt64(ctx, std.math.minInt(i64));
                    } else if (rc == .excess_text) {
                        break :malformed;
                    } else {
                        if (b_neg) {
                            n -= 1;
                            sz += 1;
                        }
                        break :to_double;
                    }
                },
                JSONB.FLOAT5, JSONB.FLOAT => {
                    if (sz == 0) break :malformed;
                    break :to_double;
                },
                JSONB.TEXTRAW, JSONB.TEXT => api.resultText(ctx, a[i + n ..][0..sz], .transient),
                JSONB.TEXT5, JSONB.TEXTJ => {
                    // Translate the JSON string into raw text.
                    const n_out = sz;
                    const z = a + i + n;
                    const z_out = db.gpa.alloc(u8, @as(usize, n_out) + 1) catch {
                        api.resultErrorNomem(ctx);
                        return;
                    };
                    var i_out: usize = 0;
                    var i_in: u32 = 0;
                    while (i_in < sz) : (i_in += 1) {
                        const c = z[i_in];
                        if (c == '\\') {
                            var v: u32 = undefined;
                            const sz_escape = jsonUnescapeOneChar(z + i_in, sz - i_in, &v);
                            if (v <= 0x7f) {
                                z_out[i_out] = @truncate(v);
                                i_out += 1;
                            } else if (v <= 0x7ff) {
                                std.debug.assert(sz_escape >= 2);
                                z_out[i_out] = @truncate(0xc0 | (v >> 6));
                                z_out[i_out + 1] = @truncate(0x80 | (v & 0x3f));
                                i_out += 2;
                            } else if (v < 0x10000) {
                                std.debug.assert(sz_escape >= 3);
                                z_out[i_out] = @truncate(0xe0 | (v >> 12));
                                z_out[i_out + 1] = @truncate(0x80 | ((v >> 6) & 0x3f));
                                z_out[i_out + 2] = @truncate(0x80 | (v & 0x3f));
                                i_out += 3;
                            } else if (v == json_invalid_char) {
                                // Silently ignore illegal unicode.
                            } else {
                                std.debug.assert(sz_escape >= 4);
                                z_out[i_out] = @truncate(0xf0 | (v >> 18));
                                z_out[i_out + 1] = @truncate(0x80 | ((v >> 12) & 0x3f));
                                z_out[i_out + 2] = @truncate(0x80 | ((v >> 6) & 0x3f));
                                z_out[i_out + 3] = @truncate(0x80 | (v & 0x3f));
                                i_out += 4;
                            }
                            i_in += sz_escape - 1;
                        } else {
                            z_out[i_out] = c;
                            i_out += 1;
                        }
                    }
                    std.debug.assert(i_out <= n_out);
                    func.resultOwnedText(ctx, z_out, i_out);
                },
                JSONB.ARRAY, JSONB.OBJECT => {
                    if (e_mode == 0) {
                        e_mode = if (userFlags(ctx) & JSON.BLOB != 0) 2 else 1;
                    }
                    if (e_mode == 2) {
                        api.resultBlob(ctx, a[i..][0 .. sz + n], .transient);
                    } else {
                        jsonReturnTextJsonFromBlob(ctx, a + i, sz + n);
                    }
                },
                else => break :malformed,
            }
            return;
        }
        // to_double:
        const z = db.gpa.dupeSentinel(u8, a[i + n ..][0..sz], 0) catch {
            api.resultErrorNomem(ctx);
            return;
        };
        var r: f64 = undefined;
        const rc = numeric.atoF(z, &r);
        db.gpa.free(z);
        if (rc <= 0) break :malformed;
        api.resultDouble(ctx, r);
        return;
    }
    // returnfromblob_malformed:
    api.resultError(ctx, "malformed JSON");
}

/// Port of jsonFunctionArgToBlob(): the SQL value or JSON in `arg` as
/// JSONB in `parse` (uninitialized on entry). a_blob may be allocated
/// (n_blob_alloc > 0; the caller frees it), static, or the blob of
/// `arg`. Fails (C: non-zero), maybe with an error set, if `arg` is a
/// BLOB that is not JSONB, or on OOM.
fn jsonFunctionArgToBlob(ctx: *Context, arg: *Mem, parse: *JsonParse) ToBlobError!void {
    // External (n_blob_alloc == 0), so never written.
    const a_null = [_]u8{JSONB.NULL};
    const e_type = api.valueType(arg);
    parse.* = .{ .db = api.contextDbHandle(ctx) };
    switch (e_type) {
        SQLITE_BLOB => {
            if (!jsonArgIsJsonb(arg, parse)) {
                api.resultError(ctx, "JSON cannot hold BLOB values");
                return error.Malformed;
            }
        },
        SQLITE_TEXT => {
            const z_json = api.valueText(arg) orelse return error.OutOfMemory;
            const n_json = api.valueBytes(arg);
            if (api.valueSubtype(arg) == json_subtype) {
                parse.z_json = z_json.ptr;
                parse.n_json = @intCast(n_json);
                jsonConvertTextToBlob(parse, ctx) catch |err| {
                    api.resultError(ctx, "malformed JSON");
                    if (parse.n_blob_alloc > 0) parse.gpa().free(parse.blob()[0..parse.n_blob_alloc]);
                    parse.* = .{};
                    return err;
                };
            } else {
                jsonBlobAppendNode(parse, JSONB.TEXTRAW, n_json, z_json.ptr);
            }
        },
        SQLITE_FLOAT => {
            if (numeric.isNaN(api.valueDouble(arg))) {
                jsonBlobAppendNode(parse, JSONB.NULL, 0, null);
            } else {
                const n = api.valueBytes(arg);
                const z = api.valueText(arg) orelse return error.OutOfMemory;
                if (z[0] == 'I') {
                    jsonBlobAppendNode(parse, JSONB.FLOAT, 5, "9e999");
                } else if (z[0] == '-' and z[1] == 'I') {
                    jsonBlobAppendNode(parse, JSONB.FLOAT, 6, "-9e999");
                } else {
                    jsonBlobAppendNode(parse, JSONB.FLOAT, n, z.ptr);
                }
            }
        },
        SQLITE_INTEGER => {
            const n = api.valueBytes(arg);
            const z = api.valueText(arg) orelse return error.OutOfMemory;
            jsonBlobAppendNode(parse, JSONB.INT, n, z.ptr);
        },
        else => {
            parse.a_blob = @constCast(&a_null);
            parse.n_blob = 1;
            return;
        },
    }
    if (parse.oom) {
        api.resultErrorNomem(ctx);
        return error.OutOfMemory;
    }
}

/// The message of jsonBadPathError() (its ctx==0 case), allocated with
/// `gpa`; null on OOM.
fn jsonBadPathMsg(gpa: Allocator, z_path: ?[*:0]const u8, rc: u32) ?[:0]u8 {
    const path: printf.Arg = .{ .str = if (z_path) |p| std.mem.span(p) else null };
    const r = if (rc == JSON_LOOKUP.NOTARRAY)
        printf.mprintf(gpa, "not an array element: %Q", &.{path})
    else if (rc == JSON_LOOKUP.ERROR)
        printf.mprintf(gpa, "malformed JSON", &.{})
    else if (rc == JSON_LOOKUP.TOODEEP)
        printf.mprintf(gpa, "JSON path too deep", &.{})
    else
        printf.mprintf(gpa, "bad JSON path: %Q", &.{path});
    return r catch null;
}

/// Port of jsonBadPathError(): the error for a path problem: "not an
/// array element" (NOTARRAY), "JSON path too deep" (TOODEEP), "malformed
/// JSON" (ERROR) or "bad JSON path". (Without a context, C returns the
/// message: that is jsonBadPathMsg().)
fn jsonBadPathError(ctx: *Context, z_path: ?[*:0]const u8, rc: u32) void {
    const gpa = api.contextDbHandle(ctx).gpa;
    const msg = jsonBadPathMsg(gpa, z_path, rc) orelse {
        api.resultErrorNomem(ctx);
        return;
    };
    defer gpa.free(msg);
    api.resultError(ctx, msg);
}

/// Port of jsonInsertIntoBlob(): argv[0] is the JSON; the other arguments
/// are pairs of a path and the content to insert or set there, as
/// `e_edit` (JEDIT.INS, REPL, SET or AINS) says. The result is the
/// edited JSON.
fn jsonInsertIntoBlob(ctx: *Context, argv: []*Mem, e_edit: JEDIT) void {
    const argc = argv.len;
    var rc: u32 = 0;
    var z_path: ?[*:0]const u8 = null;
    std.debug.assert(argc & 1 == 1);
    const flgs: u32 = if (argc == 1) 0 else JSON_EDITABLE;
    const p = jsonParseFuncArg(ctx, argv[0], flgs) orelse return;
    patherror: {
        var i: usize = 1;
        while (i < argc - 1) : (i += 2) {
            if (api.valueType(argv[i]) == SQLITE_NULL) continue;
            const zp = api.valueText(argv[i]) orelse {
                api.resultErrorNomem(ctx);
                jsonParseFree(p);
                return;
            };
            z_path = zp.ptr;
            if (zp[0] != '$') break :patherror;
            var ax: JsonParse = undefined;
            jsonFunctionArgToBlob(ctx, argv[i + 1], &ax) catch {
                jsonParseReset(&ax);
                jsonParseFree(p);
                return;
            };
            if (zp[1] == 0) {
                if (e_edit == JEDIT.REPL or e_edit == JEDIT.SET) {
                    jsonBlobEdit(p, 0, p.n_blob, ax.a_blob, ax.n_blob);
                }
                rc = 0;
            } else {
                p.e_edit = e_edit;
                p.n_ins = ax.n_blob;
                p.a_ins = ax.a_blob;
                p.delta = 0;
                p.i_depth = 0;
                rc = jsonLookupStep(p, 0, zp.ptr + 1, 0);
            }
            jsonParseReset(&ax);
            if (rc == JSON_LOOKUP.NOTFOUND) continue;
            if (jsonLookupIsError(rc)) break :patherror;
        }
        jsonReturnParse(ctx, p);
        jsonParseFree(p);
        return;
    }
    // jsonInsertIntoBlob_patherror:
    jsonParseFree(p);
    jsonBadPathError(ctx, z_path, rc);
}

/// Port of jsonArgIsJsonb(): if `arg` is a blob that seems to be JSONB,
/// point `p` at it and return true.
///
/// Blobs of at most 7 bytes of payload get a full validity check, as
/// they might be text JSON wrongly cast to a BLOB (tag-20240123-a); text
/// JSON cannot pass the superficial size check of larger ones.
fn jsonArgIsJsonb(arg: *Mem, p: *JsonParse) bool {
    var sz: u32 = 0;
    if (api.valueType(arg) != SQLITE_BLOB) return false;
    const b = api.valueBlob(arg);
    p.a_blob = if (b) |x| @constCast(x.ptr) else null;
    p.n_blob = @intCast(api.valueBytes(arg));
    if (p.n_blob > 0 and p.a_blob != null) {
        const c = p.blob()[0];
        if (c & 0x0f <= JSONB.OBJECT) {
            const n = jsonbPayloadSize(p, 0, &sz);
            if (n > 0 and sz + n == p.n_blob and
                (c & 0x0f > JSONB.FALSE or sz == 0) and
                (sz > 7 or (c != 0x7b and c != 0x5b and !ctype.isDigit(c)) or
                    jsonbValidityCheck(p, 0, p.n_blob, 1) == 0))
            {
                return true;
            }
        }
    }
    p.a_blob = null;
    p.n_blob = 0;
    return false;
}

/// Port of jsonParseFuncArg(): a new JsonParse with the JSONB of the
/// function argument `arg`, owned by the caller (free it with
/// jsonParseFree()). Null, with an error set, on errors, and null with
/// no error for an SQL NULL (so that NULL arguments give NULL results).
fn jsonParseFuncArg(ctx: *Context, arg: *Mem, flgs: u32) ?*JsonParse {
    var p: ?*JsonParse = null;
    var from_cache: ?*JsonParse = null;
    const e_type = api.valueType(arg);
    if (e_type == SQLITE_NULL) return null;
    if (flgs & JSON_NOCACHE == 0) from_cache = jsonCacheSearch(ctx, arg);
    if (from_cache) |fc| {
        fc.n_jp_ref += 1;
        if (flgs & JSON_EDITABLE == 0) return fc;
    }
    const db = api.contextDbHandle(ctx);
    oom: {
        rebuild_from_cache: while (true) {
            const px = db.gpa.create(JsonParse) catch break :oom;
            p = px;
            px.* = .{ .db = db, .n_jp_ref = 1 };
            if (from_cache) |fc| {
                const n_blob = fc.n_blob;
                const a = db.gpa.alloc(u8, n_blob) catch break :oom;
                px.a_blob = a.ptr;
                @memcpy(a, fc.blob()[0..n_blob]);
                px.n_blob = n_blob;
                px.n_blob_alloc = n_blob;
                px.has_nonstd = fc.has_nonstd;
                jsonParseFree(fc);
                return px;
            }
            if (e_type == SQLITE_BLOB) {
                if (jsonArgIsJsonb(arg, px)) {
                    if (flgs & JSON_EDITABLE != 0 and !jsonBlobMakeEditable(px, 0)) break :oom;
                    return px;
                }
                // A blob that is not JSONB is read as text JSON
                // (tag-20240123-a), against the documentation but as
                // applications have come to depend on it (reading JSON
                // with readfile() in the CLI, for example).
            }
            const z = api.valueText(arg);
            px.z_json = if (z) |s| s.ptr else null;
            px.n_json = @intCast(api.valueBytes(arg));
            if (db.malloc_failed) break :oom;
            if (px.n_json == 0) {
                // json_pfa_malformed:
                if (flgs & JSON_KEEPERROR != 0) {
                    px.n_err = 1;
                    return px;
                }
                jsonParseFree(px);
                api.resultError(ctx, "malformed JSON");
                return null;
            }
            std.debug.assert(px.z_json != null);
            if (jsonConvertTextToBlob(px, if (flgs & JSON_KEEPERROR != 0) null else ctx)) |_| {} else |_| {
                if (flgs & JSON_KEEPERROR != 0) {
                    px.n_err = 1;
                    return px;
                }
                jsonParseFree(px);
                return null;
            }
            const is_rcstr = valueIsOfClass(arg, int.destructor(rcstrUnref));
            if (!is_rcstr) {
                const n_json: usize = @intCast(px.n_json);
                const z_new = rcstrNew(n_json) orelse break :oom;
                @memcpy(z_new[0..n_json], px.z_json.?[0..n_json]);
                z_new[n_json] = 0;
                px.z_json = z_new;
            } else {
                _ = rcstrRef(@constCast(px.z_json.?));
            }
            px.b_json_is_rcstr = true;
            const rc = jsonCacheInsert(ctx, px);
            if (rc == RC.NOMEM) break :oom;
            if (flgs & JSON_EDITABLE != 0) {
                from_cache = px;
                p = null;
                continue :rebuild_from_cache;
            }
            return px;
        }
    }
    // json_pfa_oom:
    jsonParseFree(from_cache);
    jsonParseFree(p);
    api.resultErrorNomem(ctx);
    return null;
}

/// Port of jsonReturnParse(): the result is the JSONB blob of `p` or its
/// JSON text, as JSON.BLOB of the function says.
fn jsonReturnParse(ctx: *Context, p: *JsonParse) void {
    if (p.oom) {
        api.resultErrorNomem(ctx);
        return;
    }
    const flgs = userFlags(ctx);
    if (flgs & JSON.BLOB != 0) {
        if (p.n_blob_alloc > 0 and !p.b_read_only) {
            func.resultOwnedBlob(ctx, p.blob()[0..p.n_blob_alloc], p.n_blob);
            p.n_blob_alloc = 0;
        } else {
            api.resultBlob(ctx, p.blob()[0..p.n_blob], .transient);
        }
    } else {
        var s: JsonString = undefined;
        jsonStringInit(&s, ctx);
        p.delta = 0;
        _ = jsonTranslateBlobToText(p, 0, &s);
        jsonReturnString(&s, p, ctx);
        api.resultSubtype(ctx, json_subtype);
    }
}

// =============================================== scalar SQL functions

/// Port of jsonQuoteFunc(): json_quote(VALUE), the JSON form of an SQL
/// value: strings in double quotes, NULL as null.
fn jsonQuoteFunc(ctx: *Context, argv: []*Mem) void {
    var jx: JsonString = undefined;
    jsonStringInit(&jx, ctx);
    jsonAppendSqlValue(&jx, argv[0]);
    jsonReturnString(&jx, null, null);
    api.resultSubtype(ctx, json_subtype);
}

/// Port of jsonArrayFunc(): json_array(VALUE,...), a JSON array of the
/// arguments; an error for a BLOB argument.
fn jsonArrayFunc(ctx: *Context, argv: []*Mem) void {
    var jx: JsonString = undefined;
    jsonStringInit(&jx, ctx);
    jsonAppendChar(&jx, '[');
    for (argv) |arg| {
        jsonAppendSeparator(&jx);
        jsonAppendSqlValue(&jx, arg);
    }
    jsonAppendChar(&jx, ']');
    jsonReturnString(&jx, null, null);
    api.resultSubtype(ctx, json_subtype);
}

/// Port of jsonArrayLengthFunc(): json_array_length(JSON[, PATH]), the
/// number of elements of the (top-level) array; 0 if it is not an array.
fn jsonArrayLengthFunc(ctx: *Context, argv: []*Mem) void {
    var cnt: i64 = 0;
    var i: u32 = undefined;
    var e_err = false;
    const p = jsonParseFuncArg(ctx, argv[0], 0) orelse return;
    if (argv.len == 2) {
        const z_path = api.valueText(argv[1]) orelse {
            jsonParseFree(p);
            return;
        };
        i = jsonLookupStep(p, 0, if (z_path[0] == '$') z_path.ptr + 1 else "@", 0);
        if (jsonLookupIsError(i)) {
            if (i == JSON_LOOKUP.NOTFOUND) {
                // no-op
            } else {
                jsonBadPathError(ctx, z_path.ptr, i);
            }
            e_err = true;
            i = 0;
        }
    } else {
        i = 0;
    }
    if (p.blob()[i] & 0x0f == JSONB.ARRAY) cnt = jsonbArrayCount(p, i);
    if (!e_err) api.resultInt64(ctx, cnt);
    jsonParseFree(p);
}

/// Port of jsonAllAlphanum(): `z` is all alphanumerics and underscores.
fn jsonAllAlphanum(z: []const u8) bool {
    for (z) |c| {
        if (!ctype.isAlnum(c) and c != '_') return false;
    }
    return true;
}

/// Port of jsonExtractFunc(): json_extract(JSON, PATH, ...), "->"(JSON,
/// PATH) and "->>"(JSON, PATH): the element at PATH, NULL if not found.
///
/// With JSON.JSON or more than one PATH the result is JSON; with
/// JSON.SQL it is an SQL value; otherwise JSON for arrays and objects and
/// SQL for other values. Several PATHs give a JSON array of the results.
/// JSON.ABPATH (-> and ->>) allows abbreviated paths, as PostgreSQL does.
fn jsonExtractFunc(ctx: *Context, argv: []*Mem) void {
    const argc = argv.len;
    var jx: JsonString = undefined;
    if (argc < 2) return;
    const p = jsonParseFuncArg(ctx, argv[0], 0) orelse return;
    const flags = userFlags(ctx);
    jsonStringInit(&jx, ctx);
    done: {
        if (argc > 2) jsonAppendChar(&jx, '[');
        for (1..argc) |i| {
            // With a single PATH argument.
            const zp = api.valueText(argv[i]) orelse break :done;
            const z_path = zp.ptr;
            const n_path = std.mem.len(z_path) & 0x3fffffff;
            var j: u32 = undefined;
            if (z_path[0] == '$') {
                j = jsonLookupStep(p, 0, z_path + 1, 0);
            } else if (flags & JSON.ABPATH != 0) {
                // The -> and ->> operators accept abbreviated PATH arguments,
                // mostly for PostgreSQL compatibility:
                //
                //     NUMBER   ==>  $[NUMBER]     // PG compatible
                //     LABEL    ==>  $.LABEL       // PG compatible
                //     [NUMBER] ==>  $[NUMBER]     // Not PG. For convenience
                //
                // A negative NUMBER counts from the right, as in PG:
                //
                //     NUMBER   ==>  $[#NUMBER]    // PG compatible
                jsonStringInit(&jx, ctx);
                if (api.valueType(argv[i]) == SQLITE_INTEGER) {
                    jsonAppendRawNZ(&jx, "[");
                    if (z_path[0] == '-') jsonAppendRawNZ(&jx, "#");
                    jsonAppendRaw(&jx, z_path[0..n_path]);
                    jsonAppendRawNZ(&jx, "]\x00");
                } else if (jsonAllAlphanum(z_path[0..n_path])) {
                    jsonAppendRawNZ(&jx, ".");
                    jsonAppendRaw(&jx, z_path[0..n_path]);
                } else if (z_path[0] == '[' and n_path >= 3 and z_path[n_path - 1] == ']') {
                    jsonAppendRaw(&jx, z_path[0..n_path]);
                } else {
                    jsonAppendRawNZ(&jx, ".\"");
                    jsonAppendRaw(&jx, z_path[0..n_path]);
                    jsonAppendRawNZ(&jx, "\"");
                }
                _ = jsonStringTerminate(&jx);
                j = jsonLookupStep(p, 0, @ptrCast(jx.buf()), 0);
                jsonStringReset(&jx);
            } else {
                jsonBadPathError(ctx, z_path, 0);
                break :done;
            }
            if (j < p.n_blob) {
                if (argc == 2) {
                    if (flags & JSON.JSON != 0) {
                        jsonStringInit(&jx, ctx);
                        _ = jsonTranslateBlobToText(p, j, &jx);
                        jsonReturnString(&jx, null, null);
                        jsonStringReset(&jx);
                        std.debug.assert(flags & JSON.BLOB == 0);
                        api.resultSubtype(ctx, json_subtype);
                    } else {
                        jsonReturnFromBlob(p, j, ctx, 0);
                        if (flags & (JSON.SQL | JSON.BLOB) == 0 and p.blob()[j] & 0x0f >= JSONB.ARRAY) {
                            api.resultSubtype(ctx, json_subtype);
                        }
                    }
                } else {
                    jsonAppendSeparator(&jx);
                    _ = jsonTranslateBlobToText(p, j, &jx);
                }
            } else if (j == JSON_LOOKUP.NOTFOUND) {
                if (argc == 2) {
                    break :done; // Return NULL if not found
                } else {
                    jsonAppendSeparator(&jx);
                    jsonAppendRawNZ(&jx, "null");
                }
            } else {
                jsonBadPathError(ctx, z_path, j);
                break :done;
            }
        }
        if (argc > 2) {
            jsonAppendChar(&jx, ']');
            jsonReturnString(&jx, null, null);
            if (flags & JSON.BLOB == 0) api.resultSubtype(ctx, json_subtype);
        }
    }
    // json_extract_error:
    jsonStringReset(&jx);
    jsonParseFree(p);
}

/// Results of jsonMergePatch() (JSON_MERGE_*).
const JSON_MERGE = struct {
    const OK = 0;
    /// Malformed TARGET blob.
    const BADTARGET = 1;
    /// Malformed PATCH blob.
    const BADPATCH = 2;
    const OOM = 3;
    /// Nested too deep.
    const TOODEEP = 4;
};

/// Port of jsonMergePatch(): RFC-7396 MergePatch of two JSONB blobs. The
/// target (at `i_target` of `target`) is updated in place; the patch (at
/// `i_patch` of `patch`) is read-only. The RFC algorithm, restructured as
/// implemented (the line numbers are referenced below):
///
///     01   define MergePatch(Target, Patch):
///     02      if Patch is not an Object:
///     03         return Patch
///     04      else: // if Patch is an Object
///     05         if Target is not an Object:
///     06            Target = {}
///     07      for each Name/Value pair in Patch:
///     08         if Name exists in Target:
///     09            if Value is null:
///     10               remove the Name/Value pair from Target
///     11            else
///     12               Target[name] = MergePatch(Target[Name], Value)
///     13         else if Value is not NULL:
///     14            if Value is not an Object:
///     15               Target[name] = Value
///     16            else:
///     17               Target[name] = MergePatch('{}',value)
///     18      return Target
fn jsonMergePatch(target: *JsonParse, i_target: u32, patch: *const JsonParse, i_patch: u32, i_depth: u32) i32 {
    var n: u32 = undefined;
    var sz: u32 = 0;
    var i_t_label: u32 = 0;
    var n_t_label: u32 = 0;
    var sz_t_label: u32 = 0;
    var i_t_value: u32 = 0;
    var n_t_value: u32 = 0;
    var sz_t_value: u32 = 0;

    std.debug.assert(i_target < target.n_blob);
    std.debug.assert(i_patch < patch.n_blob);
    var x = patch.blob()[i_patch] & 0x0f;
    if (x != JSONB.OBJECT) { // Algorithm line 02
        n = jsonbPayloadSize(patch, i_patch, &sz);
        const sz_patch = n + sz;
        sz = 0;
        n = jsonbPayloadSize(target, i_target, &sz);
        const sz_target = n + sz;
        jsonBlobEdit(target, i_target, sz_target, patch.blob() + i_patch, sz_patch);
        return if (target.oom) JSON_MERGE.OOM else JSON_MERGE.OK; // Line 03
    }
    x = target.blob()[i_target] & 0x0f;
    if (x != JSONB.OBJECT) { // Algorithm line 05
        n = jsonbPayloadSize(target, i_target, &sz);
        jsonBlobEdit(target, i_target + n, sz, null, 0);
        x = target.blob()[i_target];
        target.blob()[i_target] = (x & 0xf0) | JSONB.OBJECT;
    }
    n = jsonbPayloadSize(patch, i_patch, &sz);
    if (n == 0) return JSON_MERGE.BADPATCH;
    var i_p_cursor = i_patch + n;
    const i_p_end = i_p_cursor + sz;
    n = jsonbPayloadSize(target, i_target, &sz);
    if (n == 0) return JSON_MERGE.BADTARGET;
    const i_t_start = i_target + n;
    const i_t_end_be = i_t_start + sz;

    while (i_p_cursor < i_p_end) { // Algorithm line 07
        const i_p_label = i_p_cursor;
        const e_p_label = patch.blob()[i_p_cursor] & 0x0f;
        if (e_p_label < JSONB.TEXT or e_p_label > JSONB.TEXTRAW) return JSON_MERGE.BADPATCH;
        var sz_p_label: u32 = undefined;
        const n_p_label = jsonbPayloadSize(patch, i_p_cursor, &sz_p_label);
        if (n_p_label == 0) return JSON_MERGE.BADPATCH;
        const i_p_value = i_p_cursor + n_p_label + sz_p_label;
        if (i_p_value >= i_p_end) return JSON_MERGE.BADPATCH;
        var sz_p_value: u32 = undefined;
        const n_p_value = jsonbPayloadSize(patch, i_p_value, &sz_p_value);
        if (n_p_value == 0) return JSON_MERGE.BADPATCH;
        i_p_cursor = i_p_value + n_p_value + sz_p_value;
        if (i_p_cursor > i_p_end) return JSON_MERGE.BADPATCH;

        var i_t_cursor = i_t_start;
        const i_t_end: u32 = i_t_end_be +% @as(u32, @bitCast(target.delta));
        while (i_t_cursor < i_t_end) {
            i_t_label = i_t_cursor;
            const e_t_label = target.blob()[i_t_cursor] & 0x0f;
            if (e_t_label < JSONB.TEXT or e_t_label > JSONB.TEXTRAW) return JSON_MERGE.BADTARGET;
            n_t_label = jsonbPayloadSize(target, i_t_cursor, &sz_t_label);
            if (n_t_label == 0) return JSON_MERGE.BADTARGET;
            i_t_value = i_t_label + n_t_label + sz_t_label;
            if (i_t_value >= i_t_end) return JSON_MERGE.BADTARGET;
            n_t_value = jsonbPayloadSize(target, i_t_value, &sz_t_value);
            if (n_t_value == 0) return JSON_MERGE.BADTARGET;
            if (i_t_value + n_t_value + sz_t_value > i_t_end) return JSON_MERGE.BADTARGET;
            const is_equal = jsonLabelCompare(
                patch.blob() + i_p_label + n_p_label,
                sz_p_label,
                e_p_label == JSONB.TEXT or e_p_label == JSONB.TEXTRAW,
                target.blob() + i_t_label + n_t_label,
                sz_t_label,
                e_t_label == JSONB.TEXT or e_t_label == JSONB.TEXTRAW,
            );
            if (is_equal) break;
            i_t_cursor = i_t_value + n_t_value + sz_t_value;
        }
        x = patch.blob()[i_p_value] & 0x0f;
        if (i_t_cursor < i_t_end) {
            // A match was found. Algorithm line 08.
            if (x == 0) {
                // Patch value is NULL. Algorithm line 09.
                jsonBlobEdit(target, i_t_label, n_t_label + sz_t_label + n_t_value + sz_t_value, null, 0);
                // No OOM on a delete-only edit.
                if (target.oom) return JSON_MERGE.OOM;
            } else {
                // Algorithm line 12.
                const saved_delta = target.delta;
                target.delta = 0;
                if (i_depth >= json_max_depth) return JSON_MERGE.TOODEEP;
                const rc = jsonMergePatch(target, i_t_value, patch, i_p_value, i_depth + 1);
                if (rc != 0) return rc;
                target.delta += saved_delta;
            }
        } else if (x > 0) { // Algorithm line 13
            // No match and the patch value is not NULL.
            const sz_new = sz_p_label + n_p_label;
            if (patch.blob()[i_p_value] & 0x0f != JSONB.OBJECT) { // Line 14
                jsonBlobEdit(target, i_t_end, 0, null, sz_p_value + n_p_value + sz_new);
                if (target.oom) return JSON_MERGE.OOM;
                @memmove((target.blob() + i_t_end)[0..sz_new], (patch.blob() + i_p_label)[0..sz_new]);
                @memmove((target.blob() + i_t_end + sz_new)[0 .. sz_p_value + n_p_value], (patch.blob() + i_p_value)[0 .. sz_p_value + n_p_value]);
            } else {
                jsonBlobEdit(target, i_t_end, 0, null, sz_new + 1);
                if (target.oom) return JSON_MERGE.OOM;
                @memmove((target.blob() + i_t_end)[0..sz_new], (patch.blob() + i_p_label)[0..sz_new]);
                target.blob()[i_t_end + sz_new] = 0x00;
                const saved_delta = target.delta;
                target.delta = 0;
                if (i_depth >= json_max_depth) return JSON_MERGE.TOODEEP;
                const rc = jsonMergePatch(target, i_t_end + sz_new, patch, i_p_value, i_depth + 1);
                if (rc != 0) return rc;
                target.delta += saved_delta;
            }
        }
    }
    if (target.delta != 0) jsonAfterEditSizeAdjust(target, i_target);
    return if (target.oom) JSON_MERGE.OOM else JSON_MERGE.OK;
}

/// Port of jsonPatchFunc(): json_patch(JSON1, JSON2), the RFC 7396
/// MergePatch of the two arguments.
fn jsonPatchFunc(ctx: *Context, argv: []*Mem) void {
    std.debug.assert(argv.len == 2);
    const target = jsonParseFuncArg(ctx, argv[0], JSON_EDITABLE) orelse return;
    if (jsonParseFuncArg(ctx, argv[1], 0)) |patch| {
        const rc = jsonMergePatch(target, 0, patch, 0, 0);
        if (rc == JSON_MERGE.OK) {
            jsonReturnParse(ctx, target);
        } else if (rc == JSON_MERGE.OOM) {
            api.resultErrorNomem(ctx);
        } else if (rc == JSON_MERGE.TOODEEP) {
            api.resultError(ctx, "JSON nested too deep");
        } else {
            api.resultError(ctx, "malformed JSON");
        }
        jsonParseFree(patch);
    }
    jsonParseFree(target);
}

/// Port of jsonObjectFunc(): json_object(NAME,VALUE,...), a JSON object
/// of the name/value pairs. Names must be text, and values not BLOBs.
fn jsonObjectFunc(ctx: *Context, argv: []*Mem) void {
    var jx: JsonString = undefined;
    if (argv.len & 1 != 0) {
        api.resultError(ctx, "json_object() requires an even number of arguments");
        return;
    }
    jsonStringInit(&jx, ctx);
    jsonAppendChar(&jx, '{');
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (api.valueType(argv[i]) != SQLITE_TEXT) {
            api.resultError(ctx, "json_object() labels must be TEXT");
            jsonStringReset(&jx);
            return;
        }
        jsonAppendSeparator(&jx);
        const z = api.valueText(argv[i]);
        const n = api.valueBytes(argv[i]);
        jsonAppendString(&jx, if (z) |s| s[0..n] else null);
        jsonAppendChar(&jx, ':');
        jsonAppendSqlValue(&jx, argv[i + 1]);
    }
    jsonAppendChar(&jx, '}');
    jsonReturnString(&jx, null, null);
    api.resultSubtype(ctx, json_subtype);
}

/// Port of jsonRemoveFunc(): json_remove(JSON, PATH, ...), the JSON with
/// the elements at the PATHs removed. Also json(JSON) and jsonb(JSON).
fn jsonRemoveFunc(ctx: *Context, argv: []*Mem) void {
    var z_path: ?[*:0]const u8 = null;
    if (argv.len < 1) return;
    const p = jsonParseFuncArg(ctx, argv[0], if (argv.len > 1) JSON_EDITABLE else 0) orelse return;
    done: {
        for (argv[1..]) |arg| {
            const zp = api.valueText(arg) orelse break :done;
            z_path = zp.ptr;
            if (zp[0] != '$') {
                // json_remove_patherror:
                jsonBadPathError(ctx, z_path, 0);
                break :done;
            }
            // json_remove(j,'$') returns NULL.
            if (zp[1] == 0) break :done;
            p.e_edit = JEDIT.DEL;
            p.delta = 0;
            const rc = jsonLookupStep(p, 0, zp.ptr + 1, 0);
            if (jsonLookupIsError(rc)) {
                if (rc == JSON_LOOKUP.NOTFOUND) continue; // No-op
                jsonBadPathError(ctx, z_path, rc);
                break :done;
            }
        }
        jsonReturnParse(ctx, p);
        jsonParseFree(p);
        return;
    }
    // json_remove_done:
    jsonParseFree(p);
}

/// Port of jsonReplaceFunc(): json_replace(JSON, PATH, VALUE, ...), the
/// JSON with the values at existing PATHs replaced.
fn jsonReplaceFunc(ctx: *Context, argv: []*Mem) void {
    if (argv.len < 1) return;
    if (argv.len & 1 == 0) {
        jsonWrongNumArgs(ctx, "replace");
        return;
    }
    jsonInsertIntoBlob(ctx, argv, JEDIT.REPL);
}

/// Port of jsonSetFunc(): json_set(JSON, PATH, VALUE, ...) sets the
/// values at the PATHs, creating them if need be; json_insert() only
/// creates, and json_array_insert() inserts array elements.
fn jsonSetFunc(ctx: *Context, argv: []*Mem) void {
    const az_ins_type = [_][]const u8{ "insert", "set", "array_insert" };
    const a_edit_type = [_]JEDIT{ JEDIT.INS, JEDIT.SET, JEDIT.AINS };
    const e_ins_type = jsonInsertType(userFlags(ctx));
    if (argv.len < 1) return;
    std.debug.assert(e_ins_type <= 2);
    if (argv.len & 1 == 0) {
        jsonWrongNumArgs(ctx, az_ins_type[e_ins_type]);
        return;
    }
    jsonInsertIntoBlob(ctx, argv, a_edit_type[e_ins_type]);
}

/// Port of jsonTypeFunc(): json_type(JSON[, PATH]), the type of the
/// (top-level) element.
fn jsonTypeFunc(ctx: *Context, argv: []*Mem) void {
    var i: u32 = undefined;
    const p = jsonParseFuncArg(ctx, argv[0], 0) orelse return;
    done: {
        if (argv.len == 2) {
            const zp = api.valueText(argv[1]) orelse break :done;
            if (zp[0] != '$') {
                jsonBadPathError(ctx, zp.ptr, 0);
                break :done;
            }
            i = jsonLookupStep(p, 0, zp.ptr + 1, 0);
            if (jsonLookupIsError(i)) {
                if (i == JSON_LOOKUP.NOTFOUND) {
                    // no-op
                } else {
                    jsonBadPathError(ctx, zp.ptr, i);
                }
                break :done;
            }
        } else {
            i = 0;
        }
        api.resultTextZ(ctx, jsonb_type[p.blob()[i] & 0x0f], .static);
    }
    jsonParseFree(p);
}

/// Port of jsonPrettyFunc(): json_pretty(JSON[, INDENT]), the JSON
/// pretty-printed with INDENT (four spaces by default, as in PostgreSQL)
/// for each level of indentation.
fn jsonPrettyFunc(ctx: *Context, argv: []*Mem) void {
    var s: JsonString = undefined;
    const parse = jsonParseFuncArg(ctx, argv[0], 0) orelse return;
    var x: JsonPretty = .{ .parse = parse, .out = &s, .z_indent = "    " };
    jsonStringInit(&s, ctx);
    if (argv.len == 2) {
        if (api.valueText(argv[1])) |z| x.z_indent = std.mem.span(z.ptr);
    }
    _ = jsonTranslateBlobToPrettyText(&x, 0);
    jsonReturnString(&s, null, null);
    jsonParseFree(x.parse);
}

/// Port of jsonValidFunc(): json_valid(JSON[, FLAGS]), 1 if JSON is
/// well-formed by FLAGS (1 by default), else 0; NULL for NULL:
///
///     0x01      Canonical RFC-8259 JSON text
///     0x02      JSON text with optional JSON-5 extensions
///     0x04      Superficially appears to be JSONB
///     0x08      Strictly well-formed JSONB
///
/// FLAGS outside 1 to 15 are an error.
fn jsonValidFunc(ctx: *Context, argv: []*Mem) void {
    var flags: u8 = 1;
    var res: u8 = 0;
    if (argv.len == 2) {
        const f = api.valueInt64(argv[1]);
        if (f < 1 or f > 15) {
            api.resultError(ctx, "FLAGS parameter to json_valid() must be between 1 and 15");
            return;
        }
        flags = @intCast(f & 0x0f);
    }
    text: {
        switch (api.valueType(argv[0])) {
            SQLITE_NULL => return,
            SQLITE_BLOB => {
                var py: JsonParse = .{};
                if (jsonArgIsJsonb(argv[0], &py)) {
                    if (flags & 0x04 != 0) {
                        // Superficial checking only, done by jsonArgIsJsonb().
                        res = 1;
                    } else if (flags & 0x08 != 0) {
                        // Strict checking.
                        res = @intFromBool(jsonbValidityCheck(&py, 0, py.n_blob, 1) == 0);
                    }
                    break :text;
                }
                // Fall through to the text interpretation (tag-20240123-a).
            },
            else => {},
        }
        if (flags & 0x3 == 0) break :text;
        if (jsonParseFuncArg(ctx, argv[0], JSON_KEEPERROR | JSON_NOCACHE)) |p| {
            if (p.oom) {
                api.resultErrorNomem(ctx);
            } else if (p.n_err != 0) {
                // no-op
            } else if (flags & 0x02 != 0 or !p.has_nonstd) {
                res = 1;
            }
            jsonParseFree(p);
        } else {
            api.resultErrorNomem(ctx);
        }
    }
    api.resultInt(ctx, res);
}

/// Port of jsonErrorFunc(): json_error_position(JSON): NULL for NULL; 0
/// if JSON (text, with JSON-5 extensions, or JSONB) is well-formed, else
/// the 1-based character position (byte offset for JSONB) of the first
/// error.
fn jsonErrorFunc(ctx: *Context, argv: []*Mem) void {
    var i_err_pos: i64 = 0;
    std.debug.assert(argv.len == 1);
    var s: JsonParse = .{ .db = api.contextDbHandle(ctx) };
    if (jsonArgIsJsonb(argv[0], &s)) {
        i_err_pos = jsonbValidityCheck(&s, 0, s.n_blob, 1);
    } else {
        const z = api.valueText(argv[0]) orelse return; // NULL input or OOM
        s.z_json = z.ptr;
        s.n_json = @intCast(api.valueBytes(argv[0]));
        if (jsonConvertTextToBlob(&s, null)) |_| {} else |_| {
            if (s.oom) {
                i_err_pos = -1;
            } else {
                // Convert the byte offset i_err into a character offset.
                var k: u32 = 0;
                while (k < s.i_err and z[k] != 0) : (k += 1) {
                    if (z[k] & 0xc0 != 0x80) i_err_pos += 1;
                }
                i_err_pos += 1;
            }
        }
    }
    jsonParseReset(&s);
    if (i_err_pos < 0) {
        api.resultErrorNomem(ctx);
    } else {
        api.resultInt64(ctx, i_err_pos);
    }
}

// ============================================ aggregate SQL functions

/// Port of jsonArrayStep(): the step of json_group_array(VALUE), the
/// JSON array of the values of the group.
fn jsonArrayStep(ctx: *Context, argv: []*Mem) void {
    const str = func.aggContext(JsonString, ctx, true) orelse return;
    if (str.z_buf == null) {
        jsonStringInit(str, ctx);
        jsonAppendChar(str, '[');
    } else if (str.n_used > 1) {
        jsonAppendChar(str, ',');
    }
    str.ctx = ctx;
    jsonAppendSqlValue(str, argv[0]);
}

/// Port of jsonArrayCompute(): the current (or final) value of
/// json_group_array().
fn jsonArrayCompute(ctx: *Context, is_final: bool) void {
    const flags = userFlags(ctx);
    if (func.aggContext(JsonString, ctx, false)) |str| {
        str.ctx = ctx;
        jsonAppendRawNZ(str, "]\x00");
        jsonStringTrimOneChar(str);
        if (str.e_err != 0) {
            jsonReturnString(str, null, null);
            return;
        } else if (flags & JSON.BLOB != 0) {
            jsonReturnStringAsBlob(str);
            if (is_final) {
                if (!str.b_static) rcstrUnref(str.z_buf.?);
            } else {
                jsonStringTrimOneChar(str);
            }
            return;
        } else if (is_final) {
            const z = str.buf()[0..@intCast(str.n_used) :0];
            if (str.b_static) {
                api.resultText(ctx, z, .transient);
            } else {
                api.resultTextZ(ctx, z, .{ .func = int.destructor(rcstrUnref) });
            }
            str.b_static = true;
        } else {
            api.resultText(ctx, str.buf()[0..@intCast(str.n_used)], .transient);
            jsonStringTrimOneChar(str);
        }
    } else if (flags & JSON.BLOB != 0) {
        const S = struct {
            const empty_array = [_]u8{0x0b};
        };
        api.resultBlob(ctx, &S.empty_array, .static);
    } else {
        api.resultText(ctx, "[]", .static);
    }
    api.resultSubtype(ctx, json_subtype);
}

/// Port of jsonArrayValue(): xValue of json_group_array().
fn jsonArrayValue(ctx: *Context) void {
    jsonArrayCompute(ctx, false);
}

/// Port of jsonArrayFinal(): xFinal of json_group_array().
fn jsonArrayFinal(ctx: *Context) void {
    jsonArrayCompute(ctx, true);
}

/// Port of jsonGroupInverse(): xInverse of json_group_array() and
/// json_group_object(): remove the first element of the group, through
/// the first comma that is not in a string.
fn jsonGroupInverse(ctx: *Context, argv: []*Mem) void {
    _ = argv;
    var in_str = false;
    var n_nest: i32 = 0;
    // The step function has always made the context.
    const str = func.aggContext(JsonString, ctx, false) orelse return;
    const z = str.buf();
    var i: u64 = 1;
    while (i < str.n_used) : (i += 1) {
        const c = z[@intCast(i)];
        if (c == ',' and !in_str and n_nest == 0) break;
        if (c == '"') {
            in_str = !in_str;
        } else if (c == '\\') {
            i += 1;
        } else if (!in_str) {
            if (c == '{' or c == '[') n_nest += 1;
            if (c == '}' or c == ']') n_nest -= 1;
        }
    }
    if (i < str.n_used) {
        str.n_used -= i;
        const n: usize = @intCast(str.n_used - 1);
        std.mem.copyForwards(u8, z[1..][0..n], z[@intCast(i + 1)..][0..n]);
        z[@intCast(str.n_used)] = 0;
    } else {
        str.n_used = 1;
    }
}

/// Port of jsonObjectStep(): the step of json_group_object(NAME, VALUE),
/// the JSON object of the names and values of the group.
///
/// Rows with a NULL NAME add no entry, but an "@" entry goes into the
/// string, and its first character becomes "@", so that xInverse() works
/// correctly; jsonObjectCompute() undoes that.
fn jsonObjectStep(ctx: *Context, argv: []*Mem) void {
    const str = func.aggContext(JsonString, ctx, true) orelse return;
    const z = api.valueText(argv[0]);
    if (str.z_buf == null) {
        jsonStringInit(str, ctx);
        jsonAppendChar(str, '{');
    } else if (str.n_used > 1) {
        jsonAppendChar(str, ',');
    }
    str.ctx = ctx;
    if (z) |s| {
        // sqlite3Strlen30()
        jsonAppendString(str, s.ptr[0 .. std.mem.len(s.ptr) & 0x3fffffff]);
        jsonAppendChar(str, ':');
        jsonAppendSqlValue(str, argv[1]);
    } else {
        str.buf()[0] = '@';
        jsonAppendRawNZ(str, "@");
    }
}

/// Port of jsonObjectCompute(): the current (or final) value of
/// json_group_object().
fn jsonObjectCompute(ctx: *Context, is_final: bool) void {
    const flags = userFlags(ctx);
    if (func.aggContext(JsonString, ctx, false)) |og_str| {
        var str = og_str;
        var tmp_str: JsonString = undefined;
        jsonAppendRawNZ(og_str, "}\x00"); // Ensure it is zero-terminated
        jsonStringTrimOneChar(og_str); // Remove the zero terminator
        str.ctx = ctx;
        if (str.e_err != 0) {
            jsonReturnString(str, null, null);
            return;
        }
        if (str.buf()[0] != '{') {
            // The string has null entries to remove.
            var in_str = false;
            if (!is_final) {
                // Work with a copy unless this is the final result.
                jsonStringInit(&tmp_str, ctx);
                jsonAppendRawNZ(&tmp_str, str.buf()[0..@intCast(str.n_used + 1)]);
                str = &tmp_str;
                if (str.e_err != 0) {
                    jsonReturnString(str, null, null);
                    return;
                }
                jsonStringTrimOneChar(str); // Remove the zero terminator
            }
            // Change the initial "@" flag back to "{" and remove all "@"
            // entries with their commas.
            const b = str.buf();
            b[0] = '{';
            var i: u64 = 1;
            var j: u64 = 1;
            while (i < str.n_used) : (i += 1) {
                const c = b[@intCast(i)];
                if (c == '"') {
                    in_str = !in_str;
                    b[@intCast(j)] = '"';
                    j += 1;
                } else if (c == '\\') {
                    b[@intCast(j)] = '\\';
                    j += 1;
                    i += 1;
                    b[@intCast(j)] = b[@intCast(i)];
                    j += 1;
                } else if (c == '@' and !in_str) {
                    std.debug.assert(i + 1 < str.n_used);
                    if (b[@intCast(i + 1)] == ',') {
                        i += 1;
                    } else if (b[@intCast(j - 1)] == ',') {
                        j -= 1;
                    }
                } else {
                    b[@intCast(j)] = c;
                    j += 1;
                }
            }
            b[@intCast(j)] = 0; // Restore the zero terminator
            str.n_used = j; // Truncate the string
        }
        if (flags & JSON.BLOB != 0) {
            jsonReturnStringAsBlob(str);
            if (is_final) {
                if (!str.b_static) rcstrUnref(str.z_buf.?);
            } else {
                jsonStringTrimOneChar(og_str);
            }
        } else if (is_final) {
            const z = str.buf()[0..@intCast(str.n_used) :0];
            if (str.b_static) {
                api.resultText(ctx, z, .transient);
            } else {
                api.resultTextZ(ctx, z, .{ .func = int.destructor(rcstrUnref) });
            }
            str.b_static = true;
        } else {
            api.resultText(ctx, str.buf()[0..@intCast(str.n_used)], .transient);
            jsonStringTrimOneChar(og_str);
        }
        if (str != og_str) jsonStringReset(str);
    } else if (flags & JSON.BLOB != 0) {
        const S = struct {
            const empty_object = [_]u8{0x0c};
        };
        api.resultBlob(ctx, &S.empty_object, .static);
    } else {
        api.resultText(ctx, "{}", .static);
    }
    api.resultSubtype(ctx, json_subtype);
}

/// Port of jsonObjectValue(): xValue of json_group_object().
fn jsonObjectValue(ctx: *Context) void {
    jsonObjectCompute(ctx, false);
}

/// Port of jsonObjectFinal(): xFinal of json_group_object().
fn jsonObjectFinal(ctx: *Context) void {
    jsonObjectCompute(ctx, true);
}

// ============================================= json_each and json_tree

/// A parent of the current element of json_tree() (JsonParent).
const JsonParent = struct {
    /// Start of the object or array.
    i_head: u32 = 0,
    /// Start of the value.
    i_value: u32 = 0,
    /// First byte past the end.
    i_end: u32 = 0,
    /// Length of the path.
    n_path: u32 = 0,
    /// Key for JSONB.ARRAY.
    i_key: i64 = 0,
};

/// A cursor of json_each() or json_tree() (JsonEachCursor). It must not
/// move: `path` may point into itself.
const JsonEachCursor = struct {
    base: vtab.VtabCursor = .{},
    /// The rowid.
    i_rowid: u32 = 0,
    /// Index in s_parse.a_blob of the current row.
    i: u32 = 0,
    /// EOF when i equals or exceeds this value.
    i_end: u32 = 0,
    /// Size of the root path in bytes.
    n_root: u32 = 0,
    /// Type of the container of element i.
    e_type: u8 = 0,
    /// True for json_tree(), false for json_each().
    b_recursive: bool,
    /// 1 for json_each(), 2 for jsonb_each().
    e_mode: u8,
    /// Current nesting depth.
    n_parent: u32 = 0,
    /// Parent elements of i; its len is nParentAlloc.
    a_parent: []JsonParent = &.{},
    db: *Sqlite3,
    /// The current path.
    path: JsonString = .{},
    /// The parse of the input JSON.
    s_parse: JsonParse = .{},

    fn of(cur: *vtab.VtabCursor) *JsonEachCursor {
        return @alignCast(@fieldParentPtr("base", cur));
    }
};

/// A json_each(), json_tree(), jsonb_each() or jsonb_tree() table
/// (JsonEachConnection).
const JsonEachConnection = struct {
    base: vtab.Vtab = .{},
    db: *Sqlite3,
    /// 1 for json_each(), 2 for jsonb_each().
    e_mode: u8,
    /// True for json_tree(), false for json_each().
    b_recursive: bool,

    fn of(p: *vtab.Vtab) *JsonEachConnection {
        return @fieldParentPtr("base", p);
    }
};

/// Column numbers (JEACH_*). jsonEachBestIndex() assumes that JSON and
/// ROOT are the last two columns of the table.
const JEACH = struct {
    const KEY = 0;
    const VALUE = 1;
    const TYPE = 2;
    const ATOM = 3;
    const ID = 4;
    const PARENT = 5;
    const FULLKEY = 6;
    const PATH = 7;
    const JSON = 8;
    const ROOT = 9;
};

/// Port of jsonEachConnect(): the constructor of the json_each virtual
/// table. The module name in argv[0] tells the variant.
fn jsonEachConnect(db: *Sqlite3, _: ?*anyopaque, argv: []const [:0]const u8, pp_vtab: *?*vtab.Vtab, _: *?[:0]u8) i32 {
    const rc = vtab.declareVtab(db, "CREATE TABLE x(key,value,type,atom,id,parent,fullkey,path," ++
        "json HIDDEN,root HIDDEN)");
    if (rc == RC.OK) {
        const e_mode: u8 = if (argv[0][4] == 'b') 2 else 1;
        const new = db.gpa.create(JsonEachConnection) catch return RC.NOMEM;
        new.* = .{ .db = db, .e_mode = e_mode, .b_recursive = argv[0][4 + e_mode] == 't' };
        pp_vtab.* = &new.base;
        _ = vtab.config(db, vtab.VTAB_INNOCUOUS, 0);
    }
    return rc;
}

/// Port of jsonEachDisconnect(): the destructor of the json_each virtual
/// table.
fn jsonEachDisconnect(p_vtab: *vtab.Vtab) i32 {
    const p = JsonEachConnection.of(p_vtab);
    p.db.gpa.destroy(p);
    return RC.OK;
}

/// Port of jsonEachOpen(): a new JsonEachCursor for json_each() or
/// json_tree().
fn jsonEachOpen(p: *vtab.Vtab, pp_cursor: *?*vtab.VtabCursor) i32 {
    const t = JsonEachConnection.of(p);
    const cur = t.db.gpa.create(JsonEachCursor) catch return RC.NOMEM;
    cur.* = .{ .db = t.db, .e_mode = t.e_mode, .b_recursive = t.b_recursive };
    jsonStringZero(&cur.path);
    pp_cursor.* = &cur.base;
    return RC.OK;
}

/// Port of jsonEachCursorReset(): reset a JsonEachCursor to its original
/// state, freeing the memory it holds.
fn jsonEachCursorReset(p: *JsonEachCursor) void {
    jsonParseReset(&p.s_parse);
    jsonStringReset(&p.path);
    p.db.gpa.free(p.a_parent);
    p.i_rowid = 0;
    p.i = 0;
    p.a_parent = &.{};
    p.n_parent = 0;
    p.i_end = 0;
    p.e_type = 0;
}

/// Port of jsonEachClose(): the destructor of a JsonEachCursor.
fn jsonEachClose(cur: *vtab.VtabCursor) i32 {
    const p = JsonEachCursor.of(cur);
    jsonEachCursorReset(p);
    p.db.gpa.destroy(p);
    return RC.OK;
}

/// Port of jsonEachEof(): the cursor is past the end of the JSON.
fn jsonEachEof(cur: *vtab.VtabCursor) bool {
    const p = JsonEachCursor.of(cur);
    return p.i >= p.i_end;
}

/// Port of jsonSkipLabel(): the index of the value if the cursor is at
/// the label of an object entry, else the cursor position (the value).
fn jsonSkipLabel(p: *JsonEachCursor) u32 {
    if (p.e_type == JSONB.OBJECT) {
        var sz: u32 = 0;
        const n = jsonbPayloadSize(&p.s_parse, p.i, &sz);
        sz += p.i + n;
        if (sz >= p.s_parse.n_blob) sz = p.i;
        return sz;
    } else {
        return p.i;
    }
}

/// Port of jsonAppendPathName(): append the path name of the current
/// element: "[N]" in an array, ".label" or ".\"label\"" in an object.
fn jsonAppendPathName(p: *JsonEachCursor) void {
    std.debug.assert(p.n_parent > 0);
    std.debug.assert(p.e_type == JSONB.ARRAY or p.e_type == JSONB.OBJECT);
    if (p.e_type == JSONB.ARRAY) {
        jsonPrintf(30, &p.path, "[%lld]", &.{.{ .int = p.a_parent[p.n_parent - 1].i_key }});
    } else {
        var sz: u32 = 0;
        const n = jsonbPayloadSize(&p.s_parse, p.i, &sz);
        const k = p.i + n;
        const z = p.s_parse.blob()[k..][0..sz];
        var need_quote = false;
        if (sz == 0 or !ctype.isAlpha(z[0])) {
            need_quote = true;
        } else {
            for (z) |ch| {
                if (!ctype.isAlnum(ch)) {
                    need_quote = true;
                    break;
                }
            }
        }
        if (need_quote) {
            jsonPrintf(sz + 4, &p.path, ".\"%.*s\"", &.{ .{ .int = sz }, .{ .str = z } });
        } else {
            jsonPrintf(sz + 2, &p.path, ".%.*s", &.{ .{ .int = sz }, .{ .str = z } });
        }
    }
}

/// Port of jsonEachMalformedInput(): report a "malformed JSON" (or OOM)
/// error against the cursor.
fn jsonEachMalformedInput(cur: *vtab.VtabCursor) i32 {
    const p = JsonEachCursor.of(cur);
    vtab.setErrMsg(p.db, cur.vtab, "malformed JSON", .{});
    jsonEachCursorReset(p);
    return if (cur.vtab.err_msg != null) RC.ERROR else RC.NOMEM;
}

/// Port of jsonEachNext(): advance the cursor to the next element; for
/// json_tree() that descends into arrays and objects.
fn jsonEachNext(cur: *vtab.VtabCursor) i32 {
    const p = JsonEachCursor.of(cur);
    var rc: i32 = RC.OK;
    if (p.b_recursive) {
        var level_change = false;
        var sz: u32 = 0;
        const i = jsonSkipLabel(p);
        const x = p.s_parse.blob()[i] & 0x0f;
        const n = jsonbPayloadSize(&p.s_parse, i, &sz);
        if (n == 0) return jsonEachMalformedInput(cur);
        if (x == JSONB.OBJECT or x == JSONB.ARRAY) {
            if (p.n_parent >= p.a_parent.len) {
                const n_new = p.a_parent.len * 2 + 3;
                p.a_parent = p.db.gpa.realloc(p.a_parent, n_new) catch return RC.NOMEM;
            }
            level_change = true;
            const parent = &p.a_parent[p.n_parent];
            parent.i_head = p.i;
            parent.i_value = i;
            parent.i_end = i + n + sz;
            parent.i_key = -1;
            parent.n_path = @intCast(p.path.n_used);
            if (p.e_type != 0 and p.n_parent != 0) {
                jsonAppendPathName(p);
                if (p.path.e_err != 0) rc = RC.NOMEM;
            }
            p.n_parent += 1;
            p.i = i + n;
        } else {
            p.i = i + n + sz;
        }
        while (p.n_parent > 0 and p.i >= p.a_parent[p.n_parent - 1].i_end) {
            p.n_parent -= 1;
            p.path.n_used = p.a_parent[p.n_parent].n_path;
            level_change = true;
        }
        if (level_change) {
            if (p.n_parent > 0) {
                const i_val = p.a_parent[p.n_parent - 1].i_value;
                p.e_type = p.s_parse.blob()[i_val] & 0x0f;
            } else {
                p.e_type = 0;
            }
        }
    } else {
        var sz: u32 = 0;
        const i = jsonSkipLabel(p);
        const n = jsonbPayloadSize(&p.s_parse, i, &sz);
        if (n == 0) return jsonEachMalformedInput(cur);
        p.i = i + n + sz;
    }
    if (p.e_type == JSONB.ARRAY and p.n_parent != 0) {
        p.a_parent[p.n_parent - 1].i_key += 1;
    }
    p.i_rowid +%= 1;
    return rc;
}

/// Port of jsonEachPathLength(): the length of the path; for rowid 0 of
/// json_tree() with a root path, that of the root's container.
fn jsonEachPathLength(p: *JsonEachCursor) u32 {
    var n: u32 = @intCast(p.path.n_used);
    const z = p.path.buf();
    if (p.i_rowid == 0 and p.b_recursive and n >= 2) {
        while (n > 1) {
            n -= 1;
            if (z[n] == '[' or z[n] == '.') {
                var sz: u32 = 0;
                const c_saved = z[n];
                z[n] = 0;
                std.debug.assert(p.s_parse.e_edit == null);
                const x = jsonLookupStep(&p.s_parse, 0, @ptrCast(z + 1), 0);
                z[n] = c_saved;
                if (jsonLookupIsError(x)) continue;
                if (x + jsonbPayloadSize(&p.s_parse, x, &sz) == p.i) break;
            }
        }
    }
    return n;
}

/// Port of jsonEachColumn(): the value of column `i_column`.
fn jsonEachColumn(cur: *vtab.VtabCursor, ctx: *Context, i_column: i32) i32 {
    const p = JsonEachCursor.of(cur);
    switch (i_column) {
        JEACH.KEY => {
            if (p.n_parent == 0) {
                if (p.n_root == 1) return RC.OK;
                const j = jsonEachPathLength(p);
                const n = p.n_root - j;
                const z = p.path.buf();
                if (n == 0) {
                    // NULL
                } else if (z[j] == '[') {
                    var x: i64 = 0;
                    _ = util.atoi64(z[j + 1 ..][0 .. n - 1], &x);
                    api.resultInt64(ctx, x);
                } else if (z[j + 1] == '"') {
                    api.resultText(ctx, z[j + 2 ..][0 .. n - 3], .transient);
                } else {
                    api.resultText(ctx, z[j + 1 ..][0 .. n - 1], .transient);
                }
                return RC.OK;
            }
            if (p.e_type == JSONB.OBJECT) {
                jsonReturnFromBlob(&p.s_parse, p.i, ctx, 1);
            } else {
                std.debug.assert(p.e_type == JSONB.ARRAY);
                api.resultInt64(ctx, p.a_parent[p.n_parent - 1].i_key);
            }
        },
        JEACH.VALUE => {
            const i = jsonSkipLabel(p);
            jsonReturnFromBlob(&p.s_parse, i, ctx, p.e_mode);
            if (p.s_parse.blob()[i] & 0x0f >= JSONB.ARRAY) {
                api.resultSubtype(ctx, json_subtype);
            }
        },
        JEACH.TYPE => {
            const i = jsonSkipLabel(p);
            const e_type = p.s_parse.blob()[i] & 0x0f;
            api.resultText(ctx, jsonb_type[e_type], .static);
        },
        JEACH.ATOM => {
            const i = jsonSkipLabel(p);
            if (p.s_parse.blob()[i] & 0x0f < JSONB.ARRAY) {
                jsonReturnFromBlob(&p.s_parse, i, ctx, 1);
            }
        },
        JEACH.ID => api.resultInt64(ctx, p.i),
        JEACH.PARENT => {
            if (p.n_parent > 0 and p.b_recursive) {
                api.resultInt64(ctx, p.a_parent[p.n_parent - 1].i_head);
            }
        },
        JEACH.FULLKEY => {
            const n_base = p.path.n_used;
            if (p.n_parent != 0) jsonAppendPathName(p);
            api.resultText64(ctx, p.path.buf()[0..@intCast(p.path.n_used)], .transient);
            p.path.n_used = n_base;
        },
        JEACH.PATH => {
            const n = jsonEachPathLength(p);
            api.resultText64(ctx, p.path.buf()[0..n], .transient);
        },
        JEACH.JSON => {
            if (p.s_parse.z_json) |z| {
                const zt: [*:0]const u8 = @ptrCast(z);
                api.resultText(ctx, std.mem.span(zt), .transient);
            } else {
                api.resultBlob(ctx, p.s_parse.blob()[0..p.s_parse.n_blob], .transient);
            }
        },
        // JEACH.ROOT
        else => api.resultText(ctx, p.path.buf()[0..p.n_root], .transient),
    }
    return RC.OK;
}

/// Port of jsonEachRowid(): the current rowid.
fn jsonEachRowid(cur: *vtab.VtabCursor, rowid: *i64) i32 {
    rowid.* = JsonEachCursor.of(cur).i_rowid;
    return RC.OK;
}

/// Port of jsonEachBestIndex(): an equality constraint on the json column
/// is required. idx_num is 1 if it is found, 3 if the root constraint is
/// found too, and 0 otherwise.
fn jsonEachBestIndex(_: *vtab.Vtab, info: *vtab.IndexInfo) i32 {
    // Indexes of the constraints on JSON and ROOT.
    var a_idx = [2]i32{ -1, -1 };
    // Mask of unusable JSON and ROOT constraints.
    var unusable_mask: u32 = 0;
    // Mask of usable == constraints on JSON and ROOT.
    var idx_mask: u32 = 0;
    comptime std.debug.assert(JEACH.ROOT == JEACH.JSON + 1);
    for (info.constraints, 0..) |cons, i| {
        if (cons.i_column < JEACH.JSON) continue;
        const i_col: u5 = @intCast(cons.i_column - JEACH.JSON);
        std.debug.assert(i_col == 0 or i_col == 1);
        const i_mask = @as(u32, 1) << i_col;
        if (!cons.usable) {
            unusable_mask |= i_mask;
        } else if (cons.op == vtab.INDEX_CONSTRAINT.EQ) {
            a_idx[i_col] = @intCast(i);
            idx_mask |= i_mask;
        }
    }
    if (info.order_by.len > 0 and info.order_by[0].i_column < 0 and !info.order_by[0].desc) {
        info.order_by_consumed = true;
    }

    if (unusable_mask & ~idx_mask != 0) {
        // Any unusable constraints on JSON or ROOT reject the plan.
        return RC.CONSTRAINT;
    }
    if (a_idx[0] < 0) {
        // No JSON input: leave estimated_cost at the huge initial value,
        // to discourage the planner from choosing this plan.
        info.idx_num = 0;
    } else {
        info.estimated_cost = 1.0;
        var i: usize = @intCast(a_idx[0]);
        info.usage[i].argv_index = 1;
        info.usage[i].omit = true;
        if (a_idx[1] < 0) {
            // Only JSON supplied: plan 1.
            info.idx_num = 1;
        } else {
            i = @intCast(a_idx[1]);
            info.usage[i].argv_index = 2;
            info.usage[i].omit = true;
            // Both JSON and ROOT supplied: plan 3.
            info.idx_num = 3;
        }
    }
    return RC.OK;
}

/// The bad-path error of jsonEachFilter().
fn jsonEachBadPath(cur: *vtab.VtabCursor, z_root: [:0]const u8) i32 {
    const p = JsonEachCursor.of(cur);
    vtab.setErrMsgOwned(p.db, cur.vtab, jsonBadPathMsg(p.db.gpa, z_root.ptr, 0));
    jsonEachCursorReset(p);
    return if (cur.vtab.err_msg != null) RC.ERROR else RC.NOMEM;
}

/// Port of jsonEachFilter(): start a scan of the JSON argv[0], from the
/// path argv[1] with idx_num 3.
fn jsonEachFilter(cur: *vtab.VtabCursor, idx_num: i32, _: ?[:0]const u8, argv: []*Mem) i32 {
    const p = JsonEachCursor.of(cur);
    var i: u32 = undefined;
    jsonEachCursorReset(p);
    if (idx_num == 0) return RC.OK;
    p.s_parse = .{ .n_jp_ref = 1, .db = p.db };
    if (jsonArgIsJsonb(argv[0], &p.s_parse)) {
        // JSONB.
    } else {
        const z = api.valueText(argv[0]);
        p.s_parse.z_json = if (z) |t| t.ptr else null;
        p.s_parse.n_json = @intCast(api.valueBytes(argv[0]));
        if (p.s_parse.z_json == null) {
            p.i = 0;
            p.i_end = 0;
            return RC.OK;
        }
        jsonConvertTextToBlob(&p.s_parse, null) catch |err| switch (err) {
            error.OutOfMemory => return RC.NOMEM,
            error.Malformed => return jsonEachMalformedInput(cur),
        };
    }
    if (idx_num == 3) {
        const z_root = api.valueText(argv[1]) orelse return RC.OK;
        if (z_root[0] != '$') return jsonEachBadPath(cur, z_root);
        p.n_root = @intCast(z_root.len);
        if (z_root[1] == 0) {
            i = 0;
            p.i = 0;
            p.e_type = 0;
        } else {
            i = jsonLookupStep(&p.s_parse, 0, z_root.ptr + 1, 0);
            if (jsonLookupIsError(i)) {
                if (i == JSON_LOOKUP.NOTFOUND) {
                    p.i = 0;
                    p.e_type = 0;
                    p.i_end = 0;
                    return RC.OK;
                }
                return jsonEachBadPath(cur, z_root);
            }
            if (p.s_parse.i_label != 0) {
                p.i = p.s_parse.i_label;
                p.e_type = JSONB.OBJECT;
            } else {
                p.i = i;
                p.e_type = JSONB.ARRAY;
            }
        }
        jsonAppendRaw(&p.path, z_root[0..p.n_root]);
    } else {
        i = 0;
        p.i = 0;
        p.e_type = 0;
        p.n_root = 1;
        jsonAppendRaw(&p.path, "$");
    }
    p.n_parent = 0;
    var sz: u32 = 0;
    const n = jsonbPayloadSize(&p.s_parse, i, &sz);
    p.i_end = i + n + sz;
    if (p.s_parse.blob()[i] & 0x0f >= JSONB.ARRAY and !p.b_recursive) {
        p.i = i + n;
        p.e_type = p.s_parse.blob()[i] & 0x0f;
        p.a_parent = p.db.gpa.alloc(JsonParent, 1) catch return RC.NOMEM;
        p.n_parent = 1;
        p.a_parent[0] = .{ .i_key = 0, .i_end = p.i_end, .i_head = p.i, .i_value = i };
    }
    return RC.OK;
}

/// The methods of the json_each virtual table (jsonEachModule). There is
/// no xCreate: the tables are eponymous only.
const json_each_module: vtab.Module = .{
    .i_version = 0,
    .x_connect = jsonEachConnect,
    .x_best_index = jsonEachBestIndex,
    .x_disconnect = jsonEachDisconnect,
    .x_open = jsonEachOpen,
    .x_close = jsonEachClose,
    .x_filter = jsonEachFilter,
    .x_next = jsonEachNext,
    .x_eof = jsonEachEof,
    .x_column = jsonEachColumn,
    .x_rowid = jsonEachRowid,
};

/// Port of sqlite3JsonVtabRegister(): register the JSON table-valued
/// function `name` and return its Module; null if `name` is not one.
/// Called by build.locateTable() for unknown tables named "json...".
pub fn jsonVtabRegister(db: *Sqlite3, name: []const u8) ?*int.Module {
    const az_module = [_][]const u8{ "json_each", "json_tree", "jsonb_each", "jsonb_tree" };
    std.debug.assert(db.modules.get(name) == null);
    for (az_module) |m| {
        if (ctype.eqlNoCase(m, name)) {
            return vtab.createModuleInternal(db, m, &json_each_module, null, null);
        }
    }
    return null;
}

// ======================================================= registration

/// JFUNCTION(): a deterministic JSON function. `use_cache` marks it
/// FUNC.RUNONLY (it uses the parse cache), `ws` FUNC.RESULT_SUBTYPE (may
/// set a subtype), `rs` FUNC.SUBTYPE (reads subtypes), `jsonb` adds
/// JSON.BLOB to `i_arg`, the user data.
fn jfunction(name: [:0]const u8, n_arg: i16, use_cache: u1, ws: u1, rs: u1, jsonb: u1, i_arg: usize, x: FuncDef.StepFn) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = .{
            .enc = ENC.UTF8,
            .BUILTIN = true,
            .CONSTANT = true, // SQLITE_DETERMINISTIC
            .RUNONLY = use_cache != 0,
            .SUBTYPE = rs != 0,
            .RESULT_SUBTYPE = ws != 0,
        },
        .user_data = func.intToPtr(i_arg | @as(usize, jsonb) * JSON.BLOB),
        .x_sfunc = x,
        .name = name,
    };
}

/// WAGGREGATE(): an aggregate that is also a window function.
fn waggregate(name: [:0]const u8, n_arg: i16, arg: usize, step: FuncDef.StepFn, final: FuncDef.FinalFn, value: FuncDef.FinalFn, inverse: FuncDef.StepFn, f: FUNC) FuncDef {
    return .{
        .n_arg = n_arg,
        .func_flags = f.with(.{ .enc = ENC.UTF8, .BUILTIN = true }),
        .user_data = func.intToPtr(arg),
        .x_sfunc = step,
        .x_finalize = final,
        .x_value = value,
        .x_inverse = inverse,
        .name = name,
    };
}

/// SQLITE_SUBTYPE|SQLITE_RESULT_SUBTYPE|SQLITE_UTF8|SQLITE_DETERMINISTIC.
const agg_flags: FUNC = .{ .SUBTYPE = true, .RESULT_SUBTYPE = true, .enc = ENC.UTF8, .CONSTANT = true };

/// aJsonFunc[] of sqlite3RegisterJsonFunctions(): the JSON functions, in
/// callback.builtins.
pub const funcs = [_]FuncDef{
    //     sqlite3_result_subtype() --------------,  ,--- sqlite3_value_subtype()
    //                                            |  |
    //                       Uses cache ------, |  | ,---- Returns JSONB
    //                                        | |  | |
    //               Number of arguments ---, | |  | | ,--- Flags
    //                                      | | |  | | |
    jfunction("json", 1, 1, 1, 0, 0, 0, jsonRemoveFunc),
    jfunction("jsonb", 1, 1, 0, 0, 1, 0, jsonRemoveFunc),
    jfunction("json_array", -1, 0, 1, 1, 0, 0, jsonArrayFunc),
    jfunction("jsonb_array", -1, 0, 1, 1, 1, 0, jsonArrayFunc),
    jfunction("json_array_insert", -1, 1, 1, 1, 0, JSON.AINS, jsonSetFunc),
    jfunction("jsonb_array_insert", -1, 1, 0, 1, 1, JSON.AINS, jsonSetFunc),
    jfunction("json_array_length", 1, 1, 0, 0, 0, 0, jsonArrayLengthFunc),
    jfunction("json_array_length", 2, 1, 0, 0, 0, 0, jsonArrayLengthFunc),
    jfunction("json_error_position", 1, 1, 0, 0, 0, 0, jsonErrorFunc),
    jfunction("json_extract", -1, 1, 1, 0, 0, 0, jsonExtractFunc),
    jfunction("jsonb_extract", -1, 1, 0, 0, 1, 0, jsonExtractFunc),
    jfunction("->", 2, 1, 1, 0, 0, JSON.JSON, jsonExtractFunc),
    jfunction("->>", 2, 1, 0, 0, 0, JSON.SQL, jsonExtractFunc),
    jfunction("json_insert", -1, 1, 1, 1, 0, 0, jsonSetFunc),
    jfunction("jsonb_insert", -1, 1, 0, 1, 1, 0, jsonSetFunc),
    jfunction("json_object", -1, 0, 1, 1, 0, 0, jsonObjectFunc),
    jfunction("jsonb_object", -1, 0, 1, 1, 1, 0, jsonObjectFunc),
    jfunction("json_patch", 2, 1, 1, 0, 0, 0, jsonPatchFunc),
    jfunction("jsonb_patch", 2, 1, 0, 0, 1, 0, jsonPatchFunc),
    jfunction("json_pretty", 1, 1, 0, 0, 0, 0, jsonPrettyFunc),
    jfunction("json_pretty", 2, 1, 0, 0, 0, 0, jsonPrettyFunc),
    jfunction("json_quote", 1, 0, 1, 1, 0, 0, jsonQuoteFunc),
    jfunction("json_remove", -1, 1, 1, 0, 0, 0, jsonRemoveFunc),
    jfunction("jsonb_remove", -1, 1, 0, 0, 1, 0, jsonRemoveFunc),
    jfunction("json_replace", -1, 1, 1, 1, 0, 0, jsonReplaceFunc),
    jfunction("jsonb_replace", -1, 1, 0, 1, 1, 0, jsonReplaceFunc),
    jfunction("json_set", -1, 1, 1, 1, 0, JSON.ISSET, jsonSetFunc),
    jfunction("jsonb_set", -1, 1, 0, 1, 1, JSON.ISSET, jsonSetFunc),
    jfunction("json_type", 1, 1, 0, 0, 0, 0, jsonTypeFunc),
    jfunction("json_type", 2, 1, 0, 0, 0, 0, jsonTypeFunc),
    jfunction("json_valid", 1, 1, 0, 0, 0, 0, jsonValidFunc),
    jfunction("json_valid", 2, 1, 0, 0, 0, 0, jsonValidFunc),
    waggregate("json_group_array", 1, 0, jsonArrayStep, jsonArrayFinal, jsonArrayValue, jsonGroupInverse, agg_flags),
    waggregate("jsonb_group_array", 1, JSON.BLOB, jsonArrayStep, jsonArrayFinal, jsonArrayValue, jsonGroupInverse, agg_flags),
    waggregate("json_group_object", 2, 0, jsonObjectStep, jsonObjectFinal, jsonObjectValue, jsonGroupInverse, agg_flags),
    waggregate("jsonb_group_object", 2, JSON.BLOB, jsonObjectStep, jsonObjectFinal, jsonObjectValue, jsonGroupInverse, agg_flags),
};

// ================================================================== tests

const testing = std.testing;
const Conn = @import("sql_test.zig").Conn;
const mem = @import("../vdbe/mem.zig");

// Expected values come from the sqlite3 3.54.1 shell.

test "json: parse and render text JSON and JSON5" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("SELECT json(' { \"a\" : [1, 2.5, \"x\\ny\", true, false, null] } ')", "{\"a\":[1,2.5,\"x\\ny\",true,false,null]}\n");
    try c.expectRows("SELECT json('{a:0x1F, b:.5, c:+Infinity, d:''q'', /* c */ e:[1,2,],}')", "{\"a\":31,\"b\":0.5,\"c\":9e999,\"d\":\"q\",\"e\":[1,2]}\n");
    try c.expectRows("SELECT json_valid('{a:1}'), json_valid('{a:1}', 2), json_valid('[1,2'), json_valid(NULL), " ++
        "json_error_position('[1,2'), json_error_position('{\"a\":1}'), json_error_position('[1,x]')", "0|1|0|NULL|5|0|4\n");
    try c.expectRows("SELECT json_quote('a\"b\\'), json_quote(3.5), json_quote(NULL), " ++
        "json_array(1, 'two', 3.0e0, NULL, json('{\"x\":1}')), json_object('k', 1, 'l', json_array(2))", "\"a\\\"b\\\\\"|3.5|null|[1,\"two\",3.0,null,{\"x\":1}]|{\"k\":1,\"l\":[2]}\n");
    try c.expectRows("SELECT json_pretty('{\"a\":[1,{\"b\":null}],\"c\":{}}'), json_pretty('[1,2]', '--')", "{\n    \"a\": [\n        1,\n        {\n            \"b\": null\n        }\n    ],\n    \"c\": {}\n}|[\n--1,\n--2\n]\n");
    // The parse cache: the same text several times in one statement.
    try c.exec("CREATE TABLE t(j); INSERT INTO t VALUES('{\"a\":1,\"b\":[2,3]}'), ('[5]'), ('{\"a\":1,\"b\":[2,3]}');");
    try c.expectRows("SELECT json_extract(j, '$.a'), j -> '$.b', json_set(j, '$.c', 4), json_type(j) FROM t", "1|[2,3]|{\"a\":1,\"b\":[2,3],\"c\":4}|object\n" ++
        "NULL|NULL|[5]|array\n1|[2,3]|{\"a\":1,\"b\":[2,3],\"c\":4}|object\n");
}

test "json: errors" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectError("SELECT json('{\"a\":')", "malformed JSON");
    try c.expectError("SELECT json(x'0b01')", "malformed JSON");
    try c.expectError("SELECT json_extract('{}', 'a')", "bad JSON path: 'a'");
    try c.expectError("SELECT json_remove('[1]', 'x')", "bad JSON path: 'x'");
    try c.expectError("SELECT json_set('{}', '$.a')", "json_set() needs an odd number of arguments");
    try c.expectError("SELECT json_object('a')", "json_object() requires an even number of arguments");
    try c.expectError("SELECT json_object(1, 2)", "json_object() labels must be TEXT");
    try c.expectError("SELECT json_valid('1', 16)", "FLAGS parameter to json_valid() must be between 1 and 15");
    try c.expectError("SELECT json_array_insert('{}', '$.a', 1)", "not an array element: '$.a'");
    try c.expectRows("SELECT json_extract('{}', '$.a['), json_array(x'00')", "NULL|[null]\n");
}

test "json: JSONB round trip" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("SELECT hex(jsonb('{\"a\":[1,\"b\",null]}')), json(x'8C17615B1331176200')", "8C17615B1331176200|{\"a\":[1,\"b\",null]}\n");
    try c.expectRows("SELECT hex(jsonb('{a:0x1F,\"b\\n\":''c'',d:1.,e:-.5}')), json(jsonb('{a:0x1F,\"b\\n\":''c'',d:1.,e:-.5}'))", "CC181761443078314638625C6E1763176426312E1765362D2E35|{\"a\":31,\"b\\n\":\"c\",\"d\":1.0,\"e\":-0.5}\n");
    try c.expectRows("SELECT jsonb('{\"a\":1}') = jsonb(json(jsonb('{\"a\":1}'))), json_valid(jsonb('[1]'), 8), json_valid(x'0b', 8), json_error_position(x'1b02')", "1|1|1|0\n");
    try c.expectRows("SELECT json_valid(x'5b1331', 8), json_error_position(x'5b1331'), json_type(x'0c'), json_error_position(x'3b31')", "0|2|object|1\n");
    try c.expectRows("SELECT hex(jsonb_set(jsonb('[1,{\"a\":2}]'), '$[1].b', 'x')), json(jsonb_remove(jsonb('[1,{\"a\":2}]'), '$[1].a')), " ++
        "hex(jsonb_extract('{\"a\":[1,2]}', '$.a')), quote(jsonb_extract('{\"a\":[1,2]}', '$.a[0]'))", "BB13318C176113321A621A78|[1,{}]|4B13311332|1\n");
}

test "json: paths, edits and the -> and ->> operators" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("SELECT '{\"a\":{\"b\":[5,6]}}' -> '$.a', '{\"a\":{\"b\":[5,6]}}' ->> '$.a.b[1]', '[1,2,3]' -> 1, '[1,2,3]' ->> -1, '{\"x y\":7}' ->> 'x y'", "{\"b\":[5,6]}|6|2|3|7\n");
    try c.expectRows("SELECT json_extract('{\"a\":[1,2,3]}', '$.a[#-1]', '$.b', '$.a[0]'), json_extract('{\"a\":\"x\"}', '$.a'), json_type('{\"a\":[1,2.5,\"s\"]}', '$.a[1]')", "[3,null,1]|x|real\n");
    try c.expectRows("SELECT json_set('{\"a\":1}', '$.b.c', 2, '$.a', json('[3]')), json_insert('[1]', '$[#]', 9), " ++
        "json_replace('{\"a\":1}', '$.a', 'x', '$.z', 1), json_remove('[1,2,3]', '$[0]', '$[0]')", "{\"a\":[3],\"b\":{\"c\":2}}|[1,9]|{\"a\":\"x\"}|[3]\n");
    try c.expectRows("SELECT json_patch('{\"a\":1,\"b\":{\"c\":2}}', '{\"b\":{\"c\":null,\"d\":3},\"e\":4}'), json_array_length('[1,[2,3]]', '$[1]'), json_array_insert('[1,2]', '$[1]', 'x')", "{\"a\":1,\"b\":{\"d\":3},\"e\":4}|2|[1,\"x\",2]\n");
}

test "json: aggregates" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("WITH t(x) AS (VALUES(1),('a,b'),(NULL),(2.5)) SELECT json_group_array(x), json_group_object(coalesce(x,'n'), x), hex(jsonb_group_array(x)) FROM t", "[1,\"a,b\",null,2.5]|{\"1\":1,\"a,b\":\"a,b\",\"n\":null,\"2.5\":2.5}|BB133137612C620035322E35\n");
    try c.expectRows("SELECT json_group_array(x), json_group_object(x, x), hex(jsonb_group_object(x, x)) FROM (SELECT 1 AS x WHERE 0)", "[]|{}|0C\n");
}

/// Calls the aggregate `name` on a context of its own as a window
/// function would: step, value and inverse in the order of `ops`, then
/// final. Returns the values ('v' and 'f' ops) joined with " ".
fn windowCalls(out: *std.ArrayList(u8), name: []const u8, ops: []const union(enum) { step: [2]?[]const u8, inverse, value }) !void {
    var db: Sqlite3 = .{ .gpa = undefined };
    db.gpa = malloc.dbAllocator(&db);
    const def: *const FuncDef = for (&funcs) |*f| {
        if (std.mem.eql(u8, f.name, name)) break f;
    } else unreachable;
    var accum: Mem = .{ .db = &db };
    var res: Mem = .{ .db = &db };
    defer mem.release(&res);
    for (ops) |op| {
        switch (op) {
            .step, .inverse => {
                var cells: [2]Mem = .{ .{ .db = &db }, .{ .db = &db } };
                defer for (&cells) |*m| mem.release(m);
                var argv: [2]*Mem = .{ &cells[0], &cells[1] };
                if (op == .step) for (op.step, 0..) |a, i| {
                    if (a) |t| try mem.setStr(&cells[i], t, ENC.UTF8, .static);
                };
                var ctx: Context = .{ .out = &res, .mem = &accum, .func = def, .argv = &.{} };
                if (op == .step) def.x_sfunc.?(&ctx, argv[0..@intCast(def.n_arg)]) else def.x_inverse.?(&ctx, argv[0..@intCast(def.n_arg)]);
                try testing.expectEqual(@as(i32, 0), ctx.is_error);
            },
            .value => {
                try testing.expectEqual(@as(i32, 0), mem.aggValue(&accum, &res, def));
                try out.appendSlice(testing.allocator, api.valueText(&res).?);
                try out.append(testing.allocator, ' ');
            },
        }
    }
    try testing.expectEqual(@as(i32, 0), mem.finalize(&accum, def));
    defer mem.release(&accum);
    try out.appendSlice(testing.allocator, api.valueText(&accum) orelse "NULL");
}

test "json: window xValue and xInverse" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try windowCalls(&out, "json_group_array", &.{
        .{ .step = .{ "1", null } }, .{ .step = .{ "a,\"]", null } }, .value,   .inverse, .value,
        .{ .step = .{ "z", null } }, .value,                          .inverse, .inverse, .value,
    });
    try testing.expectEqualStrings("[\"1\",\"a,\\\"]\"] [\"a,\\\"]\"] [\"a,\\\"]\",\"z\"] [] []", out.items);
    out.clearRetainingCapacity();
    try windowCalls(&out, "json_group_object", &.{
        .{ .step = .{ "a", "1" } }, .{ .step = .{ null, "2" } }, .{ .step = .{ "b", "x" } }, .value,
        .inverse,                   .value,                      .inverse,                   .value,
    });
    try testing.expectEqualStrings("{\"a\":\"1\",\"b\":\"x\"} {\"b\":\"x\"} {\"b\":\"x\"} {\"b\":\"x\"}", out.items);
}

test "json: json_each and json_tree" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    try c.expectRows("SELECT * FROM json_each('{\"a\":1,\"b\":[2,3]}')", "a|1|integer|1|1|NULL|$.a|$\nb|[2,3]|array|NULL|5|NULL|$.b|$\n");
    try c.expectRows("SELECT * FROM json_tree('{\"a\":1,\"b\":[2,3],\"c d\":{}}')", "NULL|{\"a\":1,\"b\":[2,3],\"c d\":{}}|object|NULL|0|NULL|$|$\n" ++
        "a|1|integer|1|2|0|$.a|$\nb|[2,3]|array|NULL|6|0|$.b|$\n0|2|integer|2|9|6|$.b[0]|$.b\n1|3|integer|3|11|6|$.b[1]|$.b\n" ++
        "c d|{}|object|NULL|13|0|$.\"c d\"|$\n");
    // The root path argument, and the hidden columns.
    try c.expectRows("SELECT key, value, fullkey, path, json, root FROM json_tree('{\"a\":[1,{\"b\":2}]}', '$.a[1]')", "a[1]|{\"b\":2}|$.a[1]|$|{\"a\":[1,{\"b\":2}]}|$.a[1]\nb|2|$.a[1].b|$.a[1]|{\"a\":[1,{\"b\":2}]}|$.a[1]\n");
    try c.expectRows("SELECT rowid, key, value FROM json_each('[5,6]', '$') UNION ALL SELECT count(*), 0, 0 FROM json_each('[1]', '$.x')", "0|0|5\n1|1|6\n0|0|0\n");
    try c.expectRows("SELECT count(*) FROM json_each(NULL), json_tree('[1]', NULL)", "0\n");
    // JSONB input and jsonb_each() values.
    try c.expectRows("SELECT key, hex(value), type FROM jsonb_each(jsonb('{\"a\":[1],\"b\":\"x\"}'))", "a|2B1331|array\nb|78|text\n");
    // A correlated argument, and the J subtype of container values.
    try c.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, j); INSERT INTO t VALUES(1, '[1,[2]]'), (2, '{\"k\":3}');");
    try c.expectRows("SELECT t.id, e.key, json_array(e.value) FROM t, json_each(t.j) AS e ORDER BY e.value", "1|0|[1]\n2|k|[3]\n1|1|[[2]]\n");
}

test "json: json_each errors and registration" {
    var c: Conn = undefined;
    try c.open();
    defer c.close();
    // The modules are registered on first use.
    try c.expectRows("SELECT count(*) FROM pragma_module_list WHERE name LIKE 'json%'", "0\n");
    try c.expectRows("SELECT count(*) FROM JSON_TREE('[1]'), jsonb_each('[2]')", "2\n");
    try c.expectRows("SELECT name FROM pragma_module_list WHERE name LIKE 'json%' ORDER BY 1", "json_tree\njsonb_each\n");
    try c.expectError("SELECT * FROM json_each('[1,')", "malformed JSON");
    try c.expectError("SELECT * FROM json_tree('[1]', 'a')", "bad JSON path: 'a'");
    try c.expectError("SELECT * FROM json_each('[1]', '$[')", "bad JSON path: '$['");
    try c.exec("CREATE TABLE obj(x)");
    try c.expectError("SELECT key FROM json_tree(obj.x) LEFT JOIN obj", "table-function argument references tables to its right");
    try c.expectError("CREATE VIRTUAL TABLE v USING json_each", "no such module: json_each");
}
