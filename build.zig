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
    _ = b.addModule("ulid", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/Ulid.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
    });

    // Creates an executable that will run `test` blocks. The tests have their own
    // root, src/tests.zig, so that src/Ulid.zig imports nothing outside the
    // package paths in build.zig.zon.
    // `zig build test --fuzz -Dllvm`: the self-hosted x86_64 backend emits no
    // coverage instrumentation, so 0.16.0's fuzzer has nothing to steer by.
    const llvm = b.option(bool, "llvm", "Build the tests with LLVM (needed for --fuzz)") orelse false;
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = if (llvm) true else null,
        // Zig 0.16.0's stock runner breaks --fuzz; see tools/test_runner.zig.
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .server },
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build bench` times the codec and the generator. It builds in
    // ReleaseFast unless -Dbench-optimize says otherwise, whatever
    // -Doptimize is. With -Dcompare it also runs the rival libraries that
    // bench/fetch-rivals.sh clones into bench/vendor. None of bench/ is in
    // the package paths, so consumers never fetch it.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimize mode for the bench step (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const compare = b.option(
        bool,
        "compare",
        "Also bench the rival libraries in bench/vendor",
    ) orelse false;

    const bench_ulid = b.createModule(.{
        .root_source_file = b.path("src/Ulid.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const rivals = b.createModule(.{
        .root_source_file = b.path(if (compare) "bench/rivals.zig" else "bench/no_rivals.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{.{ .name = "ulid", .module = bench_ulid }},
    });
    if (compare) {
        const vendored = [_]struct { []const u8, []const u8 }{
            .{ "hendrik", "bench/vendor/hendriknielaender-ulid.zig/src/ulid.zig" },
            .{ "jkoop", "bench/vendor/jkoop-ulid-zig/src/root.zig" },
            .{ "leroycep", "bench/vendor/leroycep-zig-ulid/ulid.zig" },
        };
        for (vendored) |v| {
            const name, const path = v;
            rivals.addImport(name, b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = bench_optimize,
            }));
        }
    }

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{ .name = "ulid", .module = bench_ulid },
                .{ .name = "rivals", .module = rivals },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the benchmark");
    bench_step.dependOn(&run_bench.step);

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
