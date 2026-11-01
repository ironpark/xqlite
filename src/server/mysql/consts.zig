//! The numbers of the MySQL client/server protocol (MariaDB's
//! include/mysql_com.h): capability and status flags, commands, column
//! types and flags, character sets.

/// Capability flags (CLIENT_*).
pub const Cap = struct {
    /// CLIENT_LONG_PASSWORD, which MariaDB servers clear (CLIENT_MYSQL)
    /// to say that the handshake carries MariaDB's extended capabilities.
    pub const mysql: u32 = 1;
    pub const found_rows: u32 = 2;
    pub const long_flag: u32 = 4;
    pub const connect_with_db: u32 = 8;
    pub const no_schema: u32 = 16;
    pub const compress: u32 = 32;
    pub const odbc: u32 = 64;
    pub const local_files: u32 = 128;
    pub const ignore_space: u32 = 256;
    pub const protocol_41: u32 = 512;
    pub const interactive: u32 = 1024;
    pub const ssl: u32 = 2048;
    pub const transactions: u32 = 8192;
    pub const secure_connection: u32 = 32768;
    pub const multi_statements: u32 = 1 << 16;
    pub const multi_results: u32 = 1 << 17;
    pub const ps_multi_results: u32 = 1 << 18;
    pub const plugin_auth: u32 = 1 << 19;
    pub const connect_attrs: u32 = 1 << 20;
    pub const plugin_auth_lenenc_client_data: u32 = 1 << 21;
    pub const session_track: u32 = 1 << 23;
    pub const deprecate_eof: u32 = 1 << 24;
};

/// What the server offers. Not SSL, LOCAL INFILE, compression, session
/// tracking or query attributes.
pub const server_caps: u32 = Cap.mysql | Cap.found_rows | Cap.long_flag | Cap.connect_with_db |
    Cap.protocol_41 | Cap.interactive | Cap.transactions | Cap.secure_connection |
    Cap.multi_statements | Cap.multi_results | Cap.ps_multi_results | Cap.plugin_auth |
    Cap.connect_attrs | Cap.plugin_auth_lenenc_client_data | Cap.deprecate_eof;

/// Server status flags (SERVER_STATUS_*).
pub const Status = struct {
    pub const in_trans: u16 = 1;
    pub const autocommit: u16 = 2;
    pub const more_results_exists: u16 = 8;
    pub const no_backslash_escapes: u16 = 512;
};

/// Commands (COM_*).
pub const Com = enum(u8) {
    sleep = 0x00,
    quit = 0x01,
    init_db = 0x02,
    query = 0x03,
    field_list = 0x04,
    create_db = 0x05,
    drop_db = 0x06,
    refresh = 0x07,
    shutdown = 0x08,
    statistics = 0x09,
    process_info = 0x0A,
    connect = 0x0B,
    process_kill = 0x0C,
    debug = 0x0D,
    ping = 0x0E,
    change_user = 0x11,
    stmt_prepare = 0x16,
    stmt_execute = 0x17,
    stmt_send_long_data = 0x18,
    stmt_close = 0x19,
    stmt_reset = 0x1A,
    set_option = 0x1B,
    stmt_fetch = 0x1C,
    reset_connection = 0x1F,
    _,
};

/// Column types (MYSQL_TYPE_*).
pub const Type = enum(u8) {
    decimal = 0,
    tiny = 1,
    short = 2,
    long = 3,
    float = 4,
    double = 5,
    null = 6,
    timestamp = 7,
    longlong = 8,
    int24 = 9,
    date = 10,
    time = 11,
    datetime = 12,
    year = 13,
    newdate = 14,
    varchar = 15,
    bit = 16,
    json = 245,
    newdecimal = 246,
    @"enum" = 247,
    set = 248,
    tiny_blob = 249,
    medium_blob = 250,
    long_blob = 251,
    blob = 252,
    var_string = 253,
    string = 254,
    geometry = 255,
    _,
};

/// Column flags (*_FLAG).
pub const Flag = struct {
    pub const not_null: u16 = 1;
    pub const pri_key: u16 = 2;
    pub const unique_key: u16 = 4;
    pub const multiple_key: u16 = 8;
    pub const blob: u16 = 16;
    pub const unsigned: u16 = 32;
    pub const zerofill: u16 = 64;
    pub const binary: u16 = 128;
    pub const @"enum": u16 = 256;
    pub const auto_increment: u16 = 512;
    pub const timestamp: u16 = 1024;
    pub const set: u16 = 2048;
    pub const num: u16 = 32768;
};

/// Character sets (collation ids).
pub const Charset = struct {
    /// utf8mb4_general_ci: the server's, and that of every text column.
    pub const utf8mb4: u16 = 45;
    /// binary: numbers, dates and byte strings.
    pub const binary: u16 = 63;
};

/// The decimals of a floating-point column without a fixed scale
/// (NOT_FIXED_DEC).
pub const not_fixed_dec: u8 = 31;

/// The header bytes of the generic responses.
pub const ok_header: u8 = 0x00;
pub const eof_header: u8 = 0xFE;
pub const err_header: u8 = 0xFF;
/// The value of a NULL column in a text row.
pub const null_value: u8 = 0xFB;

/// COM_STMT_EXECUTE: the flag of an unsigned parameter type.
pub const unsigned_param: u8 = 0x80;
