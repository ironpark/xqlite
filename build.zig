const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("xqlite", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        // libc provides fcntl() byte-range locks for the unix VFS (and
        // wasi-libc the clock and localtime_r() on wasm32-wasi);
        // wasm32-freestanding has none (src/util/platform.zig).
        .link_libc = target.result.os.tag != .freestanding,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "xqlite",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "xqlite" is the name you will use in your source code to
                // import this module (e.g. `@import("xqlite")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "xqlite", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this text") orelse &.{};
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Example programs of the Zig API (examples/*.zig): `zig build
    // example-<name>` runs one (arguments after `--`), `zig build examples`
    // builds them all.
    const examples_step = b.step("examples", "Build the example programs");
    inline for (.{ "basic", "extensions" }) |name| {
        const example = b.addExecutable(.{
            .name = "example-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "xqlite", .module = mod }},
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
        const run_example = b.addRunArtifact(example);
        run_example.addPassthruArgs();
        b.step("example-" ++ name, "Run examples/" ++ name ++ ".zig").dependOn(&run_example.step);
    }

    // The sqlite3-compatible C ABI (src/capi.zig): libxqlite3, its header
    // and its tests. See addCapi() and docs/c-api.md.
    const capi_test_step = addCapi(b, target, optimize);
    // `zig build wasm`: the WebAssembly module for JavaScript hosts
    // (src/wasm/api.zig, wasm32-freestanding, no libc) in zig-out/wasm,
    // whatever -Dtarget is; ReleaseSmall unless -Dwasm-optimize says
    // otherwise. `zig build wasm-example` runs examples/wasm/node.mjs
    // with it. docs/wasm.md.
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "zig build wasm: optimization mode (default small)") orelse .small;
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_lib = b.addExecutable(.{
        .name = "xqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm/api.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{.{ .name = "xqlite", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = wasm_target,
                .optimize = wasm_optimize,
            }) }},
        }),
    });
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm_lib, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } });
    b.step("wasm", "Build the WebAssembly module for JavaScript hosts (zig-out/wasm/xqlite.wasm)").dependOn(&install_wasm.step);
    const run_wasm_example = b.addSystemCommand(&.{"node"});
    run_wasm_example.addFileArg(b.path("examples/wasm/node.mjs"));
    run_wasm_example.addArtifactArg(wasm_lib);
    run_wasm_example.has_side_effects = true;
    b.step("wasm-example", "Run examples/wasm/node.mjs (Node.js) with the WebAssembly module").dependOn(&run_wasm_example.step);

    // `zig build test` also checks that the names docs/zig-api.md and the
    // examples use exist in the module, as its users see it.
    const doc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("docs/names_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "xqlite", .module = mod }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(doc_tests).step);

    // ... and that src/ and tools/xqt keep no mutable globals but the few
    // it lists.
    // The seeded fuzzers (src/fuzz_tests.zig): `zig build fuzz -- NAME
    // [SEED]` runs one. Their smoke test runs with the module's tests
    // (src/root.zig), which import the same files.
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const fuzz_exe = b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_module });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.addPassthruArgs();
    b.step("fuzz", "Run a seeded fuzzer (zig build fuzz -- NAME [SEED])").dependOn(&run_fuzz.step);

    const globals_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/globals_test.zig"),
            .target = target,
            // It runs every time (see below); optimized, that takes 30ms.
            .optimize = .ReleaseFast,
        }),
    });
    const run_globals_tests = b.addRunArtifact(globals_tests);
    run_globals_tests.setCwd(b.path("."));
    // It reads src/ at run time, which the cache does not see.
    run_globals_tests.has_side_effects = true;
    test_step.dependOn(&run_globals_tests.step);
    test_step.dependOn(examples_step);

    // The journal's checksums once more, optimized: Zig 0.17 compiled one
    // of them wrong in optimized builds only (see superNameChecksum() in
    // src/pager/journal.zig), which the Debug tests above cannot see.
    const journal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/pager/journal.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(journal_tests).step);

    // The test tool (tools/xqt): `zig build tools` installs xqt next to
    // xqlite, and tools/crashshim.c as a library to preload into sqlite3.
    // Neither is part of the library or of `zig build test`.
    const xqt_options = b.addOptions();
    xqt_options.addOption([]const u8, "root", b.root.toString(b.allocator) catch @panic("OOM"));
    const xqt_lib = b.createModule(.{
        .root_source_file = b.path("tools/xqt/lib/xqt.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const xqt_exe = b.addExecutable(.{
        .name = "xqt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/xqt/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "xqt", .module = xqt_lib },
                .{ .name = "build_options", .module = xqt_options.createModule() },
            },
        }),
    });
    const crashshim = b.addLibrary(.{
        .name = "crashshim",
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseSafe, .link_libc = true }),
    });
    crashshim.root_module.addCSourceFile(.{ .file = b.path("tools/crashshim.c") });
    if (target.result.os.tag == .linux) crashshim.root_module.linkSystemLibrary("dl", .{});
    const tools_step = b.step("tools", "Build xqt and the crash shim of the cross-checks (tools/xqt)");
    tools_step.dependOn(b.getInstallStep());
    tools_step.dependOn(&b.addInstallArtifact(xqt_exe, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(crashshim, .{}).step);

    // `zig build test-wasi`: the unit tests (module and CLI) built for
    // wasm32-wasi and run under wasmtime, then `xqt wasi`, which runs an
    // xqlite built for wasm32-wasi (ReleaseSafe) against sqlite3 and this
    // native build. Needs wasmtime on PATH. docs/wasm.md.
    const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const wasi_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasi_target,
        .optimize = optimize,
        .link_libc = true,
    });
    const wasi_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasi_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "xqlite", .module = wasi_mod }},
    });
    const wasi_safe_exe = b.addExecutable(.{
        .name = "xqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasi_target,
            .optimize = .safe,
            .imports = &.{.{ .name = "xqlite", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = wasi_target,
                .optimize = .safe,
                .link_libc = true,
            }) }},
        }),
    });
    const test_wasi_step = b.step("test-wasi", "Run the unit tests and `xqt wasi` on wasm32-wasi under wasmtime");
    for ([_]*std.Build.Step.Compile{
        b.addTest(.{ .root_module = wasi_mod, .filters = test_filters }),
        b.addTest(.{ .root_module = wasi_exe_mod, .filters = test_filters }),
    }) |t| {
        const run = b.addSystemCommand(&.{ "wasmtime", "run", "--dir", "." });
        run.addArtifactArg(t);
        // The tests make their temporary directories under .zig-cache/tmp.
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        test_wasi_step.dependOn(&run.step);
    }
    const wasi_run = addXqtRun(b, xqt_exe, exe, crashshim);
    wasi_run.addArgs(&.{ "wasi", "--wasm" });
    wasi_run.addArtifactArg(wasi_safe_exe);
    test_wasi_step.dependOn(&wasi_run.step);

    // `zig build check`: everything at once, in parallel. The unit tests,
    // every `xqt interop` module, every planner case file but vtablog.txt
    // and fuzzcheck on SQLite's corpora; -Dslt=true adds sqllogictest
    // (ref/sqllogictest), -Dfuzz=true a run of each seeded fuzzer with a
    // random seed. A new interop module needs no change here.
    const check_slt = b.option(bool, "slt", "zig build check: also run sqllogictest (minutes)") orelse false;
    const check_fuzz = b.option(bool, "fuzz", "zig build check: also run each seeded fuzzer with a random seed") orelse false;
    const check_step = b.step("check", "Run the unit tests, the cross-checks, the planner cases and fuzzcheck (-Dslt, -Dfuzz for more)");
    check_step.dependOn(test_step);
    check_step.dependOn(capi_test_step);
    check_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xqt_exe.root_module })).step);
    const interop_run = addXqtRun(b, xqt_exe, exe, crashshim);
    interop_run.addArg("interop");
    check_step.dependOn(&interop_run.step);
    const planner_run = addXqtRun(b, xqt_exe, exe, crashshim);
    planner_run.addArgs(&.{ "planner", "--known" });
    planner_run.addFileArg(b.path("tools/planner/known-failures.list"));
    check_step.dependOn(&planner_run.step);
    // The long runs (sqllogictest, fuzzcheck, the fuzzers) use a ReleaseSafe
    // build whatever -Doptimize is: safety checks on, minutes not hours.
    // The cross-checks and the planner use the build asked for.
    const safe_exe = if (optimize == .safe) exe else b.addExecutable(.{
        .name = "xqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "xqlite", .module = mod }},
        }),
    });
    if (check_slt) {
        const slt_run = addXqtRun(b, xqt_exe, safe_exe, crashshim);
        slt_run.addArg("slt");
        slt_run.addDirectoryArg(b.path("ref/sqllogictest/test"));
        check_step.dependOn(&slt_run.step);
    }
    // SQLite's corpora (`xqt fetch sqlite`), one process each.
    for (1..9) |i| {
        const run_fuzzcheck = b.addRunArtifact(safe_exe);
        run_fuzzcheck.addArg("fuzzcheck");
        run_fuzzcheck.addFileArg(b.path(b.fmt("ref/sqlite/test/fuzzdata{d}.db", .{i})));
        run_fuzzcheck.has_side_effects = true;
        check_step.dependOn(&run_fuzzcheck.step);
    }
    if (check_fuzz) {
        const safe_fuzz = if (optimize == .safe) fuzz_exe else b.addExecutable(.{
            .name = "fuzz",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/fuzz_tests.zig"),
                .target = target,
                .optimize = .ReleaseSafe,
                .link_libc = true,
            }),
        });
        for ([_][]const u8{ "btree_model", "btree_corrupt", "ir_roundtrip" }) |name| {
            const run = b.addRunArtifact(safe_fuzz);
            run.addArg(name);
            run.has_side_effects = true;
            check_step.dependOn(&run.step);
        }
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// The C ABI: `zig build` installs libxqlite3 (static and shared) in
/// zig-out/lib, sqlite3.h and xqlite.h in zig-out/include and a
/// pkg-config file. `-Dcapi-name=sqlite3` names the libraries libsqlite3
/// (a drop-in replacement), `-Dcapi=false` skips them. `zig build
/// test-capi` runs tools/capi/capi_test.c against both libraries;
/// `zig build capi-shell` builds SQLite's own shell (shell.c of the
/// amalgamation, -Dsqlite-shell-c) on libxqlite3 and runs a smoke
/// script. Returns the test-capi step.
fn addCapi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const enabled = b.option(bool, "capi", "Build and install the C libraries (libxqlite3) with `zig build` (default: true)") orelse true;
    const name = b.option([]const u8, "capi-name", "Base name of the C libraries: lib<name>.a, lib<name>.so/.dylib (default: xqlite3; sqlite3 for a drop-in libsqlite3)") orelse "xqlite3";
    const shell_c = b.option([]const u8, "sqlite-shell-c", "shell.c of the SQLite 3.54.1 amalgamation, for `zig build capi-shell` (default: /tmp/xq-sqlite-build/shell.c)") orelse "/tmp/xq-sqlite-build/shell.c";

    const make = struct {
        fn lib(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, n: []const u8, linkage: std.builtin.LinkMode) *std.Build.Step.Compile {
            const m = bb.createModule(.{
                .root_source_file = bb.path("src/capi.zig"),
                .target = t,
                .optimize = o,
                .link_libc = true,
                .pic = true,
            });
            m.addIncludePath(bb.path("include"));
            m.addCSourceFile(.{ .file = bb.path("src/capi/varargs.c"), .flags = &.{"-std=c99"} });
            m.addCSourceFile(.{ .file = bb.path("src/capi/loadext.c"), .flags = &.{"-std=c99"} });
            if (t.result.os.tag == .linux) {
                m.linkSystemLibrary("pthread", .{});
                // dlopen() for sqlite3_load_extension(), in libdl before glibc 2.34.
                m.linkSystemLibrary("dl", .{});
            }
            const l = bb.addLibrary(.{
                .name = n,
                .linkage = linkage,
                .root_module = m,
                // SQLite's libtool version: libsqlite3.so.0, as on Linux
                // distributions.
                .version = if (linkage == .dynamic) .{ .major = 0, .minor = 8, .patch = 6 } else null,
            });
            if (linkage == .static) l.bundle_compiler_rt = true;
            return l;
        }
    };
    const static = make.lib(b, target, optimize, name, .static);
    const shared = make.lib(b, target, optimize, name, .dynamic);

    // WebAssembly: wasm32-wasi gets the static library (a WASI program
    // links it); wasm32-freestanding, without a C library, gets none (its
    // module is `zig build wasm`).
    const wasm = target.result.cpu.arch.isWasm();
    if (enabled and target.result.os.tag != .freestanding) {
        b.installArtifact(static);
        if (!wasm) b.installArtifact(shared);
        b.installFile("include/sqlite3.h", "include/sqlite3.h");
        b.installFile("include/sqlite3ext.h", "include/sqlite3ext.h");
        b.installFile("include/xqlite.h", "include/xqlite.h");
        const pc = b.addWriteFiles().add(b.fmt("{s}.pc", .{name}), b.fmt(
            \\prefix=${{pcfiledir}}/../..
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: {s}
            \\Description: xqlite, an SQL database engine ported from SQLite to Zig, with the sqlite3 C API
            \\Version: 3.54.1
            \\Libs: -L${{libdir}} -l{s}
            \\Libs.private: -lm -lpthread -ldl
            \\Cflags: -I${{includedir}}
            \\
        , .{ name, name }));
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, b.fmt("pkgconfig/{s}.pc", .{name})).step);
    }

    // The C test program, linked once with each library.
    const test_step = b.step("test-capi", "Run the C API test (tools/capi/capi_test.c) against libxqlite3, static and shared");
    // A loadable extension for its sqlite3_load_extension() checks, built
    // against sqlite3ext.h alone (it calls through sqlite3_api_routines).
    const ext = b.addLibrary(.{
        .name = "xqexttest",
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true }),
    });
    ext.root_module.addCSourceFile(.{ .file = b.path("tools/capi/ext_test.c"), .flags = &.{"-std=c99"} });
    ext.root_module.addIncludePath(b.path("include"));
    for ([_]*std.Build.Step.Compile{ static, shared }, [_][]const u8{ "static", "shared" }) |lib, kind| {
        const exe = b.addExecutable(.{
            .name = b.fmt("capi-test-{s}", .{kind}),
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        exe.root_module.addCSourceFile(.{ .file = b.path("tools/capi/capi_test.c"), .flags = &.{"-std=gnu99"} });
        exe.root_module.addIncludePath(b.path("include"));
        exe.root_module.linkLibrary(lib);
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.addArtifactArg(ext);
        run.expectExitCode(0);
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }

    // SQLite's own shell on libxqlite3: the drop-in proof.
    const shell = b.addExecutable(.{
        .name = "sqlite3-xqlite",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    shell.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = shell_c }, .flags = &.{
        "-std=gnu99",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
        "-Wno-everything",
    } });
    shell.root_module.addIncludePath(b.path("include"));
    shell.root_module.linkLibrary(static);
    const shell_step = b.step("capi-shell", "Build SQLite's shell.c (-Dsqlite-shell-c) on libxqlite3 and run tools/capi/shell_smoke.sql");
    shell_step.dependOn(&b.addInstallArtifact(shell, .{}).step);
    const run_shell = b.addRunArtifact(shell);
    run_shell.addArgs(&.{ "-batch", ":memory:" });
    run_shell.setStdIn(.{ .lazy_path = b.path("tools/capi/shell_smoke.sql") });
    run_shell.expectStdOutEqual(@embedFile("tools/capi/shell_smoke.expected"));
    // The script has two failing statements on purpose: sqlite3 exits 1.
    run_shell.expectExitCode(1);
    run_shell.has_side_effects = true;
    shell_step.dependOn(&run_shell.step);

    return test_step;
}

/// `xqt --xq XQLITE --crashshim SHIM`, for `zig build check`: run from
/// the build root every time; the caller adds the command.
fn addXqtRun(b: *std.Build, xqt: *std.Build.Step.Compile, xqlite: *std.Build.Step.Compile, crashshim: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(xqt);
    run.addArg("--xq");
    run.addArtifactArg(xqlite);
    run.addArg("--crashshim");
    run.addArtifactArg(crashshim);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}
