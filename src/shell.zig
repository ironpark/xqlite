//! An interactive SQL shell compatible with the sqlite3 command-line
//! program (port of the parts of shell.c.in that do not need features
//! xqlite lacks): statement input, the output modes and the common
//! dot-commands.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const xqlite = @import("xqlite");
const qrf = @import("qrf.zig");

const sql = xqlite.sql;
const api = sql.api;
const RC = sql.RC;
const Stmt = sql.Stmt;
const Sqlite3 = sql.Sqlite3;
const incomplete = sql.complete.incomplete;

pub const Error = error{ OutOfMemory, WriteFailed, ReadFailed, ExitRequested };

// ================================================================= modes

// Display modes (MODE_*), indexes into mode_info.
const MODE_Insert = 7;
const MODE_List = 12;
const MODE_QBox = 16;
const MODE_Split = 18;
const MODE_Www = 22;
const MODE_BATCH = 50;
const MODE_TTY = 51;

const dflt_char_limit = 300;
const dflt_line_limit = 5;
const dflt_title_limit = 20;
const dflt_multi_insert = 3000;

/// Strings used by mode_info (aModeStr[]).
const mode_str = [_]?[]const u8{ null, "\n", "|", " ", ",", "\r\n", "\x1e", "\x1f", "\t", "", "NULL", "null", "\"\"", ": " };

/// Port of ModeInfo: the settings of a built-in display mode.
const ModeInfo = struct {
    name: []const u8,
    csep: u8,
    rsep: u8,
    null_: u8,
    text: qrf.TextMode,
    hdr: qrf.TextMode,
    blob: qrf.BlobMode,
    b_hdr: qrf.Switch,
    style: qrf.Style,
    /// 0 other, 1 line, 2 columnar.
    cx: u8,
    /// 1 border off, 2 split column, 4 row count.
    flg: u8,
};

fn mi(name: []const u8, csep: u8, rsep: u8, null_: u8, text: u8, hdr: u8, blob: u8, b_hdr: u8, style: u8, cx: u8, flg: u8) ModeInfo {
    return .{
        .name = name,
        .csep = csep,
        .rsep = rsep,
        .null_ = null_,
        .text = @fromBackingInt(@intCast(text)),
        .hdr = @fromBackingInt(@intCast(hdr)),
        .blob = @fromBackingInt(@intCast(blob)),
        .b_hdr = @fromBackingInt(@intCast(b_hdr)),
        .style = @fromBackingInt(@intCast(style)),
        .cx = cx,
        .flg = flg,
    };
}

/// aModeInfo[].
const mode_info = [_]ModeInfo{
    mi("ascii", 7, 6, 9, 1, 1, 0, 1, 12, 0, 0),
    mi("box", 0, 0, 9, 1, 1, 0, 3, 1, 2, 0),
    mi("c", 4, 1, 10, 5, 5, 4, 1, 12, 0, 0),
    mi("column", 0, 0, 9, 1, 1, 0, 3, 2, 2, 0),
    mi("count", 0, 0, 0, 0, 0, 0, 0, 3, 0, 0),
    mi("csv", 4, 5, 9, 3, 3, 0, 1, 12, 0, 0),
    mi("html", 0, 0, 9, 4, 4, 0, 3, 7, 0, 0),
    mi("insert", 0, 0, 10, 2, 2, 0, 1, 8, 0, 0),
    mi("jatom", 4, 1, 11, 6, 6, 0, 1, 12, 0, 0),
    mi("jobject", 0, 1, 11, 6, 6, 0, 0, 10, 0, 0),
    mi("json", 0, 0, 11, 6, 6, 0, 0, 9, 0, 0),
    mi("line", 13, 1, 9, 1, 1, 0, 0, 11, 1, 0),
    mi("list", 2, 1, 9, 1, 1, 0, 1, 12, 0, 0),
    mi("markdown", 0, 0, 9, 1, 1, 0, 3, 13, 2, 0),
    mi("off", 0, 0, 0, 0, 0, 0, 0, 14, 0, 0),
    mi("psql", 0, 0, 9, 1, 1, 0, 3, 19, 2, 5),
    mi("qbox", 0, 0, 10, 2, 1, 0, 3, 1, 2, 0),
    mi("quote", 4, 1, 10, 2, 2, 0, 1, 12, 0, 0),
    mi("split", 0, 0, 9, 1, 1, 0, 1, 2, 2, 2),
    mi("table", 0, 0, 9, 1, 1, 0, 3, 19, 2, 0),
    mi("tabs", 8, 1, 9, 3, 3, 0, 1, 12, 0, 0),
    mi("tcl", 3, 1, 12, 5, 5, 4, 1, 12, 0, 0),
    mi("www", 0, 0, 9, 4, 4, 0, 3, 7, 0, 0),
};

/// The owned optional strings of Mode.spec.
const mode_str_fields = .{ "column_sep", "row_sep", "table_name", "null_text" };

/// Port of Mode: how query results are shown. The strings and widths of
/// spec are owned (allocated with the shell's allocator).
const Mode = struct {
    e_mode: u8 = MODE_List,
    auto_screen_width: bool = false,
    /// MFLG_HDR: .headers has set spec.titles.
    hdr_set: bool = false,
    /// spec.bTextJsonb: kept for the .mode description only, as rendering
    /// JSONB blobs as JSON text is not ported.
    text_jsonb: qrf.Switch = .auto,
    /// autoExplain: render EXPLAIN and EXPLAIN QUERY PLAN specially.
    auto_explain: bool = true,
    spec: qrf.Spec = .{},

    /// Port of modeFree(): auto_explain survives.
    fn deinit(m: *Mode, gpa: Allocator) void {
        inline for (mode_str_fields) |f| {
            if (@field(m.spec, f)) |z| gpa.free(z);
        }
        gpa.free(m.spec.widths);
        m.* = .{ .auto_explain = m.auto_explain };
    }

    /// Port of modeDup().
    fn dup(m: *const Mode, gpa: Allocator) Allocator.Error!Mode {
        var r = m.*;
        inline for (mode_str_fields) |f| {
            @field(r.spec, f) = null;
        }
        r.spec.widths = &.{};
        errdefer r.deinit(gpa);
        inline for (mode_str_fields) |f| {
            if (@field(m.spec, f)) |z| @field(r.spec, f) = try gpa.dupe(u8, z);
        }
        r.spec.widths = try gpa.dupe(i16, m.spec.widths);
        return r;
    }
};

/// Port of modeSetStr().
fn setStr(gpa: Allocator, field: *?[]const u8, z: ?[]const u8) Allocator.Error!void {
    const new = if (z) |s| try gpa.dupe(u8, s) else null;
    if (field.*) |old| gpa.free(old);
    field.* = new;
}

// ================================================================= state

/// Port of ShellState, for the features ported.
pub const Shell = struct {
    gpa: Allocator,
    io: Io,
    db: *Sqlite3,
    db_filename: []const u8,
    out: *Io.Writer,
    err_out: *Io.Writer,
    stdin: *Io.Reader,
    mode: Mode = .{},
    mode_stack: std.ArrayList(Mode) = .empty,
    bail: bool = false,
    echo: bool = false,
    count_changes: bool = false,
    stdin_is_interactive: bool,
    stdout_is_console: bool,
    /// Name of the input being read: "<stdin>", "<cmdline>" or a file.
    in_file: ?[]const u8 = null,
    lineno: i64 = 0,
    input_nesting: u32 = 0,
    /// Errors seen by .dump.
    n_err: u32 = 0,
    writable_schema: bool = false,
    err_prefix: ?[]const u8 = null,
    exit_code: u8 = 0,
    // The parsed dot-command (p->dot).
    dot_orig: []const u8 = "",
    dot_copy: std.ArrayList(u8) = .empty,
    dot_args: std.ArrayList([]const u8) = .empty,
    dot_ofst: std.ArrayList(usize) = .empty,

    fn deinit(p: *Shell) void {
        p.mode.deinit(p.gpa);
        for (p.mode_stack.items) |*m| m.deinit(p.gpa);
        p.mode_stack.deinit(p.gpa);
        p.dot_copy.deinit(p.gpa);
        p.dot_args.deinit(p.gpa);
        p.dot_ofst.deinit(p.gpa);
    }

    fn print(p: *Shell, comptime fmt: []const u8, args: anytype) Error!void {
        try p.out.print(fmt, args);
    }

    /// Writes to standard error. Standard output is flushed first only
    /// on a terminal, as with the buffering of C stdio.
    fn eprint(p: *Shell, comptime fmt: []const u8, args: anytype) Error!void {
        if (p.stdout_is_console) try p.out.flush();
        try p.err_out.print(fmt, args);
        try p.err_out.flush();
    }

    /// Port of modeChange().
    fn modeChange(p: *Shell, e_mode: u8) Error!void {
        const gpa = p.gpa;
        if (e_mode < mode_info.len) {
            const info = &mode_info[e_mode];
            const m = &p.mode;
            m.e_mode = e_mode;
            if (info.csep != 0) try setStr(gpa, &m.spec.column_sep, mode_str[info.csep]);
            if (info.rsep != 0) try setStr(gpa, &m.spec.row_sep, mode_str[info.rsep]);
            if (info.null_ != 0) try setStr(gpa, &m.spec.null_text, mode_str[info.null_]);
            m.spec.text = info.text;
            m.spec.blob = info.blob;
            if (!m.hdr_set) m.spec.titles = info.b_hdr;
            m.spec.title = info.hdr;
            m.spec.border = if (info.flg & 1 != 0) .no else .auto;
            if (info.flg & 2 != 0) {
                m.spec.split_column = .yes;
                m.auto_screen_width = true;
            } else {
                m.spec.split_column = .no;
            }
            m.spec.row_count = if (info.flg & 4 != 0) .yes else .no;
        } else if (e_mode == MODE_BATCH) {
            const hdr = p.mode.hdr_set;
            p.mode.deinit(gpa);
            try p.modeChange(MODE_List);
            p.mode.hdr_set = hdr;
        } else if (e_mode == MODE_TTY) {
            const hdr = p.mode.hdr_set;
            p.mode.deinit(gpa);
            try p.modeChange(MODE_QBox);
            p.mode.auto_screen_width = true;
            p.mode.spec.text = .relaxed;
            p.mode.spec.char_limit = dflt_char_limit;
            p.mode.spec.line_limit = dflt_line_limit;
            p.mode.spec.title_limit = dflt_title_limit;
            p.mode.spec.multi_insert = dflt_multi_insert;
            p.mode.text_jsonb = .yes;
            p.mode.hdr_set = hdr;
        }
    }

    fn modePush(p: *Shell) Error!void {
        const m = try p.mode.dup(p.gpa);
        try p.mode_stack.append(p.gpa, m);
    }

    fn modePop(p: *Shell) void {
        const m = p.mode_stack.pop() orelse return;
        p.mode.deinit(p.gpa);
        p.mode = m;
    }

    /// Port of shellScreenWidth(): the width of the terminal on standard
    /// input, output or error, or 80.
    fn screenWidth(p: *Shell) i32 {
        for ([_]Io.File{ .stdin(), .stdout(), .stderr() }) |f| {
            var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
            const r = p.io.operate(.{ .device_io_control = .{
                .file = f,
                .code = std.posix.T.IOCGWINSZ,
                .arg = &ws,
            } }) catch continue;
            if (r.device_io_control >= 0) return ws.col;
        }
        return 80;
    }
};

// ============================================================ utilities

/// isspace() of the C locale.
const isSpace = std.ascii.isWhitespace;

fn skipSpace(z: []const u8) []const u8 {
    return std.mem.trimStart(u8, z, &std.ascii.whitespace);
}

/// Port of quoteChar(): '"' if the name must be quoted, else 0.
fn quoteChar(name: []const u8) u8 {
    return if (qrf.needQuote(name)) '"' else 0;
}

/// Port of appendText(): append z, quoted with `quote` if not 0.
fn appendText(gpa: Allocator, s: *std.ArrayList(u8), z: []const u8, quote: u8) Allocator.Error!void {
    if (quote == 0) return s.appendSlice(gpa, z);
    try s.append(gpa, quote);
    for (z) |c| {
        try s.append(gpa, c);
        if (c == quote) try s.append(gpa, quote);
    }
    try s.append(gpa, quote);
}

/// Port of appendCompletion(): what completes the statement `base`:
/// closing an open quote or comment and parentheses, and with
/// `semi` the final ";" (or ";END;" for a trigger).
fn appendCompletion(gpa: Allocator, s: *std.ArrayList(u8), base: []const u8, semi: bool, assume_nl: bool) Allocator.Error!void {
    const r = incomplete(base);
    const cc: u8 = @truncate(@as(u64, @bitCast(r)) >> 16);
    const n_paren: i32 = @truncate(r >> 32);
    const e_semi: u8 = @truncate(@as(u64, @bitCast(r)) >> 8);
    const e_stat: u8 = @truncate(@as(u64, @bitCast(r)));
    switch (cc) {
        0 => {},
        '-' => if (!assume_nl) try s.append(gpa, '\n'),
        '/' => try s.appendSlice(gpa, "*/"),
        else => try s.append(gpa, cc),
    }
    if (n_paren > 0) try s.appendNTimes(gpa, ')', @intCast(n_paren));
    if (e_stat != RC.OK and e_stat != RC.EMPTY) switch (e_semi) {
        1 => if (semi) try s.append(gpa, ';'),
        2 => try s.appendSlice(gpa, if (semi) "END;" else "END"),
        3 => try s.appendSlice(gpa, if (semi) ";END;" else ";END"),
        else => {},
    };
}

/// Port of resolve_backslashes(): expand C escapes in place, returning
/// the new length.
fn resolveBackslashes(z: []u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < z.len) : ({
        i += 1;
        j += 1;
    }) {
        var c = z[i];
        if (c == '\\' and i + 1 < z.len) {
            i += 1;
            c = z[i];
            switch (c) {
                'a' => c = 7,
                'b' => c = 8,
                't' => c = '\t',
                'n' => c = '\n',
                'v' => c = 11,
                'f' => c = 12,
                'r' => c = '\r',
                '"', '\'', '\\' => {},
                'x' => {
                    var hv: u8 = 0;
                    var nhd: usize = 0;
                    while (nhd < 2 and i + 1 + nhd < z.len) : (nhd += 1) {
                        const d = std.fmt.charToDigit(z[i + 1 + nhd], 16) catch break;
                        hv = (hv << 4) | d;
                    }
                    i += nhd;
                    c = hv;
                },
                '0'...'7' => {
                    c -= '0';
                    if (i + 1 < z.len and z[i + 1] >= '0' and z[i + 1] <= '7') {
                        i += 1;
                        c = (c << 3) +% (z[i] - '0');
                        if (i + 1 < z.len and z[i + 1] >= '0' and z[i + 1] <= '7') {
                            i += 1;
                            c = (c << 3) +% (z[i] - '0');
                        }
                    }
                },
                else => {},
            }
        }
        z[j] = c;
    }
    return j;
}

/// Port of integerValue(), without the size suffixes.
fn integerValue(z_arg: []const u8) i64 {
    var z = z_arg;
    var neg = false;
    if (z.len > 0 and (z[0] == '-' or z[0] == '+')) {
        neg = z[0] == '-';
        z = z[1..];
    }
    var v: i64 = 0;
    if (z.len > 2 and z[0] == '0' and (z[1] == 'x' or z[1] == 'X')) {
        for (z[2..]) |c| {
            const d = std.fmt.charToDigit(c, 16) catch break;
            v = v *% 16 +% d;
        }
    } else {
        for (z) |c| {
            if (c < '0' or c > '9') break;
            v = v *% 10 +% (c - '0');
        }
    }
    return if (neg) -%v else v;
}

/// Port of the .dbconfig command: show, or set and show, the
/// sqlite3_db_config() options.
fn dotDbconfig(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    const Choice = struct { name: []const u8, op: ?sql.main.DbConfig };
    const choices = [_]Choice{
        .{ .name = "attach_create", .op = .enable_attach_create },
        .{ .name = "attach_write", .op = .enable_attach_write },
        .{ .name = "comments", .op = .enable_comments },
        .{ .name = "defensive", .op = .defensive },
        .{ .name = "dqs_ddl", .op = .dqs_ddl },
        .{ .name = "dqs_dml", .op = .dqs_dml },
        .{ .name = "enable_fkey", .op = .enable_fkey },
        .{ .name = "enable_qpsg", .op = .enable_qpsg },
        .{ .name = "enable_trigger", .op = .enable_trigger },
        .{ .name = "enable_view", .op = .enable_view },
        .{ .name = "fts3_tokenizer", .op = .enable_fts3_tokenizer },
        // SQLITE_DBCONFIG_FP_DIGITS.
        .{ .name = "fp_digits", .op = null },
        .{ .name = "legacy_alter_table", .op = .legacy_alter_table },
        .{ .name = "legacy_file_format", .op = .legacy_file_format },
        .{ .name = "load_extension", .op = .enable_load_extension },
        .{ .name = "no_ckpt_on_close", .op = .no_ckpt_on_close },
        .{ .name = "reset_database", .op = .reset_database },
        .{ .name = "reverse_scanorder", .op = .reverse_scanorder },
        .{ .name = "stmt_scanstatus", .op = .stmt_scanstatus },
        .{ .name = "trigger_eqp", .op = .trigger_eqp },
        .{ .name = "trusted_schema", .op = .trusted_schema },
        .{ .name = "writable_schema", .op = .writable_schema },
    };
    var found = false;
    for (choices) |ch| {
        if (args.len > 1 and !std.mem.eql(u8, args[1], ch.name)) continue;
        found = true;
        if (ch.op) |op| {
            const onoff: i32 = if (args.len >= 3) @intFromBool(try booleanValue(p, args[2])) else -1;
            const v = sql.main.dbConfig(p.db, op, onoff);
            try p.print("{s:>19} {s}\n", .{ ch.name, if (v) "on" else "off" });
        } else {
            const v = sql.main.dbConfigFpDigits(p.db, if (args.len >= 3) @truncate(integerValue(args[2])) else -1);
            try p.print("{s:>19} {d}\n", .{ ch.name, v });
        }
        if (args.len > 1) break;
    }
    if (args.len > 1 and !found) {
        try dotCmdError(p, 1, "unknown dbconfig", "Enter \".dbconfig\" with no arguments for a list");
    }
}

/// Port of booleanValue().
fn booleanValue(p: *Shell, z: []const u8) Error!bool {
    var i: usize = 0;
    if (z.len > 1 and z[0] == '0' and z[1] == 'x') {
        i = 2;
        while (i < z.len and std.ascii.isHex(z[i])) i += 1;
    } else {
        while (i < z.len and std.ascii.isDigit(z[i])) i += 1;
    }
    if (i > 0 and i == z.len) return (integerValue(z) & 0xffffffff) != 0;
    if (std.ascii.eqlIgnoreCase(z, "on") or std.ascii.eqlIgnoreCase(z, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(z, "off") or std.ascii.eqlIgnoreCase(z, "no")) return false;
    try p.eprint("ERROR: Not a boolean value: \"{s}\". Assuming \"no\".\n", .{z});
    return false;
}

/// Port of optionMatch(): z is "-opt" or "--opt".
fn optionMatch(z_arg: []const u8, opt: []const u8) bool {
    var z = z_arg;
    if (z.len == 0 or z[0] != '-') return false;
    z = z[1..];
    if (z.len > 0 and z[0] == '-') z = z[1..];
    return std.mem.eql(u8, z, opt);
}

/// Port of pickStr(): the index of z in `choices`, or null.
fn pickStr(z: []const u8, choices: []const []const u8) ?usize {
    for (choices, 0..) |c, i| if (std.mem.eql(u8, z, c)) return i;
    return null;
}

/// Port of append_c_string(): z as a C string literal.
fn appendCString(gpa: Allocator, s: *std.ArrayList(u8), z: []const u8) Allocator.Error!void {
    try s.append(gpa, '"');
    for (z) |c| switch (c) {
        '\\', '"' => try s.appendSlice(gpa, &.{ '\\', c }),
        '\t' => try s.appendSlice(gpa, "\\t"),
        '\n' => try s.appendSlice(gpa, "\\n"),
        '\r' => try s.appendSlice(gpa, "\\r"),
        0x0c => try s.appendSlice(gpa, "\\f"),
        else => if (c < 0x20 or c == 0x7f) {
            try s.print(gpa, "\\{o:0>3}", .{c});
        } else try s.append(gpa, c),
    };
    try s.append(gpa, '"');
}

/// Port of sqlite3_strglob() for the patterns used here: "sqlite_stat?".
fn isStatTable(name: []const u8) bool {
    return name.len == 12 and std.mem.startsWith(u8, name, "sqlite_stat");
}

// ============================================================ execution

/// Port of shell_error_context(): two lines pointing at the error
/// position in `z`, or "".
fn errorContext(p: *Shell, s: *std.ArrayList(u8), z_arg: ?[]const u8) Allocator.Error!void {
    var z = z_arg orelse return;
    const off_raw = sql.main.errorOffset(p.db);
    if (off_raw < 0 or off_raw >= z.len) return;
    var off: usize = @intCast(off_raw);
    while (off > 50) {
        off -= 1;
        z = z[1..];
        while (z.len > 0 and z[0] & 0xc0 == 0x80) {
            z = z[1..];
            off -%= 1;
        }
    }
    var len = z.len;
    if (len > 78) {
        len = 78;
        while (len > 0 and z[len] & 0xc0 == 0x80) len -= 1;
    }
    try s.appendSlice(p.gpa, "\n  ");
    for (z[0..len]) |c| try s.append(p.gpa, if (isSpace(c)) ' ' else c);
    try s.appendSlice(p.gpa, "\n  ");
    if (off < 25) {
        try s.appendNTimes(p.gpa, ' ', off);
        try s.appendSlice(p.gpa, "^--- error here");
    } else {
        try s.appendNTimes(p.gpa, ' ', off - 14);
        try s.appendSlice(p.gpa, "error here ---^");
    }
}

/// Port of save_err_msg().
fn saveErrMsg(p: *Shell, phase: []const u8, rc: i32, z: ?[]const u8) Allocator.Error![]u8 {
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(p.gpa);
    try s.print(p.gpa, "{s}, {s}", .{ phase, sql.main.errmsg(p.db) });
    if (rc > 1) try s.print(p.gpa, " ({d})", .{rc});
    try errorContext(p, &s, z);
    return s.toOwnedSlice(p.gpa);
}

/// Port of shell_exec(): run every statement of `text`, showing results
/// as `mode` says. Returns RC.OK or the error code, with the message (if
/// `err_msg` is given) allocated with the shell's allocator.
fn shellExec(p: *Shell, mode: *const Mode, text: []const u8, err_msg: ?*?[]u8) Error!i32 {
    if (err_msg) |e| e.* = null;
    var spec = mode.spec;
    const style = mode_info[mode.e_mode].style;
    if (mode.auto_screen_width) spec.screen_width = p.screenWidth();
    if (spec.blob == .auto) {
        spec.blob = switch (spec.text) {
            .relaxed, .sql => .sql,
            .json => .json,
            else => .text,
        };
    }
    var z = text;
    var rc: i32 = RC.OK;
    while (z.len > 0 and rc == RC.OK) {
        var stmt_opt: ?*Stmt = null;
        var tail: []const u8 = "";
        rc = sql.prepare.prepareV2(p.db, z, &stmt_opt, &tail);
        if (rc != RC.OK) {
            if (err_msg) |e| e.* = try saveErrMsg(p, "in prepare", rc, z);
            continue;
        }
        const stmt = stmt_opt orelse {
            // A comment or white space.
            z = skipSpace(tail);
            continue;
        };
        spec.style = style;
        const is_explain = api.stmtIsExplain(stmt);
        if (is_explain != 0 and mode.auto_explain) spec.style = if (is_explain == 1) .explain else .eqp;
        var qerr: ?[]u8 = null;
        rc = qrf.format(p.gpa, stmt, spec, p.out, &qerr) catch |err| {
            _ = api.finalize(stmt);
            return err;
        };
        if (err_msg) |e| {
            e.* = qerr;
        } else if (qerr) |m| p.gpa.free(m);
        const rc2 = api.finalize(stmt);
        if (rc2 != RC.OK and rc != RC.NOMEM) rc = rc2;
        if (rc == RC.OK) {
            z = skipSpace(tail);
        } else if (err_msg) |e| {
            if (e.* == null) e.* = try saveErrMsg(p, "stepping", rc, null);
        }
    }
    return rc;
}

/// Port of runOneSqlLine(): run `text` read from `file` at line
/// `startline`, reporting an error. Returns the number of errors.
fn runOneSqlLine(p: *Shell, text: []const u8, file: ?[]const u8, startline: i64) Error!u32 {
    var err_msg: ?[]u8 = null;
    const rc = try shellExec(p, &p.mode, text, &err_msg);
    defer if (err_msg) |m| p.gpa.free(m);
    if (rc != RC.OK or err_msg != null) {
        var kind: []const u8 = "Error";
        var tail: []const u8 = undefined;
        if (err_msg) |m| {
            if (std.mem.startsWith(u8, m, "in prepare, ")) {
                kind = "Parse error";
                tail = m[12..];
            } else if (std.mem.startsWith(u8, m, "stepping, ")) {
                kind = "Runtime error";
                tail = m[10..];
            } else {
                tail = m;
            }
        } else {
            tail = sql.main.errmsg(p.db);
        }
        if (file != null or !p.stdin_is_interactive) {
            const f = file orelse "";
            if (std.mem.eql(u8, f, "cmdline")) {
                try p.eprint("{s} in {f} command line argument: {s}\n", .{ kind, xqlite.sql_util.ordinal(@intCast(startline)), tail });
            } else if (std.mem.eql(u8, f, "<stdin>")) {
                try p.eprint("{s} near line {d}: {s}\n", .{ kind, startline, tail });
            } else {
                try p.eprint("{s} near line {d} of {s}: {s}\n", .{ kind, startline, f, tail });
            }
        } else {
            try p.eprint("{s}: {s}\n", .{ kind, tail });
        }
        return 1;
    } else if (p.count_changes) {
        try p.print("changes: {d}   total_changes: {d}\n", .{ api.changes(p.db), api.totalChanges(p.db) });
    }
    return 0;
}

fn echoGroupInput(p: *Shell, z: []const u8) Error!void {
    if (p.echo) {
        try p.print("{s}\n", .{z});
        try p.out.flush();
    }
}

fn lineIsAllWhitespace(z: []const u8) bool {
    var i: usize = 0;
    while (i < z.len) {
        if (isSpace(z[i])) {
            i += 1;
            continue;
        }
        if (z[i] == '-' and i + 1 < z.len and z[i + 1] == '-') {
            i += 2;
            while (i < z.len and z[i] != '\n') i += 1;
            if (i == z.len) return true;
            i += 1;
            continue;
        }
        return false;
    }
    return true;
}

/// xqlite: whether `z` is a T-SQL GO line: GO (any case) and an optional
/// count, between spaces.
fn isGoLine(z: []const u8) bool {
    const t = std.mem.trim(u8, z, " \t\r");
    if (t.len < 2 or !std.ascii.eqlIgnoreCase(t[0..2], "GO")) return false;
    const rest = std.mem.trim(u8, t[2..], " \t");
    for (rest) |c| if (!std.ascii.isDigit(c)) return false;
    return t.len == 2 or t[2] == ' ' or t[2] == '\t';
}

/// Port of line_is_complete(): `z` is complete SQL, possibly followed by
/// white space or a "--" comment.
fn lineIsComplete(gpa: Allocator, z: []const u8) Allocator.Error!bool {
    const x = incomplete(z);
    if (x == 0 or x == 0x10) return true;
    if (x == 0x2d0001) {
        const with_nl = try std.mem.concat(gpa, u8, &.{ z, "\n" });
        defer gpa.free(with_nl);
        const y = incomplete(with_nl);
        if (y == 0 or y == 0x10) return true;
    }
    return false;
}

/// Port of local_getline(): read one line into `buf`, without its line
/// ending. Returns false at the end of input.
fn readLine(gpa: Allocator, r: *Io.Reader, buf: *std.ArrayList(u8)) Error!bool {
    buf.clearRetainingCapacity();
    var got_any = false;
    while (true) {
        const chunk = r.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return got_any,
            error.ReadFailed => return error.ReadFailed,
        };
        got_any = true;
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |k| {
            try buf.appendSlice(gpa, chunk[0..k]);
            r.toss(k + 1);
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\r') _ = buf.pop();
            return true;
        }
        try buf.appendSlice(gpa, chunk);
        r.toss(chunk.len);
    }
}

/// Port of process_input(): read and run statements and dot-commands
/// from `in` (null: standard input, with prompts). Returns the number of
/// errors (as 0 or 1).
fn processInput(p: *Shell, in: ?*Io.Reader, src: []const u8) Error!u32 {
    if (p.input_nesting == 25) {
        try p.eprint("{s}: Input nesting limit (25) reached at line {d}. Check recursion.\n", .{ src, p.lineno });
        return 1;
    }
    p.input_nesting += 1;
    const saved_in_file = p.in_file;
    const saved_lineno = p.lineno;
    p.in_file = src;
    p.lineno = 0;
    defer {
        p.input_nesting -= 1;
        p.in_file = saved_in_file;
        p.lineno = saved_lineno;
    }
    const interactive = in == null and p.stdin_is_interactive;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(p.gpa);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(p.gpa);
    var err_cnt: u32 = 0;
    // Never reset, as in the C code (hasSemi in process_input()): once a
    // line has had a ';', every later line checks for a complete statement.
    var has_semi = false;
    var startline: i64 = 0;
    while (err_cnt == 0 or !p.bail or interactive) {
        try p.out.flush();
        if (interactive) {
            try p.out.writeAll(if (text.items.len > 0) "   ...> " else "sqlite> ");
            try p.out.flush();
        }
        if (!try readLine(p.gpa, in orelse p.stdin, &line)) {
            if (interactive) try p.out.writeAll("\n");
            break;
        }
        p.lineno += 1;
        const z = line.items;
        if (text.items.len == 0 and lineIsAllWhitespace(z)) {
            try echoGroupInput(p, z);
            continue;
        }
        if (text.items.len == 0 and z.len > 0 and (z[0] == '.' or z[0] == '#')) {
            try echoGroupInput(p, z);
            if (z[0] == '.') {
                const rc = try doMetaCommand(p, z);
                if (rc == 2) break;
                if (rc != 0) err_cnt += 1;
            }
            continue;
        }
        // xqlite: in the T-SQL dialect a line holding only GO (SQL
        // Server's batch separator) ends the statement before it.
        if (sql.main.getDialect(p.db) == .mssql and isGoLine(z)) {
            if (text.items.len > 0) {
                try echoGroupInput(p, text.items);
                err_cnt += try runOneSqlLine(p, text.items, p.in_file, startline);
                text.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.indexOfScalar(u8, z, ';') != null) has_semi = true;
        if (text.items.len == 0) {
            try text.appendSlice(p.gpa, skipSpace(z));
            startline = p.lineno;
        } else {
            try text.append(p.gpa, '\n');
            try text.appendSlice(p.gpa, z);
        }
        if (text.items.len > 0 and has_semi and try lineIsComplete(p.gpa, text.items)) {
            try echoGroupInput(p, text.items);
            err_cnt += try runOneSqlLine(p, text.items, p.in_file, startline);
            text.clearRetainingCapacity();
        } else if (text.items.len > 0 and lineIsAllWhitespace(text.items)) {
            try echoGroupInput(p, text.items);
            text.clearRetainingCapacity();
        }
    }
    if (text.items.len > 0) {
        // Perhaps incomplete: let the parser report that.
        try echoGroupInput(p, text.items);
        err_cnt += try runOneSqlLine(p, text.items, p.in_file, startline);
    }
    return @intFromBool(err_cnt > 0);
}

// ========================================================= dot-commands

/// Port of parseDotCmdArgs(): split a dot-command into arguments.
fn parseDotCmdArgs(p: *Shell, line: []const u8) Allocator.Error!void {
    const gpa = p.gpa;
    p.dot_orig = line;
    p.dot_copy.clearRetainingCapacity();
    p.dot_args.clearRetainingCapacity();
    p.dot_ofst.clearRetainingCapacity();
    try p.dot_copy.appendSlice(gpa, line);
    var z = p.dot_copy.items;
    var n = z.len;
    while (n > 0 and isSpace(z[n - 1])) n -= 1;
    if (n > 0 and z[n - 1] == ';') {
        n -= 1;
        while (n > 0 and isSpace(z[n - 1])) n -= 1;
    }
    z = z[0..n];
    var h: usize = 1;
    while (h < z.len) {
        while (h < z.len and isSpace(z[h])) h += 1;
        if (h >= z.len) break;
        if (z[h] == '\'' or z[h] == '"') {
            const delim = z[h];
            h += 1;
            const start = h;
            while (h < z.len and z[h] != delim) {
                if (z[h] == '\\' and delim == '"' and h + 1 < z.len) h += 1;
                h += 1;
            }
            var arg = z[start..h];
            if (h < z.len) h += 1;
            if (delim == '"') arg = arg[0..resolveBackslashes(arg)];
            try p.dot_args.append(gpa, arg);
            try p.dot_ofst.append(gpa, start);
        } else {
            const start = h;
            while (h < z.len and !isSpace(z[h])) h += 1;
            try p.dot_args.append(gpa, z[start..h]);
            try p.dot_ofst.append(gpa, start);
            if (h < z.len) h += 1;
        }
    }
}

/// Port of shellErrorLocation().
fn errorLocation(p: *Shell, buf: []u8) []const u8 {
    if (p.err_prefix) |e| return e;
    const f = p.in_file orelse "<stdin>";
    if (std.mem.eql(u8, f, "<stdin>")) return std.fmt.bufPrint(buf, "line {d}:", .{p.lineno}) catch buf;
    return std.fmt.bufPrint(buf, "{s}:{d}:", .{ f, p.lineno }) catch buf;
}

/// Port of dotCmdError(): point at argument `i_arg` of the dot-command.
fn dotCmdError(p: *Shell, i_arg: usize, brief: ?[]const u8, detail: ?[]const u8) Error!void {
    var buf: [600]u8 = undefined;
    const loc = errorLocation(p, &buf);
    if (brief) |b| if (i_arg < p.dot_args.items.len) {
        const i = p.dot_ofst.items[i_arg];
        const n_prompt = b.len + 5;
        try p.eprint("{s} {s}\n", .{ loc, p.dot_orig });
        if (i > n_prompt) {
            try p.eprint("{s} {[2]s: >[3]}{[1]s} ---^\n", .{ loc, b, "", 1 + i - n_prompt });
        } else {
            try p.eprint("{s} {[2]s: >[3]}^--- {[1]s}\n", .{ loc, b, "", i });
        }
    };
    if (detail) |d| try p.eprint("{s} {s}\n", .{ loc, d });
}

/// The help text of the commands supported (a subset of azHelp[]).
const help_text = [_][]const u8{
    ".backup ?DB? FILE        Backup DB (default \"main\") to FILE",
    "   Options:",
    "       --async             Write to FILE without journal and fsync()",
    ".bail on|off             Stop after hitting an error.  Default OFF",
    ".changes on|off          Show number of rows changed by SQL",
    ".dialect ?NAME?          Show or set the SQL dialect: sqlite, postgres, mariadb",
    ".dump ?OBJECTS?          Render database content as SQL",
    "   Options:",
    "     --data-only            Output only INSERT statements",
    "     --newlines             Allow unescaped newline characters in output",
    "     --nosys                Omit system tables (ex: \"sqlite_stat1\")",
    "   OBJECTS is a LIKE pattern for tables, indexes, triggers or views to dump",
    ".echo on|off             Turn command echo on or off",
    ".exit ?CODE?             Exit this program with return-code CODE",
    ".headers on|off          Turn display of headers on or off",
    ".help ?-all? ?PATTERN?   Show help text for PATTERN",
    ".indexes ?PATTERN?       Show names of indexes matching PATTERN",
    "   -a|--all                 Also show system-generated indexes",
    "   --sys                    Show only system-generated indexes",
    ".mode ?MODE? ?OPTIONS?   Set output mode",
    ".nullvalue STRING        Use STRING in place of NULL values",
    ".print STRING...         Print literal STRING",
    ".quit                    Stop interpreting input stream, exit if primary.",
    ".read FILE               Read input from FILE or command output",
    ".restore ?DB? FILE       Restore content of DB (default \"main\") from FILE",
    ".save ?OPTIONS? FILE     Write database to FILE (an alias for .backup ...)",
    ".schema ?PATTERN?        Show the CREATE statements matching PATTERN",
    "   Options:",
    "      --indent             Try to pretty-print the schema",
    "      --nosys              Omit objects whose names start with \"sqlite_\"",
    ".tables ?TABLE?          List names of tables matching LIKE pattern TABLE",
    ".timeout MS              Try opening locked tables for MS milliseconds",
};

/// Port of showHelp(), for the first-line and prefix forms. Returns the
/// number of commands shown.
fn showHelp(p: *Shell, pattern_arg: ?[]const u8) Error!usize {
    const pattern = pattern_arg orelse {
        for (help_text) |h| if (h[0] == '.') try p.print("{s}\n", .{h});
        return help_text.len;
    };
    const all = std.mem.eql(u8, pattern, "-a") or std.mem.eql(u8, pattern, "-all") or std.mem.eql(u8, pattern, "--all");
    const pat = if (pattern.len > 0 and pattern[0] == '.') pattern[1..] else pattern;
    var n: usize = 0;
    var showing = false;
    for (help_text) |h| {
        if (h[0] == '.') {
            showing = all or std.mem.startsWith(u8, h[1..], pat);
            if (showing) n += 1;
        }
        if (showing and (h[0] == '.' or all)) try p.print("{s}\n", .{h});
    }
    if (n == 1 and !all) {
        // One match: show its details too.
        showing = false;
        n = 0;
        for (help_text) |h| {
            if (h[0] == '.') showing = std.mem.startsWith(u8, h[1..], pat);
            if (showing and h[0] != '.') try p.print("{s}\n", .{h});
        }
        n = 1;
    }
    return n;
}

/// A dot-command that failed after reporting the error (C: rc 1).
const DotError = Error || error{CommandFailed};

/// The rc of a dot-command for doMetaCommand(): 1 if it failed.
fn dotStatus(r: DotError!void) Error!u8 {
    r catch |err| switch (err) {
        error.CommandFailed => return 1,
        else => |e| return e,
    };
    return 0;
}

/// Port of do_meta_command(): run a dot-command. Returns 0, 1 on error,
/// or 2 to stop reading the input (the rc of the C shell, which makes its
/// exit status).
fn doMetaCommand(p: *Shell, line: []const u8) Error!u8 {
    try parseDotCmdArgs(p, line);
    const args = p.dot_args.items;
    if (args.len == 0) return 0;
    const cmd = args[0];
    const n = cmd.len;
    const c = cmd[0];
    const isCmd = struct {
        fn f(z: []const u8, name: []const u8) bool {
            return z.len <= name.len and std.mem.eql(u8, z, name[0..z.len]);
        }
    }.f;
    var rc: u8 = 0;
    if ((c == 'b' and n >= 3 and isCmd(cmd, "backup")) or (c == 's' and n >= 3 and isCmd(cmd, "save"))) {
        rc = try dotStatus(dotBackup(p));
    } else if (c == 'b' and n >= 3 and isCmd(cmd, "bail")) {
        if (args.len == 2) {
            p.bail = try booleanValue(p, args[1]);
        } else {
            try p.eprint("Usage: .bail on|off\n", .{});
            rc = 1;
        }
    } else if (c == 'c' and n >= 3 and isCmd(cmd, "changes")) {
        if (args.len == 2) {
            p.count_changes = try booleanValue(p, args[1]);
        } else {
            try p.eprint("Usage: .changes on|off\n", .{});
            rc = 1;
        }
    } else if (c == 'd' and n >= 3 and isCmd(cmd, "dbconfig")) {
        rc = try dotStatus(dotDbconfig(p));
    } else if (c == 'd' and n >= 3 and isCmd(cmd, "dialect")) {
        // xqlite: the SQL dialect of the connection (PRAGMA xq_dialect).
        if (args.len == 1) {
            try p.print("{s}\n", .{sql.main.getDialect(p.db).name()});
        } else if (args.len == 2) {
            if (xqlite.dialect.Dialect.fromName(args[1])) |d| {
                sql.main.setDialect(p.db, d);
            } else {
                try p.eprint("Error: unknown dialect: {s}\n", .{args[1]});
                rc = 1;
            }
        } else {
            try p.eprint("Usage: .dialect ?sqlite|postgres|mariadb?\n", .{});
            rc = 1;
        }
    } else if (c == 'd' and isCmd(cmd, "dump")) {
        rc = try dotStatus(dotDump(p));
    } else if (c == 'e' and isCmd(cmd, "echo")) {
        if (args.len == 2) {
            p.echo = try booleanValue(p, args[1]);
        } else {
            try p.eprint("Usage: .echo on|off\n", .{});
            rc = 1;
        }
    } else if (c == 'e' and isCmd(cmd, "explain")) {
        // Automatic now; kept for backwards compatibility.
        if (args.len >= 2) {
            p.mode.auto_explain = if (std.mem.eql(u8, args[1], "auto")) true else try booleanValue(p, args[1]);
        }
    } else if (c == 'e' and isCmd(cmd, "exit")) {
        if (args.len > 1) {
            const code = integerValue(args[1]);
            if (code != 0) {
                p.exit_code = @truncate(@as(u64, @bitCast(code)));
                return error.ExitRequested;
            }
        }
        rc = 2;
    } else if (c == 'h' and isCmd(cmd, "headers")) {
        if (args.len == 2) {
            if (std.mem.eql(u8, args[1], "always")) {
                p.mode.spec.titles = .always;
            } else {
                p.mode.spec.titles = if (try booleanValue(p, args[1])) .yes else .no;
            }
            p.mode.hdr_set = true;
            p.mode.spec.title = mode_info[p.mode.e_mode].hdr;
        } else {
            try p.eprint("Usage: .headers off|on|always\n", .{});
            rc = 1;
        }
    } else if (c == 'h' and isCmd(cmd, "help")) {
        if (args.len >= 2) {
            if (try showHelp(p, args[1]) == 0) try p.print("Nothing matches '{s}'\n", .{args[1]});
        } else {
            _ = try showHelp(p, null);
        }
    } else if (c == 'i' and (isCmd(cmd, "indices") or isCmd(cmd, "indexes"))) {
        rc = try dotStatus(dotIndexes(p));
    } else if (c == 'm' and isCmd(cmd, "mode")) {
        rc = try dotStatus(dotMode(p));
    } else if (c == 'n' and isCmd(cmd, "nullvalue")) {
        if (args.len == 2) {
            try setStr(p.gpa, &p.mode.spec.null_text, args[1]);
        } else {
            try p.eprint("Usage: .nullvalue STRING\n", .{});
            rc = 1;
        }
    } else if (c == 'p' and n >= 3 and isCmd(cmd, "print")) {
        for (args[1..], 1..) |a, i| {
            if (i > 1) try p.out.writeAll(" ");
            try p.out.writeAll(a);
        }
        try p.out.writeAll("\n");
    } else if (c == 'q' and isCmd(cmd, "quit")) {
        rc = 2;
    } else if (c == 'r' and n >= 3 and isCmd(cmd, "read")) {
        rc = try dotStatus(dotRead(p));
    } else if (c == 'r' and n >= 3 and isCmd(cmd, "restore")) {
        rc = try dotStatus(dotRestore(p));
    } else if (c == 's' and isCmd(cmd, "schema")) {
        rc = try dotStatus(dotSchema(p));
    } else if (c == 's' and isCmd(cmd, "separator")) {
        if (args.len < 2 or args.len > 3) {
            try p.eprint("Usage: .separator COL ?ROW?\n", .{});
            rc = 1;
        }
        if (args.len >= 2) try setStr(p.gpa, &p.mode.spec.column_sep, args[1]);
        if (args.len >= 3) try setStr(p.gpa, &p.mode.spec.row_sep, args[2]);
    } else if (c == 's' and isCmd(cmd, "show")) {
        rc = try dotStatus(dotShow(p));
    } else if (c == 't' and n > 1 and isCmd(cmd, "tables")) {
        rc = try dotStatus(dotTables(p));
    } else if (c == 't' and n > 4 and isCmd(cmd, "timeout")) {
        _ = sql.main.busyTimeout(p.db, if (args.len >= 2) @truncate(integerValue(args[1])) else 0);
    } else {
        try p.eprint("Error: unknown command or invalid arguments:  \"{s}\". Enter \".help\" for help\n", .{cmd});
        rc = 1;
    }
    return rc;
}

/// Open `filename` for .backup and .restore, as sqlite3_open_v2() with
/// URI names; null after reporting the error.
fn openOther(p: *Shell, filename: []const u8) Error!?*Sqlite3 {
    var opened: ?*Sqlite3 = null;
    const orc = sql.main.open(p.db.vfs.?, filename, .{ .uri = true }, &opened);
    if (orc == RC.OK) return opened.?;
    try p.eprint("Error: cannot open \"{s}\"\n", .{filename});
    if (opened) |db| _ = sql.main.close(db);
    return null;
}

/// .backup ?DB? ?OPTIONS? FILE and .save: copy database DB to FILE with
/// the backup API, 100 pages a step.
fn dotBackup(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    var dest_file: ?[]const u8 = null;
    var z_db: ?[]const u8 = null;
    var async_ = false;
    for (args[1..], 1..) |a, j| {
        if (a.len > 0 and a[0] == '-') {
            const z = if (a.len > 1 and a[1] == '-') a[1..] else a;
            if (std.mem.eql(u8, z, "-async")) {
                async_ = true;
            } else {
                // (The appendvfs of --append is not ported.)
                try dotCmdError(p, j, "unknown option", "should be -append or -async");
                return error.CommandFailed;
            }
        } else if (dest_file == null) {
            dest_file = a;
        } else if (z_db == null) {
            z_db = dest_file;
            dest_file = a;
        } else {
            try p.eprint("Usage: .backup ?DB? ?OPTIONS? FILENAME\n", .{});
            return error.CommandFailed;
        }
    }
    const file = dest_file orelse {
        try p.eprint("missing FILENAME argument on .backup\n", .{});
        return error.CommandFailed;
    };
    const dest = try openOther(p, file) orelse return error.CommandFailed;
    defer _ = sql.main.close(dest);
    if (async_) _ = sql.legacy.exec(dest, "PRAGMA synchronous=OFF; PRAGMA journal_mode=OFF;", null, null, null);
    const b = sql.backup.init(dest, "main", p.db, z_db orelse "main") orelse {
        try p.eprint("Error: {s}\n", .{sql.main.errmsg(dest)});
        return error.CommandFailed;
    };
    var rc = sql.backup.step(b, 100);
    while (rc == RC.OK) rc = sql.backup.step(b, 100);
    _ = sql.backup.finish(b);
    if (rc != RC.DONE) {
        try p.eprint("Error: {s}\n", .{sql.main.errmsg(dest)});
        return error.CommandFailed;
    }
}

/// .restore ?DB? FILE: copy FILE into database DB with the backup API,
/// retrying a busy source three times.
fn dotRestore(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    var src_file: []const u8 = undefined;
    var z_db: []const u8 = "main";
    if (args.len == 2) {
        src_file = args[1];
    } else if (args.len == 3) {
        src_file = args[2];
        z_db = args[1];
    } else {
        try p.eprint("Usage: .restore ?DB? FILE\n", .{});
        return error.CommandFailed;
    }
    const src = try openOther(p, src_file) orelse return error.CommandFailed;
    defer _ = sql.main.close(src);
    const b = sql.backup.init(p.db, z_db, src, "main") orelse {
        try p.eprint("Error: {s}\n", .{sql.main.errmsg(p.db)});
        return error.CommandFailed;
    };
    var n_timeout: u32 = 0;
    var rc = sql.backup.step(b, 100);
    while (rc == RC.OK or rc == RC.BUSY) : (rc = sql.backup.step(b, 100)) {
        if (rc == RC.BUSY) {
            if (n_timeout >= 3) break;
            n_timeout += 1;
            _ = p.db.vfs.?.sleep(100_000);
        }
    }
    _ = sql.backup.finish(b);
    if (rc == RC.DONE) return;
    if (rc == RC.BUSY or rc == RC.LOCKED) {
        try p.eprint("Error: source database is busy\n", .{});
    } else {
        try p.eprint("Error: {s}\n", .{sql.main.errmsg(p.db)});
    }
    return error.CommandFailed;
}

/// .read FILE
fn dotRead(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    if (args.len != 2) {
        try p.eprint("Usage: .read FILE\n", .{});
        return error.CommandFailed;
    }
    const file = Io.Dir.cwd().openFile(p.io, args[1], .{}) catch {
        try p.eprint("Error: cannot open \"{s}\"\n", .{args[1]});
        return error.CommandFailed;
    };
    defer file.close(p.io);
    // The arguments live in p.dot_copy, which nested commands reuse.
    const name = try p.gpa.dupe(u8, args[1]);
    defer p.gpa.free(name);
    var buf: [16384]u8 = undefined;
    var r = file.reader(p.io, &buf);
    if (try processInput(p, &r.interface, name) != 0) return error.CommandFailed;
}

/// Port of the .show command.
fn dotShow(p: *Shell) DotError!void {
    if (p.dot_args.items.len != 1) {
        try p.eprint("Usage: .show\n", .{});
        return error.CommandFailed;
    }
    const gpa = p.gpa;
    const m = &p.mode;
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    try s.print(gpa, "{s: >12}: {s}\n", .{ "echo", if (p.echo) "on" else "off" });
    try s.print(gpa, "{s: >12}: {s}\n", .{ "eqp", "off" });
    try s.print(gpa, "{s: >12}: {s}\n", .{ "explain", if (m.auto_explain) "auto" else "off" });
    try s.print(gpa, "{s: >12}: {s}\n", .{ "headers", switch (m.spec.titles) {
        .always => "always",
        .yes => "on",
        else => "off",
    } });
    const style = m.spec.style;
    if (style == .column or style == .box or style == .table or style == .markdown) {
        try s.print(gpa, "{s: >12}: {s} --wrap {d} --wordwrap {s} --{s}quote\n", .{
            "mode",                                        mode_info[m.e_mode].name,              m.spec.wrap,
            if (m.spec.word_wrap == .yes) "on" else "off", if (m.spec.text == .sql) "" else "no",
        });
    } else {
        try s.print(gpa, "{s: >12}: {s}\n", .{ "mode", mode_info[m.e_mode].name });
    }
    try s.print(gpa, "{s: >12}: ", .{"nullvalue"});
    try appendCString(gpa, &s, m.spec.null_text orelse "");
    try s.print(gpa, "\n{s: >12}: {s}\n", .{ "output", "stdout" });
    try s.print(gpa, "{s: >12}: ", .{"colseparator"});
    try appendCString(gpa, &s, m.spec.column_sep orelse "");
    try s.print(gpa, "\n{s: >12}: ", .{"rowseparator"});
    try appendCString(gpa, &s, m.spec.row_sep orelse "");
    try s.print(gpa, "\n{s: >12}: off\n", .{"stats"});
    try s.print(gpa, "{s: >12}: ", .{"width"});
    for (m.spec.widths) |w| try s.print(gpa, "{d} ", .{w});
    try s.print(gpa, "\n{s: >12}: {s}\n", .{ "filename", p.db_filename });
    try p.out.writeAll(s.items);
}

/// Port of the .tables command, reading only the main and temp schemas.
fn dotTables(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    const pattern: ?[]const u8 = if (args.len > 1) args[1] else null;
    const gpa = p.gpa;
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    var schemas: [2][]const u8 = .{ "main", "temp" };
    const n_schema: usize = if (try hasTempSchema(p)) 2 else 1;
    for (schemas[0..n_schema]) |db_name| {
        if (s.items.len > 0) try s.appendSlice(gpa, " UNION ALL ");
        if (std.mem.eql(u8, db_name, "main")) {
            try s.appendSlice(gpa, "SELECT name FROM ");
        } else {
            try s.print(gpa, "SELECT '{s}'||'.'||name FROM ", .{db_name});
        }
        try s.print(gpa, "\"{s}\".sqlite_schema WHERE type IN ('table','view')   AND name NOT LIKE 'sqlite__%' ESCAPE '_'", .{db_name});
        if (pattern) |pat| try appendf(gpa, &s, " AND name LIKE %Q", &.{.{ .str = pat }});
    }
    try s.appendSlice(gpa, " ORDER BY 1");
    try p.modePush();
    defer p.modePop();
    try p.modeChange(MODE_Split);
    _ = try shellExec(p, &p.mode, s.items, null);
}

/// Appends the output of an SQLite printf format to `s`.
fn appendf(gpa: Allocator, s: *std.ArrayList(u8), fmt: []const u8, args: []const xqlite.printf.Arg) Error!void {
    try qrf.appendPrintf(gpa, s, fmt, args);
}

/// Whether the temp schema holds anything (PRAGMA database_list lists
/// it only once it is in use).
fn hasTempSchema(p: *Shell) Error!bool {
    return (try queryInt(p, "SELECT count(*) FROM sqlite_temp_schema")) > 0;
}

/// Port of db_int(): the integer result of a query (0 on error).
fn queryInt(p: *Shell, text: []const u8) Error!i64 {
    var stmt_opt: ?*Stmt = null;
    if (sql.prepare.prepareV2(p.db, text, &stmt_opt, null) != RC.OK) return 0;
    const stmt = stmt_opt orelse return 0;
    defer _ = api.finalize(stmt);
    if (api.step(stmt) != RC.ROW) return 0;
    return api.columnInt64(stmt, 0);
}

/// Port of the .indexes command. The C code reads pragma_index_list();
/// the same names come from sqlite_schema.
fn dotIndexes(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    var all = false;
    var sys = false;
    var pattern: ?[]const u8 = null;
    for (args[1..], 1..) |a, i| {
        if (a.len > 0 and a[0] == '-') {
            if (optionMatch(a, "all") or optionMatch(a, "a")) {
                all = true;
            } else if (optionMatch(a, "sys")) {
                sys = true;
                all = false;
            } else {
                try dotCmdError(p, i, "unknown option", null);
                return error.CommandFailed;
            }
        } else if (pattern == null) {
            pattern = a;
        } else {
            try dotCmdError(p, i, "unknown argument", null);
            return error.CommandFailed;
        }
    }
    const gpa = p.gpa;
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    const n_schema: usize = if (try hasTempSchema(p)) 2 else 1;
    for (0..n_schema) |k| {
        if (k == 0) {
            try s.appendSlice(gpa, "SELECT name FROM main.sqlite_schema");
        } else {
            try s.appendSlice(gpa, " UNION ALL SELECT 'temp.'||name FROM temp.sqlite_schema");
        }
        try s.appendSlice(gpa, " WHERE type='index'");
        if (sys) {
            try s.appendSlice(gpa, " AND name LIKE 'sqlite__autoindex__%' ESCAPE '_'");
        } else if (!all) {
            try s.appendSlice(gpa, " AND name NOT LIKE 'sqlite__%' ESCAPE '_'");
        }
        if (pattern) |pat| try appendf(gpa, &s, " AND name LIKE '%%%q%%'", &.{.{ .str = pat }});
    }
    try s.appendSlice(gpa, " ORDER BY 1");
    try p.modePush();
    defer p.modePop();
    try p.modeChange(MODE_Split);
    _ = try shellExec(p, &p.mode, s.items, null);
}

/// Port of shellFakeSchema(): "name(col,...)" for a view, from the column
/// names of a query on it (the C code uses PRAGMA table_info).
fn fakeSchema(p: *Shell, s: *std.ArrayList(u8), name: []const u8) Error!void {
    const gpa = p.gpa;
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(gpa);
    try appendf(gpa, &q, "SELECT * FROM \"%w\"", &.{.{ .str = name }});
    var stmt_opt: ?*Stmt = null;
    if (sql.prepare.prepareV2(p.db, q.items, &stmt_opt, null) != RC.OK) return;
    const stmt = stmt_opt orelse return;
    defer _ = api.finalize(stmt);
    const n_col = api.columnCount(stmt);
    if (n_col == 0) return;
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(gpa);
    try appendText(gpa, &t, name, quoteChar(name));
    for (0..n_col) |i| {
        try t.append(gpa, if (i == 0) '(' else ',');
        const col = if (api.columnName(stmt, i)) |z| std.mem.sliceTo(z, 0) else "";
        try appendText(gpa, &t, col, quoteChar(col));
    }
    try t.append(gpa, ')');
    // Keep "*/" out of the comment.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, t.items, i, "*/")) |k| {
        t.items[k + 1] = '*';
        i = k + 1;
    }
    try s.appendSlice(gpa, "\n/* ");
    try s.appendSlice(gpa, t.items);
    try s.appendSlice(gpa, " */");
}

/// Port of the .schema command for the main database. The C code builds
/// its query from PRAGMA database_list and SQL functions of the shell;
/// their work is done here on the rows of sqlite_schema.
fn dotSchema(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    const gpa = p.gpa;
    var name: ?[]const u8 = null;
    var debug = false;
    var no_sys = false;
    for (args[1..]) |a| {
        if (optionMatch(a, "indent")) {
            // Pretty-printing is not ported; the text is shown as is.
        } else if (optionMatch(a, "debug")) {
            debug = true;
        } else if (optionMatch(a, "nosys")) {
            no_sys = true;
        } else if (a.len > 0 and a[0] == '-') {
            try p.eprint("Unknown option: \"{s}\"\n", .{a});
            return error.CommandFailed;
        } else if (name == null) {
            name = a;
        } else {
            try p.eprint("Usage: .schema ?--indent? ?--nosys? ?LIKE-PATTERN?\n", .{});
            return error.CommandFailed;
        }
    }
    if (name) |z| {
        var lower_buf: [32]u8 = undefined;
        if (z.len <= lower_buf.len) {
            const lz = std.ascii.lowerString(&lower_buf, z);
            const is_schema = for ([_][]const u8{ "sqlite_master", "sqlite_schema", "sqlite_temp_master", "sqlite_temp_schema" }) |s| {
                if (std.mem.eql(u8, lz, s)) break true;
            } else false;
            if (is_schema) {
                try p.print("CREATE TABLE {s}sqlite_schema (\n  type text,\n  name text,\n  tbl_name text,\n  rootpage integer,\n  sql text\n);\n", .{if (std.mem.startsWith(u8, lz, "sqlite_t")) "temp." else ""});
            }
        }
    }
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(gpa);
    try q.appendSlice(gpa, "SELECT sql, type, name FROM sqlite_schema WHERE ");
    if (name) |z| {
        const glob = std.mem.indexOfAny(u8, z, "*?[") != null;
        try q.appendSlice(gpa, if (std.mem.indexOfScalar(u8, z, '.') != null) "lower('main.'||tbl_name)" else "lower(tbl_name)");
        try appendf(gpa, &q, if (glob) " GLOB %Q" else " LIKE %Q", &.{.{ .str = z }});
        try q.appendSlice(gpa, if (glob) " AND " else " ESCAPE '\\' AND ");
    }
    if (no_sys) try q.appendSlice(gpa, " name NOT LIKE 'sqlite__%' ESCAPE '_' AND ");
    try q.appendSlice(gpa, "sql IS NOT NULL ORDER BY rowid");
    if (debug) {
        try p.print("SQL: {s};\n", .{q.items});
        return;
    }

    // Collect the rows first: views are queried while formatting.
    var rows: std.ArrayList([2][]u8) = .empty;
    defer {
        for (rows.items) |r| {
            gpa.free(r[0]);
            gpa.free(r[1]);
        }
        rows.deinit(gpa);
    }
    {
        var stmt_opt: ?*Stmt = null;
        if (sql.prepare.prepareV2(p.db, q.items, &stmt_opt, null) != RC.OK) {
            try p.eprint("Error: {s}\n", .{sql.main.errmsg(p.db)});
            return error.CommandFailed;
        }
        const stmt = stmt_opt orelse return;
        defer _ = api.finalize(stmt);
        var rc = api.step(stmt);
        while (rc == RC.ROW) : (rc = api.step(stmt)) {
            const text = std.mem.sliceTo(api.columnText(stmt, 0) orelse "", 0);
            const obj = std.mem.sliceTo(api.columnText(stmt, 2) orelse "", 0);
            const a = try gpa.dupe(u8, text);
            errdefer gpa.free(a);
            try rows.append(gpa, .{ a, try gpa.dupe(u8, obj) });
        }
        if (rc != RC.DONE) {
            try p.eprint("Error: {s}\n", .{sql.main.errmsg(p.db)});
            return error.CommandFailed;
        }
    }

    const prefixes = [_][]const u8{ "TABLE", "INDEX", "UNIQUE INDEX", "VIEW", "TRIGGER", "VIRTUAL TABLE" };
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (rows.items) |r| {
        const text = r[0];
        s.clearRetainingCapacity();
        // shell_add_schema(sql, NULL, name)
        try s.appendSlice(gpa, text);
        if (std.mem.startsWith(u8, text, "CREATE ")) {
            for (prefixes) |pre| {
                if (std.mem.startsWith(u8, text[7..], pre) and text.len > 7 + pre.len and text[7 + pre.len] == ' ') {
                    try appendCompletion(gpa, &s, text, true, false);
                    if (pre[0] == 'V') try fakeSchema(p, &s, r[1]);
                    break;
                }
            }
        }
        // shell_complete_sql(..., 1)
        try appendCompletion(gpa, &s, s.items, true, false);
        out.clearRetainingCapacity();
        try qrf.appendEscaped(gpa, &out, p.mode.spec.esc, s.items);
        try out.append(gpa, '\n');
        try p.out.writeAll(out.items);
    }
}

/// Port of printSchemaLine().
fn printSchemaLine(p: *Shell, z: []const u8, tail: []const u8) Error!void {
    if (std.mem.startsWith(u8, z, "CREATE TABLE ") and z.len > 13 and (z[13] == '\'' or z[13] == '"')) {
        try p.print("CREATE TABLE IF NOT EXISTS {s}{s}", .{ z[13..], tail });
    } else {
        try p.print("{s}{s}", .{ z, tail });
    }
}

const dump_data_only = 1;
const dump_no_sys = 2;

/// Port of dump_callback(): the SQL that recreates table `table` and its
/// content.
fn dumpTable(p: *Shell, table: []const u8, kind: []const u8, text: []const u8, flags: u8) Error!void {
    const data_only = flags & dump_data_only != 0;
    const no_sys = flags & dump_no_sys != 0;
    if (std.mem.eql(u8, table, "sqlite_sequence") and !no_sys) {
        if (try queryInt(p, "SELECT count(*) FROM sqlite_sequence") > 0) {
            if (!p.writable_schema) {
                try p.out.writeAll("PRAGMA writable_schema=ON;\n");
                p.writable_schema = true;
            }
            try p.out.writeAll("CREATE TABLE IF NOT EXISTS sqlite_sequence(name,seq);\nDELETE FROM sqlite_sequence;\n");
        }
    } else if (isStatTable(table) and !no_sys) {
        if (!data_only) try p.out.writeAll("ANALYZE sqlite_schema;\n");
    } else if (std.mem.startsWith(u8, table, "sqlite_")) {
        return;
    } else if (data_only) {
        // Only the content.
    } else if (std.mem.startsWith(u8, text, "CREATE VIRTUAL TABLE")) {
        if (!p.writable_schema) {
            try p.out.writeAll("PRAGMA writable_schema=ON;\n");
            p.writable_schema = true;
        }
        const ins = xqlite.printf.mprintf(p.gpa, "INSERT INTO sqlite_schema(type,name,tbl_name,rootpage,sql)VALUES('table','%q','%q',0,'%q');", &.{ .{ .str = table }, .{ .str = table }, .{ .str = text } }) catch return error.OutOfMemory;
        defer p.gpa.free(ins);
        try p.print("{s}\n", .{ins});
        return;
    } else {
        try printSchemaLine(p, text, ";\n");
    }

    if (std.mem.eql(u8, kind, "table")) {
        // The columns listed by PRAGMA table_info (tableColumnList()),
        // which leaves out generated columns.
        var q: std.ArrayList(u8) = .empty;
        defer q.deinit(p.gpa);
        try q.appendSlice(p.gpa, "SELECT ");
        {
            const info = xqlite.printf.mprintf(p.gpa, "PRAGMA table_info=%Q", &.{.{ .str = table }}) catch return error.OutOfMemory;
            defer p.gpa.free(info);
            var stmt_opt: ?*Stmt = null;
            _ = sql.prepare.prepareV2(p.db, info, &stmt_opt, null);
            var n_col: usize = 0;
            if (stmt_opt) |stmt| {
                defer _ = api.finalize(stmt);
                while (api.step(stmt) == RC.ROW) : (n_col += 1) {
                    const name = api.columnText(stmt, 1) orelse "";
                    if (n_col > 0) try q.append(p.gpa, ',');
                    try appendText(p.gpa, &q, name, quoteChar(name));
                }
            }
            if (n_col == 0) try q.append(p.gpa, '*');
        }
        try q.appendSlice(p.gpa, " FROM ");
        try appendText(p.gpa, &q, table, quoteChar(table));
        var m = p.mode;
        m.spec.table_name = table;
        m.e_mode = MODE_Insert;
        m.spec.text = .sql;
        m.spec.blob = .sql;
        m.spec.titles = .no;
        m.spec.char_limit = 0;
        const rc = try shellExec(p, &m, q.items, null);
        if (rc != RC.OK) p.n_err += 1;
    }
}

/// Port of the .dump command, without --preserve-rowids.
fn dotDump(p: *Shell) DotError!void {
    const gpa = p.gpa;
    const args = p.dot_args.items;
    var flags: u8 = 0;
    var like: std.ArrayList(u8) = .empty;
    defer like.deinit(gpa);
    for (args[1..], 1..) |a, i| {
        if (a.len > 0 and a[0] == '-') {
            if (optionMatch(a, "newlines")) {
                // No-op, as in the C code.
            } else if (optionMatch(a, "data-only")) {
                flags |= dump_data_only;
            } else if (optionMatch(a, "nosys")) {
                flags |= dump_no_sys;
            } else {
                try dotCmdError(p, i, "unknown option", null);
                return error.CommandFailed;
            }
        } else {
            if (like.items.len > 0) try like.appendSlice(gpa, " OR ");
            try appendf(gpa, &like, "name LIKE %Q ESCAPE '\\' OR EXISTS (  SELECT 1 FROM sqlite_schema WHERE     name LIKE %Q ESCAPE '\\' AND    sql LIKE 'CREATE VIRTUAL TABLE%%' AND    substr(o.name, 1, length(name)+1) == (name||'_'))", &.{ .{ .str = a }, .{ .str = a } });
        }
    }
    if (like.items.len == 0) try like.appendSlice(gpa, "true");

    const saved_mode = try p.mode.dup(gpa);
    defer {
        p.mode.deinit(gpa);
        p.mode = saved_mode;
    }
    // outputDumpWarning(): virtual tables are dumped by writing to
    // sqlite_schema.
    {
        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(gpa);
        try w.print(gpa, "SELECT 1 FROM sqlite_schema o WHERE sql LIKE 'CREATE VIRTUAL TABLE%' AND ({s})", .{like.items});
        if (try queryInt(p, w.items) == 1) {
            try p.out.writeAll("/* WARNING: Script requires that SQLITE_DBCONFIG_DEFENSIVE be disabled */\n");
        }
    }
    const data_only = flags & dump_data_only != 0;
    if (!data_only) try p.out.writeAll("PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n");
    p.writable_schema = false;
    p.mode.spec.titles = .no;
    p.n_err = 0;

    // The tables, collected first since dumping them runs other queries.
    var q: std.ArrayList(u8) = .empty;
    defer q.deinit(gpa);
    try q.print(gpa, "SELECT name, type, sql FROM sqlite_schema AS o WHERE ({s}) AND type=='table'  AND sql NOT NULL ORDER BY tbl_name='sqlite_sequence', rowid", .{like.items});
    var tables: std.ArrayList([3][]u8) = .empty;
    defer {
        for (tables.items) |t| for (t) |z| gpa.free(z);
        tables.deinit(gpa);
    }
    try collectRows(p, q.items, 3, &tables);
    var completed: std.ArrayList(u8) = .empty;
    defer completed.deinit(gpa);
    for (tables.items) |t| {
        // shell_complete_sql(sql)
        completed.clearRetainingCapacity();
        try completed.appendSlice(gpa, t[2]);
        try appendCompletion(gpa, &completed, t[2], false, false);
        try dumpTable(p, t[0], t[1], completed.items, flags);
    }

    if (!data_only) {
        // Port of run_table_dump_query() on the indexes, triggers and views.
        q.clearRetainingCapacity();
        try q.print(gpa, "SELECT sql FROM sqlite_schema AS o WHERE ({s}) AND sql NOT NULL  AND type IN ('index','trigger','view') ORDER BY type COLLATE NOCASE DESC", .{like.items});
        var others: std.ArrayList([1][]u8) = .empty;
        defer {
            for (others.items) |t| gpa.free(t[0]);
            others.deinit(gpa);
        }
        try collectRows(p, q.items, 1, &others);
        for (others.items) |t| {
            completed.clearRetainingCapacity();
            try completed.appendSlice(gpa, t[0]);
            try appendCompletion(gpa, &completed, t[0], false, false);
            const z = completed.items;
            try p.out.writeAll(z);
            try p.out.writeAll(if (std.mem.indexOf(u8, z, "--") != null) "\n;\n" else ";\n");
        }
    }
    if (p.writable_schema) {
        try p.out.writeAll("PRAGMA writable_schema=OFF;\n");
        p.writable_schema = false;
    }
    if (!data_only) try p.out.writeAll(if (p.n_err != 0) ";\nROLLBACK; -- due to errors\n" else "COMMIT;\n");
    if (p.n_err > 0) return error.CommandFailed;
}

/// Runs `text` and copies the first `n` columns of every row (as text,
/// "" for NULL). Errors are written into the dump as the C code does.
fn collectRows(p: *Shell, text: []const u8, comptime n: usize, rows: *std.ArrayList([n][]u8)) Error!void {
    const gpa = p.gpa;
    var stmt_opt: ?*Stmt = null;
    const prc = sql.prepare.prepareV2(p.db, text, &stmt_opt, null);
    if (prc != RC.OK) {
        try p.print("/**** ERROR: ({d}) {s} *****/\n", .{ prc, sql.main.errmsg(p.db) });
        p.n_err += 1;
        return;
    }
    const stmt = stmt_opt orelse return;
    var rc = api.step(stmt);
    while (rc == RC.ROW) : (rc = api.step(stmt)) {
        var row: [n][]u8 = undefined;
        var k: usize = 0;
        errdefer for (row[0..k]) |z| gpa.free(z);
        while (k < n) : (k += 1) {
            row[k] = try gpa.dupe(u8, std.mem.sliceTo(api.columnText(stmt, k) orelse "", 0));
        }
        try rows.append(gpa, row);
    }
    const frc = api.finalize(stmt);
    if (frc != RC.OK) {
        try p.print("/**** ERROR: ({d}) {s} *****/\n", .{ frc, sql.main.errmsg(p.db) });
        p.n_err += 1;
    }
}

/// Port of modeTitleDsply(): what to show about the titles in the .mode
/// description (0 nothing, 1 off, 2 on, 3 always, 4 the encoding, 5 the
/// encoding and always).
fn modeTitleDsply(p: *Shell, b_all: bool) u8 {
    const info = &mode_info[p.mode.e_mode];
    var bt: u8 = @backingInt(p.mode.spec.titles);
    var et: u8 = @backingInt(p.mode.spec.title);
    const bh: u8 = @backingInt(info.b_hdr);
    const eh: u8 = @backingInt(info.hdr);
    var v: u64 = 0x0133013311220102;
    if (bh == 0) return 0;
    if (et == 0) et = eh;
    if (bt == 0) bt = bh;
    if (et != eh) v >>= 32;
    if (bt != bh) v >>= 16;
    if (bt < 2) v >>= 8;
    if (!b_all) v >>= 4;
    var r: u8 = @intCast(v & 3);
    if (p.mode.spec.titles == .always) {
        if (r == 3) r = 5;
        if (r == 2) r = 3;
    } else {
        if (r == 3) r = 4;
    }
    return r;
}

fn modeFind(name: []const u8) ?u8 {
    for (mode_info, 0..) |info, i| if (std.mem.eql(u8, info.name, name)) return @intCast(i);
    if (std.mem.eql(u8, name, "batch")) return MODE_BATCH;
    if (std.mem.eql(u8, name, "tty")) return MODE_TTY;
    return null;
}

/// The --quote arguments; from "sql" on, index k is qrf.TextMode k.
const quote_names = [_][]const u8{ "off", "on", "sql", "csv", "html", "tcl", "json", "relaxed" };

/// Port of dotCmdMode(), without --align, --once, --tag, --ifmt and --fpfmt
/// (--textjsonb is recorded but JSONB blobs are not rendered as JSON).
fn dotMode(p: *Shell) DotError!void {
    const args = p.dot_args.items;
    const gpa = p.gpa;
    const m = &p.mode;
    var i_mode: ?usize = null;
    var chng = false;
    var b_all = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        var z = a;
        if (z.len > 1 and z[0] == '-' and z[1] == '-') z = z[1..];
        if ((z.len == 0 or z[0] != '-') and i_mode == null) {
            if (modeFind(a)) |e| if (e != MODE_Www) {
                i_mode = i;
                try p.modeChange(e);
                // (Legacy) a table name may follow the mode name.
                if (i + 1 < args.len and (args[i + 1].len == 0 or args[i + 1][0] != '-')) {
                    i += 1;
                    try setStr(gpa, &m.spec.table_name, args[i]);
                }
                chng = true;
                continue;
            };
        }
        if (pickStr(z, &.{ "-blob", "-blob-quote" }) != null) {
            i += 1;
            if (i >= args.len) return missingArg(p, i - 1);
            if (std.meta.stringToEnum(qrf.BlobMode, args[i])) |b| m.spec.blob = b;
            chng = true;
        } else if (optionMatch(z, "border")) {
            i += 1;
            if (i >= args.len) return missingArg(p, i - 1);
            if (pickStr(args[i], &.{ "auto", "off", "on" })) |k| m.spec.border = @fromBackingInt(@intCast(k));
            chng = true;
        } else if (pickStr(z, &.{ "-charlimit", "-linelimit", "-titlelimit", "-multiinsert" })) |k| {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            const w: i32 = @truncate(integerValue(args[i]));
            switch (k) {
                0 => m.spec.char_limit = w,
                1 => m.spec.line_limit = w,
                2 => m.spec.title_limit = w,
                else => m.spec.multi_insert = @bitCast(w),
            }
            chng = true;
        } else if (pickStr(z, &.{ "-tablename", "-rowsep", "-colsep", "-null" })) |k| {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            try setStr(gpa, switch (k) {
                0 => &m.spec.table_name,
                1 => &m.spec.row_sep,
                2 => &m.spec.column_sep,
                else => &m.spec.null_text,
            }, args[i]);
            chng = true;
        } else if (optionMatch(z, "escape")) {
            i += 1;
            if (i >= args.len) return missingArg(p, i - 1);
            m.spec.esc = std.meta.stringToEnum(qrf.Escape, args[i]) orelse {
                try dotCmdError(p, i, "unknown escape type", "should be auto, off, ascii, or symbol");
                return error.CommandFailed;
            };
            chng = true;
        } else if (optionMatch(z, "limits")) {
            i += 1;
            if (i >= args.len) return missingArg(p, i - 1);
            if (!setLimits(m, args[i])) {
                try dotCmdError(p, i, "bad argument", "Should be \"on\" or \"off\" or \"L,C,T\" where L, C, and T are unsigned integers");
                return error.CommandFailed;
            }
            chng = true;
        } else if (optionMatch(z, "list")) {
            try p.out.writeAll("available modes:");
            for (mode_info, 0..) |info, k| if (k != MODE_Www) try p.print(" {s}", .{info.name});
            try p.out.writeAll(" batch tty\n");
            chng = true;
        } else if (optionMatch(z, "noquote")) {
            m.spec.text = .plain;
            m.spec.blob = .auto;
            chng = true;
        } else if (optionMatch(z, "quote")) {
            var k: usize = 1;
            if (i + 1 < args.len and (args[i + 1].len == 0 or args[i + 1][0] != '-') and
                (i_mode != null or std.mem.eql(u8, args[i + 1], "off") or modeFind(args[i + 1]) == null))
            {
                i += 1;
                if (pickStr(args[i], &.{ "no", "yes", "0", "1" })) |b| {
                    k = b & 1;
                } else {
                    k = pickStr(args[i], &quote_names) orelse {
                        try dotCmdError(p, i, "unknown", "should be off, on, sql, csv, html, tcl, json, or relaxed");
                        return error.CommandFailed;
                    };
                }
            }
            switch (k) {
                1 => {
                    try setStr(gpa, &m.spec.null_text, "NULL");
                    m.spec.text = .sql;
                },
                2 => m.spec.text = .sql,
                3 => m.spec.text = .csv,
                4 => m.spec.text = .html,
                5 => m.spec.text = .tcl,
                6 => m.spec.text = .json,
                7 => m.spec.text = .relaxed,
                else => m.spec.text = .plain,
            }
            chng = true;
        } else if (optionMatch(z, "reset")) {
            const e = m.e_mode;
            m.deinit(gpa);
            try p.modeChange(e);
        } else if (optionMatch(z, "rowcount")) {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            m.spec.row_count = if (try booleanValue(p, args[i])) .yes else .no;
            chng = true;
        } else if (optionMatch(z, "screenwidth") or optionMatch(z, "sw")) {
            i += 1;
            if (i >= args.len) return missingArg(p, i - 1);
            if (std.mem.eql(u8, args[i], "off")) {
                m.auto_screen_width = false;
                m.spec.screen_width = 0;
            } else if (std.mem.eql(u8, args[i], "auto")) {
                m.auto_screen_width = true;
            } else {
                m.auto_screen_width = false;
                m.spec.screen_width = @intCast(std.math.clamp(integerValue(args[i]), 0, qrf.max_width));
            }
            chng = true;
        } else if (optionMatch(z, "textjsonb")) {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            m.text_jsonb = if (try booleanValue(p, args[i])) .yes else .no;
            chng = true;
        } else if (optionMatch(z, "titles") or optionMatch(z, "title")) {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            const k = pickStr(args[i], &.{ "off", "on", "always", "auto", "plain", "sql", "csv", "html", "tcl", "json" }) orelse {
                try dotCmdError(p, i, "bad --titles value", "should be off, on, always, auto, plain, sql, csv, html, tcl, or json");
                return error.CommandFailed;
            };
            m.hdr_set = false;
            if (k <= 2) {
                m.spec.titles = @fromBackingInt(@intCast(k + 1));
            } else if (k == 3) {
                m.spec.title = mode_info[m.e_mode].hdr;
                m.spec.titles = mode_info[m.e_mode].b_hdr;
            } else {
                m.spec.title = @fromBackingInt(@intCast(k - 3));
                if (m.spec.titles == .no) m.spec.titles = .always;
            }
            chng = true;
        } else if (optionMatch(z, "widths") or optionMatch(z, "width")) {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            var widths: std.ArrayList(i16) = .empty;
            defer widths.deinit(gpa);
            var zw = skipSpace(args[i]);
            while (zw.len > 0) {
                var k: usize = @intFromBool(zw[0] == '-' and zw.len > 1 and std.ascii.isDigit(zw[1]));
                var w: i32 = 0;
                var n_digit: usize = 0;
                while (k < zw.len and std.ascii.isDigit(zw[k])) : (k += 1) {
                    w = w * 10 + (zw[k] - '0');
                    if (w > qrf.max_width) {
                        try dotCmdError(p, i + 1, "width too big", "Maximum column width is 10000");
                        return error.CommandFailed;
                    }
                    n_digit += 1;
                }
                if (n_digit == 0) {
                    try dotCmdError(p, i + 1, "syntax error", "should be a comma-separated list if integers");
                    return error.CommandFailed;
                }
                if (zw[0] == '-') w = -w;
                try widths.append(gpa, @intCast(w));
                zw = zw[k..];
                if (zw.len > 0 and zw[0] == ',') zw = zw[1..];
                zw = skipSpace(zw);
            }
            gpa.free(m.spec.widths);
            m.spec.widths = try widths.toOwnedSlice(gpa);
            chng = true;
        } else if (optionMatch(z, "wrap")) {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            m.spec.wrap = @intCast(std.math.clamp(integerValue(args[i]), -qrf.max_width, qrf.max_width));
            chng = true;
        } else if (optionMatch(z, "ww")) {
            m.spec.word_wrap = .yes;
            chng = true;
        } else if (optionMatch(z, "wordwrap")) {
            if (i + 1 >= args.len) return missingArg(p, i);
            i += 1;
            m.spec.word_wrap = if (try booleanValue(p, args[i])) .yes else .no;
            chng = true;
        } else if (optionMatch(z, "v") or optionMatch(z, "verbose")) {
            b_all = true;
        } else if (z.len > 0 and z[0] == '-') {
            try dotCmdError(p, i, "bad option", "Use \".help .mode\" for more info");
            return error.CommandFailed;
        } else {
            try dotCmdError(p, i, if (i_mode != null) "bad argument" else "unknown mode", "Use \".help .mode\" for more info");
            return error.CommandFailed;
        }
    }
    if (!chng or b_all) try showMode(p, b_all);
}

fn missingArg(p: *Shell, i: usize) DotError {
    try dotCmdError(p, i, "missing argument", null);
    return error.CommandFailed;
}

/// Port of modeSetLimit().
fn setLimits(m: *Mode, z: []const u8) bool {
    if (std.mem.eql(u8, z, "on")) {
        m.spec.line_limit = dflt_line_limit;
        m.spec.char_limit = dflt_char_limit;
        m.spec.title_limit = dflt_title_limit;
    } else if (std.mem.eql(u8, z, "off")) {
        m.spec.line_limit = 0;
        m.spec.char_limit = 0;
        m.spec.title_limit = 0;
    } else {
        var it = std.mem.splitScalar(u8, z, ',');
        var vals: [3]i32 = undefined;
        var n: usize = 0;
        while (it.next()) |part| {
            if (n == 3) break;
            vals[n] = std.fmt.parseInt(i32, part, 10) catch break;
            if (vals[n] < 0) return false;
            n += 1;
        }
        if (n < 2) return false;
        m.spec.line_limit = vals[0];
        m.spec.char_limit = vals[1];
        if (n == 3) m.spec.title_limit = vals[2];
    }
    return true;
}

/// The description printed by .mode without arguments (the tail of
/// dotCmdMode()).
fn showMode(p: *Shell, b_all: bool) Error!void {
    const gpa = p.gpa;
    const m = &p.mode;
    const info = &mode_info[m.e_mode];
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    try s.appendSlice(gpa, info.name);
    if (b_all) try s.appendSlice(gpa, " --align \"\"");
    if (b_all or (m.spec.border == .no) != (info.flg & 1 != 0)) {
        try s.print(gpa, " --border {s}", .{if (m.spec.border == .no) "off" else "on"});
    }
    if (b_all or m.spec.blob != .auto) {
        try s.print(gpa, " --blob-quote {s}", .{@tagName(m.spec.blob)});
    }
    if (mode_str[info.csep]) |dflt| if (b_all or !std.mem.eql(u8, dflt, m.spec.column_sep orelse "")) {
        try s.appendSlice(gpa, " --colsep ");
        try appendCString(gpa, &s, m.spec.column_sep orelse "");
    };
    if (b_all or m.spec.esc != .auto) {
        try s.print(gpa, " --escape {s}", .{@tagName(m.spec.esc)});
    }
    if (b_all) try s.appendSlice(gpa, " --fpfmt auto --ifmt auto");
    if (b_all or (m.spec.line_limit > 0 and info.cx > 0) or m.spec.char_limit > 0 or (m.spec.title_limit > 0 and info.cx > 0)) {
        if (m.spec.line_limit == 0 and m.spec.char_limit == 0 and m.spec.title_limit == 0) {
            try s.appendSlice(gpa, " --limits off");
        } else if (m.spec.line_limit == dflt_line_limit and m.spec.char_limit == dflt_char_limit and m.spec.title_limit == dflt_title_limit) {
            try s.appendSlice(gpa, " --limits on");
        } else {
            try s.print(gpa, " --limits {d},{d},{d}", .{ m.spec.line_limit, m.spec.char_limit, m.spec.title_limit });
        }
    }
    if (b_all or (m.spec.multi_insert != 0 and info.style == .insert)) {
        try s.print(gpa, " --multiinsert {d}", .{m.spec.multi_insert});
    }
    if (mode_str[info.null_]) |dflt| if (b_all or !std.mem.eql(u8, dflt, m.spec.null_text orelse "")) {
        try s.appendSlice(gpa, " --null ");
        try appendCString(gpa, &s, m.spec.null_text orelse "");
    };
    const et = @backingInt(info.text);
    const at = @backingInt(m.spec.text);
    if (b_all or (et != at and (et > 1 or at > 1))) {
        try s.print(gpa, " --quote {s}", .{if (m.spec.text == .plain) "off" else quote_names[at]});
    }
    if (b_all or ((m.spec.row_count == .yes) != (info.flg & 4 != 0))) {
        try s.print(gpa, " --rowcount {s}", .{if (m.spec.row_count == .yes) "on" else "off"});
    }
    if (mode_str[info.rsep]) |dflt| if (b_all or !std.mem.eql(u8, dflt, m.spec.row_sep orelse "")) {
        try s.appendSlice(gpa, " --rowsep ");
        try appendCString(gpa, &s, m.spec.row_sep orelse "");
    };
    if (b_all or (info.cx != 0 and (m.spec.screen_width > 0 or m.auto_screen_width))) {
        if (m.auto_screen_width) {
            try s.appendSlice(gpa, " --sw auto");
        } else {
            try s.print(gpa, " --sw {d}", .{m.spec.screen_width});
        }
    }
    if (b_all or m.e_mode == MODE_Insert) {
        try s.appendSlice(gpa, " --tablename ");
        try appendCString(gpa, &s, m.spec.table_name orelse "");
    }
    if (b_all or m.text_jsonb != .auto) try s.print(gpa, " --textjsonb {s}", .{if (m.text_jsonb == .yes) "on" else "off"});
    const k = modeTitleDsply(p, b_all);
    switch (k) {
        1 => try s.appendSlice(gpa, " --titles off"),
        2 => try s.appendSlice(gpa, " --titles on"),
        3 => try s.appendSlice(gpa, " --titles always"),
        4, 5 => {
            const names = [_][]const u8{ "plain", "sql", "csv", "html", "tcl", "json" };
            try s.print(gpa, " --titles {s}", .{names[@backingInt(m.spec.title) - 1]});
            if (k == 5) try s.appendSlice(gpa, " --titles always");
        },
        else => {},
    }
    if (m.spec.widths.len > 0 and (b_all or info.cx == 2)) {
        for (m.spec.widths, 0..) |w, i| try s.print(gpa, "{s}{d}", .{ if (i == 0) " --widths " else ",", w });
    } else if (b_all) {
        try s.appendSlice(gpa, " --widths \"\"");
    }
    if (b_all or (info.cx > 0 and m.spec.word_wrap != .auto)) {
        if (b_all) try s.print(gpa, " --wordwrap {s}", .{if (m.spec.word_wrap == .yes) "on" else "off"});
        if (m.spec.wrap != 0) try s.print(gpa, " --wrap {d}", .{m.spec.wrap});
        if (!b_all) try s.appendSlice(gpa, " --ww");
    }
    try p.print(".mode {s}\n", .{s.items});
    try p.out.flush();
}

// ================================================================= entry

/// The `sql` command: open `path` (null or ":memory:" for an in-memory
/// database) and run each of `cmds` (SQL or dot-commands) as the sqlite3
/// shell runs its command-line arguments, or else read standard input.
/// Returns the exit code.
pub fn run(gpa: Allocator, io: Io, v: xqlite.vfs.Vfs, path: ?[]const u8, cmds: []const []const u8, out: *Io.Writer, err_out: *Io.Writer) Error!u8 {
    const filename = path orelse ":memory:";
    var opened: ?*Sqlite3 = null;
    // As the sqlite3 shell (SQLITE_CONFIG_URI), "file:" names are URIs.
    const orc = sql.main.open(v, filename, .{ .uri = true }, &opened);
    const db = opened orelse {
        try err_out.print("Error: unable to open database \"{s}\": out of memory\n", .{filename});
        try err_out.flush();
        return 1;
    };
    defer _ = sql.main.close(db);
    if (orc != RC.OK) {
        try err_out.print("Error: unable to open database \"{s}\": {s}\n", .{ filename, sql.main.errmsg(db) });
        try err_out.flush();
        return 1;
    }
    // open_db(): without --unsafe-testing (not ported), the schema is not
    // trusted (SQLITE_DBCONFIG_TRUSTED_SCHEMA off) and the connection is in
    // defensive mode (SQLITE_DBCONFIG_DEFENSIVE on).
    _ = sql.main.dbConfig(db, .trusted_schema, 0);
    _ = sql.main.dbConfig(db, .defensive, 1);
    // The extensions the sqlite3 shell builds in.
    _ = xqlite.ext.series.init(db);
    // For differential testing against an sqlite3 built with vtablog.c
    // (see tools/planner/README.md).
    if (std.c.getenv("XQ_VTABLOG") != null) {
        _ = xqlite.ext.vtablog.init(db, out);
    }

    var stdin_buf: [16384]u8 = undefined;
    var stdin_reader: Io.File.Reader = .initStreaming(.stdin(), io, &stdin_buf);
    var p: Shell = .{
        .gpa = gpa,
        .io = io,
        .db = db,
        .db_filename = path orelse "",
        .out = out,
        .err_out = err_out,
        .stdin = &stdin_reader.interface,
        .stdin_is_interactive = std.c.isatty(0) != 0 and cmds.len == 0,
        .stdout_is_console = std.c.isatty(1) != 0,
    };
    defer p.deinit();
    // Port of modeDefault().
    try p.modeChange(if (p.stdin_is_interactive or p.stdout_is_console) MODE_TTY else MODE_BATCH);

    var rc: u8 = 0;
    if (cmds.len > 0) {
        for (cmds, 0..) |cmd, i| {
            // Error messages count the arguments as sqlite3 DB CMD... does.
            const arg_index = i + 2;
            try echoGroupInput(&p, cmd);
            if (cmd.len > 0 and cmd[0] == '.') {
                var prefix_buf: [64]u8 = undefined;
                p.in_file = "<cmdline>";
                p.err_prefix = std.fmt.bufPrint(&prefix_buf, "argv[{d}]:", .{arg_index}) catch null;
                const mrc = doMetaCommand(&p, cmd) catch |err| switch (err) {
                    error.ExitRequested => return p.exit_code,
                    else => |e| return e,
                };
                p.err_prefix = null;
                if (mrc != 0) {
                    rc = if (mrc == 2) 0 else mrc;
                    break;
                }
            } else {
                if (try runOneSqlLine(&p, cmd, "cmdline", @intCast(arg_index)) != 0) {
                    rc = 1;
                    break;
                }
            }
        }
    } else {
        if (p.stdin_is_interactive) {
            try p.print("xqlite shell (SQLite {s} compatible)\nEnter \".help\" for usage hints.\n", .{"3.54.1"});
            if (path == null) try p.print("Connected to a transient in-memory database.\n", .{});
        }
        rc = @intCast(processInput(&p, null, "<stdin>") catch |err| switch (err) {
            error.ExitRequested => return p.exit_code,
            else => |e| return e,
        });
    }
    try out.flush();
    return rc;
}

test "parse dot-command arguments" {
    var p: Shell = undefined;
    p.gpa = std.testing.allocator;
    p.dot_copy = .empty;
    p.dot_args = .empty;
    p.dot_ofst = .empty;
    defer {
        p.dot_copy.deinit(p.gpa);
        p.dot_args.deinit(p.gpa);
        p.dot_ofst.deinit(p.gpa);
    }
    try parseDotCmdArgs(&p, ".separator \"\\t\" 'a b' x ;");
    try std.testing.expectEqual(@as(usize, 4), p.dot_args.items.len);
    try std.testing.expectEqualStrings("separator", p.dot_args.items[0]);
    try std.testing.expectEqualStrings("\t", p.dot_args.items[1]);
    try std.testing.expectEqualStrings("a b", p.dot_args.items[2]);
    try std.testing.expectEqualStrings("x", p.dot_args.items[3]);
}

test "appendCompletion" {
    const gpa = std.testing.allocator;
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    try appendCompletion(gpa, &s, "CREATE TABLE t(a /* x", true, false);
    try std.testing.expectEqualStrings("*/);", s.items);
    s.clearRetainingCapacity();
    try appendCompletion(gpa, &s, "CREATE TABLE t(a)", false, false);
    try std.testing.expectEqualStrings("", s.items);
}

test "lineIsComplete" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try lineIsComplete(gpa, "SELECT 1;"));
    try std.testing.expect(try lineIsComplete(gpa, "SELECT 1; -- done"));
    try std.testing.expect(!try lineIsComplete(gpa, "SELECT 1"));
}
