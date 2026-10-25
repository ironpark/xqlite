//! Operations on Mem values (port of vdbemem.c, plus the affinity helpers
//! of vdbe.c). A Mem owns at most one buffer, `z_malloc`; `z` may point
//! into it, to static or ephemeral memory, or to memory freed by `x_del`.
//!
//! Only UTF-8 text is supported so far: changing a value to a UTF-16
//! encoding fails.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const numeric = @import("../sql/numeric.zig");
const printf = @import("../sql/printf.zig");
const btree = @import("../btree/btree.zig");

const Mem = vi.Mem;
const MEM = vi.MEM;
const ENC = vi.ENC;
const Aff = int.Aff;
const RC = int.RC;
const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const Destructor = vi.Destructor;

pub const Error = error{ OutOfMemory, TooBig };

/// SQLITE_MAX_LENGTH: the default limit on TEXT and BLOB sizes.
pub const max_length = 1000000000;

/// SQLITE_MAX_ALLOCATION_SIZE.
pub const max_allocation_size = 2147483391;

/// The allocator of a Mem's buffers: its connection's, or the default for
/// values not tied to a connection.
fn gpa(m: *const Mem) std.mem.Allocator {
    return if (m.db) |db| db.gpa else std.heap.smp_allocator;
}

/// Port of sqlite3VdbeChangeEncoding().
pub fn changeEncoding(m: *Mem, desired: u8) Error!void {
    if (m.flags & MEM.Str == 0) {
        m.enc = desired;
        return;
    }
    if (m.enc == desired) return;
    // UTF-16 is not ported yet.
    return error.OutOfMemory;
}

/// Port of sqlite3VdbeMemGrow(): make `z` a writable buffer of at least
/// `n` bytes, copying the current content if `preserve`.
pub fn grow(m: *Mem, n: usize, preserve_arg: bool) Error!void {
    var preserve = preserve_arg;
    const a = gpa(m);
    if (m.z_malloc.len > 0 and preserve and m.z == m.z_malloc.ptr) {
        m.z_malloc = a.realloc(m.z_malloc, n) catch {
            a.free(m.z_malloc);
            m.z_malloc = &.{};
            setNull(m);
            m.z = null;
            return error.OutOfMemory;
        };
        m.z = m.z_malloc.ptr;
        preserve = false;
    } else {
        if (m.z_malloc.len > 0) a.free(m.z_malloc);
        m.z_malloc = a.alloc(u8, n) catch {
            m.z_malloc = &.{};
            setNull(m);
            m.z = null;
            return error.OutOfMemory;
        };
    }
    if (preserve) if (m.z) |z| {
        @memcpy(m.z_malloc[0..@intCast(m.n)], z[0..@intCast(m.n)]);
    };
    if (m.flags & MEM.Dyn != 0) m.x_del.?(m.z);
    m.z = m.z_malloc.ptr;
    m.flags &= ~(MEM.Dyn | MEM.Ephem | MEM.Static);
}

/// Port of sqlite3VdbeMemClearAndResize(): a buffer of at least `sz`
/// bytes; string and blob content is discarded, numbers kept.
pub fn clearAndResize(m: *Mem, sz: usize) Error!void {
    if (m.z_malloc.len < sz) return grow(m, sz, false);
    m.z = m.z_malloc.ptr;
    m.flags &= MEM.Null | MEM.Int | MEM.Real | MEM.IntReal;
}

/// Port of sqlite3VdbeMemZeroTerminateIfAble(): NUL-terminate a string if
/// there is room. An optimization; returns whether it is terminated.
pub fn zeroTerminateIfAble(m: *Mem) bool {
    if (m.flags & (MEM.Str | MEM.Term | MEM.Ephem | MEM.Static) != MEM.Str) return false;
    if (m.enc != ENC.UTF8) return false;
    if (m.flags & MEM.Dyn != 0) return false;
    if (m.z_malloc.len >= m.n + 1) {
        m.z.?[@intCast(m.n)] = 0;
        m.flags |= MEM.Term;
        return true;
    }
    return false;
}

/// Port of vdbeMemAddTerminator(): three zero bytes, enough for UTF-16.
fn addTerminator(m: *Mem) Error!void {
    const n: usize = @intCast(m.n);
    try grow(m, n + 3, true);
    const z = m.z.?;
    z[n] = 0;
    z[n + 1] = 0;
    z[n + 2] = 0;
    m.flags |= MEM.Term;
}

/// Port of sqlite3VdbeMemMakeWriteable(): move a string or blob into the
/// Mem's own buffer.
pub fn makeWriteable(m: *Mem) Error!void {
    if (m.flags & (MEM.Str | MEM.Blob) != 0) {
        if (m.flags & MEM.Zero != 0) try expandBlob(m);
        if (m.z_malloc.len == 0 or m.z != m.z_malloc.ptr) try addTerminator(m);
    }
    m.flags &= ~MEM.Ephem;
}

/// Port of sqlite3VdbeMemExpandBlob(): materialize the zero tail of a
/// MEM_Zero blob.
pub fn expandBlob(m: *Mem) Error!void {
    std.debug.assert(m.flags & MEM.Zero != 0);
    var n_byte: i32 = m.n + m.u.n_zero;
    if (n_byte <= 0) {
        if (m.flags & MEM.Blob == 0) return;
        n_byte = 1;
    }
    try grow(m, @intCast(n_byte), true);
    @memset(m.z.?[@intCast(m.n)..][0..@intCast(m.u.n_zero)], 0);
    m.n += m.u.n_zero;
    m.flags &= ~(MEM.Zero | MEM.Term);
}

/// Port of sqlite3VdbeMemNulTerminate().
pub fn nulTerminate(m: *Mem) Error!void {
    if (m.flags & (MEM.Term | MEM.Str) != MEM.Str) return;
    return addTerminator(m);
}

/// Port of vdbeMemRenderNum(): the text of a number, as SQLite prints it:
/// integers plainly (IntReal with ".0"), reals with "%!.*g".
fn renderNum(buf: []u8, m: *Mem) usize {
    std.debug.assert(m.flags & (MEM.Int | MEM.Real | MEM.IntReal) != 0);
    if (m.flags & (MEM.Int | MEM.IntReal) != 0) {
        var n = numeric.int64ToText(m.u.i, buf);
        if (m.flags & MEM.IntReal != 0) {
            @memcpy(buf[n..][0..2], ".0");
            n += 2;
        }
        return n;
    }
    const digits: u8 = if (m.db) |db| db.n_fp_digit else 17;
    var tmp: [64]u8 = undefined;
    const s = printf.formatDouble(&tmp, m.u.r, digits);
    @memcpy(buf[0..s.len], s);
    return s.len;
}

/// Port of sqlite3VdbeMemStringify(): add a text representation to a
/// number. With `force` the numeric representation is dropped.
pub fn stringify(m: *Mem, enc: u8, force: bool) Error!void {
    const n_byte = 32;
    std.debug.assert(m.flags & (MEM.Str | MEM.Blob | MEM.Zero) == 0);
    clearAndResize(m, n_byte) catch |err| {
        m.enc = 0;
        return err;
    };
    const n = renderNum(m.z_malloc[0..n_byte], m);
    m.z.?[n] = 0;
    m.n = @intCast(n);
    m.enc = ENC.UTF8;
    m.flags |= MEM.Str | MEM.Term;
    if (force) m.flags &= ~(MEM.Int | MEM.Real | MEM.IntReal);
    try changeEncoding(m, enc);
}

/// Port of sqlite3VdbeMemFinalize(): run the finalizer of the aggregate
/// whose context is in `m` and store the result there. Returns the error
/// code the function reported.
pub fn finalize(m: *Mem, func: *FuncDef) i32 {
    const func_mod = @import("func.zig");
    var t: Mem = .{ .db = m.db };
    var ctx: vi.Context = .{ .out = &t, .mem = m, .func = func, .enc = if (m.db) |db| db.enc else ENC.UTF8 };
    func_mod.callFinalize(func, &ctx);
    std.debug.assert(m.flags & MEM.Dyn == 0);
    if (m.z_malloc.len > 0) gpa(m).free(m.z_malloc);
    m.* = t;
    return ctx.is_error;
}

/// Port of sqlite3VdbeMemAggValue(): the current value of a window
/// aggregate.
pub fn aggValue(accum: *Mem, out: *Mem, func: *FuncDef) i32 {
    const func_mod = @import("func.zig");
    setNull(out);
    var ctx: vi.Context = .{ .out = out, .mem = accum, .func = func, .enc = if (accum.db) |db| db.enc else ENC.UTF8 };
    func_mod.callValue(func, &ctx);
    return ctx.is_error;
}

/// Port of vdbeMemClearExternAndSetNull().
fn clearExternAndSetNull(m: *Mem) void {
    std.debug.assert(m.isDynamic());
    if (m.flags & MEM.Agg != 0) {
        _ = finalize(m, m.u.def);
        std.debug.assert(m.flags & MEM.Agg == 0);
    }
    if (m.flags & MEM.Dyn != 0) m.x_del.?(m.z);
    m.flags = MEM.Null;
}

/// Port of vdbeMemClear().
fn clear(m: *Mem) void {
    if (m.isDynamic()) clearExternAndSetNull(m);
    if (m.z_malloc.len > 0) {
        gpa(m).free(m.z_malloc);
        m.z_malloc = &.{};
    }
    m.z = null;
}

/// Port of sqlite3VdbeMemRelease(): free everything the Mem holds.
pub fn release(m: *Mem) void {
    if (m.isDynamic() or m.z_malloc.len > 0) clear(m);
}

/// Port of sqlite3VdbeMemReleaseMalloc().
pub fn releaseMalloc(m: *Mem) void {
    std.debug.assert(!m.isDynamic());
    if (m.z_malloc.len > 0) clear(m);
}

/// Port of sqlite3VdbeIntValue(): the value as an integer (0 for NULL;
/// text and blobs are parsed as far as they look like a number).
pub fn intValue(m: *const Mem) i64 {
    const flags = m.flags;
    if (flags & (MEM.Int | MEM.IntReal) != 0) return m.u.i;
    if (flags & MEM.Real != 0) return numeric.realToI64(m.u.r);
    if (flags & (MEM.Str | MEM.Blob) != 0) if (m.z) |z| {
        var v: i64 = 0;
        _ = util.atoi64(z[0..@intCast(m.n)], &v);
        return v;
    };
    return 0;
}

/// Port of sqlite3MemRealValueRC(): convert the text of a string or blob
/// to a double. The result follows sqlite3AtoF(): 0 if not a number,
/// negative if only a prefix is, positive if all of it is; bit 2 set if
/// it has a decimal point or exponent.
pub fn realValueRC(m: *Mem, value: *f64) i32 {
    std.debug.assert(m.flags & (MEM.Str | MEM.Blob) != 0);
    const z = m.z orelse {
        value.* = 0.0;
        return 0;
    };
    std.debug.assert(m.enc == ENC.UTF8 or m.enc == 0);
    if (m.flags & MEM.Term != 0 or zeroTerminateIfAble(m)) return numeric.atoF(@ptrCast(z), value);
    if (m.n == 0) {
        value.* = 0.0;
        return 0;
    }
    // sqlite3MemRealValueRCSlowPath(): a NUL-terminated copy.
    const a = gpa(m);
    const z_copy = a.dupeSentinel(u8, z[0..@intCast(m.n)], 0) catch {
        value.* = 0.0;
        return 0;
    };
    defer a.free(z_copy);
    return numeric.atoF(z_copy.ptr, value);
}

/// Port of sqlite3VdbeRealValue().
pub fn realValue(m: *Mem) f64 {
    if (m.flags & MEM.Real != 0) return m.u.r;
    if (m.flags & (MEM.Int | MEM.IntReal) != 0) return @floatFromInt(m.u.i);
    if (m.flags & (MEM.Str | MEM.Blob) != 0) {
        var r: f64 = undefined;
        _ = realValueRC(m, &r);
        return r;
    }
    return 0.0;
}

/// Port of sqlite3VdbeBooleanValue(): the truth of a value, `if_null` for
/// NULL.
pub fn booleanValue(m: *Mem, if_null: bool) bool {
    if (m.flags & (MEM.Int | MEM.IntReal) != 0) return m.u.i != 0;
    if (m.flags & MEM.Null != 0) return if_null;
    return realValue(m) != 0.0;
}

/// Port of sqlite3VdbeIntegerAffinity(): turn a real with an exact
/// integer value into an integer.
pub fn integerAffinity(m: *Mem) void {
    std.debug.assert(m.flags & (MEM.Real | MEM.IntReal) != 0);
    if (m.flags & MEM.IntReal != 0) {
        m.setTypeFlag(MEM.Int);
        return;
    }
    const ix = numeric.realToI64(m.u.r);
    // Only if the round trip is exact and not at the ends of the range
    // (ticket #3922).
    if (m.u.r == @as(f64, @floatFromInt(ix)) and ix > std.math.minInt(i64) and ix < std.math.maxInt(i64)) {
        m.u.i = ix;
        m.setTypeFlag(MEM.Int);
    }
}

/// Port of sqlite3VdbeMemIntegerify().
pub fn integerify(m: *Mem) void {
    m.u.i = intValue(m);
    m.setTypeFlag(MEM.Int);
}

/// Port of sqlite3VdbeMemRealify().
pub fn realify(m: *Mem) void {
    m.u.r = realValue(m);
    m.setTypeFlag(MEM.Real);
}

/// Port of sqlite3VdbeMemNumerify(): convert to INTEGER or REAL, as much
/// of the text as looks like a number.
pub fn numerify(m: *Mem) void {
    if (m.flags & (MEM.Int | MEM.Real | MEM.IntReal | MEM.Null) == 0) {
        std.debug.assert(m.flags & (MEM.Blob | MEM.Str) != 0);
        var r: f64 = undefined;
        const rc = realValueRC(m, &r);
        m.u.r = r;
        var ix: i64 = 0;
        const as_int = rc & 2 == 0 and @intFromEnum(util.atoi64(m.bytes(), &ix)) < 2;
        if (as_int) {
            m.u.i = ix;
            m.setTypeFlag(MEM.Int);
        } else {
            ix = numeric.realToI64(r);
            if (numeric.realSameAsInt(r, ix)) {
                m.u.i = ix;
                m.setTypeFlag(MEM.Int);
            } else {
                m.setTypeFlag(MEM.Real);
            }
        }
    }
    m.flags &= ~(MEM.Str | MEM.Blob | MEM.Zero);
}

/// Port of sqlite3VdbeMemCast(): CAST(value AS affinity).
pub fn cast(m: *Mem, aff: u8, enc: u8) Error!void {
    if (m.flags & MEM.Null != 0) return;
    switch (aff) {
        Aff.blob => {
            if (m.flags & MEM.Blob == 0) {
                try applyAffinity(m, Aff.text, enc);
                if (m.flags & MEM.Str != 0) m.setTypeFlag(MEM.Blob);
            } else {
                m.flags &= ~(MEM.TypeMask & ~MEM.Blob);
            }
        },
        Aff.numeric => numerify(m),
        Aff.integer => integerify(m),
        Aff.real => realify(m),
        else => {
            std.debug.assert(aff == Aff.text);
            m.flags |= (m.flags & MEM.Blob) >> 3;
            try applyAffinity(m, Aff.text, enc);
            m.flags &= ~(MEM.Int | MEM.Real | MEM.IntReal | MEM.Blob | MEM.Zero);
            if (enc != ENC.UTF8) m.n &= ~@as(i32, 1);
            try changeEncoding(m, enc);
            _ = zeroTerminateIfAble(m);
        },
    }
}

/// Port of sqlite3VdbeMemSetNull(): free external content and become NULL,
/// keeping the buffer.
pub fn setNull(m: *Mem) void {
    if (m.isDynamic()) {
        clearExternAndSetNull(m);
    } else {
        m.flags = MEM.Null;
    }
}

/// Port of sqlite3VdbeMemSetZeroBlob().
pub fn setZeroBlob(m: *Mem, n: i32) void {
    release(m);
    m.flags = MEM.Blob | MEM.Zero;
    m.n = 0;
    m.u = .{ .n_zero = @max(n, 0) };
    m.enc = ENC.UTF8;
    m.z = null;
}

/// Port of sqlite3VdbeMemSetInt64().
pub fn setInt64(m: *Mem, val: i64) void {
    if (m.isDynamic()) setNull(m);
    m.u = .{ .i = val };
    m.flags = MEM.Int;
}

/// Port of sqlite3VdbeMemSetDouble(): NaN becomes NULL.
pub fn setDouble(m: *Mem, val: f64) void {
    setNull(m);
    if (!std.math.isNan(val)) {
        m.u = .{ .r = val };
        m.flags = MEM.Real;
    }
}

/// Port of sqlite3NoopDestructor().
pub fn noopDestructor(_: ?*anyopaque) void {}

/// Port of sqlite3VdbeMemSetPointer(): a NULL carrying a pointer of type
/// `ptype` (sqlite3_result_pointer).
pub fn setPointer(m: *Mem, ptr: ?*anyopaque, ptype: ?[*:0]const u8, destructor: ?*const fn (?*anyopaque) void) void {
    std.debug.assert(m.flags == MEM.Null);
    clear(m);
    m.u = .{ .z_ptype = ptype orelse "" };
    m.z = @ptrCast(ptr);
    m.flags = MEM.Null | MEM.Dyn | MEM.Subtype | MEM.Term;
    m.e_subtype = 'p';
    m.x_del = destructor orelse noopDestructor;
}

/// Port of sqlite3VdbeMemTooBig(): a string or blob over SQLITE_LIMIT_LENGTH.
pub fn tooBig(m: *const Mem) bool {
    if (m.flags & (MEM.Str | MEM.Blob) != 0) {
        var n = m.n;
        if (m.flags & MEM.Zero != 0) n += m.u.n_zero;
        return n > m.db.?.limit(.length);
    }
    return false;
}

/// Port of sqlite3VdbeMemShallowCopy(): copy the value without its buffer;
/// strings then point at `from`'s, marked `src_type` (MEM_Ephem or
/// MEM_Static) unless static already.
pub fn shallowCopy(to: *Mem, from: *const Mem, src_type: u16) void {
    if (to.isDynamic()) clearExternAndSetNull(to);
    copyCell(to, from);
    if (from.flags & MEM.Static == 0) {
        to.flags &= ~(MEM.Dyn | MEM.Static | MEM.Ephem);
        std.debug.assert(src_type == MEM.Ephem or src_type == MEM.Static);
        to.flags |= src_type;
    }
}

/// memcpy(pTo, pFrom, MEMCELLSIZE): the value fields only.
fn copyCell(to: *Mem, from: *const Mem) void {
    to.u = from.u;
    to.z = from.z;
    to.n = from.n;
    to.flags = from.flags;
    to.enc = from.enc;
    to.e_subtype = from.e_subtype;
}

/// Port of sqlite3VdbeMemCopy(): a deep copy.
pub fn copy(to: *Mem, from: *const Mem) Error!void {
    if (to.isDynamic()) clearExternAndSetNull(to);
    copyCell(to, from);
    to.flags &= ~MEM.Dyn;
    if (to.flags & (MEM.Str | MEM.Blob) != 0) {
        if (from.flags & MEM.Static == 0) {
            to.flags |= MEM.Ephem;
            try makeWriteable(to);
        }
    }
}

/// Port of sqlite3VdbeMemMove(): move the value and buffer of `from` into
/// `to`; `from` becomes NULL.
pub fn move(to: *Mem, from: *Mem) void {
    release(to);
    to.* = from.*;
    from.flags = MEM.Null;
    from.z_malloc = &.{};
}

/// Port of sqlite3VdbeMemSetStr(): a string (`enc` nonzero) or blob
/// (`enc` 0). A null `z` sets NULL. TooBig if past SQLITE_LIMIT_LENGTH.
pub fn setStr(m: *Mem, z_arg: ?[]const u8, enc_arg: u8, del: Destructor) Error!void {
    const z = z_arg orelse {
        setNull(m);
        return;
    };
    const limit: i64 = if (m.db) |db| db.limit(.length) else max_length;
    var enc = enc_arg;
    var flags: u16 = undefined;
    if (enc == 0) {
        flags = MEM.Blob;
        enc = ENC.UTF8;
    } else {
        flags = MEM.Str;
    }
    if (@as(i64, @intCast(z.len)) > limit) {
        switch (del) {
            .dynamic => gpa(m).free(@constCast(z)),
            .func => |f| f(@ptrCast(@constCast(z.ptr))),
            else => {},
        }
        setNull(m);
        return error.TooBig;
    }
    switch (del) {
        .transient => {
            try clearAndResize(m, @max(z.len, 32));
            @memcpy(m.z.?[0..z.len], z);
        },
        .dynamic => {
            release(m);
            m.z = @constCast(z.ptr);
            m.z_malloc = @constCast(z);
        },
        .static => {
            release(m);
            m.z = @constCast(z.ptr);
            flags |= MEM.Static;
        },
        .func => |f| {
            release(m);
            m.z = @constCast(z.ptr);
            m.x_del = f;
            flags |= MEM.Dyn;
        },
    }
    m.n = @intCast(z.len & 0x7fffffff);
    m.flags = flags;
    m.enc = enc;
}

/// Port of sqlite3VdbeMemSetText() for a NUL-terminated string: like
/// `setStr` with MEM_Term.
pub fn setTextZ(m: *Mem, z: [:0]const u8, del: Destructor) Error!void {
    if (z.len > m.db.?.limit(.length)) {
        setNull(m);
        return error.TooBig;
    }
    switch (del) {
        .transient => {
            try clearAndResize(m, @max(z.len + 1, 32));
            @memcpy(m.z.?[0 .. z.len + 1], z[0 .. z.len + 1]);
        },
        .dynamic => {
            release(m);
            m.z = @constCast(z.ptr);
            m.z_malloc = @constCast(z.ptr)[0 .. z.len + 1];
        },
        .static => {
            release(m);
            m.z = @constCast(z.ptr);
        },
        .func => |f| {
            release(m);
            m.z = @constCast(z.ptr);
            m.x_del = f;
        },
    }
    m.flags = MEM.Str | MEM.Term | switch (del) {
        .static => MEM.Static,
        .func => MEM.Dyn,
        else => @as(u16, 0),
    };
    m.n = @intCast(z.len);
    m.enc = ENC.UTF8;
}

/// Port of sqlite3VdbeMemFromBtree(): copy `amt` bytes of the cursor's
/// payload from `offset` into the Mem's buffer as a blob.
pub fn fromBtree(cur: *btree.Cursor, offset: u32, amt: u32, m: *Mem) (Error || btree.Error)!void {
    m.flags = MEM.Null;
    if (amt >= max_allocation_size) return error.OutOfMemory;
    if (@as(u64, amt) + offset > cur.payloadSize()) return error.Corrupt;
    try clearAndResize(m, @as(usize, amt) + 1);
    cur.payload(offset, m.z.?[0..amt]) catch |err| {
        release(m);
        return err;
    };
    m.z.?[amt] = 0;
    m.flags = MEM.Blob;
    m.n = @intCast(amt);
}

/// Port of sqlite3VdbeMemFromBtreeZeroOffset(): the first `amt` bytes of
/// the payload, pointing into the page when they are all there.
pub fn fromBtreeZeroOffset(cur: *btree.Cursor, amt: u32, m: *Mem) (Error || btree.Error)!void {
    std.debug.assert(!m.isDynamic());
    const avail = cur.payloadFetch();
    if (amt <= avail.len) {
        m.z = @constCast(avail.ptr);
        m.flags = MEM.Blob | MEM.Ephem;
        m.n = @intCast(amt);
    } else {
        try fromBtree(cur, 0, amt, m);
    }
}

/// Port of sqlite3ValueText(): the value as NUL-terminated text in `enc`,
/// converting it if needed; null for NULL.
pub fn valueText(m: *Mem, enc: u8) Error!?[*:0]const u8 {
    if (m.flags & (MEM.Str | MEM.Term) == MEM.Str | MEM.Term and m.enc == enc) {
        return @ptrCast(m.z.?);
    }
    if (m.flags & MEM.Null != 0) return null;
    // valueToText().
    if (m.flags & (MEM.Blob | MEM.Str) != 0) {
        if (m.flags & MEM.Zero != 0) try expandBlob(m);
        m.flags |= MEM.Str;
        if (m.enc != enc & ~ENC.UTF16_ALIGNED) try changeEncoding(m, enc & ~ENC.UTF16_ALIGNED);
        try nulTerminate(m);
    } else {
        try stringify(m, enc, false);
    }
    if (m.enc == enc & ~ENC.UTF16_ALIGNED) return @ptrCast(m.z.?);
    return null;
}

/// Port of sqlite3ValueBytes(): the size of the value as text or blob.
pub fn valueBytes(m: *Mem, enc: u8) Error!i32 {
    if (m.flags & MEM.Str != 0 and m.enc == enc) return m.n;
    if (m.flags & MEM.Str != 0 and enc != ENC.UTF8 and m.enc != ENC.UTF8) return m.n;
    if (m.flags & MEM.Blob != 0) {
        if (m.flags & MEM.Zero != 0) return m.n + m.u.n_zero;
        return m.n;
    }
    if (m.flags & MEM.Null != 0) return 0;
    _ = try valueText(m, enc);
    return m.n;
}

// =============================================================== affinity

/// Port of alsoAnInt() (vdbe.c).
fn alsoAnInt(m: *Mem, r: f64, out: *i64) bool {
    const iv = numeric.realToI64(r);
    if (numeric.realSameAsInt(r, iv)) {
        out.* = iv;
        return true;
    }
    return util.atoi64(m.bytes(), out) == .ok;
}

/// Port of applyNumericAffinity() (vdbe.c): turn text that looks like a
/// number into one; with `try_for_int`, "48.00" becomes an integer.
pub fn applyNumericAffinity(m: *Mem, try_for_int: bool) void {
    std.debug.assert(m.flags & (MEM.Str | MEM.Int | MEM.Real | MEM.IntReal) == MEM.Str);
    var r: f64 = undefined;
    const rc = realValueRC(m, &r);
    if (rc <= 0) return;
    var iv: i64 = undefined;
    if (rc & 2 == 0 and alsoAnInt(m, r, &iv)) {
        m.u = .{ .i = iv };
        m.flags |= MEM.Int;
    } else {
        m.u = .{ .r = r };
        m.flags |= MEM.Real;
        if (try_for_int) integerAffinity(m);
    }
    // TEXT to NUMERIC is many-to-one: drop the text.
    m.flags &= ~MEM.Str;
}

/// Port of applyAffinity() (vdbe.c) / sqlite3ValueApplyAffinity().
pub fn applyAffinity(m: *Mem, affinity: u8, enc: u8) Error!void {
    if (affinity >= Aff.numeric) {
        if (m.flags & MEM.Int == 0) {
            if (m.flags & (MEM.Real | MEM.IntReal) == 0) {
                if (m.flags & MEM.Str != 0) applyNumericAffinity(m, true);
            } else if (affinity <= Aff.real) {
                integerAffinity(m);
            }
        }
    } else if (affinity == Aff.text) {
        if (m.flags & MEM.Str == 0) {
            if (m.flags & (MEM.Real | MEM.Int | MEM.IntReal) != 0) try stringify(m, enc, true);
        }
        m.flags &= ~(MEM.Real | MEM.Int | MEM.IntReal);
    }
}

/// Port of computeNumericType() (vdbe.c).
fn computeNumericType(m: *Mem) u16 {
    std.debug.assert(m.flags & (MEM.Int | MEM.Real | MEM.IntReal) == 0);
    if (m.flags & MEM.Zero != 0) {
        expandBlob(m) catch {
            m.u = .{ .i = 0 };
            return MEM.Int;
        };
    }
    var r: f64 = undefined;
    const rc = realValueRC(m, &r);
    m.u = .{ .r = r };
    var ix: i64 = 0;
    if (rc <= 0) {
        if (rc & 2 == 0 and @intFromEnum(util.atoi64(m.bytes(), &ix)) <= 1) {
            m.u = .{ .i = ix };
            return MEM.Int;
        }
        return MEM.Real;
    } else if (rc & 2 == 0 and util.atoi64(m.bytes(), &ix) == .ok) {
        m.u = .{ .i = ix };
        return MEM.Int;
    }
    return MEM.Real;
}

/// Port of numericType() (vdbe.c): MEM_Int and/or MEM_Real for the value,
/// setting u.i/u.r but not the flags.
pub fn numericType(m: *Mem) u16 {
    if (m.flags & (MEM.Int | MEM.Real | MEM.IntReal | MEM.Null) != 0) {
        return m.flags & (MEM.Int | MEM.Real | MEM.IntReal | MEM.Null);
    }
    return computeNumericType(m);
}

/// Port of sqlite3_value_type(): the fundamental datatype.
pub fn valueType(m: *const Mem) i32 {
    const types = comptime blk: {
        var t: [64]u8 = undefined;
        for (0..64) |f| {
            t[f] = if (f & MEM.Null != 0)
                vi.SQLITE_NULL
            else if (f & MEM.Int != 0)
                vi.SQLITE_INTEGER
            else if (f & MEM.Real != 0)
                vi.SQLITE_FLOAT
            else if (f & MEM.IntReal != 0)
                vi.SQLITE_FLOAT
            else if (f & MEM.Str != 0)
                vi.SQLITE_TEXT
            else if (f & MEM.Blob != 0)
                vi.SQLITE_BLOB
            else
                vi.SQLITE_NULL;
        }
        break :blk t;
    };
    return types[m.flags & MEM.AffMask];
}

/// Port of sqlite3_value_numeric_type().
pub fn valueNumericType(m: *Mem) i32 {
    var t = valueType(m);
    if (t == vi.SQLITE_TEXT) {
        applyNumericAffinity(m, false);
        t = valueType(m);
    }
    return t;
}

// =================================================================== tests

test "mem: affinity and conversions" {
    var m: Mem = .{};
    defer release(&m);
    try setStr(&m, "  42  ", ENC.UTF8, .transient);
    try applyAffinity(&m, Aff.numeric, ENC.UTF8);
    try std.testing.expectEqual(MEM.Int, m.flags & MEM.TypeMask);
    try std.testing.expectEqual(@as(i64, 42), m.u.i);

    try setStr(&m, "48.00", ENC.UTF8, .transient);
    try applyAffinity(&m, Aff.integer, ENC.UTF8);
    try std.testing.expectEqual(@as(i64, 48), m.u.i);

    try setStr(&m, "1.5x", ENC.UTF8, .transient);
    try applyAffinity(&m, Aff.numeric, ENC.UTF8);
    try std.testing.expect(m.flags & MEM.Str != 0);

    setDouble(&m, 2.5);
    try applyAffinity(&m, Aff.text, ENC.UTF8);
    try std.testing.expectEqualStrings("2.5", m.bytes());

    setInt64(&m, -7);
    _ = try valueText(&m, ENC.UTF8);
    try std.testing.expectEqualStrings("-7", m.bytes());
    try std.testing.expectEqual(@as(i64, -7), intValue(&m));

    try setStr(&m, "abc", 0, .static);
    try cast(&m, Aff.text, ENC.UTF8);
    try std.testing.expectEqual(vi.SQLITE_TEXT, valueType(&m));
}
