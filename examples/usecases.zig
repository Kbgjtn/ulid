//! Use cases for the ulid package, one function each. Run them all with
//!
//!     zig build example
//!
//! `zig build test` compiles this file, so every example here builds
//! against the current API. Read the functions in order: each one is
//! self-contained and prints what it shows.
const std = @import("std");
const Io = std.Io;
const Ulid = @import("ulid");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &stdout.interface;

    try generateFromTheClock(io, out);
    try generateUnguessable(io, out);
    try generateInTests(out);
    try parseUserInput(out);
    try readTheTimestamp(out);
    try queryATimeRange(out);
    try storeAsBytes(out);
    try convertToUuidV7(out);
    try readAndWriteJson(init.gpa, out);
    try shareOneGenerator(io, out);
    try decodeAtComptime(out);
    try out.flush();
}

/// 1. Generate IDs from the wall clock. One `Generator` keeps them strictly
/// increasing, even within one millisecond.
fn generateFromTheClock(io: Io, out: *Io.Writer) !void {
    try out.writeAll("\n== generate from the clock\n");
    var gen: Ulid.Generator = .{};
    var prev = try gen.nextNow(io);
    for (0..3) |_| {
        const id = try gen.nextNow(io);
        std.debug.assert(prev.order(id) == .lt);
        prev = id;
        // "{f}" prints the canonical uppercase text; fmtLower the lowercase.
        try out.print("{f}  {f}\n", .{ id, id.fmtLower() });
    }
}

/// 2. Generate IDs that cannot be guessed, for tokens or public URLs.
/// `nextNowSecure` reads entropy from the OS for every new millisecond and
/// fails instead of falling back to a weaker seed.
fn generateUnguessable(io: Io, out: *Io.Writer) !void {
    try out.writeAll("\n== generate unguessable IDs\n");
    var gen: Ulid.Generator = .{};
    // error.EntropyUnavailable means no OS entropy: refuse to issue a
    // token rather than issue a weak one.
    const id = try gen.nextNowSecure(io);
    try out.print("{f}\n", .{id});
}

/// 3. Generate fixed IDs in tests: pass the time and a seeded RNG to
/// `next`. The same inputs always give the same IDs.
fn generateInTests(out: *Io.Writer) !void {
    try out.writeAll("\n== fixed IDs for tests\n");
    const ms: u48 = 1_700_000_000_000;
    var prng: std.Random.DefaultPrng = .init(42);
    var gen: Ulid.Generator = .{};
    const a = try gen.next(ms, prng.random());
    const b = try gen.next(ms, prng.random());
    // The same millisecond adds one to the random part.
    std.debug.assert(b.randomness() == a.randomness() + 1);
    try out.print("{f}\n{f}\n", .{ a, b });
}

/// 4. Parse IDs from user input, with a distinct message per error.
/// Lowercase is accepted by default; `.aliases = true` also reads I and L
/// as 1 and O as 0, for IDs typed by hand.
fn parseUserInput(out: *Io.Writer) !void {
    try out.writeAll("\n== parse user input\n");
    const inputs = [_][]const u8{
        "01ARZ3NDEKTSV4RRFFQ69G5FAV", // canonical
        "01arz3ndektsv4rrffq69g5fav", // lowercase: accepted
        "OLARZ3NDEKTSV4RRFFQ69G5FAV", // O and L: rejected unless aliases
        "01ARZ3", // too short
        "8ZZZZZZZZZZZZZZZZZZZZZZZZZ", // above the 128-bit maximum
    };
    for (inputs) |text| {
        if (Ulid.decode(text, .{})) |id| {
            try out.print("ok       {s} -> {f}\n", .{ text, id });
        } else |err| {
            const why = switch (err) {
                error.UlidInvalidLength => "must be 26 characters",
                error.UlidInvalidCharacter => "not Crockford base32",
                error.UlidOverflow => "first character above 7",
            };
            try out.print("rejected {s}: {s}\n", .{ text, why });
        }
    }
    const typed = try Ulid.decode("OLARZ3NDEKTSV4RRFFQ69G5FAV", .{ .aliases = true });
    try out.print("aliases  OLARZ3NDEKTSV4RRFFQ69G5FAV -> {f}\n", .{typed});
}

/// 5. Read when an ID was made. The timestamp is Unix milliseconds.
fn readTheTimestamp(out: *Io.Writer) !void {
    try out.writeAll("\n== read the timestamp\n");
    const id = try Ulid.decode("01ARZ3NDEKTSV4RRFFQ69G5FAV", .{});
    const ms = id.timestamp();
    const secs: std.time.epoch.EpochSeconds = .{ .secs = ms / 1000 };
    const day = secs.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const clock = secs.getDaySeconds();
    try out.print("{f} was made at {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} UTC\n", .{
        id,                               day.year,                month_day.month.numeric(),
        @as(u8, month_day.day_index) + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(),
        clock.getSecondsIntoMinute(),     ms % 1000,
    });
}

/// 6. Query a time range in a store sorted by ID. The smallest and largest
/// IDs of a millisecond bound every ID made in it, as bytes or as text.
fn queryATimeRange(out: *Io.Writer) !void {
    try out.writeAll("\n== bounds for a time range\n");
    const from_ms: u48 = 1_700_000_000_000;
    const to_ms: u48 = from_ms + 60_000; // one minute
    const low: Ulid = .init(from_ms, 0);
    const high: Ulid = .init(to_ms, std.math.maxInt(u80));
    try out.print("WHERE id BETWEEN '{f}' AND '{f}'\n", .{ low, high });
}

/// 7. Store IDs as 16 raw bytes, for example in a binary key column. The
/// bytes are big-endian, so sorting the bytes sorts by time.
fn storeAsBytes(out: *Io.Writer) !void {
    try out.writeAll("\n== store as 16 bytes\n");
    const id = try Ulid.decode("01ARZ3NDEKTSV4RRFFQ69G5FAV", .{});
    const key: [16]u8 = id.bytes;
    const back: Ulid = .{ .bytes = key };
    std.debug.assert(back.order(id) == .eq);
    try out.print("{x}\n", .{key});
}

/// 8. Exchange IDs with systems that expect a UUID, such as a database
/// `uuid` column. `toUuidV7` overwrites 6 random bits with the UUID version
/// and variant; `fromUuidV7` and `parseUuidV7` keep all 128 bits.
fn convertToUuidV7(out: *Io.Writer) !void {
    try out.writeAll("\n== UUIDv7\n");
    const id = try Ulid.decode("01ARZ3NDEKTSV4RRFFQ69G5FAV", .{});
    try out.print("as UUIDv7 text: {f}\n", .{id.fmtUuid()});

    const from_db = try Ulid.parseUuidV7("017f22e2-79b0-7cc3-98c4-dc0c0c07398f");
    try out.print("from UUIDv7:    {f}\n", .{from_db});

    if (Ulid.parseUuidV7("017f22e2-79b0-4cc3-98c4-dc0c0c07398f")) |_| {
        unreachable;
    } else |err| switch (err) {
        error.UuidNotV7 => try out.writeAll("a UUIDv4 is rejected: UuidNotV7\n"),
        error.UuidInvalidLength, error.UuidInvalidCharacter => unreachable,
    }
}

/// 9. Read and write IDs in JSON. A `Ulid` field is its 26-character
/// string. Parsing a `Ulid` itself allocates nothing.
fn readAndWriteJson(gpa: std.mem.Allocator, out: *Io.Writer) !void {
    try out.writeAll("\n== JSON\n");
    const Order = struct { id: Ulid, total_cents: u32 };

    const order: Order = .{ .id = try Ulid.decode("01ARZ3NDEKTSV4RRFFQ69G5FAV", .{}), .total_cents = 1299 };
    const text = try std.json.Stringify.valueAlloc(gpa, order, .{});
    defer gpa.free(text);
    try out.print("{s}\n", .{text});

    const parsed = try std.json.parseFromSlice(Order, gpa, text, .{});
    defer parsed.deinit();
    std.debug.assert(parsed.value.id.order(order.id) == .eq);
}

/// 10. Share one generator between tasks. `Generator` has no lock of its
/// own, so guard it with a mutex. For IDs that need not be ordered across
/// tasks, give each task its own generator instead.
fn shareOneGenerator(io: Io, out: *Io.Writer) !void {
    try out.writeAll("\n== one generator, many tasks\n");
    const Shared = struct {
        mutex: Io.Mutex = .init,
        gen: Ulid.Generator = .{},
        ids: [8]Ulid = undefined,
        len: usize = 0,

        fn worker(s: *@This(), task_io: Io) Io.Cancelable!void {
            for (0..2) |_| {
                try s.mutex.lock(task_io);
                defer s.mutex.unlock(task_io);
                // Overflow needs 2^80 IDs in one millisecond.
                s.ids[s.len] = s.gen.nextNow(task_io) catch unreachable;
                s.len += 1;
            }
        }
    };
    var shared: Shared = .{};
    var group: Io.Group = .init;
    for (0..4) |_| group.async(io, Shared.worker, .{ &shared, io });
    try group.await(io);

    // Taken under the lock, so the IDs are strictly increasing in the
    // order they were stored.
    for (shared.ids[0..shared.len], 0..) |id, i| {
        if (i > 0) std.debug.assert(shared.ids[i - 1].order(id) == .lt);
        try out.print("{f}\n", .{id});
    }
}

/// 11. Decode constant IDs at compile time. A bad literal is a compile
/// error, not a runtime one.
fn decodeAtComptime(out: *Io.Writer) !void {
    try out.writeAll("\n== comptime\n");
    const root_id = comptime Ulid.decode("01ARZ3NDEKTSV4RRFFQ69G5FAV", .{}) catch unreachable;
    try out.print("{f} has timestamp {d}\n", .{ root_id, root_id.timestamp() });
}
