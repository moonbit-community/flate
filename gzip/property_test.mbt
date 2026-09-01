// Property-based tests for the gzip container wrapper.

///|
/// Property: `gzip_compress` round-trips arbitrary bytes at every level, and
/// the optimal path round-trips too.
test "property: gzip round-trips at every level" {
  @quickcheck.check(
    (data : Bytes) => {
      for level in 0..<10 {
        if @gzip.gunzip(@gzip.gzip_compress(data, level~)) != data {
          return false
        }
      }
      if @gzip.gunzip(@gzip.gzip_compress_optimal(data, iterations=3)) != data {
        return false
      }
      true
    },
    count=40,
    max_size=2000,
    seed=0x6A7F001,
  )
}

///|
/// Property: decoding arbitrary bytes through `gunzip` never panics and is
/// deterministic — the same input yields the same bytes or error every time.
test "property: gunzip never panics and is deterministic" {
  @quickcheck.check(
    (data : Bytes) => {
      let a = try @gzip.gunzip(data) catch {
        @gzip.GzipError(_, _) => b""
      } noraise {
        ok => ok
      }
      let b = try @gzip.gunzip(data) catch {
        @gzip.GzipError(_, _) => b""
      } noraise {
        ok => ok
      }
      a == b
    },
    count=60,
    max_size=2000,
    seed=0x6A7F002,
  )
}
