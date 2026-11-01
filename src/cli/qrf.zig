//! The query result formatter: renders the rows of a statement as text in
//! one of the shell's output styles (port of ext/qrf/qrf.c, without the
//! statistics and JSONB renderings).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const xqlite = @import("xqlite");
const api = xqlite.sql.api;
const printf = xqlite.printf;
const RC = xqlite.sql.RC;
const Stmt = xqlite.sql.Stmt;

const SQLITE_INTEGER = 1;
const SQLITE_FLOAT = 2;
const SQLITE_TEXT = 3;
const SQLITE_BLOB = 4;

pub const Style = enum(u8) {
    auto,
    box,
    column,
    count,
    csv,
    eqp,
    explain,
    html,
    insert,
    json,
    jobject,
    line,
    list,
    markdown,
    off,
    quote,
    stats,
    stats_est,
    stats_vm,
    table,
};

/// Quoting styles for text (QRF_TEXT_*).
pub const TextMode = enum(u8) { auto, plain, sql, csv, html, tcl, json, relaxed };
/// Quoting styles for BLOBs (QRF_BLOB_*).
pub const BlobMode = enum(u8) { auto, text, sql, hex, tcl, json, size };
/// Control-character escapes (QRF_ESC_*).
pub const Escape = enum(u8) { auto, off, ascii, symbol };
/// Tri-state settings (QRF_Auto/No/Yes); `always` is only for titles.
pub const Switch = enum(u8) { auto, no, yes, always };
/// Horizontal alignment (QRF_ALIGN_*).
pub const Align = enum(u8) { auto, left, center, right };

/// QRF_MAX_WIDTH.
pub const max_width = 10000;

/// Port of sqlite3_qrf_spec: how to render a result.
pub const Spec = struct {
    style: Style = .auto,
    text: TextMode = .auto,
    title: TextMode = .auto,
    blob: BlobMode = .auto,
    esc: Escape = .auto,
    titles: Switch = .auto,
    word_wrap: Switch = .auto,
    border: Switch = .auto,
    split_column: Switch = .auto,
    row_count: Switch = .auto,
    title_align: Align = .auto,
    dflt_align: Align = .auto,
    wrap: i32 = 0,
    screen_width: i32 = 0,
    line_limit: i32 = 0,
    char_limit: i32 = 0,
    title_limit: i32 = 0,
    multi_insert: u32 = 0,
    widths: []const i16 = &.{},
    aligns: []const Align = &.{},
    column_sep: ?[]const u8 = null,
    row_sep: ?[]const u8 = null,
    table_name: ?[]const u8 = null,
    null_text: ?[]const u8 = null,
    /// A printf format for floating point values (e.g. "%0.16g"), or null
    /// to use the text conversion of the value.
    fp_fmt: ?[]const u8 = null,
    /// xqlite: the types of result columns (the connection's cache). With
    /// it, a statement compiled in a dialect other than SQLite's shows the
    /// values of table columns as that dialect does (xqlite.display: a
    /// PostgreSQL boolean is t/f, a numeric(10,2) 1.50), except in the
    /// styles that write SQL or JSON values (quote, insert, json, jobject).
    columns: ?*xqlite.display.Columns = null,
};

pub const Error = error{ OutOfMemory, WriteFailed };

// ================================================================ helpers

const isSpace = std.ascii.isWhitespace;
const isDigit = std.ascii.isDigit;
/// qrfAlpha(): letters and '_'.
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

/// z[i], or 0 past the end (the C code reads NUL-terminated strings).
fn at(z: []const u8, i: usize) u8 {
    return if (i < z.len) z[i] else 0;
}

/// The text before the first NUL, as C sees a string.
fn cstr(z: []const u8) []const u8 {
    return std.mem.sliceTo(z, 0);
}

/// A growable string (sqlite3_str).
const Str = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,

    fn deinit(s: *Str) void {
        s.list.deinit(s.gpa);
    }
    fn len(s: *const Str) usize {
        return s.list.items.len;
    }
    fn append(s: *Str, z: []const u8) Error!void {
        try s.list.appendSlice(s.gpa, z);
    }
    fn appendChar(s: *Str, n: anytype, c: u8) Error!void {
        if (n <= 0) return;
        try s.list.appendNTimes(s.gpa, c, @intCast(n));
    }
    fn appendf(s: *Str, fmt: []const u8, args: []const printf.Arg) Error!void {
        try appendPrintf(s.gpa, &s.list, fmt, args);
    }
    /// Appends text formatted by std.fmt.
    fn print(s: *Str, comptime fmt: []const u8, args: anytype) Error!void {
        try s.list.print(s.gpa, fmt, args);
    }
    fn truncate(s: *Str, n: usize) void {
        s.list.shrinkRetainingCapacity(n);
    }
    fn toOwned(s: *Str) Error![]u8 {
        return s.list.toOwnedSlice(s.gpa);
    }
};

/// Appends the output of an SQLite printf format (sqlite3_str_appendf())
/// to `list`. Short results are formatted on the stack; only longer ones
/// need a temporary allocation.
pub fn appendPrintf(gpa: Allocator, list: *std.ArrayList(u8), fmt: []const u8, args: []const printf.Arg) Error!void {
    var base: [128]u8 = undefined;
    var acc = printf.StrAccum.init(gpa, &base, printf.max_length);
    defer acc.reset();
    acc.internal = true;
    printf.vappendf(&acc, fmt, .{ .list = args });
    if (acc.acc_error != 0) return error.OutOfMemory;
    try list.appendSlice(gpa, acc.slice());
}

/// Spans of Unicode code points with their display width (aQrfUWidth).
const uwidth = [_]struct { u8, u32 }{
    .{ 0, 0x00300 }, .{ 1, 0x00370 }, .{ 0, 0x00483 }, .{ 1, 0x00487 }, .{ 0, 0x00488 },
    .{ 1, 0x0048a }, .{ 0, 0x00591 }, .{ 1, 0x005be }, .{ 0, 0x005bf }, .{ 1, 0x005c0 },
    .{ 0, 0x005c1 }, .{ 1, 0x005c3 }, .{ 0, 0x005c4 }, .{ 1, 0x005c6 }, .{ 0, 0x005c7 },
    .{ 1, 0x005c8 }, .{ 0, 0x00600 }, .{ 1, 0x00604 }, .{ 0, 0x00610 }, .{ 1, 0x00616 },
    .{ 0, 0x0064b }, .{ 1, 0x0065f }, .{ 0, 0x00670 }, .{ 1, 0x00671 }, .{ 0, 0x006d6 },
    .{ 1, 0x006e5 }, .{ 0, 0x006e7 }, .{ 1, 0x006e9 }, .{ 0, 0x006ea }, .{ 1, 0x006ee },
    .{ 0, 0x0070f }, .{ 1, 0x00710 }, .{ 0, 0x00711 }, .{ 1, 0x00712 }, .{ 0, 0x00730 },
    .{ 1, 0x0074b }, .{ 0, 0x007a6 }, .{ 1, 0x007b1 }, .{ 0, 0x007eb }, .{ 1, 0x007f4 },
    .{ 0, 0x00901 }, .{ 1, 0x00903 }, .{ 0, 0x0093c }, .{ 1, 0x0093d }, .{ 0, 0x00941 },
    .{ 1, 0x00949 }, .{ 0, 0x0094d }, .{ 1, 0x0094e }, .{ 0, 0x00951 }, .{ 1, 0x00955 },
    .{ 0, 0x00962 }, .{ 1, 0x00964 }, .{ 0, 0x00981 }, .{ 1, 0x00982 }, .{ 0, 0x009bc },
    .{ 1, 0x009bd }, .{ 0, 0x009c1 }, .{ 1, 0x009c5 }, .{ 0, 0x009cd }, .{ 1, 0x009ce },
    .{ 0, 0x009e2 }, .{ 1, 0x009e4 }, .{ 0, 0x00a01 }, .{ 1, 0x00a03 }, .{ 0, 0x00a3c },
    .{ 1, 0x00a3d }, .{ 0, 0x00a41 }, .{ 1, 0x00a43 }, .{ 0, 0x00a47 }, .{ 1, 0x00a49 },
    .{ 0, 0x00a4b }, .{ 1, 0x00a4e }, .{ 0, 0x00a70 }, .{ 1, 0x00a72 }, .{ 0, 0x00a81 },
    .{ 1, 0x00a83 }, .{ 0, 0x00abc }, .{ 1, 0x00abd }, .{ 0, 0x00ac1 }, .{ 1, 0x00ac6 },
    .{ 0, 0x00ac7 }, .{ 1, 0x00ac9 }, .{ 0, 0x00acd }, .{ 1, 0x00ace }, .{ 0, 0x00ae2 },
    .{ 1, 0x00ae4 }, .{ 0, 0x00b01 }, .{ 1, 0x00b02 }, .{ 0, 0x00b3c }, .{ 1, 0x00b3d },
    .{ 0, 0x00b3f }, .{ 1, 0x00b40 }, .{ 0, 0x00b41 }, .{ 1, 0x00b44 }, .{ 0, 0x00b4d },
    .{ 1, 0x00b4e }, .{ 0, 0x00b56 }, .{ 1, 0x00b57 }, .{ 0, 0x00b82 }, .{ 1, 0x00b83 },
    .{ 0, 0x00bc0 }, .{ 1, 0x00bc1 }, .{ 0, 0x00bcd }, .{ 1, 0x00bce }, .{ 0, 0x00c3e },
    .{ 1, 0x00c41 }, .{ 0, 0x00c46 }, .{ 1, 0x00c49 }, .{ 0, 0x00c4a }, .{ 1, 0x00c4e },
    .{ 0, 0x00c55 }, .{ 1, 0x00c57 }, .{ 0, 0x00cbc }, .{ 1, 0x00cbd }, .{ 0, 0x00cbf },
    .{ 1, 0x00cc0 }, .{ 0, 0x00cc6 }, .{ 1, 0x00cc7 }, .{ 0, 0x00ccc }, .{ 1, 0x00cce },
    .{ 0, 0x00ce2 }, .{ 1, 0x00ce4 }, .{ 0, 0x00d41 }, .{ 1, 0x00d44 }, .{ 0, 0x00d4d },
    .{ 1, 0x00d4e }, .{ 0, 0x00dca }, .{ 1, 0x00dcb }, .{ 0, 0x00dd2 }, .{ 1, 0x00dd5 },
    .{ 0, 0x00dd6 }, .{ 1, 0x00dd7 }, .{ 0, 0x00e31 }, .{ 1, 0x00e32 }, .{ 0, 0x00e34 },
    .{ 1, 0x00e3b }, .{ 0, 0x00e47 }, .{ 1, 0x00e4f }, .{ 0, 0x00eb1 }, .{ 1, 0x00eb2 },
    .{ 0, 0x00eb4 }, .{ 1, 0x00eba }, .{ 0, 0x00ebb }, .{ 1, 0x00ebd }, .{ 0, 0x00ec8 },
    .{ 1, 0x00ece }, .{ 0, 0x00f18 }, .{ 1, 0x00f1a }, .{ 0, 0x00f35 }, .{ 1, 0x00f36 },
    .{ 0, 0x00f37 }, .{ 1, 0x00f38 }, .{ 0, 0x00f39 }, .{ 1, 0x00f3a }, .{ 0, 0x00f71 },
    .{ 1, 0x00f7f }, .{ 0, 0x00f80 }, .{ 1, 0x00f85 }, .{ 0, 0x00f86 }, .{ 1, 0x00f88 },
    .{ 0, 0x00f90 }, .{ 1, 0x00f98 }, .{ 0, 0x00f99 }, .{ 1, 0x00fbd }, .{ 0, 0x00fc6 },
    .{ 1, 0x00fc7 }, .{ 0, 0x0102d }, .{ 1, 0x01031 }, .{ 0, 0x01032 }, .{ 1, 0x01033 },
    .{ 0, 0x01036 }, .{ 1, 0x0103b }, .{ 0, 0x01058 }, .{ 1, 0x0105a }, .{ 2, 0x01100 },
    .{ 0, 0x01160 }, .{ 1, 0x01200 }, .{ 0, 0x0135f }, .{ 1, 0x01360 }, .{ 0, 0x01712 },
    .{ 1, 0x01715 }, .{ 0, 0x01732 }, .{ 1, 0x01735 }, .{ 0, 0x01752 }, .{ 1, 0x01754 },
    .{ 0, 0x01772 }, .{ 1, 0x01774 }, .{ 0, 0x017b4 }, .{ 1, 0x017b6 }, .{ 0, 0x017b7 },
    .{ 1, 0x017be }, .{ 0, 0x017c6 }, .{ 1, 0x017c7 }, .{ 0, 0x017c9 }, .{ 1, 0x017d4 },
    .{ 0, 0x017dd }, .{ 1, 0x017de }, .{ 0, 0x0180b }, .{ 1, 0x0180e }, .{ 0, 0x018a9 },
    .{ 1, 0x018aa }, .{ 0, 0x01920 }, .{ 1, 0x01923 }, .{ 0, 0x01927 }, .{ 1, 0x01929 },
    .{ 0, 0x01932 }, .{ 1, 0x01933 }, .{ 0, 0x01939 }, .{ 1, 0x0193c }, .{ 0, 0x01a17 },
    .{ 1, 0x01a19 }, .{ 0, 0x01b00 }, .{ 1, 0x01b04 }, .{ 0, 0x01b34 }, .{ 1, 0x01b35 },
    .{ 0, 0x01b36 }, .{ 1, 0x01b3b }, .{ 0, 0x01b3c }, .{ 1, 0x01b3d }, .{ 0, 0x01b42 },
    .{ 1, 0x01b43 }, .{ 0, 0x01b6b }, .{ 1, 0x01b74 }, .{ 0, 0x01dc0 }, .{ 1, 0x01dcb },
    .{ 0, 0x01dfe }, .{ 1, 0x01e00 }, .{ 0, 0x0200b }, .{ 1, 0x02010 }, .{ 0, 0x0202a },
    .{ 1, 0x0202f }, .{ 0, 0x02060 }, .{ 1, 0x02064 }, .{ 0, 0x0206a }, .{ 1, 0x02070 },
    .{ 0, 0x020d0 }, .{ 1, 0x020f0 }, .{ 2, 0x02329 }, .{ 1, 0x0232b }, .{ 2, 0x02e80 },
    .{ 0, 0x0302a }, .{ 2, 0x03030 }, .{ 1, 0x0303f }, .{ 2, 0x03040 }, .{ 0, 0x03099 },
    .{ 2, 0x0309b }, .{ 1, 0x0a4d0 }, .{ 0, 0x0a806 }, .{ 1, 0x0a807 }, .{ 0, 0x0a80b },
    .{ 1, 0x0a80c }, .{ 0, 0x0a825 }, .{ 1, 0x0a827 }, .{ 2, 0x0ac00 }, .{ 1, 0x0d7a4 },
    .{ 2, 0x0f900 }, .{ 1, 0x0fb00 }, .{ 0, 0x0fb1e }, .{ 1, 0x0fb1f }, .{ 0, 0x0fe00 },
    .{ 2, 0x0fe10 }, .{ 1, 0x0fe1a }, .{ 0, 0x0fe20 }, .{ 1, 0x0fe24 }, .{ 2, 0x0fe30 },
    .{ 1, 0x0fe70 }, .{ 0, 0x0feff }, .{ 2, 0x0ff00 }, .{ 1, 0x0ff61 }, .{ 2, 0x0ffe0 },
    .{ 1, 0x0ffe7 }, .{ 0, 0x0fff9 }, .{ 1, 0x0fffc }, .{ 0, 0x10a01 }, .{ 1, 0x10a04 },
    .{ 0, 0x10a05 }, .{ 1, 0x10a07 }, .{ 0, 0x10a0c }, .{ 1, 0x10a10 }, .{ 0, 0x10a38 },
    .{ 1, 0x10a3b }, .{ 0, 0x10a3f }, .{ 1, 0x10a40 }, .{ 0, 0x1d167 }, .{ 1, 0x1d16a },
    .{ 0, 0x1d173 }, .{ 1, 0x1d183 }, .{ 0, 0x1d185 }, .{ 1, 0x1d18c }, .{ 0, 0x1d1aa },
    .{ 1, 0x1d1ae }, .{ 0, 0x1d242 }, .{ 1, 0x1d245 }, .{ 2, 0x20000 }, .{ 1, 0x2fffe },
    .{ 2, 0x30000 }, .{ 1, 0x3fffe }, .{ 0, 0xe0001 }, .{ 1, 0xe0002 }, .{ 0, 0xe0020 },
    .{ 1, 0xe0080 }, .{ 0, 0xe0100 }, .{ 1, 0xe01f0 },
};

/// Port of sqlite3_qrf_wcwidth(): the display width of code point `c`.
pub fn wcwidth(c: u32) i32 {
    if (c < 0x300) return 1;
    var first: usize = 0;
    var last: usize = uwidth.len - 1;
    while (first + 1 < last) {
        const mid = (first + last) / 2;
        const c_mid = uwidth[mid][1];
        if (c_mid < c) {
            first = mid;
        } else if (c_mid > c) {
            last = mid - 1;
        } else {
            return uwidth[mid][0];
        }
    }
    if (uwidth[last][1] > c) return uwidth[first][0];
    return uwidth[last][0];
}

/// Port of sqlite3_qrf_decode_utf8(): the code point of the multi-byte
/// character at z[i] (0 if malformed) and its length.
fn decodeUtf8(z: []const u8, i: usize, u: *u32) usize {
    const c0: u32 = at(z, i);
    const c1: u32 = at(z, i + 1);
    const c2: u32 = at(z, i + 2);
    const c3: u32 = at(z, i + 3);
    if (c0 & 0xe0 == 0xc0 and c1 & 0xc0 == 0x80) {
        u.* = ((c0 & 0x1f) << 6) | (c1 & 0x3f);
        return 2;
    }
    if (c0 & 0xf0 == 0xe0 and c1 & 0xc0 == 0x80 and c2 & 0xc0 == 0x80) {
        u.* = ((c0 & 0x0f) << 12) | ((c1 & 0x3f) << 6) | (c2 & 0x3f);
        return 3;
    }
    if (c0 & 0xf8 == 0xf0 and c1 & 0xc0 == 0x80 and c2 & 0xc0 == 0x80 and c3 & 0xc0 == 0x80) {
        // (The C code masks the lead byte with 0x0f.)
        u.* = ((c0 & 0x0f) << 18) | ((c1 & 0x3f) << 12) | ((c2 & 0x3f) << 6) | (c3 & 0x3f);
        return 4;
    }
    u.* = 0;
    return 1;
}

/// Port of qrfIsVt100(): the length of the VT100 escape at z[i] (an ESC),
/// or 0.
fn vt100Len(z: []const u8, i: usize) usize {
    if (at(z, i + 1) != '[') return 0;
    var k: usize = 2;
    while (at(z, i + k) >= 0x30 and at(z, i + k) <= 0x3f) k += 1;
    while (at(z, i + k) >= 0x20 and at(z, i + k) <= 0x2f) k += 1;
    if (at(z, i + k) < 0x40 or at(z, i + k) > 0x7e) return 0;
    return k + 1;
}

/// Port of sqlite3_qrf_wcswidth(): the display width of `z`.
pub fn wcswidth(z: []const u8) i32 {
    var n: i32 = 0;
    var i: usize = 0;
    while (at(z, i) != 0) {
        const c = z[i];
        if (c < ' ') {
            const k = if (c == 0x1b) vt100Len(z, i) else 0;
            i += if (k > 0) k else 1;
        } else if (c & 0x80 == 0) {
            n += 1;
            i += 1;
        } else {
            var u: u32 = 0;
            i += decodeUtf8(z, i, &u);
            n += wcwidth(u);
        }
    }
    return n;
}

/// Port of qrfDisplayWidth(): the width of the widest line of z, and the
/// number of line breaks in it.
fn displayWidth(z: []const u8, n_nl: ?*i32) i32 {
    var mx: i32 = 0;
    var n: i32 = 0;
    var nl: i32 = 0;
    var i: usize = 0;
    while (i < z.len) {
        const c = z[i];
        if (c < ' ') {
            const k = if (c == 0x1b) vt100Len(z, i) else 0;
            if (k > 0) {
                i += k;
            } else {
                if (c == '\t') {
                    n = (n + 8) & ~@as(i32, 7);
                } else if (c == '\n' or c == '\r') {
                    nl += 1;
                    if (n > mx) mx = n;
                    n = 0;
                }
                i += 1;
            }
        } else if (c & 0x80 == 0) {
            n += 1;
            i += 1;
        } else {
            var u: u32 = 0;
            i += decodeUtf8(z, i, &u);
            n += wcwidth(u);
        }
    }
    if (mx > n) n = mx;
    if (n_nl) |p| p.* = nl;
    return n;
}

fn isEscapedCtrl(z: []const u8, i: usize) bool {
    const c = z[i];
    return c <= 0x1f and c != '\t' and c != '\n' and (c != '\r' or at(z, i + 1) != '\n');
}

/// Port of qrfEscape(): escape the control characters (other than tab,
/// newline and CR-LF) of s[start..] as ^X (ascii) or U+24xx (symbol).
pub fn escape(esc: Escape, s: *Str, start: usize) Error!void {
    const tail = s.list.items[start..];
    var n_ctrl: usize = 0;
    for (0..tail.len) |i| {
        if (isEscapedCtrl(tail, i)) n_ctrl += 1;
    }
    if (n_ctrl == 0) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(s.gpa);
    try out.ensureTotalCapacity(s.gpa, tail.len + n_ctrl * 2);
    for (0..tail.len) |i| {
        const c = tail[i];
        if (!isEscapedCtrl(tail, i)) {
            out.appendAssumeCapacity(c);
        } else if (esc == .symbol) {
            out.appendSliceAssumeCapacity(&.{ 0xe2, 0x90, 0x80 + c });
        } else {
            out.appendSliceAssumeCapacity(&.{ '^', 0x40 + c });
        }
    }
    s.truncate(start);
    try s.append(out.items);
}

/// Appends `z` to `list` with control characters escaped as by `esc`
/// (for text written outside of a query result, such as .schema output).
pub fn appendEscaped(gpa: Allocator, list: *std.ArrayList(u8), esc: Escape, z: []const u8) Error!void {
    var s: Str = .{ .gpa = gpa, .list = list.* };
    defer list.* = s.list;
    const start = s.len();
    try s.append(z);
    if (esc != .off) try escape(if (esc == .auto) .ascii else esc, &s, start);
}

/// Port of qrf_need_quote(): whether an identifier must be quoted.
pub fn needQuote(name: ?[]const u8) bool {
    const z = name orelse return true;
    if (z.len == 0 or !isAlpha(z[0])) return true;
    for (z) |c| if (!isAlnum(c)) return true;
    return isKeyword(z);
}

/// sqlite3_keyword_check().
pub fn isKeyword(z: []const u8) bool {
    const tk = xqlite.tokenize;
    return tk.keywordCode(z) != tk.keywordCode("xq__");
}

// ============================================================ formatter

const PerCol = struct {
    z: []const u8 = "",
    w: i32 = 0,
    mx_w: i32 = 0,
    e: Align = .auto,
    fx: bool = false,
    b_num: bool = false,
};

/// One line of EXPLAIN QUERY PLAN output (qrfEQPGraphRow).
const EqpRow = struct {
    id: i32,
    parent: i32,
    text: []u8,
};

const Qrf = struct {
    gpa: Allocator,
    stmt: *Stmt,
    w: *Writer,
    out: Str,
    i_err: i32 = RC.OK,
    err_msg: ?[]u8 = null,
    n_col: usize,
    mx_width: i32,
    mx_height: i32,
    n_row: i64 = 0,
    spec: Spec,
    line_cols: ?[][]u8 = null,
    line_mx_col_wth: i32 = 0,
    /// The value being rendered by the line style, reused for every row.
    line_val: Str,
    n_ins: u32 = 0,
    /// The EXPLAIN QUERY PLAN rows collected so far (qrfEQPGraph).
    eqp_rows: std.ArrayList(EqpRow) = .empty,
    /// xqlite: the type of each result column for display.text(), when
    /// the statement's dialect shows values otherwise than SQLite (else
    /// empty), and that dialect.
    col_types: []?xqlite.types.Type = &.{},
    viewer: xqlite.Dialect = .sqlite,

    /// xqlite: the value of column `i_col` as the statement's dialect
    /// shows it, if not as SQLite does.
    fn displayText(p: *Qrf, i_col: usize, buf: *[xqlite.display.max_len]u8) ?[]const u8 {
        if (i_col >= p.col_types.len) return null;
        const t = p.col_types[i_col] orelse return null;
        const cell: xqlite.Value = switch (api.columnType(p.stmt, i_col)) {
            SQLITE_INTEGER => .{ .integer = api.columnInt64(p.stmt, i_col) },
            SQLITE_FLOAT => .{ .float = api.columnDouble(p.stmt, i_col) },
            SQLITE_TEXT => .{ .text = if (api.columnText(p.stmt, i_col)) |z| cstr(z) else "" },
            else => return null,
        };
        return xqlite.display.text(p.viewer, t, cell, buf);
    }

    /// xqlite: col_types, for a statement of a dialect other than
    /// SQLite's in a style that shows values as text.
    fn initDisplay(p: *Qrf) Error!void {
        const columns = p.spec.columns orelse return;
        const viewer = p.stmt.xq_lang.dialect;
        if (viewer == .sqlite or p.n_col == 0) return;
        switch (p.spec.style) {
            .quote, .insert, .json, .jobject, .explain, .eqp, .count, .off, .stats, .stats_est, .stats_vm => return,
            else => {},
        }
        const t = try p.gpa.alloc(?xqlite.types.Type, p.n_col);
        for (t, 0..) |*x, i| x.* = if (try columns.get(p.stmt.db, p.stmt, i)) |e| e.type else null;
        p.col_types = t;
        p.viewer = viewer;
    }

    /// Port of qrfError().
    fn setError(p: *Qrf, code: i32, msg: []const u8) Error!void {
        p.i_err = code;
        if (p.err_msg) |m| p.gpa.free(m);
        p.err_msg = try p.gpa.dupe(u8, msg);
    }

    /// Port of qrfWrite(): send the accumulated output to the writer.
    fn write(p: *Qrf) Error!void {
        if (p.out.len() > 0) {
            try p.w.writeAll(p.out.list.items);
            p.out.truncate(0);
        }
    }

    fn columnName(p: *Qrf, i: usize) []const u8 {
        return if (api.columnName(p.stmt, i)) |z| cstr(z) else "";
    }

    fn colSep(p: *const Qrf) []const u8 {
        return p.spec.column_sep orelse ",";
    }
    fn rowSep(p: *const Qrf) []const u8 {
        return p.spec.row_sep orelse "\n";
    }
    fn nullText(p: *const Qrf) []const u8 {
        return p.spec.null_text orelse "";
    }
};

/// Port of qrfRelaxable(): whether z can be shown as plain text without
/// being mistaken for NULL, a number or quoted text.
fn relaxable(p: *const Qrf, z: []const u8) bool {
    if (z.len == 0) {
        const nul = p.spec.null_text;
        return nul != null and nul.?.len != 0;
    }
    if (z[0] == '\'' or isSpace(z[0])) return false;
    const n = z.len;
    if (z[n - 1] == '\'' or isSpace(z[n - 1])) return false;
    if (p.spec.null_text) |nul| if (std.mem.eql(u8, nul, z)) return false;
    var i: usize = @intFromBool(z[0] == '-' or z[0] == '+');
    if (std.mem.eql(u8, z[i..], "Inf")) return false;
    if (!isDigit(at(z, i))) return true;
    i += 1;
    while (isDigit(at(z, i))) i += 1;
    if (at(z, i) == 0) return false;
    if (at(z, i) == '.') {
        i += 1;
        while (isDigit(at(z, i))) i += 1;
        if (at(z, i) == 0) return false;
    }
    if (at(z, i) == 'e' or at(z, i) == 'E') {
        i += 1;
        if (at(z, i) == '+' or at(z, i) == '-') i += 1;
        if (!isDigit(at(z, i))) return true;
        i += 1;
        while (isDigit(at(z, i))) i += 1;
    }
    return at(z, i) != 0;
}

/// Characters that make a CSV field need quoting (qrfCsvQuote[]).
fn csvNeedsQuote(c: u8) bool {
    return c <= 0x20 or c == '"' or c == '\'' or c >= 0x7f;
}

/// Port of qrfEncodeText(): append text `z` encoded as spec.text says.
fn encodeText(p: *Qrf, s: *Str, z: []const u8) Error!void {
    const start = s.len();
    sw: switch (p.spec.text) {
        .relaxed => {
            if (relaxable(p, z)) {
                try s.append(z);
                break :sw;
            }
            continue :sw .sql;
        },
        .sql => try s.appendf(if (p.spec.esc == .off) "%Q" else "%#Q", &.{.{ .str = z }}),
        .csv => {
            // (An empty field is quoted too.)
            var quote = z.len == 0 or std.mem.indexOf(u8, z, p.colSep()) != null;
            for (z) |c| {
                if (csvNeedsQuote(c)) quote = true;
            }
            if (quote) {
                try s.append("\"");
                for (z) |c| {
                    if (c == '"') try s.append("\"");
                    try s.append(&.{c});
                }
                try s.append("\"");
            } else {
                try s.append(z);
            }
        },
        .html => {
            for (z) |c| switch (c) {
                '>' => try s.append("&gt;"),
                '&' => try s.append("&amp;"),
                '<' => try s.append("&lt;"),
                '"' => try s.append("&quot;"),
                '\'' => try s.append("&#39;"),
                else => try s.append(&.{c}),
            };
        },
        .tcl, .json => {
            try s.append("\"");
            for (z) |c| switch (c) {
                '"' => try s.append("\\\""),
                '\\' => try s.append("\\\\"),
                0x08 => try s.append("\\b"),
                0x0c => try s.append("\\f"),
                '\n' => try s.append("\\n"),
                '\r' => try s.append("\\r"),
                '\t' => try s.append("\\t"),
                else => if (c < 0x20) {
                    if (p.spec.text == .json) {
                        try s.print("\\u{x:0>4}", .{c});
                    } else {
                        try s.print("\\{o:0>3}", .{c});
                    }
                } else try s.append(&.{c}),
            };
            try s.append("\"");
        },
        else => try s.append(z),
    }
    if (p.spec.esc != .off) try escape(p.spec.esc, s, start);
}

const hex_digits = "0123456789abcdef";

/// Port of qrfRenderValue(): append the value of column `i_col`.
fn renderValue(p: *Qrf, s: *Str, i_col: usize) Error!void {
    const start = s.len();
    var display_buf: [xqlite.display.max_len]u8 = undefined;
    if (p.displayText(i_col, &display_buf)) |z| try s.append(z) else switch (api.columnType(p.stmt, i_col)) {
        SQLITE_INTEGER => {
            try s.print("{d}", .{api.columnInt64(p.stmt, i_col)});
        },
        SQLITE_FLOAT => {
            if (p.spec.fp_fmt) |fmt| {
                try s.appendf(fmt, &.{.{ .double = api.columnDouble(p.stmt, i_col) }});
            } else {
                try s.append(if (api.columnText(p.stmt, i_col)) |z| cstr(z) else "");
            }
        },
        SQLITE_BLOB => {
            const a = api.columnBlob(p.stmt, i_col) orelse "";
            switch (p.spec.blob) {
                .hex, .sql => {
                    if (p.spec.blob == .sql) try s.append("x'");
                    for (a) |c| try s.append(&.{ hex_digits[c >> 4], hex_digits[c & 0xf] });
                    if (p.spec.blob == .sql) try s.append("'");
                },
                .tcl, .json => {
                    try s.append("\"");
                    for (a) |c| {
                        if (p.spec.blob == .tcl) {
                            try s.append(&.{ '\\', '0' + (c >> 6), '0' + ((c >> 3) & 7), '0' + (c & 7) });
                        } else {
                            try s.append(&.{ '\\', 'u', '0', '0', hex_digits[c >> 4], hex_digits[c & 0xf] });
                        }
                    }
                    try s.append("\"");
                },
                .size => {
                    try s.print("({d}-byte blob)", .{a.len});
                },
                else => {
                    // The bytes as they are, with control characters escaped.
                    try s.append(a);
                    if (p.spec.esc != .off) try escape(p.spec.esc, s, start);
                },
            }
        },
        SQLITE_TEXT => try encodeText(p, s, if (api.columnText(p.stmt, i_col)) |z| cstr(z) else ""),
        else => try s.append(p.nullText()),
    }
    // Truncate values longer than spec.char_limit display characters.
    if (p.spec.char_limit > 0 and s.len() - start > @as(usize, @intCast(p.spec.char_limit))) {
        const z = s.list.items[start..];
        var ii: usize = 0;
        var w: i32 = 0;
        const limit = @max(p.spec.char_limit, 4);
        while (true) {
            const c = at(z, ii);
            if (c < ' ') {
                const k = if (c == 0x1b) vt100Len(z, ii) else 0;
                if (k > 0) {
                    ii += k;
                } else if (c == 0) {
                    break;
                } else {
                    ii += 1;
                }
            } else if (c & 0x80 == 0) {
                w += 1;
                if (w > limit) break;
                ii += 1;
            } else {
                var u: u32 = 0;
                const n = decodeUtf8(z, ii, &u);
                w += wcwidth(u);
                if (w > limit) break;
                ii += n;
            }
        }
        if (w > limit) {
            s.truncate(start + ii);
            try s.append("...");
        }
    }
}

/// Port of qrfTitleLimit(): shorten a title to at most `n` display
/// characters, ending it with "..." if cut, and turn tabs and line breaks
/// into spaces. Returns the new length of z and its display width.
fn titleLimit(z: []u8, n_max: i32) struct { usize, i32 } {
    var i: usize = 0;
    var n: i32 = 0;
    var ellipsis: ?usize = null;
    var end: usize = z.len;
    while (true) {
        const c = at(z, i);
        if (c < ' ') {
            if (c == 0) {
                ellipsis = null;
                end = i;
                break;
            }
            const k = if (c == 0x1b) vt100Len(z, i) else 0;
            if (k > 0) {
                i += k;
            } else if (c == '\t' or c == '\n' or c == '\r') {
                z[i] = ' ';
            } else {
                i += 1;
            }
        } else if (c & 0x80 == 0) {
            if (n >= n_max - 3 and ellipsis == null) ellipsis = i;
            if (n == n_max) {
                end = i;
                break;
            }
            n += 1;
            i += 1;
        } else {
            var u: u32 = 0;
            const len = decodeUtf8(z, i, &u);
            if (n + @as(i32, @intCast(len)) > n_max - 3 and ellipsis == null) ellipsis = i;
            if (n + @as(i32, @intCast(len)) > n_max) {
                end = i;
                break;
            }
            i += len;
            n += wcwidth(u);
        }
    }
    if (ellipsis) |e| if (n_max >= 3 and e + 3 <= z.len) {
        @memcpy(z[e..][0..3], "...");
        end = e + 3;
    };
    return .{ end, n };
}

/// Port of qrfRTrim(): drop trailing spaces.
fn rtrim(s: *Str) void {
    s.truncate(std.mem.trimEnd(u8, s.list.items, " ").len);
}

/// Port of qrfWidthPrint(): append z padded to |w| display characters,
/// right-justified when w < 0.
fn widthPrint(s: *Str, w_arg: i32, z: []const u8) Error!void {
    const w = std.math.clamp(w_arg, -10000000, 10000000);
    const aw: i32 = @intCast(@abs(w));
    var i: usize = 0;
    var n: i32 = 0;
    while (at(z, i) != 0) {
        const c = z[i];
        if (c & 0xc0 == 0xc0) {
            var u: u32 = 0;
            const len = decodeUtf8(z, i, &u);
            const x = wcwidth(u);
            if (x + n > aw) break;
            i += len;
            n += x;
        } else if (c == 0x1b and vt100Len(z, i) > 0) {
            i += vt100Len(z, i);
        } else if (n >= aw) {
            break;
        } else {
            n += 1;
            i += 1;
        }
    }
    if (n >= aw) {
        try s.append(z[0..i]);
    } else if (w < 0) {
        try s.appendChar(aw - n, ' ');
        try s.append(z[0..i]);
    } else {
        try s.append(z[0..i]);
        try s.appendChar(aw - n, ' ');
    }
}

const Wrapped = struct { this: usize, wide: i32, next: usize };

/// Port of qrfWrapLine(): how much of z fits on one line of width w, its
/// display width, and where the next line starts.
fn wrapLine(z: []const u8, w: i32, b_wrap: bool) Wrapped {
    if (at(z, 0) == 0) return .{ .this = 0, .wide = 0, .next = 0 };
    var n: i32 = 0;
    var i: usize = 0;
    var c: u8 = 0;
    while (n <= w) : (i += 1) {
        c = at(z, i);
        if (c >= 0xc0) {
            var u: u32 = 0;
            const len = decodeUtf8(z, i, &u);
            const wcw = wcwidth(u);
            if (wcw + n > w) break;
            i += len - 1;
            n += wcw;
            continue;
        }
        if (c >= ' ') {
            if (n == w) break;
            n += 1;
            continue;
        }
        if (c == 0 or c == '\n') break;
        if (c == '\r' and at(z, i + 1) == '\n') {
            i += 1;
            c = z[i];
            break;
        }
        if (c == '\t') {
            const wcw = 8 - (n & 7);
            if (n + wcw > w) break;
            n += wcw;
            continue;
        }
        const k = if (c == 0x1b) vt100Len(z, i) else 0;
        if (k > 0) {
            i += k - 1;
        } else if (n == w) {
            break;
        } else {
            n += 1;
        }
    }
    if (c == 0) return .{ .this = i, .wide = n, .next = i };
    if (c == '\n') return .{ .this = i, .wide = n, .next = i + 1 };

    // The line ends somewhere other than at a newline or the end: maybe
    // back up to a better place to break it.
    if (b_wrap and at(z, i) != 0 and !isSpace(z[i]) and isAlnum(c) == isAlnum(z[i])) {
        const half: isize = @intCast(i / 2);
        var k: isize = @as(isize, @intCast(i)) - 1;
        while (k >= half) : (k -= 1) {
            if (isSpace(z[@intCast(k)])) break;
        }
        if (k < half and half > 0) {
            k = @intCast(i);
            while (k >= half) : (k -= 1) {
                const ku: usize = @intCast(k);
                if (isAlnum(z[ku - 1]) != isAlnum(at(z, ku)) and at(z, ku) & 0xc0 != 0x80) break;
            }
        }
        if (k >= half) {
            i = @intCast(k);
            n = displayWidth(z[0..i], null);
        }
    }
    const this = i;
    while (at(z, i) == ' ' or at(z, i) == '\t' or at(z, i) == '\r') i += 1;
    return .{ .this = this, .wide = n, .next = i };
}

/// Port of qrfAppendWithTabs(): append z[0..n_val], expanding tabs and
/// showing other control characters as U+24xx symbols.
fn appendWithTabs(s: *Str, z_arg: []const u8, n_val_arg: usize) Error!void {
    var z = z_arg;
    var n_val = n_val_arg;
    var i: usize = 0;
    var col: u32 = 0;
    while (i < n_val) {
        const c = z[i];
        if (c < ' ') {
            try s.append(z[0..i]);
            n_val -= i;
            z = z[i..];
            i = 0;
            const k = if (c == 0x1b) vt100Len(z, 0) else 0;
            if (k > 0) {
                try s.append(z[0..k]);
                z = z[k..];
                n_val -= k;
            } else if (c == '\t') {
                const kk = 8 - (col & 7);
                try s.appendChar(kk, ' ');
                col += kk;
                z = z[1..];
                n_val -= 1;
            } else if (c == '\r' and n_val == 1) {
                z = z[1..];
                n_val -= 1;
            } else {
                col += 1;
                try s.append(&.{ 0xe2, 0x90, 0x80 + c });
                z = z[1..];
                n_val -= 1;
            }
        } else if (c & 0x80 == 0) {
            i += 1;
            col += 1;
        } else {
            var u: u32 = 0;
            i += decodeUtf8(z, i, &u);
            col +%= @intCast(wcwidth(u));
        }
    }
    try s.append(z[0..@min(i, z.len)]);
}

/// Port of qrfPrintAligned().
fn printAligned(s: *Str, col: *const PerCol, n_val: usize, n_ws: i32) Error!void {
    var e = col.e;
    if (e == .auto and col.b_num) e = .right;
    switch (e) {
        .center => {
            try s.appendChar(@divTrunc(n_ws, 2), ' ');
            try appendWithTabs(s, col.z, n_val);
            try s.appendChar(n_ws - @divTrunc(n_ws, 2), ' ');
        },
        .right => {
            try s.appendChar(n_ws, ' ');
            try appendWithTabs(s, col.z, n_val);
        },
        else => {
            try appendWithTabs(s, col.z, n_val);
            try s.appendChar(n_ws, ' ');
        },
    }
}

/// Columnar layout data (qrfColData).
const ColData = struct {
    n_col: usize,
    b_multi_row: bool = false,
    n_margin: i32 = 0,
    az: std.ArrayList([]const u8) = .empty,
    ai_wth: std.ArrayList(i32) = .empty,
    ab_num: std.ArrayList(bool) = .empty,
    a: []PerCol,
};

const box_24 = "\u{2500}";
const box_13 = "\u{2502}";
const box_123 = "\u{251c}";
const box_134 = "\u{2524}";
const box_234 = "\u{252c}";
const box_124 = "\u{2534}";
const box_1234 = "\u{253c}";
const box_r12 = "\u{2570}";
const box_r23 = "\u{256d}";
const box_r34 = "\u{256e}";
const box_r14 = "\u{256f}";
const dbl_24 = "\u{2550}";
const dbl_123 = "\u{255e}";
const dbl_134 = "\u{2561}";
const dbl_1234 = "\u{256a}";
const dbl_12 = "\u{2558}";
const dbl_14 = "\u{255b}";
const dbl_124 = "\u{2567}";

/// Port of qrfRowSeparator(): an ascii-art separator line.
fn rowSeparator(p: *Qrf, d: *const ColData, sep: u8) Error!void {
    if (d.n_col > 0) {
        const border = p.spec.border != .no;
        if (border) try p.out.append(&.{sep});
        try p.out.appendChar(d.a[0].w + d.n_margin, '-');
        for (d.a[1..]) |col| {
            try p.out.append(&.{sep});
            try p.out.appendChar(col.w + d.n_margin, '-');
        }
        if (border) try p.out.append(&.{sep});
    }
    try p.out.append("\n");
}

fn boxLine(s: *Str, n: i32, dbl: bool) Error!void {
    var i: i32 = 0;
    while (i < n) : (i += 1) try s.append(if (dbl) dbl_24 else box_24);
}

/// Port of qrfBoxSeparator().
fn boxSeparator(p: *Qrf, d: *const ColData, sep1: []const u8, sep2: []const u8, sep3: []const u8, dbl: bool) Error!void {
    if (d.n_col > 0) {
        const border = p.spec.border != .no;
        if (border) try p.out.append(sep1);
        try boxLine(&p.out, d.a[0].w + d.n_margin, dbl);
        for (d.a[1..]) |col| {
            try p.out.append(sep2);
            try boxLine(&p.out, col.w + d.n_margin, dbl);
        }
        if (border) try p.out.append(sep3);
    }
    try p.out.append("\n");
}

/// Port of qrfColumnSeparator(): the dashes under the titles in column
/// style.
fn columnSeparator(p: *Qrf, d: *const ColData, col_sep: []const u8, row_sep: []const u8) Error!void {
    for (d.a, 0..) |col, j| {
        try p.out.appendChar(col.w, '-');
        if (j < d.n_col - 1) {
            try p.out.append(col_sep);
        } else {
            rtrim(&p.out);
            try p.out.append(row_sep);
        }
    }
}

/// Port of qrfLoadAlignment(): the default alignment of the body.
fn loadAlignment(d: *ColData, p: *const Qrf) void {
    for (d.a, 0..) |*col, i| {
        col.e = p.spec.dflt_align;
        if (i < p.spec.aligns.len) {
            if (p.spec.aligns[i] != .auto) col.e = p.spec.aligns[i];
        } else if (i < p.spec.widths.len) {
            if (p.spec.widths[i] < 0) col.e = .right;
        }
    }
}

/// Port of qrfValidLayout(): the column widths if the single column of d
/// fits the screen as n_col columns, else null.
fn validLayout(arena: Allocator, d: *const ColData, n_col: usize, n_sw: i32) Error!?[]i32 {
    const aw = try arena.alloc(i32, n_col);
    const nr = (d.az.items.len + n_col - 1) / n_col;
    var w: i32 = 0;
    for (d.ai_wth.items, 0..) |wth, i| {
        if (i % nr == 0) {
            if (i > 0) aw[i / nr - 1] = w;
            w = wth;
        } else if (wth > w) {
            w = wth;
        }
    }
    aw[n_col - 1] = w;
    var t: i64 = 0;
    for (aw) |x| t += x;
    t += 2 * @as(i64, @intCast(n_col - 1));
    if (t > n_sw) return null;
    return aw;
}

/// Port of qrfSplitColumn(): lay out a single column side by side in as
/// many columns as fit the screen.
fn splitColumn(arena: Allocator, d: *ColData, p: *const Qrf) Error!void {
    var n_col: usize = 1;
    var aw: []i32 = &.{};
    var n_col_next: usize = 2;
    var n_row: usize = 1;
    const n = d.az.items.len;
    while (true) {
        const aw_new = try validLayout(arena, d, n_col_next, p.spec.screen_width) orelse break;
        aw = aw_new;
        n_col = n_col_next;
        n_row = (n + n_col - 1) / n_col;
        if (n_row == 1) break;
        n_col_next += 1;
        while ((n + n_col_next - 1) / n_col_next == n_row) n_col_next += 1;
    }
    if (n_col == 1) return;
    const total = n_row * n_col;
    const az = try arena.alloc([]const u8, total);
    const ai_wth = try arena.alloc(i32, total);
    const ab_num = try arena.alloc(bool, total);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const j = (i % n_row) * n_col + (i / n_row);
        if (i < n) {
            az[j] = d.az.items[i];
            ab_num[j] = d.ab_num.items[i];
            ai_wth[j] = d.ai_wth.items[i];
        } else {
            az[j] = "";
            ab_num[j] = false;
            ai_wth[j] = 0;
        }
    }
    const a = try arena.alloc(PerCol, n_col);
    var w: i32 = 0;
    for (a, 0..) |*col, k| {
        col.* = .{ .fx = true, .mx_w = aw[k], .w = aw[k], .e = d.a[0].e };
        w += aw[k];
    }
    d.az = .fromOwnedSlice(az);
    d.ai_wth = .fromOwnedSlice(ai_wth);
    d.ab_num = .fromOwnedSlice(ab_num);
    d.a = a;
    d.n_col = n_col;
    d.n_margin = @min(@divTrunc(p.spec.screen_width - w, @as(i32, @intCast(n_col - 1))), 5);
}

/// Port of qrfRestrictScreenWidth(): narrow columns to fit the screen.
fn restrictScreenWidth(d: *ColData, p: *const Qrf) void {
    d.n_margin = 2;
    if (p.spec.screen_width == 0) return;
    const n_col: i32 = @intCast(d.n_col);
    var sep_w: i32 = if (p.spec.style == .column) n_col * 2 - 2 else n_col * 3 + 1 - @as(i32, if (p.spec.border == .no) 2 else 0);
    var sum_w: i64 = 0;
    for (d.a) |col| sum_w += col.w;
    if (p.spec.screen_width >= sum_w + sep_w) return;

    d.n_margin = 0;
    sep_w = if (p.spec.style == .column) n_col - 1 else n_col + 1 - @as(i32, if (p.spec.border == .no) 2 else 0);
    const target_w = p.spec.screen_width - sep_w;
    const min_squoze = 8;
    const min_ex_squoze = 16;
    while (sum_w > target_w) {
        var ix: ?usize = null;
        var mx: i32 = 0;
        for (d.a, 0..) |col, i| {
            const w = col.w;
            if (!col.fx and w > mx and w > min_squoze and (w > min_ex_squoze or w * 2 > col.mx_w)) {
                ix = i;
                mx = w;
            }
        }
        const k = ix orelse break;
        var gain: i32 = if (mx >= min_squoze * 2) @divTrunc(mx, 2) else mx - min_squoze;
        if (sum_w - gain < target_w) gain = @intCast(sum_w - target_w);
        sum_w -= gain;
        d.a[k].w -= gain;
        d.b_multi_row = true;
    }
}

/// Port of qrfColumnar(): the box, column, markdown and table styles,
/// which read the whole result first to size the columns.
fn columnar(p: *Qrf) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rc = api.step(p.stmt);
    var n_column = p.n_col;
    if (n_column == 0) return;
    if (rc == RC.DONE) {
        if (p.spec.titles != .always) {
            if (p.spec.row_count == .yes) {
                try p.out.append("(0 rows)\n");
                try p.write();
            }
            return;
        }
    } else if (rc != RC.ROW) {
        return;
    }

    var d: ColData = .{ .n_col = n_column, .a = try arena.alloc(PerCol, n_column) };
    @memset(d.a, .{});

    if (p.spec.titles == .yes or p.spec.titles == .always) {
        const saved = p.spec.text;
        p.spec.text = p.spec.title;
        for (0..n_column) |i| {
            var s: Str = .{ .gpa = arena };
            try encodeText(p, &s, p.columnName(i));
            const z = try s.toOwned();
            var n_nl: i32 = 0;
            var w: i32 = undefined;
            var cell: []const u8 = z;
            if (p.spec.title_limit != 0) {
                const r = titleLimit(z, p.spec.title_limit);
                cell = z[0..r[0]];
                w = r[1];
            } else {
                w = displayWidth(z, &n_nl);
            }
            try d.az.append(arena, cell);
            try d.ai_wth.append(arena, w);
            try d.ab_num.append(arena, false);
            if (w > d.a[i].mx_w) d.a[i].mx_w = w;
            if (n_nl != 0) d.b_multi_row = true;
        }
        p.spec.text = saved;
    }

    while (rc == RC.ROW) {
        for (0..n_column) |i| {
            const e_type = api.columnType(p.stmt, i);
            var s: Str = .{ .gpa = arena };
            try renderValue(p, &s, i);
            const z = try s.toOwned();
            var n_nl: i32 = 0;
            const w = displayWidth(z, &n_nl);
            try d.az.append(arena, z);
            try d.ai_wth.append(arena, w);
            try d.ab_num.append(arena, e_type == SQLITE_INTEGER or e_type == SQLITE_FLOAT);
            if (w > d.a[i].mx_w) d.a[i].mx_w = w;
            if (n_nl != 0) d.b_multi_row = true;
        }
        p.n_row += 1;
        rc = api.step(p.stmt);
    }

    // The width and alignment of every column.
    if (p.spec.titles == .no) {
        loadAlignment(&d, p);
    } else {
        const e: Align = if (p.spec.title_align == .auto) .center else p.spec.title_align;
        for (d.a) |*col| col.e = e;
    }
    for (d.a, 0..) |*col, i| {
        var w: i32 = 0;
        if (i < p.spec.widths.len) {
            w = p.spec.widths[i];
            if (w == -32768) {
                w = 0;
                if (p.spec.aligns.len > i and p.spec.aligns[i] == .auto) col.e = .right;
            } else if (w < 0) {
                w = -w;
                if (p.spec.aligns.len > i and p.spec.aligns[i] == .auto) col.e = .right;
            }
            if (w != 0) col.fx = true;
        }
        if (w == 0) {
            w = col.mx_w;
            if (p.spec.wrap > 0 and w > p.spec.wrap) {
                w = p.spec.wrap;
                d.b_multi_row = true;
            }
        } else if ((!d.b_multi_row or w == 1) and col.mx_w > w) {
            d.b_multi_row = true;
            if (w == 1) w = 2;
        }
        col.w = w;
    }

    if (n_column == 1 and d.az.items.len > 1 and p.spec.split_column == .yes and
        p.spec.style == .column and p.spec.titles == .no and p.spec.screen_width > d.a[0].w + 3)
    {
        try splitColumn(arena, &d, p);
        n_column = d.n_col;
    } else {
        restrictScreenWidth(&d, p);
    }

    // The line across the top, and the row and column separators.
    var row_start: []const u8 = undefined;
    var col_sep: []const u8 = undefined;
    var row_sep: []const u8 = undefined;
    switch (p.spec.style) {
        .box => {
            if (d.n_margin != 0) {
                row_start = box_13 ++ " ";
                col_sep = " " ++ box_13 ++ " ";
                row_sep = " " ++ box_13 ++ "\n";
            } else {
                row_start = box_13;
                col_sep = box_13;
                row_sep = box_13 ++ "\n";
            }
            if (p.spec.border == .no) {
                row_start = row_start[3..];
                row_sep = "\n";
            } else {
                try boxSeparator(p, &d, box_r23, box_234, box_r34, false);
            }
        },
        .table => {
            if (d.n_margin != 0) {
                row_start = "| ";
                col_sep = " | ";
                row_sep = " |\n";
            } else {
                row_start = "|";
                col_sep = "|";
                row_sep = "|\n";
            }
            if (p.spec.border == .no) {
                row_start = row_start[1..];
                row_sep = "\n";
            } else {
                try rowSeparator(p, &d, '+');
            }
        },
        .column => {
            const spaces = "     ";
            row_start = "";
            col_sep = if (d.n_margin < 2) " " else if (d.n_margin <= 5) spaces[@intCast(5 - d.n_margin)..] else spaces;
            row_sep = "\n";
        },
        else => {
            if (d.n_margin != 0) {
                row_start = "| ";
                col_sep = " | ";
                row_sep = " |\n";
            } else {
                row_start = "|";
                col_sep = "|";
                row_sep = "|\n";
            }
        },
    }

    const b_ww = p.spec.word_wrap == .yes and d.b_multi_row;
    const b_rtrim = p.spec.style == .column or
        (p.spec.border == .no and (p.spec.style == .box or p.spec.style == .table));
    var i: usize = 0;
    while (i < d.az.items.len) : (i += n_column) {
        for (0..n_column) |j| {
            d.a[j].z = d.az.items[i + j];
            d.a[j].b_num = d.ab_num.items[i + j];
        }
        var more = false;
        var n_row: i32 = 0;
        while (true) {
            try p.out.append(row_start);
            more = false;
            for (0..n_column) |j| {
                const r = wrapLine(d.a[j].z, d.a[j].w, b_ww);
                try printAligned(&p.out, &d.a[j], r.this, d.a[j].w - r.wide);
                d.a[j].z = d.a[j].z[@min(r.next, d.a[j].z.len)..];
                if (at(d.a[j].z, 0) != 0) more = true;
                if (j < n_column - 1) {
                    try p.out.append(col_sep);
                } else {
                    if (b_rtrim) rtrim(&p.out);
                    try p.out.append(row_sep);
                }
            }
            n_row += 1;
            if (!(more and n_row < p.mx_height)) break;
        }
        if (more) {
            // Cut short by the line limit: show an ellipsis.
            try p.out.append(row_start);
            for (0..n_column) |j| {
                if (at(d.a[j].z, 0) == 0) {
                    try p.out.appendChar(d.a[j].w, ' ');
                } else {
                    const n_e: i32 = @min(3, d.a[j].w);
                    d.a[j].z = "...";
                    try printAligned(&p.out, &d.a[j], @intCast(n_e), d.a[j].w - n_e);
                }
                if (j < n_column - 1) {
                    try p.out.append(col_sep);
                } else {
                    if (b_rtrim) rtrim(&p.out);
                    try p.out.append(row_sep);
                }
            }
        }

        // The separator under the titles, or between rows.
        if ((i == 0 or d.b_multi_row) and i + n_column < d.az.items.len) {
            const title_sep = i == 0 and (p.spec.titles == .yes or p.spec.titles == .always);
            if (title_sep) loadAlignment(&d, p);
            switch (p.spec.style) {
                .table => if (title_sep or d.b_multi_row) try rowSeparator(p, &d, '+'),
                .box => {
                    if (title_sep) {
                        try boxSeparator(p, &d, dbl_123, dbl_1234, dbl_134, true);
                    } else if (d.b_multi_row) {
                        try boxSeparator(p, &d, box_123, box_1234, box_134, false);
                    }
                },
                .markdown => if (title_sep) try rowSeparator(p, &d, '|'),
                .column => {
                    if (title_sep) {
                        try columnSeparator(p, &d, col_sep, row_sep);
                    } else if (d.b_multi_row) {
                        rtrim(&p.out);
                        try p.out.append("\n");
                    }
                },
                else => {},
            }
        }
    }

    // The line across the bottom.
    if (p.spec.border != .no or p.n_row == 0) {
        switch (p.spec.style) {
            .box => if (p.n_row > 0)
                try boxSeparator(p, &d, box_r12, box_124, box_r14, false)
            else
                try boxSeparator(p, &d, dbl_12, dbl_124, dbl_14, true),
            .table => try rowSeparator(p, &d, '+'),
            .markdown => if (p.n_row == 0) try rowSeparator(p, &d, '|'),
            .column => if (p.n_row == 0) try columnSeparator(p, &d, col_sep, row_sep),
            else => {},
        }
    }
    if (p.spec.row_count == .yes) try appendRowCount(p, "(", ")\n");
    try p.write();
}

/// Appends "<pre>N row(s)<post>".
fn appendRowCount(p: *Qrf, pre: []const u8, post: []const u8) Error!void {
    try p.out.print("{s}{d} row{s}{s}", .{ pre, p.n_row, if (p.n_row == 1) "" else "s", post });
}

/// Port of qrfOneJsonRow().
fn oneJsonRow(p: *Qrf) Error!void {
    for (0..p.n_col) |i| {
        if (i > 0) try p.out.append(",");
        try encodeText(p, &p.out, p.columnName(i));
        try p.out.append(":");
        try renderValue(p, &p.out, i);
    }
    try p.write();
}

/// Port of qrfSimpleTitle(): the title row of the non-columnar styles.
fn simpleTitle(p: *Qrf) Error!void {
    switch (p.spec.style) {
        .html => {
            try p.out.append("<tr>");
            for (0..p.n_col) |i| {
                try p.out.append("\n<th>");
                try encodeText(p, &p.out, p.columnName(i));
            }
            try p.out.append("\n</tr>\n");
        },
        .quote, .list => {
            const saved = p.spec.text;
            p.spec.text = p.spec.title;
            for (0..p.n_col) |i| {
                if (i > 0) try p.out.append(p.colSep());
                try encodeText(p, &p.out, p.columnName(i));
            }
            try p.out.append(p.rowSep());
            try p.write();
            p.spec.text = saved;
        },
        else => {},
    }
}

/// Port of qrfOneSimpleRow(): render one row of a non-columnar style.
fn oneSimpleRow(p: *Qrf) Error!void {
    const titles = p.spec.titles == .yes or p.spec.titles == .always;
    switch (p.spec.style) {
        .off, .count => {},
        .eqp => {
            const line = if (api.columnText(p.stmt, 3)) |z| cstr(z) else "";
            if (line.len > 0 and line[0] == '-') try eqpRender(p);
            try eqpAppend(p, @truncate(api.columnInt64(p.stmt, 0)), @truncate(api.columnInt64(p.stmt, 1)), line);
        },
        .json => {
            try p.out.append(if (p.n_row == 0) "[{" else "},\n{");
            try oneJsonRow(p);
        },
        .jobject => {
            try p.out.append(if (p.n_row == 0) "{" else "}\n{");
            try oneJsonRow(p);
        },
        .html => {
            if (p.n_row == 0 and titles) try simpleTitle(p);
            try p.out.append("<tr>");
            for (0..p.n_col) |i| {
                try p.out.append("\n<td>");
                try renderValue(p, &p.out, i);
            }
            try p.out.append("\n</tr>\n");
            try p.write();
        },
        .insert => {
            const mx_ins = p.spec.multi_insert;
            const sz_start = p.out.len();
            if (p.n_ins == 0 or p.n_ins >= mx_ins) {
                if (p.n_ins != 0) {
                    try p.out.append(";\n");
                    p.n_ins = 0;
                }
                const tab = p.spec.table_name.?;
                if (needQuote(tab)) {
                    try p.out.appendf("INSERT INTO \"%w\"", &.{.{ .str = tab }});
                } else {
                    try p.out.append("INSERT INTO ");
                    try p.out.append(tab);
                }
                if (titles) {
                    for (0..p.n_col) |i| {
                        const name = p.columnName(i);
                        try p.out.append(if (i == 0) "(" else ",");
                        if (needQuote(name)) {
                            try p.out.appendf("\"%w\"", &.{.{ .str = name }});
                        } else {
                            try p.out.append(name);
                        }
                    }
                    try p.out.append(")");
                }
                try p.out.append(" VALUES(");
            } else {
                try p.out.append(",\n  (");
            }
            for (0..p.n_col) |i| {
                if (i > 0) try p.out.append(",");
                try renderValue(p, &p.out, i);
            }
            p.n_ins +%= @intCast(p.out.len() + 2 - sz_start);
            if (p.n_ins >= mx_ins) {
                try p.out.append(");\n");
                p.n_ins = 0;
            } else {
                try p.out.append(")");
            }
            try p.write();
        },
        .line => {
            if (p.line_cols == null) {
                const cols = try p.gpa.alloc([]u8, p.n_col);
                @memset(cols, &.{});
                p.line_cols = cols;
                p.line_mx_col_wth = 0;
                for (cols, 0..) |*c, i| {
                    const name = if (api.columnName(p.stmt, i)) |z| cstr(z) else "unknown";
                    c.* = try p.gpa.dupe(u8, name);
                    if (p.spec.title_limit > 0) {
                        const r = titleLimit(c.*, p.spec.title_limit);
                        const t = try p.gpa.dupe(u8, c.*[0..r[0]]);
                        p.gpa.free(c.*);
                        c.* = t;
                    }
                    const sz = wcswidth(c.*);
                    if (sz > p.line_mx_col_wth) p.line_mx_col_wth = sz;
                }
            }
            if (p.n_row != 0) try p.out.append("\n");
            const val = &p.line_val;
            const sep = p.colSep();
            const n_sep: i32 = @intCast(sep.len);
            const mx_w = p.mx_width -| (n_sep + p.line_mx_col_wth);
            const b_ww = p.spec.word_wrap == .yes;
            for (p.line_cols.?, 0..) |name, i| {
                var cnt: i32 = 0;
                try widthPrint(&p.out, -p.line_mx_col_wth, name);
                try p.out.append(sep);
                val.truncate(0);
                try renderValue(p, val, i);
                var z: []const u8 = val.list.items;
                while (true) {
                    var r = wrapLine(z, mx_w, b_ww);
                    if (cnt != 0) try p.out.appendChar(p.line_mx_col_wth + n_sep, ' ');
                    cnt += 1;
                    if (cnt > p.mx_height) {
                        z = "...";
                        r.this = 3;
                        r.next = 3;
                    }
                    try p.out.append(z[0..@min(r.this, z.len)]);
                    try p.out.append("\n");
                    z = z[@min(r.next, z.len)..];
                    if (at(z, 0) == 0) break;
                }
            }
            try p.write();
        },
        else => {
            if (p.n_row == 0 and titles) try simpleTitle(p);
            for (0..p.n_col) |i| {
                if (i > 0) try p.out.append(p.colSep());
                try renderValue(p, &p.out, i);
            }
            try p.out.append(p.rowSep());
            try p.write();
        },
    }
    p.n_row += 1;
}

/// Port of qrfInitialize(): fill in the defaults of the spec.
fn initialize(p: *Qrf) void {
    const s = &p.spec;
    p.mx_width = if (s.screen_width <= 0) std.math.maxInt(i32) else s.screen_width;
    p.mx_height = if (s.line_limit <= 0) std.math.maxInt(i32) else s.line_limit;
    if (s.style == .auto) {
        s.style = switch (api.stmtIsExplain(p.stmt)) {
            0 => .box,
            1 => .explain,
            else => .eqp,
        };
    }
    // sqlite3_stmt_explain() is not ported, so a statement can only be
    // rendered in the EXPLAIN style it was prepared with; the statistics
    // styles need scan status, which is not ported either.
    if ((s.style == .eqp and api.stmtIsExplain(p.stmt) != 2) or
        (s.style == .explain and api.stmtIsExplain(p.stmt) != 1) or
        s.style == .stats or s.style == .stats_est or s.style == .stats_vm)
    {
        s.style = .box;
    }
    switch (s.style) {
        .list => {
            if (s.column_sep == null) s.column_sep = "|";
            if (s.row_sep == null) s.row_sep = "\n";
        },
        .jobject, .json => {
            s.text = .json;
            s.null_text = "null";
            if (s.fp_fmt == null) s.fp_fmt = "%0.16g";
        },
        .html => {
            s.text = .html;
            s.null_text = "null";
        },
        .insert => {
            s.text = .sql;
            s.null_text = "NULL";
            if (s.table_name == null or s.table_name.?.len == 0) s.table_name = "tab";
            if (s.fp_fmt == null) s.fp_fmt = "%0.16g";
        },
        .line => {
            if (s.column_sep == null) s.column_sep = ": ";
        },
        .csv => {
            s.style = .list;
            s.text = .csv;
            s.column_sep = ",";
            s.row_sep = "\r\n";
            s.null_text = "";
            if (s.esc == .auto) s.esc = .off;
        },
        .quote => {
            s.text = .sql;
            s.null_text = "NULL";
            s.column_sep = ",";
            s.row_sep = "\n";
        },
        else => {},
    }
    if (s.esc == .auto) s.esc = .ascii;
    if (s.text == .auto) s.text = .plain;
    if (s.title == .auto) {
        s.title = switch (s.style) {
            .box, .column, .table => .plain,
            else => s.text,
        };
    }
    if (s.blob == .auto) {
        s.blob = switch (s.text) {
            .sql => .sql,
            .csv, .tcl => .tcl,
            .json => .json,
            else => .text,
        };
    }
    if (s.titles == .auto) {
        s.titles = switch (s.style) {
            .box, .csv, .column, .table, .markdown => .yes,
            else => .no,
        };
    }
    if (s.word_wrap == .auto) s.word_wrap = .yes;
    if (s.column_sep == null) s.column_sep = ",";
    if (s.row_sep == null) s.row_sep = "\n";
}

// ======================================================= EXPLAIN renderings

/// Port of qrfEqpAppend().
fn eqpAppend(p: *Qrf, id: i32, parent: i32, text: []const u8) Error!void {
    const z = try p.gpa.dupe(u8, text);
    errdefer p.gpa.free(z);
    try p.eqp_rows.append(p.gpa, .{ .id = id, .parent = parent, .text = z });
}

/// Port of qrfEqpReset().
fn eqpReset(p: *Qrf) void {
    for (p.eqp_rows.items) |r| p.gpa.free(r.text);
    p.eqp_rows.clearRetainingCapacity();
}

/// Port of qrfEqpNextRow(): the index of the next row after `old` (or the
/// first) whose parent is `id`.
fn eqpNextRow(p: *Qrf, id: i32, old: ?usize) ?usize {
    var i = if (old) |o| o + 1 else 0;
    while (i < p.eqp_rows.items.len) : (i += 1) {
        if (p.eqp_rows.items[i].parent == id) return i;
    }
    return null;
}

/// Port of qrfEqpRenderLevel(): the rows under `id`, with `prefix`
/// (at most 100 bytes, as zPrefix[]) before each.
fn eqpRenderLevel(p: *Qrf, id: i32, prefix: *[100]u8, n: usize) Error!void {
    var row = eqpNextRow(p, id, null);
    while (row) |r| {
        const next = eqpNextRow(p, id, r);
        try p.out.append(prefix[0..n]);
        try p.out.append(if (next != null) "|--" else "`--");
        try p.out.append(p.eqp_rows.items[r].text);
        try p.out.append("\n");
        if (n < prefix.len - 7) {
            @memcpy(prefix[n..][0..3], if (next != null) "|  " else "   ");
            try eqpRenderLevel(p, p.eqp_rows.items[r].id, prefix, n + 3);
        }
        row = next;
    }
}

/// Port of qrfEqpRender() (without the scan-status cycle counts): show
/// and reset the collected EXPLAIN QUERY PLAN rows.
fn eqpRender(p: *Qrf) Error!void {
    if (p.eqp_rows.items.len == 0) return;
    const first = p.eqp_rows.items[0];
    if (first.text.len > 0 and first.text[0] == '-') {
        if (p.eqp_rows.items.len == 1) return eqpReset(p);
        try p.out.append(first.text[@min(3, first.text.len)..]);
        try p.out.append("\n");
        p.gpa.free(first.text);
        _ = p.eqp_rows.orderedRemove(0);
    } else {
        try p.out.append("QUERY PLAN\n");
    }
    var prefix: [100]u8 = undefined;
    try eqpRenderLevel(p, 0, &prefix, 0);
    eqpReset(p);
}

/// Port of qrfExplain(): EXPLAIN output in aligned columns, with the
/// bodies of loops indented.
fn explain(p: *Qrf) Error!void {
    const next_ops = [_][]const u8{ "Next", "Prev", "VPrev", "VNext", "SorterNext", "Return" };
    const yield_ops = [_][]const u8{ "Yield", "SeekLT", "SeekGT", "RowSetRead", "Rewind" };
    const inArray = struct {
        fn f(z: []const u8, list: []const []const u8) bool {
            for (list) |x| if (std.mem.eql(u8, z, x)) return true;
            return false;
        }
    }.f;
    var indent: std.ArrayList(i32) = .empty;
    defer indent.deinit(p.gpa);
    var is_yield: std.ArrayList(bool) = .empty;
    defer is_yield.deinit(p.gpa);

    // First pass: the indentation of each opcode.
    var i_op: usize = 0;
    while (p.i_err == RC.OK and api.step(p.stmt) == RC.ROW) : (i_op += 1) {
        const addr = api.columnInt64(p.stmt, 0);
        const op = if (api.columnText(p.stmt, 1)) |z| cstr(z) else "";
        const p1 = api.columnInt64(p.stmt, 2);
        const p2 = api.columnInt64(p.stmt, 3);
        // p2 as an index into indent[]: they differ inside the sub-programs
        // of triggers and foreign keys.
        const p2op = p2 + (@as(i64, @intCast(i_op)) - addr);
        try is_yield.append(p.gpa, inArray(op, &yield_ops));
        try indent.append(p.gpa, 0);
        if (inArray(op, &next_ops) and p2op > 0) {
            var i: usize = @intCast(p2op);
            while (i < i_op) : (i += 1) indent.items[i] += 2;
        }
        if (std.mem.eql(u8, op, "Goto") and p2op < i_op and p2op >= 0 and (is_yield.items[@intCast(p2op)] or p1 != 0)) {
            var i: usize = @intCast(p2op);
            while (i < i_op) : (i += 1) indent.items[i] += 2;
        }
    }

    // Second pass: the output.
    _ = api.reset(p.stmt);
    if (p.i_err != RC.OK) return;
    const widths = [_]i32{ 4, 13, 4, 4, 4, 13, 2, 13 };
    const n_arg = @min(p.n_col, widths.len);
    i_op = 0;
    while (p.i_err == RC.OK and api.step(p.stmt) == RC.ROW) : (i_op += 1) {
        if (i_op == 0) {
            for (0..n_arg) |i| {
                try widthPrint(&p.out, widths[i], p.columnName(i));
                try p.out.append(if (i == n_arg - 1) "\n" else "  ");
            }
            for (0..n_arg) |i| {
                try p.out.appendChar(widths[i], '-');
                try p.out.append(if (i == n_arg - 1) "\n" else "  ");
            }
        }
        for (0..n_arg) |i| {
            var sep: []const u8 = "  ";
            var w = widths[i];
            if (i == n_arg - 1) w = 0;
            const val = if (api.columnText(p.stmt, i)) |z| cstr(z) else "";
            const len = wcswidth(val);
            if (len > w) {
                w = len;
                sep = " ";
            }
            if (i == 1 and i_op < indent.items.len) try p.out.appendChar(indent.items[i_op], ' ');
            try widthPrint(&p.out, w, val);
            try p.out.append(if (i == n_arg - 1) "\n" else sep);
        }
        p.n_row += 1;
    }
    try p.write();
}

/// Port of qrfFinalize().
fn finalize(p: *Qrf) Error!void {
    switch (p.spec.style) {
        .count => {
            try p.out.print("{d}\n", .{p.n_row});
        },
        .json => if (p.n_row > 0) try p.out.append("}]\n"),
        .jobject => if (p.n_row > 0) try p.out.append("}\n"),
        .insert => if (p.n_ins != 0) try p.out.append(";\n"),
        .eqp => try eqpRender(p),
        else => {},
    }
    try p.write();
}

/// Port of sqlite3_format_query_result(): run `stmt` (which must not
/// have been stepped) and write its rows to `w` as `spec` says. Returns
/// RC.OK or the error code; the message of an error, allocated with
/// `gpa`, is stored in `err_msg`.
pub fn format(gpa: Allocator, stmt: *Stmt, spec: Spec, w: *Writer, err_msg: *?[]u8) Error!i32 {
    var p: Qrf = .{
        .gpa = gpa,
        .stmt = stmt,
        .w = w,
        .out = .{ .gpa = gpa },
        .line_val = .{ .gpa = gpa },
        .n_col = api.columnCount(stmt),
        .mx_width = 0,
        .mx_height = 0,
        .spec = spec,
    };
    defer {
        p.out.deinit();
        p.line_val.deinit();
        eqpReset(&p);
        p.eqp_rows.deinit(gpa);
        gpa.free(p.col_types);
        if (p.line_cols) |cols| {
            for (cols) |c| gpa.free(c);
            gpa.free(cols);
        }
    }
    errdefer if (p.err_msg) |m| gpa.free(m);
    initialize(&p);
    try p.initDisplay();
    switch (p.spec.style) {
        .box, .column, .markdown, .table => try columnar(&p),
        .explain => try explain(&p),
        else => {
            while (api.step(stmt) == RC.ROW) try oneSimpleRow(&p);
            if (p.n_col > 0 and p.n_row == 0 and p.spec.titles == .always) try simpleTitle(&p);
            if (p.n_col > 0 and p.spec.row_count == .yes) {
                switch (p.spec.style) {
                    .line, .csv, .list, .quote => {
                        if (p.spec.style == .line and p.n_row > 0) try p.out.append("\n");
                        try appendRowCount(&p, "(", ")\n");
                    },
                    .html => try appendRowCount(&p, "<!-- ", " -->\n"),
                    .insert => try appendRowCount(&p, "/* ", " inserted */\n"),
                    else => {},
                }
            }
        },
    }
    // Port of qrfResetStmt().
    const rc = api.reset(stmt);
    if (rc != RC.OK and p.i_err == RC.OK) try p.setError(rc, xqlite.sql.main.errmsg(stmt.db));
    try finalize(&p);
    err_msg.* = p.err_msg;
    return p.i_err;
}

test "wcwidth" {
    try std.testing.expectEqual(@as(i32, 1), wcwidth('a'));
    try std.testing.expectEqual(@as(i32, 2), wcwidth(0x6f22)); // 漢
    try std.testing.expectEqual(@as(i32, 0), wcwidth(0x0301));
    try std.testing.expectEqual(@as(i32, 6), wcswidth("ab\u{6f22}\u{5b57}"));
}

test "wrapLine" {
    const r = wrapLine("hello world", 7, true);
    try std.testing.expectEqual(@as(usize, 5), r.this);
    try std.testing.expectEqual(@as(usize, 6), r.next);
    const r2 = wrapLine("ab\ncd", 10, false);
    try std.testing.expectEqual(@as(usize, 2), r2.this);
    try std.testing.expectEqual(@as(usize, 3), r2.next);
}

test "relaxable" {
    var p: Qrf = undefined;
    p.spec = .{};
    try std.testing.expect(relaxable(&p, "abc"));
    try std.testing.expect(!relaxable(&p, "12"));
    try std.testing.expect(!relaxable(&p, "1.5e3"));
    try std.testing.expect(relaxable(&p, "1.5x"));
    try std.testing.expect(!relaxable(&p, " a"));
}
