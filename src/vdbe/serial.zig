//! Records: serial types, unpacking and comparison, and deferred cursor
//! moves (port of the second half of vdbeaux.c).
//!
//! C reads keys through raw pointers and relies on padding after the
//! buffers; here keys are slices, and reads past the end return zero
//! bytes, which only matters for corrupt records (they are reported as
//! corrupt either way).

const std = @import("std");
const vi = @import("vdbe_int.zig");
const mem = @import("mem.zig");
const int = @import("../sql/sqlite_int.zig");
const varint = @import("../util/varint.zig");
const btree = @import("../btree/btree.zig");

const Mem = vi.Mem;
const MEM = vi.MEM;
const KeyInfo = vi.KeyInfo;
const UnpackedRecord = vi.UnpackedRecord;
const VdbeCursor = vi.VdbeCursor;
const CollSeq = int.CollSeq;
const RC = int.RC;
const KeyInfoOrder = int.KeyInfoOrder;

/// sqlite3SmallTypeSizes: data sizes of serial types below 128.
pub const small_type_sizes = blk: {
    var t: [128]u8 = undefined;
    const fixed = [_]u8{ 0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0 };
    for (0..128) |i| t[i] = if (i < 12) fixed[i] else (i - 12) / 2;
    break :blk t;
};

/// Port of sqlite3VdbeSerialTypeLen().
pub inline fn serialTypeLen(serial_type: u32) u32 {
    if (serial_type >= 128) return (serial_type - 12) / 2;
    return small_type_sizes[serial_type];
}

/// A byte of `s`, or 0 past its end.
inline fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

fn get4(s: []const u8, i: usize) u32 {
    return @as(u32, at(s, i)) << 24 | @as(u32, at(s, i + 1)) << 16 | @as(u32, at(s, i + 2)) << 8 | at(s, i + 3);
}

fn get8(s: []const u8, i: usize) u64 {
    return @as(u64, get4(s, i)) << 32 | get4(s, i + 4);
}

pub const Varint32 = struct { value: u32, len: u32 };

/// The header varint at `i`, as the getVarint32() macro reads it: the
/// one-byte case inline, the rest out of line.
pub inline fn getVarint32(s: []const u8, i: usize) Varint32 {
    if (i < s.len and s[i] < 0x80) return .{ .value = s[i], .len = 1 };
    return getVarint32Slow(s, i);
}

/// Port of sqlite3GetVarint32() for getVarint32(): a varint of two or
/// more bytes, or one that starts past the end of `s` (which reads as 0).
pub noinline fn getVarint32Slow(s: []const u8, i: usize) Varint32 {
    if (i + varint.max_len <= s.len) {
        const d = varint.get32(s[i..]);
        return .{ .value = d.value, .len = d.len };
    }
    var buf: [9]u8 = undefined;
    for (&buf, 0..) |*b, k| b.* = at(s, i + k);
    const d = varint.get32(&buf);
    return .{ .value = d.value, .len = d.len };
}

/// Port of sqlite3VdbeSerialGet7(): a REAL; NaN becomes NULL (returns
/// true).
fn serialGet7(s: []const u8, i: usize, m: *Mem) bool {
    const x = if (i + 8 <= s.len) std.mem.readInt(u64, s[i..][0..8], .big) else get8(s, i);
    m.u = .{ .r = @bitCast(x) };
    if (std.math.isNan(m.u.r)) {
        m.flags = MEM.Null;
        return true;
    }
    m.flags = MEM.Real;
    return false;
}

/// Port of vdbeRecordDecodeInt(): the integer of serial type 1-6, 8 or 9
/// at `p`, which must hold all of its bytes (the ONE_BYTE_INT() to
/// sqlite3Get8byte() macros).
pub inline fn decodeIntPtr(serial_type: u32, p: [*]const u8) i64 {
    return switch (serial_type) {
        0, 1 => @as(i8, @bitCast(p[0])),
        2 => std.mem.readInt(i16, p[0..2], .big),
        3 => @as(i32, @bitCast(@as(u32, p[0]) << 24 | @as(u32, p[1]) << 16 | @as(u32, p[2]) << 8)) >> 8,
        4 => std.mem.readInt(i32, p[0..4], .big),
        5 => @as(i64, std.mem.readInt(i16, p[0..2], .big)) * (@as(i64, 1) << 32) + std.mem.readInt(u32, p[2..6], .big),
        6 => std.mem.readInt(i64, p[0..8], .big),
        else => @as(i64, serial_type) - 8,
    };
}

/// Port of vdbeRecordDecodeInt() on a slice: bytes past the end of `s`
/// read as 0.
inline fn decodeInt(serial_type: u32, s: []const u8, i: usize) i64 {
    const n: usize = if (serial_type < 2) 1 else small_type_sizes[serial_type & 0x7f];
    if (i + n <= s.len) return decodeIntPtr(serial_type, s.ptr + i);
    return decodeIntSlow(serial_type, s, i);
}

/// decodeInt() of a value running past the end of `s` (corrupt records).
noinline fn decodeIntSlow(serial_type: u32, s: []const u8, i: usize) i64 {
    return switch (serial_type) {
        0, 1 => @as(i8, @bitCast(at(s, i))),
        2 => @as(i16, @bitCast(@as(u16, at(s, i)) << 8 | at(s, i + 1))),
        3 => blk: {
            const v: u32 = @as(u32, at(s, i)) << 16 | @as(u32, at(s, i + 1)) << 8 | at(s, i + 2);
            break :blk @as(i32, @bitCast(v << 8)) >> 8;
        },
        4 => @as(i32, @bitCast(get4(s, i))),
        5 => blk: {
            const hi: i64 = @as(i16, @bitCast(@as(u16, at(s, i)) << 8 | at(s, i + 1)));
            break :blk hi * (@as(i64, 1) << 32) + get4(s, i + 2);
        },
        6 => @bitCast(get8(s, i)),
        else => @as(i64, serial_type) - 8,
    };
}

/// Port of sqlite3VdbeSerialGet() (the in-line switch of OP_Column) for
/// a value whose bytes are all at `p`. Strings and blobs point at `p`
/// (MEM_Ephem).
pub inline fn serialGetPtr(p: [*]const u8, serial_type: u32, m: *Mem) void {
    switch (serial_type) {
        10 => {
            // NULL with the virtual-table no-change flag (internal).
            m.flags = MEM.Null | MEM.Zero;
            m.n = 0;
            m.u = .{ .n_zero = 0 };
        },
        0, 11 => m.flags = MEM.Null,
        1...6, 8, 9 => {
            m.u = .{ .i = decodeIntPtr(serial_type, p) };
            m.flags = MEM.Int;
        },
        7 => {
            m.u = .{ .r = @bitCast(std.mem.readInt(u64, p[0..8], .big)) };
            m.flags = if (std.math.isNan(m.u.r)) MEM.Null else MEM.Real;
        },
        else => {
            m.z = @constCast(p);
            m.n = @intCast((serial_type - 12) / 2);
            m.flags = if (serial_type & 1 != 0) MEM.Str | MEM.Ephem else MEM.Blob | MEM.Ephem;
        },
    }
}

/// Port of sqlite3VdbeSerialGet(): decode the value of `serial_type` at
/// `s[i..]`. Strings and blobs point into `s` (MEM_Ephem). Bytes of a
/// number past the end of `s` read as 0.
pub fn serialGet(s: []const u8, i: usize, serial_type: u32, m: *Mem) void {
    if (serial_type >= 12 or i + small_type_sizes[serial_type] <= s.len) {
        return serialGetPtr(s.ptr + i, serial_type, m);
    }
    serialGetSlow(s, i, serial_type, m);
}

/// serialGet() of a number running past the end of `s` (corrupt records).
noinline fn serialGetSlow(s: []const u8, i: usize, serial_type: u32, m: *Mem) void {
    switch (serial_type) {
        1...6 => {
            m.u = .{ .i = decodeIntSlow(serial_type, s, i) };
            m.flags = MEM.Int;
        },
        7 => _ = serialGet7(s, i, m),
        else => serialGetPtr(s.ptr + i, serial_type, m),
    }
}

/// Port of sqlite3VdbeAllocUnpackedRecord(): room for a decoded key of
/// `key_info` (n_key_field + 1 fields).
pub fn allocUnpackedRecord(a: std.mem.Allocator, key_info: *KeyInfo) error{OutOfMemory}!*UnpackedRecord {
    const n = @as(usize, key_info.n_key_field) + 1;
    const r = try a.create(UnpackedRecord);
    const cells = try a.alloc(Mem, n);
    for (cells) |*c| c.* = .{ .db = key_info.db };
    r.* = .{ .key_info = key_info, .mem = cells.ptr, .n_field = @intCast(n) };
    return r;
}

/// Port of sqlite3VdbeRecordUnpack(): decode `key` into `r`, up to
/// r.n_field fields. Values point into `key`.
pub fn recordUnpack(key: []const u8, r: *UnpackedRecord) void {
    const ki = r.key_info;
    r.default_rc = 0;
    const hdr = getVarint32(key, 0);
    var idx: u32 = hdr.len;
    const sz_hdr = hdr.value;
    var d: u32 = sz_hdr;
    var u: u16 = 0;
    var m: [*]Mem = r.mem;
    while (idx < sz_hdr and d <= key.len) {
        const st = getVarint32(key, idx);
        idx += st.len;
        m[0].enc = ki.enc;
        m[0].db = ki.db;
        m[0].z_malloc = &.{};
        m[0].z = null;
        serialGet(key, d, st.value, &m[0]);
        d += serialTypeLen(st.value);
        u += 1;
        if (u >= r.n_field) break;
        m += 1;
    }
    if (d > key.len and u > 0) {
        // A corrupt record: the last value may lie past the end.
        const last = if (u < r.n_field) m - 1 else m;
        mem.setNull(&last[0]);
    }
    r.n_field = u;
}

/// Port of vdbeCompareMemString(): compare strings with a collation.
fn compareMemString(m1: *const Mem, m2: *const Mem, coll: *const CollSeq) i32 {
    // Only UTF-8 is supported, so no encoding change is ever needed.
    const cmp = coll.cmp.?;
    return switch (cmp(coll.user, m1.bytes(), m2.bytes())) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn isAllZero(z: []const u8) bool {
    for (z) |c| if (c != 0) return false;
    return true;
}

/// memcmp() of two slices of the same length: the difference of the
/// first differing bytes, or 0. Compares eight bytes at a time.
pub fn memcmp(a: []const u8, b: []const u8) i32 {
    std.debug.assert(a.len == b.len);
    const n = a.len;
    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) {
        const x = std.mem.readInt(u64, a[i..][0..8], .big);
        const y = std.mem.readInt(u64, b[i..][0..8], .big);
        if (x != y) {
            // The first differing byte is the highest one in big-endian.
            const shift: u6 = @intCast(56 - (@clz(x ^ y) & ~@as(u7, 7)));
            return @as(i32, @as(u8, @truncate(x >> shift))) - @as(u8, @truncate(y >> shift));
        }
    }
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(i32, a[i]) - b[i];
    }
    return 0;
}

/// Port of sqlite3BlobCompare(): memcmp order, the shorter first when one
/// is a prefix of the other.
pub fn blobCompare(b1: *const Mem, b2: *const Mem) i32 {
    const n1 = b1.n;
    const n2 = b2.n;
    if ((b1.flags | b2.flags) & MEM.Zero != 0) {
        if (b1.flags & b2.flags & MEM.Zero != 0) return b1.u.n_zero - b2.u.n_zero;
        if (b1.flags & MEM.Zero != 0) {
            if (!isAllZero(b2.bytes())) return -1;
            return b1.u.n_zero - n2;
        }
        if (!isAllZero(b1.bytes())) return 1;
        return n1 - b2.u.n_zero;
    }
    const n: usize = @intCast(@min(n1, n2));
    const c = memcmp(b1.bytes()[0..n], b2.bytes()[0..n]);
    if (c != 0) return c;
    return n1 - n2;
}

/// Port of sqlite3IntFloatCompare(): NaN counts as NULL (less than any
/// integer).
pub fn intFloatCompare(i: i64, r: f64) i32 {
    if (std.math.isNan(r)) return 1;
    if (r < -9223372036854775808.0) return 1;
    if (r >= 9223372036854775808.0) return -1;
    const y: i64 = @intFromFloat(r);
    if (i < y) return -1;
    if (i > y) return 1;
    const fi: f64 = @floatFromInt(i);
    return if (fi < r) -1 else @intFromBool(fi > r);
}

/// Port of sqlite3MemCompare(): NULLs first, then numbers, then text by
/// `coll` (memcmp if null), then blobs.
pub fn memCompare(m1: *const Mem, m2: *const Mem, coll: ?*const CollSeq) i32 {
    const f1 = m1.flags;
    const f2 = m2.flags;
    const combined = f1 | f2;
    if (combined & MEM.Null != 0) return @as(i32, f2 & MEM.Null) - @as(i32, f1 & MEM.Null);
    if (combined & (MEM.Int | MEM.Real | MEM.IntReal) != 0) {
        if (f1 & f2 & (MEM.Int | MEM.IntReal) != 0) {
            if (m1.u.i < m2.u.i) return -1;
            if (m1.u.i > m2.u.i) return 1;
            return 0;
        }
        if (f1 & f2 & MEM.Real != 0) {
            if (m1.u.r < m2.u.r) return -1;
            if (m1.u.r > m2.u.r) return 1;
            return 0;
        }
        if (f1 & (MEM.Int | MEM.IntReal) != 0) {
            if (f2 & MEM.Real != 0) return intFloatCompare(m1.u.i, m2.u.r);
            if (f2 & (MEM.Int | MEM.IntReal) != 0) {
                if (m1.u.i < m2.u.i) return -1;
                if (m1.u.i > m2.u.i) return 1;
                return 0;
            }
            return -1;
        }
        if (f1 & MEM.Real != 0) {
            if (f2 & (MEM.Int | MEM.IntReal) != 0) return -intFloatCompare(m2.u.i, m1.u.r);
            return -1;
        }
        return 1;
    }
    if (combined & MEM.Str != 0) {
        if (f1 & MEM.Str == 0) return 1;
        if (f2 & MEM.Str == 0) return -1;
        if (coll) |c| return compareMemString(m1, m2, c);
    }
    return blobCompare(m1, m2);
}

/// Port of sqlite3VdbeRecordCompareWithSkip(): compare the record `key1`
/// with the unpacked `r`: negative, zero or positive as key1 is less,
/// equal or greater. With `skip` the first fields are known to be equal.
/// Corruption sets r.err_code and returns 0.
pub fn recordCompareWithSkip(key1: []const u8, r: *UnpackedRecord, skip: bool) i32 {
    var d1: u32 = undefined;
    var i: usize = undefined;
    var sz_hdr1: u32 = undefined;
    var idx1: u32 = undefined;
    var rhs: [*]Mem = r.mem;
    var rc: i32 = 0;
    // Uninitialized, as in C: each use sets the fields it reads.
    var mem1: Mem = undefined;
    if (skip) {
        var s1: u32 = at(key1, 1);
        if (s1 < 0x80) {
            idx1 = 2;
        } else {
            const v = getVarint32(key1, 1);
            s1 = v.value;
            idx1 = 1 + v.len;
        }
        sz_hdr1 = at(key1, 0);
        d1 = sz_hdr1 + serialTypeLen(s1);
        i = 1;
        rhs += 1;
    } else {
        sz_hdr1 = at(key1, 0);
        if (sz_hdr1 < 0x80) {
            idx1 = 1;
        } else {
            const v = getVarint32(key1, 0);
            sz_hdr1 = v.value;
            idx1 = v.len;
        }
        d1 = sz_hdr1;
        i = 0;
    }
    if (d1 > key1.len) {
        r.err_code = RC.CORRUPT;
        return 0;
    }

    var serial_type: u32 = 0;
    while (true) {
        const p = &rhs[0];
        if (p.flags & (MEM.Int | MEM.IntReal) != 0) {
            serial_type = at(key1, idx1);
            if (serial_type >= 10) {
                rc = if (serial_type == 10) -1 else 1;
            } else if (serial_type == 0) {
                rc = -1;
            } else if (serial_type == 7) {
                _ = serialGet7(key1, d1, &mem1);
                rc = -intFloatCompare(p.u.i, mem1.u.r);
            } else {
                const lhs = decodeInt(serial_type, key1, d1);
                const rhs_v = p.u.i;
                if (lhs < rhs_v) {
                    rc = -1;
                } else if (lhs > rhs_v) {
                    rc = 1;
                }
            }
        } else if (p.flags & MEM.Real != 0) {
            serial_type = at(key1, idx1);
            if (serial_type >= 10) {
                rc = if (serial_type == 10) -1 else 1;
            } else if (serial_type == 0) {
                rc = -1;
            } else if (serial_type == 7) {
                if (serialGet7(key1, d1, &mem1)) {
                    rc = -1;
                } else if (mem1.u.r < p.u.r) {
                    rc = -1;
                } else if (mem1.u.r > p.u.r) {
                    rc = 1;
                }
            } else {
                serialGet(key1, d1, serial_type, &mem1);
                rc = intFloatCompare(mem1.u.i, p.u.r);
            }
        } else if (p.flags & MEM.Str != 0) {
            serial_type = getVarint32(key1, idx1).value;
            if (serial_type < 12) {
                rc = -1;
            } else if (serial_type & 1 == 0) {
                rc = 1;
            } else {
                const n: u32 = (serial_type - 12) / 2;
                const ki = r.key_info;
                if (d1 + n > key1.len or ki.n_all_field <= i) {
                    r.err_code = RC.CORRUPT;
                    return 0;
                }
                if (ki.coll[i]) |coll| {
                    mem1 = .{ .enc = ki.enc, .db = ki.db, .flags = MEM.Str, .z = @constCast(key1.ptr + d1), .n = @intCast(n) };
                    rc = compareMemString(&mem1, p, coll);
                } else {
                    const n_cmp: usize = @min(n, @as(u32, @intCast(p.n)));
                    rc = memcmp(key1[d1..][0..n_cmp], p.bytes()[0..n_cmp]);
                    if (rc == 0) rc = @as(i32, @intCast(n)) - p.n;
                }
            }
        } else if (p.flags & MEM.Blob != 0) {
            serial_type = getVarint32(key1, idx1).value;
            if (serial_type < 12 or serial_type & 1 != 0) {
                rc = -1;
            } else {
                const n: u32 = (serial_type - 12) / 2;
                if (d1 + n > key1.len) {
                    r.err_code = RC.CORRUPT;
                    return 0;
                }
                if (p.flags & MEM.Zero != 0) {
                    rc = if (!isAllZero(key1[d1..][0..n])) 1 else @as(i32, @intCast(n)) - p.u.n_zero;
                } else {
                    const n_cmp: usize = @min(n, @as(u32, @intCast(p.n)));
                    rc = memcmp(key1[d1..][0..n_cmp], p.bytes()[0..n_cmp]);
                    if (rc == 0) rc = @as(i32, @intCast(n)) - p.n;
                }
            }
        } else {
            serial_type = at(key1, idx1);
            if (!(serial_type == 0 or serial_type == 10 or (serial_type == 7 and serialGet7(key1, d1, &mem1)))) {
                rc = 1;
            }
        }

        if (rc != 0) {
            const sort_flags = r.key_info.sort_flags[i];
            if (sort_flags != 0) {
                const is_null = serial_type == 0 or p.flags & MEM.Null != 0;
                if (sort_flags & KeyInfoOrder.bignull == 0 or (sort_flags & KeyInfoOrder.desc != 0) != is_null) {
                    rc = -rc;
                }
            }
            return rc;
        }

        i += 1;
        if (i == r.n_field) break;
        rhs += 1;
        d1 += serialTypeLen(serial_type);
        if (d1 > key1.len) break;
        idx1 += varint.len(serial_type);
        if (idx1 >= sz_hdr1) {
            r.err_code = RC.CORRUPT;
            return 0;
        }
    }
    r.eq_seen = true;
    return r.default_rc;
}

/// Port of sqlite3VdbeRecordCompare().
pub fn recordCompare(key1: []const u8, r: *UnpackedRecord) i32 {
    return recordCompareWithSkip(key1, r, false);
}

/// Port of vdbeRecordCompareInt(): when the first field of `r` is an
/// integer and the header size fits in one byte.
fn recordCompareInt(key1: []const u8, r: *UnpackedRecord) i32 {
    const serial_type: u32 = at(key1, 1);
    const off: usize = at(key1, 0) & 0x3f;
    var lhs: i64 = undefined;
    if (serial_type >= 1 and serial_type <= 6) {
        lhs = decodeInt(serial_type, key1, off);
    } else if (serial_type == 8 or serial_type == 9) {
        lhs = @as(i64, serial_type) - 8;
    } else {
        return recordCompare(key1, r);
    }
    const v = r.u.i;
    if (v > lhs) return r.r1;
    if (v < lhs) return r.r2;
    if (r.n_field > 1) return recordCompareWithSkip(key1, r, true);
    r.eq_seen = true;
    return r.default_rc;
}

/// Port of vdbeRecordCompareString(): when the first field of `r` is text
/// in the BINARY collation and the header size fits in one byte.
fn recordCompareString(key1: []const u8, r: *UnpackedRecord) i32 {
    var serial_type: i32 = @as(i8, @bitCast(at(key1, 1)));
    while (true) {
        if (serial_type < 12) {
            if (serial_type < 0) {
                serial_type = @intCast(getVarint32(key1, 1).value);
                if (serial_type >= 12) continue;
            }
            return r.r1;
        }
        if (serial_type & 1 == 0) return r.r2;
        const sz_hdr: u32 = at(key1, 0);
        const n_str: u32 = @intCast(@divTrunc(serial_type - 12, 2));
        if (sz_hdr + n_str > key1.len) {
            r.err_code = RC.CORRUPT;
            return 0;
        }
        const pn: u32 = @intCast(r.n);
        const n_cmp = @min(pn, n_str);
        var res = memcmp(key1[sz_hdr..][0..n_cmp], r.u.z.?[0..n_cmp]);
        if (res > 0) return r.r2;
        if (res < 0) return r.r1;
        res = @as(i32, @intCast(n_str)) - r.n;
        if (res == 0) {
            if (r.n_field > 1) return recordCompareWithSkip(key1, r, true);
            r.eq_seen = true;
            return r.default_rc;
        }
        return if (res > 0) r.r2 else r.r1;
    }
}

pub const RecordCompare = *const fn (key1: []const u8, r: *UnpackedRecord) i32;

/// Port of sqlite3VdbeFindCompare(): the fastest comparator for `r`.
pub fn findCompare(r: *UnpackedRecord) RecordCompare {
    const ki = r.key_info;
    if (ki.n_all_field <= 13) {
        const flags = r.mem[0].flags;
        if (ki.sort_flags[0] != 0) {
            if (ki.sort_flags[0] & KeyInfoOrder.bignull != 0) return recordCompare;
            r.r1 = 1;
            r.r2 = -1;
        } else {
            r.r1 = -1;
            r.r2 = 1;
        }
        if (flags & MEM.Int != 0) {
            r.u = .{ .i = r.mem[0].u.i };
            return recordCompareInt;
        }
        if (flags & (MEM.Real | MEM.IntReal | MEM.Null | MEM.Blob) == 0 and isBinary(ki.coll[0])) {
            r.u = .{ .z = r.mem[0].z };
            r.n = r.mem[0].n;
            return recordCompareString;
        }
    }
    return recordCompare;
}

/// Port of sqlite3IsBinary(): no collation, or BINARY.
pub fn isBinary(coll: ?*const CollSeq) bool {
    const c = coll orelse return true;
    return c.cmp == binaryCollation;
}

/// The BINARY collation (binCollFunc): memcmp, then length.
pub fn binaryCollation(_: ?*anyopaque, a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    const c = memcmp(a[0..n], b[0..n]);
    if (c != 0) return if (c < 0) .lt else .gt;
    return std.math.order(a.len, b.len);
}

/// Port of sqlite3VdbeIdxRowid(): the rowid at the end of the index entry
/// under the cursor.
pub fn idxRowid(db: *int.Sqlite3, cur: *btree.Cursor) (mem.Error || btree.Error)!i64 {
    const n_cell_key = cur.payloadSize();
    var m: Mem = .{ .db = db, .flags = 0 };
    try mem.fromBtreeZeroOffset(cur, n_cell_key, &m);
    defer mem.releaseMalloc(&m);
    const z = m.bytes();
    const sz_hdr = getVarint32(z, 0).value;
    if (sz_hdr < 3 or sz_hdr > z.len) return error.Corrupt;
    const type_rowid = getVarint32(z, sz_hdr - 1).value;
    if (type_rowid < 1 or type_rowid > 9 or type_rowid == 7) return error.Corrupt;
    const len_rowid = small_type_sizes[type_rowid];
    if (z.len < sz_hdr + len_rowid) return error.Corrupt;
    var v: Mem = .{};
    serialGet(z, z.len - len_rowid, type_rowid, &v);
    return v.u.i;
}

/// Port of sqlite3VdbeIdxKeyCompare(): compare the index entry under the
/// cursor (ignoring its rowid) with `r`.
pub fn idxKeyCompare(db: *int.Sqlite3, c: *VdbeCursor, r: *UnpackedRecord) (mem.Error || btree.Error)!i32 {
    const cur = c.uc.cursor;
    const n_cell_key = cur.payloadSize();
    if (n_cell_key == 0 or n_cell_key > 0x7fffffff) return error.Corrupt;
    var m: Mem = .{ .db = db, .flags = 0 };
    try mem.fromBtreeZeroOffset(cur, n_cell_key, &m);
    defer mem.releaseMalloc(&m);
    return recordCompareWithSkip(m.bytes(), r, false);
}

/// Port of sqlite3VdbeFinishMoveto(): carry out a deferred seek.
pub fn finishMoveto(c: *VdbeCursor) btree.Error!void {
    std.debug.assert(c.deferred_moveto and c.is_table and c.e_cur_type == .btree);
    const res = try c.uc.cursor.tableMoveto(c.moveto_target, false);
    if (res != .eq) return error.Corrupt;
    c.deferred_moveto = false;
    c.cache_status = vi.cache_stale;
}

/// Port of sqlite3VdbeHandleMovedCursor(): the row under the cursor moved
/// (deleted or rebalanced); restore the position, or make it a NULL row.
pub fn handleMovedCursor(c: *VdbeCursor) btree.Error!void {
    const different = try c.uc.cursor.restore();
    c.cache_status = vi.cache_stale;
    if (different) c.null_row = true;
}

/// Port of sqlite3VdbeCursorRestore().
pub fn cursorRestore(c: *VdbeCursor) btree.Error!void {
    if (c.uc.cursor.hasMoved()) return handleMovedCursor(c);
}

/// Port of sqlite3BtreeIndexMoveto() taking an unpacked record: move the
/// index cursor near `r`.
pub fn indexMoveto(cur: *btree.Cursor, r: *UnpackedRecord) btree.Error!std.math.Order {
    const kc: IndexKeyCtx = .{ .r = r, .cmp = findCompare(r) };
    return cur.indexMoveto(kc.indexKey());
}

/// A btree.IndexKey comparing stored keys with an unpacked record, as
/// sqlite3BtreeIndexMoveto() calls xRecordCompare.
pub const IndexKeyCtx = struct {
    r: *UnpackedRecord,
    cmp: RecordCompare,

    /// Calls `cmp` through the function pointer.
    pub fn compare(ctx: *const anyopaque, stored: []const u8) btree.CompareError!std.math.Order {
        const self: *const IndexKeyCtx = @ptrCast(@alignCast(ctx));
        return finish(self.r, self.cmp(stored, self.r));
    }

    /// compare() with the comparator fixed, so that the b-tree's call
    /// reaches it directly, as C calls xRecordCompare.
    fn compareWith(comptime cmp: RecordCompare) *const fn (ctx: *const anyopaque, stored: []const u8) btree.CompareError!std.math.Order {
        return struct {
            fn f(ctx: *const anyopaque, stored: []const u8) btree.CompareError!std.math.Order {
                const self: *const IndexKeyCtx = @ptrCast(@alignCast(ctx));
                return finish(self.r, @call(.always_inline, cmp, .{ stored, self.r }));
            }
        }.f;
    }

    inline fn finish(r: *UnpackedRecord, c: i32) btree.CompareError!std.math.Order {
        if (r.err_code != 0) {
            return if (r.err_code == RC.NOMEM) error.OutOfMemory else error.Corrupt;
        }
        // The b-tree wants the order of the stored key relative to the
        // search key.
        if (c < 0) return .lt;
        if (c > 0) return .gt;
        return .eq;
    }

    pub fn indexKey(self: *const IndexKeyCtx) btree.IndexKey {
        const f = if (self.cmp == &recordCompareInt)
            compareWith(recordCompareInt)
        else if (self.cmp == &recordCompareString)
            compareWith(recordCompareString)
        else if (self.cmp == &recordCompare)
            compareWith(recordCompare)
        else
            compare;
        return .{ .ctx = self, .compare = f };
    }
};

/// The b-tree's view of `ki` (for restoring saved positions and inserts
/// without a prior seek): btreeMoveto() for index keys.
pub fn btreeKeyInfo(ki: *KeyInfo) btree.KeyInfo {
    return .{ .ctx = ki, .seek = seekPacked };
}

fn seekPacked(ctx: *const anyopaque, cur: *btree.Cursor, key: []const u8) btree.Error!std.math.Order {
    const ki: *KeyInfo = @ptrCast(@alignCast(@constCast(ctx)));
    const n = @as(usize, ki.n_key_field) + 1;
    var stack: [16]Mem = undefined;
    const gpa = if (ki.db) |db| db.gpa else @import("../sql/malloc.zig").allocator;
    const cells = if (n <= stack.len) stack[0..n] else try gpa.alloc(Mem, n);
    defer if (n > stack.len) gpa.free(cells);
    for (cells) |*c| c.* = .{ .db = ki.db };
    var r: UnpackedRecord = .{ .key_info = ki, .mem = cells.ptr, .n_field = @intCast(n) };
    recordUnpack(key, &r);
    if (r.n_field == 0 or r.n_field > ki.n_all_field) return error.Corrupt;
    return indexMoveto(cur, &r);
}

/// BTREE_FDK_RANGE: entries findIndexKey() looks at on either side.
const fdk_range = 10;
/// BTREE_ULPDISTORTION: the ULPs by which REAL key fields may differ.
const ulp_distortion = 2;

/// Port of vdbeSkipField(): whether field `i_col` is left out of the
/// comparison. Fields in `mask` are skipped, unless `integrity`, in which
/// case only REAL values a few ULPs apart are.
fn skipField(mask: int.Bitmask, i_col: usize, m1: *const Mem, m2: *const Mem, integrity: bool) bool {
    if (i_col >= int.bms or mask & (@as(int.Bitmask, 1) << @intCast(i_col)) == 0) return false;
    if (!integrity) return true;
    if (m1.flags & MEM.Real != 0 and m2.flags & MEM.Real != 0) {
        const a: u64 = @bitCast(m1.u.r);
        const b: u64 = @bitCast(m2.u.r);
        if ((if (a < b) b - a else a - b) <= ulp_distortion) return true;
    }
    return false;
}

/// Port of vdbeIsMatchingIndexKey(): compare the index entry under `cur`
/// with `r`, field by field, as skipField() allows. Returns the usual
/// negative, zero or positive result.
fn isMatchingIndexKey(cur: *btree.Cursor, integrity: bool, mask: int.Bitmask, r: *UnpackedRecord) btree.Error!i32 {
    const ki = r.key_info;
    const gpa = ki.db.?.gpa;
    const n_rec = cur.payloadSize();
    if (n_rec > 0x7fffffff) return error.Corrupt;
    // Read the record in place when it is all on the page; copy it only
    // when it spills onto overflow pages. (The C code always copies, with
    // five zeroed spare bytes for a corrupt header varint; getVarint32()
    // and serialGet() here read 0 past the end of the slice instead.)
    const local = cur.payloadFetch();
    var copy: ?[]u8 = null;
    defer if (copy) |z| gpa.free(z);
    const rec: []const u8 = if (n_rec <= local.len) local[0..n_rec] else blk: {
        const z = try gpa.alloc(u8, n_rec);
        copy = z;
        try cur.payload(0, z);
        break :blk z;
    };

    const hdr = getVarint32(rec, 0);
    const sz_hdr = hdr.value;
    if (sz_hdr > 98307) return error.Corrupt;
    var idx_hdr: u32 = hdr.len;
    var idx_rec: u32 = sz_hdr;
    var res: i32 = 0;
    var m: Mem = .{ .db = ki.db, .enc = ki.enc };
    for (0..ki.n_all_field) |ii| {
        if (idx_hdr >= sz_hdr) return error.Corrupt;
        const st = getVarint32(rec, idx_hdr);
        idx_hdr += st.len;
        const n_serial = serialTypeLen(st.value);
        if (@as(u64, idx_rec) + n_serial > n_rec) return error.Corrupt;
        serialGet(rec, idx_rec, st.value, &m);
        if (!skipField(mask, ii, &r.mem[ii], &m, integrity)) {
            res = memCompare(&m, &r.mem[ii], ki.coll[ii]);
            if (res != 0) break;
        }
        idx_rec += n_serial;
    }
    return res;
}

/// Port of sqlite3VdbeFindIndexKey(): the key `r` of index `idx` should be
/// in the index but was not found exactly, perhaps because an indexed
/// expression or VIRTUAL column computes a REAL a little differently.
/// Look for the entry near `cur` (and, unless `integrity`, then in the
/// whole index), comparing as isMatchingIndexKey() does. Returns 0 with
/// `cur` on the entry if found, nonzero otherwise.
pub fn findIndexKey(cur: *btree.Cursor, idx: *const int.Index, r: *UnpackedRecord, integrity: bool) btree.Error!i32 {
    var res: i32 = 1;
    var mask: int.Bitmask = 0;
    for (0..@min(idx.n_column, int.bms)) |ii| {
        const i_col = idx.ai_column[ii];
        if (i_col == int.XN_EXPR or (i_col >= 0 and idx.table.cols[@intCast(i_col)].col_flags & int.COLFLAG.VIRTUAL != 0)) {
            mask |= @as(int.Bitmask, 1) << @intCast(ii);
        }
    }
    // Without expressions or virtual columns the key cannot be elsewhere.
    if (mask == 0) return res;

    // Step back fdk_range entries. Hitting the start means the first
    // scan covers the whole index (n_step < 0).
    var n_step: i32 = fdk_range * 2;
    var ii: usize = 0;
    while (!cur.eof() and ii < fdk_range) : (ii += 1) {
        if (!try cur.previous()) {
            _ = try cur.first();
            n_step = -1;
            break;
        }
    }
    // At most two scans: near the cursor, then (unless `integrity`) the
    // whole index.
    while (!cur.eof()) {
        var i: i32 = 0;
        while (i < n_step or n_step < 0) : (i += 1) {
            res = try isMatchingIndexKey(cur, integrity, mask, r);
            if (res == 0) break;
            if (!try cur.next()) break;
        }
        if (n_step < 0 or res == 0 or integrity) break;
        n_step = -1;
        _ = try cur.first();
    }
    return res;
}

test "serial: compare records" {
    // Record (1, 'abc') vs unpacked (1, 'abd').
    const rec = [_]u8{ 3, 1, 19, 1, 'a', 'b', 'c' };
    var sort_flags = [_]u8{ 0, 0 };
    var coll = [_]?*CollSeq{ null, null };
    var ki: KeyInfo = .{ .n_key_field = 2, .n_all_field = 2, .db = null, .sort_flags = &sort_flags, .coll = &coll };
    var cells: [2]Mem = .{ .{}, .{} };
    mem.setInt64(&cells[0], 1);
    try mem.setStr(&cells[1], "abd", vi.ENC.UTF8, .static);
    var r: UnpackedRecord = .{ .key_info = &ki, .mem = &cells, .n_field = 2 };
    try std.testing.expect(recordCompare(&rec, &r) < 0);
    const f = findCompare(&r);
    try std.testing.expect(f(&rec, &r) < 0);
    try mem.setStr(&cells[1], "abc", vi.ENC.UTF8, .static);
    r.default_rc = 0;
    try std.testing.expectEqual(@as(i32, 0), recordCompare(&rec, &r));
    try std.testing.expect(r.eq_seen);

    var u: UnpackedRecord = .{ .key_info = &ki, .mem = &cells, .n_field = 2 };
    recordUnpack(&rec, &u);
    try std.testing.expectEqual(@as(u16, 2), u.n_field);
    try std.testing.expectEqual(@as(i64, 1), cells[0].u.i);
    try std.testing.expectEqualStrings("abc", cells[1].bytes());
}
