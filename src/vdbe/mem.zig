//! Operations on Mem values (port of vdbemem.c, plus the affinity helpers
//! of vdbe.c). A Mem owns at most one buffer, `z_malloc`; `z` may point
//! into it, to static or ephemeral memory, or to memory freed by `x_del`.
//!
//! The engine keeps text in UTF-8. A value becomes UTF-16 only when an
//! interface asks for it (sqlite3_value_text16()), as in SQLite by
//! translating it in place (utf.zig), and is read back as UTF-8.

const std = @import("std");
const vi = @import("vdbe_int.zig");
const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const numeric = @import("xqlite_base").numeric;
const printf = @import("../sql/printf.zig");
const btree = @import("xqlite_storage").btree;
const malloc = @import("../sql/malloc.zig");
const thunk = @import("xqlite_base").thunk;
const utf = @import("utf.zig");

const Mem = vi.Mem;
const MEM = vi.MEM;
const ENC = vi.ENC;
const Aff = int.Aff;
const RC = int.RC;
const Sqlite3 = int.Sqlite3;
const FuncDef = int.FuncDef;
const Destructor = vi.Destructor;

/// The errors of setting a string or blob: TooBig past
/// SQLITE_LIMIT_LENGTH. The other operations can only run out of memory.
pub const Error = error{ OutOfMemory, TooBig };
const Oom = error{OutOfMemory};

/// SQLITE_MAX_LENGTH: the default limit on TEXT and BLOB sizes.
pub const max_length = 1000000000;

/// SQLITE_MAX_ALLOCATION_SIZE.
pub const max_allocation_size = 2147483391;

/// The allocator of a Mem's buffers: its connection's (sqlite3DbMalloc),
/// or sqlite3_malloc() for values not tied to a connection.
fn gpa(m: *const Mem) std.mem.Allocator {
    return if (m.db) |db| db.gpa else malloc.allocator;
}

/// `z` as the buffer of `m`: all of its allocation (szMalloc is
/// sqlite3DbMallocSize()).
fn ownBuffer(m: *Mem, z: [*]u8) void {
    m.z_malloc = z[0..malloc.dbMallocSize(m.db, z)];
}

/// Port of sqlite3VdbeChangeEncoding().
pub fn changeEncoding(m: *Mem, desired: u8) Oom!void {
    if (!m.flags.Str) {
        m.enc = desired;
        return;
    }
    if (m.enc == desired) return;
    return translate(m, desired);
}

/// Port of sqlite3VdbeMemTranslate(): convert the string to encoding
/// `desired`, in a new buffer of its own.
fn translate(m: *Mem, desired: u8) Oom!void {
    @branchHint(.cold);
    std.debug.assert(m.flags.Str and m.enc != desired and m.enc != 0 and m.n >= 0);
    if (m.enc != ENC.UTF8 and desired != ENC.UTF8) {
        // Between the two UTF-16 byte orders: swap the bytes in place.
        try makeWriteable(m);
        const z = m.z.?;
        var i: usize = 0;
        while (i + 1 < @as(usize, @intCast(m.n))) : (i += 2) std.mem.swap(u8, &z[i], &z[i + 1]);
        m.enc = desired;
        return;
    }
    if (desired == ENC.UTF8) m.n &= ~@as(i32, 1);
    const out = try gpa(m).alloc(u8, utf.maxLen(@intCast(m.n), desired));
    const n = utf.translate(m.bytes(), m.enc, desired, out);
    const flags = (MEM{ .Str = true, .Term = true }).with(m.flags.only(MEM.AffMask.with(.{ .Subtype = true })));
    release(m);
    m.flags = flags;
    m.enc = desired;
    m.z = out.ptr;
    m.n = @intCast(n);
    ownBuffer(m, out.ptr);
}

/// The text of a UTF-16 string or blob as NUL-terminated UTF-8, for
/// reading a number from it without changing the value (SQLite's
/// sqlite3AtoF() and sqlite3Atoi64() read UTF-16 directly); null on OOM.
fn utf8Copy(m: *const Mem) ?Utf8Copy {
    @branchHint(.cold);
    const in = m.bytes();
    const out = gpa(m).alloc(u8, utf.maxLen(in.len, ENC.UTF8)) catch return null;
    const n = utf.translate(in, m.enc, ENC.UTF8, out);
    return .{ .buf = out, .s = out[0..n :0] };
}

const Utf8Copy = struct {
    buf: []u8,
    s: [:0]u8,

    fn free(cp: Utf8Copy, m: *const Mem) void {
        gpa(m).free(cp.buf);
    }
};

fn isUtf16(m: *const Mem) bool {
    return m.enc == ENC.UTF16LE or m.enc == ENC.UTF16BE;
}

/// Bring a value an interface turned into UTF-16 back to UTF-8, before
/// the engine reads it again (the C ABI calls this on the registers it
/// handed out). The engine itself only reads UTF-8.
pub fn toUtf8(m: *Mem) void {
    if (m.flags.Str and isUtf16(m)) changeEncoding(m, ENC.UTF8) catch {
        if (m.db) |db| db.oomFault();
        setNull(m);
    };
}

/// Port of sqlite3VdbeMemGrow(): make `z` a writable buffer of at least
/// `n` bytes, copying the current content if `preserve`.
pub fn grow(m: *Mem, n: usize, preserve_arg: bool) Oom!void {
    var preserve = preserve_arg;
    const a = gpa(m);
    if (m.z_malloc.len > 0 and preserve and m.z == m.z_malloc.ptr) {
        const z = a.realloc(m.z_malloc, n) catch {
            a.free(m.z_malloc);
            m.z_malloc = &.{};
            setNull(m);
            m.z = null;
            return error.OutOfMemory;
        };
        ownBuffer(m, z.ptr);
        m.z = m.z_malloc.ptr;
        preserve = false;
    } else {
        if (m.z_malloc.len > 0) a.free(m.z_malloc);
        const z = a.alloc(u8, n) catch {
            m.z_malloc = &.{};
            setNull(m);
            m.z = null;
            return error.OutOfMemory;
        };
        ownBuffer(m, z.ptr);
    }
    if (preserve) if (m.z) |z| {
        @memcpy(m.z_malloc[0..@intCast(m.n)], z[0..@intCast(m.n)]);
    };
    if (m.flags.Dyn) m.x_del.?(m.z);
    m.z = m.z_malloc.ptr;
    m.flags.clear(.{ .Dyn = true, .Ephem = true, .Static = true });
}

/// Port of sqlite3VdbeMemClearAndResize(): a buffer of at least `sz`
/// bytes; string and blob content is discarded, numbers kept.
pub fn clearAndResize(m: *Mem, sz: usize) Oom!void {
    if (m.z_malloc.len < sz) return grow(m, sz, false);
    m.z = m.z_malloc.ptr;
    m.flags = m.flags.only(.{ .Null = true, .Int = true, .Real = true, .IntReal = true });
}

/// Port of sqlite3VdbeMemZeroTerminateIfAble(): NUL-terminate a string if
/// there is room. An optimization; returns whether it is terminated.
pub fn zeroTerminateIfAble(m: *Mem) bool {
    if (m.flags.only(.{ .Str = true, .Term = true, .Ephem = true, .Static = true }) != MEM{ .Str = true }) return false;
    if (m.enc != ENC.UTF8) return false;
    if (m.flags.Dyn) return false;
    if (m.z_malloc.len >= m.n + 1) {
        m.z.?[@intCast(m.n)] = 0;
        m.flags.Term = true;
        return true;
    }
    return false;
}

/// Port of vdbeMemAddTerminator(): three zero bytes, enough for UTF-16.
fn addTerminator(m: *Mem) Oom!void {
    const n: usize = @intCast(m.n);
    try grow(m, n + 3, true);
    const z = m.z.?;
    z[n] = 0;
    z[n + 1] = 0;
    z[n + 2] = 0;
    m.flags.Term = true;
}

/// Port of sqlite3VdbeMemMakeWriteable(): move a string or blob into the
/// Mem's own buffer.
pub fn makeWriteable(m: *Mem) Oom!void {
    if (m.flags.intersects(.{ .Str = true, .Blob = true })) {
        if (m.flags.Zero) try expandBlob(m);
        if (m.z_malloc.len == 0 or m.z != m.z_malloc.ptr) try addTerminator(m);
    }
    m.flags.Ephem = false;
}

/// Port of sqlite3VdbeMemExpandBlob(): materialize the zero tail of a
/// MEM_Zero blob.
pub fn expandBlob(m: *Mem) Oom!void {
    std.debug.assert(m.flags.Zero);
    var n_byte: i32 = m.n + m.u.n_zero;
    if (n_byte <= 0) {
        if (!m.flags.Blob) return;
        n_byte = 1;
    }
    try grow(m, @intCast(n_byte), true);
    @memset(m.z.?[@intCast(m.n)..][0..@intCast(m.u.n_zero)], 0);
    m.n += m.u.n_zero;
    m.flags.clear(.{ .Zero = true, .Term = true });
}

/// Port of sqlite3VdbeMemNulTerminate().
pub fn nulTerminate(m: *Mem) Oom!void {
    if (m.flags.only(.{ .Term = true, .Str = true }) != MEM{ .Str = true }) return;
    return addTerminator(m);
}

/// Port of vdbeMemRenderNum(): the text of a number, as SQLite prints it:
/// integers plainly (IntReal with ".0"), reals with "%!.*g".
fn renderNum(buf: []u8, m: *Mem) usize {
    std.debug.assert(m.flags.intersects(.{ .Int = true, .Real = true, .IntReal = true }));
    if (m.flags.intersects(.{ .Int = true, .IntReal = true })) {
        var n = numeric.int64ToText(m.u.i, buf);
        if (m.flags.IntReal) {
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
pub fn stringify(m: *Mem, enc: u8, force: bool) Oom!void {
    const n_byte = 32;
    std.debug.assert(!m.flags.intersects(.{ .Str = true, .Blob = true, .Zero = true }));
    clearAndResize(m, n_byte) catch |err| {
        m.enc = 0;
        return err;
    };
    const n = renderNum(m.z_malloc[0..n_byte], m);
    m.z.?[n] = 0;
    m.n = @intCast(n);
    m.enc = ENC.UTF8;
    m.flags.set(.{ .Str = true, .Term = true });
    if (force) m.flags.clear(.{ .Int = true, .Real = true, .IntReal = true });
    try changeEncoding(m, enc);
}

/// What an aggregate's xFinal or xValue reported: the error code (0 if
/// none) and what the error is (Context.err_state).
pub const AggResult = struct {
    rc: i32,
    state: ?int.ErrorState = null,
};

/// Port of sqlite3VdbeMemFinalize(): run the finalizer of the aggregate
/// whose context is in `m` and store the result there.
pub fn finalize(m: *Mem, func: *const FuncDef) AggResult {
    const func_mod = @import("func.zig");
    var t: Mem = .{ .db = m.db };
    var ctx: vi.Context = .{ .out = &t, .mem = m, .func = func, .argv = &.{}, .enc = if (m.db) |db| db.enc else ENC.UTF8 };
    func_mod.callFinalize(func, &ctx);
    std.debug.assert(!m.flags.Dyn);
    if (m.z_malloc.len > 0) gpa(m).free(m.z_malloc);
    m.* = t;
    return .{ .rc = ctx.is_error, .state = ctx.err_state };
}

/// Port of sqlite3VdbeMemAggValue(): the current value of a window
/// aggregate.
pub fn aggValue(accum: *Mem, out: *Mem, func: *const FuncDef) AggResult {
    const func_mod = @import("func.zig");
    setNull(out);
    var ctx: vi.Context = .{ .out = out, .mem = accum, .func = func, .argv = &.{}, .enc = if (accum.db) |db| db.enc else ENC.UTF8 };
    func_mod.callValue(func, &ctx);
    return .{ .rc = ctx.is_error, .state = ctx.err_state };
}

/// Port of vdbeMemClearExternAndSetNull().
fn clearExternAndSetNull(m: *Mem) void {
    std.debug.assert(m.isDynamic());
    if (m.flags.Agg) {
        _ = finalize(m, m.u.def);
        std.debug.assert(!m.flags.Agg);
    }
    if (m.flags.Dyn) m.x_del.?(m.z);
    m.flags = .{ .Null = true };
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
    if (flags.intersects(.{ .Int = true, .IntReal = true })) return m.u.i;
    if (flags.Real) return numeric.realToI64(m.u.r);
    if (flags.intersects(.{ .Str = true, .Blob = true })) if (m.z) |z| {
        var v: i64 = 0;
        if (isUtf16(m)) {
            const copy8 = utf8Copy(m) orelse return 0;
            defer copy8.free(m);
            _ = util.atoi64(copy8.s, &v);
            return v;
        }
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
    std.debug.assert(m.flags.intersects(.{ .Str = true, .Blob = true }));
    const z = m.z orelse {
        value.* = 0.0;
        return 0;
    };
    if (isUtf16(m)) {
        const copy8 = utf8Copy(m) orelse {
            value.* = 0.0;
            return 0;
        };
        defer copy8.free(m);
        return numeric.atoF(copy8.s.ptr, value);
    }
    if (m.flags.Term or zeroTerminateIfAble(m)) return numeric.atoF(@ptrCast(z), value);
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
    if (m.flags.Real) return m.u.r;
    if (m.flags.intersects(.{ .Int = true, .IntReal = true })) return @floatFromInt(m.u.i);
    if (m.flags.intersects(.{ .Str = true, .Blob = true })) {
        var r: f64 = undefined;
        _ = realValueRC(m, &r);
        return r;
    }
    return 0.0;
}

/// Port of sqlite3VdbeBooleanValue(): the truth of a value, `if_null` for
/// NULL.
pub fn booleanValue(m: *Mem, if_null: bool) bool {
    if (m.flags.intersects(.{ .Int = true, .IntReal = true })) return m.u.i != 0;
    if (m.flags.Null) return if_null;
    return realValue(m) != 0.0;
}

/// Port of sqlite3VdbeIntegerAffinity(): turn a real with an exact
/// integer value into an integer.
pub fn integerAffinity(m: *Mem) void {
    std.debug.assert(m.flags.intersects(.{ .Real = true, .IntReal = true }));
    if (m.flags.IntReal) {
        m.setTypeFlag(.{ .Int = true });
        return;
    }
    const ix = numeric.realToI64(m.u.r);
    // Only if the round trip is exact and not at the ends of the range
    // (ticket #3922).
    if (m.u.r == @as(f64, @floatFromInt(ix)) and ix > std.math.minInt(i64) and ix < std.math.maxInt(i64)) {
        m.u.i = ix;
        m.setTypeFlag(.{ .Int = true });
    }
}

/// Port of sqlite3VdbeMemIntegerify().
pub fn integerify(m: *Mem) void {
    m.u.i = intValue(m);
    m.setTypeFlag(.{ .Int = true });
}

/// Port of sqlite3VdbeMemRealify().
pub fn realify(m: *Mem) void {
    m.u.r = realValue(m);
    m.setTypeFlag(.{ .Real = true });
}

/// Port of sqlite3VdbeMemNumerify(): convert to INTEGER or REAL, as much
/// of the text as looks like a number.
pub fn numerify(m: *Mem) void {
    if (!m.flags.intersects(.{ .Int = true, .Real = true, .IntReal = true, .Null = true })) {
        std.debug.assert(m.flags.intersects(.{ .Blob = true, .Str = true }));
        var r: f64 = undefined;
        const rc = realValueRC(m, &r);
        m.u.r = r;
        var ix: i64 = 0;
        const as_int = rc & 2 == 0 and @backingInt(util.atoi64(m.bytes(), &ix)) < 2;
        if (as_int) {
            m.u.i = ix;
            m.setTypeFlag(.{ .Int = true });
        } else {
            ix = numeric.realToI64(r);
            if (numeric.realSameAsInt(r, ix)) {
                m.u.i = ix;
                m.setTypeFlag(.{ .Int = true });
            } else {
                m.setTypeFlag(.{ .Real = true });
            }
        }
    }
    m.flags.clear(.{ .Str = true, .Blob = true, .Zero = true });
}

/// Port of sqlite3VdbeMemCast(): CAST(value AS affinity).
pub fn cast(m: *Mem, aff: u8, enc: u8) Oom!void {
    if (m.flags.Null) return;
    switch (aff) {
        Aff.blob => {
            if (!m.flags.Blob) {
                try applyAffinity(m, Aff.text, enc);
                if (m.flags.Str) m.setTypeFlag(.{ .Blob = true });
            } else {
                m.flags.clear(MEM.TypeMask.without(.{ .Blob = true }));
            }
        },
        Aff.numeric => numerify(m),
        Aff.integer => integerify(m),
        Aff.real => realify(m),
        else => {
            std.debug.assert(aff == Aff.text);
            // C: flags |= (flags & MEM_Blob) >> 3, which is MEM_Str.
            if (m.flags.Blob) m.flags.Str = true;
            try applyAffinity(m, Aff.text, enc);
            m.flags.clear(.{ .Int = true, .Real = true, .IntReal = true, .Blob = true, .Zero = true });
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
        m.flags = .{ .Null = true };
    }
}

/// Port of sqlite3VdbeMemSetZeroBlob().
pub fn setZeroBlob(m: *Mem, n: i32) void {
    release(m);
    m.flags = .{ .Blob = true, .Zero = true };
    m.n = 0;
    m.u = .{ .n_zero = @max(n, 0) };
    m.enc = ENC.UTF8;
    m.z = null;
}

/// Port of sqlite3VdbeMemSetInt64().
pub fn setInt64(m: *Mem, val: i64) void {
    if (m.isDynamic()) setNull(m);
    m.u = .{ .i = val };
    m.flags = .{ .Int = true };
}

/// Port of sqlite3VdbeMemSetDouble(): NaN becomes NULL.
pub fn setDouble(m: *Mem, val: f64) void {
    setNull(m);
    if (!std.math.isNan(val)) {
        m.u = .{ .r = val };
        m.flags = .{ .Real = true };
    }
}

/// The object that `m` holds with MEM_Dyn and the destructor
/// int.destructor(del) (`del` a typed destructor, `fn (*T) void`), as a
/// RowSet or VdbeFrame register or a ValueList pointer does; null if it
/// holds anything else. The destructor stands for the type, as in C's
/// tests of pMem->xDel.
pub fn dynObject(m: *const Mem, comptime del: anytype) ?@typeInfo(@TypeOf(del)).@"fn".param_types[0].? {
    if (!m.flags.Dyn or m.x_del != int.destructor(del)) return null;
    return thunk.downcast(@typeInfo(@TypeOf(del)).@"fn".param_types[0].?, m.z);
}

/// Port of sqlite3NoopDestructor().
pub fn noopDestructor(_: ?*anyopaque) void {}

/// Port of sqlite3VdbeMemSetPointer(): a NULL carrying a pointer of type
/// `ptype` (sqlite3_result_pointer).
pub fn setPointer(m: *Mem, ptr: ?*anyopaque, ptype: ?[*:0]const u8, destructor: ?int.DestructorFn) void {
    std.debug.assert(m.flags == MEM{ .Null = true });
    clear(m);
    m.u = .{ .z_ptype = ptype orelse "" };
    m.z = @ptrCast(ptr);
    m.flags = .{ .Null = true, .Dyn = true, .Subtype = true, .Term = true };
    m.e_subtype = 'p';
    m.x_del = destructor orelse noopDestructor;
}

/// Port of sqlite3VdbeMemTooBig(): a string or blob over SQLITE_LIMIT_LENGTH.
pub fn tooBig(m: *const Mem) bool {
    if (m.flags.intersects(.{ .Str = true, .Blob = true })) {
        var n = m.n;
        if (m.flags.Zero) n += m.u.n_zero;
        return n > m.db.?.limit(.length);
    }
    return false;
}

/// Port of sqlite3VdbeMemShallowCopy(): copy the value without its buffer;
/// strings then point at `from`'s, marked `src_type` (MEM_Ephem or
/// MEM_Static) unless static already.
pub fn shallowCopy(to: *Mem, from: *const Mem, src_type: MEM) void {
    if (to.isDynamic()) clearExternAndSetNull(to);
    copyCell(to, from);
    if (!from.flags.Static) {
        to.flags.clear(.{ .Dyn = true, .Static = true, .Ephem = true });
        std.debug.assert(src_type == MEM{ .Ephem = true } or src_type == MEM{ .Static = true });
        to.flags.set(src_type);
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
pub fn copy(to: *Mem, from: *const Mem) Oom!void {
    if (to.isDynamic()) clearExternAndSetNull(to);
    copyCell(to, from);
    to.flags.Dyn = false;
    if (to.flags.intersects(.{ .Str = true, .Blob = true })) {
        if (!from.flags.Static) {
            to.flags.Ephem = true;
            try makeWriteable(to);
        }
    }
}

/// Port of sqlite3VdbeMemMove(): move the value and buffer of `from` into
/// `to`; `from` becomes NULL.
pub fn move(to: *Mem, from: *Mem) void {
    release(to);
    to.* = from.*;
    from.flags = .{ .Null = true };
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
    var flags: MEM = undefined;
    if (enc == 0) {
        flags = .{ .Blob = true };
        enc = ENC.UTF8;
    } else {
        flags = .{ .Str = true };
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
            if (z.len > 0) ownBuffer(m, @constCast(z.ptr));
        },
        .static => {
            release(m);
            m.z = @constCast(z.ptr);
            flags.Static = true;
        },
        .func => |f| {
            release(m);
            m.z = @constCast(z.ptr);
            m.x_del = f;
            flags.Dyn = true;
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
            ownBuffer(m, @constCast(z.ptr));
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
    m.flags = (MEM{ .Str = true, .Term = true }).with(switch (del) {
        .static => .{ .Static = true },
        .func => .{ .Dyn = true },
        else => .{},
    });
    m.n = @intCast(z.len);
    m.enc = ENC.UTF8;
}

/// Port of sqlite3VdbeMemFromBtree(): copy `amt` bytes of the cursor's
/// payload from `offset` into the Mem's buffer as a blob.
pub fn fromBtree(cur: *btree.Cursor, offset: u32, amt: u32, m: *Mem) btree.Error!void {
    m.flags = .{ .Null = true };
    if (amt >= max_allocation_size) return error.OutOfMemory;
    if (@as(u64, amt) + offset > cur.payloadSize()) return error.Corrupt;
    try clearAndResize(m, @as(usize, amt) + 1);
    cur.payload(offset, m.z.?[0..amt]) catch |err| {
        release(m);
        return err;
    };
    m.z.?[amt] = 0;
    m.flags = .{ .Blob = true };
    m.n = @intCast(amt);
}

/// Port of sqlite3VdbeMemFromBtreeZeroOffset(): the first `amt` bytes of
/// the payload, pointing into the page when they are all there.
pub fn fromBtreeZeroOffset(cur: *btree.Cursor, amt: u32, m: *Mem) btree.Error!void {
    std.debug.assert(!m.isDynamic());
    const avail = cur.payloadFetch();
    if (amt <= avail.len) {
        m.z = @constCast(avail.ptr);
        m.flags = .{ .Blob = true, .Ephem = true };
        m.n = @intCast(amt);
    } else {
        try fromBtree(cur, 0, amt, m);
    }
}

/// Port of sqlite3ValueText(): the value as NUL-terminated text in `enc`,
/// converting it if needed; null for NULL.
pub fn valueText(m: *Mem, enc: u8) Oom!?[*:0]const u8 {
    if (m.flags.contains(.{ .Str = true, .Term = true }) and m.enc == enc) {
        return @ptrCast(m.z.?);
    }
    if (m.flags.Null) return null;
    // valueToText().
    if (m.flags.intersects(.{ .Blob = true, .Str = true })) {
        if (m.flags.Zero) try expandBlob(m);
        m.flags.Str = true;
        if (m.enc != enc & ~ENC.UTF16_ALIGNED) try changeEncoding(m, enc & ~ENC.UTF16_ALIGNED);
        try nulTerminate(m);
    } else {
        try stringify(m, enc, false);
    }
    if (m.enc == enc & ~ENC.UTF16_ALIGNED) return @ptrCast(m.z.?);
    return null;
}

/// Port of sqlite3ValueBytes(): the size of the value as text or blob.
pub fn valueBytes(m: *Mem, enc: u8) Oom!i32 {
    if (m.flags.Str and m.enc == enc) return m.n;
    if (m.flags.Str and enc != ENC.UTF8 and m.enc != ENC.UTF8) return m.n;
    if (m.flags.Blob) {
        if (m.flags.Zero) return m.n + m.u.n_zero;
        return m.n;
    }
    if (m.flags.Null) return 0;
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
    std.debug.assert(m.flags.only(.{ .Str = true, .Int = true, .Real = true, .IntReal = true }) == MEM{ .Str = true });
    var r: f64 = undefined;
    const rc = realValueRC(m, &r);
    if (rc <= 0) return;
    var iv: i64 = undefined;
    if (rc & 2 == 0 and alsoAnInt(m, r, &iv)) {
        m.u = .{ .i = iv };
        m.flags.Int = true;
    } else {
        m.u = .{ .r = r };
        m.flags.Real = true;
        if (try_for_int) integerAffinity(m);
    }
    // TEXT to NUMERIC is many-to-one: drop the text.
    m.flags.Str = false;
}

/// Port of applyAffinity() (vdbe.c) / sqlite3ValueApplyAffinity().
pub fn applyAffinity(m: *Mem, affinity: u8, enc: u8) Oom!void {
    if (affinity >= Aff.numeric) {
        if (!m.flags.Int) {
            if (!m.flags.intersects(.{ .Real = true, .IntReal = true })) {
                if (m.flags.Str) applyNumericAffinity(m, true);
            } else if (affinity <= Aff.real) {
                integerAffinity(m);
            }
        }
    } else if (affinity == Aff.text) {
        if (!m.flags.Str) {
            if (m.flags.intersects(.{ .Real = true, .Int = true, .IntReal = true })) try stringify(m, enc, true);
        }
        m.flags.clear(.{ .Real = true, .Int = true, .IntReal = true });
    }
}

/// Port of computeNumericType() (vdbe.c).
fn computeNumericType(m: *Mem) MEM {
    std.debug.assert(!m.flags.intersects(.{ .Int = true, .Real = true, .IntReal = true }));
    if (m.flags.Zero) {
        expandBlob(m) catch {
            m.u = .{ .i = 0 };
            return .{ .Int = true };
        };
    }
    var r: f64 = undefined;
    const rc = realValueRC(m, &r);
    m.u = .{ .r = r };
    var ix: i64 = 0;
    if (rc <= 0) {
        if (rc & 2 == 0 and @backingInt(util.atoi64(m.bytes(), &ix)) <= 1) {
            m.u = .{ .i = ix };
            return .{ .Int = true };
        }
        return .{ .Real = true };
    } else if (rc & 2 == 0 and util.atoi64(m.bytes(), &ix) == .ok) {
        m.u = .{ .i = ix };
        return .{ .Int = true };
    }
    return .{ .Real = true };
}

/// Port of numericType() (vdbe.c): MEM_Int and/or MEM_Real for the value,
/// setting u.i/u.r but not the flags.
pub fn numericType(m: *Mem) MEM {
    if (m.flags.intersects(.{ .Int = true, .Real = true, .IntReal = true, .Null = true })) {
        return m.flags.only(.{ .Int = true, .Real = true, .IntReal = true, .Null = true });
    }
    return computeNumericType(m);
}

/// Port of sqlite3_value_type(): the fundamental datatype.
pub fn valueType(m: *const Mem) i32 {
    const types = comptime blk: {
        var t: [64]u8 = undefined;
        for (0..64) |i| {
            const f = MEM.fromInt(i);
            t[i] = if (f.Null)
                vi.SQLITE_NULL
            else if (f.Int)
                vi.SQLITE_INTEGER
            else if (f.Real)
                vi.SQLITE_FLOAT
            else if (f.IntReal)
                vi.SQLITE_FLOAT
            else if (f.Str)
                vi.SQLITE_TEXT
            else if (f.Blob)
                vi.SQLITE_BLOB
            else
                vi.SQLITE_NULL;
        }
        break :blk t;
    };
    return types[m.flags.affIndex()];
}

/// Port of sqlite3_value_numeric_type().
pub fn valueNumericType(m: *Mem) i32 {
    var t = valueType(m);
    if (t == vi.SQLITE_TEXT and isUtf16(m)) {
        // UTF-16 text: a UTF-8 copy decides.
        const copy8 = utf8Copy(m) orelse return t;
        defer copy8.free(m);
        var tmp: Mem = .{ .db = m.db, .flags = .{ .Str = true, .Term = true, .Static = true }, .enc = ENC.UTF8, .z = copy8.s.ptr, .n = @intCast(copy8.s.len) };
        applyNumericAffinity(&tmp, false);
        if (!tmp.flags.Str) {
            m.u = tmp.u;
            m.flags.Str = false;
            m.flags.Int = tmp.flags.Int;
            m.flags.Real = tmp.flags.Real;
        }
        return valueType(m);
    }
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
    try std.testing.expectEqual(MEM{ .Int = true }, m.flags.only(MEM.TypeMask));
    try std.testing.expectEqual(@as(i64, 42), m.u.i);

    try setStr(&m, "48.00", ENC.UTF8, .transient);
    try applyAffinity(&m, Aff.integer, ENC.UTF8);
    try std.testing.expectEqual(@as(i64, 48), m.u.i);

    try setStr(&m, "1.5x", ENC.UTF8, .transient);
    try applyAffinity(&m, Aff.numeric, ENC.UTF8);
    try std.testing.expect(m.flags.Str);

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
