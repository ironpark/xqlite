const std = @import("std");

/// WebAssembly SIMD (simd128) for the wasm32 targets this build picks
/// itself, so the @Vector loops (WAL checksums, JSON and UTF-8 scans)
/// compile to vector instructions there instead of being scalarized.
const wasm_simd = std.Target.wasm.featureSet(&.{.simd128});

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
        // The VFS and storage layers and the shared helpers, packages of
        // their own (pkg/vfs, pkg/storage, pkg/base, pkg/uuid, pkg/sql/lexer, pkg/sql/parse). See
        // engineImports().
        .imports = engineImports(b, target, optimize),
    });
    linkCapiC(b, mod, target, optimize, buildConfig(b).hasExt("carray"));

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
    // The wire protocol servers (src/server, module xqlite_server): on
    // the Zig API, so that the engine library has no networking. The CLI
    // (`xqlite serve`) imports it; its wasm builds do not.
    const server_mod = b.addModule("xqlite_server", .{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "xqlite", .module = mod }},
    });

    const exe = b.addExecutable(.{
        .name = "xqlite",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/cli/main.zig"),
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
                .{ .name = "xqlite_server", .module = server_mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    exe.root_module.strip = stripOption(b);
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
    // The packages' tests, which the module's do not include (a test
    // binary runs the tests of its root module only).
    test_step.dependOn(&b.addRunArtifact(vfsTests(b, target, optimize, test_filters)).step);
    test_step.dependOn(&b.addRunArtifact(storageTests(b, target, optimize, test_filters)).step);
    for (leafTestsAll(b, target, optimize, test_filters)) |t| test_step.dependOn(&b.addRunArtifact(t).step);
    test_step.dependOn(&b.addRunArtifact(sqlparseTests(b, target, optimize, test_filters)).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = server_mod, .filters = test_filters })).step);

    // Example programs of the Zig API (examples/*.zig): `zig build
    // example-<name>` runs one (arguments after `--`), `zig build examples`
    // builds them all.
    const examples_step = b.step("examples", "Build the example programs");
    // examples/extension/sqlite_regex.zig loads a library that is not part
    // of the build (docs/load-extension.md): `-- PATH` of it.
    inline for (.{ .{ "basic", "basic" }, .{ "extensions", "extensions" }, .{ "sqlite-regex", "extension/sqlite_regex" } }) |e| {
        const name = e[0];
        const example = b.addExecutable(.{
            .name = "example-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ e[1] ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "xqlite", .module = mod }},
            }),
        });
        examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
        const run_example = b.addRunArtifact(example);
        run_example.addPassthruArgs();
        b.step("example-" ++ name, "Run examples/" ++ e[1] ++ ".zig").dependOn(&run_example.step);
    }

    // The reference sqlite3 shells and SQLite's sources (sqliteRef()).
    const sqlite_ref = sqliteRef(b, target);
    // The sqlite3-compatible C ABI (src/capi.zig): libxqlite3, its header
    // and its tests. See addCapi() and docs/c-api.md.
    // `zig build ext`: the loadable extension (addExt()).
    const ext = addExt(b, target, optimize);
    const capi = addCapi(b, target, optimize, sqlite_ref, ext.lib, mod);
    // `zig build testfixture`: SQLite's TCL test fixture on libxqlite3 and
    // on SQLite's amalgamation, for `xqt tcl` (addTcl()).
    addTcl(b, target, sqlite_ref);
    if (!target.result.cpu.arch.isWasm()) examples_step.dependOn(&b.addInstallArtifact(capi.c_example, .{}).step);
    // `zig build wasm`: the WebAssembly module for JavaScript hosts
    // (src/wasm/api.zig, wasm32-freestanding, no libc) in zig-out/wasm,
    // whatever -Dtarget is; ReleaseSmall unless -Dwasm-optimize says
    // otherwise. `zig build wasm-example` runs examples/wasm/node.mjs
    // with it. docs/wasm.md.
    const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "zig build wasm: optimization mode (default small)") orelse .small;
    // -Dwasm-simd=false for runtimes without WebAssembly SIMD.
    const wasm_features = if (b.option(bool, "wasm-simd", "zig build wasm, test-wasi: use WebAssembly SIMD (default true)") orelse true) wasm_simd else std.Target.Cpu.Feature.Set.empty;
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding, .cpu_features_add = wasm_features });
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
                .imports = engineImports(b, wasm_target, wasm_optimize),
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

    // ... and that src/, pkg/ and tools/xqt keep no mutable globals but the few
    // it lists.
    // The seeded fuzzers (src/fuzz_tests.zig): `zig build fuzz -- NAME
    // [SEED]` runs one. Their smoke test runs with the module's tests
    // (src/root.zig), which import the same files.
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = engineImports(b, target, optimize),
    });
    const fuzz_exe = b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_module });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.addPassthruArgs();
    installSqliteRef(run_fuzz, sqlite_ref);
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
    // It reads src/ and pkg/ at run time, which the cache does not see.
    run_globals_tests.has_side_effects = true;
    test_step.dependOn(&run_globals_tests.step);
    test_step.dependOn(examples_step);

    // The journal's checksums once more, optimized: Zig 0.17 compiled one
    // of them wrong in optimized builds only (see superNameChecksum() in
    // pkg/storage/src/pager/journal.zig), which the Debug tests above
    // cannot see.
    const journal_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("pkg/storage/src/pager/journal.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(journal_tests).step);

    // The packages alone, without the engine: quick to build when working
    // on the VFS, the pager or the b-tree. `zig build test` runs these too.
    const pkg_step = b.step("test-pkg", "Run the tests of the packages under pkg/ alone (no engine build)");
    pkg_step.dependOn(&b.addRunArtifact(vfsTests(b, target, optimize, test_filters)).step);
    pkg_step.dependOn(&b.addRunArtifact(storageTests(b, target, optimize, test_filters)).step);
    for (leafTestsAll(b, target, optimize, test_filters)) |t| pkg_step.dependOn(&b.addRunArtifact(t).step);
    pkg_step.dependOn(&b.addRunArtifact(sqlparseTests(b, target, optimize, test_filters)).step);
    pkg_step.dependOn(&b.addRunArtifact(journal_tests).step);

    // The b-tree benchmark of pkg/storage (bench/btree.zig), ReleaseFast.
    const btree_bench = b.addRunArtifact(b.dependency("xqlite_storage", .{ .target = target, .optimize = optimize }).artifact("btree-bench"));
    btree_bench.addPassthruArgs();
    btree_bench.has_side_effects = true;
    const btree_bench_step = b.step("bench-btree", "Run the b-tree benchmark of pkg/storage, ReleaseFast, without the engine (-- -n ROWS -page-size BYTES)");
    btree_bench_step.dependOn(&btree_bench.step);

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
    const xqt_options_module = xqt_options.createModule();
    const xqt = struct {
        /// xqt for an xqlite of configuration `cfg`: the interop modules
        /// of the dialects it lacks are left out.
        fn build(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, lib: *std.Build.Module, options: *std.Build.Module, cfg: Config) *std.Build.Step.Compile {
            return bb.addExecutable(.{
                .name = "xqt",
                .root_module = bb.createModule(.{
                    .root_source_file = bb.path("tools/xqt/main.zig"),
                    .target = t,
                    .optimize = o,
                    .link_libc = true,
                    .imports = &.{
                        .{ .name = "xqt", .module = lib },
                        .{ .name = "build_options", .module = options },
                        .{ .name = "xqlite_config", .module = cfg.module },
                    },
                }),
            });
        }
    };
    const xqt_exe = xqt.build(b, target, optimize, xqt_lib, xqt_options_module, buildConfig(b));
    const crashshim = b.addLibrary(.{
        .name = "crashshim",
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseSafe, .link_libc = true }),
    });
    crashshim.root_module.addCSourceFile(.{ .file = b.path("tools/crashshim.c") });
    if (target.result.os.tag == .linux) crashshim.root_module.linkSystemLibrary("dl", .{});
    const tools_step = b.step("tools", "Build xqt, the crash shim, the loadable extension and the reference sqlite3 shells of the cross-checks (tools/xqt)");
    tools_step.dependOn(b.getInstallStep());
    tools_step.dependOn(&b.addInstallArtifact(xqt_exe, .{}).step);
    tools_step.dependOn(&b.addInstallArtifact(crashshim, .{}).step);
    tools_step.dependOn(ext.install);
    if (sqlite_ref) |ref| {
        tools_step.dependOn(&ref.install_shell.step);
        tools_step.dependOn(&b.addInstallArtifact(ref.planner, .{}).step);
    }

    // `zig build test-wasi`: the unit tests (module and CLI) built for
    // wasm32-wasi and run under wasmtime, then `xqt wasi`, which runs an
    // xqlite built for wasm32-wasi (ReleaseSafe) against sqlite3 and this
    // native build. Needs wasmtime on PATH. docs/wasm.md.
    const wasi_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi, .cpu_features_add = wasm_features });
    const wasi_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasi_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = engineImports(b, wasi_target, optimize),
    });
    linkCapiC(b, wasi_mod, wasi_target, optimize, buildConfig(b).hasExt("carray"));
    const wasi_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = wasi_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "xqlite", .module = wasi_mod }},
    });
    const wasi_safe_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasi_target,
        .optimize = .safe,
        .link_libc = true,
        .imports = engineImports(b, wasi_target, .safe),
    });
    linkCapiC(b, wasi_safe_mod, wasi_target, .safe, buildConfig(b).hasExt("carray"));
    const wasi_safe_exe = b.addExecutable(.{
        .name = "xqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = wasi_target,
            .optimize = .safe,
            .imports = &.{.{ .name = "xqlite", .module = wasi_safe_mod }},
        }),
    });
    const test_wasi_step = b.step("test-wasi", "Run the unit tests and `xqt wasi` on wasm32-wasi under wasmtime");
    for ([_]*std.Build.Step.Compile{
        b.addTest(.{ .root_module = wasi_mod, .filters = test_filters }),
        b.addTest(.{ .root_module = wasi_exe_mod, .filters = test_filters }),
        vfsTests(b, wasi_target, optimize, test_filters),
        storageTests(b, wasi_target, optimize, test_filters),
        sqlparseTests(b, wasi_target, optimize, test_filters),
    } ++ leafTestsAll(b, wasi_target, optimize, test_filters)) |t| {
        const run = b.addSystemCommand(&.{ "wasmtime", "run", "--dir", "." });
        run.addArtifactArg(t);
        // The tests make their temporary directories under .zig-cache/tmp.
        run.setCwd(b.path("."));
        run.has_side_effects = true;
        test_wasi_step.dependOn(&run.step);
    }
    const wasi_run = addXqtRun(b, xqt_exe, exe, crashshim, sqlite_ref, null);
    wasi_run.addArgs(&.{ "wasi", "--wasm" });
    wasi_run.addArtifactArg(wasi_safe_exe);
    test_wasi_step.dependOn(&wasi_run.step);

    // `zig build check`: everything at once, in parallel. The unit tests,
    // every `xqt interop` module, every planner case file but vtablog.txt
    // and fuzzcheck on SQLite's corpora; -Dslt=true adds sqllogictest
    // (ref/sqllogictest), -Dfuzz=true a run of each seeded fuzzer with a
    // random seed, -Dfast=true the C test and benchmark on the ReleaseFast
    // library (capi-fast, a minute and a half). A new interop module needs
    // no change here.
    const check_slt = b.option(bool, "slt", "zig build check: also run sqllogictest (minutes)") orelse false;
    const check_fuzz = b.option(bool, "fuzz", "zig build check: also run each seeded fuzzer with a random seed") orelse false;
    const check_fast = b.option(bool, "fast", "zig build check: also run capi-fast (about 90 s)") orelse false;
    const check_step = b.step("check", "Run the unit tests, the cross-checks, the planner cases and fuzzcheck (-Dslt, -Dfuzz, -Dfast for more)");
    check_step.dependOn(test_step);
    check_step.dependOn(capi.test_step);
    if (check_fast) check_step.dependOn(capi.fast_step);
    check_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xqt_exe.root_module })).step);
    // The engine with no dialect but SQLite's and no extension.
    const minimal_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = engineImportsWith(b, target, optimize, minimalConfigModule(b)),
    });
    linkCapiC(b, minimal_mod, target, optimize, false);
    const minimal_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/minimal_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "xqlite", .module = minimal_mod }},
    }) });
    const minimal_run = b.addRunArtifact(minimal_tests);
    check_step.dependOn(&minimal_run.step);
    b.step("test-minimal", "Run tools/minimal_test.zig on the engine built with -Ddialects=none -Dext=none").dependOn(&minimal_run.step);
    const interop_run = addXqtRun(b, xqt_exe, exe, crashshim, sqlite_ref, ext.lib);
    // (Only interop loads the extension; the other runs do not build it.)
    interop_run.addArg("interop");
    check_step.dependOn(&interop_run.step);
    const planner_run = addXqtRun(b, xqt_exe, exe, crashshim, sqlite_ref, null);
    planner_run.addArgs(&.{ "planner", "--known" });
    planner_run.addFileArg(b.path("tools/planner/known-failures.list"));
    check_step.dependOn(&planner_run.step);
    // Each dialect built in whose server's outputs are recorded
    // (tools/dialect/*-expected, `xqt dialect-diff NAME --record`):
    // xqlite against the recording, no server needed. A dialect goes in
    // this list once its recording is made.
    // Each with its case files beside the default one (null).
    const recorded_dialects = [_]struct { []const u8, []const u8, []const ?[]const u8 }{
        .{ "postgres", "pg", &.{ null, "tools/dialect/pg-array-cases.txt", "tools/dialect/pg-uuid-cases.txt", "tools/dialect/pg-interval-cases.txt", "tools/dialect/pg-jsonb-cases.txt", "tools/dialect/pg-numeric-cases.txt", "tools/dialect/pg-integer-cases.txt", "tools/dialect/pg-syntax-cases.txt", "tools/dialect/pg-format-cases.txt", "tools/dialect/pg-error-cases.txt", "tools/dialect/pg-string-cases.txt", "tools/dialect/pg-numeric-math-cases.txt", "tools/dialect/pg-intervalstyle-cases.txt", "tools/dialect/pg-boolean-cases.txt", "tools/dialect/pg-select-cases.txt", "tools/dialect/pg-mathstat-cases.txt", "tools/dialect/pg-cursor-cases.txt", "tools/dialect/pg-dml-cases.txt", "tools/dialect/pg-float-cases.txt", "tools/dialect/pg-lock-cases.txt", "tools/dialect/pg-constraints-cases.txt", "tools/dialect/pg-grouping-cases.txt", "tools/dialect/pg-merge-view-cases.txt", "tools/dialect/pg-viewdef-cases.txt", "tools/dialect/pg-join-cases.txt" } },
    };
    for (recorded_dialects) |rd| {
        const on = for (Config.dialects, buildConfig(b).dialect) |name, built| {
            if (std.mem.eql(u8, name, rd[0])) break built;
        } else unreachable;
        if (!on) continue;
        for (rd[2]) |cases| {
            const dialect_run = addXqtRun(b, xqt_exe, exe, crashshim, sqlite_ref, null);
            dialect_run.addArgs(&.{ "dialect-diff", rd[1] });
            if (cases) |f| dialect_run.addFileArg(b.path(f));
            check_step.dependOn(&dialect_run.step);
        }
    }
    // `zig build check-matrix`: the engine built with no dialect but
    // SQLite's and with each dialect alone, as -Ddialects=none,
    // -Ddialects=postgres ... would build it, all in this one build (in
    // parallel, one cache): for each, the unit tests (module, CLI,
    // servers), the C API test on the static library, `xqt interop` with
    // the extension of that build, and the recorded dialect-diff of the
    // dialect. What does not depend on the dialects (fuzzcheck, the
    // planner, the packages, wasm) runs in `check` only; `zig build
    // check check-matrix` runs both.
    const matrix_step = b.step("check-matrix", "Run the unit tests, the C API test, xqt interop and dialect-diff on the engine built with each dialect alone and with none");
    {
        const current = buildConfig(b);
        var variants: [Config.dialects.len + 1][Config.dialects.len]bool = @splat(@splat(false));
        for (variants[1..], 0..) |*v, i| v[i] = true;
        for (variants) |on| {
            const cfg: Config = .make(b, on, current.ext);
            const label = cfg.label(b);
            const m = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = engineImportsWith(b, target, optimize, cfg.module),
            });
            linkCapiC(b, m, target, optimize, cfg.hasExt("carray"));
            const sm = b.createModule(.{
                .root_source_file = b.path("src/server/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "xqlite", .module = m }},
            });
            const e = b.addExecutable(.{ .name = "xqlite", .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "xqlite", .module = m }, .{ .name = "xqlite_server", .module = sm } },
            }) });
            for ([_]*std.Build.Module{ m, e.root_module, sm }, [_][]const u8{ "engine", "cli", "server" }) |root, what| {
                const t = b.addTest(.{ .name = b.fmt("test-{s}-{s}", .{ what, label }), .root_module = root, .filters = test_filters });
                matrix_step.dependOn(&b.addRunArtifact(t).step);
            }
            const x = extLib(b, target, optimize, cfg);
            const lib = capiLib(b, target, optimize, b.fmt("xqlite3-{s}", .{label}), .static, cfg);
            matrix_step.dependOn(&capiTestRun(b, target, optimize, b.fmt("capi-test-{s}", .{label}), lib, capi.ext_test, x).step);
            const q = xqt.build(b, target, optimize, xqt_lib, xqt_options_module, cfg);
            const interop = addXqtRun(b, q, e, crashshim, sqlite_ref, x);
            interop.addArg("interop");
            matrix_step.dependOn(&interop.step);
            for (recorded_dialects) |rd| {
                const built = for (Config.dialects, cfg.dialect) |name, d_on| {
                    if (std.mem.eql(u8, name, rd[0])) break d_on;
                } else unreachable;
                if (!built) continue;
                for (rd[2]) |cases| {
                    const dialect_run = addXqtRun(b, q, e, crashshim, sqlite_ref, null);
                    dialect_run.addArgs(&.{ "dialect-diff", rd[1] });
                    if (cases) |f| dialect_run.addFileArg(b.path(f));
                    matrix_step.dependOn(&dialect_run.step);
                }
            }
        }
    }
    // The long runs (sqllogictest, fuzzcheck, the fuzzers) use a ReleaseSafe
    // build whatever -Doptimize is: safety checks on, minutes not hours.
    // The cross-checks and the planner use the build asked for.
    const safe_exe = if (optimize == .safe) exe else b.addExecutable(.{
        .name = "xqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{ .{ .name = "xqlite", .module = mod }, .{ .name = "xqlite_server", .module = server_mod } },
        }),
    });
    if (check_slt) {
        const slt_run = addXqtRun(b, xqt_exe, safe_exe, crashshim, sqlite_ref, null);
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
                .imports = engineImports(b, target, .ReleaseSafe),
            }),
        });
        for ([_][]const u8{ "btree_model", "btree_corrupt", "btree_sqlite3", "ir_roundtrip", "ir_ext" }) |name| {
            const run = b.addRunArtifact(safe_fuzz);
            run.addArg(name);
            installSqliteRef(run, sqlite_ref);
            // ir_ext loads the extension of this build into sqlite3.
            if (std.mem.eql(u8, name, "ir_ext")) if (ext.lib) |lib| {
                run.addArg("--ext");
                run.addArtifactArg(lib);
            };
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
/// script; `zig build capi-fast` runs the C test and tools/capi/bench.c
/// on the ReleaseFast static library several times. Returns the
/// test-capi and capi-fast steps.
fn addCapi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sqlite_ref: ?SqliteRef, xqlite_ext: ?*std.Build.Step.Compile, zig_mod: *std.Build.Module) struct { test_step: *std.Build.Step, fast_step: *std.Build.Step, ext_test: *std.Build.Step.Compile, c_example: *std.Build.Step.Compile } {
    const enabled = b.option(bool, "capi", "Build and install the C libraries (libxqlite3) with `zig build` (default: true)") orelse true;
    const name = b.option([]const u8, "capi-name", "Base name of the C libraries: lib<name>.a, lib<name>.so/.dylib (default: xqlite3; sqlite3 for a drop-in libsqlite3)") orelse "xqlite3";
    // The amalgamation's files, from the `sqlite` dependency unless given.
    const amalgamation = struct {
        /// Null in a project that depends on this one, unless given.
        fn file(opt: ?[]const u8, ref: ?SqliteRef, basename: []const u8) ?std.Build.LazyPath {
            if (opt) |path| return .{ .cwd_relative = path };
            const r = ref orelse return null;
            return r.dep.path(basename);
        }
    };
    const shell_c_opt = b.option([]const u8, "sqlite-shell-c", "shell.c of the SQLite 3.54.1 amalgamation, for `zig build capi-shell` (default: the `sqlite` dependency's)");
    const sqlite_c_opt = b.option([]const u8, "sqlite-c", "sqlite3.c of the SQLite 3.54.1 amalgamation, for `zig build capi-sortbench` (default: the `sqlite` dependency's)");

    const make = struct {
        fn lib(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, n: []const u8, linkage: std.builtin.LinkMode) *std.Build.Step.Compile {
            return capiLib(bb, t, o, n, linkage, buildConfig(bb));
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
        test_step.dependOn(&capiTestRun(b, target, optimize, b.fmt("capi-test-{s}", .{kind}), lib, ext, xqlite_ext).step);
    }
    // Db.loadExtension() (the Zig API, through src/capi/bridge.zig) with
    // the same test extension: tools/capi/zig_load_test.zig.
    if (!target.result.cpu.arch.isWasm()) {
        const zig_load = b.addExecutable(.{
            .name = "capi-zig-load-test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/capi/zig_load_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "xqlite", .module = zig_mod }},
            }),
        });
        const run_zig_load = b.addRunArtifact(zig_load);
        run_zig_load.addArtifactArg(ext);
        run_zig_load.expectExitCode(0);
        test_step.dependOn(&run_zig_load.step);
    }

    // The C test and an insert benchmark (tools/capi/bench.c) on the
    // ReleaseFast static library, whatever -Doptimize is, each run several
    // times: ReleaseFast leaves `undefined` memory as it was, so a read of
    // it fails only now and then, with the addresses of the run (a
    // function context did, in about 40% of capi_test runs).
    const fast_step = b.step("capi-fast", "Run tools/capi/capi_test.c and tools/capi/bench.c on the ReleaseFast static libxqlite3, 8 times each");
    const fast_lib = if (optimize == .fast) static else make.lib(b, target, .fast, name, .static);
    for ([_][]const u8{ "capi_test", "bench" }) |prog| {
        const exe = b.addExecutable(.{
            .name = b.fmt("capi-fast-{s}", .{prog}),
            .root_module = b.createModule(.{ .target = target, .optimize = .fast, .link_libc = true }),
        });
        exe.root_module.addCSourceFile(.{ .file = b.path(b.fmt("tools/capi/{s}.c", .{prog})), .flags = &.{"-std=gnu99"} });
        exe.root_module.addIncludePath(b.path("include"));
        exe.root_module.linkLibrary(fast_lib);
        for (0..8) |_| {
            const run = b.addRunArtifact(exe);
            run.setCwd(b.path("."));
            if (std.mem.eql(u8, prog, "capi_test")) run.addArtifactArg(ext);
            run.expectExitCode(0);
            run.has_side_effects = true;
            fast_step.dependOn(&run.step);
        }
    }

    // The sort benchmark (tools/capi/sortbench.c), ReleaseFast, on SQLite's
    // sqlite3.c and then on libxqlite3, which must give the same rows in
    // the same order. Arguments after `--` go to both.
    const sortbench_step = b.step("capi-sortbench", "Run tools/capi/sortbench.c on SQLite's sqlite3.c (-Dsqlite-c), then on the ReleaseFast libxqlite3 against its results (-- -spill to spill)");
    if (amalgamation.file(sqlite_c_opt, sqlite_ref, "sqlite3.c")) |sqlite_c| {
        const sortbench_sqlite = b.addExecutable(.{
            .name = "sortbench-sqlite",
            .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
        });
        sortbench_sqlite.root_module.addCSourceFile(.{ .file = b.path("tools/capi/sortbench.c"), .flags = &.{"-std=gnu99"} });
        sortbench_sqlite.root_module.addCSourceFile(.{ .file = sqlite_c, .flags = &.{
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-Wno-everything",
        } });
        sortbench_sqlite.root_module.addIncludePath(sqlite_c.dirname());
        const sortbench = b.addExecutable(.{
            .name = "sortbench",
            .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
        });
        sortbench.root_module.addCSourceFile(.{ .file = b.path("tools/capi/sortbench.c"), .flags = &.{"-std=gnu99"} });
        sortbench.root_module.addIncludePath(b.path("include"));
        sortbench.root_module.linkLibrary(fast_lib);
        const run_ref = b.addRunArtifact(sortbench_sqlite);
        run_ref.addPassthruArgs();
        run_ref.has_side_effects = true;
        const run_bench = b.addRunArtifact(sortbench);
        run_bench.addPassthruArgs();
        run_bench.addArg("-ref");
        run_bench.addFileArg(run_ref.captureStdOut(.{}));
        run_bench.stdio = .inherit;
        run_bench.has_side_effects = true;
        sortbench_step.dependOn(&run_bench.step);
    }

    // SQLite's own shell on libxqlite3: the drop-in proof.
    const shell_step = b.step("capi-shell", "Build SQLite's shell.c (-Dsqlite-shell-c) on libxqlite3 and run tools/capi/shell_smoke.sql");
    if (amalgamation.file(shell_c_opt, sqlite_ref, "shell.c")) |shell_c| {
        const shell = b.addExecutable(.{
            .name = "sqlite3-xqlite",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        shell.root_module.addCSourceFile(.{ .file = shell_c, .flags = &.{
            "-std=gnu99",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-Wno-everything",
        } });
        shell.root_module.addIncludePath(b.path("include"));
        shell.root_module.linkLibrary(static);
        shell_step.dependOn(&b.addInstallArtifact(shell, .{}).step);
        const run_shell = b.addRunArtifact(shell);
        run_shell.addArgs(&.{ "-batch", ":memory:" });
        run_shell.setStdIn(.{ .lazy_path = b.path("tools/capi/shell_smoke.sql") });
        run_shell.expectStdOutEqual(@embedFile("tools/capi/shell_smoke.expected"));
        // The script has two failing statements on purpose: sqlite3 exits 1.
        run_shell.expectExitCode(1);
        run_shell.has_side_effects = true;
        shell_step.dependOn(&run_shell.step);
    }

    // A C example on libxqlite3 (examples/extension/sqlite_regex.c): a third-party
    // extension, sqlite-regex, loaded with sqlite3_load_extension(). `zig
    // build example-sqlite-regex-c -- ./regex0` runs it; the library is not
    // part of the build (docs/load-extension.md).
    const regex_example = b.addExecutable(.{
        .name = "example-sqlite-regex-c",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    regex_example.root_module.addCSourceFile(.{ .file = b.path("examples/extension/sqlite_regex.c"), .flags = &.{"-std=c99"} });
    regex_example.root_module.addIncludePath(b.path("include"));
    regex_example.root_module.linkLibrary(static);
    const run_regex_example = b.addRunArtifact(regex_example);
    run_regex_example.addPassthruArgs();
    run_regex_example.has_side_effects = true;
    b.step("example-sqlite-regex-c", "Run examples/extension/sqlite_regex.c on libxqlite3 (-- PATH of sqlite-regex's regex0 library)").dependOn(&run_regex_example.step);

    return .{ .test_step = test_step, .fast_step = fast_step, .ext_test = ext, .c_example = regex_example };
}

/// The loadable extension (src/loadable.zig, docs/extension.md):
/// libxqlite_ext.so or .dylib in zig-out/lib, the engine functions and
/// collations of the dialects built in (-Ddialects) for a real sqlite3.
/// `zig build ext` builds it, `zig build tools` too, and `zig build
/// check` hands it to `xqt interop`. None for WebAssembly, which loads
/// no libraries (lib null).
fn addExt(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct { lib: ?*std.Build.Step.Compile, install: *std.Build.Step } {
    const step = b.step("ext", "Build the SQLite loadable extension zig-out/lib/libxqlite_ext.{so,dylib} (docs/extension.md)");
    const lib = extLib(b, target, optimize, buildConfig(b)) orelse return .{ .lib = null, .install = step };
    step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    return .{ .lib = lib, .install = step };
}

/// The loadable extension of configuration `cfg`; null on wasm (no
/// dynamic loader).
fn extLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, cfg: Config) ?*std.Build.Step.Compile {
    if (target.result.cpu.arch.isWasm()) return null;
    const m = b.createModule(.{
        .root_source_file = b.path("src/loadable.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
        .imports = engineImportsWith(b, target, optimize, cfg.module),
        .strip = stripOption(b),
    });
    m.addIncludePath(b.path("include"));
    m.addCSourceFile(.{ .file = b.path("src/loadable/entry.c"), .flags = &.{ "-std=c99", "-fvisibility=hidden" } });
    return b.addLibrary(.{ .name = "xqlite_ext", .linkage = .dynamic, .root_module = m });
}

/// libxqlite3 (src/capi.zig) of configuration `cfg`.
/// The C part of the C ABI (src/capi/varargs.c, loadext.c: the variadic
/// functions, sqlite3_mutex and the sqlite3_api_routines table) as a
/// static library of engine module `m`. Db.loadExtension() and the
/// shell's .load compile the C ABI into a program (src/capi/bridge.zig)
/// and need it; a program that loads nothing uses none of its objects.
/// None on wasm32-freestanding, which has no C library and no loader.
fn linkCapiC(b: *std.Build, m: *std.Build.Module, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, carray: bool) void {
    if (t.result.os.tag == .freestanding) return;
    // No UBSan: the engine module goes into programs of other optimize
    // modes (a ReleaseSafe CLI on a Debug module), without its runtime.
    const cm = b.createModule(.{ .target = t, .optimize = o, .link_libc = true, .pic = true, .sanitize_c = .off });
    cm.addIncludePath(b.path("include"));
    cm.addCSourceFile(.{ .file = b.path("src/capi/varargs.c"), .flags = &.{"-std=c99"} });
    cm.addCSourceFile(.{ .file = b.path("src/capi/loadext.c"), .flags = if (carray) &.{"-std=c99"} else &.{ "-std=c99", "-DXQ_OMIT_CARRAY" } });
    m.linkLibrary(b.addLibrary(.{ .name = "xqlite_capi_c", .linkage = .static, .root_module = cm }));
    // dlopen(), in libdl before glibc 2.34.
    if (t.result.os.tag == .linux) m.linkSystemLibrary("dl", .{});
}

fn capiLib(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, n: []const u8, linkage: std.builtin.LinkMode, cfg: Config) *std.Build.Step.Compile {
    const m = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = t,
        .optimize = o,
        .link_libc = true,
        .pic = true,
        .imports = engineImportsWith(b, t, o, cfg.module),
        .strip = stripOption(b),
    });
    m.addIncludePath(b.path("include"));
    m.addCSourceFile(.{ .file = b.path("src/capi/varargs.c"), .flags = &.{"-std=c99"} });
    m.addCSourceFile(.{ .file = b.path("src/capi/loadext.c"), .flags = if (cfg.hasExt("carray")) &.{"-std=c99"} else &.{ "-std=c99", "-DXQ_OMIT_CARRAY" } });
    if (t.result.os.tag == .linux) {
        m.linkSystemLibrary("pthread", .{});
        // dlopen() for sqlite3_load_extension(), in libdl before glibc 2.34.
        m.linkSystemLibrary("dl", .{});
    }
    const l = b.addLibrary(.{
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

/// The C API test (tools/capi/capi_test.c) linked with `lib`, run with
/// the test extension `ext_test` and, if any, the xqlite extension.
fn capiTestRun(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, lib: *std.Build.Step.Compile, ext_test: *std.Build.Step.Compile, xqlite_ext: ?*std.Build.Step.Compile) *std.Build.Step.Run {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    exe.root_module.addCSourceFile(.{ .file = b.path("tools/capi/capi_test.c"), .flags = &.{"-std=gnu99"} });
    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.linkLibrary(lib);
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addArtifactArg(ext_test);
    // The xqlite extension (docs/extension.md), loaded into libxqlite3.
    if (xqlite_ext) |x| run.addArtifactArg(x);
    run.expectExitCode(0);
    run.has_side_effects = true;
    return run;
}

/// `zig build testfixture`: SQLite's TCL test fixture (tclsqlite.c and the
/// test*.c helpers that need only the public API, tools/tcl/README.md)
/// twice, on the same sources: zig-out/bin/testfixture-xqlite on
/// libxqlite3 (-Dtcl-optimize, default ReleaseSafe) and
/// zig-out/bin/testfixture-sqlite on SQLite's 3.54.1 amalgamation, so
/// that `xqt tcl` can tell a test the harness cannot pass from an
/// incompatibility. Needs ref/sqlite (`xqt fetch sqlite`: test*.c, the
/// headers, lemon) and ref/tcl (`xqt fetch tcl`: Tcl 8.6).
fn addTcl(b: *std.Build, target: std.Build.ResolvedTarget, sqlite_ref: ?SqliteRef) void {
    const step = b.step("testfixture", "Build SQLite's TCL test fixture on libxqlite3 and on SQLite 3.54.1 (zig-out/bin/testfixture-{xqlite,sqlite}) from ref/sqlite and ref/tcl, for xqt tcl");
    const src_opt = b.option([]const u8, "sqlite-src", "SQLite's source tree for `zig build testfixture` (default: ref/sqlite, from xqt fetch sqlite)") orelse "ref/sqlite";
    const tcl_opt = b.option([]const u8, "tcl-prefix", "Tcl 8.6 for `zig build testfixture` (default: ref/tcl, from xqt fetch tcl)") orelse "ref/tcl";
    const lib_optimize = b.option(std.builtin.OptimizeMode, "tcl-optimize", "zig build testfixture: optimization mode of libxqlite3 (default ReleaseSafe)") orelse .safe;
    const ref = sqlite_ref orelse return;
    const os = target.result.os.tag;
    if (target.result.cpu.arch.isWasm() or os == .windows) return;

    const io = b.graph.io;
    const src_path = optPath(b, src_opt);
    const tcl_path = optPath(b, tcl_opt);
    for ([_][2][]const u8{ .{ src_opt, "src/test1.c" }, .{ tcl_opt, "include/tcl.h" } }) |need| {
        const p = b.pathJoin(&.{ need[0], need[1] });
        const found = std.Io.Dir.cwd().access(io, fromRoot(b, p), .{});
        found catch {
            step.dependOn(&b.addFail(b.fmt("zig build testfixture: no {s} (zig-out/bin/xqt fetch sqlite, xqt fetch tcl; -Dsqlite-src, -Dtcl-prefix)", .{p})).step);
            return;
        };
    }

    // parse.h (lemon) and opcodes.h (mkopcodeh.tcl), which sqliteInt.h
    // includes, as SQLite's main.mk makes them.
    const host = b.graph.host;
    const lemon = b.addExecutable(.{
        .name = "lemon",
        .root_module = b.createModule(.{ .target = host, .optimize = .ReleaseFast, .link_libc = true }),
    });
    lemon.root_module.addCSourceFile(.{ .file = src_path.path(b, "tool/lemon.c"), .flags = &.{"-Wno-everything"} });
    const run_lemon = b.addRunArtifact(lemon);
    run_lemon.addArgs(&.{ "-S", "-q" });
    run_lemon.addPrefixedFileArg("-T", src_path.path(b, "tool/lempar.c"));
    const parse_dir = run_lemon.addPrefixedOutputDirectoryArg("-d", "parse");
    run_lemon.addFileArg(src_path.path(b, "src/parse.y"));
    const tclsh = b.addSystemCommand(&.{b.pathJoin(&.{ fromRoot(b, tcl_opt), "bin", "tclsh8.6" })});
    tclsh.setEnvironmentVariable("TCL_LIBRARY", b.pathJoin(&.{ fromRoot(b, tcl_opt), "lib", "tcl8.6" }));
    tclsh.addFileArg(b.path("tools/tcl/opcodes.tcl"));
    tclsh.addFileArg(parse_dir.path(b, "parse.h"));
    tclsh.addFileArg(src_path.path(b, "src/vdbe.c"));
    tclsh.addFileArg(src_path.path(b, "tool/mkopcodeh.tcl"));
    const gen = b.addWriteFiles();
    _ = gen.addCopyFile(parse_dir.path(b, "parse.h"), "parse.h");
    _ = gen.addCopyFile(tclsh.captureStdOut(.{}), "opcodes.h");

    // test1.c with its reads of SQLite's structures rewritten.
    const patch = b.addExecutable(.{
        .name = "patch_test1",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/tcl/patch_test1.zig"), .target = host, .optimize = .Debug }),
    });
    const run_patch = b.addRunArtifact(patch);
    run_patch.addFileArg(src_path.path(b, "src/test1.c"));
    const test1 = run_patch.addOutputFileArg("test1.c");

    // What the fixture of main.mk compiles (TESTSRC), less the helpers
    // that need SQLite's internals or modules neither library has
    // (tools/tcl/README.md), and with the extensions as in TESTSRC.
    const helpers = [_][]const u8{
        "test4",          "test6",          "test8",          "test9",        "test_autoext",
        "test_backup",    "test_bestindex", "test_blob",      "test_config",  "test_delete",
        "test_demovfs",   "test_devsym",    "test_fs",        "test_func",    "test_hexio",
        "test_init",      "test_intarray",  "test_journal",   "test_malloc",  "test_md5",
        "test_multiplex", "test_mutex",     "test_onefile",   "test_osinst",  "test_pcache",
        "test_quota",     "test_schema",    "test_superlock", "test_syscall", "test_tclsh",
        "test_tclvar",    "test_thread",    "test_vdbecov",   "test_vfs",     "test_window",
        "test_wsd",
    };
    const misc = [_][]const u8{
        "amatch",   "appendvfs", "basexx",   "cksumvfs", "closure",    "csv",       "decimal",
        "diskused", "eval",      "explain",  "fileio",   "fuzzer",     "ieee754",   "mmapwarm",
        "nextchar", "normalize", "prefixes", "qpvtab",   "randomjson", "regexp",    "remember",
        "series",   "spellfix",  "stmtrand", "strdup",   "totype",     "unionvtab", "wholenumber",
    };
    // The optional parts both libraries have (docs/c-api.md), so that
    // test_config.c's sqlite_options and the amalgamation agree.
    const features = [_][]const u8{
        "-DSQLITE_ENABLE_COLUMN_METADATA",
        "-DSQLITE_ENABLE_NORMALIZE",
        "-DSQLITE_ENABLE_BYTECODE_VTAB",
        "-DSQLITE_ENABLE_CARRAY",
        "-DSQLITE_ENABLE_SNAPSHOT",
    };
    const lib = capiLib(b, target, lib_optimize, "xqlite3", .static, buildConfig(b));
    for ([_][]const u8{ "xqlite", "sqlite" }) |engine| {
        const xq = std.mem.eql(u8, engine, "xqlite");
        const exe = b.addExecutable(.{
            .name = b.fmt("testfixture-{s}", .{engine}),
            .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
        });
        const m = exe.root_module;
        const flags = std.mem.concat(b.allocator, []const u8, &.{ &.{
            "-DSQLITE_TEST=1",
            "-DSQLITE_CORE",
            "-DSQLITE_PRIVATE=",
            "-DBUILD_sqlite",
            "-DSQLITE_CKSUMVFS_STATIC",
            "-DSQLITE_STATIC_RANDOMJSON",
            "-DSQLITE_SERIES_CONSTRAINT_VERIFY=1",
            "-Wno-everything",
        }, &features }) catch @panic("OOM");
        // The engine's sqlite3.h first: include/ or the amalgamation's.
        m.addIncludePath(if (xq) b.path("include") else ref.dep.path("."));
        m.addIncludePath(gen.getDirectory());
        for ([_][]const u8{ "src", "ext/qrf", "ext/expert", "ext/misc" }) |d| m.addIncludePath(src_path.path(b, d));
        m.addIncludePath(tcl_path.path(b, "include"));
        m.addCSourceFile(.{ .file = test1, .flags = flags });
        for (helpers) |h| m.addCSourceFile(.{ .file = src_path.path(b, b.fmt("src/{s}.c", .{h})), .flags = flags });
        for (misc) |e| m.addCSourceFile(.{ .file = src_path.path(b, b.fmt("ext/misc/{s}.c", .{e})), .flags = flags });
        for ([_][]const u8{ "ext/expert/sqlite3expert.c", "ext/expert/test_expert.c", "ext/qrf/qrf.c" }) |f|
            m.addCSourceFile(.{ .file = src_path.path(b, f), .flags = flags });
        m.addCSourceFile(.{ .file = src_path.path(b, "src/tclsqlite.c"), .flags = concatFlags(b, flags, &.{"-DTCLSH_INIT_PROC=xqtclTestInit"}) });
        m.addCSourceFile(.{ .file = b.path("tools/tcl/shim.c"), .flags = concatFlags(b, flags, &.{b.fmt("-DXQTCL_ENGINE=\"{s}\"", .{engine})}) });
        if (xq) {
            m.linkLibrary(lib);
        } else {
            // As SQLite's configure builds it (sqliteRef()), with the
            // same optional parts.
            m.addCSourceFile(.{ .file = ref.dep.path("sqlite3.c"), .flags = concatFlags(b, &features, &(configure_flags ++ .{
                "-DSQLITE_WITHOUT_ZONEMALLOC",
                "-Wno-everything",
            })) });
        }
        m.addObjectFile(tcl_path.path(b, "lib/libtcl8.6.a"));
        m.linkSystemLibrary("z", .{});
        m.linkSystemLibrary("pthread", .{});
        m.linkSystemLibrary("m", .{});
        if (os == .macos) m.linkFramework("CoreFoundation", .{});
        if (os == .linux) m.linkSystemLibrary("dl", .{});
        step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}

/// An option's path as a LazyPath: absolute, or relative to the build
/// root.
fn optPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) .{ .cwd_relative = path } else b.path(path);
}

/// `base` then `more`.
fn concatFlags(b: *std.Build, base: []const []const u8, more: []const []const u8) []const []const u8 {
    return std.mem.concat(b.allocator, []const u8, &.{ base, more }) catch @panic("OOM");
}

/// The options sqlite_cfg.h gives on macOS and Linux that make a
/// difference, as SQLite's configure builds it (sqliteRef(), and the
/// reference SQLite of zig build testfixture).
const configure_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DHAVE_ISNAN=1",
    "-DHAVE_LOCALTIME_R=1",
    "-DHAVE_GMTIME_R=1",
    "-DHAVE_USLEEP=1",
};

/// `path` if absolute, else relative to the build root.
fn fromRoot(b: *std.Build, path: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return b.root.joinString(b.allocator, path) catch @panic("OOM");
}

/// The reference sqlite3 shells of the cross-checks, built from the
/// SQLite release this port tracks (the lazy dependency `sqlite`, the
/// 3.54.1 amalgamation), so that no sqlite3 has to be built by hand.
const SqliteRef = struct {
    /// sqlite3.c, shell.c and sqlite3.h.
    dep: *std.Build.Dependency,
    /// As SQLite's configure and make build it (the same compile_options
    /// but SQLITE_HAVE_ZLIB, which only the shell's .archive uses): for
    /// `xqt interop`, `bench`, `wasi`, `gen superjournal` and the
    /// btree_sqlite3 fuzzer. Installed as zig-out/bin/sqlite3-ref.
    shell: *std.Build.Step.Compile,
    install_shell: *std.Build.Step.InstallArtifact,
    /// For `xqt planner`, which compares bytecode: without
    /// SQLITE_ENABLE_EXPLAIN_COMMENTS (docs/testing.md).
    planner: *std.Build.Step.Compile,
};

/// Null in a project that depends on this one, which does not fetch
/// SQLite, and on the first run of the build script, after which the
/// build runner fetches the dependency and runs it again.
fn sqliteRef(b: *std.Build, target: std.Build.ResolvedTarget) ?SqliteRef {
    if (b.pkg_hash.len != 0) return null;
    const dep = b.lazyDependency("sqlite", .{}) orelse return null;
    const shell = sqliteShell(b, target, dep, "sqlite3-ref", &(configure_flags ++ .{
        // OPT_FEATURE_FLAGS.
        "-DNDEBUG",
        "-DSQLITE_ENABLE_MATH_FUNCTIONS",
        "-DSQLITE_ENABLE_PERCENTILE",
        // SHELL_OPT.
        "-DSQLITE_DQS=0",
        "-DSQLITE_ENABLE_BYTECODE_VTAB",
        "-DSQLITE_ENABLE_DBPAGE_VTAB",
        "-DSQLITE_ENABLE_DBSTAT_VTAB",
        "-DSQLITE_ENABLE_EXPLAIN_COMMENTS",
        "-DSQLITE_ENABLE_FTS4",
        "-DSQLITE_ENABLE_OFFSET_SQL_FUNC",
        "-DSQLITE_ENABLE_RTREE",
        "-DSQLITE_ENABLE_STMTVTAB",
        "-DSQLITE_ENABLE_UNKNOWN_SQL_FUNCTION",
        "-DSQLITE_STRICT_SUBTYPE=1",
    }));
    return .{
        .dep = dep,
        .shell = shell,
        .install_shell = b.addInstallArtifact(shell, .{}),
        .planner = sqliteShell(b, target, dep, "sqlite3-planner", &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_ENABLE_MATH_FUNCTIONS",
            "-DSQLITE_ENABLE_STMTVTAB",
            "-DSQLITE_ENABLE_BYTECODE_VTAB",
            "-DSQLITE_STRICT_SUBTYPE=1",
        }),
    };
}

/// SQLite's shell, on its own sqlite3.c, compiled with `flags`.
fn sqliteShell(b: *std.Build, target: std.Build.ResolvedTarget, dep: *std.Build.Dependency, name: []const u8, flags: []const []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
    });
    // SQLITE_WITHOUT_ZONEMALLOC: on macOS sqlite3MallocSize() is
    // otherwise the malloc zone's size of a block, whose rounding differs
    // from one Mac to another; rehash() sizes the hash tables by it, and
    // so the order ANALYZE visits the tables in (as the engine does, and
    // SQLite on Linux: the size asked for).
    const all = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-DSQLITE_WITHOUT_ZONEMALLOC", "-Wno-everything" } }) catch @panic("OOM");
    exe.root_module.addCSourceFiles(.{ .root = dep.path("."), .files = &.{ "sqlite3.c", "shell.c" }, .flags = all });
    exe.root_module.addIncludePath(dep.path("."));
    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("pthread", .{});
        exe.root_module.linkSystemLibrary("dl", .{});
        exe.root_module.linkSystemLibrary("m", .{});
    }
    return exe;
}

/// For a run of the fuzzers: the reference shell installed first, where
/// btree_sqlite3 looks for it (zig-out/bin/sqlite3-ref, unless $SQLITE3).
fn installSqliteRef(run: *std.Build.Step.Run, ref: ?SqliteRef) void {
    const r = ref orelse return;
    run.step.dependOn(&r.install_shell.step);
}

/// `xqt --xq XQLITE --crashshim SHIM --ext EXT --sqlite3 REF --sq PLANNER`, for
/// `zig build check`: run from the build root every time; the caller adds
/// the command. $SQLITE3 and $SQ, if set, still choose the shells.
fn addXqtRun(b: *std.Build, xqt: *std.Build.Step.Compile, xqlite: *std.Build.Step.Compile, crashshim: *std.Build.Step.Compile, ref: ?SqliteRef, ext: ?*std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(xqt);
    run.addArg("--xq");
    run.addArtifactArg(xqlite);
    run.addArg("--crashshim");
    run.addArtifactArg(crashshim);
    if (ext) |e| if (b.graph.environ_map.get("XQT_EXT") == null) {
        run.addArg("--ext");
        run.addArtifactArg(e);
    };
    if (ref) |r| {
        if (b.graph.environ_map.get("SQLITE3") == null) {
            run.addArg("--sqlite3");
            run.addArtifactArg(r.shell);
        }
        if (b.graph.environ_map.get("SQ") == null) {
            run.addArg("--sq");
            run.addArtifactArg(r.planner);
        }
    }
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// The VFS layer (pkg/vfs, a path dependency) for `target`, as the
/// import `xqlite_vfs` of a module. Its module takes the optimization
/// mode of the compilation that imports it; `optimize` goes to the
/// package for its own tests. The same arguments give the same module.
fn vfsImport(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.Module.Import {
    const dep = b.dependency("xqlite_vfs", .{ .target = target, .optimize = optimize });
    return .{ .name = "xqlite_vfs", .module = dep.module("xqlite_vfs") };
}

/// The imports of a module of the engine for `target`: the VFS, storage
/// and base packages, and the build configuration.
fn engineImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const std.Build.Module.Import {
    return engineImportsWith(b, target, optimize, configModule(b));
}

fn engineImportsWith(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, config_module: *std.Build.Module) []const std.Build.Module.Import {
    return b.allocator.dupe(std.Build.Module.Import, &([_]std.Build.Module.Import{
        vfsImport(b, target, optimize),
        storageImport(b, target, optimize),
        sqlparseImport(b, target, optimize),
        .{ .name = "xqlite_config", .module = config_module },
    } ++ leafImports(b, target, optimize))) catch @panic("OOM");
}

/// xqlite's version (build.zig.zon), `xqlite.config.version`.
const zon_version = @import("build.zig.zon").version;

/// `xqlite_config` with no dialect but SQLite's and no extension, for
/// tools/minimal_test.zig whatever -Ddialects and -Dext say.
fn minimalConfigModule(b: *std.Build) *std.Build.Module {
    const options = b.addOptions();
    for (Config.dialects) |name| options.addOption(bool, b.fmt("dialect_{s}", .{name}), false);
    for (Config.exts) |name| options.addOption(bool, b.fmt("ext_{s}", .{name}), false);
    options.addOption([]const u8, "version", zon_version);
    return options.createModule();
}

/// The build configuration, from -Ddialects and -Dext (configModule()).
const Config = struct {
    const dialects = [_][]const u8{ "postgres", "mariadb", "mssql", "oracle" };
    const exts = [_][]const u8{ "carray", "series", "vtablog" };
    dialect: [dialects.len]bool,
    ext: [exts.len]bool,
    module: *std.Build.Module,

    fn hasExt(c: Config, name: []const u8) bool {
        for (exts, c.ext) |e, on| if (std.mem.eql(u8, e, name)) return on;
        unreachable;
    }

    /// The configuration with the dialects `dialect` and the extensions
    /// `ext` (in the order of `dialects` and `exts`), with a module of
    /// its own: what `-Ddialects` and `-Dext` would give.
    fn make(b: *std.Build, dialect: [dialects.len]bool, ext: [exts.len]bool) Config {
        const options = b.addOptions();
        for (dialects, dialect) |name, on| options.addOption(bool, b.fmt("dialect_{s}", .{name}), on);
        for (exts, ext) |name, on| options.addOption(bool, b.fmt("ext_{s}", .{name}), on);
        options.addOption([]const u8, "version", zon_version);
        return .{ .dialect = dialect, .ext = ext, .module = options.createModule() };
    }

    /// "none", or the names of the dialects, joined by commas.
    fn label(c: Config, b: *std.Build) []const u8 {
        var names: std.ArrayList(u8) = .empty;
        for (dialects, c.dialect) |name, on| {
            if (!on) continue;
            if (names.items.len > 0) names.append(b.allocator, ',') catch @panic("OOM");
            names.appendSlice(b.allocator, name) catch @panic("OOM");
        }
        return if (names.items.len == 0) "none" else names.items;
    }
};

var config: ?Config = null;

/// -Dstrip: leave out debug information from the CLI, libxqlite3 and
/// libxqlite_ext (the release archives). Null keeps Zig's default.
fn stripOption(b: *std.Build) ?bool {
    if (strip_option == null) strip_option = .{b.option(bool, "strip", "Strip debug information from the CLI and the C libraries (default: Zig's, by -Doptimize)")};
    return strip_option.?[0];
}
var strip_option: ?struct { ?bool } = null;

/// `xqlite_config`, what the engine is built with: a `dialect_<name>`
/// bool for each dialect but SQLite's (-Ddialects, see
/// src/dialect/dialect.zig) and an `ext_<name>` bool for each built-in
/// extension (-Dext, see src/ext). The same module for every
/// compilation of the engine.
fn configModule(b: *std.Build) *std.Build.Module {
    return buildConfig(b).module;
}

fn buildConfig(b: *std.Build) Config {
    if (config) |c| return c;
    var on_all: [2][4]bool = undefined;
    const lists = [_]struct { []const u8, []const u8, []const []const u8 }{
        .{ "dialects", "dialect", &Config.dialects },
        .{ "ext", "ext", &Config.exts },
    };
    for (lists, &on_all) |l, *on| {
        const help = b.fmt("Comma-separated {s} to build in, of {s}; \"all\" or \"none\" (default: all)", .{ l[0], std.mem.join(b.allocator, ", ", l[2]) catch @panic("OOM") });
        const value = b.option([]const u8, l[0], help) orelse "all";
        on.* = @splat(std.mem.eql(u8, value, "all"));
        if (!std.mem.eql(u8, value, "all") and !std.mem.eql(u8, value, "none")) {
            var it = std.mem.tokenizeAny(u8, value, ", ");
            while (it.next()) |name| {
                for (l[2], 0..) |known, i| {
                    if (std.mem.eql(u8, name, known)) {
                        on[i] = true;
                        break;
                    }
                } else std.debug.panic("-D{s}: unknown name {s} (one of {s})", .{ l[0], name, std.mem.join(b.allocator, ", ", l[2]) catch "" });
            }
        }
    }
    config = .make(b, on_all[0], on_all[1][0..Config.exts.len].*);
    return config.?;
}

/// The packages with no dependency but std: the name of the path
/// dependency (build.zig.zon) and of the module it exports. The engine
/// imports each module under that name; `zig build test`, test-pkg and
/// test-wasi run the tests of each.
const LeafPkg = struct { dep: []const u8, module: []const u8 };
/// The helpers every layer shares; the storage package imports the same
/// module (see storageImport()).
const base_pkg: LeafPkg = .{ .dep = "xqlite_base", .module = "xqlite_base" };
/// The dialects' lexers; sqlparse imports it too.
const sqllex_pkg: LeafPkg = .{ .dep = "sqllex", .module = "sql/lexer" };
const leaf_pkgs = [_]LeafPkg{
    base_pkg,
    sqllex_pkg,
    .{ .dep = "uuid", .module = "uuid" }, // RFC 9562 UUIDs (PostgreSQL's uuid)
    .{ .dep = "decimal", .module = "decimal" }, // exact numbers (numeric)
    .{ .dep = "datetime", .module = "datetime" }, // calendar, interval
    .{ .dep = "json", .module = "json" }, // JSON escaping, SQLite's JSONB
    .{ .dep = "regex", .module = "regex" }, // PostgreSQL's regular expressions
    .{ .dep = "pgtext", .module = "pgtext" }, // PostgreSQL's array text
};

/// The module of `p` for `target`, as an import of the same name.
fn leafImport(b: *std.Build, p: LeafPkg, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.Module.Import {
    const dep = b.dependency(p.dep, .{ .target = target, .optimize = optimize });
    return .{ .name = p.module, .module = dep.module(p.module) };
}

fn leafImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) [leaf_pkgs.len]std.Build.Module.Import {
    var out: [leaf_pkgs.len]std.Build.Module.Import = undefined;
    for (leaf_pkgs, &out) |p, *o| o.* = leafImport(b, p, target, optimize);
    return out;
}

/// The tests of `p` for `target`: those `zig build test` runs in its
/// directory.
fn leafTests(b: *std.Build, p: LeafPkg, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) *std.Build.Step.Compile {
    const dep = b.dependency(p.dep, .{ .target = target, .optimize = optimize });
    return b.addTest(.{
        .name = b.fmt("{s}-test", .{p.dep}),
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = filters,
    });
}

fn leafTestsAll(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) [leaf_pkgs.len]*std.Build.Step.Compile {
    var out: [leaf_pkgs.len]*std.Build.Step.Compile = undefined;
    for (leaf_pkgs, &out) |p, *o| o.* = leafTests(b, p, target, optimize, filters);
    return out;
}

/// The sqlparse package (pkg/sql/parse, a path dependency) for `target`,
/// as the import `sqlparse` of a module (the dialects' parsers).
fn sqlparseImport(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.Module.Import {
    const dep = b.dependency("sqlparse", .{ .target = target, .optimize = optimize });
    return .{ .name = "sql/parse", .module = dep.module("sql/parse") };
}

/// The sqlparse package's tests for `target`: those `zig build test` runs
/// in pkg/sql/parse.
fn sqlparseTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) *std.Build.Step.Compile {
    const dep = b.dependency("sqlparse", .{ .target = target, .optimize = optimize });
    return b.addTest(.{
        .name = "sqlparse-test",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{leafImport(b, sqllex_pkg, target, optimize)},
        }),
        .filters = filters,
    });
}

/// The storage layer (pkg/storage, a path dependency) for `target`, as
/// the import `xqlite_storage` of a module. It imports the modules of
/// vfsImport() and leafImport(base_pkg) with the same arguments: the build system
/// makes one dependency of pkg/vfs and of pkg/base for the root and the
/// storage package alike.
fn storageImport(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.Module.Import {
    const dep = b.dependency("xqlite_storage", .{ .target = target, .optimize = optimize });
    return .{ .name = "xqlite_storage", .module = dep.module("xqlite_storage") };
}

/// The storage package's tests for `target`: those `zig build test` runs
/// in pkg/storage (but its optimized journal test).
fn storageTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) *std.Build.Step.Compile {
    const dep = b.dependency("xqlite_storage", .{ .target = target, .optimize = optimize });
    return b.addTest(.{
        .name = "storage-test",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ vfsImport(b, target, optimize), leafImport(b, base_pkg, target, optimize) },
        }),
        .filters = filters,
    });
}

/// The VFS package's tests for `target`: those `zig build test` runs in
/// pkg/vfs.
fn vfsTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) *std.Build.Step.Compile {
    const dep = b.dependency("xqlite_vfs", .{ .target = target, .optimize = optimize });
    return b.addTest(.{
        .name = "vfs-test",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag != .freestanding,
        }),
        .filters = filters,
    });
}
