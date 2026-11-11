const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("ulid", .{
        .root_source_file = b.path("src/Ulid.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The tests have their own root, src/tests.zig, so that src/Ulid.zig
    // imports nothing outside the package paths in build.zig.zon.
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

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build example` runs examples/usecases.zig. The test step also
    // compiles it, so the examples cannot fall behind the API. Nothing
    // under examples/ is in the package paths.
    const example_exe = b.addExecutable(.{
        .name = "usecases",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/usecases.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ulid", .module = b.createModule(.{
                .root_source_file = b.path("src/Ulid.zig"),
                .target = target,
                .optimize = optimize,
            }) }},
        }),
    });
    test_step.dependOn(&example_exe.step);
    const example_step = b.step("example", "Run examples/usecases.zig");
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

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
}
