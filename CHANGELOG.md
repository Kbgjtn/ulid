# Changelog

## 0.3.0 - unreleased

### Added

- `parseUuidV7` parses UUIDv7 text.
- `Generator.nextNowSecure` uses `io.randomSecure` and fails with `error.EntropyUnavailable` instead of falling back.
- `UuidError` and `UuidParseError` error sets.

### Changed

- **Breaking:** a seeded `std.Random` now gives different IDs from `next`. Order is unchanged.
- `jsonParse` no longer allocates. Strings longer than 26 bytes return `error.LengthMismatch`.
- `next` is faster within the same millisecond (7.2 to 5.0 ns).

### Fixed

- README: each fuzz test gets the full `--fuzz=N` limit.
