//! The root of the xqlite loadable extension (`zig build ext`,
//! libxqlite_ext.so or .dylib): see src/loadable/root.zig and
//! docs/extension.md. It is here, beside capi.zig, so that the files it
//! uses are inside its module; it exports only the entry points of
//! src/loadable/entry.c.

comptime {
    _ = @import("loadable/root.zig");
}

test {
    _ = @import("loadable/root.zig");
}
