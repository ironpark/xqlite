//! Opcodes of records (vdbe.c): OP_Column, which decodes a field of the
//! record under a cursor (caching the parsed header in
//! VdbeCursor.offsets and .types), OP_MakeRecord, which encodes
//! registers into a record, and the affinity and type checks applied
//! around them. The record format itself is in ../record.zig and
//! ../serial.zig.

const std = @import("std");
const core = @import("../exec.zig");
const vi = @import("../vdbe_int.zig");
const mem = @import("../mem.zig");
const aux = @import("../aux.zig");
const serial = @import("../serial.zig");
const int = @import("../../sql/sqlite_int.zig");
const varint = @import("../../util/varint.zig");

const Exec = core.Exec;
const Flow = core.Flow;
const Op = vi.Op;
const Mem = vi.Mem;
const MEM = vi.MEM;
const ENC = vi.ENC;
const VdbeCursor = vi.VdbeCursor;
const RC = int.RC;
const Aff = int.Aff;

/// vdbeMemTypeName().
fn memTypeName(m: *const Mem) []const u8 {
    const names = [_][]const u8{ "INT", "REAL", "TEXT", "BLOB", "NULL" };
    return names[@intCast(mem.valueType(m) - 1)];
}

/// sqlite3StdType.
pub const std_type = [_][]const u8{ "ANY", "BLOB", "INT", "INTEGER", "REAL", "TEXT" };

pub fn opIsType(e: *Exec, op: *Op) Flow {
    var type_mask: u16 = undefined;
    if (op.p1 >= 0) {
        const c = e.csr(op.p1);
        if (op.p3 < c.n_hdr_parsed) {
            const st = c.types[@intCast(op.p3)];
            if (st >= 12) {
                type_mask = if (st & 1 != 0) 0x04 else 0x08;
            } else {
                const masks = [_]u16{ 0x10, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x2, 0x01, 0x01, 0x10, 0x10 };
                type_mask = masks[st];
            }
        } else {
            type_mask = @as(u16, 1) << @intCast(op.p4.int32 - 1);
        }
    } else {
        type_mask = @as(u16, 1) << @intCast(mem.valueType(e.reg(op.p3)) - 1);
    }
    return if (type_mask & op.p5 != 0) .jump_p2 else .next;
}

// ================================================================ OP_Column

/// The op_column_corrupt exit.
fn columnCorrupt(e: *Exec) Flow {
    if (e.ops[0].p3 > 0) {
        e.pc = e.ops[0].p3 - 1;
        return .goto_pc;
    }
    e.rc = RC.CORRUPT;
    return .abort;
}

/// Port of OP_Column.
pub fn opColumn(e: *Exec, op: *Op) Flow {
    const v = e.v;
    var c = e.csr(op.p1);
    var p2: u32 = @intCast(op.p2);
    // Only set (and released) when the header is not all on the page.
    var s_mem: Mem = undefined;
    restart: while (true) {
        const offsets = c.offsets.ptr;
        // Where to resume parsing the header (in locals: the stores to
        // the cursor would otherwise force reloads).
        var z_data: []const u8 = undefined;
        var parse = false;
        var i_parse: u32 = undefined;
        var hdr_parse: u32 = undefined;
        var end_hdr: u32 = undefined;
        if (c.cache_status != v.cache_ctr) {
            if (c.null_row) {
                if (c.e_cur_type == .pseudo and c.seek_result > 0) {
                    // The register of a pseudo cursor holds the record.
                    const preg = e.reg(c.seek_result);
                    c.payload_size = @intCast(preg.n);
                    c.sz_row = @intCast(preg.n);
                    c.row = preg.z;
                } else {
                    mem.setNull(e.reg(op.p3));
                    return .next;
                }
            } else {
                const cur = c.uc.cursor;
                if (c.deferred_moveto) {
                    if (c.alt_map) |map| {
                        const i_map = map[1 + p2];
                        if (i_map > 0) {
                            c = c.alt_cursor.?;
                            p2 = i_map - 1;
                            continue :restart;
                        }
                    }
                    serial.finishMoveto(c) catch |err| return e.fail(err);
                } else if (cur.hasMoved()) {
                    serial.handleMovedCursor(c) catch |err| return e.fail(err);
                    continue :restart;
                }
                const fetched = cur.payloadFetchWithSize();
                c.payload_size = fetched.n_payload;
                c.row = fetched.local.ptr;
                c.sz_row = @intCast(fetched.local.len);
            }
            c.cache_status = v.cache_ctr;
            const row0 = c.row.?[0..c.sz_row];
            const hd = serial.getVarint32(row0, 0);
            end_hdr = hd.value;
            offsets[0] = end_hdr;
            c.i_hdr_offset = hd.len;
            c.n_hdr_parsed = 0;
            if (row0.len < end_hdr) {
                // The header is not all on the page.
                c.row = null;
                c.sz_row = 0;
                if (end_hdr > 98307 or end_hdr > c.payload_size) return columnCorrupt(e);
            } else {
                // Go straight to parsing (nHdrParsed <= p2 holds).
                z_data = row0;
                parse = true;
                i_parse = 0;
                hdr_parse = hd.len;
            }
        } else if (c.e_cur_type == .btree and c.uc.cursor.hasMoved()) {
            serial.handleMovedCursor(c) catch |err| return e.fail(err);
            continue :restart;
        }

        if (!parse) {
            if (c.n_hdr_parsed > p2) break;
            end_hdr = offsets[0];
            if (c.i_hdr_offset < end_hdr) {
                // Make sure z_data covers the header.
                if (c.row) |row| {
                    z_data = row[0..c.sz_row];
                } else {
                    s_mem = .{ .db = e.db, .flags = 0 };
                    mem.fromBtreeZeroOffset(c.uc.cursor, end_hdr, &s_mem) catch |err| return e.fail(err);
                    z_data = s_mem.bytes();
                }
                parse = true;
                i_parse = c.n_hdr_parsed;
                hdr_parse = c.i_hdr_offset;
            }
        }
        if (parse) {
            // op_column_read_header: fill in types[] and offsets[]
            // through field p2.
            const types = c.types.ptr;
            const payload_size = c.payload_size;
            var i = i_parse;
            var offset64: u64 = offsets[i];
            var hdr = hdr_parse;
            while (true) {
                // One-byte serial types in line (a byte past the end of a
                // corrupt record reads as 0).
                var t: u32 = if (hdr < z_data.len) z_data[hdr] else 0;
                if (t < 0x80) {
                    hdr += 1;
                    offset64 += serial.small_type_sizes[t];
                } else {
                    const d = serial.getVarint32Slow(z_data, hdr);
                    t = d.value;
                    hdr += d.len;
                    offset64 += serial.serialTypeLen(t);
                }
                types[i] = t;
                i += 1;
                offsets[i] = @truncate(offset64);
                if (!(i <= p2 and hdr < end_hdr)) break;
            }
            // Corrupt if the header runs past its declared size, the data
            // does not end with the record, or runs past it.
            if ((hdr >= end_hdr and (hdr > end_hdr or offset64 != payload_size)) or
                offset64 > payload_size)
            {
                if (end_hdr == 0) {
                    i = 0;
                    hdr = end_hdr;
                } else {
                    if (c.row == null) mem.release(&s_mem);
                    return columnCorrupt(e);
                }
            }
            c.n_hdr_parsed = @intCast(i);
            c.i_hdr_offset = hdr;
            if (c.row == null) mem.release(&s_mem);
            if (i > p2) break;
        }
        // Fewer columns than p2: the default value or NULL.
        const dest = e.reg(op.p3);
        if (op.p4type == .mem) {
            mem.shallowCopy(dest, op.p4.mem, MEM.Static);
        } else {
            mem.setNull(dest);
        }
        return .next;
    }
    const t = c.types[p2];
    const offsets = c.offsets.ptr;
    const dest = e.reg(op.p3);
    if (dest.isDynamic()) mem.setNull(dest);
    if (c.sz_row >= offsets[p2 + 1]) {
        // The content is on the page: the in-line sqlite3VdbeSerialGet().
        const z = c.row.? + offsets[p2];
        if (t < 12) {
            serial.serialGetPtr(z, t, dest);
        } else {
            // A string or blob gets its own copy (sqlite3VdbeSerialGet()
            // then sqlite3VdbeDeephemeralize()).
            const len: u32 = (t - 12) / 2;
            dest.n = @intCast(len);
            dest.enc = e.encoding;
            if (dest.szMalloc() < len + 2) {
                if (len > e.db.limit(.length)) return .too_big;
                dest.flags = MEM.Null;
                mem.grow(dest, len + 2, false) catch return .no_mem;
            } else {
                dest.z = dest.z_malloc.ptr;
            }
            const out = dest.z.?;
            @memcpy(out[0..len], z[0..len]);
            out[len] = 0;
            out[len + 1] = 0;
            dest.flags = if (t & 1 != 0) MEM.Str | MEM.Term else MEM.Blob;
        }
    } else {
        dest.enc = e.encoding;
        const p5 = op.p5 & vi.OPFLAG.BYTELENARG;
        if ((p5 != 0 and (p5 == vi.OPFLAG.TYPEOFARG or (t >= 12 and (t & 1 == 0 or p5 == vi.OPFLAG.BYTELENARG)))) or
            serial.serialTypeLen(t) == 0)
        {
            // The content does not matter; use zeros.
            const zeros: [16]u8 = @splat(0);
            serial.serialGet(&zeros, 0, t, dest);
            if (t >= 12) {
                dest.z = null;
                dest.flags &= ~MEM.Ephem;
                dest.flags |= MEM.Static;
            }
        } else {
            columnFromOverflow(e, c, t, offsets[p2], dest) catch |err| switch (err) {
                error.OutOfMemory => return .no_mem,
                error.TooBig => return .too_big,
                else => return e.fail(err),
            };
        }
    }
    return .next;
}

/// Port of vdbeColumnFromOverflow() (without the large-value cache).
fn columnFromOverflow(e: *Exec, c: *VdbeCursor, t: u32, offset: u32, dest: *Mem) !void {
    const len = serial.serialTypeLen(t);
    if (len > e.db.limit(.length)) return error.TooBig;
    try mem.fromBtree(c.uc.cursor, offset, len, dest);
    serial.serialGet(dest.z.?[0..len], 0, t, dest);
    if (t & 1 != 0 and dest.enc == ENC.UTF8) {
        dest.z.?[len] = 0;
        dest.flags |= MEM.Term;
    }
    dest.flags &= ~MEM.Ephem;
}

// ===================================================== affinity and types

pub fn opTypeCheck(e: *Exec, op: *Op) Flow {
    const tab = op.p4.table;
    const cols = tab.cols;
    var in1: i32 = op.p1;
    var i: usize = undefined;
    var n_col: usize = undefined;
    if (op.p3 < 2) {
        i = 0;
        n_col = cols.len;
    } else {
        i = @intCast(op.p3 - 2);
        n_col = i + 1;
    }
    while (i < n_col) : (i += 1) {
        const col = &cols[i];
        if (col.col_flags & int.COLFLAG.GENERATED != 0 and op.p3 < 2) {
            if (col.col_flags & int.COLFLAG.VIRTUAL != 0) continue;
            if (op.p3 != 0) {
                in1 += 1;
                continue;
            }
        }
        const m = e.reg(in1);
        mem.applyAffinity(m, col.affinity, e.encoding) catch return .no_mem;
        if (m.flags & MEM.Null == 0) {
            const ok = switch (col.e_ctype) {
                int.COLTYPE.BLOB => m.flags & MEM.Blob != 0,
                int.COLTYPE.INTEGER, int.COLTYPE.INT => m.flags & MEM.Int != 0,
                int.COLTYPE.TEXT => m.flags & MEM.Str != 0,
                int.COLTYPE.REAL => blk: {
                    if (m.flags & MEM.Int != 0) {
                        // Keep a small integer exact, but typed REAL.
                        if (m.u.i <= 140737488355327 and m.u.i >= -140737488355328) {
                            m.flags |= MEM.IntReal;
                            m.flags &= ~MEM.Int;
                        } else {
                            m.u = .{ .r = @floatFromInt(m.u.i) };
                            m.flags |= MEM.Real;
                            m.flags &= ~MEM.Int;
                        }
                        break :blk true;
                    }
                    break :blk m.flags & (MEM.Real | MEM.IntReal) != 0;
                },
                else => true,
            };
            if (!ok) {
                aux.vdbeError(e.v, "cannot store {s} value in {s} column {s}.{s}", .{
                    memTypeName(m), std_type[col.e_ctype - 1], tab.name, col.name(),
                });
                e.rc = RC.CONSTRAINT_DATATYPE;
                return .abort;
            }
        }
        in1 += 1;
    }
    return .next;
}

pub fn opAffinity(e: *Exec, op: *Op) Flow {
    const aff = op.p4.z;
    var in1 = op.p1;
    var i: usize = 0;
    while (aff[i] != 0) : (i += 1) {
        const a = aff[i];
        const m = e.reg(in1);
        mem.applyAffinity(m, a, e.encoding) catch return .no_mem;
        if (a == Aff.real and m.flags & MEM.Int != 0) {
            m.u = .{ .r = @floatFromInt(m.u.i) };
            m.flags |= MEM.Real;
            m.flags &= ~(MEM.Int | MEM.Str);
        }
        in1 += 1;
    }
    return .next;
}

// ============================================================ OP_MakeRecord

pub fn opMakeRecord(e: *Exec, op: *Op) Flow {
    const n_field: usize = @intCast(op.p2);
    const data0: usize = @intCast(op.p1);
    const recs = e.regs[data0..][0..n_field];
    const out = e.reg(op.p3);
    if (op.p4type == .z) {
        const aff = op.p4.z;
        var i: usize = 0;
        while (aff[i] != 0) : (i += 1) {
            const a = aff[i];
            const rec = &recs[i];
            mem.applyAffinity(rec, a, e.encoding) catch return .no_mem;
            if (a == Aff.real and rec.flags & MEM.Int != 0) {
                rec.flags |= MEM.IntReal;
                rec.flags &= ~MEM.Int;
            }
        }
    }

    // Pick the serial type of each field and size the record.
    var n_data: u64 = 0;
    var n_hdr: u64 = 0;
    var n_zero: i64 = 0;
    var k = n_field;
    while (k > 0) {
        k -= 1;
        const rec = &recs[k];
        if (rec.flags & MEM.Null != 0) {
            rec.u_temp = if (rec.flags & MEM.Zero != 0) 10 else 0;
            n_hdr += 1;
        } else if (rec.flags & (MEM.Int | MEM.IntReal) != 0) {
            const i = rec.u.i;
            const uu: u64 = if (i < 0) @bitCast(~i) else @bitCast(i);
            n_hdr += 1;
            if (uu <= 127) {
                if (i & 1 == i and e.v.min_write_file_format >= 4) {
                    rec.u_temp = 8 + @as(u32, @intCast(uu));
                } else {
                    n_data += 1;
                    rec.u_temp = 1;
                }
            } else if (uu <= 32767) {
                n_data += 2;
                rec.u_temp = 2;
            } else if (uu <= 8388607) {
                n_data += 3;
                rec.u_temp = 3;
            } else if (uu <= 2147483647) {
                n_data += 4;
                rec.u_temp = 4;
            } else if (uu <= 140737488355327) {
                n_data += 6;
                rec.u_temp = 5;
            } else {
                n_data += 8;
                if (rec.flags & MEM.IntReal != 0) {
                    // An 8-byte integer might as well be a real.
                    rec.u = .{ .r = @floatFromInt(rec.u.i) };
                    rec.flags &= ~MEM.IntReal;
                    rec.flags |= MEM.Real;
                    rec.u_temp = 7;
                } else {
                    rec.u_temp = 6;
                }
            }
        } else if (rec.flags & MEM.Real != 0) {
            n_hdr += 1;
            n_data += 8;
            rec.u_temp = 7;
        } else {
            var len: u64 = @intCast(rec.n);
            var serial_type: u64 = len * 2 + 12 + @intFromBool(rec.flags & MEM.Str != 0);
            if (rec.flags & MEM.Zero != 0) {
                serial_type += @as(u64, @intCast(rec.u.n_zero)) * 2;
                if (n_data != 0) {
                    mem.expandBlob(rec) catch return .no_mem;
                    len = @intCast(rec.n);
                } else {
                    n_zero += rec.u.n_zero;
                }
            }
            n_data += len;
            n_hdr += varint.len(serial_type);
            rec.u_temp = @intCast(serial_type);
        }
    }
    if (n_hdr <= 126) {
        n_hdr += 1;
    } else {
        const n_varint = varint.len(n_hdr);
        n_hdr += n_varint;
        if (n_varint < varint.len(n_hdr)) n_hdr += 1;
    }
    const n_byte = n_hdr + n_data;
    if (n_byte + @as(u64, @intCast(n_zero)) <= out.szMalloc()) {
        out.z = out.z_malloc.ptr;
    } else {
        if (n_byte + @as(u64, @intCast(n_zero)) > @as(u64, @intCast(e.db.limit(.length)))) return .too_big;
        mem.clearAndResize(out, @intCast(n_byte)) catch return .no_mem;
    }
    out.n = @intCast(n_byte);
    out.flags = MEM.Blob;
    if (n_zero != 0) {
        out.u = .{ .n_zero = @intCast(n_zero) };
        out.flags |= MEM.Zero;
    }
    const z = out.z.?[0..@intCast(n_byte)];
    var hdr: usize = varint.put(z, n_hdr);
    var payload: usize = @intCast(n_hdr);
    for (recs) |*rec| {
        const st = rec.u_temp;
        hdr += varint.put(z[hdr..], st);
        if (st >= 1 and st <= 7) {
            const bits: u64 = if (st == 7) @bitCast(rec.u.r) else @bitCast(rec.u.i);
            const len = serial.small_type_sizes[st];
            var j: usize = len;
            var x = bits;
            while (j > 0) {
                j -= 1;
                z[payload + j] = @truncate(x);
                x >>= 8;
            }
            payload += len;
        } else if (st >= 12 and rec.n > 0) {
            const n: usize = @intCast(rec.n);
            @memcpy(z[payload..][0..n], rec.z.?[0..n]);
            payload += n;
        }
    }
    std.debug.assert(hdr == n_hdr and payload == n_byte);
    return .next;
}
