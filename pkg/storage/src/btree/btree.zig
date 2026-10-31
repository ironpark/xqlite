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
//! The rest of btree.c is in the files next to this one, as functions of
//! a `*Btree` that this file calls as methods: page access and cells
//! (page.zig), the freelist and overflow chains (alloc.zig), balancing
//! (balance.zig), page relocation for auto-vacuum (vacuum.zig), the
//! pointer map (ptrmap.zig) and the integrity check (integrity.zig).
//!
//! Not ported yet: shared cache and incremental blob I/O.

const std = @import("std");
const corrupt = @import("../corrupt.zig").corrupt;
const checking = @import("../corrupt.zig").checking;
const thunk = @import("xqlite_base").thunk;
const vfs = @import("xqlite_vfs").vfs;
const pager_mod = @import("../pager/pager.zig");
const varint = @import("../varint.zig");
pub const header = @import("header.zig");
const page = @import("page.zig");
const ptrmap = @import("ptrmap.zig");
const alloc = @import("alloc.zig");
const balancing = @import("balance.zig");
const vacuum = @import("vacuum.zig");

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
    /// The connection's autovacuum-pages callback (see AutovacPages).
    autovac_pages: ?AutovacPages = null,
    /// The URI parameters of the database, for the VFS (Pager.Options).
    uri_params: []const u8 = "",
};

/// How many of its `n_free` free pages a full auto-vacuum commit of `bt`
/// gives back (xAutovacPages, sqlite3_autovacuum_pages()): null for all
/// of them (no callback is set).
pub const AutovacPages = thunk.Closure(*const fn (ctx: ?*anyopaque, bt: *Btree, n_orig: u32, n_free: u32, page_size: u32) ?u32);

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
    autovac_pages: ?AutovacPages = null,

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
    /// Size of the cell `Cursor.transferRow` left in the scratch space
    /// (nPreformatSize).
    n_preformat_size: u32 = 0,
    /// Backups reading this b-tree (Btree.nBackup): while there are any,
    /// it cannot be detached.
    n_backup: u32 = 0,
    /// Some cursor may be an incremental blob cursor (hasIncrblobCur):
    /// changes to table rows look for them only when set.
    has_incrblob_cur: bool = false,

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
            .uri_params = opts.uri_params,
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
            .autovac_pages = opts.autovac_pages,
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
    pub fn setPagerFlags(bt: *Btree, f: pager_mod.Flags) void {
        bt.pager.setFlags(f);
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
    /// size, as does any other invalid size, which only sets the reserve
    /// (C passes -1 for that). Fails with ReadOnly once the size is fixed
    /// (the database exists). `fix` fixes it now.
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

    /// Port of sqlite3BtreeGetRequestedReserve(): the reserve asked for by
    /// the last setPageSize(), or the current one if larger.
    pub fn getRequestedReserve(bt: *const Btree) u8 {
        return @intCast(@max(bt.reserve_wanted, bt.getReserve()));
    }

    /// Port of sqlite3PagerIsMemdb() of the b-tree's pager: a temporary
    /// database (":memory:", "" or TEMP), which VACUUM and the backup API
    /// do not give another page size.
    pub fn isMemdb(bt: *const Btree) bool {
        return bt.pager.isMemdb();
    }

    /// Port of sqlite3BtreeIsInBackup().
    pub fn isInBackup(bt: *const Btree) bool {
        return bt.n_backup != 0;
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

    // Functions of a b-tree in its other files, as methods here: page
    // access (page.zig), allocation and overflow chains (alloc.zig),
    // balancing (balance.zig) and page relocation (vacuum.zig).
    pub const getPage = page.getPage;
    const getAndInitPage = page.getAndInitPage;
    const allocatePage = alloc.allocatePage;
    const freePage = alloc.freePage;
    const getOverflowPage = alloc.getOverflowPage;
    const clearCell = alloc.clearCell;
    const fillInCell = alloc.fillInCell;
    const balanceQuick = balancing.balanceQuick;
    const balanceDeeper = balancing.balanceDeeper;
    const balanceNonroot = balancing.balanceNonroot;
    const invalidateAllOverflowCache = vacuum.invalidateAllOverflowCache;
    const relocatePage = vacuum.relocatePage;
    const incrVacuumStep = vacuum.incrVacuumStep;
    const finalDbSize = vacuum.finalDbSize;

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
            if (n_page > n_page_file) return corrupt(@src());
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
        return bt.commitPhaseOneSuper(null);
    }

    /// sqlite3BtreeCommitPhaseOne() of a multi-database transaction: the
    /// journal names the super-journal `super` (see Pager).
    pub fn commitPhaseOneSuper(bt: *Btree, super: ?[]const u8) Error!void {
        if (bt.in_trans != .write) return;
        if (bt.isAutoVacuum()) try bt.autoVacuumCommit();
        if (bt.do_truncate) bt.pager.truncateImage(bt.n_page);
        try bt.pager.commitPhaseOneSuper(super, false);
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
            if (root < 1) return corrupt(@src());
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

    /// Port of invalidateIncrblobCursors(): the row `i_row` of the table
    /// rooted at `root` (every row, with `is_clear_table`) is being
    /// replaced or deleted, so the incremental blob cursors on it become
    /// invalid (sqlite3_blob_read() and _write() then fail with
    /// SQLITE_ABORT). Called only while `has_incrblob_cur`, which it
    /// clears when no such cursor is left.
    fn invalidateIncrblobCursors(bt: *Btree, root: Pgno, i_row: i64, is_clear_table: bool) void {
        std.debug.assert(bt.has_incrblob_cur);
        bt.has_incrblob_cur = false;
        var it = bt.cursors;
        while (it) |c| : (it = c.next_cursor) {
            if (c.flags.incrblob) {
                bt.has_incrblob_cur = true;
                if (c.pgno_root == root and (is_clear_table or c.info.n_key == i_row)) {
                    c.state = .invalid;
                }
            }
        }
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

    // ========================================================= auto-vacuum

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
        if (n_orig < n_fin or n_free >= n_orig) return corrupt(@src());
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
        if (ptrmap.isReserved(bt, n_orig)) return corrupt(@src());
        const n_free = header.get(p1.data, .freelist_count);
        // The application may keep some free pages.
        var n_vac = n_free;
        if (bt.autovac_pages) |h| if (h.call(.{ bt, n_orig, n_free, bt.page_size })) |n| {
            n_vac = @min(n, n_free);
            if (n_vac == 0) return;
        };
        const n_fin = bt.finalDbSize(n_orig, n_vac);
        if (n_fin > n_orig) return corrupt(@src());

        errdefer bt.pager.rollback() catch {};
        if (n_fin < n_orig) try bt.saveAllCursors(0, null);
        var i_free = n_orig;
        while (i_free > n_fin) : (i_free -= 1) {
            if (!try bt.incrVacuumStep(n_fin, i_free, n_vac == n_free)) break;
        }
        if (n_free > 0) {
            try bt.pager.write(p1.db_page);
            if (n_vac == n_free) {
                header.put(p1.data, .first_freelist_trunk, 0);
                header.put(p1.data, .freelist_count, 0);
            }
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
        if (pgno_root > bt.n_page) return corrupt(@src());
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
                if (e.e_type == .root_page or e.e_type == .free_page) return corrupt(@src());
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
        if (pgno > bt.n_page) return corrupt(@src());
        // Guard against cycles in a corrupt file.
        if (depth > max_depth) return corrupt(@src());
        const pg = try bt.getAndInitPage(pgno);
        defer releasePage(pg);
        if (pg.db_page.n_ref != 1 + @as(u32, @intFromBool(pgno == 1))) return corrupt(@src());
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
        // Every incremental blob cursor on the table is invalidated (a
        // no-op if `root` is not a table b-tree).
        if (bt.has_incrblob_cur) bt.invalidateIncrblobCursors(root, 0, true);
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
        if (root > bt.n_page) return corrupt(@src());
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

pub fn orderToInt(o: Order) i32 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub const straddles = page.straddles;
const ptrDiff = page.ptrDiff;

/// Port of assertParentIndex(): `child` is the left child of cell `idx`
/// of `parent`, or its right child if `idx` is past the last cell.
fn assertParentIndex(parent: *const MemPage, idx: u32, child: Pgno) void {
    std.debug.assert(idx <= parent.n_cell);
    const pgno = if (idx == parent.n_cell) parent.rightChild() else get4(parent.findCell(idx));
    std.debug.assert(pgno == child);
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
        /// An incremental blob cursor (BTCF_Incrblob).
        incrblob: bool = false,
        _: u2 = 0,
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
        /// The cell was built by `transferRow` (BTREE_PREFORMAT); the
        /// payload is ignored. The key must not be in the b-tree yet, as
        /// in SQLite (OP_NotExists comes first): replacing an entry of
        /// the same payload size would overwrite it with the empty payload.
        preformat: bool = false,
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
        if (cur.info.n_size == 0) cur.parseCurrentCell() else if (checking()) cur.assertCellInfo();
    }

    /// Port of assertCellInfo(): the cached cell is the current one.
    fn assertCellInfo(cur: *Cursor) void {
        const info = cur.page.parseCellAt(cur.ix);
        std.debug.assert(info.n_key == cur.info.n_key and info.payload == cur.info.payload and
            info.n_payload == cur.info.n_payload and info.n_local == cur.info.n_local and
            info.n_size == cur.info.n_size);
    }

    /// Port of cursorIsAtLastEntry(): what the `at_last` flag claims.
    fn isAtLastEntry(cur: *const Cursor) bool {
        for (cur.ap_page[0..@intCast(cur.i_page)], cur.ai_idx[0..@intCast(cur.i_page)]) |pg, idx| {
            if (idx != pg.n_cell) return false;
        }
        return cur.ix + 1 == cur.page.n_cell and cur.page.leaf;
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
        if (cur.ix >= pg.n_cell) return corrupt(@src());
        cur.getCellInfo();
        const info = cur.info;
        std.debug.assert(@as(u64, offset_arg) + buf_arg.len <= info.n_payload);
        // The local payload must end inside the usable part of the page.
        if (@intFromPtr(info.payload) - @intFromPtr(pg.data) > bt.usable_size - info.n_local) return corrupt(@src());

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
            const n_ovfl = (info.n_payload -% info.n_local +% ovfl_size -% 1) / ovfl_size; // u32, wraps as in C
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
            if (next_page > bt.n_page) return corrupt(@src());
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
                if (write and (db_page.n_ref != 1 or MemPage.of(db_page).is_init)) return corrupt(@src());
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
        return corrupt(@src());
    }

    /// Port of sqlite3BtreePayloadChecked(): payload() for an incremental
    /// blob cursor, which may have been moved (it is restored) or
    /// invalidated (error.Abort).
    pub fn payloadChecked(cur: *Cursor, offset: u32, buf: []u8) Error!void {
        if (cur.state != .valid) {
            if (cur.state == .invalid) return error.Abort;
            try cur.restorePosition();
            // Port note: btreeRestoreCursorPosition() leaves a cursor whose
            // row is gone on a neighbour; the row was deleted, which
            // invalidated the cursor first, so it is on its row here.
            if (cur.state != .valid) return error.Abort;
        }
        return cur.accessPayload(offset, buf, false);
    }

    /// Port of sqlite3BtreePutData(): overwrite `buf.len` bytes of the
    /// payload of the current row from `offset`, for an incremental blob
    /// cursor on a table b-tree. The size of the row cannot change.
    pub fn putData(cur: *Cursor, offset: u32, buf: []const u8) Error!void {
        std.debug.assert(cur.flags.incrblob);
        try cur.restoreIfNeeded();
        std.debug.assert(cur.state != .requireseek);
        if (cur.state != .valid) return error.Abort;
        // Save the positions of the other cursors on the table, which may
        // hold the page modified below (they cannot fail to save on a
        // table b-tree).
        try cur.bt.saveAllCursors(cur.pgno_root, cur);
        if (!cur.flags.write) return error.ReadOnly;
        std.debug.assert(!cur.bt.read_only and cur.bt.in_trans == .write and cur.page.int_key);
        return cur.accessPayload(offset, @constCast(buf), true);
    }

    /// Port of sqlite3BtreeIncrblobCursor(): mark the cursor as an
    /// incremental blob cursor.
    pub fn incrblobCursor(cur: *Cursor) void {
        cur.flags.incrblob = true;
        cur.bt.has_incrblob_cur = true;
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
        if (cur.i_page >= max_depth - 1) return corrupt(@src());
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
            return corrupt(@src());
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
        const i: usize = @intCast(cur.i_page - 1);
        if (checking()) assertParentIndex(cur.ap_page[i], cur.ai_idx[i], cur.page.pgno);
        cur.invalidateCell();
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
        if (!root.is_init or (cur.key_info == null) != root.int_key) return corrupt(@src());
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
            if (root.pgno != 1) return corrupt(@src());
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
        if (cur.state == .valid and cur.flags.at_last) {
            if (checking()) std.debug.assert(cur.isAtLastEntry());
            return true;
        }
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
        if (!pg.is_init) return corrupt(@src());
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
        if (!pg.is_init) return corrupt(@src());
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
                if (cur.flags.at_last) {
                    if (checking()) std.debug.assert(cur.isAtLastEntry());
                    return .lt;
                }
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
                        if (@intFromPtr(cell) >= @intFromPtr(pg.data_end)) return corrupt(@src());
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
                        if (!cur.page.is_init) return corrupt(@src());
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
                    if (@intFromPtr(cell + n) >= @intFromPtr(pg.data_end)) return corrupt(@src());
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
                    if (n_key < 2 or @divTrunc(n_key, @as(i64, bt.usable_size)) > bt.n_page) return corrupt(@src());
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
            if (o != cur and o.state == .valid and o.page == cur.page) return corrupt(@src());
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
            if (pg.db_page.n_ref > 1) return corrupt(@src());

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
            return corrupt(@src());
        if (info.n_local == total) return overwriteContent(pg, info.payload, x, 0, info.n_local);

        // btreeOverwriteOverflowCell
        try overwriteContent(pg, info.payload, x, 0, info.n_local);
        var offset: u32 = info.n_local;
        var ovfl_pgno = get4(info.payload + offset);
        var ovfl_size = cur.bt.usable_size - 4;
        while (true) {
            const op = try cur.bt.getPage(ovfl_pgno, .{});
            defer cur.bt.pager.unref(op.db_page);
            if (op.db_page.n_ref != 1 or op.is_init) return corrupt(@src());
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
        std.debug.assert(opts.preformat or (x.key == null) == (cur.key_info == null));
        std.debug.assert(!opts.preformat or seek != null or cur.key_info == null);

        if (cur.flags.multiple) {
            try bt.saveAllCursors(cur.pgno_root, cur);
            // Only possible if two b-trees share a root in a corrupt schema.
            if (seek != null and cur.i_page < 0) return corrupt(@src());
        }
        // An insert into a table b-tree invalidates the incremental blob
        // cursors on the row it replaces.
        if (cur.key_info == null and bt.has_incrblob_cur) bt.invalidateIncrblobCursors(cur.pgno_root, n_key, false);
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
                    return cur.overwriteCell(.{ .data = x.key orelse &.{} });
                }
            }
        }
        // Where the cursor is relative to the new entry. Without a seek it
        // is on the entry being replaced.
        const loc = seek orelse .eq;
        std.debug.assert(cur.state == .valid or (cur.state == .invalid and loc != .eq));

        const pg = cur.page;
        if (pg.n_free < 0) {
            if (cur.state.atLeast(.skipnext)) return corrupt(@src());
            try pg.computeFreeSpace();
        }
        const new_cell = bt.tmpCell();
        var sz_new: u32 = undefined;
        if (opts.preformat) {
            sz_new = bt.n_preformat_size;
            if (sz_new < 4) {
                sz_new = 4;
                new_cell[3] = 0;
            }
            if (bt.isAutoVacuum() and sz_new > pg.max_local) {
                const info = pg.parseCell(new_cell);
                if (info.n_payload != info.n_local) {
                    try ptrmap.put(bt, get4(new_cell + sz_new - 4), .overflow1, pg.pgno);
                }
            }
        } else {
            sz_new = try bt.fillInCell(pg, new_cell, x);
        }
        var idx: usize = cur.ix;
        cur.info.n_size = 0;
        if (loc == .eq) {
            if (idx >= pg.n_cell) return corrupt(@src());
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
                if (@intFromPtr(old_cell) < @intFromPtr(pg.data + pg.hdr_offset + 10)) return corrupt(@src());
                if (@intFromPtr(old_cell) + sz_new > @intFromPtr(pg.data_end)) return corrupt(@src());
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

    /// Port of sqlite3BtreeTransferRow(): copy the entry of `src` into a
    /// cell for `dest`, with rowid `key` for tables, overflow pages and
    /// all. The cell is left in the scratch space of dest's b-tree, for
    /// an insert() with `preformat` to finish. `dest` must be positioned
    /// (on a page).
    pub fn transferRow(dest: *Cursor, src: *Cursor, key: i64) Error!void {
        const bt = dest.bt;
        const start = bt.tmpCell();
        var out = start;
        src.getCellInfo();
        const n_payload = src.info.n_payload;
        if (n_payload < 0x80) {
            out[0] = @intCast(n_payload);
            out += 1;
        } else {
            out += varint.put(out[0..9], n_payload);
        }
        if (dest.key_info == null) out += varint.put(out[0..9], @bitCast(key));
        var n_in: u32 = src.info.n_local;
        var in: [*]const u8 = src.info.payload;
        if (@intFromPtr(in) + n_in > @intFromPtr(src.page.data_end)) return corrupt(@src());
        var n_rem = n_payload;
        if (n_in == n_rem and n_in < dest.page.max_local) {
            @memcpy(out[0..n_in], in[0..n_in]);
            bt.n_preformat_size = n_in + @as(u32, @intCast(out - start));
            return;
        }

        const src_pager = src.bt.pager;
        var pgno_out: ?[*]u8 = null;
        var ovfl_in: Pgno = 0;
        var page_in: ?*pager_mod.Page = null;
        var page_out: ?*MemPage = null;
        defer {
            if (page_out) |po| releasePage(po);
            if (page_in) |pi| src_pager.unref(pi);
        }
        var n_out: u32 = dest.page.payloadToLocal(n_payload);
        bt.n_preformat_size = n_out + @as(u32, @intCast(out - start));
        if (n_out < n_payload) {
            pgno_out = out + n_out;
            bt.n_preformat_size += 4;
        }
        if (n_rem > n_in) {
            if (@intFromPtr(in) + n_in + 4 > @intFromPtr(src.page.data_end)) return corrupt(@src());
            ovfl_in = get4(src.info.payload + n_in);
        }
        while (true) {
            n_rem -= n_out;
            while (true) {
                std.debug.assert(n_out > 0);
                if (n_in > 0) {
                    const n_copy = @min(n_out, n_in);
                    // In a corrupt file the source chain may run through the
                    // page being filled (C copies with memcpy() regardless).
                    @memmove(out[0..n_copy], in[0..n_copy]);
                    n_out -= n_copy;
                    n_in -= n_copy;
                    out += n_copy;
                    in += n_copy;
                }
                if (n_out > 0) {
                    if (page_in) |pi| src_pager.unref(pi);
                    page_in = null;
                    const pi = try src_pager.get(ovfl_in, .{});
                    page_in = pi;
                    in = pi.data.ptr;
                    ovfl_in = get4(in);
                    in += 4;
                    n_in = src.bt.usable_size - 4;
                }
                if (n_out == 0) break;
            }
            if (n_rem > 0) {
                const po_ptr = pgno_out orelse return corrupt(@src());
                const new = try bt.allocatePage(0, .any);
                put4(po_ptr, new.pgno);
                if (bt.isAutoVacuum()) if (page_out) |po| {
                    ptrmap.put(bt, new.pgno, .overflow2, po.pgno) catch |err| {
                        releasePage(new);
                        return err;
                    };
                };
                if (page_out) |po| releasePage(po);
                page_out = new;
                pgno_out = new.data;
                put4(new.data, 0);
                out = new.data + 4;
                n_out = @min(bt.usable_size - 4, n_rem);
            }
            if (n_rem == 0) break;
        }
    }

    /// Port of sqlite3BtreeDelete(): delete the current entry.
    pub fn delete(cur: *Cursor, opts: DeleteOptions) Error!void {
        const bt = cur.bt;
        std.debug.assert(bt.in_trans == .write and !bt.read_only and cur.flags.write);
        if (cur.state != .valid) {
            if (!cur.state.atLeast(.requireseek)) return corrupt(@src());
            try cur.restorePosition();
            if (cur.state != .valid) return;
        }

        const cell_depth = cur.i_page;
        const cell_idx = cur.ix;
        const pg = cur.page;
        if (pg.n_cell <= cell_idx) return corrupt(@src());
        var cell = pg.findCell(cell_idx);
        if (pg.n_free < 0) pg.computeFreeSpace() catch return corrupt(@src());
        if (@intFromPtr(cell) < @intFromPtr(pg.cell_idx + pg.n_cell)) return corrupt(@src());

        // With save_position: if deleting will not rebalance, the cursor can
        // stay put (skipnext); otherwise save the key (requireseek).
        const preserve: enum { none, save_key, stay } = if (!opts.save_position)
            .none
        else if (!pg.leaf or @as(i64, pg.n_free) + pg.cellSize(cell) + 2 > bt.usable_size * 2 / 3 or pg.n_cell == 1)
            .save_key
        else
            .stay;
        if (preserve == .save_key) try cur.saveKey();
        // Deleting a row of a table b-tree invalidates the incremental
        // blob cursors on it.
        if (cur.key_info == null and bt.has_incrblob_cur) {
            cur.getCellInfo();
            bt.invalidateIncrblobCursors(cur.pgno_root, cur.info.n_key, false);
        }

        // An entry on an interior page is replaced by its predecessor, the
        // largest entry in its left subtree, which makes balancing easier.
        if (!pg.leaf) {
            if (!try cur.previous()) return corrupt(@src());
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
            if (@intFromPtr(cell) < @intFromPtr(leaf.data + 4)) return corrupt(@src());
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
