//! The MySQL/MariaDB client/server protocol (handshake v10,
//! mysql_native_password, COM_QUERY with text result sets, the prepared
//! statements of the binary protocol), for Server(mysql.Protocol). See
//! Protocol.zig for how to run it and docs/server.md ("MySQL 프로토콜")
//! for what it covers.

pub const Protocol = @import("Protocol.zig");
pub const consts = @import("consts.zig");
pub const packet = @import("packet.zig");
pub const auth = @import("auth.zig");
pub const columns = @import("columns.zig");
pub const errors = @import("errors.zig");
pub const prepared = @import("prepared.zig");

test {
    _ = packet;
    _ = auth;
    _ = columns;
    _ = errors;
    _ = prepared;
    _ = @import("Handler.zig");
    _ = @import("test.zig");
}
