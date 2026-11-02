//! PostgreSQL's frontend/backend protocol, version 3.0, for
//! Server(Protocol): psql, libpq and the drivers talk to the server's
//! database in the PostgreSQL dialect.
//!
//!     var pg_protocol: pg.Protocol = .init(io, .{ .auth = .{ .method = .@"scram-sha-256", .password = pw } });
//!     var srv = try server.Server(pg.Protocol).init(io, gpa, &pg_protocol, .{ .address = addr, .path = "app.db" });
//!
//! - Startup: SSLRequest and GSSENCRequest are refused ('N': the client
//!   goes on in the clear), CancelRequest cancels by the BackendKeyData
//!   (Registry.cancel()), the StartupMessage's user, database (any name,
//!   or Config.database), application_name and options (`-c name=value`,
//!   run as SET).
//! - Authentication: trust, cleartext password, MD5, SCRAM-SHA-256
//!   (auth.zig).
//! - Simple query: a script of statements (Session.run()), RowDescription,
//!   DataRow in the text format, CommandComplete, EmptyQueryResponse,
//!   ErrorResponse and NoticeResponse.
//! - Extended query: Parse (named and unnamed statements), Bind (portals,
//!   text parameters and binary ones of the common types), Describe
//!   (the parameter and result types before the statement runs), Execute
//!   with a row limit (PortalSuspended), Close, Flush, Sync; after an
//!   error the messages up to Sync are skipped.
//! - COPY and the function call protocol are not supported (an error).
//!
//! See docs/server.md ("PostgreSQL 프로토콜").

const std = @import("std");
const Connection = @import("../root.zig").Connection;

pub const auth = @import("auth.zig");
pub const values = @import("values.zig");
pub const wire = @import("wire.zig");
const Backend = @import("Backend.zig");

pub const Config = struct {
    auth: auth.Config = .{},
    /// The database name clients must give; null: any (the server serves
    /// its one file whatever the name).
    database: ?[]const u8 = null,
    /// The version reported (ParameterStatus server_version), as the
    /// dialect's SHOW server_version and version() say (a test compares).
    server_version: []const u8 = "16.15 (xqlite)",
};

pub const Protocol = struct {
    config: Config,
    /// SCRAM's keys of the password, derived once.
    scram: auth.ScramSecret,

    /// SCRAM's PBKDF2 runs here, with a random salt (4096 iterations,
    /// PostgreSQL's default).
    pub fn init(io: std.Io, config: Config) Protocol {
        var salt: [16]u8 = undefined;
        io.random(&salt);
        return .{
            .config = config,
            .scram = if (config.auth.method == .@"scram-sha-256") .init(config.auth.password, salt, 4096) else undefined,
        };
    }

    pub fn serve(p: *Protocol, c: *Connection) !void {
        return Backend.serve(p, c);
    }
};

test {
    _ = auth;
    _ = values;
    _ = wire;
    _ = Backend;
    _ = @import("test.zig");
}
