//! The b-tree layer (port of btree.c).
//!
//! A database file holds many b-trees, each identified by its root page.
//! Table b-trees (intkey) map a 64-bit rowid to a payload and keep all
//! content in the leaves; index b-trees (blobkey) store keys only, with
//! content in interior cells too. Payloads that do not fit on a page spill
//! into a chain of overflow pages. Free pages are kept on the freelist
//! (trunk pages each listing leaf pages).
//!
//! `Btree` is one open database (BtShared and Btree merged: there is no
//! shared cache). `Cursor` walks and modifies one b-tree.
//!
//! In auto-vacuum databases every page move also updates the pointer map
//! (ptrmap.zig), and commit relocates pages to drop free pages from the
//! end of the file.
//!
//! A database whose header says read version 2 is opened in WAL mode
//! (lockBtree), and `setVersion` switches the file between the two.
//!
//! Not ported yet: shared cache, incremental blob I/O and
//! BtreeTransferRow.

const std = @import("std");
const thunk = @import("../util/thunk.zig");
const vfs = @import("../vfs/vfs.zig");
const pager_mod = @import("../pager/pager.zig");
const varint = @import("../util/varint.zig");
pub const header = @import("header.zig");
const page = @import("page.zig");
const ptrmap = @import("ptrmap.zig");

const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const Pager = pager_mod.Pager;
const CellInfo = page.CellInfo;
const get2 = page.get2;
const put2 = page.put2;
const get4 = page.get4;
const put4 = page.put4;

pub const Pgno = pager_mod.Pgno;
pub const MemPage = page.MemPage;
pub const max_depth = page.max_depth;

pub const Error = pager_mod.Error || error{
    /// The file is not a database, or uses a format this build cannot read
    /// (SQLITE_NOTADB).
    NotADatabase,
};

/// Errors a key comparison may report.
pub const CompareError = error{ Corrupt, OutOfMemory };

/// MX_CELL: the most cells a page can hold.
pub fn maxCells(page_size: u32) u32 {
    return (page_size - 8) / 6;
}

pub const TransState = enum { none, read, write };

pub const TransMode = enum {
    read,
    /// Takes a RESERVED lock.
    write,
    /// Takes an EXCLUSIVE lock up front.
    exclusive,
};

pub const TableKind = enum {
    /// 64-bit rowid keys with a payload (SQL tables).
    intkey,
    /// Arbitrary keys and no payload (SQL indexes).
    blobkey,
};

/// Indexes of the 4-byte meta values stored at offset 36 of page 1.
pub const Meta = enum(u4) {
    free_page_count = 0,
    schema_version = 1,
    file_format = 2,
    default_cache_size = 3,
    largest_root_page = 4,
    text_encoding = 5,
    user_version = 6,
    incr_vacuum = 7,
    application_id = 8,
    /// Not stored in the file: the pager's data version.
    data_version = 15,
};

/// PRAGMA secure_delete; the values are what the pragma reports.
pub const SecureDelete = enum(u2) {
    off = 0,
    /// Overwrite deleted content, including freelist pages, with zeros.
    on = 1,
    /// Overwrite deleted content in b-tree pages, but do not write freelist
    /// leaves back (PRAGMA secure_delete=FAST).
    fast = 2,
};

/// PRAGMA auto_vacuum (BTREE_AUTOVACUUM_*).
pub const AutoVacuum = enum(u2) {
    none = 0,
    /// Free pages are removed from the file at every commit.
    full = 1,
    /// Free pages stay until PRAGMA incremental_vacuum.
    incremental = 2,

    /// The mode recorded in a header: auto-vacuum if the largest root page
    /// is set, incremental if the incremental-vacuum field is too.
    fn fromHeader(largest_root_page: u32, incremental_vacuum: u32) AutoVacuum {
        if (largest_root_page == 0) return .none;
        return if (incremental_vacuum != 0) .incremental else .full;
    }
};

pub const Options = struct {
    /// Page size for a new database. Existing files use their own.
    page_size: u32 = header.default_page_size,
    read_only: bool = false,
    create: bool = true,
    journal_mode: pager_mod.JournalMode = .delete,
    synchronous: pager_mod.Synchronous = .full,
    full_fsync: bool = false,
    cache_size: i32 = -2000,
    busy_handler: ?pager_mod.BusyHandler = null,
    /// PRAGMA cell_size_check.
    cell_size_check: bool = false,
    secure_delete: SecureDelete = .off,
    /// Auto-vacuum mode for a new database. Existing files use their own.
    auto_vacuum: AutoVacuum = .none,
    /// Close the b-tree when its last cursor closes (BTREE_SINGLE), as
    /// ephemeral tables do.
    single: bool = false,
    /// The connection's count of reading statements (&db.n_vdbe_read) for
    /// a database of a connection; see Btree.n_vdbe_read. Null for a
    /// b-tree used on its own.
    n_vdbe_read: ?*const i32 = null,
};

/// Compares stored index keys against a search key: call(.{stored})
/// returns the order of `stored` relative to it. Made with
/// IndexKey.init(key, f) from a typed `f(key, stored)`.
pub const IndexKey = thunk.Closure(*const fn (ctx: *const anyopaque, stored: []const u8) CompareError!Order);

/// What the b-tree needs to know about an index's keys (its view of
/// KeyInfo): how to seek to a packed key, as when restoring a saved cursor
/// position or inserting without a prior seek: call(.{cur, key}) is
/// btreeMoveto() for index keys (unpack `key` once, then call
/// `cur.indexMoveto`). Made with KeyInfo.init(info, f) from a typed
/// `f(info, cur, key)`.
pub const KeyInfo = thunk.Closure(*const fn (ctx: *const anyopaque, cur: *Cursor, key: []const u8) Error!Order);

/// Content for `Cursor.insert` (BtreePayload).
pub const Payload = struct {
    /// The key of an index entry. Null for tables.
    key: ?[]const u8 = null,
    /// The rowid of a table entry.
    rowid: i64 = 0,
    /// The row content of a table entry.
    data: []const u8 = &.{},
    /// Zero bytes appended to `data`.
    n_zero: u32 = 0,
    /// How to seek to an index entry when no prior seek result is given:
    /// by a prefix of the key (BtreePayload.aMem/nMem), so an entry whose
    /// prefix is equal is overwritten. Null seeks by the whole `key`.
    seek: ?IndexKey = null,

    fn nKey(x: Payload) i64 {
        return if (x.key) |k| @intCast(k.len) else x.rowid;
    }
};

pub const Btree = struct {
    gpa: Allocator,
    pager: *Pager,
    /// Open cursors, newest first.
    cursors: ?*Cursor = null,
    /// Page 1, held for the duration of every transaction.
    page1: ?*MemPage = null,
    in_trans: TransState = .none,

    read_only: bool,
    /// The page size can no longer be changed (BTS_PAGESIZE_FIXED).
    page_size_fixed: bool = false,
    secure_delete: SecureDelete,
    /// The database was empty when the transaction started.
    initially_empty: bool = false,
    cell_size_check: bool,
    auto_vacuum: AutoVacuum = .none,
    /// An incremental vacuum shrank `n_page`; truncate at commit.
    do_truncate: bool = false,
    /// Closes with its last cursor (BTREE_SINGLE).
    single: bool = false,
    /// Do not open the WAL even if the header asks for it, while
    /// `setVersion` moves the file out of WAL mode (BTS_NO_WAL).
    no_wal: bool = false,
    /// The count of statements of the connection that read
    /// (p->db->nVdbeRead), if the b-tree belongs to one (Options): while
    /// others read, ending a transaction leaves a read transaction.
    n_vdbe_read: ?*const i32 = null,

    page_size: u32,
    usable_size: u32,
    /// Pages in the database.
    n_page: u32 = 0,
    reserve_wanted: u8 = 0,
    /// Payload limits for index pages (max_local, min_local) and table
    /// leaves (max_leaf, min_leaf).
    max_local: u16 = 0,
    min_local: u16 = 0,
    max_leaf: u16 = 0,
    min_leaf: u16 = 0,
    max1byte_payload: u8 = 0,

    /// Pages moved to the freelist in this transaction (pHasContent). Their
    /// content may matter for rollback, so reusing them must not skip the
    /// journal.
    has_content: std.AutoHashMapUnmanaged(Pgno, void) = .empty,
    /// Scratch space for one cell plus a 4-byte prefix (pTmpSpace).
    tmp_space: ?[]u8 = null,
    /// Compensates for the pager's data version bump on our own commits.
    data_version_bias: u32 = 0,

    // ================================================================ open

    /// Port of sqlite3BtreeOpen(). A null path opens an anonymous temporary
    /// database.
    pub fn open(gpa: Allocator, v: vfs.Vfs, path: ?[]const u8, opts: Options) Error!*Btree {
        const bt = try gpa.create(Btree);
        errdefer gpa.destroy(bt);
        const p = try Pager.open(gpa, v, path, .{
            .page_size = opts.page_size,
            .read_only = opts.read_only,
            .create = opts.create,
            .journal_mode = opts.journal_mode,
            .synchronous = opts.synchronous,
            .full_fsync = opts.full_fsync,
            .extra_size = @sizeOf(MemPage),
            .cache_size = opts.cache_size,
            .busy_handler = opts.busy_handler,
            .reiniter = pageReinit,
        });
        errdefer p.close(.{});

        var hdr: [header.size]u8 = undefined;
        try p.readFileHeader(&hdr);
        bt.* = .{
            .gpa = gpa,
            .pager = p,
            .read_only = p.isReadOnly(),
            .secure_delete = opts.secure_delete,
            .cell_size_check = opts.cell_size_check,
            .page_size = opts.page_size,
            .usable_size = opts.page_size,
            .auto_vacuum = opts.auto_vacuum,
            .single = opts.single,
            .n_vdbe_read = opts.n_vdbe_read,
        };
        var reserve: u8 = 0;
        if (header.pageSize(&hdr)) |page_size| {
            bt.page_size = page_size;
            reserve = hdr[header.reserved_space_offset];
            bt.page_size_fixed = true;
            bt.auto_vacuum = .fromHeader(header.get(&hdr, .largest_root_page), header.get(&hdr, .incremental_vacuum));
        }
        try p.setPageSize(bt.page_size, reserve);
        bt.usable_size = bt.page_size - reserve;
        return bt;
    }

    /// Port of sqlite3BtreeClose(). All cursors must be closed. Rolls back
    /// any open transaction. `db` is the connection's part in closing a
    /// WAL (see Pager.close).
    pub fn close(bt: *Btree, db: pager_mod.Conn) void {
        std.debug.assert(bt.cursors == null);
        bt.rollback(null, false) catch {};
        bt.pager.close(db);
        bt.has_content.deinit(bt.gpa);
        bt.freeTempSpace();
        bt.gpa.destroy(bt);
    }

    pub fn setCacheSize(bt: *Btree, n: i32) void {
        bt.pager.setCacheSize(n);
    }

    /// Port of sqlite3BtreeSetPagerFlags().
    pub fn setPagerFlags(bt: *Btree, level: pager_mod.Synchronous, full_fsync: bool, ckpt_full_fsync: bool, cache_spill: bool) void {
        bt.pager.setFlags(level, full_fsync, ckpt_full_fsync, cache_spill);
    }

    /// Port of sqlite3BtreeSetSpillSize(): set the cache spill threshold
    /// (0 leaves it) and return the effective one.
    pub fn setSpillSize(bt: *Btree, n: i32) u32 {
        return bt.pager.setSpillSize(n);
    }

    /// Port of sqlite3BtreeMaxPageCount().
    pub fn maxPageCount(bt: *Btree, mx: Pgno) Pgno {
        return bt.pager.maxPageCount(mx);
    }

    /// Port of sqlite3BtreeSecureDelete(): change the setting unless
    /// `mode` is null. Returns the setting in effect.
    pub fn secureDelete(bt: *Btree, mode: ?SecureDelete) SecureDelete {
        if (mode) |m| bt.secure_delete = m;
        return bt.secure_delete;
    }

    /// Port of sqlite3BtreeSetPageSize(). `page_size` 0 keeps the current
    /// size. Fails with ReadOnly once the size is fixed (the database
    /// exists). `fix` fixes it now.
    pub fn setPageSize(bt: *Btree, page_size: u32, reserve_arg: u8, fix: bool) Error!void {
        bt.reserve_wanted = reserve_arg;
        var reserve = reserve_arg;
        const current: u8 = @intCast(bt.page_size - bt.usable_size);
        if (current == reserve and (page_size == 0 or page_size == bt.page_size)) return;
        if (reserve < current) reserve = current;
        if (bt.page_size_fixed) return error.ReadOnly;
        if (header.validPageSize(page_size)) {
            std.debug.assert(bt.cursors == null);
            bt.page_size = if (reserve > 32 and page_size == 512) 1024 else page_size;
            bt.freeTempSpace();
        }
        try bt.pager.setPageSize(bt.page_size, reserve);
        // The pager ignores the change while pages are referenced.
        bt.page_size = bt.pager.page_size;
        bt.usable_size = bt.page_size - reserve;
        if (fix) bt.page_size_fixed = true;
    }

    pub fn getPageSize(bt: *const Btree) u32 {
        return bt.page_size;
    }

    /// Bytes reserved at the end of every page.
    pub fn getReserve(bt: *const Btree) u32 {
        return bt.page_size - bt.usable_size;
    }

    /// Pages in the database (sqlite3BtreeLastPage).
    pub fn lastPage(bt: *const Btree) Pgno {
        return bt.n_page;
    }

    pub fn txnState(bt: *const Btree) TransState {
        return bt.in_trans;
    }

    /// Port of sqlite3BtreeSetAutoVacuum(). Fails with ReadOnly if the
    /// database exists and the change would turn auto-vacuum on or off.
    pub fn setAutoVacuum(bt: *Btree, mode: AutoVacuum) Error!void {
        if (bt.page_size_fixed and (mode != .none) != bt.isAutoVacuum()) return error.ReadOnly;
        bt.auto_vacuum = mode;
    }

    /// Port of sqlite3BtreeGetAutoVacuum().
    pub fn getAutoVacuum(bt: *const Btree) AutoVacuum {
        return bt.auto_vacuum;
    }

    /// ISAUTOVACUUM: the file has pointer-map pages (full or incremental).
    pub fn isAutoVacuum(bt: *const Btree) bool {
        return bt.auto_vacuum != .none;
    }

    // ======================================================= page helpers

    /// Port of btreePageFromDbPage().
    fn pageFromDbPage(bt: *Btree, pg: *pager_mod.Page, pgno: Pgno) *MemPage {
        const mp = MemPage.of(pg);
        if (pgno != mp.pgno) {
            mp.data = pg.data.ptr;
            mp.db_page = pg;
            mp.bt = bt;
            mp.pgno = pgno;
            mp.hdr_offset = if (pgno == 1) 100 else 0;
        }
        return mp;
    }

    /// Port of btreeGetPage(). The page is not initialized.
    pub fn getPage(bt: *Btree, pgno: Pgno, flags: pager_mod.GetFlags) Error!*MemPage {
        const pg = try bt.pager.get(pgno, flags);
        return bt.pageFromDbPage(pg, pgno);
    }

    /// Port of btreePageLookup(): the page if it is cached, referenced.
    fn lookupPage(bt: *Btree, pgno: Pgno) ?*MemPage {
        const pg = bt.pager.lookup(pgno) orelse return null;
        return bt.pageFromDbPage(pg, pgno);
    }

    /// Port of getAndInitPage().
    fn getAndInitPage(bt: *Btree, pgno: Pgno) Error!*MemPage {
        if (pgno > bt.n_page) return error.Corrupt;
        const pg = try bt.pager.get(pgno, .{});
        const mp = MemPage.of(pg);
        if (!mp.is_init) {
            _ = bt.pageFromDbPage(pg, pgno);
            mp.init() catch |err| {
                releasePage(mp);
                return err;
            };
        }
        return mp;
    }

    /// Port of btreeGetUnusedPage(): a page about to be reused, which no one
    /// else may be referencing.
    fn getUnusedPage(bt: *Btree, pgno: Pgno, flags: pager_mod.GetFlags) Error!*MemPage {
        const mp = try bt.getPage(pgno, flags);
        if (mp.db_page.n_ref > 1) {
            releasePage(mp);
            return error.Corrupt;
        }
        mp.is_init = false;
        return mp;
    }

    fn allocateTempSpace(bt: *Btree) Error!void {
        if (bt.tmp_space != null) return;
        // 8 spare bytes so cell parsers may overrun a maximal cell.
        const t = try bt.gpa.alloc(u8, bt.page_size + 8);
        // Cells shorter than 4 bytes are padded from here, and the first 4
        // bytes are room to prepend a child pointer.
        @memset(t[0..8], 0);
        @memset(t[bt.page_size..], 0);
        bt.tmp_space = t;
    }

    fn freeTempSpace(bt: *Btree) void {
        if (bt.tmp_space) |t| bt.gpa.free(t);
        bt.tmp_space = null;
    }

    /// The cell-sized part of the scratch space.
    fn tmpCell(bt: *Btree) [*]u8 {
        return bt.tmp_space.?.ptr + 4;
    }

    // =========================================================== locking

    /// Port of lockBtree(): take a read lock and load page 1. Leaves
    /// `page1` null after adopting a page size read from the file; the
    /// caller retries.
    fn lockBtree(bt: *Btree) Error!void {
        std.debug.assert(bt.page1 == null);
        try bt.pager.sharedLock();
        const p1 = try bt.getPage(1, .{});
        // Released on every path that does not keep page 1 in `page1`.
        var held = true;
        defer if (held) bt.pager.unrefPageOne(p1.db_page);
        const data = p1.data;

        var n_page = header.get(data, .database_size);
        const n_page_file = bt.pager.pageCount();
        // The in-header size is only trustworthy if a 3.7.0+ writer kept
        // the version-valid-for field in sync.
        if (n_page == 0 or header.get(data, .file_change_counter) != header.get(data, .version_valid_for)) n_page = n_page_file;
        if (n_page > 0) {
            const h = try header.Header.parse(data[0..header.size]);
            // Unknown write versions make the file read-only; parse()
            // refused unknown read versions.
            if (h.readOnly()) bt.read_only = true;
            // Read version 2: the database is in WAL mode. Open the WAL,
            // and let the caller retry, as page 1 may be newer there.
            if (h.read_version == .wal and !bt.no_wal) {
                if (!try bt.pager.openWal()) return;
            }
            if (h.page_size != bt.page_size) {
                // Page 1 was read with the wrong page size. Adopt the real
                // one and let the caller try again. The pager ignores the
                // change while page 1 is referenced, so release it first.
                held = false;
                bt.pager.unrefPageOne(p1.db_page);
                bt.page_size = h.page_size;
                bt.usable_size = h.usableSize();
                bt.page_size_fixed = true;
                bt.freeTempSpace();
                try bt.pager.setPageSize(h.page_size, h.reserved_space);
                return;
            }
            if (n_page > n_page_file) return error.Corrupt;
            bt.page_size_fixed = true;
            bt.usable_size = h.usableSize();
            bt.auto_vacuum = .fromHeader(h.largest_root_page, h.incremental_vacuum);
        }

        // A cell needs room for a 2-byte pointer, a header of up to 17
        // bytes and a 4-byte overflow pointer; maxLocal keeps at least four
        // cells per page.
        bt.max_local = @intCast((bt.usable_size - 12) * 64 / 255 - 23);
        bt.min_local = @intCast((bt.usable_size - 12) * 32 / 255 - 23);
        bt.max_leaf = @intCast(bt.usable_size - 35);
        bt.min_leaf = @intCast((bt.usable_size - 12) * 32 / 255 - 23);
        bt.max1byte_payload = @intCast(@min(bt.max_local, 127));
        bt.page1 = p1;
        held = false;
        bt.n_page = n_page;
    }

    /// Port of unlockBtreeIfUnused(): drop page 1, and with it the read
    /// lock, once no transaction is open.
    fn unlockIfUnused(bt: *Btree) void {
        if (bt.in_trans == .none) {
            if (bt.page1) |p1| {
                std.debug.assert(bt.pager.refCount() == 1);
                bt.page1 = null;
                bt.pager.unrefPageOne(p1.db_page);
            }
        }
    }

    /// Port of newDatabase(): format an empty file as a one-page database.
    fn newDatabase(bt: *Btree) Error!void {
        if (bt.n_page > 0) return;
        const p1 = bt.page1.?;
        const data = p1.data;
        try bt.pager.write(p1.db_page);
        const h: header.Header = .{
            .page_size = bt.page_size,
            .reserved_space = @intCast(bt.page_size - bt.usable_size),
            .database_size = 1,
            // Left for the schema layer, as SQLite does.
            .schema_format = 0,
            .text_encoding = @fromBackingInt(@intCast(0)),
            .largest_root_page = @intFromBool(bt.isAutoVacuum()),
            .incremental_vacuum = @intFromBool(bt.auto_vacuum == .incremental),
        };
        h.write(data[0..header.size]);
        p1.zero(page.table_leaf);
        bt.page_size_fixed = true;
        bt.n_page = 1;
    }

    /// Port of sqlite3BtreeNewDb(): reinitialize page 1 as an empty
    /// database. Requires a write transaction.
    pub fn newDb(bt: *Btree) Error!void {
        bt.n_page = 0;
        return bt.newDatabase();
    }

    // ======================================================= transactions

    /// Port of sqlite3BtreeBeginTrans(). A no-op if a transaction of the
    /// requested strength is already open; a read transaction can be
    /// upgraded. Lock contention retries through the busy handler only
    /// when no transaction was open (holding a read lock while waiting for
    /// a writer could deadlock). A write transaction makes sure the pager
    /// has `n_savepoint` savepoints open (the connection's nSavepoint).
    pub fn beginTrans(bt: *Btree, mode: TransMode, n_savepoint: u32) Error!void {
        const wrflag = mode != .read;
        if (bt.in_trans == .write or (bt.in_trans == .read and !wrflag)) {
            if (wrflag) try bt.pager.openSavepoint(n_savepoint);
            return;
        }
        if (bt.read_only and wrflag) return error.ReadOnly;

        bt.initially_empty = bt.n_page == 0;
        while (true) {
            bt.tryBegin(mode) catch |err_arg| {
                var err = err_arg;
                // A stale WAL snapshot outside a transaction is plain
                // contention: a new read transaction gets a fresh one.
                if (err == error.BusySnapshot and bt.in_trans == .none) err = error.Busy;
                if ((err == error.Busy or err == error.BusyRecovery) and bt.in_trans == .none) {
                    if (bt.pager.busy_handler) |h| if (h.call(.{})) continue;
                }
                return err;
            };
            break;
        }

        bt.in_trans = if (wrflag) .write else .read;
        if (wrflag) {
            // Fix the in-header size if an old writer left it wrong, so that
            // a rollback can trust it.
            const p1 = bt.page1.?;
            if (bt.n_page != header.get(p1.data, .database_size)) {
                try bt.pager.write(p1.db_page);
                header.put(p1.data, .database_size, bt.n_page);
            }
            try bt.pager.openSavepoint(n_savepoint);
        }
    }

    /// Port of sqlite3BtreeBeginStmt(): open statement transaction
    /// `i_statement`, a savepoint numbered after every SAVEPOINT the
    /// connection has open. Requires a write transaction.
    pub fn beginStmt(bt: *Btree, i_statement: u32) Error!void {
        std.debug.assert(bt.in_trans == .write and !bt.read_only and i_statement > 0);
        try bt.pager.openSavepoint(i_statement);
    }

    /// Port of sqlite3BtreeSavepoint(): release savepoint `i` (and those
    /// opened after it), or roll back to it; rolling back to -1 restores
    /// the start of the transaction. A no-op without a write transaction.
    /// Cursors are saved first on rollback; their positions may no longer
    /// exist afterwards.
    pub fn savepoint(bt: *Btree, op: pager_mod.SavepointOp, i: i32) Error!void {
        if (bt.in_trans != .write) return;
        std.debug.assert(i >= 0 or (i == -1 and op == .rollback));
        if (op == .rollback) try bt.saveAllCursors(0, null);
        try bt.pager.savepoint(op, i);
        if (i < 0 and bt.initially_empty) bt.n_page = 0;
        try bt.newDatabase();
        bt.setNPage(bt.page1.?);
    }

    fn tryBegin(bt: *Btree, mode: TransMode) Error!void {
        errdefer bt.unlockIfUnused();
        while (bt.page1 == null) try bt.lockBtree();
        if (mode != .read) {
            if (bt.read_only) return error.ReadOnly;
            try bt.pager.begin(mode == .exclusive);
            try bt.newDatabase();
        }
    }

    /// Port of sqlite3BtreeSetVersion(): set the read and write versions of
    /// the header to 2 (WAL) or 1 (rollback), in a write transaction left
    /// for the caller to commit. Version 1 keeps the WAL from opening
    /// meanwhile, even if the header still says 2.
    pub fn setVersion(bt: *Btree, version: u8) Error!void {
        std.debug.assert(version == 1 or version == 2);
        bt.no_wal = version == 1;
        defer bt.no_wal = false;
        try bt.beginTrans(.read, 0);
        const data = bt.page1.?.data;
        if (data[header.write_version_offset] != version or data[header.read_version_offset] != version) {
            try bt.beginTrans(.exclusive, 0);
            try bt.pager.write(bt.page1.?.db_page);
            data[header.write_version_offset] = version;
            data[header.read_version_offset] = version;
        }
    }

    /// Port of sqlite3BtreeCheckpoint(): checkpoint the WAL (see
    /// Pager.checkpoint). Fails with Locked inside a transaction.
    pub fn checkpoint(bt: *Btree, db: pager_mod.Conn, mode: pager_mod.CheckpointMode, n_log: ?*i32, n_ckpt: ?*i32) (Error || error{Locked})!void {
        if (bt.in_trans != .none) return error.Locked;
        // An empty database switched to WAL mode has not opened its WAL
        // yet; a read transaction does that (C runs PRAGMA table_list).
        if (!bt.pager.useWal() and bt.pager.journal_mode == .wal) {
            if (bt.beginTrans(.read, 0)) |_| {
                bt.commitPhaseTwo(false) catch {};
            } else |_| {}
        }
        try bt.pager.checkpoint(db, mode, n_log, n_ckpt);
    }

    /// Port of sqlite3BtreeCommitPhaseOne(): write and sync everything. Only
    /// finalizing the journal remains.
    pub fn commitPhaseOne(bt: *Btree) Error!void {
        if (bt.in_trans != .write) return;
        if (bt.isAutoVacuum()) try bt.autoVacuumCommit();
        if (bt.do_truncate) bt.pager.truncateImage(bt.n_page);
        try bt.pager.commitPhaseOne(false);
    }

    /// Port of sqlite3BtreeCommitPhaseTwo(). Cursors must be closed. With
    /// `cleanup`, a failure to finalize the journal still ends the
    /// transaction (the caller committed by other means).
    pub fn commitPhaseTwo(bt: *Btree, cleanup: bool) Error!void {
        if (bt.in_trans == .none) return;
        if (bt.in_trans == .write) {
            bt.pager.commitPhaseTwo() catch |err| if (!cleanup) return err;
            bt.data_version_bias -%= 1;
            bt.has_content.clearRetainingCapacity();
        }
        bt.endTransaction();
    }

    pub fn commit(bt: *Btree) Error!void {
        try bt.commitPhaseOne();
        try bt.commitPhaseTwo(false);
    }

    /// Port of btreeEndTransaction().
    fn endTransaction(bt: *Btree) void {
        bt.do_truncate = false;
        if (bt.in_trans != .none and bt.n_vdbe_read != null and bt.n_vdbe_read.?.* > 1) {
            // Other statements of the connection may still be reading
            // the database: downgrade to a read transaction.
            bt.in_trans = .read;
        } else {
            bt.in_trans = .none;
            bt.unlockIfUnused();
        }
    }

    /// Port of sqlite3BtreeRollback(). With `trip` set, cursors are put in
    /// the fault state (only write cursors if `write_only`); otherwise
    /// their positions are saved so they survive the rollback. The
    /// transaction always ends, even if an error is returned.
    pub fn rollback(bt: *Btree, trip_arg: ?Error, write_only_arg: bool) Error!void {
        var first_err: ?Error = null;
        var trip = trip_arg;
        var write_only = write_only_arg;
        if (trip == null) {
            bt.saveAllCursors(0, null) catch |err| {
                first_err = err;
                trip = err;
                write_only = false;
            };
        }
        if (trip) |t| bt.tripAllCursors(t, write_only) catch |err| {
            first_err = first_err orelse err;
        };

        if (bt.in_trans == .write) {
            bt.pager.rollback() catch |err| {
                first_err = err;
            };
            // The rollback may have reloaded page 1.
            if (bt.getPage(1, .{})) |p1| {
                bt.setNPage(p1);
                bt.pager.unrefPageOne(p1.db_page);
            } else |_| {}
            bt.has_content.clearRetainingCapacity();
        }
        bt.endTransaction();
        if (first_err) |err| return err;
    }

    /// Port of btreeSetNPage().
    fn setNPage(bt: *Btree, p1: *MemPage) void {
        const n = header.get(p1.data, .database_size);
        bt.n_page = if (n == 0) bt.pager.pageCount() else n;
    }

    /// Port of sqlite3BtreeTripAllCursors(). With `write_only`, read
    /// cursors only save their positions; if that fails, every cursor is
    /// tripped with that error instead.
    pub fn tripAllCursors(bt: *Btree, err: Error, write_only: bool) Error!void {
        if (!write_only) return bt.tripEveryCursor(err);
        var it = bt.cursors;
        while (it) |c| : (it = c.next_cursor) {
            if (!c.flags.write) {
                if (c.state == .valid or c.state == .skipnext) {
                    c.savePosition() catch |e| {
                        bt.tripEveryCursor(e);
                        return e;
                    };
                }
            } else {
                c.trip(err);
            }
            c.releaseAllPages();
        }
    }

    /// tripAllCursors() for read and write cursors alike, which cannot
    /// fail.
    fn tripEveryCursor(bt: *Btree, err: Error) void {
        var it = bt.cursors;
        while (it) |c| : (it = c.next_cursor) {
            c.trip(err);
            c.releaseAllPages();
        }
    }

    // ============================================================ cursors

    /// Port of sqlite3BtreeCursor(). The cursor lives in caller memory and
    /// must stay at the same address until `Cursor.close`. A transaction
    /// must be open (a write transaction for write cursors). `key_info`
    /// non-null opens an index b-tree.
    pub fn cursor(bt: *Btree, cur: *Cursor, root_arg: Pgno, opts: Cursor.Options) Error!void {
        std.debug.assert(bt.in_trans != .none and bt.page1 != null);
        std.debug.assert(!opts.write or (bt.in_trans == .write and !bt.read_only));
        var root = root_arg;
        if (root <= 1) {
            if (root < 1) return error.Corrupt;
            // An empty database has no page 1 yet.
            if (bt.n_page == 0) root = 0;
        }
        if (opts.write) try bt.allocateTempSpace();

        cur.* = .{
            .bt = bt,
            .pgno_root = root,
            .key_info = opts.key_info,
            .flags = .{ .write = opts.write },
            .next_cursor = bt.cursors,
        };
        // All cursors on one b-tree must know there are others.
        var it = bt.cursors;
        while (it) |c| : (it = c.next_cursor) {
            if (c.pgno_root == root) {
                c.flags.multiple = true;
                cur.flags.multiple = true;
            }
        }
        bt.cursors = cur;
    }

    /// Port of saveAllCursors(): save the position of every cursor on the
    /// b-tree `root` (all b-trees if 0) except `except`, before modifying
    /// it.
    fn saveAllCursors(bt: *Btree, root: Pgno, except: ?*Cursor) Error!void {
        var it = bt.cursors;
        while (it) |c| : (it = c.next_cursor) {
            if (c != except and (root == 0 or c.pgno_root == root)) break;
        }
        const first = it orelse {
            if (except) |e| e.flags.multiple = false;
            return;
        };
        it = first;
        while (it) |c| : (it = c.next_cursor) {
            if (c == except or (root != 0 and c.pgno_root != root)) continue;
            if (c.state == .valid or c.state == .skipnext) {
                try c.savePosition();
            } else {
                c.releaseAllPages();
            }
        }
    }

    // ===================================================== page allocation

    /// How `allocatePage` uses its `nearby` argument (BTALLOC_*).
    const AllocMode = enum {
        /// Prefer a page close to `nearby`.
        any,
        /// Return `nearby` itself if it is on the freelist.
        exact,
        /// Return a page no larger than `nearby` if there is one.
        le,
    };

    /// Port of allocateBtreePage(): take a page from the freelist, or
    /// append one. The page is writable and referenced, its content
    /// undefined. Modes other than `any` are only for auto-vacuum.
    fn allocatePage(bt: *Btree, nearby: Pgno, mode: AllocMode) Error!*MemPage {
        std.debug.assert(mode == .any or (nearby > 0 and bt.isAutoVacuum()));
        const p1 = bt.page1.?;
        const mx_page = bt.n_page;
        const n_free = header.get(p1.data, .freelist_count);
        if (n_free >= mx_page) return error.Corrupt;
        if (n_free == 0) return bt.appendPage();

        // Searching walks every trunk until the wanted page turns up.
        const search_list = switch (mode) {
            .any => false,
            .le => true,
            .exact => nearby <= mx_page and (try ptrmap.get(bt, nearby)).e_type == .free_page,
        };

        try bt.pager.write(p1.db_page);
        header.put(p1.data, .freelist_count, n_free - 1);

        var trunk: ?*MemPage = null;
        var prev: ?*MemPage = null;
        defer {
            if (trunk) |t| releasePage(t);
            if (prev) |t| releasePage(t);
        }
        var n_search: u32 = 0;
        while (true) {
            if (prev) |pt| releasePage(pt);
            prev = trunk;
            trunk = null;
            const i_trunk = if (prev) |pt| get4(pt.data) else header.get(p1.data, .first_freelist_trunk);
            if (i_trunk > mx_page or n_search > n_free) return error.Corrupt;
            n_search += 1;
            trunk = try bt.getUnusedPage(i_trunk, .{});
            const t = trunk.?;
            const k = get4(t.data + 4);

            if (k == 0 and !search_list) {
                // A trunk without leaves: allocate the trunk itself.
                std.debug.assert(prev == null);
                try bt.pager.write(t.db_page);
                header.put(p1.data, .first_freelist_trunk, get4(t.data));
                trunk = null;
                return t;
            }
            if (k > bt.usable_size / 4 - 2) return error.Corrupt;

            if (search_list and (nearby == i_trunk or (i_trunk < nearby and mode == .le))) {
                // The trunk itself is the page wanted. Unlink it, promoting
                // its first leaf to trunk if it has leaves.
                try bt.pager.write(t.db_page);
                var next_trunk = t.data[0..4].*;
                if (k > 0) {
                    const i_new_trunk = get4(t.data + 8);
                    if (i_new_trunk > mx_page) return error.Corrupt;
                    const nt = try bt.getUnusedPage(i_new_trunk, .{});
                    defer releasePage(nt);
                    try bt.pager.write(nt.db_page);
                    nt.data[0..4].* = t.data[0..4].*;
                    put4(nt.data + 4, k - 1);
                    @memcpy(nt.data[8..][0 .. (k - 1) * 4], t.data[12..][0 .. (k - 1) * 4]);
                    put4(&next_trunk, i_new_trunk);
                }
                if (prev) |pt| {
                    try bt.pager.write(pt.db_page);
                    pt.data[0..4].* = next_trunk;
                } else {
                    header.put(p1.data, .first_freelist_trunk, get4(&next_trunk));
                }
                trunk = null;
                return t;
            }

            if (k > 0) {
                // Take a leaf: the first one no larger than `nearby` (le),
                // or the one closest to it.
                const a = t.data;
                var closest: u32 = 0;
                if (nearby > 0) {
                    if (mode == .le) {
                        for (0..k) |i| {
                            if (get4(a + 8 + i * 4) <= nearby) {
                                closest = @intCast(i);
                                break;
                            }
                        }
                    } else {
                        var dist = absInt32(get4(a + 8) -% nearby);
                        for (1..k) |i| {
                            const d2 = absInt32(get4(a + 8 + i * 4) -% nearby);
                            if (d2 < dist) {
                                closest = @intCast(i);
                                dist = d2;
                            }
                        }
                    }
                }
                const pgno = get4(a + 8 + closest * 4);
                if (pgno > mx_page or pgno < 2) return error.Corrupt;
                if (!search_list or pgno == nearby or (pgno < nearby and mode == .le)) {
                    try bt.pager.write(t.db_page);
                    if (closest < k - 1) a[8 + closest * 4 ..][0..4].* = a[4 + k * 4 ..][0..4].*;
                    put4(a + 4, k - 1);
                    // A page freed earlier in this transaction may still need
                    // its old content journaled; others can skip the read.
                    const no_content = !bt.has_content.contains(pgno);
                    const pg = try bt.getUnusedPage(pgno, .{ .no_content = no_content });
                    errdefer releasePage(pg);
                    try bt.pager.write(pg.db_page);
                    return pg;
                }
            }
            std.debug.assert(search_list);
        }
    }

    /// The append half of allocateBtreePage(): extend the database by one
    /// page (two if the next one must be a pointer-map page).
    fn appendPage(bt: *Btree) Error!*MemPage {
        const p1 = bt.page1.?;
        // After an incremental vacuum, pages between the image and the end
        // of the file may hold content a rollback needs: read (and journal)
        // them instead of assuming they are blank.
        const flags: pager_mod.GetFlags = .{ .no_content = !bt.do_truncate };
        try bt.pager.write(p1.db_page);
        bt.n_page += 1;
        if (bt.pager.isLockPage(bt.n_page)) bt.n_page += 1;
        if (bt.isAutoVacuum() and ptrmap.isPage(bt, bt.n_page)) {
            const map = try bt.getUnusedPage(bt.n_page, flags);
            defer releasePage(map);
            try bt.pager.write(map.db_page);
            bt.n_page += 1;
            if (bt.pager.isLockPage(bt.n_page)) bt.n_page += 1;
        }
        header.put(p1.data, .database_size, bt.n_page);
        const pg = try bt.getUnusedPage(bt.n_page, flags);
        errdefer releasePage(pg);
        try bt.pager.write(pg.db_page);
        return pg;
    }

    /// Port of freePage2(): put page `pgno` on the freelist. `mem` is the
    /// page if the caller has it; its reference count is not changed.
    fn freePage2(bt: *Btree, mem: ?*MemPage, pgno: Pgno) Error!void {
        const p1 = bt.page1.?;
        if (pgno < 2 or pgno > bt.n_page) return error.Corrupt;
        var pg: ?*MemPage = null;
        if (mem) |m| {
            pg = m;
            bt.pager.ref(m.db_page);
        } else {
            pg = bt.lookupPage(pgno);
        }
        var trunk: ?*MemPage = null;
        defer {
            if (pg) |x| {
                x.is_init = false;
                releasePage(x);
            }
            if (trunk) |t| releasePage(t);
        }

        try bt.pager.write(p1.db_page);
        const n_free = header.get(p1.data, .freelist_count);
        header.put(p1.data, .freelist_count, n_free + 1);

        if (bt.secure_delete == .on) {
            if (pg == null) pg = try bt.getPage(pgno, .{});
            try bt.pager.write(pg.?.db_page);
            @memset(pg.?.data[0..bt.page_size], 0);
        }
        if (bt.isAutoVacuum()) try ptrmap.put(bt, pgno, .free_page, 0);

        var i_trunk: Pgno = 0;
        if (n_free != 0) {
            i_trunk = header.get(p1.data, .first_freelist_trunk);
            if (i_trunk > bt.n_page) return error.Corrupt;
            trunk = try bt.getPage(i_trunk, .{});
            const t = trunk.?;
            const n_leaf = get4(t.data + 4);
            if (n_leaf > bt.usable_size / 4 - 2) return error.Corrupt;
            // Trunks hold at most usableSize/4-8 leaves: versions before
            // 3.6.0 reported fuller trunks as corrupt.
            if (n_leaf < bt.usable_size / 4 - 8) {
                try bt.pager.write(t.db_page);
                put4(t.data + 4, n_leaf + 1);
                put4(t.data + 8 + n_leaf * 4, pgno);
                if (pg) |x| if (bt.secure_delete != .on) bt.pager.dontWrite(x.db_page);
                try bt.has_content.put(bt.gpa, pgno, {});
                return;
            }
        }

        // The freelist is empty or its first trunk is full: the page becomes
        // the new first trunk.
        if (pg == null) pg = try bt.getPage(pgno, .{});
        const x = pg.?;
        try bt.pager.write(x.db_page);
        put4(x.data, i_trunk);
        put4(x.data + 4, 0);
        header.put(p1.data, .first_freelist_trunk, pgno);
    }

    fn freePage(bt: *Btree, pg: *MemPage) Error!void {
        return bt.freePage2(pg, pg.pgno);
    }

    /// Port of getOverflowPage(): the overflow page after `ovfl`, or 0.
    /// `page` is `ovfl` itself, referenced, unless `want_page` is false or
    /// the pointer map answered without reading it.
    fn getOverflowPage(bt: *Btree, ovfl: Pgno, want_page: bool) Error!struct { next: Pgno, page: ?*MemPage } {
        if (bt.isAutoVacuum()) {
            // Guess that the chain continues on the next page and check
            // the guess against the pointer map.
            var guess = ovfl + 1;
            while (ptrmap.isReserved(bt, guess)) guess += 1;
            if (guess <= bt.n_page) {
                const e = try ptrmap.get(bt, guess);
                if (e.e_type == .overflow2 and e.parent == ovfl) return .{ .next = guess, .page = null };
            }
        }
        const pg = try bt.getPage(ovfl, .{});
        const next = get4(pg.data);
        if (want_page) return .{ .next = next, .page = pg };
        releasePage(pg);
        return .{ .next = next, .page = null };
    }

    /// Port of clearCellOverflow(): free the overflow chain of a cell.
    fn clearCellOverflow(bt: *Btree, pg: *MemPage, cell: [*]u8, info: CellInfo) Error!void {
        if (@intFromPtr(cell) + info.n_size > @intFromPtr(pg.data_end)) return error.Corrupt;
        var ovfl = get4(cell + info.n_size - 4);
        const ovfl_size = bt.usable_size - 4;
        var n_ovfl = (info.n_payload - info.n_local + ovfl_size - 1) / ovfl_size;
        while (n_ovfl > 0) : (n_ovfl -= 1) {
            if (ovfl < 2 or ovfl > bt.n_page) return error.Corrupt;
            var next: Pgno = 0;
            var op: ?*MemPage = null;
            if (n_ovfl > 1) {
                const r = try bt.getOverflowPage(ovfl, true);
                next = r.next;
                op = r.page;
            }
            if (op == null) op = bt.lookupPage(ovfl);
            defer if (op) |o| bt.pager.unref(o.db_page);
            // No cursor should be using an overflow page of a cell being
            // deleted. More references mean it is not an overflow page.
            if (op) |o| if (o.db_page.n_ref != 1) return error.Corrupt;
            try bt.freePage2(op, ovfl);
            ovfl = next;
        }
    }

    /// BTREE_CLEAR_CELL: parse a cell and free its overflow chain.
    fn clearCell(bt: *Btree, pg: *MemPage, cell: [*]u8) Error!CellInfo {
        const info = pg.parseCell(cell);
        if (info.n_local != info.n_payload) try bt.clearCellOverflow(pg, cell, info);
        return info;
    }

    /// Port of fillInCell(): build the cell for `x` in `cell`, allocating
    /// and filling overflow pages as needed. Returns the cell size.
    fn fillInCell(bt: *Btree, pg: *MemPage, cell: [*]u8, x: Payload) Error!u32 {
        var n_header: u32 = pg.child_ptr_size;
        var n_payload: u32 = undefined;
        var src: []const u8 = undefined;
        if (pg.int_key) {
            std.debug.assert(pg.int_key_leaf);
            n_payload = @intCast(x.data.len + x.n_zero);
            src = x.data;
            n_header += varint.put(cell[n_header..][0..9], n_payload);
            n_header += varint.put(cell[n_header..][0..9], @bitCast(x.rowid));
        } else {
            src = x.key.?;
            n_payload = @intCast(src.len);
            n_header += varint.put(cell[n_header..][0..9], n_payload);
        }

        var payload = cell + n_header;
        if (n_payload <= pg.max_local) {
            // The common case: everything fits on the page.
            var n = n_header + n_payload;
            if (n < 4) {
                n = 4;
                payload[n_payload] = 0;
            }
            @memcpy(payload[0..src.len], src);
            @memset(payload[src.len..n_payload], 0);
            return n;
        }

        const local = pg.payloadToLocal(n_payload);
        var space_left: u32 = local;
        const size = local + n_header + 4;
        var prior = cell + n_header + local;
        var pgno_ovfl: Pgno = 0;
        var to_release: ?*MemPage = null;
        defer if (to_release) |r| releasePage(r);

        var remaining = n_payload;
        while (true) {
            var n = @min(remaining, space_left);
            if (src.len >= n) {
                @memcpy(payload[0..n], src[0..n]);
            } else if (src.len > 0) {
                n = @intCast(src.len);
                @memcpy(payload[0..n], src);
            } else {
                @memset(payload[0..n], 0);
            }
            remaining -= n;
            if (remaining == 0) break;
            payload += n;
            src = src[@min(n, src.len)..];
            space_left -= n;
            if (space_left == 0) {
                // The pointer-map entry of the previous page in the chain.
                const pgno_ptrmap = pgno_ovfl;
                if (bt.isAutoVacuum()) {
                    pgno_ovfl += 1;
                    while (ptrmap.isReserved(bt, pgno_ovfl)) pgno_ovfl += 1;
                }
                const ovfl = try bt.allocatePage(pgno_ovfl, .any);
                if (bt.isAutoVacuum()) {
                    // Even the first page gets an entry now (completed when
                    // the cell is inserted), or getOverflowPage() could
                    // misread a stale one while freeing the chain.
                    const e_type: ptrmap.Type = if (pgno_ptrmap != 0) .overflow2 else .overflow1;
                    ptrmap.put(bt, ovfl.pgno, e_type, pgno_ptrmap) catch |err| {
                        releasePage(ovfl);
                        return err;
                    };
                }
                put4(prior, ovfl.pgno);
                if (to_release) |r| releasePage(r);
                to_release = ovfl;
                pgno_ovfl = ovfl.pgno;
                prior = ovfl.data;
                put4(prior, 0);
                payload = ovfl.data + 4;
                space_left = bt.usable_size - 4;
            }
        }
        return size;
    }

    // ========================================================= balancing

    /// Port of balance_quick(): `pg` is the rightmost leaf of a table and
    /// overflows with one cell at its end, as when appending rows. Put that
    /// cell alone on a new right sibling instead of redistributing.
    fn balanceQuick(bt: *Btree, parent: *MemPage, pg: *MemPage, space: *[13]u8) Error!void {
        std.debug.assert(pg.n_overflow == 1);
        if (pg.n_cell == 0) return error.Corrupt;
        const new = try bt.allocatePage(0, .any);
        defer releasePage(new);

        var cells = [1][*]u8{pg.ap_ovfl[0]};
        var sizes = [1]u16{pg.cellSize(pg.ap_ovfl[0])};
        new.zero(page.table_leaf);
        var b: CellArray = .{ .n_cell = 1, .ref = pg, .cells = &cells, .sizes = &sizes };
        b.ap_end[0] = pg.data_end;
        b.ix_nx[0] = 2;
        try rebuildPage(&b, 0, 1, new);
        new.n_free = @intCast(bt.usable_size - new.cell_offset - 2 - sizes[0]);
        if (bt.isAutoVacuum()) {
            try ptrmap.put(bt, new.pgno, .btree_page, parent.pgno);
            if (sizes[0] > new.min_local) try ptrmap.putOvflPtr(new, new, cells[0]);
        }

        // The divider is the largest rowid on `pg`: skip the payload size
        // of its last cell and copy the rowid varint.
        var cell = pg.findCell(pg.n_cell - 1);
        var stop = cell + 9;
        while (true) {
            const byte = cell[0];
            cell += 1;
            if (byte & 0x80 == 0 or @intFromPtr(cell) >= @intFromPtr(stop)) break;
        }
        stop = cell + 9;
        var out: u32 = 4;
        while (true) {
            const byte = cell[0];
            space[out] = byte;
            out += 1;
            cell += 1;
            if (byte & 0x80 == 0 or @intFromPtr(cell) >= @intFromPtr(stop)) break;
        }
        const r = parent.insertCell(parent.n_cell, space, out, null, pg.pgno);
        put4(parent.data + parent.hdr_offset + 8, new.pgno);
        return r;
    }

    /// Port of balance_deeper(): the root overflows. Move its content to a
    /// new child and leave the root empty with that child on the right.
    /// Returns the child, referenced.
    fn balanceDeeper(bt: *Btree, root: *MemPage) Error!*MemPage {
        std.debug.assert(root.n_overflow > 0);
        try bt.pager.write(root.db_page);
        const child = try bt.allocatePage(root.pgno, .any);
        errdefer releasePage(child);
        try copyNodeContent(root, child);
        if (bt.isAutoVacuum()) try ptrmap.put(bt, child.pgno, .btree_page, root.pgno);

        const n = root.n_overflow;
        @memcpy(child.ai_ovfl[0..n], root.ai_ovfl[0..n]);
        @memcpy(child.ap_ovfl[0..n], root.ap_ovfl[0..n]);
        child.n_overflow = n;

        root.zero(child.data[0] & ~page.ptf_leaf);
        put4(root.data + root.hdr_offset + 8, child.pgno);
        return child;
    }

    /// Port of balance_nonroot(): redistribute the cells of child
    /// `i_parent_idx` of `parent` and up to two siblings so that all are
    /// about equally full, adding or removing siblings as needed. The
    /// parent may end up over- or underfull; the caller balances it next.
    /// `ovfl_space` (page-sized) holds divider cells that overflow the
    /// parent and must live until the parent is balanced. On error the
    /// database may be inconsistent and must be rolled back.
    fn balanceNonroot(
        bt: *Btree,
        parent: *MemPage,
        i_parent_idx: u32,
        ovfl_space: []u8,
        is_root: bool,
        bulk: bool,
    ) Error!void {
        const usable = bt.usable_size;
        var ap_old: [nb]?*MemPage = @splat(null);
        var ap_new: [nb + 2]?*MemPage = @splat(null);
        var ap_div: [nb - 1][*]u8 = undefined;
        // Index in b.cells of the first cell right of the i-th new page.
        var cnt_new: [nb + 2]i32 = undefined;
        var cnt_old: [nb + 2]i32 = undefined;
        var sz_new: [nb + 2]i32 = undefined;
        var ab_done: [nb + 2]bool = @splat(false);
        var b: CellArray = .{ .ref = undefined, .cells = &.{}, .sizes = &.{} };
        var space1: []u8 = undefined;
        var scratch: []align(@alignOf([*]u8)) u8 = &.{};
        defer {
            bt.gpa.free(scratch);
            for (ap_old) |o| if (o) |x| releasePage(x);
            for (ap_new) |o| if (o) |x| releasePage(x);
        }
        std.debug.assert(parent.n_overflow == 0 or (parent.n_overflow == 1 and parent.ai_ovfl[0] == i_parent_idx));
        std.debug.assert(parent.n_free >= 0);

        // Choose the siblings: NN on each side of the page if possible,
        // more from one side at the edges, all children if there are at
        // most NB. Their divider cells are dropped from the parent now so
        // that the parent has no overflow cells left.
        var i: u32 = parent.n_overflow + parent.n_cell;
        var nx_div: u32 = 0;
        if (i >= 2) {
            const bulk_n: u32 = @intFromBool(bulk);
            if (i_parent_idx == 0) {
                nx_div = 0;
            } else if (i_parent_idx == i) {
                nx_div = i - 2 + bulk_n;
            } else {
                nx_div = i_parent_idx - 1;
            }
            i = 2 - bulk_n;
        }
        const n_old = i + 1;
        const right: [*]u8 = if (i + nx_div - parent.n_overflow == parent.n_cell)
            parent.data + parent.hdr_offset + 8
        else
            parent.findCell(i + nx_div - parent.n_overflow);
        var pgno = get4(right);
        var n_max_cells: u32 = 0;
        while (true) {
            const old = try bt.getAndInitPage(pgno);
            ap_old[i] = old;
            if (old.n_free < 0) try old.computeFreeSpace();
            n_max_cells += old.n_cell + @as(u32, old.ap_ovfl.len);
            if (i == 0) break;
            i -= 1;

            if (parent.n_overflow != 0 and i + nx_div == parent.ai_ovfl[0]) {
                ap_div[i] = parent.ap_ovfl[0];
                pgno = get4(ap_div[i]);
                sz_new[i] = parent.cellSize(ap_div[i]);
                parent.n_overflow = 0;
            } else {
                ap_div[i] = parent.findCell(i + nx_div - parent.n_overflow);
                pgno = get4(ap_div[i]);
                const sz: u32 = parent.cellSize(ap_div[i]);
                sz_new[i] = @intCast(sz);
                // Dropping a cell overwrites only its first 4 bytes, which
                // are not needed. Secure delete zeroes it all, so keep a
                // copy in ovfl_space until aSpace1 exists.
                if (bt.secure_delete != .off) {
                    const off = parent.offsetOf(ap_div[i]);
                    if (off + sz <= usable) {
                        @memcpy(ovfl_space[off..][0..sz], ap_div[i][0..sz]);
                        ap_div[i] = ovfl_space.ptr + off;
                    }
                }
                try parent.dropCell(i + nx_div - parent.n_overflow, sz);
            }
        }

        // Multiple of 4 to keep the original 8-byte alignment reasoning.
        n_max_cells = (n_max_cells + 3) & ~@as(u32, 3);
        // One allocation holds the cell pointers, their sizes and aSpace1.
        const ptrs_len = n_max_cells * @sizeOf([*]u8);
        const sizes_len = n_max_cells * @sizeOf(u16);
        scratch = try bt.gpa.alignedAlloc(u8, .of([*]u8), ptrs_len + sizes_len + bt.page_size);
        b.cells = @as([*][*]u8, @ptrCast(scratch.ptr))[0..n_max_cells];
        b.sizes = @as([*]u16, @ptrCast(@alignCast(scratch.ptr + ptrs_len)))[0..n_max_cells];
        space1 = scratch[ptrs_len + sizes_len ..];

        // Gather pointers to every cell of the siblings and copies of the
        // dividers (from space1). On leaves the dividers lose their child
        // pointer, on interior pages they take the left sibling's right
        // pointer, so all cells in b look alike.
        b.ref = ap_old[0].?;
        const leaf_correction: u16 = if (b.ref.leaf) 4 else 0;
        const leaf_data = b.ref.int_key_leaf;
        var i_space1: u32 = 0;
        for (0..n_old) |ii| {
            const old = ap_old[ii].?;
            const data = old.data;
            const mask = old.mask_page;
            var pi_cell = data + old.cell_offset;
            // All siblings must be the same kind of page.
            if (old.data[0] != b.ref.data[0]) return error.Corrupt;

            @memset(b.sizes[b.n_cell..][0 .. old.n_cell + old.n_overflow], 0);
            if (old.n_overflow > 0) {
                if (old.n_cell < old.ai_ovfl[0]) return error.Corrupt;
                for (0..old.ai_ovfl[0]) |_| {
                    b.cells[b.n_cell] = data + (mask & get2(pi_cell));
                    pi_cell += 2;
                    b.n_cell += 1;
                }
                // Multiple overflow cells are always adjacent.
                for (old.ap_ovfl[0..old.n_overflow]) |c| {
                    b.cells[b.n_cell] = c;
                    b.n_cell += 1;
                }
            }
            // The cell pointers, with the count and array in locals (a
            // store through b.cells may alias b.n_cell).
            const pi_end = data + old.cell_offset + 2 * @as(u32, old.n_cell);
            const cells = b.cells.ptr;
            var n_cell = b.n_cell;
            while (@intFromPtr(pi_cell) < @intFromPtr(pi_end)) {
                cells[n_cell] = data + (mask & get2(pi_cell));
                pi_cell += 2;
                n_cell += 1;
            }
            b.n_cell = n_cell;

            cnt_old[ii] = @intCast(b.n_cell);
            if (ii < n_old - 1 and !leaf_data) {
                const sz: u16 = @intCast(sz_new[ii]);
                const temp = space1.ptr + i_space1;
                i_space1 += sz;
                if (i_space1 > bt.page_size) return error.Corrupt;
                @memcpy(temp[0..sz], ap_div[ii][0..sz]);
                b.cells[b.n_cell] = temp + leaf_correction;
                b.sizes[b.n_cell] = sz - leaf_correction;
                if (!old.leaf) {
                    // The right pointer of `old` becomes the left pointer of
                    // the divider.
                    b.cells[b.n_cell][0..4].* = old.data[8..12].*;
                } else {
                    // No cell may be smaller than 4 bytes; pad with zeros.
                    while (b.sizes[b.n_cell] < 4) {
                        space1[i_space1] = 0;
                        i_space1 += 1;
                        b.sizes[b.n_cell] += 1;
                    }
                }
                b.n_cell += 1;
            }
        }
        const n_cell_total: i32 = @intCast(b.n_cell);

        // Work out how many pages the cells need (k), the bytes used on
        // each (sz_new) and where each page ends (cnt_new). This first
        // packing fills pages from the left.
        const usable_space: i32 = @intCast(usable - 12 + leaf_correction);
        var k: usize = 0;
        for (0..n_old) |ii| {
            const p = ap_old[ii].?;
            b.ap_end[k] = p.data_end;
            b.ix_nx[k] = @intCast(cnt_old[ii]);
            // Skip entries for siblings without cells.
            if (k > 0 and b.ix_nx[k] == b.ix_nx[k - 1]) k -= 1;
            if (!leaf_data) {
                k += 1;
                b.ap_end[k] = parent.data_end;
                b.ix_nx[k] = @intCast(cnt_old[ii] + 1);
            }
            sz_new[ii] = usable_space - p.n_free;
            for (p.ap_ovfl[0..p.n_overflow]) |c| sz_new[ii] += 2 + @as(i32, p.cellSize(c));
            cnt_new[ii] = cnt_old[ii];
            k += 1;
        }
        k = n_old;
        var ii: usize = 0;
        while (ii < k) : (ii += 1) {
            while (sz_new[ii] > usable_space) {
                if (ii + 1 >= k) {
                    k = ii + 2;
                    if (k > nb + 2) return error.Corrupt;
                    sz_new[k - 1] = 0;
                    cnt_new[k - 1] = n_cell_total;
                }
                if (cnt_new[ii] < 1) return error.Corrupt;
                var sz: i32 = 2 + @as(i32, b.cellSizeAt(cnt_new[ii] - 1));
                sz_new[ii] -= sz;
                if (!leaf_data) {
                    sz = if (cnt_new[ii] < n_cell_total) 2 + @as(i32, b.cellSizeAt(cnt_new[ii])) else 0;
                }
                sz_new[ii + 1] += sz;
                cnt_new[ii] -= 1;
            }
            while (cnt_new[ii] < n_cell_total) {
                var sz: i32 = 2 + @as(i32, b.cellSizeAt(cnt_new[ii]));
                if (sz_new[ii] + sz > usable_space) break;
                sz_new[ii] += sz;
                cnt_new[ii] += 1;
                if (!leaf_data) {
                    sz = if (cnt_new[ii] < n_cell_total) 2 + @as(i32, b.cellSizeAt(cnt_new[ii])) else 0;
                }
                sz_new[ii + 1] -= sz;
            }
            if (cnt_new[ii] >= n_cell_total) {
                k = ii + 1;
            } else if (cnt_new[ii] <= (if (ii > 0) cnt_new[ii - 1] else 0)) {
                return error.Corrupt;
            }
        }

        // The packing above leaves the rightmost page nearly empty, maybe
        // completely. Shift cells right to even it out; this is required,
        // not just an optimization.
        ii = k - 1;
        while (ii > 0) : (ii -= 1) {
            var sz_right = sz_new[ii];
            var sz_left = sz_new[ii - 1];
            var r = cnt_new[ii - 1] - 1;
            var d = r + 1 - @intFromBool(leaf_data);
            while (true) {
                const sz_r: i32 = b.cellSizeAt(r);
                const sz_d: i32 = b.cellSizeAt(d);
                if (sz_right != 0 and
                    (bulk or sz_right + sz_d + 2 > sz_left - (sz_r + @as(i32, if (ii == k - 1) 0 else 2))))
                    break;
                sz_right += sz_d + 2;
                sz_left -= sz_r + 2;
                cnt_new[ii - 1] = r;
                r -= 1;
                d -= 1;
                if (r < 0) break;
            }
            sz_new[ii] = sz_right;
            sz_new[ii - 1] = sz_left;
            if (cnt_new[ii - 1] <= (if (ii > 1) cnt_new[ii - 2] else 0)) return error.Corrupt;
        }

        // Reuse the old pages, allocating more if needed.
        const page_flags = ap_old[0].?.data[0];
        var n_new: usize = 0;
        for (0..k) |j| {
            if (j < n_old) {
                const new = ap_old[j].?;
                ap_new[j] = new;
                ap_old[j] = null;
                n_new += 1;
                try bt.pager.write(new.db_page);
                // Only the cursor (for the page being balanced) may hold
                // another reference.
                const expected = @as(u32, 1) + @intFromBool(@as(i64, @intCast(j)) == @as(i64, i_parent_idx) - nx_div);
                if (new.db_page.n_ref != expected) return error.Corrupt;
            } else {
                const new = try bt.allocatePage(if (bulk) 1 else pgno, .any);
                pgno = new.pgno;
                new.zero(page_flags);
                ap_new[j] = new;
                n_new += 1;
                cnt_old[j] = n_cell_total;
                if (bt.isAutoVacuum()) try ptrmap.put(bt, new.pgno, .btree_page, parent.pgno);
            }
        }

        // Page numbers before the swap below.
        var a_pgno: [nb + 2]Pgno = undefined;
        for (0..n_new) |j| a_pgno[j] = ap_new[j].?.pgno;

        // Swap page numbers so the new pages are in ascending order, which
        // keeps table scans close to sequential I/O. N is at most 5.
        for (0..n_new - 1) |j| {
            var ib = j;
            for (j + 1..n_new) |m| {
                if (ap_new[m].?.pgno < ap_new[ib].?.pgno) ib = m;
            }
            if (ib != j) {
                const pa = ap_new[j].?;
                const pb = ap_new[ib].?;
                bt.pager.swapPageNumbers(pa.db_page, pb.db_page);
                std.mem.swap(Pgno, &pa.pgno, &pb.pgno);
            }
        }

        put4(right, ap_new[n_new - 1].?.pgno);
        // The rightmost new sibling inherits the right child of the
        // rightmost old one.
        if (page_flags & page.ptf_leaf == 0 and n_old != n_new) {
            const old = if (n_new > n_old) ap_new[n_old - 1].? else ap_old[n_old - 1].?;
            ap_new[n_new - 1].?.data[8..12].* = old.data[8..12].*;
        }

        // Pointer-map entries for cells changing pages: their child (on
        // interior pages) and the start of their overflow chain. Dividers
        // inserted into the parent are handled by insertCell, the right
        // children of the siblings after the siblings are filled.
        if (bt.isAutoVacuum()) {
            var old = ap_new[0].?;
            var new = old;
            var cnt_old_next: u32 = @as(u32, new.n_cell) + new.n_overflow;
            var i_new: usize = 0;
            var i_old: usize = 0;
            for (0..b.n_cell) |ci| {
                const cell = b.cells[ci];
                while (ci == cnt_old_next) {
                    i_old += 1;
                    std.debug.assert(i_old < n_new or i_old < n_old);
                    old = if (i_old < n_new) ap_new[i_old].? else ap_old[i_old].?;
                    cnt_old_next += @as(u32, old.n_cell) + old.n_overflow + @intFromBool(!leaf_data);
                }
                if (ci == @as(usize, @intCast(cnt_new[i_new]))) {
                    i_new += 1;
                    new = ap_new[i_new].?;
                    if (!leaf_data) continue;
                }
                // A cell that stays on the same page needs no update; a
                // divider or overflow cell always does.
                if (i_old >= n_new or new.pgno != a_pgno[i_old] or !within(cell, old.data, old.data_end)) {
                    if (leaf_correction == 0) try ptrmap.put(bt, get4(cell), .btree_page, new.pgno);
                    if (b.cellSizeAt(@intCast(ci)) > new.min_local) try ptrmap.putOvflPtr(new, old, cell);
                }
            }
        }

        // Insert the new dividers into the parent.
        var i_ovfl_space: u32 = 0;
        for (0..n_new - 1) |j| {
            const new = ap_new[j].?;
            var cj: u32 = @intCast(cnt_new[j]);
            var cell = b.cells[cj];
            var sz: u32 = b.sizes[cj] + leaf_correction;
            var temp: ?[*]u8 = ovfl_space.ptr + i_ovfl_space;
            if (!new.leaf) {
                new.data[8..12].* = cell[0..4].*;
            } else if (leaf_data) {
                // Table leaves have no divider cells; the divider is the
                // largest rowid of the left sibling.
                cj -= 1;
                const info = new.parseCell(b.cells[cj]);
                cell = temp.?;
                sz = 4 + @as(u32, varint.put(cell[4..][0..9], @bitCast(info.n_key)));
                temp = null;
            } else {
                cell -= 4;
                // A leaf cell reported as 4 bytes may really be shorter
                // (the minimum size); reparse it for the exact size.
                if (b.sizes[cj] == 4) sz = parent.cellSize(cell);
            }
            i_ovfl_space += sz;
            if (straddles(b.ap_end[b.endIndex(cj)], cell, cell + sz)) return error.Corrupt;
            try parent.insertCell(nx_div + j, cell, sz, temp, new.pgno);
        }

        // Rewrite the siblings without clobbering cells still to be read:
        // when cells move left, page i only after page i-1; when they move
        // right, only after page i+1. A downward pass then an upward pass
        // covers every page once.
        var signed_i: i32 = 1 - @as(i32, @intCast(n_new));
        while (signed_i < @as(i32, @intCast(n_new))) : (signed_i += 1) {
            const i_pg: usize = @abs(signed_i);
            if (ab_done[i_pg]) continue;
            if (signed_i >= 0 or cnt_old[i_pg - 1] >= cnt_new[i_pg - 1]) {
                var i_new: u32 = 0;
                var i_old: u32 = 0;
                var n_new_cell: u32 = @intCast(cnt_new[0]);
                if (i_pg > 0) {
                    const shift = @intFromBool(!leaf_data);
                    i_old = if (i_pg < n_old) @intCast(cnt_old[i_pg - 1] + shift) else b.n_cell;
                    i_new = @intCast(cnt_new[i_pg - 1] + shift);
                    n_new_cell = @intCast(cnt_new[i_pg] - @as(i32, @intCast(i_new)));
                }
                try editPage(ap_new[i_pg].?, i_old, i_new, n_new_cell, &b);
                ab_done[i_pg] = true;
                ap_new[i_pg].?.n_free = usable_space - sz_new[i_pg];
            }
        }

        if (is_root and parent.n_cell == 0 and parent.hdr_offset <= ap_new[0].?.n_free) {
            // The root lost its last divider: copy the only child into it,
            // making the tree one level shallower (balance-shallower). The
            // child must be defragmented first because page 1 is smaller.
            const child = ap_new[0].?;
            try child.defragment(-1);
            try copyNodeContent(child, parent);
            try bt.freePage(child);
        } else if (bt.isAutoVacuum() and leaf_correction == 0) {
            // The right children of the siblings.
            for (ap_new[0..n_new]) |new| try ptrmap.put(bt, get4(new.?.data + 8), .btree_page, new.?.pgno);
        }

        // Free old pages that were not reused.
        if (n_new < n_old) {
            for (n_new..n_old) |j| try bt.freePage(ap_old[j].?);
        }
    }

    // ========================================================= auto-vacuum

    /// Port of invalidateAllOverflowCache(): pages are about to move, so
    /// cached overflow page numbers may go stale.
    fn invalidateAllOverflowCache(bt: *Btree) void {
        var it = bt.cursors;
        while (it) |c| : (it = c.next_cursor) c.flags.valid_ovfl = false;
    }

    /// Port of relocatePage(): move `pg` (whose pointer-map entry is
    /// `e_type`/`ptr_page`) to the unused location `free_pgno`, fixing the
    /// pointer to it and the pointer-map entries of the pages it points
    /// to. `pg` stays referenced. See `Pager.movePage` for `is_commit`.
    fn relocatePage(bt: *Btree, pg: *MemPage, e_type: ptrmap.Type, ptr_page: Pgno, free_pgno: Pgno, is_commit: bool) Error!void {
        std.debug.assert(e_type != .free_page);
        const old_pgno = pg.pgno;
        if (old_pgno < 3) return error.Corrupt;

        try bt.pager.movePage(pg.db_page, free_pgno, is_commit);
        pg.pgno = free_pgno;

        if (e_type == .btree_page or e_type == .root_page) {
            try setChildPtrmaps(pg);
        } else {
            const next_ovfl = get4(pg.data);
            if (next_ovfl != 0) try ptrmap.put(bt, next_ovfl, .overflow2, free_pgno);
        }

        if (e_type != .root_page) {
            const ptr_pg = try bt.getPage(ptr_page, .{});
            defer releasePage(ptr_pg);
            try bt.pager.write(ptr_pg.db_page);
            try modifyPagePointer(ptr_pg, old_pgno, free_pgno, e_type);
            try ptrmap.put(bt, free_pgno, e_type, ptr_page);
        }
    }

    /// Port of incrVacuumStep(): make `last_pg` unused, moving its content
    /// to a free page if it has any. `n_fin` is the size the database will
    /// have when vacuuming is done. With `at_commit` the caller keeps calling
    /// until the file is `n_fin` pages and then drops the whole freelist;
    /// otherwise each call also shrinks `n_page`. Returns false when there
    /// is nothing left to do.
    fn incrVacuumStep(bt: *Btree, n_fin: Pgno, last_pg_arg: Pgno, at_commit: bool) Error!bool {
        std.debug.assert(last_pg_arg > n_fin);
        var last_pg = last_pg_arg;
        if (!ptrmap.isReserved(bt, last_pg)) {
            if (header.get(bt.page1.?.data, .freelist_count) == 0) return false;
            const e = try ptrmap.get(bt, last_pg);
            if (e.e_type == .root_page) return error.Corrupt;

            if (e.e_type == .free_page) {
                // Take it off the freelist. Unneeded at commit: the whole
                // freelist is dropped afterwards.
                if (!at_commit) {
                    const free_pg = try bt.allocatePage(last_pg, .exact);
                    std.debug.assert(free_pg.pgno == last_pg);
                    releasePage(free_pg);
                }
            } else {
                const last = try bt.getPage(last_pg, .{});
                defer releasePage(last);
                // Without `at_commit`, swap with the first free page at or
                // below `n_fin`; with it, keep allocating until one lands
                // within the final size.
                const mode: AllocMode = if (at_commit) .any else .le;
                const near: Pgno = if (at_commit) 0 else n_fin;
                var free_pgno: Pgno = undefined;
                while (true) {
                    const db_size = bt.n_page;
                    const free_pg = try bt.allocatePage(near, mode);
                    free_pgno = free_pg.pgno;
                    releasePage(free_pg);
                    if (free_pgno > db_size) return error.Corrupt;
                    if (!at_commit or free_pgno <= n_fin) break;
                }
                std.debug.assert(free_pgno < last_pg);
                try bt.relocatePage(last, e.e_type, e.parent, free_pgno, at_commit);
            }
        }

        if (!at_commit) {
            last_pg -= 1;
            while (ptrmap.isReserved(bt, last_pg)) last_pg -= 1;
            bt.do_truncate = true;
            bt.n_page = last_pg;
        }
        return true;
    }

    /// Port of finalDbSize(): the size of a database of `n_orig` pages
    /// after vacuuming away `n_free` free pages, along with the
    /// pointer-map pages no longer needed.
    fn finalDbSize(bt: *Btree, n_orig: Pgno, n_free: Pgno) Pgno {
        const n_entry = bt.usable_size / 5;
        const n_ptrmap = (n_free -% n_orig +% ptrmap.pageno(bt, n_orig) +% n_entry) / n_entry;
        var n_fin = n_orig -% n_free -% n_ptrmap;
        const lck = bt.pager.lockPage();
        if (n_orig > lck and n_fin < lck) n_fin -%= 1;
        while (ptrmap.isReserved(bt, n_fin)) n_fin -%= 1;
        return n_fin;
    }

    /// Port of sqlite3BtreeIncrVacuum(): one step of PRAGMA
    /// incremental_vacuum, freeing the last page of the file. Returns
    /// false when there is nothing (left) to free. Requires a write
    /// transaction.
    pub fn incrVacuum(bt: *Btree) Error!bool {
        std.debug.assert(bt.in_trans == .write);
        if (!bt.isAutoVacuum()) return false;
        const p1 = bt.page1.?;
        const n_orig = bt.n_page;
        const n_free = header.get(p1.data, .freelist_count);
        const n_fin = bt.finalDbSize(n_orig, n_free);
        if (n_orig < n_fin or n_free >= n_orig) return error.Corrupt;
        if (n_free == 0) return false;
        try bt.saveAllCursors(0, null);
        bt.invalidateAllOverflowCache();
        if (!try bt.incrVacuumStep(n_fin, n_orig, false)) return false;
        try bt.pager.write(p1.db_page);
        header.put(p1.data, .database_size, bt.n_page);
        return true;
    }

    /// Port of autoVacuumCommit(): in full auto-vacuum mode, move pages
    /// down into free slots so the file can be truncated to drop every
    /// free page. Rolls the pager back on failure.
    fn autoVacuumCommit(bt: *Btree) Error!void {
        bt.invalidateAllOverflowCache();
        if (bt.auto_vacuum == .incremental) return;
        const p1 = bt.page1.?;
        const n_orig = bt.n_page;
        // No database ends on a pointer-map page or the lock page.
        if (ptrmap.isReserved(bt, n_orig)) return error.Corrupt;
        const n_free = header.get(p1.data, .freelist_count);
        const n_fin = bt.finalDbSize(n_orig, n_free);
        if (n_fin > n_orig) return error.Corrupt;

        errdefer bt.pager.rollback() catch {};
        if (n_fin < n_orig) try bt.saveAllCursors(0, null);
        var i_free = n_orig;
        while (i_free > n_fin) : (i_free -= 1) {
            if (!try bt.incrVacuumStep(n_fin, i_free, true)) break;
        }
        if (n_free > 0) {
            try bt.pager.write(p1.db_page);
            header.put(p1.data, .first_freelist_trunk, 0);
            header.put(p1.data, .freelist_count, 0);
            header.put(p1.data, .database_size, n_fin);
            bt.do_truncate = true;
            bt.n_page = n_fin;
        }
    }

    // ============================================================= tables

    /// Port of sqlite3BtreeCreateTable(): a new empty b-tree. Returns its
    /// root page.
    pub fn createTable(bt: *Btree, kind: TableKind) Error!Pgno {
        std.debug.assert(bt.in_trans == .write and !bt.read_only);
        const root = if (bt.isAutoVacuum()) try bt.allocateRootPage() else try bt.allocatePage(1, .any);
        defer releasePage(root);
        root.zero(if (kind == .intkey) page.table_leaf else page.index_leaf);
        return root.pgno;
    }

    /// The auto-vacuum half of btreeCreateTable(). Root pages sit right
    /// after page 1 (vacuuming never moves them), so the new root goes
    /// after the largest one so far, moving any page already there.
    /// Returns the root, writable and referenced.
    fn allocateRootPage(bt: *Btree) Error!*MemPage {
        // The page moved may be an overflow page.
        bt.invalidateAllOverflowCache();
        var pgno_root = bt.getMeta(.largest_root_page);
        if (pgno_root > bt.n_page) return error.Corrupt;
        pgno_root += 1;
        while (ptrmap.isReserved(bt, pgno_root)) pgno_root += 1;
        std.debug.assert(pgno_root >= 3);

        const move = try bt.allocatePage(pgno_root, .exact);
        var root = move;
        if (move.pgno != pgno_root) {
            // Got another page: move what is at pgno_root there.
            const pgno_move = move.pgno;
            const saved = bt.saveAllCursors(0, null);
            releasePage(move);
            try saved;

            root = try bt.getPage(pgno_root, .{});
            {
                errdefer releasePage(root);
                const e = try ptrmap.get(bt, pgno_root);
                if (e.e_type == .root_page or e.e_type == .free_page) return error.Corrupt;
                try bt.relocatePage(root, e.e_type, e.parent, pgno_move, false);
            }
            releasePage(root);
            root = try bt.getPage(pgno_root, .{});
        }
        errdefer releasePage(root);
        try bt.pager.write(root.db_page);
        try ptrmap.put(bt, pgno_root, .root_page, 0);
        try bt.updateMeta(.largest_root_page, pgno_root);
        return root;
    }

    /// Port of clearDatabasePage(): free every page below `pgno` and, if
    /// `free_self`, `pgno` itself; otherwise leave it an empty leaf.
    /// Counts the entries removed into `changes`.
    fn clearDatabasePage(bt: *Btree, pgno: Pgno, free_self: bool, depth: u32, changes_arg: ?*i64) Error!void {
        var changes = changes_arg;
        if (pgno > bt.n_page) return error.Corrupt;
        // Guard against cycles in a corrupt file.
        if (depth > max_depth) return error.Corrupt;
        const pg = try bt.getAndInitPage(pgno);
        defer releasePage(pg);
        if (pg.db_page.n_ref != 1 + @as(u32, @intFromBool(pgno == 1))) return error.Corrupt;
        for (0..pg.n_cell) |i| {
            const cell = pg.findCell(i);
            if (!pg.leaf) try bt.clearDatabasePage(get4(cell), true, depth + 1, changes);
            _ = try bt.clearCell(pg, cell);
        }
        if (!pg.leaf) {
            try bt.clearDatabasePage(pg.rightChild(), true, depth + 1, changes);
            // Interior cells of a table are not entries.
            if (pg.int_key) changes = null;
        }
        if (changes) |c| c.* += pg.n_cell;
        if (free_self) {
            try bt.freePage(pg);
        } else {
            try bt.pager.write(pg.db_page);
            pg.zero(pg.data[pg.hdr_offset] | page.ptf_leaf);
        }
    }

    /// Port of sqlite3BtreeClearTable(): delete every entry of the b-tree
    /// rooted at `root`. Returns the number of entries deleted.
    pub fn clearTable(bt: *Btree, root: Pgno) Error!i64 {
        std.debug.assert(bt.in_trans == .write);
        try bt.saveAllCursors(root, null);
        var changes: i64 = 0;
        try bt.clearDatabasePage(root, false, 0, &changes);
        return changes;
    }

    /// Port of sqlite3BtreeDropTable(): delete a b-tree and free its root.
    /// In an auto-vacuum database the b-tree with the largest root page may
    /// be moved into the freed root; its old root page number is returned
    /// (else 0) so the schema can be updated.
    pub fn dropTable(bt: *Btree, root: Pgno) Error!Pgno {
        std.debug.assert(bt.in_trans == .write and root >= 2);
        if (root > bt.n_page) return error.Corrupt;
        _ = try bt.clearTable(root);
        const pg = try bt.getPage(root, .{});
        if (!bt.isAutoVacuum()) {
            defer releasePage(pg);
            try bt.freePage(pg);
            return 0;
        }

        var max_root = bt.getMeta(.largest_root_page);
        var moved: Pgno = 0;
        if (root == max_root) {
            defer releasePage(pg);
            try bt.freePage(pg);
        } else {
            // Keep the roots packed: move the last one into the gap.
            releasePage(pg);
            const move = try bt.getPage(max_root, .{});
            {
                defer releasePage(move);
                try bt.relocatePage(move, .root_page, 0, root, false);
            }
            const old = try bt.getPage(max_root, .{});
            defer releasePage(old);
            try bt.pager.write(old.db_page);
            try bt.freePage(old);
            moved = max_root;
        }
        max_root -= 1;
        while (ptrmap.isReserved(bt, max_root)) max_root -= 1;
        try bt.updateMeta(.largest_root_page, max_root);
        return moved;
    }

    /// Port of sqlite3BtreeGetMeta().
    pub fn getMeta(bt: *Btree, idx: Meta) u32 {
        std.debug.assert(bt.in_trans != .none);
        if (idx == .data_version) return bt.pager.dataVersion() +% bt.data_version_bias;
        return get4(bt.page1.?.data + header.meta_offset + @as(u32, @backingInt(idx)) * 4);
    }

    /// Port of sqlite3BtreeUpdateMeta(). The free page count is read-only.
    pub fn updateMeta(bt: *Btree, idx: Meta, value: u32) Error!void {
        std.debug.assert(bt.in_trans == .write);
        std.debug.assert(idx != .free_page_count and idx != .data_version);
        const p1 = bt.page1.?;
        try bt.pager.write(p1.db_page);
        put4(p1.data + header.meta_offset + @as(u32, @backingInt(idx)) * 4, value);
        // Switches between full and incremental; only setAutoVacuum turns
        // auto-vacuum on or off.
        if (idx == .incr_vacuum and bt.isAutoVacuum()) bt.auto_vacuum = if (value != 0) .incremental else .full;
    }

    pub const integrityCheck = @import("integrity.zig").check;
};

/// Port of pageReinit(): after rollback restores a page, its MemPage must
/// be decoded again.
fn pageReinit(pg: *pager_mod.Page) void {
    const mp = MemPage.of(pg);
    if (mp.is_init) {
        mp.is_init = false;
        // It might be an overflow or freelist page now, in which case
        // initializing fails harmlessly; every b-tree page must be redone.
        if (pg.n_ref > 1) mp.init() catch {};
    }
}

pub fn releasePage(mp: *MemPage) void {
    mp.bt.pager.unref(mp.db_page);
}

/// sqlite3AbsInt32() applied to a 32-bit difference.
fn absInt32(x: u32) u32 {
    const v: i32 = @bitCast(x);
    if (v >= 0) return @intCast(v);
    if (v == std.math.minInt(i32)) return std.math.maxInt(i32);
    return @intCast(-v);
}

pub fn orderToInt(o: Order) i32 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn within(p: [*]const u8, start: [*]const u8, end: [*]const u8) bool {
    return @intFromPtr(p) >= @intFromPtr(start) and @intFromPtr(p) < @intFromPtr(end);
}

/// SQLITE_OVERFLOW(P,S,E): the range [S,E) crosses P.
pub fn straddles(p: [*]const u8, start: [*]const u8, end: [*]const u8) bool {
    return @intFromPtr(start) < @intFromPtr(p) and @intFromPtr(end) > @intFromPtr(p);
}

fn ptrDiff(a: [*]const u8, b: [*]const u8) isize {
    return @as(isize, @intCast(@intFromPtr(a))) - @as(isize, @intCast(@intFromPtr(b)));
}

// =================================================================== cells

/// NB: pages taking part in a balance (the page and one neighbour on each
/// side). Has been 3 since SQLite's inception; other values are untested.
const nb = 3;

/// The cells of the pages being balanced, in order (CellArray). For index
/// b-trees the parent's dividers sit between the siblings' cells; table
/// b-trees have no dividers. `ap_end[k]` is the end of the page holding
/// cells up to `ix_nx[k]`, used to detect cells that cross a page end.
const CellArray = struct {
    n_cell: u32 = 0,
    /// A page of the same kind, for parsing.
    ref: *MemPage,
    cells: [][*]u8,
    /// Cell sizes; 0 means not yet computed.
    sizes: []u16,
    ap_end: [nb * 2][*]u8 = undefined,
    ix_nx: [nb * 2]u32 = @splat(std.math.maxInt(u32)),

    fn cellSizeAt(b: *CellArray, n: i32) u16 {
        const i: usize = @intCast(n);
        if (b.sizes[i] == 0) b.sizes[i] = b.ref.cellSize(b.cells[i]);
        return b.sizes[i];
    }

    fn populate(b: *CellArray, first: u32, n: u32) void {
        for (first..first + n) |i| _ = b.cellSizeAt(@intCast(i));
    }

    /// Index into ap_end of the page holding cell `i`.
    fn endIndex(b: *const CellArray, i: u32) usize {
        var k: usize = 0;
        while (b.ix_nx[k] <= i) k += 1;
        return k;
    }
};

/// Port of rebuildPage(): replace the content of `pg` with cells
/// [first, first+n) of `b`. Cells already on `pg` are copied out first.
/// Leaves `n_free` stale.
fn rebuildPage(b: *CellArray, first: u32, n: u32, pg: *MemPage) Error!void {
    std.debug.assert(n > 0);
    const hdr = pg.hdr_offset;
    const a = pg.data;
    const usable = pg.bt.usable_size;
    const end = a + usable;
    const tmp = pg.bt.pager.tempSpace().ptr;
    var j: u32 = get2(a + hdr + 5);
    if (j > usable) j = 0;
    @memcpy(tmp[j..usable], a[j..usable]);

    var k = b.endIndex(first);
    var src_end = b.ap_end[k];
    var cellptr = pg.cell_idx;
    var data = end;
    var i = first;
    while (true) {
        var cell = b.cells[i];
        const sz = b.sizes[i];
        std.debug.assert(sz > 0);
        if (within(cell, a + j, end)) {
            if (@intFromPtr(cell) + sz > @intFromPtr(end)) return error.Corrupt;
            cell = tmp + (@intFromPtr(cell) - @intFromPtr(a));
        } else if (straddles(src_end, cell, cell + sz)) {
            return error.Corrupt;
        }
        data -= sz;
        // C stores the offset before this check; checking first keeps the
        // offset from going below the start of the page.
        if (@intFromPtr(data) < @intFromPtr(cellptr) + 2) return error.Corrupt;
        put2(cellptr, @intCast(@intFromPtr(data) - @intFromPtr(a)));
        cellptr += 2;
        @memmove(data[0..sz], cell[0..sz]);
        i += 1;
        if (i >= first + n) break;
        if (b.ix_nx[k] <= i) {
            k += 1;
            src_end = b.ap_end[k];
        }
    }

    pg.n_cell = @intCast(n);
    pg.n_overflow = 0;
    put2(a + hdr + 1, 0);
    put2(a + hdr + 3, n);
    put2(a + hdr + 5, @intCast(@intFromPtr(data) - @intFromPtr(a)));
    a[hdr + 7] = 0;
}

/// Port of pageInsertArray(): add cells [first, first+n) of `b`, writing
/// their pointers at `cellptr`. `data` is the start of the content area
/// and `begin` the end of the final cell pointer array. Returns true if
/// they do not fit without defragmenting.
fn pageInsertArray(pg: *MemPage, begin: [*]u8, data: *[*]u8, cellptr_arg: [*]u8, first: u32, n: u32, b: *CellArray) bool {
    if (n == 0) return false;
    std.debug.assert(pg.hdr_offset == 0);
    const a = pg.data;
    var p_data = data.*;
    var cellptr = cellptr_arg;
    var k = b.endIndex(first);
    var end = b.ap_end[k];
    var i = first;
    while (true) {
        const sz = b.sizes[i];
        const cell = b.cells[i];
        const free_slot: ?u32 = if (a[1] == 0 and a[2] == 0) null else pg.findSlot(sz) catch null;
        var slot: [*]u8 = undefined;
        if (free_slot) |s| {
            slot = a + s;
        } else {
            if (ptrDiff(p_data, begin) < sz) return true;
            p_data -= sz;
            slot = p_data;
        }
        // A cell crossing the end of its page means corruption.
        if (straddles(end, cell, cell + sz)) return true;
        @memmove(slot[0..sz], cell[0..sz]);
        put2(cellptr, @intCast(@intFromPtr(slot) - @intFromPtr(a)));
        cellptr += 2;
        i += 1;
        if (i >= first + n) break;
        if (b.ix_nx[k] <= i) {
            k += 1;
            end = b.ap_end[k];
        }
    }
    data.* = p_data;
    return false;
}

/// Port of pageFreeArray(): free the space of those cells in
/// [first, first+n) that live on `pg`. Returns how many there were.
fn pageFreeArray(pg: *MemPage, first: u32, n: u32, b: *CellArray) u32 {
    const a = pg.data;
    const end = a + pg.bt.usable_size;
    const start = a + pg.hdr_offset + 8 + pg.child_ptr_size;
    var n_ret: u32 = 0;
    // Adjacent cells are merged before calling freeSpace.
    var n_free: usize = 0;
    var ofst: [10]u32 = undefined;
    var after: [10]u32 = undefined;
    for (first..first + n) |i| {
        const cell = b.cells[i];
        if (!within(cell, start, end)) continue;
        const sz: u32 = b.sizes[i];
        const i_ofst: u32 = @intCast(@intFromPtr(cell) - @intFromPtr(a));
        const i_after = i_ofst + sz;
        var j: usize = 0;
        while (j < n_free) : (j += 1) {
            if (ofst[j] == i_after) {
                ofst[j] = i_ofst;
                break;
            } else if (after[j] == i_ofst) {
                after[j] = i_after;
                break;
            }
        }
        if (j >= n_free) {
            if (n_free >= ofst.len) {
                for (0..n_free) |m| pg.freeSpace(ofst[m], after[m] - ofst[m]) catch {};
                n_free = 0;
            }
            ofst[n_free] = i_ofst;
            after[n_free] = i_after;
            if (@intFromPtr(a) + i_after > @intFromPtr(end)) return 0;
            n_free += 1;
        }
        n_ret += 1;
    }
    for (0..n_free) |m| pg.freeSpace(ofst[m], after[m] - ofst[m]) catch {};
    return n_ret;
}

/// Port of editPage(): `pg` holds its cells starting at b.cells[old]; make
/// it hold n cells starting at b.cells[new] by trimming and adding at the
/// edges, or rebuild it if that does not work out. Leaves `n_free` stale.
fn editPage(pg: *MemPage, i_old: u32, i_new: u32, n_new: u32, b: *CellArray) Error!void {
    const a = pg.data;
    const hdr = pg.hdr_offset;
    const begin = pg.cell_idx + n_new * 2;
    var n_cell: u32 = pg.n_cell;
    const i_old_end = i_old + pg.n_cell + pg.n_overflow;
    const i_new_end = i_new + n_new;

    edit: {
        // Remove cells from the start and end of the page.
        if (i_old < i_new) {
            const n_shift = pageFreeArray(pg, i_old, i_new - i_old, b);
            if (n_shift > n_cell) return error.Corrupt;
            @memmove(pg.cell_idx[0 .. n_cell * 2], pg.cell_idx[n_shift * 2 ..][0 .. n_cell * 2]);
            n_cell -= n_shift;
        }
        if (i_new_end < i_old_end) {
            const n_tail = pageFreeArray(pg, i_new_end, i_old_end - i_new_end, b);
            if (n_tail > n_cell) return error.Corrupt;
            n_cell -= n_tail;
        }

        var data = a + get2(a + hdr + 5);
        if (@intFromPtr(data) < @intFromPtr(begin)) break :edit;
        if (@intFromPtr(data) > @intFromPtr(pg.data_end)) break :edit;

        // Add cells to the start of the page.
        if (i_new < i_old) {
            const n_add = @min(n_new, i_old - i_new);
            @memmove(pg.cell_idx[n_add * 2 ..][0 .. n_cell * 2], pg.cell_idx[0 .. n_cell * 2]);
            if (pageInsertArray(pg, begin, &data, pg.cell_idx, i_new, n_add, b)) break :edit;
            n_cell += n_add;
        }

        // Add the overflow cells.
        for (pg.ai_ovfl[0..pg.n_overflow]) |ovfl_idx| {
            const i_cell = @as(i64, i_old) + ovfl_idx - i_new;
            if (i_cell < 0 or i_cell >= n_new) continue;
            const ic: u32 = @intCast(i_cell);
            const cellptr = pg.cell_idx + ic * 2;
            if (n_cell > ic) @memmove(cellptr[2..][0 .. (n_cell - ic) * 2], cellptr[0 .. (n_cell - ic) * 2]);
            n_cell += 1;
            _ = b.cellSizeAt(@intCast(ic + i_new));
            if (pageInsertArray(pg, begin, &data, cellptr, ic + i_new, 1, b)) break :edit;
        }

        // Append cells to the end of the page.
        const n_append = if (n_new > n_cell) n_new - n_cell else 0;
        if (pageInsertArray(pg, begin, &data, pg.cell_idx + n_cell * 2, i_new + n_cell, n_append, b)) break :edit;

        pg.n_cell = @intCast(n_new);
        pg.n_overflow = 0;
        put2(a + hdr + 3, n_new);
        put2(a + hdr + 5, @intCast(@intFromPtr(data) - @intFromPtr(a)));
        return;
    }
    // Editing in place failed; rebuild from scratch.
    if (n_new < 1) return error.Corrupt;
    b.populate(i_new, n_new);
    return rebuildPage(b, i_new, n_new, pg);
}

/// Port of copyNodeContent(): copy the b-tree node on `from` to `to` (not
/// its overflow cells) and reinitialize `to`.
fn copyNodeContent(from: *MemPage, to: *MemPage) Error!void {
    const usable = from.bt.usable_size;
    const to_hdr = to.hdr_offset;
    std.debug.assert(from.is_init and from.n_free >= to_hdr);
    const i_data: u32 = get2(from.data + from.hdr_offset + 5);
    @memcpy(to.data[i_data..usable], from.data[i_data..usable]);
    const n = from.cell_offset + 2 * @as(u32, from.n_cell);
    @memcpy(to.data[to_hdr..][0..n], from.data[from.hdr_offset..][0..n]);
    to.is_init = false;
    try to.init();
    try to.computeFreeSpace();
    // `to` now holds the pointers to the children and overflow chains.
    if (to.bt.isAutoVacuum()) try setChildPtrmaps(to);
}

/// Port of setChildPtrmaps(): point the pointer-map entries of every
/// child and overflow chain referenced from `pg` at `pg`.
fn setChildPtrmaps(pg: *MemPage) Error!void {
    if (!pg.is_init) try pg.init();
    const bt = pg.bt;
    for (0..pg.n_cell) |i| {
        const cell = pg.findCell(i);
        try ptrmap.putOvflPtr(pg, pg, cell);
        if (!pg.leaf) try ptrmap.put(bt, get4(cell), .btree_page, pg.pgno);
    }
    if (!pg.leaf) try ptrmap.put(bt, pg.rightChild(), .btree_page, pg.pgno);
}

/// Port of modifyPagePointer(): change the pointer to `from` on `pg` to
/// point at `to`. `e_type` says which pointer: a child (btree_page), the
/// overflow chain of a cell (overflow1), or the next-page link of an
/// overflow page (overflow2). `pg` must be writable.
fn modifyPagePointer(pg: *MemPage, from: Pgno, to: Pgno, e_type: ptrmap.Type) Error!void {
    if (e_type == .overflow2) {
        if (get4(pg.data) != from) return error.Corrupt;
        put4(pg.data, to);
        return;
    }
    if (!pg.is_init) try pg.init();
    const usable_end = pg.data + pg.bt.usable_size;
    for (0..pg.n_cell) |i| {
        const cell = pg.findCell(i);
        if (e_type == .overflow1) {
            const info = pg.parseCell(cell);
            if (info.n_local < info.n_payload) {
                if (@intFromPtr(cell + info.n_size) > @intFromPtr(usable_end)) return error.Corrupt;
                if (get4(cell + info.n_size - 4) == from) {
                    put4(cell + info.n_size - 4, to);
                    return;
                }
            }
        } else {
            if (@intFromPtr(cell + 4) > @intFromPtr(usable_end)) return error.Corrupt;
            if (get4(cell) == from) {
                put4(cell, to);
                return;
            }
        }
    }
    if (e_type != .btree_page or pg.rightChild() != from) return error.Corrupt;
    put4(pg.data + pg.hdr_offset + 8, to);
}

// ================================================================= cursor

pub const Cursor = struct {
    state: State = .invalid,
    flags: Flags = .{},
    /// With state `skipnext`: next() is a no-op if .gt (the cursor is on
    /// the entry after the saved one), previous() if .lt.
    skip_next: Order = .eq,
    /// The error that put the cursor in the `fault` state.
    fault: ?Error = null,
    bt: *Btree,
    /// Page numbers of the current entry's overflow chain; 0 = unknown.
    overflow: []Pgno = &.{},
    /// Saved key (padded allocation) while in `requireseek`.
    saved_key: ?[]u8 = null,
    next_cursor: ?*Cursor = null,
    /// Cache of the current cell, valid while `info.n_size != 0`.
    info: CellInfo = .{},
    /// Saved rowid or key length.
    n_key: i64 = 0,
    pgno_root: Pgno,
    /// Depth of the current page; -1 when no page is held.
    i_page: i8 = -1,
    cur_int_key: bool = false,
    /// Cell index on the current page.
    ix: u16 = 0,
    ai_idx: [max_depth - 1]u16 = undefined,
    key_info: ?KeyInfo,
    page: *MemPage = undefined,
    /// Ancestors of the current page.
    ap_page: [max_depth - 1]*MemPage = undefined,
    bulk_load: bool = false,

    pub const State = enum(u8) {
        valid,
        /// Not on an entry (empty b-tree, or ran off either end).
        invalid,
        /// Valid, but the next step in the direction of `skip_next` is a
        /// no-op.
        skipnext,
        /// The b-tree changed; the position is saved and must be restored.
        requireseek,
        /// An unrecoverable error; see `fault`.
        fault,

        fn atLeast(a: State, b: State) bool {
            return @backingInt(a) >= @backingInt(b);
        }
    };

    pub const Flags = packed struct(u8) {
        write: bool = false,
        /// `info.n_key` is valid.
        valid_nkey: bool = false,
        /// `overflow` is valid.
        valid_ovfl: bool = false,
        /// On the last entry.
        at_last: bool = false,
        /// Other cursors may be open on the same b-tree.
        multiple: bool = false,
        _: u3 = 0,
    };

    pub const Options = struct {
        write: bool = false,
        /// Non-null for index b-trees.
        key_info: ?KeyInfo = null,
    };

    pub const InsertOptions = struct {
        /// The entry likely goes at the end; bias the search.
        append: bool = false,
        /// Leave the cursor where a following next()/previous() works.
        save_position: bool = false,
        /// The result of a seek just made for this key: .lt if the cursor
        /// is on a smaller entry, .gt if on a larger one, .eq if on the
        /// entry itself. Null if unknown (a seek is then done here).
        seek_result: ?Order = null,
    };

    pub const DeleteOptions = struct {
        /// Leave the cursor so next()/previous() go where they would have.
        save_position: bool = false,
    };

    /// Port of sqlite3BtreeCloseCursor().
    pub fn close(cur: *Cursor) void {
        const bt = cur.bt;
        var link = &bt.cursors;
        while (link.*) |c| : (link = &c.next_cursor) {
            if (c == cur) {
                link.* = cur.next_cursor;
                break;
            }
        }
        cur.releaseAllPages();
        bt.unlockIfUnused();
        bt.gpa.free(cur.overflow);
        if (cur.saved_key) |k| bt.gpa.free(k);
        cur.* = undefined;
        if (bt.single and bt.cursors == null) bt.close(.{});
    }

    /// Port of sqlite3BtreeCursorHintFlags(BTREE_BULKLOAD): rows arrive in
    /// order, so pack pages fully.
    pub fn setBulkLoad(cur: *Cursor, on: bool) void {
        cur.bulk_load = on;
    }

    /// Port of btreeReleaseAllCursorPages().
    fn releaseAllPages(cur: *Cursor) void {
        if (cur.i_page < 0) return;
        for (cur.ap_page[0..@intCast(cur.i_page)]) |p| releasePage(p);
        releasePage(cur.page);
        cur.i_page = -1;
    }

    /// Port of sqlite3BtreeClearCursor().
    pub fn clear(cur: *Cursor) void {
        if (cur.saved_key) |k| cur.bt.gpa.free(k);
        cur.saved_key = null;
        cur.state = .invalid;
    }

    /// Put the cursor in the `fault` state with `err`.
    fn trip(cur: *Cursor, err: Error) void {
        cur.clear();
        cur.state = .fault;
        cur.fault = err;
    }

    /// Port of saveCursorKey(): remember the current key.
    fn saveKey(cur: *Cursor) Error!void {
        std.debug.assert(cur.state == .valid and cur.saved_key == null);
        if (cur.cur_int_key) {
            cur.n_key = cur.integerKey();
            return;
        }
        const n = cur.payloadSize();
        cur.n_key = n;
        // Padding guards record decoders against corrupt keys.
        const key = try cur.bt.gpa.alloc(u8, @as(usize, n) + 9 + 8);
        errdefer cur.bt.gpa.free(key);
        try cur.accessPayload(0, key[0..n], false);
        @memset(key[n..], 0);
        cur.saved_key = key;
    }

    /// Port of saveCursorPosition(): save the position and release the
    /// pages, entering `requireseek`.
    fn savePosition(cur: *Cursor) Error!void {
        std.debug.assert(cur.state == .valid or cur.state == .skipnext);
        if (cur.state == .skipnext) {
            cur.state = .valid;
        } else {
            cur.skip_next = .eq;
        }
        defer {
            cur.flags.valid_nkey = false;
            cur.flags.valid_ovfl = false;
            cur.flags.at_last = false;
        }
        try cur.saveKey();
        cur.releaseAllPages();
        cur.state = .requireseek;
    }

    fn savedKey(cur: *const Cursor) ?[]const u8 {
        const k = cur.saved_key orelse return null;
        return k[0..@intCast(cur.n_key)];
    }

    /// Port of btreeMoveto(): seek to a packed index key, or to rowid
    /// `n_key` when `key` is null.
    fn moveto(cur: *Cursor, key: ?[]const u8, n_key: i64, bias: bool) Error!Order {
        if (key) |k| {
            const ki = cur.key_info.?;
            return ki.call(.{ cur, k });
        }
        return cur.tableMoveto(n_key, bias);
    }

    /// Port of btreeRestoreCursorPosition().
    fn restorePosition(cur: *Cursor) Error!void {
        std.debug.assert(cur.state.atLeast(.requireseek));
        if (cur.state == .fault) return cur.fault.?;
        cur.state = .invalid;
        const res = try cur.moveto(cur.savedKey(), cur.n_key, false);
        if (cur.saved_key) |k| cur.bt.gpa.free(k);
        cur.saved_key = null;
        if (res != .eq) cur.skip_next = res;
        if (cur.skip_next != .eq and cur.state == .valid) cur.state = .skipnext;
    }

    fn restoreIfNeeded(cur: *Cursor) Error!void {
        if (cur.state.atLeast(.requireseek)) try cur.restorePosition();
    }

    /// Port of sqlite3BtreeCursorHasMoved(): the cursor is no longer
    /// known to be on its entry.
    pub fn hasMoved(cur: *const Cursor) bool {
        return cur.state != .valid;
    }

    /// Port of sqlite3BtreeCursorRestore(). Returns true if the cursor
    /// ended up on a different entry (its entry was deleted).
    pub fn restore(cur: *Cursor) Error!bool {
        std.debug.assert(cur.state != .valid);
        try cur.restoreIfNeeded();
        return cur.state != .valid;
    }

    pub fn eof(cur: *const Cursor) bool {
        return cur.state != .valid;
    }

    /// Port of getCellInfo(): the check in line, the parse out of line.
    inline fn getCellInfo(cur: *Cursor) void {
        if (cur.info.n_size == 0) cur.parseCurrentCell();
    }

    noinline fn parseCurrentCell(cur: *Cursor) void {
        cur.flags.valid_nkey = true;
        cur.info = cur.page.parseCellAt(cur.ix);
    }

    /// The rowid of the current entry (table b-trees).
    pub fn integerKey(cur: *Cursor) i64 {
        std.debug.assert(cur.state == .valid and cur.cur_int_key);
        cur.getCellInfo();
        return cur.info.n_key;
    }

    /// Bytes of payload in the current entry: the data for tables, the
    /// key for indexes.
    pub fn payloadSize(cur: *Cursor) u32 {
        std.debug.assert(cur.state == .valid);
        cur.getCellInfo();
        return cur.info.n_payload;
    }

    /// Port of sqlite3BtreePayload(): read `buf.len` payload bytes from
    /// `offset`.
    pub fn payload(cur: *Cursor, offset: u32, buf: []u8) Error!void {
        std.debug.assert(cur.state == .valid and cur.i_page >= 0);
        return cur.accessPayload(offset, buf, false);
    }

    /// Port of sqlite3BtreePayloadFetch(): the part of the payload stored on
    /// the page, without copying. Invalidated by any b-tree call.
    pub fn payloadFetch(cur: *Cursor) []const u8 {
        std.debug.assert(cur.state == .valid);
        cur.getCellInfo();
        return cur.localPayload();
    }

    /// The end of fetchPayload(): the local payload of the parsed cell.
    inline fn localPayload(cur: *Cursor) []const u8 {
        var amt: isize = cur.info.n_local;
        // Too little room for the local content: corrupt.
        const room = ptrDiff(cur.page.data_end, cur.info.payload);
        if (amt > room) amt = @max(0, room);
        return cur.info.payload[0..@intCast(amt)];
    }

    /// sqlite3BtreePayloadSize() and sqlite3BtreePayloadFetch() together,
    /// as OP_Column calls them, parsing the cell once.
    pub inline fn payloadFetchWithSize(cur: *Cursor) struct { n_payload: u32, local: []const u8 } {
        std.debug.assert(cur.state == .valid);
        cur.getCellInfo();
        return .{ .n_payload = cur.info.n_payload, .local = cur.localPayload() };
    }

    /// Port of accessPayload(): read (or overwrite, if `write`) payload
    /// bytes, following and caching the overflow chain.
    fn accessPayload(cur: *Cursor, offset_arg: u32, buf_arg: []u8, write: bool) Error!void {
        const pg = cur.page;
        const bt = cur.bt;
        std.debug.assert(cur.state == .valid);
        if (cur.ix >= pg.n_cell) return error.Corrupt;
        cur.getCellInfo();
        const info = cur.info;
        std.debug.assert(@as(u64, offset_arg) + buf_arg.len <= info.n_payload);
        // The local payload must end inside the usable part of the page.
        if (@intFromPtr(info.payload) - @intFromPtr(pg.data) > bt.usable_size - info.n_local) return error.Corrupt;

        var offset = offset_arg;
        var buf = buf_arg;
        if (offset < info.n_local) {
            const a = @min(buf.len, info.n_local - offset);
            try cur.copyPayload(info.payload + offset, buf[0..a], write, pg.db_page);
            offset = 0;
            buf = buf[a..];
        } else {
            offset -= info.n_local;
        }
        if (buf.len == 0) return;

        const ovfl_size = bt.usable_size - 4;
        var next_page = get4(info.payload + info.n_local);
        var i_idx: usize = 0;
        if (!cur.flags.valid_ovfl) {
            const n_ovfl = (info.n_payload - info.n_local + ovfl_size - 1) / ovfl_size;
            if (cur.overflow.len < n_ovfl) {
                cur.overflow = try bt.gpa.realloc(cur.overflow, n_ovfl * 2);
            }
            @memset(cur.overflow[0..n_ovfl], 0);
            cur.flags.valid_ovfl = true;
        } else if (cur.overflow[offset / ovfl_size] != 0) {
            // Skip straight to the first page needed.
            i_idx = offset / ovfl_size;
            next_page = cur.overflow[i_idx];
            offset %= ovfl_size;
        }

        while (next_page != 0) {
            if (next_page > bt.n_page) return error.Corrupt;
            cur.overflow[i_idx] = next_page;
            if (offset >= ovfl_size) {
                // Only the link to the next page is needed.
                next_page = if (cur.overflow[i_idx + 1] != 0)
                    cur.overflow[i_idx + 1]
                else
                    (try bt.getOverflowPage(next_page, false)).next;
                offset -= ovfl_size;
            } else {
                const a = @min(buf.len, ovfl_size - offset);
                const db_page = try bt.pager.get(next_page, .{});
                defer bt.pager.unref(db_page);
                if (write and (db_page.n_ref != 1 or MemPage.of(db_page).is_init)) return error.Corrupt;
                const data = db_page.data.ptr;
                next_page = get4(data);
                try cur.copyPayload(data + 4 + offset, buf[0..a], write, db_page);
                offset = 0;
                buf = buf[a..];
                if (buf.len == 0) return;
            }
            i_idx += 1;
        }
        // The overflow chain ended early.
        return error.Corrupt;
    }

    fn copyPayload(cur: *Cursor, ptr: [*]u8, buf: []u8, write: bool, db_page: *pager_mod.Page) Error!void {
        if (write) {
            try cur.bt.pager.write(db_page);
            @memcpy(ptr[0..buf.len], buf);
        } else {
            @memcpy(buf, ptr[0..buf.len]);
        }
    }

    // ========================================================== movement

    /// Port of moveToChild().
    fn moveToChild(cur: *Cursor, pgno: Pgno) Error!void {
        std.debug.assert(cur.state == .valid and cur.i_page >= 0);
        if (cur.i_page >= max_depth - 1) return error.Corrupt;
        cur.invalidateCell();
        const i: usize = @intCast(cur.i_page);
        cur.ai_idx[i] = cur.ix;
        cur.ap_page[i] = cur.page;
        cur.ix = 0;
        cur.page = cur.childPage(pgno) catch |err| {
            cur.page = cur.ap_page[i];
            return err;
        };
        cur.i_page += 1;
    }

    fn childPage(cur: *Cursor, pgno: Pgno) Error!*MemPage {
        const child = try cur.bt.getAndInitPage(pgno);
        if (child.n_cell < 1 or child.int_key != cur.cur_int_key) {
            releasePage(child);
            return error.Corrupt;
        }
        return child;
    }

    /// Forget the cached cell, whose position is changing.
    fn invalidateCell(cur: *Cursor) void {
        cur.info.n_size = 0;
        cur.flags.valid_nkey = false;
        cur.flags.valid_ovfl = false;
    }

    /// Port of moveToParent().
    fn moveToParent(cur: *Cursor) void {
        std.debug.assert(cur.state == .valid and cur.i_page > 0);
        cur.invalidateCell();
        const i: usize = @intCast(cur.i_page - 1);
        cur.ix = cur.ai_idx[i];
        const leaf = cur.page;
        cur.page = cur.ap_page[i];
        cur.i_page -= 1;
        releasePage(leaf);
    }

    /// Port of moveToRoot(). Returns false (SQLITE_EMPTY) if the b-tree is
    /// empty. Page 1 may be a "virtual root": an empty interior root with
    /// one child, which the cursor descends into.
    fn moveToRoot(cur: *Cursor) Error!bool {
        if (cur.i_page >= 0) {
            if (cur.i_page > 0) {
                releasePage(cur.page);
                var i = cur.i_page - 1;
                while (i > 0) : (i -= 1) releasePage(cur.ap_page[@intCast(i)]);
                cur.i_page = 0;
                cur.page = cur.ap_page[0];
                return cur.atRoot();
            }
        } else if (cur.pgno_root == 0) {
            cur.state = .invalid;
            return false;
        } else {
            if (cur.state.atLeast(.requireseek)) {
                if (cur.state == .fault) return cur.fault.?;
                cur.clear();
            }
            cur.page = cur.bt.getAndInitPage(cur.pgno_root) catch |err| {
                cur.state = .invalid;
                return err;
            };
            cur.i_page = 0;
            cur.cur_int_key = cur.page.int_key;
        }
        const root = cur.page;
        // The root may be linked into another b-tree of the other kind in a
        // corrupt file.
        if (!root.is_init or (cur.key_info == null) != root.int_key) return error.Corrupt;
        return cur.atRoot();
    }

    fn atRoot(cur: *Cursor) Error!bool {
        const root = cur.page;
        cur.ix = 0;
        cur.invalidateCell();
        cur.flags.at_last = false;
        if (root.n_cell > 0) {
            cur.state = .valid;
            return true;
        }
        if (!root.leaf) {
            if (root.pgno != 1) return error.Corrupt;
            cur.state = .valid;
            try cur.moveToChild(root.rightChild());
            return true;
        }
        cur.state = .invalid;
        return false;
    }

    /// Port of moveToLeftmost(): down to the smallest entry below the
    /// current one.
    fn moveToLeftmost(cur: *Cursor) Error!void {
        while (!cur.page.leaf) try cur.moveToChild(get4(cur.page.findCell(cur.ix)));
    }

    /// Port of moveToRightmost(): down to the largest entry below the
    /// current page.
    fn moveToRightmost(cur: *Cursor) Error!void {
        while (!cur.page.leaf) {
            cur.ix = cur.page.n_cell;
            try cur.moveToChild(cur.page.rightChild());
        }
        cur.ix = cur.page.n_cell - 1;
    }

    /// Port of sqlite3BtreeFirst(). Returns false if the b-tree is empty.
    pub fn first(cur: *Cursor) Error!bool {
        if (!try cur.moveToRoot()) return false;
        try cur.moveToLeftmost();
        return true;
    }

    /// Port of sqlite3BtreeLast(). Returns false if the b-tree is empty.
    pub fn last(cur: *Cursor) Error!bool {
        if (cur.state == .valid and cur.flags.at_last) return true;
        if (!try cur.moveToRoot()) return false;
        cur.moveToRightmost() catch |err| {
            cur.flags.at_last = false;
            return err;
        };
        cur.flags.at_last = true;
        return true;
    }

    /// Port of sqlite3BtreeRowCountEst(): a guess at the number of entries,
    /// from the cell counts of the pages on the path to the current leaf.
    /// -1 if the cursor is not on a leaf entry.
    pub fn rowCountEst(cur: *const Cursor) i64 {
        if (cur.state != .valid or !cur.page.leaf) return -1;
        var n: i64 = cur.page.n_cell;
        for (cur.ap_page[0..@intCast(cur.i_page)]) |p| n *= p.n_cell;
        return n;
    }

    /// Port of sqlite3BtreeIsEmpty().
    pub fn isEmpty(cur: *Cursor) Error!bool {
        if (cur.state == .valid) return false;
        return !try cur.moveToRoot();
    }

    /// Port of sqlite3BtreeNext(). Returns false (SQLITE_DONE) past the last
    /// entry.
    pub fn next(cur: *Cursor) Error!bool {
        cur.invalidateCell();
        if (cur.state != .valid) return cur.nextSlow();
        const pg = cur.page;
        cur.ix += 1;
        if (cur.ix >= pg.n_cell) {
            cur.ix -= 1;
            return cur.nextSlow();
        }
        if (!pg.leaf) try cur.moveToLeftmost();
        return true;
    }

    /// Port of btreeNext().
    fn nextSlow(cur: *Cursor) Error!bool {
        if (cur.state != .valid) {
            try cur.restoreIfNeeded();
            if (cur.state == .invalid) return false;
            if (cur.state == .skipnext) {
                cur.state = .valid;
                if (cur.skip_next == .gt) return true;
            }
        }
        var pg = cur.page;
        cur.ix += 1;
        if (!pg.is_init) return error.Corrupt;
        if (cur.ix >= pg.n_cell) {
            if (!pg.leaf) {
                try cur.moveToChild(pg.rightChild());
                try cur.moveToLeftmost();
                return true;
            }
            while (true) {
                if (cur.i_page == 0) {
                    cur.state = .invalid;
                    return false;
                }
                cur.moveToParent();
                pg = cur.page;
                if (cur.ix < pg.n_cell) break;
            }
            // Interior cells of a table are not entries.
            if (pg.int_key) return cur.next();
            return true;
        }
        if (!pg.leaf) try cur.moveToLeftmost();
        return true;
    }

    /// Port of sqlite3BtreePrevious(). Returns false (SQLITE_DONE) before
    /// the first entry.
    pub fn previous(cur: *Cursor) Error!bool {
        cur.invalidateCell();
        cur.flags.at_last = false;
        if (cur.state != .valid or cur.ix == 0 or !cur.page.leaf) return cur.previousSlow();
        cur.ix -= 1;
        return true;
    }

    /// Port of btreePrevious().
    fn previousSlow(cur: *Cursor) Error!bool {
        if (cur.state != .valid) {
            try cur.restoreIfNeeded();
            if (cur.state == .invalid) return false;
            if (cur.state == .skipnext) {
                cur.state = .valid;
                if (cur.skip_next == .lt) return true;
            }
        }
        const pg = cur.page;
        if (!pg.is_init) return error.Corrupt;
        if (!pg.leaf) {
            try cur.moveToChild(get4(pg.findCell(cur.ix)));
            try cur.moveToRightmost();
            return true;
        }
        while (cur.ix == 0) {
            if (cur.i_page == 0) {
                cur.state = .invalid;
                return false;
            }
            cur.moveToParent();
        }
        cur.ix -= 1;
        if (cur.page.int_key and !cur.page.leaf) return cur.previous();
        return true;
    }

    /// Port of sqlite3BtreeTableMoveto(): move near rowid `key`. Returns
    /// .eq on an exact match; otherwise the cursor is on a leaf entry next
    /// to where `key` would go, and the result says whether that entry is
    /// smaller (.lt, also returned for an empty table) or larger (.gt).
    pub fn tableMoveto(cur: *Cursor, key: i64, bias_right: bool) Error!Order {
        std.debug.assert(cur.key_info == null);
        if (cur.state == .valid and cur.flags.valid_nkey) {
            if (cur.info.n_key == key) return .eq;
            if (cur.info.n_key < key) {
                if (cur.flags.at_last) return .lt;
                // Stepping to the next rowid is cheaper than a search.
                if (cur.info.n_key + 1 == key) {
                    if (try cur.next()) {
                        cur.getCellInfo();
                        if (cur.info.n_key == key) return .eq;
                    }
                }
            }
        }

        if (!try cur.moveToRoot()) return .lt;
        errdefer cur.info.n_size = 0;
        while (true) {
            const pg = cur.page;
            var lwr: i32 = 0;
            var upr: i32 = @as(i32, pg.n_cell) - 1;
            var idx: i32 = if (bias_right) upr else upr >> 1;
            var c: Order = .eq;
            while (true) {
                var cell = pg.findCellPastPtr(@intCast(idx));
                if (pg.int_key_leaf) {
                    // Skip the payload size.
                    while (true) {
                        const byte = cell[0];
                        cell += 1;
                        if (byte < 0x80) break;
                        if (@intFromPtr(cell) >= @intFromPtr(pg.data_end)) return error.Corrupt;
                    }
                }
                const cell_key: i64 = @bitCast(varint.get(cell[0..9]).value);
                if (cell_key < key) {
                    lwr = idx + 1;
                    if (lwr > upr) {
                        c = .lt;
                        break;
                    }
                } else if (cell_key > key) {
                    upr = idx - 1;
                    if (lwr > upr) {
                        c = .gt;
                        break;
                    }
                } else {
                    cur.ix = @intCast(idx);
                    if (pg.leaf) {
                        cur.flags.valid_nkey = true;
                        cur.info.n_key = cell_key;
                        cur.info.n_size = 0;
                        return .eq;
                    }
                    // Equal interior keys: the entry is in the left child.
                    lwr = idx;
                    break;
                }
                idx = (lwr + upr) >> 1;
            }
            if (pg.leaf) {
                cur.ix = @intCast(idx);
                cur.info.n_size = 0;
                return c;
            }
            const child = if (lwr >= pg.n_cell) pg.rightChild() else get4(pg.findCell(@intCast(lwr)));
            cur.ix = @intCast(lwr);
            try cur.moveToChild(child);
        }
    }

    /// Port of indexCellCompare(): compare cell `idx` with the key if it
    /// is stored entirely on the page; null if that is not cheap to tell.
    fn indexCellCompare(cur: *Cursor, idx: usize, key: IndexKey) CompareError!?Order {
        const pg = cur.page;
        const cell = pg.findCellPastPtr(idx);
        var n: u32 = cell[0];
        if (n <= pg.max1byte_payload) {
            if (@intFromPtr(cell + n) >= @intFromPtr(pg.data_end)) return null;
            return try key.call(.{cell[1..][0..n]});
        }
        if (cell[1] & 0x80 == 0) {
            n = ((n & 0x7f) << 7) + cell[1];
            if (n <= pg.max_local) {
                if (@intFromPtr(cell + n) >= @intFromPtr(pg.data_end)) return null;
                return try key.call(.{cell[2..][0..n]});
            }
        }
        return null;
    }

    /// Port of cursorOnLastPage().
    fn onLastPage(cur: *const Cursor) bool {
        for (cur.ap_page[0..@intCast(cur.i_page)], cur.ai_idx[0..@intCast(cur.i_page)]) |p, ix| {
            if (ix < p.n_cell) return false;
        }
        return true;
    }

    /// Port of sqlite3BtreeIndexMoveto(): move near `key` in an index.
    /// Results as for `tableMoveto`.
    pub fn indexMoveto(cur: *Cursor, key: IndexKey) Error!Order {
        std.debug.assert(cur.key_info != null);
        // Two shortcuts when the cursor is on the last leaf: the key is at
        // or after the last entry, or at or after the first entry of the
        // page (start searching here).
        if (cur.state == .valid and cur.page.leaf and cur.onLastPage()) {
            if (cur.ix == cur.page.n_cell - 1) {
                if (try cur.indexCellCompare(cur.ix, key)) |c| if (c != .gt) return c;
            }
            if (cur.i_page > 0) {
                if (try cur.indexCellCompare(0, key)) |c| {
                    if (c != .gt) {
                        cur.flags.valid_ovfl = false;
                        cur.flags.at_last = false;
                        if (!cur.page.is_init) return error.Corrupt;
                        return cur.indexSearch(key);
                    }
                }
            }
        }
        if (!try cur.moveToRoot()) return .lt;
        return cur.indexSearch(key);
    }

    fn indexSearch(cur: *Cursor, key: IndexKey) Error!Order {
        const bt = cur.bt;
        defer cur.info.n_size = 0;
        while (true) {
            const pg = cur.page;
            var lwr: i32 = 0;
            var upr: i32 = @as(i32, pg.n_cell) - 1;
            var idx: i32 = upr >> 1;
            var c: Order = undefined;
            while (true) {
                const cell = pg.findCellPastPtr(@intCast(idx));
                // An index record on a page is under 16384 bytes, so its size
                // takes 1 or 2 bytes when it fits on the page.
                var n: u32 = cell[0];
                if (n <= pg.max1byte_payload) {
                    if (@intFromPtr(cell + n) >= @intFromPtr(pg.data_end)) return error.Corrupt;
                    c = try key.call(.{cell[1..][0..n]});
                } else if (cell[1] & 0x80 == 0 and blk: {
                    n = ((n & 0x7f) << 7) + cell[1];
                    break :blk n <= pg.max_local and @intFromPtr(cell + n) < @intFromPtr(pg.data_end);
                }) {
                    c = try key.call(.{cell[2..][0..n]});
                } else {
                    // The record spills onto overflow pages: assemble it.
                    cur.info = pg.parseCell(cell - pg.child_ptr_size);
                    const n_key = cur.info.n_key;
                    if (n_key < 2 or @divTrunc(n_key, @as(i64, bt.usable_size)) > bt.n_page) return error.Corrupt;
                    const len: usize = @intCast(n_key);
                    // 18 bytes of padding against corrupt records.
                    const buf = try bt.gpa.alloc(u8, len + 18);
                    defer bt.gpa.free(buf);
                    cur.ix = @intCast(idx);
                    const r = cur.accessPayload(0, buf[0..len], false);
                    cur.flags.valid_ovfl = false;
                    try r;
                    @memset(buf[len..], 0);
                    c = try key.call(.{buf[0..len]});
                }
                switch (c) {
                    .lt => lwr = idx + 1,
                    .gt => upr = idx - 1,
                    .eq => {
                        cur.ix = @intCast(idx);
                        return .eq;
                    },
                }
                if (lwr > upr) break;
                idx = (lwr + upr) >> 1;
            }
            if (pg.leaf) {
                cur.ix = @intCast(idx);
                return c;
            }
            const child = if (lwr >= pg.n_cell) pg.rightChild() else get4(pg.findCell(@intCast(lwr)));
            cur.ix = @intCast(lwr);
            try cur.moveToChild(child);
        }
    }

    /// Port of sqlite3BtreeCount(): the number of entries.
    pub fn count(cur: *Cursor) Error!i64 {
        if (!try cur.moveToRoot()) return 0;
        var n: i64 = 0;
        while (true) {
            var pg = cur.page;
            if (pg.leaf or !pg.int_key) n += pg.n_cell;
            if (pg.leaf) {
                while (true) {
                    if (cur.i_page == 0) {
                        _ = try cur.moveToRoot();
                        return n;
                    }
                    cur.moveToParent();
                    if (cur.ix < cur.page.n_cell) break;
                }
                cur.ix += 1;
                pg = cur.page;
            }
            if (cur.ix == pg.n_cell) {
                try cur.moveToChild(pg.rightChild());
            } else {
                try cur.moveToChild(get4(pg.findCell(cur.ix)));
            }
        }
    }

    // ======================================================= modification

    /// Port of anotherValidCursor(): a corrupt schema can point two
    /// b-trees at the same pages; balancing would then pull the page from
    /// under the other cursor.
    fn anotherValidCursor(cur: *Cursor) Error!void {
        var it = cur.bt.cursors;
        while (it) |o| : (it = o.next_cursor) {
            if (o != cur and o.state == .valid and o.page == cur.page) return error.Corrupt;
        }
    }

    /// Port of balance(): rebalance after the current page was modified,
    /// walking up as long as pages are over- or underfull.
    fn balance(cur: *Cursor) Error!void {
        const bt = cur.bt;
        var quick_space: [13]u8 = undefined;
        // balance_nonroot's ovfl_space. The parent's overflow cells may
        // point into the previous level's buffer until the parent itself is
        // balanced, so two buffers alternate.
        var spaces: [2]?[]u8 = .{ null, null };
        var level: u1 = 0;
        defer for (spaces) |sp| if (sp) |x| bt.gpa.free(x);
        while (true) {
            const pg = cur.page;
            if (pg.n_free < 0) pg.computeFreeSpace() catch break;
            // Nothing to do without overflow cells and with at most 2/3 of
            // the page free.
            if (pg.n_overflow == 0 and pg.n_free * 3 <= @as(i64, bt.usable_size) * 2) break;
            if (cur.i_page == 0) {
                if (pg.n_overflow == 0) break;
                // The root overflows: push its content down a level and
                // balance that child on the next pass.
                try cur.anotherValidCursor();
                const child = try bt.balanceDeeper(pg);
                cur.i_page = 1;
                cur.ix = 0;
                cur.ai_idx[0] = 0;
                cur.ap_page[0] = pg;
                cur.page = child;
                continue;
            }
            // A non-root page referenced elsewhere is its own ancestor.
            if (pg.db_page.n_ref > 1) return error.Corrupt;

            const i: usize = @intCast(cur.i_page - 1);
            const parent = cur.ap_page[i];
            const i_idx = cur.ai_idx[i];
            const r = cur.balanceStep(parent, pg, i_idx, &quick_space, &spaces[level]);
            level +%= 1;
            pg.n_overflow = 0;
            releasePage(pg);
            cur.i_page -= 1;
            cur.page = cur.ap_page[@intCast(cur.i_page)];
            try r;
        }
    }

    fn balanceStep(cur: *Cursor, parent: *MemPage, pg: *MemPage, i_idx: u16, quick_space: *[13]u8, space: *?[]u8) Error!void {
        const bt = cur.bt;
        try bt.pager.write(parent.db_page);
        if (parent.n_free < 0) try parent.computeFreeSpace();
        if (pg.int_key_leaf and pg.n_overflow == 1 and pg.ai_ovfl[0] == pg.n_cell and
            parent.pgno != 1 and parent.n_cell == i_idx)
        {
            // Appending to the end of a table.
            return bt.balanceQuick(parent, pg, quick_space);
        }
        if (space.* == null) space.* = try bt.gpa.alloc(u8, bt.page_size);
        return bt.balanceNonroot(parent, i_idx, space.*.?, cur.i_page == 1, cur.bulk_load);
    }

    /// Port of btreeOverwriteContent(): write `amt` bytes of `x` starting at
    /// `x_offset` to `dest`, only if they differ.
    fn overwriteContent(pg: *MemPage, dest: [*]u8, x: Payload, x_offset: u32, amt_arg: u32) Error!void {
        const n_data = @as(i64, @intCast(x.data.len)) - x_offset;
        if (n_data <= 0) {
            // Zeros only.
            var i: u32 = 0;
            while (i < amt_arg and dest[i] == 0) i += 1;
            if (i < amt_arg) {
                try pg.bt.pager.write(pg.db_page);
                @memset(dest[i..amt_arg], 0);
            }
            return;
        }
        var amt = amt_arg;
        if (n_data < amt) {
            // Data, then zeros at the end.
            const nd: u32 = @intCast(n_data);
            try overwriteContent(pg, dest + nd, x, x_offset + nd, amt - nd);
            amt = nd;
        }
        const src = x.data[x_offset..][0..amt];
        if (!std.mem.eql(u8, dest[0..amt], src)) {
            try pg.bt.pager.write(pg.db_page);
            // Overlap is possible in a corrupt file.
            @memmove(dest[0..amt], src);
        }
    }

    /// Port of btreeOverwriteCell(): overwrite the current entry with a
    /// payload of the same size, in place.
    fn overwriteCell(cur: *Cursor, x: Payload) Error!void {
        const pg = cur.page;
        const info = cur.info;
        const total = x.data.len + x.n_zero;
        if (@intFromPtr(info.payload) + info.n_local > @intFromPtr(pg.data_end) or
            @intFromPtr(info.payload) < @intFromPtr(pg.data + pg.cell_offset))
            return error.Corrupt;
        if (info.n_local == total) return overwriteContent(pg, info.payload, x, 0, info.n_local);

        // btreeOverwriteOverflowCell
        try overwriteContent(pg, info.payload, x, 0, info.n_local);
        var offset: u32 = info.n_local;
        var ovfl_pgno = get4(info.payload + offset);
        var ovfl_size = cur.bt.usable_size - 4;
        while (true) {
            const op = try cur.bt.getPage(ovfl_pgno, .{});
            defer cur.bt.pager.unref(op.db_page);
            if (op.db_page.n_ref != 1 or op.is_init) return error.Corrupt;
            if (offset + ovfl_size < total) {
                ovfl_pgno = get4(op.data);
            } else {
                ovfl_size = @intCast(total - offset);
            }
            try overwriteContent(op, op.data + 4, x, offset, ovfl_size);
            offset += ovfl_size;
            if (offset >= total) break;
        }
    }

    /// Port of sqlite3BtreeInsert(): insert or replace an entry. For tables
    /// set `x.rowid` and `x.data`; for indexes set `x.key`. The cursor is
    /// left at an arbitrary position unless `save_position`.
    pub fn insert(cur: *Cursor, x: Payload, opts: InsertOptions) Error!void {
        const bt = cur.bt;
        var seek = opts.seek_result;
        const n_key = x.nKey();
        std.debug.assert((x.key == null) == (cur.key_info == null));

        if (cur.flags.multiple) {
            try bt.saveAllCursors(cur.pgno_root, cur);
            // Only possible if two b-trees share a root in a corrupt schema.
            if (seek != null and cur.i_page < 0) return error.Corrupt;
        }
        if (cur.state.atLeast(.requireseek)) _ = try cur.moveToRoot();
        std.debug.assert(cur.flags.write and bt.in_trans == .write and !bt.read_only);

        if (cur.key_info == null) {
            if (cur.flags.valid_nkey and n_key == cur.info.n_key) {
                // On the entry to replace; same size means overwrite in place.
                if (cur.info.n_size != 0 and cur.info.n_payload == x.data.len + x.n_zero) {
                    return cur.overwriteCell(x);
                }
            } else if (seek == null) {
                seek = try cur.tableMoveto(n_key, opts.append);
            }
        } else {
            if (seek == null and !opts.save_position) {
                seek = if (x.seek) |k|
                    try cur.indexMoveto(k)
                else
                    try cur.moveto(x.key, n_key, opts.append);
            }
            // With save_position and no seek, the cursor is on an equal
            // entry.
            if ((seek orelse .eq) == .eq) {
                cur.getCellInfo();
                if (cur.info.n_key == n_key) {
                    return cur.overwriteCell(.{ .data = x.key.? });
                }
            }
        }
        // Where the cursor is relative to the new entry. Without a seek it
        // is on the entry being replaced.
        const loc = seek orelse .eq;
        std.debug.assert(cur.state == .valid or (cur.state == .invalid and loc != .eq));

        const pg = cur.page;
        if (pg.n_free < 0) {
            if (cur.state.atLeast(.skipnext)) return error.Corrupt;
            try pg.computeFreeSpace();
        }
        const new_cell = bt.tmpCell();
        const sz_new = try bt.fillInCell(pg, new_cell, x);
        var idx: usize = cur.ix;
        cur.info.n_size = 0;
        if (loc == .eq) {
            if (idx >= pg.n_cell) return error.Corrupt;
            try bt.pager.write(pg.db_page);
            const old_cell = pg.findCell(idx);
            if (!pg.leaf) new_cell[0..4].* = old_cell[0..4].*;
            const info = try bt.clearCell(pg, old_cell);
            cur.flags.valid_ovfl = false;
            // Same size: overwrite the old cell in place. Not in auto-vacuum
            // databases if the new cell might have an overflow chain, whose
            // pointer-map entry insertCell would set.
            if (info.n_size == sz_new and info.n_local == info.n_payload and
                (!bt.isAutoVacuum() or sz_new < pg.min_local))
            {
                if (@intFromPtr(old_cell) < @intFromPtr(pg.data + pg.hdr_offset + 10)) return error.Corrupt;
                if (@intFromPtr(old_cell) + sz_new > @intFromPtr(pg.data_end)) return error.Corrupt;
                @memcpy(old_cell[0..sz_new], new_cell[0..sz_new]);
                return;
            }
            try pg.dropCell(idx, info.n_size);
        } else if (loc == .lt and pg.n_cell > 0) {
            std.debug.assert(pg.leaf);
            cur.ix += 1;
            idx = cur.ix;
            cur.flags.valid_nkey = false;
            cur.flags.valid_ovfl = false;
        }
        try pg.insertCellFast(idx, new_cell, sz_new);

        if (pg.n_overflow != 0) {
            // Balancing moves the cursor. It is left invalid; a following
            // append still finds the last page quickly.
            cur.flags.valid_nkey = false;
            cur.flags.valid_ovfl = false;
            const r = cur.balance();
            cur.page.n_overflow = 0;
            cur.state = .invalid;
            try r;
            if (opts.save_position) {
                cur.releaseAllPages();
                if (x.key) |k| cur.saved_key = try bt.gpa.dupe(u8, k);
                cur.state = .requireseek;
                cur.n_key = n_key;
            }
        }
    }

    /// Port of sqlite3BtreeDelete(): delete the current entry.
    pub fn delete(cur: *Cursor, opts: DeleteOptions) Error!void {
        const bt = cur.bt;
        std.debug.assert(bt.in_trans == .write and !bt.read_only and cur.flags.write);
        if (cur.state != .valid) {
            if (!cur.state.atLeast(.requireseek)) return error.Corrupt;
            try cur.restorePosition();
            if (cur.state != .valid) return;
        }

        const cell_depth = cur.i_page;
        const cell_idx = cur.ix;
        const pg = cur.page;
        if (pg.n_cell <= cell_idx) return error.Corrupt;
        var cell = pg.findCell(cell_idx);
        if (pg.n_free < 0) pg.computeFreeSpace() catch return error.Corrupt;
        if (@intFromPtr(cell) < @intFromPtr(pg.cell_idx + pg.n_cell)) return error.Corrupt;

        // With save_position: if deleting will not rebalance, the cursor can
        // stay put (skipnext); otherwise save the key (requireseek).
        const preserve: enum { none, save_key, stay } = if (!opts.save_position)
            .none
        else if (!pg.leaf or @as(i64, pg.n_free) + pg.cellSize(cell) + 2 > bt.usable_size * 2 / 3 or pg.n_cell == 1)
            .save_key
        else
            .stay;
        if (preserve == .save_key) try cur.saveKey();

        // An entry on an interior page is replaced by its predecessor, the
        // largest entry in its left subtree, which makes balancing easier.
        if (!pg.leaf) {
            if (!try cur.previous()) return error.Corrupt;
        }
        if (cur.flags.multiple) try bt.saveAllCursors(cur.pgno_root, cur);

        try bt.pager.write(pg.db_page);
        const info = try bt.clearCell(pg, cell);
        try pg.dropCell(cell_idx, info.n_size);

        if (!pg.leaf) {
            // Move the predecessor from its leaf into the interior page.
            const leaf = cur.page;
            if (leaf.n_free < 0) try leaf.computeFreeSpace();
            const n: Pgno = if (cell_depth < cur.i_page - 1)
                cur.ap_page[@intCast(cell_depth + 1)].pgno
            else
                cur.page.pgno;
            cell = leaf.findCell(leaf.n_cell - 1);
            if (@intFromPtr(cell) < @intFromPtr(leaf.data + 4)) return error.Corrupt;
            const n_cell = leaf.cellSize(cell);
            try bt.pager.write(leaf.db_page);
            // A 3-byte leaf cell (payload size 2) is padded to 4; the
            // interior copy is not.
            try pg.insertCell(cell_idx, cell - 4, n_cell + 4 - @as(u32, @intFromBool(cell[0] == 2)), bt.tmpCell(), n);
            try leaf.dropCell(leaf.n_cell - 1, n_cell);
        }

        // Balance the leaf first. If the entry was interior and the balance
        // did not reach that page, walk up and balance it too.
        if (cur.page.n_free * 3 > @as(i64, bt.usable_size) * 2) try cur.balance();
        if (cur.i_page > cell_depth) {
            releasePage(cur.page);
            cur.i_page -= 1;
            while (cur.i_page > cell_depth) {
                releasePage(cur.ap_page[@intCast(cur.i_page)]);
                cur.i_page -= 1;
            }
            cur.page = cur.ap_page[@intCast(cur.i_page)];
            try cur.balance();
        }

        if (preserve == .stay) {
            cur.state = .skipnext;
            if (cell_idx >= pg.n_cell) {
                cur.skip_next = .lt;
                cur.ix = pg.n_cell - 1;
            } else {
                cur.skip_next = .gt;
            }
        } else {
            const r = cur.moveToRoot();
            if (preserve == .save_key) {
                cur.releaseAllPages();
                cur.state = .requireseek;
            }
            _ = try r;
        }
    }
};

test {
    _ = header;
    _ = @import("btree_test.zig");
}
