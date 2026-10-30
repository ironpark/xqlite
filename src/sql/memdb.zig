//! The engine's memdb VFS: the VFS package's memdb (pkg/vfs/src/memdb.zig) on
//! the library allocator (sqlite3_malloc(), sql/malloc.zig), so that its
//! stores count in sqlite3_status() and toward the heap limits, as
//! memdb.c's do. sqlite3_deserialize() (sql/serialize.zig), ATTACH's
//! temporary databases (sql/attach.zig) and the C ABI's "memdb" VFS
//! (capi/vfs.zig) all use this one instance and its shared stores.

const memdb = @import("xqlite_vfs").memdb;
const Instance = memdb.Memdb(@import("malloc.zig"));

pub const FREEONCLOSE = memdb.FREEONCLOSE;
pub const RESIZEABLE = memdb.RESIZEABLE;
pub const READONLY = memdb.READONLY;

pub const Store = Instance.Store;
pub const MemFile = Instance.MemFile;
/// The process-wide state: the shared stores, the lower VFS and
/// SQLITE_CONFIG_MEMDB_MAXSIZE.
pub const state = &Instance.state;
pub const interface = Instance.interface;
pub const isMemdb = Instance.isMemdb;
pub const fileOf = Instance.fileOf;
pub const sizeLimit = Instance.sizeLimit;
pub const describe = Instance.describe;
pub const separateStore = Instance.separateStore;
