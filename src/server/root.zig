//! xqlite_server: the parts of the wire protocol servers (PostgreSQL's
//! v3, MySQL's, TDS) that do not depend on the protocol. A protocol reads
//! its client's messages and writes its own; this module gives it the
//! rest:
//!
//! - Server: listen, a task per client, the connection limit, shutdown.
//! - Session: a client's connection to the database in the client's
//!   dialect; runs scripts and reports columns, rows, completions and
//!   failures as events; transaction status.
//! - Registry: the sessions by id, for cancel requests from outside.
//! - errors: the SQLSTATE of an engine error.
//! - command: what a statement does, for command tags and row counts.
//!
//! It is built on the Zig API (module `xqlite`) only, so that the engine
//! library has no networking. See docs/server.md.

pub const Server = @import("Server.zig").Server;
pub const Config = @import("Server.zig").Config;
pub const Connection = @import("Server.zig").Connection;
pub const SessionOptions = @import("Server.zig").SessionOptions;
pub const Session = @import("Session.zig");
pub const Registry = @import("Registry.zig");
pub const errors = @import("errors.zig");
pub const command = @import("command.zig");

test {
    _ = errors;
    _ = command;
    _ = Session;
    _ = Registry;
    _ = @import("Server.zig");
    _ = @import("test.zig");
}
