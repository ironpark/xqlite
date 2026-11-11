//! `patch_test1 IN OUT`: SQLite's src/test1.c with the few places that
//! read SQLite's own structures rewritten to the public API, for the TCL
//! test harness (tools/tcl/README.md). Every replacement must match at
//! least once, so a different test1.c fails the build instead of
//! compiling into a fixture that reads the wrong memory.
//!
//! The commands whose whole body reads internals (uses_stmt_journal,
//! sqlite3_pager_refcounts) are replaced at run time by xqtclTestInit in
//! shim.c instead.

const std = @import("std");

const Replacement = struct { from: []const u8, to: []const u8 };

const replacements = [_]Replacement{
    // db_enter, db_leave, sqlite3_create_function, test_collate.
    .{ .from = "sqlite3_mutex_enter(db->mutex)", .to = "sqlite3_mutex_enter(sqlite3_db_mutex(db))" },
    .{ .from = "sqlite3_mutex_leave(db->mutex)", .to = "sqlite3_mutex_leave(sqlite3_db_mutex(db))" },
    .{ .from = "db->mallocFailed", .to = "0" },
    // The UTF conversions through sqlite3ValueNew(): shim.c's values,
    // which the library never sees.
    .{ .from = "sqlite3_value_bytes(pVal)", .to = "xqtcl_value_bytes(pVal)" },
    .{ .from = "sqlite3_value_text(pVal)", .to = "xqtcl_value_text(pVal)" },
    .{ .from = "sqlite3_value_text16be(pVal)", .to = "xqtcl_value_text16be(pVal)" },
    .{ .from = "sqlite3_value_text16le(pVal)", .to = "xqtcl_value_text16le(pVal)" },
    // test_collate_needed_cb reads Sqlite3.enc (ENC(db)), which the
    // callback is passed as eTextRep (callCollNeeded()).
    .{ .from = "int enc = ENC(db);", .to = "int enc = eTextRep;" },
    .{ .from = "db, \"test_collate\", ENC(db), SQLITE_INT_TO_PTR(enc)", .to = "db, \"test_collate\", eTextRep, SQLITE_INT_TO_PTR(enc)" },
    // sqlite3_stmt_scanstatus -debug reads Vdbe.aScan.
    .{
        .from = "ScanStatus *pScan = &((Vdbe*)pStmt)->aScan[idx];",
        .to = "ScanStatus *pScan = 0; Tcl_SetResult(interp, \"xqlite tcl harness: -debug needs SQLite internals\", TCL_STATIC); return TCL_ERROR;",
    },
};

const prologue =
    \\/* Patched by tools/tcl/patch_test1.zig for the xqlite TCL harness. */
    \\int xqtcl_value_bytes(void*);
    \\const unsigned char *xqtcl_value_text(void*);
    \\const void *xqtcl_value_text16be(void*);
    \\const void *xqtcl_value_text16le(void*);
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: patch_test1 IN OUT\n", .{});
        std.process.exit(2);
    }
    var text: []const u8 = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(16 << 20));
    for (replacements) |r| {
        if (std.mem.indexOf(u8, text, r.from) == null) {
            std.debug.print("patch_test1: {s}: not found: {s}\n", .{ args[1], r.from });
            std.process.exit(1);
        }
        text = try std.mem.replaceOwned(u8, arena, text, r.from, r.to);
    }
    const out = try std.mem.concat(arena, u8, &.{ prologue, text });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out });
}
