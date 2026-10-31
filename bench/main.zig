//! The benchmark behind `zig build bench`. It times the codec and the
//! generator on fixed, seeded inputs and prints the median and fastest
//! of several samples in nanoseconds per operation. With `-Dcompare` it
//! runs the same cases through the rival libraries in bench/rivals.zig.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ulid = @import("ulid");
const rivals = @import("rivals");

/// Inputs per pass. Each operation reads the next input, so the work
/// varies from call to call while staying in the L2 cache.
const n_inputs = 4096;
/// Passes over the inputs per sample, about a millisecond of work.
const passes = 64;
const ops_per_sample = n_inputs * passes;
const n_warmup = 3;
const n_samples = 15;
const seed = 0x0123_4567_89ab_cdef;
/// 2026-10-31T00:00:00Z, the starting time for the generator cases.
const base_ms: u48 = 1_793_404_800_000;

const libs = .{Ours} ++ rivals.all;

/// The library under test, in the same adapter shape as the rivals.
const Ours = struct {
    pub const name = "ulid (this)";
    pub const Native = Ulid;
    pub const rng_injectable = true;

    pub fn fromUlid(u: Ulid) Ulid {
        return u;
    }

    pub fn toUlid(u: Ulid) Ulid {
        return u;
    }

    pub fn encode(u: *const Ulid, out: *[Ulid.encoded_len]u8) void {
        u.encode(out);
    }

    pub fn decode(text: *const [Ulid.encoded_len]u8) Ulid {
        return Ulid.decode(text, .{}) catch |err| @panic(@errorName(err));
    }

    pub fn decodeAliases(text: *const [Ulid.encoded_len]u8) Ulid {
        return Ulid.decode(text, .{ .aliases = true }) catch |err| @panic(@errorName(err));
    }

    pub const Generator = struct {
        g: Ulid.Generator = .{},
        random: std.Random,

        pub fn init(io: Io, random: std.Random) Generator {
            _ = io;
            return .{ .random = random };
        }

        pub fn next(gen: *Generator, ms: u48) Ulid {
            return gen.g.next(ms, gen.random) catch |err| @panic(@errorName(err));
        }
    };
};

const Inputs = struct {
    ulids: [n_inputs]Ulid,
    /// The canonical text of each ULID.
    texts: [n_inputs][Ulid.encoded_len]u8,
    /// The same text with every '0' written 'O' and every '1' written 'L'.
    aliased: [n_inputs][Ulid.encoded_len]u8,

    fn fill(in: *Inputs) void {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        for (&in.ulids, &in.texts, &in.aliased) |*u, *text, *aliased| {
            u.* = .init(random.int(u48), random.int(u80));
            u.encode(text);
            for (aliased, text) |*a, c| a.* = switch (c) {
                '0' => 'O',
                '1' => 'L',
                else => c,
            };
        }
    }
};

var inputs: Inputs = undefined;

const Stats = struct {
    median: f64,
    min: f64,
};

/// Runs `case.run(i)` over every input, `passes` times per sample, and
/// returns the median and fastest sample in nanoseconds per operation.
fn measure(io: Io, case: anytype) Stats {
    for (0..n_warmup) |_| runSample(case);
    var samples: [n_samples]i96 = undefined;
    for (&samples) |*sample| {
        const start: Io.Timestamp = .now(io, .awake);
        runSample(case);
        sample.* = start.durationTo(.now(io, .awake)).nanoseconds;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    return .{ .median = perOp(samples[n_samples / 2]), .min = perOp(samples[0]) };
}

fn runSample(case: anytype) void {
    for (0..passes) |_| {
        for (0..n_inputs) |i| case.run(i);
    }
}

fn perOp(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / ops_per_sample;
}

fn EncodeCase(comptime L: type) type {
    return struct {
        natives: *const [n_inputs]L.Native,
        out: [Ulid.encoded_len]u8 = undefined,

        fn run(c: *@This(), i: usize) void {
            L.encode(&c.natives[i], &c.out);
            std.mem.doNotOptimizeAway(&c.out);
        }
    };
}

fn DecodeCase(comptime L: type, comptime decodeFn: anytype) type {
    return struct {
        texts: *const [n_inputs][Ulid.encoded_len]u8,

        fn run(c: *@This(), i: usize) void {
            const x: L.Native = decodeFn(&c.texts[i]);
            std.mem.doNotOptimizeAway(&x);
        }
    };
}

const FormatCase = struct {
    ulids: *const [n_inputs]Ulid,
    buf: [Ulid.encoded_len]u8 = undefined,

    fn run(c: *FormatCase, i: usize) void {
        var w: Io.Writer = .fixed(&c.buf);
        w.print("{f}", .{c.ulids[i]}) catch unreachable;
        std.mem.doNotOptimizeAway(&c.buf);
    }
};

/// Calls `next` with the same timestamp every time when `same_ms` is
/// set, so the generator takes its increment path, and with a timestamp
/// one millisecond later every time otherwise, so it draws fresh
/// randomness.
fn NextCase(comptime L: type, comptime same_ms: bool) type {
    return struct {
        gen: L.Generator,
        ms: u48 = base_ms,

        fn run(c: *@This(), i: usize) void {
            _ = i;
            if (!same_ms) c.ms += 1;
            const x = c.gen.next(c.ms);
            std.mem.doNotOptimizeAway(&x);
        }
    };
}

const Table = struct {
    w: *Io.Writer,
    ours: Stats = undefined,

    fn header(t: *Table) !void {
        try t.w.print("{s:<28} {s:<28} {s:>12} {s:>10} {s:>8}\n", .{
            "case", "library", "median ns/op", "min ns/op", "vs ours",
        });
        try t.w.splatByteAll('-', 28 + 1 + 28 + 1 + 12 + 1 + 10 + 1 + 8);
        try t.w.writeByte('\n');
    }

    fn row(t: *Table, case: []const u8, comptime L: type, s: Stats) !void {
        if (L == Ours) t.ours = s;
        try t.w.print("{s:<28} {s:<28} {d:>12.2} {d:>10.2} {d:>7.2}x\n", .{
            case, L.name, s.median, s.min, s.median / t.ours.median,
        });
        try t.w.flush();
    }

    fn gap(t: *Table) !void {
        try t.w.writeByte('\n');
    }
};

/// Panics unless `L` encodes and decodes every input exactly as we do,
/// so the timings compare the same work.
fn check(comptime L: type, natives: *const [n_inputs]L.Native) void {
    for (natives, &inputs.ulids, &inputs.texts, &inputs.aliased) |*x, u, text, aliased| {
        var out: [Ulid.encoded_len]u8 = undefined;
        L.encode(x, &out);
        if (!std.mem.eql(u8, &out, &text)) @panic(L.name ++ ": encode differs");
        if (@hasDecl(L, "decode") and L.toUlid(L.decode(&text)).order(u) != .eq)
            @panic(L.name ++ ": decode differs");
        if (@hasDecl(L, "decodeAliases") and L.toUlid(L.decodeAliases(&aliased)).order(u) != .eq)
            @panic(L.name ++ ": decode with aliases differs");
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &stdout.interface;

    inputs.fill();

    try w.print("zig {s}, {t}, {d} inputs x {d} passes, median of {d} samples\n\n", .{
        builtin.zig_version_string, builtin.mode, n_inputs, passes, n_samples,
    });
    var t: Table = .{ .w = w };
    try t.header();

    inline for (libs) |L| {
        const ns = try init.arena.allocator().create([n_inputs]L.Native);
        for (ns, &inputs.ulids) |*x, u| x.* = L.fromUlid(u);
        check(L, ns);
        var c: EncodeCase(L) = .{ .natives = ns };
        try t.row("encode", L, measure(io, &c));
    }

    try t.gap();
    inline for (libs) |L| {
        if (@hasDecl(L, "decode")) {
            var c: DecodeCase(L, L.decode) = .{ .texts = &inputs.texts };
            try t.row("decode", L, measure(io, &c));
        }
    }

    try t.gap();
    inline for (libs) |L| {
        if (@hasDecl(L, "decodeAliases")) {
            var c: DecodeCase(L, L.decodeAliases) = .{ .texts = &inputs.aliased };
            try t.row("decode, aliases", L, measure(io, &c));
        }
    }

    try t.gap();
    {
        var c: FormatCase = .{ .ulids = &inputs.ulids };
        try t.row("format \"{f}\" to Io.Writer", Ours, measure(io, &c));
    }

    var prng: std.Random.DefaultPrng = .init(seed);
    const xoshiro = prng.random();
    const io_source: std.Random.IoSource = .{ .io = io };
    const io_random = io_source.interface();

    try t.gap();
    inline for (libs) |L| {
        if (@hasDecl(L, "Generator")) {
            var c: NextCase(L, true) = .{ .gen = .init(io, xoshiro) };
            try t.row("next, same ms", L, measure(io, &c));
        }
    }

    try t.gap();
    inline for (libs) |L| {
        if (@hasDecl(L, "Generator") and L.rng_injectable) {
            var c: NextCase(L, false) = .{ .gen = .init(io, xoshiro) };
            try t.row("next, new ms, Xoshiro256", L, measure(io, &c));
        }
    }

    try t.gap();
    inline for (libs) |L| {
        if (@hasDecl(L, "Generator")) {
            var c: NextCase(L, false) = .{ .gen = .init(io, io_random) };
            try t.row("next, new ms, Io.random", L, measure(io, &c));
        }
    }
    try w.flush();
}
