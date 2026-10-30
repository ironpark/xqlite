//! A dialect left out of the build (`zig build -Ddialects=...`): no
//! hooks, and a frontend that fails every statement. The dialect's name
//! is still known, so that PRAGMA xq_dialect and the other ways to
//! choose it can say that it is not built in.

const int = @import("../sql/sqlite_int.zig");
const util = @import("../sql/util.zig");
const dialect = @import("dialect.zig");

pub fn Disabled(comptime d: dialect.Dialect) type {
    return struct {
        pub const frontend: dialect.Frontend = .{ .run = run };
        pub const hooks: dialect.Hooks = .{};

        fn run(p: *int.Parse, sql: [:0]const u8) (int.Oom || int.ParseError)!void {
            _ = sql;
            util.errorMsg(p, "{s}", .{dialect.not_built_message[@backingInt(d)]});
            return error.ParseFailed;
        }
    };
}
