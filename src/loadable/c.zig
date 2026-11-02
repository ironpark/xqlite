//! The C side of the extension (entry.c), as the Zig adapter calls it:
//! sqlite3's types are opaque here, and every call goes through the
//! sqlite3_api_routines table the loader handed to the entry point.

pub const sqlite3 = opaque {};
pub const sqlite3_context = opaque {};
pub const sqlite3_value = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK = 0;
pub const SQLITE_ERROR = 1;
pub const SQLITE_NOMEM = 7;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;

pub const SQLITE_INTEGER = 1;
pub const SQLITE_FLOAT = 2;
pub const SQLITE_TEXT = 3;
pub const SQLITE_BLOB = 4;
pub const SQLITE_NULL = 5;

pub const SQLITE_UTF8 = 1;
pub const SQLITE_DETERMINISTIC = 0x000000800;
pub const SQLITE_DIRECTONLY = 0x000080000;
pub const SQLITE_SUBTYPE = 0x000100000;
pub const SQLITE_INNOCUOUS = 0x000200000;
pub const SQLITE_RESULT_SUBTYPE = 0x001000000;

pub const StepFn = *const fn (?*sqlite3_context, c_int, ?[*]?*sqlite3_value) callconv(.c) void;
pub const FinalFn = *const fn (?*sqlite3_context) callconv(.c) void;
pub const CmpFn = *const fn (?*anyopaque, c_int, ?*const anyopaque, c_int, ?*const anyopaque) callconv(.c) c_int;
pub const DestroyFn = *const fn (?*anyopaque) callconv(.c) void;

pub extern fn xqe_value_type(v: *sqlite3_value) c_int;
pub extern fn xqe_value_int64(v: *sqlite3_value) i64;
pub extern fn xqe_value_double(v: *sqlite3_value) f64;
pub extern fn xqe_value_text(v: *sqlite3_value) ?[*]const u8;
pub extern fn xqe_value_blob(v: *sqlite3_value) ?*const anyopaque;
pub extern fn xqe_value_bytes(v: *sqlite3_value) c_int;
pub extern fn xqe_value_subtype(v: *sqlite3_value) c_uint;

pub extern fn xqe_result_null(ctx: *sqlite3_context) void;
pub extern fn xqe_result_int64(ctx: *sqlite3_context, v: i64) void;
pub extern fn xqe_result_double(ctx: *sqlite3_context, v: f64) void;
pub extern fn xqe_result_text(ctx: *sqlite3_context, z: [*]const u8, n: u64) void;
pub extern fn xqe_result_blob(ctx: *sqlite3_context, z: [*]const u8, n: u64) void;
pub extern fn xqe_result_zeroblob(ctx: *sqlite3_context, n: u64) void;
pub extern fn xqe_result_subtype(ctx: *sqlite3_context, t: c_uint) void;
pub extern fn xqe_result_error(ctx: *sqlite3_context, z: [*]const u8, n: c_int) void;
pub extern fn xqe_result_error_code(ctx: *sqlite3_context, rc: c_int) void;
pub extern fn xqe_result_error_nomem(ctx: *sqlite3_context) void;
pub extern fn xqe_result_error_toobig(ctx: *sqlite3_context) void;

pub extern fn xqe_user_data(ctx: *sqlite3_context) ?*anyopaque;
pub extern fn xqe_aggregate_context(ctx: *sqlite3_context, n: c_int) ?*anyopaque;
pub extern fn xqe_context_db_handle(ctx: *sqlite3_context) *sqlite3;

pub extern fn xqe_create_function(db: *sqlite3, name: [*:0]const u8, n_arg: c_int, flags: c_int, app: ?*anyopaque, x_func: ?StepFn, x_step: ?StepFn, x_final: ?FinalFn, x_destroy: ?DestroyFn) c_int;
pub extern fn xqe_create_window_function(db: *sqlite3, name: [*:0]const u8, n_arg: c_int, flags: c_int, app: ?*anyopaque, x_step: StepFn, x_final: FinalFn, x_value: FinalFn, x_inverse: StepFn, x_destroy: ?DestroyFn) c_int;
pub extern fn xqe_create_collation(db: *sqlite3, name: [*:0]const u8, arg: ?*anyopaque, x_cmp: CmpFn) c_int;
pub extern fn xqe_libversion_number() c_int;
pub extern fn xqe_errmsg(db: *sqlite3) [*:0]const u8;
pub extern fn xqe_set_errmsg(pz: ?*?[*:0]u8, z: [*:0]const u8) void;

pub extern fn xqe_prepare(db: *sqlite3, sql: [*]const u8, n: c_int, out: *?*sqlite3_stmt) c_int;
pub extern fn xqe_step(s: *sqlite3_stmt) c_int;
pub extern fn xqe_finalize(s: *sqlite3_stmt) c_int;
pub extern fn xqe_bind_text(s: *sqlite3_stmt, i: c_int, z: [*]const u8, n: c_int) c_int;
pub extern fn xqe_bind_int64(s: *sqlite3_stmt, i: c_int, v: i64) c_int;
pub extern fn xqe_column_int64(s: *sqlite3_stmt, i: c_int) i64;
