//! The prepared statements of a MySQL connection (COM_STMT_PREPARE,
//! COM_STMT_EXECUTE, COM_STMT_SEND_LONG_DATA, COM_STMT_RESET,
//! COM_STMT_CLOSE).
//!
//! Each is a Session.Prepared (described before it runs, compiled again
//! when the schema changes), kept under its statement id until the
//! client closes it. What is MySQL's here: the ids, the types the client
//! binds its parameters with, COM_STMT_SEND_LONG_DATA's bytes, and the
//! binary parameters of COM_STMT_EXECUTE.

const std = @import("std");
const xqlite = @import("xqlite");
const server = @import("../root.zig");
const c = @import("consts.zig");
const packet = @import("packet.zig");
const columns = @import("columns.zig");

const Allocator = std.mem.Allocator;
const Session = server.Session;

/// The type of a parameter, as the client last bound it.
pub const ParamType = struct {
    type: c.Type = .var_string,
    unsigned: bool = false,
};

pub const Prepared = struct {
    id: u32,
    prepared: *Session.Prepared,
    params: []ParamType,
    /// COM_STMT_SEND_LONG_DATA's bytes of each parameter, until the next
    /// execute or reset.
    long_data: []std.ArrayList(u8),
    has_long_data: []bool,

    pub fn paramCount(p: *const Prepared) usize {
        return p.params.len;
    }

    fn clearLongData(p: *Prepared) void {
        for (p.long_data, p.has_long_data) |*d, *has| {
            d.clearRetainingCapacity();
            has.* = false;
        }
    }
};

pub const Statements = struct {
    gpa: Allocator,
    map: std.AutoHashMapUnmanaged(u32, *Prepared) = .empty,
    last_id: u32 = 0,

    pub fn init(gpa: Allocator) Statements {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Statements) void {
        s.closeAll();
        s.map.deinit(s.gpa);
    }

    pub fn get(s: *Statements, id: u32) ?*Prepared {
        // MariaDB: -1 is the statement prepared last.
        return s.map.get(if (id == std.math.maxInt(u32)) s.last_id else id);
    }

    /// Keep `prepared` (Session.prepare()) under a new id; it is closed
    /// with the statement.
    pub fn add(s: *Statements, prepared: *Session.Prepared) !*Prepared {
        const n = prepared.parameterCount();
        const p = try s.gpa.create(Prepared);
        errdefer s.gpa.destroy(p);
        const params = try s.gpa.alloc(ParamType, n);
        errdefer s.gpa.free(params);
        @memset(params, .{});
        const long_data = try s.gpa.alloc(std.ArrayList(u8), n);
        errdefer s.gpa.free(long_data);
        @memset(long_data, .empty);
        const has = try s.gpa.alloc(bool, n);
        errdefer s.gpa.free(has);
        @memset(has, false);
        var id = s.last_id;
        while (true) {
            id +%= 1;
            if (id != 0 and id != std.math.maxInt(u32) and !s.map.contains(id)) break;
        }
        p.* = .{ .id = id, .prepared = prepared, .params = params, .long_data = long_data, .has_long_data = has };
        try s.map.put(s.gpa, id, p);
        s.last_id = id;
        return p;
    }

    pub fn close(s: *Statements, id: u32) void {
        const kv = s.map.fetchRemove(id) orelse return;
        s.destroy(kv.value);
    }

    pub fn closeAll(s: *Statements) void {
        var it = s.map.valueIterator();
        while (it.next()) |p| s.destroy(p.*);
        s.map.clearRetainingCapacity();
    }

    fn destroy(s: *Statements, p: *Prepared) void {
        p.prepared.close();
        for (p.long_data) |*d| d.deinit(s.gpa);
        s.gpa.free(p.long_data);
        s.gpa.free(p.has_long_data);
        s.gpa.free(p.params);
        s.gpa.destroy(p);
    }
};

/// COM_STMT_SEND_LONG_DATA: append `data` to parameter `i`.
pub fn appendLongData(gpa: Allocator, p: *Prepared, i: usize, data: []const u8) !void {
    if (i >= p.paramCount()) return;
    try p.long_data[i].appendSlice(gpa, data);
    p.has_long_data[i] = true;
}

/// COM_STMT_RESET.
pub fn reset(p: *Prepared) void {
    p.clearLongData();
    p.prepared.reset();
}

/// The field of parameter `i` (1-based), from the type the statement
/// gives it.
pub fn paramField(p: *const Prepared, i: usize) columns.Field {
    const t = p.prepared.parameterType(i) orelse return .{ .type = .var_string };
    // Bytes are a BLOB (an expression of bytes would be a VAR_STRING).
    return columns.field(t, if (t.logical == .bytes) "blob" else null);
}

pub const ExecuteError = error{
    /// Parameters the packet does not hold.
    Malformed,
    /// A parameter the statement cannot take (too big).
    Unbindable,
};

/// COM_STMT_EXECUTE of `p`, its parameters in `r` (after the statement
/// id): bind them and run the statement to its end (no cursor),
/// reporting it to `sink` as Session.run() does. The errors are the
/// sink's, OutOfMemory, and ExecuteError (nothing ran).
pub fn execute(p: *Prepared, r: *packet.Reader, sink: anytype) !void {
    _ = try r.byte(); // flags: cursors are not offered (no SERVER_STATUS_CURSOR_EXISTS)
    _ = try r.int(u32); // iteration count, always 1
    defer p.clearLongData();
    const st = p.prepared;
    st.reset();
    const n = p.paramCount();
    if (n > 0) {
        const nulls = try r.bytes((n + 7) / 8);
        if (try r.byte() == 1) {
            for (p.params) |*pt| {
                pt.type = @fromBackingInt(@intCast(try r.byte()));
                pt.unsigned = try r.byte() & c.unsigned_param != 0;
            }
        }
        for (0..n) |i| {
            const ok = if (p.has_long_data[i]) blk: {
                const d = p.long_data[i].items;
                break :blk if (isBlob(p.params[i].type)) st.bind(i + 1, .{ .blob = d }) else st.bind(i + 1, .{ .text = d });
            } else if (nulls[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0)
                st.bind(i + 1, .null)
            else blk: {
                var buf: [64]u8 = undefined;
                break :blk st.bind(i + 1, try readParam(r, p.params[i], &buf));
            };
            ok catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.Unbindable,
            };
        }
    }
    // All the rows (0): the protocol's result set has them all.
    _ = try st.execute(0, sink);
}

fn isBlob(t: c.Type) bool {
    return switch (t) {
        .tiny_blob, .medium_blob, .long_blob, .blob, .geometry, .bit => true,
        else => false,
    };
}

/// One binary parameter value of type `pt` (text of dates and times in
/// `buf`; strings borrowed from the packet).
fn readParam(r: *packet.Reader, pt: ParamType, buf: *[64]u8) ExecuteError!xqlite.Value {
    return switch (pt.type) {
        .null => .null,
        .tiny => .{ .integer = if (pt.unsigned) try r.int(u8) else try r.int(i8) },
        .short, .year => .{ .integer = if (pt.unsigned) try r.int(u16) else try r.int(i16) },
        .long, .int24 => .{ .integer = if (pt.unsigned) try r.int(u32) else try r.int(i32) },
        .longlong => blk: {
            const v = try r.int(u64);
            if (pt.unsigned and v > std.math.maxInt(i64)) break :blk .{ .text = std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable };
            break :blk .{ .integer = @bitCast(v) };
        },
        .float => .{ .float = @as(f32, @bitCast(try r.int(u32))) },
        .double => .{ .float = @bitCast(try r.int(u64)) },
        .date, .datetime, .timestamp, .newdate => .{ .text = try readDateTime(r, pt.type == .date or pt.type == .newdate, buf) },
        .time => .{ .text = try readTime(r, buf) },
        .tiny_blob, .medium_blob, .long_blob, .blob, .geometry, .bit => .{ .blob = try r.lenencStr() },
        else => .{ .text = try r.lenencStr() },
    };
}

fn readDateTime(r: *packet.Reader, date_only: bool, buf: *[64]u8) ExecuteError![]const u8 {
    const n = try r.byte();
    var d: columns.DateTime = .{};
    if (n >= 4) {
        d.year = try r.int(u16);
        d.month = try r.byte();
        d.day = try r.byte();
    }
    if (n >= 7) {
        d.hour = try r.byte();
        d.minute = try r.byte();
        d.second = try r.byte();
    }
    if (n >= 11) d.micro = try r.int(u32);
    if (n != 0 and n != 4 and n != 7 and n != 11) return error.Malformed;
    if (date_only) return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day }) catch unreachable;
    const head = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ d.year, d.month, d.day, d.hour, d.minute, d.second }) catch unreachable;
    if (d.micro == 0) return head;
    const frac = std.fmt.bufPrint(buf[head.len..], ".{d:0>6}", .{d.micro}) catch unreachable;
    return buf[0 .. head.len + frac.len];
}

fn readTime(r: *packet.Reader, buf: *[64]u8) ExecuteError![]const u8 {
    const n = try r.byte();
    var t: columns.Time = .{};
    var days: u32 = 0;
    var hour: u8 = 0;
    if (n >= 8) {
        t.negative = try r.byte() != 0;
        days = try r.int(u32);
        hour = try r.byte();
        t.minute = try r.byte();
        t.second = try r.byte();
    }
    if (n >= 12) t.micro = try r.int(u32);
    if (n != 0 and n != 8 and n != 12) return error.Malformed;
    const hours = @as(u64, days) * 24 + hour;
    const head = std.fmt.bufPrint(buf, "{s}{d:0>2}:{d:0>2}:{d:0>2}", .{ if (t.negative) "-" else "", hours, t.minute, t.second }) catch unreachable;
    if (t.micro == 0) return head;
    const frac = std.fmt.bufPrint(buf[head.len..], ".{d:0>6}", .{t.micro}) catch unreachable;
    return buf[0 .. head.len + frac.len];
}

test "binary parameters" {
    const gpa = std.testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try columns.writeDateTime(gpa, &b, .{ .year = 2024, .month = 1, .day = 2, .hour = 3, .minute = 4, .second = 5, .micro = 6 }, false);
    try columns.writeTime(gpa, &b, .{ .negative = true, .hours = 49, .minute = 2, .second = 3 });
    try packet.int8(gpa, &b, std.math.maxInt(u64));
    var r: packet.Reader = .{ .data = b.items };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2024-01-02 03:04:05.000006", (try readParam(&r, .{ .type = .datetime }, &buf)).text);
    try std.testing.expectEqualStrings("-49:02:03", (try readParam(&r, .{ .type = .time }, &buf)).text);
    try std.testing.expectEqualStrings("18446744073709551615", (try readParam(&r, .{ .type = .longlong, .unsigned = true }, &buf)).text);
}
